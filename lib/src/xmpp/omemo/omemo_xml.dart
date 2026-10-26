import 'dart:convert';
import 'dart:typed_data';

import '../xmpp_xml.dart';
import 'omemo_engine.dart';
import 'omemo_keys.dart';
import 'omemo_suite.dart';

/// Stanza building and parsing for both OMEMO versions (XEP-0384): device
/// lists, bundles, encrypted messages, and the stanza content envelope of
/// OMEMO 2 (XEP-0420). Everything read from the network is bounded.
abstract final class OmemoXml {
  static const int maxDevices = 100;
  static const int maxKeysPerMessage = 600;
  static const int maxPayloadBytes = 256 * 1024;

  static const eme = 'urn:xmpp:eme:0';
  static const sce = 'urn:xmpp:sce:1';

  // ---- PEP node names ----------------------------------------------------

  static String deviceListNode(OmemoVersion version) =>
      version == OmemoVersion.legacy
      ? 'eu.siacs.conversations.axolotl.devicelist'
      : 'urn:xmpp:omemo:2:devices';

  static String bundleNode(OmemoVersion version, int deviceId) =>
      version == OmemoVersion.legacy
      ? 'eu.siacs.conversations.axolotl.bundles:$deviceId'
      : 'urn:xmpp:omemo:2:bundles';

  static String bundleItemId(OmemoVersion version, int deviceId) =>
      version == OmemoVersion.legacy ? 'current' : '$deviceId';

  // ---- Device lists ------------------------------------------------------

  static XmppElement deviceList(
    OmemoVersion version,
    Iterable<int> ids, {
    String label = 'Conest',
    int? labelFor,
  }) {
    final root = XmppElement(
      version == OmemoVersion.legacy ? 'list' : 'devices',
      xmlns: version.namespace,
    );
    for (final id in ids) {
      root.add(
        XmppElement(
          'device',
          attributes: {
            'id': '$id',
            if (version == OmemoVersion.v2 && id == labelFor) 'label': label,
          },
        ),
      );
    }
    return root;
  }

  /// The device ids of a published list; null when [element] is no list.
  static List<int>? parseDeviceList(OmemoVersion version, XmppElement element) {
    final expectedName = version == OmemoVersion.legacy ? 'list' : 'devices';
    if (element.name != expectedName || element.xmlns != version.namespace) {
      return null;
    }
    final ids = <int>[];
    for (final device in element.all('device').take(maxDevices)) {
      final id = int.tryParse(device.attr('id') ?? '');
      if (id != null && id > 0 && id <= 0x7fffffff && !ids.contains(id)) {
        ids.add(id);
      }
    }
    return ids;
  }

  // ---- Bundles -----------------------------------------------------------

  static String _b64(List<int> bytes) => base64.encode(bytes);

  static XmppElement bundle(OmemoBundle bundle) {
    final version = bundle.version;
    final suite = version.suite;
    final root = XmppElement('bundle', xmlns: version.namespace);
    if (version == OmemoVersion.legacy) {
      // Our signatures are XEdDSA (the Edwards key with sign bit 0), so the
      // sign bit that older libraries read from the signature is 0 too.
      final signature = bundle.signedPreKeySignature;
      root
        ..add(
          XmppElement(
            'signedPreKeyPublic',
            attributes: {'signedPreKeyId': '${bundle.signedPreKeyId}'},
            text: _b64(suite.encodePublic(bundle.signedPreKey)),
          ),
        )
        ..add(XmppElement('signedPreKeySignature', text: _b64(signature)))
        ..add(
          XmppElement(
            'identityKey',
            text: _b64(suite.encodePublic(bundle.identityMontgomery)),
          ),
        );
      final prekeys = XmppElement('prekeys');
      for (final entry in bundle.preKeys.entries) {
        prekeys.add(
          XmppElement(
            'preKeyPublic',
            attributes: {'preKeyId': '${entry.key}'},
            text: _b64(suite.encodePublic(entry.value)),
          ),
        );
      }
      return root..add(prekeys);
    }
    root
      ..add(
        XmppElement(
          'spk',
          attributes: {'id': '${bundle.signedPreKeyId}'},
          text: _b64(bundle.signedPreKey),
        ),
      )
      ..add(XmppElement('spks', text: _b64(bundle.signedPreKeySignature)))
      ..add(XmppElement('ik', text: _b64(bundle.identityEdwards)));
    final prekeys = XmppElement('prekeys');
    for (final entry in bundle.preKeys.entries) {
      prekeys.add(
        XmppElement(
          'pk',
          attributes: {'id': '${entry.key}'},
          text: _b64(entry.value),
        ),
      );
    }
    return root..add(prekeys);
  }

  static Uint8List? _decode(String? text, {int? length}) {
    if (text == null) return null;
    try {
      final bytes = base64.decode(text.replaceAll(RegExp(r'\s'), ''));
      if (length != null && bytes.length != length) return null;
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  /// A device's bundle from its published element, or null when malformed.
  static OmemoBundle? parseBundle(OmemoVersion version, XmppElement element) {
    if (element.name != 'bundle' || element.xmlns != version.namespace) {
      return null;
    }
    final suite = version.suite;
    if (version == OmemoVersion.legacy) {
      final spk = element.child('signedPreKeyPublic');
      final spkId = int.tryParse(spk?.attr('signedPreKeyId') ?? '');
      final signedPreKeyEncoded = _decode(spk?.text, length: 33);
      final signature = _decode(
        element.childText('signedPreKeySignature'),
        length: 64,
      );
      final identityEncoded = _decode(
        element.childText('identityKey'),
        length: 33,
      );
      if (spkId == null ||
          signedPreKeyEncoded == null ||
          signature == null ||
          identityEncoded == null) {
        return null;
      }
      try {
        final preKeys = <int, Uint8List>{};
        for (final item
            in (element.child('prekeys')?.all('preKeyPublic') ??
                    const <XmppElement>[])
                .take(OmemoBundle.maxPreKeys)) {
          final id = int.tryParse(item.attr('preKeyId') ?? '');
          final key = _decode(item.text, length: 33);
          if (id == null || key == null) continue;
          preKeys[id] = Uint8List.fromList(suite.decodePublic(key));
        }
        return OmemoBundle.legacy(
          identityMontgomery: Uint8List.fromList(
            suite.decodePublic(identityEncoded),
          ),
          signedPreKeyId: spkId,
          signedPreKey: Uint8List.fromList(
            suite.decodePublic(signedPreKeyEncoded),
          ),
          signedPreKeySignature: signature,
          preKeys: preKeys,
        );
      } catch (_) {
        return null;
      }
    }
    final spk = element.child('spk');
    final spkId = int.tryParse(spk?.attr('id') ?? '');
    final signedPreKey = _decode(spk?.text, length: 32);
    final signature = _decode(element.childText('spks'), length: 64);
    final identity = _decode(element.childText('ik'), length: 32);
    if (spkId == null ||
        signedPreKey == null ||
        signature == null ||
        identity == null) {
      return null;
    }
    final preKeys = <int, Uint8List>{};
    for (final item
        in (element.child('prekeys')?.all('pk') ?? const <XmppElement>[]).take(
          OmemoBundle.maxPreKeys,
        )) {
      final id = int.tryParse(item.attr('id') ?? '');
      final key = _decode(item.text, length: 32);
      if (id == null || key == null) continue;
      preKeys[id] = key;
    }
    return OmemoBundle.omemo2(
      identityEdwards: identity,
      signedPreKeyId: spkId,
      signedPreKey: signedPreKey,
      signedPreKeySignature: signature,
      preKeys: preKeys,
    );
  }

  // ---- Encrypted messages ------------------------------------------------

  /// The `<encrypted>` element for [keys] (grouped per recipient JID in
  /// OMEMO 2) and the [payload].
  static XmppElement encrypted({
    required OmemoVersion version,
    required int senderDevice,
    required List<OmemoEncryptedKey> keys,
    required OmemoPayload payload,
  }) {
    final root = XmppElement('encrypted', xmlns: version.namespace);
    final header = XmppElement(
      'header',
      attributes: {'sid': '$senderDevice'},
    );
    if (version == OmemoVersion.legacy) {
      for (final key in keys) {
        header.add(
          XmppElement(
            'key',
            attributes: {
              'rid': '${key.deviceId}',
              if (key.keyExchange) 'prekey': 'true',
            },
            text: _b64(key.blob),
          ),
        );
      }
      header.add(XmppElement('iv', text: _b64(payload.iv ?? Uint8List(12))));
    } else {
      final byJid = <String, List<OmemoEncryptedKey>>{};
      for (final key in keys) {
        byJid.putIfAbsent(key.jid, () => []).add(key);
      }
      for (final entry in byJid.entries) {
        final group = XmppElement('keys', attributes: {'jid': entry.key});
        for (final key in entry.value) {
          group.add(
            XmppElement(
              'key',
              attributes: {
                'rid': '${key.deviceId}',
                if (key.keyExchange) 'kex': 'true',
              },
              text: _b64(key.blob),
            ),
          );
        }
        header.add(group);
      }
    }
    root.add(header);
    if (payload.ciphertext.isNotEmpty) {
      root.add(XmppElement('payload', text: _b64(payload.ciphertext)));
    }
    return root;
  }

  static List<XmppElement> fallback(OmemoVersion version) => [
    XmppElement(
      'body',
      text:
          'I sent you an OMEMO encrypted message but your client doesn’t '
          'seem to support that. Find more information on '
          'https://conversations.im/omemo',
    ),
    XmppElement(
      'encryption',
      xmlns: eme,
      attributes: {
        'namespace': version.namespace,
        'name': version == OmemoVersion.legacy ? 'OMEMO' : 'OMEMO 2',
      },
    ),
    XmppElement('store', xmlns: XmppNs.hints),
  ];

  /// What an `<encrypted>` element says: who sent it, the keys for
  /// [ownJid]'s device [ownDevice], and the payload.
  static OmemoIncoming? parseEncrypted(
    XmppElement element, {
    required String ownJid,
    required int ownDevice,
  }) {
    final version = OmemoVersion.byNamespace(element.xmlns);
    if (element.name != 'encrypted' || version == null) return null;
    final header = element.child('header');
    final sender = int.tryParse(header?.attr('sid') ?? '');
    if (header == null || sender == null || sender <= 0) return null;

    Uint8List? payload;
    final payloadText = element.child('payload')?.text;
    if (payloadText != null) {
      if (payloadText.length > maxPayloadBytes * 2) return null;
      payload = _decode(payloadText);
      if (payload == null || payload.length > maxPayloadBytes) return null;
    }

    Uint8List? blob;
    var keyExchange = false;
    var seen = 0;
    void consider(XmppElement key) {
      if (++seen > maxKeysPerMessage) return;
      if (int.tryParse(key.attr('rid') ?? '') != ownDevice) return;
      if (key.text.length > maxPayloadBytes) return;
      blob = _decode(key.text);
      keyExchange = const ['true', '1'].contains(
        key.attr(version == OmemoVersion.legacy ? 'prekey' : 'kex'),
      );
    }

    Uint8List? iv;
    if (version == OmemoVersion.legacy) {
      for (final key in header.all('key')) {
        consider(key);
      }
      iv = _decode(header.childText('iv'), length: 12);
    } else {
      for (final group in header.all('keys')) {
        if (group.attr('jid')?.toLowerCase() != ownJid) continue;
        for (final key in group.all('key')) {
          consider(key);
        }
      }
    }
    return OmemoIncoming(
      version: version,
      senderDevice: sender,
      key: blob,
      keyExchange: keyExchange,
      payload: payload,
      iv: iv,
    );
  }

  // ---- Stanza content envelope (OMEMO 2) ---------------------------------

  /// The envelope that OMEMO 2 encrypts: [content] children, random
  /// padding, a time stamp, and the addresses.
  static String envelope({
    required List<XmppElement> content,
    required String to,
    required String from,
    required DateTime at,
    required String padding,
  }) {
    final root = XmppElement(
      'envelope',
      xmlns: sce,
      children: [
        XmppElement(
          'content',
          children: [
            for (final element in content)
              // Content elements are in the client namespace.
              _inClientNamespace(element),
          ],
        ),
        XmppElement('rpad', text: padding),
        XmppElement(
          'time',
          attributes: {'stamp': at.toUtc().toIso8601String()},
        ),
        XmppElement('to', attributes: {'jid': to}),
        XmppElement('from', attributes: {'jid': from}),
      ],
    );
    return root.toXml();
  }

  static XmppElement _inClientNamespace(XmppElement element) => XmppElement(
    element.name,
    xmlns: element.xmlns ?? XmppNs.client,
    attributes: element.attributes,
    children: element.children,
    text: element.text,
  );

  /// Reads a decrypted envelope; null when it is not one, or when it names
  /// other addresses than [from] (the sender's bare JID) and [to] (this
  /// account's, or the chat's).
  static OmemoEnvelope? parseEnvelope(
    String xml, {
    required String from,
    required String to,
  }) {
    if (xml.length > maxPayloadBytes) return null;
    final XmppElement root;
    try {
      final events = XmppStreamParser(
        framed: true,
        maxElementChars: maxPayloadBytes,
        maxDepth: 12,
        maxChildren: 256,
      ).addText(xml);
      final first = events.whereType<XmppStreamElement>().firstOrNull;
      if (first == null) return null;
      root = first.element;
    } catch (_) {
      return null;
    }
    if (root.name != 'envelope' || root.xmlns != sce) return null;
    final content = root.child('content');
    if (content == null) return null;
    final fromJid = root.child('from')?.attr('jid');
    final toJid = root.child('to')?.attr('jid');
    // The addresses inside must match the ones outside; both are needed
    // so a message cannot be moved to another conversation.
    if (fromJid == null || bareJid(fromJid) != from) return null;
    if (toJid == null || bareJid(toJid) != to) return null;
    return OmemoEnvelope(
      content: content.children,
      at: DateTime.tryParse(root.child('time')?.attr('stamp') ?? ''),
    );
  }
}

class OmemoIncoming {
  const OmemoIncoming({
    required this.version,
    required this.senderDevice,
    required this.key,
    required this.keyExchange,
    required this.payload,
    required this.iv,
  });

  final OmemoVersion version;
  final int senderDevice;

  /// The key blob for this device, if the message has one.
  final Uint8List? key;
  final bool keyExchange;
  final Uint8List? payload;
  final Uint8List? iv;
}

class OmemoEnvelope {
  const OmemoEnvelope({required this.content, required this.at});
  final List<XmppElement> content;
  final DateTime? at;
}

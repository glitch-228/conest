import 'dart:async';
import 'dart:convert';

import 'omemo/omemo_engine.dart';
import 'omemo/omemo_keys.dart';
import 'omemo/omemo_proto.dart';
import 'omemo/omemo_random.dart';
import 'omemo/omemo_ratchet.dart';
import 'omemo/omemo_suite.dart';
import 'omemo/omemo_xml.dart';
import 'xmpp_session.dart';
import 'xmpp_xml.dart';

const _pubsub = 'http://jabber.org/protocol/pubsub';
const _publishOptions = 'http://jabber.org/protocol/pubsub#publish-options';

/// The device lists of a contact could not be read, so nobody can say
/// whether to encrypt (or to whom). Sending plain text instead would be a
/// silent downgrade, so the caller must fail.
class OmemoLookupFailed implements Exception {
  const OmemoLookupFailed(this.jid, this.reason);
  final String jid;
  final String reason;
  @override
  String toString() => 'Could not check the encryption keys of $jid: $reason';
}

/// None of the contact's devices could take an encrypted message.
class OmemoNoRecipients implements Exception {
  const OmemoNoRecipients(this.jid);
  final String jid;
  @override
  String toString() => 'No device of $jid could be encrypted to.';
}

/// What reading an incoming encrypted message gave.
class OmemoReceived {
  const OmemoReceived({
    required this.version,
    required this.senderDevice,
    this.content,
    this.body,
    this.trust,
    this.failure,
    this.at,
  });

  final OmemoVersion version;
  final int senderDevice;

  /// Elements that were inside the encryption (OMEMO 2), to merge into the
  /// message.
  final List<XmppElement>? content;

  /// The text (legacy: the whole payload; OMEMO 2: the envelope's body).
  final String? body;

  /// The sender device's trust, when known.
  final OmemoTrust? trust;

  /// Why the message could not be read, if so.
  final String? failure;

  /// The time the sender put inside the encryption (OMEMO 2); unlike the
  /// outer delay it cannot be changed by a server.
  final DateTime? at;

  bool get readable => failure == null;
}

/// One device of a contact as the keys screen shows it.
class OmemoDeviceInfo {
  const OmemoDeviceInfo({
    required this.id,
    required this.fingerprint,
    required this.trust,
    required this.versions,
    required this.changed,
  });

  final int id;

  /// Empty until the device's keys were fetched or used once.
  final String fingerprint;
  final OmemoTrust trust;
  final Set<OmemoVersion> versions;

  /// A different key was published under the remembered device id.
  final bool changed;
}

/// What scanning a contact's code did.
class OmemoScanResult {
  const OmemoScanResult({required this.verified, required this.mismatched});

  /// Devices whose fingerprint matched and are now verified.
  final int verified;

  /// Devices named in the code with another fingerprint than the one known.
  final int mismatched;
}

/// OMEMO over an XMPP session (XEP-0384): publishes this device's keys,
/// finds other people's, and wraps/unwraps messages. The cryptography is
/// in [OmemoEngine]; this class only does the XMPP and the policy.
class XmppOmemo {
  XmppOmemo({
    required this.session,
    required this.load,
    required this.save,
    OmemoRandom? random,
    DateTime Function()? now,
    this.log,
    this.legacyEnabled = false,
  }) : _random = random ?? SecureOmemoRandom(),
       _now = now ?? DateTime.now;

  final XmppSession session;

  /// Reads and writes the engine's saved state (kept in the vault).
  final Map<String, Object?>? Function() load;
  final void Function(Map<String, Object?> state) save;
  final void Function(String line)? log;
  final OmemoRandom _random;
  final DateTime Function() _now;

  /// Whether legacy OMEMO is used at all. Off until it has been checked
  /// against the reference implementations and reviewed.
  bool legacyEnabled;

  OmemoEngine? _engine;
  OmemoEngine? get engine => _engine;
  String get ownJid => session.jid.toLowerCase();

  /// Devices the last encryption left out, with the reason (for the UI).
  final List<(String, int, String)> skippedDevices = [];

  /// Cached device lists: jid -> (version -> ids), with the time read.
  final Map<String, _Devices> _devices = {};
  static const Duration deviceListAge = Duration(minutes: 5);
  static const int maxCachedJids = 500;

  /// Bundles fetched, by "version|jid|device"; only used to start a
  /// session, so they are kept briefly.
  Future<void> _serial = Future.value();

  Iterable<OmemoVersion> get versions => [
    OmemoVersion.v2,
    if (legacyEnabled) OmemoVersion.legacy,
  ];

  /// Loads or makes this device's keys and publishes them. Safe to call on
  /// every connection.
  Future<void> setUp() async {
    var engine = _engine;
    if (engine == null) {
      final stored = load();
      if (stored != null) {
        engine = await OmemoEngine.restore(stored, random: _random);
      }
      engine ??= await OmemoEngine.create(random: _random);
      _engine = engine;
      _persist();
    }
    if (await engine.maintainKeys()) _persist();
    for (final version in versions) {
      await _publishDevice(version);
      await _publishBundle(version);
    }
  }

  void _persist() {
    final engine = _engine;
    if (engine != null) save(engine.toJson());
  }

  // ---- Publishing --------------------------------------------------------

  XmppElement _iq(String type, XmppElement pubsub, {String? to}) => XmppElement(
    'iq',
    attributes: {'type': type, 'to': ?to},
    children: [pubsub],
  );

  XmppElement _options({required String maxItems}) => XmppElement(
    'publish-options',
    children: [
      XmppElement(
        'x',
        xmlns: XmppNs.dataForms,
        attributes: {'type': 'submit'},
        children: [
          _field('FORM_TYPE', _publishOptions, hidden: true),
          _field('pubsub#persist_items', 'true'),
          _field('pubsub#max_items', maxItems),
          _field('pubsub#access_model', 'open'),
        ],
      ),
    ],
  );

  XmppElement _field(String name, String value, {bool hidden = false}) =>
      XmppElement(
        'field',
        attributes: {'var': name, if (hidden) 'type': 'hidden'},
        children: [XmppElement('value', text: value)],
      );

  Future<void> _publish(
    String node,
    String itemId,
    XmppElement payload, {
    required String maxItems,
  }) async {
    Future<void> attempt(bool withOptions) async {
      await session.request(
        _iq(
          'set',
          XmppElement(
            'pubsub',
            xmlns: _pubsub,
            children: [
              XmppElement(
                'publish',
                attributes: {'node': node},
                children: [
                  XmppElement(
                    'item',
                    attributes: {'id': itemId},
                    children: [payload],
                  ),
                ],
              ),
              if (withOptions) _options(maxItems: maxItems),
            ],
          ),
        ),
      );
    }

    try {
      await attempt(true);
    } on XmppStanzaError catch (error) {
      // A server that wants other options, or none, still stores the item.
      if (error.condition == 'conflict' ||
          error.condition == 'feature-not-implemented' ||
          error.condition == 'bad-request') {
        await attempt(false);
      } else {
        rethrow;
      }
    }
  }

  Future<void> _publishDevice(OmemoVersion version) async {
    final engine = _engine!;
    // Keep the other devices of this account in the list.
    var ids = <int>[];
    try {
      ids = await _fetchDeviceList(ownJid, version, own: true);
    } on OmemoLookupFailed {
      // Publish just this device rather than none; others re-add theirs.
    }
    final all = {...ids, engine.deviceId}.take(OmemoXml.maxDevices).toList();
    if (ids.contains(engine.deviceId) && ids.length == all.length) {
      return;
    }
    await _publish(
      OmemoXml.deviceListNode(version),
      'current',
      OmemoXml.deviceList(version, all, labelFor: engine.deviceId),
      maxItems: '1',
    );
    _devices[ownJid] = (_devices[ownJid] ?? _Devices(_now()))
      ..set(version, all, _now());
  }

  Future<void> _publishBundle(OmemoVersion version) async {
    final engine = _engine!;
    final bundle = await engine.ownBundle(version);
    await _publish(
      OmemoXml.bundleNode(version, engine.deviceId),
      OmemoXml.bundleItemId(version, engine.deviceId),
      OmemoXml.bundle(bundle),
      maxItems: version == OmemoVersion.legacy ? '1' : 'max',
    );
  }

  /// Publishes the bundles again (after pre keys were spent or rotated).
  Future<void> refreshBundles() => _locked(() async {
    final engine = _engine;
    if (engine == null) return;
    if (await engine.maintainKeys()) {
      _persist();
      for (final version in versions) {
        await _publishBundle(version);
      }
    }
  });

  // ---- Looking up other devices -----------------------------------------

  Future<XmppElement?> _item(String? jid, String node, {String? itemId}) async {
    final XmppElement answer;
    try {
      answer = await session.request(
        _iq(
          'get',
          XmppElement(
            'pubsub',
            xmlns: _pubsub,
            children: [
              XmppElement(
                'items',
                attributes: {'node': node, 'max_items': '1'},
                children: [
                  if (itemId != null)
                    XmppElement('item', attributes: {'id': itemId}),
                ],
              ),
            ],
          ),
          to: jid,
        ),
      );
    } on XmppStanzaError catch (error) {
      if (const [
        'item-not-found',
        'service-unavailable',
        'feature-not-implemented',
      ].contains(error.condition)) {
        return null;
      }
      throw OmemoLookupFailed(jid ?? ownJid, error.condition);
    } on TimeoutException {
      throw OmemoLookupFailed(jid ?? ownJid, 'timeout');
    }
    final items = answer.child('pubsub', _pubsub)?.child('items');
    if (items == null) return null;
    for (final item in items.all('item').take(1)) {
      return item.children.firstOrNull;
    }
    return null;
  }

  Future<List<int>> _fetchDeviceList(
    String jid,
    OmemoVersion version, {
    bool own = false,
  }) async {
    final element = await _item(
      own ? null : jid,
      OmemoXml.deviceListNode(version),
    );
    if (element == null) return const [];
    return OmemoXml.parseDeviceList(version, element) ?? const [];
  }

  /// The devices of [jid] that take OMEMO [version], read now or from a
  /// recent lookup. Throws [OmemoLookupFailed] when they cannot be read.
  Future<List<int>> devicesOf(
    String jid,
    OmemoVersion version, {
    bool refresh = false,
  }) async {
    final cached = _devices[jid];
    final known = cached?.get(version);
    if (!refresh &&
        known != null &&
        _now().difference(cached!.readAt(version)!) < deviceListAge) {
      return known;
    }
    final ids = await _fetchDeviceList(jid, version, own: jid == ownJid);
    if (_devices.length >= maxCachedJids && !_devices.containsKey(jid)) {
      _devices.remove(_devices.keys.first);
    }
    (_devices[jid] ??= _Devices(_now())).set(version, ids, _now());
    return ids;
  }

  /// Whether this device already has keys with [jid] (a session in a version
  /// in use, or a verified device). Then "no OMEMO devices" is not believed
  /// when [jid] is asked again: it could be a server hiding them.
  bool hasEstablishedEncryption(String jid) {
    final engine = _engine;
    if (engine == null) return false;
    return engine.hasVerifiedDevice(jid) ||
        versions.any((version) => engine.hasAnySession(version, jid));
  }

  /// The version to use with [jid]: OMEMO 2 when any of their devices
  /// takes it, else legacy when enabled, else null (no OMEMO).
  Future<OmemoVersion?> versionFor(String jid, {bool refresh = false}) async {
    for (final version in versions) {
      final ids = await devicesOf(jid, version, refresh: refresh);
      if (ids.isNotEmpty) return version;
      // An OMEMO 2 list that reads empty while this device already has an
      // OMEMO 2 session with them is a hiding server or a glitch, not a
      // reason to fall back to the older, weaker format.
      if (version == OmemoVersion.v2 &&
          (_engine?.hasAnySession(version, jid) ?? false)) {
        return version;
      }
    }
    return null;
  }

  Future<OmemoBundle?> _fetchBundle(
    String jid,
    int deviceId,
    OmemoVersion version,
  ) async {
    final element = await _item(
      jid == ownJid ? null : jid,
      OmemoXml.bundleNode(version, deviceId),
      itemId: OmemoXml.bundleItemId(version, deviceId),
    );
    if (element == null) return null;
    return OmemoXml.parseBundle(version, element);
  }

  // ---- Encrypting --------------------------------------------------------

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _serial.then((_) => action());
    _serial = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Encrypts [plaintext] for every device of [jid] and this account's own
  /// other devices. Returns the `<encrypted>` element. Throws
  /// [OmemoLookupFailed] or [OmemoNoRecipients].
  Future<XmppElement> encrypt({
    required String jid,
    required OmemoVersion version,
    required List<int> plaintext,
  }) => _locked(() async {
    final engine = _engine ?? (throw StateError('OMEMO is not set up.'));
    final targets = <(String, int)>[];
    final contactDevices = await devicesOf(jid, version, refresh: true);
    for (final id in contactDevices) {
      targets.add((jid, id));
    }
    if (jid != ownJid) {
      for (final id in await devicesOf(ownJid, version, refresh: true)) {
        if (id != engine.deviceId) targets.add((ownJid, id));
      }
    }
    final payload = await engine.encryptPayload(version, plaintext);
    final keys = <OmemoEncryptedKey>[];
    skippedDevices.clear();
    var contactReached = false;
    for (final (target, deviceId) in targets.take(OmemoXml.maxDevices * 2)) {
      try {
        OmemoBundle? bundle;
        if (!engine.hasSession(version, target, deviceId)) {
          bundle = await _fetchBundle(target, deviceId, version);
          if (bundle == null) {
            log?.call('OMEMO: no bundle for $target/$deviceId');
            continue;
          }
        }
        keys.add(
          await engine.encryptKey(
            version: version,
            jid: target,
            deviceId: deviceId,
            keyMaterial: payload.keyMaterial,
            bundle: bundle,
          ),
        );
        if (target == jid) contactReached = true;
      } on OmemoIdentityChanged catch (error) {
        log?.call('OMEMO: $error');
        skippedDevices.add((target, deviceId, 'its keys changed'));
      } on OmemoKeyAgreementException catch (error) {
        log?.call('OMEMO: $error');
        skippedDevices.add((target, deviceId, error.message));
      } on OmemoLookupFailed catch (error) {
        log?.call('OMEMO: $error');
        skippedDevices.add((target, deviceId, error.reason));
      }
    }
    _persist();
    if (!contactReached) throw OmemoNoRecipients(jid);
    return OmemoXml.encrypted(
      version: version,
      senderDevice: engine.deviceId,
      keys: keys,
      payload: payload,
    );
  });

  /// The text to encrypt for [version]: legacy encrypts the body alone,
  /// OMEMO 2 an envelope with [content] and the addresses.
  List<int> plaintextFor({
    required OmemoVersion version,
    required String to,
    required List<XmppElement> content,
    String? body,
  }) {
    if (version == OmemoVersion.legacy) return utf8.encode(body ?? '');
    final random = _random.bytes(2);
    final padLength = (random[0] << 8 | random[1]) % 200;
    final padding = base64
        .encode(_random.bytes((padLength * 3 / 4).ceil()))
        .substring(0, padLength);
    return utf8.encode(
      OmemoXml.envelope(
        content: content,
        to: to,
        from: ownJid,
        at: _now(),
        padding: padding,
      ),
    );
  }

  // ---- Decrypting --------------------------------------------------------

  /// Reads the encrypted part of [message] sent by [sender] (a bare JID);
  /// [chat] is the conversation it belongs to (the other side's address for
  /// a copy of this account's own message). Messages are read one at a
  /// time, in the order they come.
  Future<OmemoReceived?> decrypt({
    required XmppElement encrypted,
    required String sender,
    required String chat,
  }) => _locked(() async {
    final engine = _engine;
    if (engine == null) return null;
    final incoming = OmemoXml.parseEncrypted(
      encrypted,
      ownJid: ownJid,
      ownDevice: engine.deviceId,
    );
    if (incoming == null) return null;
    final version = incoming.version;
    OmemoReceived fail(String reason) => OmemoReceived(
      version: version,
      senderDevice: incoming.senderDevice,
      failure: reason,
    );
    if (version == OmemoVersion.legacy && !legacyEnabled) {
      return fail('legacy OMEMO is off');
    }
    final blob = incoming.key;
    if (blob == null) return fail('not encrypted for this device');
    final payload = incoming.payload;
    try {
      final keyMaterial = await engine.decryptKey(
        version: version,
        sender: sender,
        senderDevice: incoming.senderDevice,
        blob: blob,
        keyExchange: incoming.keyExchange,
      );
      final record = engine.deviceRecord(sender, incoming.senderDevice);
      if (payload == null) {
        // A key transport message: only keys, nothing to show.
        _persist();
        unawaited(_republishAfterUse());
        return OmemoReceived(
          version: version,
          senderDevice: incoming.senderDevice,
          trust: record?.trust,
        );
      }
      final plain = await engine.decryptPayload(
        version,
        payload,
        keyMaterial,
        iv: incoming.iv,
      );
      _persist();
      if (incoming.keyExchange) unawaited(_republishAfterUse());
      final text = utf8.decode(plain, allowMalformed: false);
      if (version == OmemoVersion.legacy) {
        return OmemoReceived(
          version: version,
          senderDevice: incoming.senderDevice,
          body: text,
          trust: record?.trust,
        );
      }
      // The envelope must name the sender and the conversation.
      final envelope = OmemoXml.parseEnvelope(
        text,
        from: sender,
        to: sender == ownJid ? chat : ownJid,
      );
      if (envelope == null) return fail('the envelope does not match');
      return OmemoReceived(
        version: version,
        senderDevice: incoming.senderDevice,
        content: envelope.content,
        at: envelope.at,
        body: envelope.content.where((e) => e.name == 'body').firstOrNull?.text,
        trust: record?.trust,
      );
    } on OmemoIdentityChanged catch (error) {
      log?.call('OMEMO: $error');
      return fail('the keys of this device changed');
    } on OmemoDecryptException catch (error) {
      return fail(error.message);
    } on OmemoKeyAgreementException catch (error) {
      return fail(error.message);
    } on OmemoProtoException catch (error) {
      return fail(error.message);
    } on FormatException {
      return fail('the text is not valid');
    }
  });

  Future<void> _republishAfterUse() async {
    try {
      await refreshBundles();
    } catch (error) {
      log?.call('OMEMO: could not refresh the keys: $error');
    }
  }

  // ---- For the keys screen -----------------------------------------------

  String? get ownFingerprint => _engine?.fingerprint;
  int? get ownDeviceId => _engine?.deviceId;

  /// This device's fingerprint as a link others can scan
  /// (`xmpp:me@example.org?omemo-sid-123=<hex>`).
  String? get ownUri {
    final engine = _engine;
    if (engine == null) return null;
    final hex = engine.identity.montgomery
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    // The fingerprint is the Curve25519 identity key in hex for both
    // versions (python-omemo's documentation: "in its Curve25519 form as per
    // the specification"). Clients differ in the parameter name they scan.
    final id = engine.deviceId;
    return 'xmpp:$ownJid?omemo-sid-$id=$hex;omemo2-sid-$id=$hex';
  }

  /// The devices of [jid] known from lookups and sessions.
  List<OmemoDeviceInfo> knownDevices(String jid) {
    final engine = _engine;
    if (engine == null) return const [];
    final lists = _devices[jid];
    final ids = <int>{
      ...engine.devicesOf(jid).map((entry) => entry.key),
      for (final version in OmemoVersion.values) ...?lists?.get(version),
    };
    final out = <OmemoDeviceInfo>[];
    for (final id in ids.take(OmemoXml.maxDevices)) {
      final record = engine.deviceRecord(jid, id);
      out.add(
        OmemoDeviceInfo(
          id: id,
          fingerprint: record?.fingerprint ?? '',
          trust: record?.trust ?? OmemoTrust.blind,
          versions: {
            for (final version in OmemoVersion.values)
              if (lists?.get(version)?.contains(id) ?? false) version,
          },
          changed: _changed.contains('$jid|$id'),
        ),
      );
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  final Set<String> _changed = {};

  /// Reads the contact's device lists and the keys of every device, so
  /// fingerprints can be compared before the first message.
  Future<List<OmemoDeviceInfo>> refreshDevices(String jid) => _locked(() async {
    final engine = _engine;
    if (engine == null) return const <OmemoDeviceInfo>[];
    for (final version in versions) {
      final ids = await devicesOf(jid, version, refresh: true);
      for (final id in ids.take(OmemoXml.maxDevices)) {
        if (jid == ownJid && id == engine.deviceId) continue;
        try {
          final bundle = await _fetchBundle(jid, id, version);
          if (bundle == null) continue;
          engine.noteDevice(jid, id, bundle.identityMontgomery);
          _changed.remove('$jid|$id');
        } on OmemoIdentityChanged {
          _changed.add('$jid|$id');
        } on OmemoLookupFailed catch (error) {
          log?.call('OMEMO: $error');
        }
      }
    }
    _persist();
    return knownDevices(jid);
  });

  void setTrust(String jid, int deviceId, OmemoTrust trust) {
    _engine?.setTrust(jid, deviceId, trust);
    _persist();
  }

  /// Forgets a device's remembered key and its sessions.
  void forgetDevice(String jid, int deviceId) {
    _engine?.forgetDevice(jid, deviceId);
    _changed.remove('$jid|$deviceId');
    _persist();
  }

  /// Reads a scanned `xmpp:` link of [jid]'s fingerprints: matching devices
  /// become verified. Fingerprints that differ are counted, never trusted.
  OmemoScanResult verifyFromUri(String jid, String text) {
    final engine = _engine;
    final value = text.trim();
    if (engine == null || !value.toLowerCase().startsWith('xmpp:')) {
      return const OmemoScanResult(verified: 0, mismatched: 0);
    }
    final question = value.indexOf('?');
    if (question < 0) return const OmemoScanResult(verified: 0, mismatched: 0);
    final address = bareJid(Uri.decodeComponent(value.substring(5, question)));
    if (address != jid) {
      return const OmemoScanResult(verified: 0, mismatched: 1);
    }
    var verified = 0;
    var mismatched = 0;
    final seen = <int>{};
    for (final part
        in value
            .substring(question + 1)
            .split(RegExp('[;&]'))
            .take(OmemoXml.maxDevices)) {
      final match = RegExp(
        r'^omemo2?-sid-(\d{1,10})=([0-9a-fA-F]{64})$',
      ).firstMatch(part);
      if (match == null) continue;
      final id = int.parse(match.group(1)!);
      // The same device may be named twice (omemo- and omemo2-).
      if (!seen.add(id)) continue;
      final record = engine.deviceRecord(jid, id);
      if (record == null) {
        mismatched++;
        continue;
      }
      final hex = record.identity
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      if (hex == match.group(2)!.toLowerCase()) {
        record.trust = OmemoTrust.verified;
        verified++;
      } else {
        mismatched++;
      }
    }
    _persist();
    return OmemoScanResult(verified: verified, mismatched: mismatched);
  }

  /// Drops cached device lists, so the next send reads them again.
  void forgetLookups() => _devices.clear();
}

class _Devices {
  _Devices(this.created);
  final DateTime created;
  final Map<OmemoVersion, List<int>> _lists = {};
  final Map<OmemoVersion, DateTime> _times = {};

  List<int>? get(OmemoVersion version) => _lists[version];
  DateTime? readAt(OmemoVersion version) => _times[version];
  void set(OmemoVersion version, List<int> ids, DateTime at) {
    _lists[version] = ids;
    _times[version] = at;
  }
}

/// Merges the elements that were inside an encryption into [message],
/// replacing its body (the fallback text) and dropping the encrypted part.
XmppElement omemoDecryptedMessage(XmppElement message, OmemoReceived received) {
  final merged = XmppElement(
    message.name,
    xmlns: message.xmlns,
    attributes: Map.of(message.attributes),
  );
  for (final child in message.children) {
    final isEncrypted =
        child.name == 'encrypted' &&
        OmemoVersion.byNamespace(child.xmlns) != null;
    final isFallback =
        child.name == 'body' ||
        (child.name == 'encryption' && child.xmlns == OmemoXml.eme);
    // With OMEMO 2 the elements that change earlier messages must come from
    // inside the encryption; the same elements outside could be added by a
    // server.
    final isOuterEdit =
        received.content != null &&
        const {'replace', 'retract', 'reactions', 'reply'}.contains(child.name);
    if (isEncrypted || isFallback || isOuterEdit) continue;
    merged.add(child);
  }
  final content = received.content;
  if (content != null) {
    for (final child in content) {
      // Only elements that carry meaning inside a conversation; anything
      // else could make the message look like another kind.
      if (const {
        'body',
        'reply',
        'replace',
        'reactions',
        'retract',
        'origin-id',
      }.contains(child.name)) {
        merged.add(
          XmppElement(
            child.name,
            xmlns: child.xmlns == XmppNs.client ? null : child.xmlns,
            attributes: child.attributes,
            children: child.children,
            text: child.text,
          ),
        );
      }
    }
  } else if (received.body != null) {
    merged.add(XmppElement('body', text: received.body!));
  }
  return merged;
}

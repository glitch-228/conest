import 'dart:convert';
import 'dart:typed_data';

import 'omemo_crypto.dart';
import 'omemo_proto.dart';
import 'omemo_random.dart';
import 'omemo_suite.dart';

/// A message that cannot be decrypted (bad MAC, replay, too far ahead).
class OmemoDecryptException implements Exception {
  const OmemoDecryptException(this.message);
  final String message;
  @override
  String toString() => 'OMEMO decryption failed: $message';
}

class OmemoRatchetChain {
  OmemoRatchetChain(this.key, this.length);
  Uint8List key;
  int length;

  OmemoRatchetChain copy() =>
      OmemoRatchetChain(Uint8List.fromList(key), length);

  Map<String, Object?> toJson() => {'k': base64.encode(key), 'n': length};

  static OmemoRatchetChain fromJson(Object? json) {
    final map = json as Map;
    final key = base64.decode(map['k'] as String);
    if (key.length != 32) throw const FormatException('bad chain key');
    return OmemoRatchetChain(Uint8List.fromList(key), map['n'] as int);
  }
}

/// The Double Ratchet of Signal as OMEMO uses it, in either version.
class OmemoRatchet {
  OmemoRatchet._({
    required this.suite,
    required this.rootKey,
    required this.ownPriv,
    required this.otherPub,
    required this.sending,
    required this.receiving,
    required this.previousSending,
    required this.skipped,
  });

  final OmemoSuite suite;
  Uint8List rootKey;
  Uint8List ownPriv;
  Uint8List otherPub;
  OmemoRatchetChain? sending;
  OmemoRatchetChain? receiving;
  int? previousSending;

  /// Message keys of messages that arrived out of order, oldest first, keyed
  /// by "ratchet public key hex:counter".
  final Map<String, Uint8List> skipped;

  /// Most message keys kept for one session.
  static const int maxSkipped = 1000;

  /// Most message keys derived at once for one incoming message.
  static const int maxSkipPerMessage = 1000;

  int get sendingLength => sending?.length ?? 0;
  int? get receivingLength => receiving?.length;

  /// The initiator's ratchet: the first sending chain from the responder's
  /// signed pre key.
  static Future<OmemoRatchet> initiate(
    OmemoSuite suite,
    Uint8List sharedSecret,
    Uint8List recipientRatchetPub,
    OmemoRandom random,
  ) async {
    final ratchet = OmemoRatchet._(
      suite: suite,
      rootKey: sharedSecret,
      ownPriv: random.bytes(32),
      otherPub: recipientRatchetPub,
      sending: null,
      receiving: null,
      previousSending: null,
      skipped: {},
    );
    await ratchet._replaceChain(sendingSide: true);
    return ratchet;
  }

  /// The responder's ratchet, started by the initiator's first message.
  static Future<OmemoRatchet> respond(
    OmemoSuite suite,
    Uint8List sharedSecret,
    Uint8List ownSignedPreKeyPriv,
    Uint8List initiatorRatchetPub,
    OmemoRandom random,
  ) async {
    final ratchet = OmemoRatchet._(
      suite: suite,
      rootKey: sharedSecret,
      ownPriv: ownSignedPreKeyPriv,
      otherPub: initiatorRatchetPub,
      sending: null,
      receiving: null,
      previousSending: null,
      skipped: {},
    );
    await ratchet._replaceChain(sendingSide: false);
    ratchet.ownPriv = random.bytes(32);
    await ratchet._replaceChain(sendingSide: true);
    return ratchet;
  }

  Future<void> _replaceChain({required bool sendingSide}) async {
    final shared = await OmemoCrypto.x25519(ownPriv, otherPub);
    final out = await OmemoCrypto.hkdf(
      shared,
      salt: rootKey,
      info: suite.rootInfo,
      length: 64,
    );
    rootKey = Uint8List.fromList(out.sublist(0, 32));
    final chain = OmemoRatchetChain(Uint8List.fromList(out.sublist(32)), 0);
    if (sendingSide) {
      previousSending = sending?.length;
      sending = chain;
    } else {
      receiving = chain;
    }
  }

  Future<Uint8List> _step(OmemoRatchetChain chain) async {
    // Messages keys are HMAC(chain key, 0x01), the next chain key
    // HMAC(chain key, 0x02), as libsignal derives them.
    final next = await OmemoCrypto.hmacSha256(chain.key, const [0x02]);
    final messageKey = await OmemoCrypto.hmacSha256(chain.key, const [0x01]);
    chain.key = next;
    chain.length++;
    return messageKey;
  }

  /// Encrypts [plain] (key material) for the other side; [ad] is the
  /// session's associated data in the sender-first order.
  Future<Uint8List> encrypt(Uint8List plain, Uint8List ad) async {
    final chain = sending;
    if (chain == null) throw StateError('No sending chain.');
    final counter = chain.length;
    final previous = previousSending ?? 0;
    final ownPub = await OmemoCrypto.x25519Public(ownPriv);
    final messageKey = await _step(chain);
    return _seal(suite, messageKey, ad, ownPub, counter, previous, plain);
  }

  /// Decrypts [sealed]. Changes this ratchet only when it succeeds.
  Future<Uint8List> decrypt(
    Uint8List sealed,
    Uint8List ad,
    OmemoRandom random,
  ) async {
    final (messageBytes, _) = _openOrThrow(suite, sealed);
    final (pub, counter, previous, _) = _parseOrThrow(suite, messageBytes);

    final skippedKey = '${_hex(pub)}:$counter';
    final stored = skipped[skippedKey];
    if (stored != null) {
      final plain = await _open(suite, stored, ad, sealed);
      skipped.remove(skippedKey);
      return plain;
    }

    final work = _copy();
    final newSkipped = <String, Uint8List>{};
    final messageKey = await work._nextKey(
      pub,
      counter,
      previous,
      newSkipped,
      random,
    );
    final plain = await _open(suite, messageKey, ad, sealed);

    rootKey = work.rootKey;
    ownPriv = work.ownPriv;
    otherPub = work.otherPub;
    sending = work.sending;
    receiving = work.receiving;
    previousSending = work.previousSending;
    skipped.addAll(newSkipped);
    while (skipped.length > maxSkipped) {
      skipped.remove(skipped.keys.first);
    }
    return plain;
  }

  OmemoRatchet _copy() => OmemoRatchet._(
    suite: suite,
    rootKey: Uint8List.fromList(rootKey),
    ownPriv: Uint8List.fromList(ownPriv),
    otherPub: Uint8List.fromList(otherPub),
    sending: sending?.copy(),
    receiving: receiving?.copy(),
    previousSending: previousSending,
    skipped: {},
  );

  Future<Uint8List> _nextKey(
    Uint8List pub,
    int counter,
    int previous,
    Map<String, Uint8List> newSkipped,
    OmemoRandom random,
  ) async {
    if (!_equal(pub, otherPub)) {
      final current = receiving;
      if (current != null) {
        final missing = previous - current.length;
        if (missing > 0 && missing <= maxSkipPerMessage) {
          for (var index = 0; index < missing; index++) {
            final at = current.length;
            newSkipped['${_hex(otherPub)}:$at'] = await _step(current);
          }
        }
      }
      otherPub = pub;
      await _replaceChain(sendingSide: false);
      ownPriv = random.bytes(32);
      await _replaceChain(sendingSide: true);
    }
    final chain = receiving!;
    final missing = counter - chain.length;
    if (missing > maxSkipPerMessage) {
      throw const OmemoDecryptException('too many messages skipped');
    }
    for (var index = 0; index < missing; index++) {
      final at = chain.length;
      newSkipped['${_hex(otherPub)}:$at'] = await _step(chain);
    }
    if (counter < chain.length) {
      throw const OmemoDecryptException('message already received');
    }
    return _step(chain);
  }

  Map<String, Object?> toJson() => {
    'root': base64.encode(rootKey),
    'priv': base64.encode(ownPriv),
    'other': base64.encode(otherPub),
    'send': sending?.toJson(),
    'recv': receiving?.toJson(),
    'prev': previousSending,
    'skipped': {
      for (final entry in skipped.entries)
        entry.key: base64.encode(entry.value),
    },
  };

  static OmemoRatchet fromJson(OmemoSuite suite, Object? json) {
    final map = json as Map;
    final skipped = <String, Uint8List>{};
    final stored = map['skipped'];
    if (stored is Map) {
      for (final entry in stored.entries) {
        if (skipped.length >= maxSkipped) break;
        skipped[entry.key as String] = Uint8List.fromList(
          base64.decode(entry.value as String),
        );
      }
    }
    Uint8List key(String name) {
      final bytes = base64.decode(map[name] as String);
      if (bytes.length != 32) throw FormatException('bad $name');
      return Uint8List.fromList(bytes);
    }

    final sendJson = map['send'];
    if (sendJson == null) throw const FormatException('no sending chain');
    return OmemoRatchet._(
      suite: suite,
      rootKey: key('root'),
      ownPriv: key('priv'),
      otherPub: key('other'),
      sending: OmemoRatchetChain.fromJson(sendJson),
      receiving: map['recv'] == null
          ? null
          : OmemoRatchetChain.fromJson(map['recv']),
      previousSending: map['prev'] as int?,
      skipped: skipped,
    );
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

bool _equal(List<int> a, List<int> b) => OmemoCrypto.constantTimeEquals(a, b);

(Uint8List, Uint8List) _openOrThrow(OmemoSuite suite, Uint8List sealed) {
  try {
    return suite.openSealed(sealed);
  } on OmemoProtoException catch (error) {
    throw OmemoDecryptException(error.message);
  }
}

(Uint8List, int, int, Uint8List) _parseOrThrow(
  OmemoSuite suite,
  Uint8List messageBytes,
) {
  try {
    return suite.parseMessage(messageBytes);
  } on OmemoProtoException catch (error) {
    throw OmemoDecryptException(error.message);
  }
}

/// The parsed header of a sealed message, without touching any state.
OmemoRatchetMessage parseOmemoRatchetMessage(
  OmemoSuite suite,
  Uint8List sealed,
) {
  final (messageBytes, _) = _openOrThrow(suite, sealed);
  final (pub, counter, previous, _) = _parseOrThrow(suite, messageBytes);
  return OmemoRatchetMessage(
    ratchetPub: pub,
    counter: counter,
    previousCounter: previous,
    sealed: sealed,
  );
}

Future<(Uint8List, Uint8List, Uint8List)> _derive(
  OmemoSuite suite,
  Uint8List messageKey,
) async {
  final out = await OmemoCrypto.hkdf(
    messageKey,
    salt: Uint8List(32),
    info: suite.messageKeyInfo,
    length: 80,
  );
  return (
    Uint8List.sublistView(out, 0, 32),
    Uint8List.sublistView(out, 32, 64),
    Uint8List.sublistView(out, 64),
  );
}

Future<Uint8List> _seal(
  OmemoSuite suite,
  Uint8List messageKey,
  Uint8List ad,
  Uint8List ratchetPub,
  int counter,
  int previous,
  Uint8List plain,
) async {
  final (encryptionKey, authenticationKey, iv) = await _derive(
    suite,
    messageKey,
  );
  final cipher = await OmemoCrypto.aesCbcEncrypt(encryptionKey, iv, plain);
  final message = suite.encodeMessage(ratchetPub, counter, previous, cipher);
  final mac = await OmemoCrypto.hmacSha256(authenticationKey, [
    ...ad,
    ...message,
  ]);
  return suite.sealMessage(
    message,
    Uint8List.sublistView(mac, 0, suite.macLength),
  );
}

Future<Uint8List> _open(
  OmemoSuite suite,
  Uint8List messageKey,
  Uint8List ad,
  Uint8List sealed,
) async {
  final (decryptionKey, authenticationKey, iv) = await _derive(
    suite,
    messageKey,
  );
  final (messageBytes, mac) = _openOrThrow(suite, sealed);
  final expected = await OmemoCrypto.hmacSha256(authenticationKey, [
    ...ad,
    ...messageBytes,
  ]);
  if (!OmemoCrypto.constantTimeEquals(
    Uint8List.sublistView(expected, 0, suite.macLength),
    mac,
  )) {
    throw const OmemoDecryptException('authentication failed');
  }
  final (_, _, _, cipher) = _parseOrThrow(suite, messageBytes);
  try {
    return await OmemoCrypto.aesCbcDecrypt(decryptionKey, iv, cipher);
  } catch (_) {
    throw const OmemoDecryptException('bad padding');
  }
}

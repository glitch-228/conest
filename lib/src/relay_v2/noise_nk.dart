import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../bitchat/noise.dart' show NoiseCipherState;

/// The handshake relay v2 sessions run against the relay's static key.
const String relayV2NoiseProtocol = 'Noise_NK_25519_ChaChaPoly_SHA256';

/// Bound into every handshake, so a session key cannot be lifted into
/// another protocol.
final List<int> relayV2Prologue = utf8.encode('conest-relay-v2');

const int _keyBytes = 32;
const int _tagBytes = 16;

final _x25519 = X25519();
final _sha256 = Sha256();
final _hmac = Hmac.sha256();

Future<Uint8List> _mac(List<int> key, List<int> data) async =>
    Uint8List.fromList(
      (await _hmac.calculateMac(data, secretKey: SecretKey(key))).bytes,
    );

/// Noise's HKDF with two outputs.
Future<(Uint8List, Uint8List)> _hkdf2(
  List<int> chainingKey,
  List<int> input,
) async {
  final temp = await _mac(chainingKey, input);
  final first = await _mac(temp, [1]);
  final second = await _mac(temp, [...first, 2]);
  return (first, second);
}

class _Symmetric {
  Uint8List h = Uint8List(32);
  Uint8List ck = Uint8List(32);
  NoiseCipherState cipher = NoiseCipherState();

  void initialize() {
    final name = utf8.encode(relayV2NoiseProtocol);
    // Exactly 32 bytes: used as is.
    h = Uint8List(32)..setRange(0, name.length, name);
    ck = Uint8List.fromList(h);
  }

  Future<void> mixHash(List<int> data) async {
    h = Uint8List.fromList((await _sha256.hash([...h, ...data])).bytes);
  }

  Future<void> mixKey(List<int> input) async {
    final (nextCk, key) = await _hkdf2(ck, input);
    ck = nextCk;
    cipher = NoiseCipherState(key);
  }

  Future<Uint8List> encryptAndHash(List<int> plaintext) async {
    final ciphertext = await cipher.encryptWithAd(h, plaintext);
    await mixHash(ciphertext);
    return ciphertext;
  }

  Future<Uint8List> decryptAndHash(List<int> ciphertext) async {
    final plaintext = await cipher.decryptWithAd(h, ciphertext);
    await mixHash(ciphertext);
    return plaintext;
  }

  Future<(NoiseCipherState, NoiseCipherState)> split() async {
    final (first, second) = await _hkdf2(ck, const []);
    return (NoiseCipherState(first), NoiseCipherState(second));
  }
}

Future<Uint8List> _dh(SimpleKeyPair local, List<int> remote) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: local,
    remotePublicKey: SimplePublicKey(remote, type: KeyPairType.x25519),
  );
  final bytes = Uint8List.fromList(await shared.extractBytes());
  if (bytes.every((byte) => byte == 0)) {
    throw const FormatException('Weak Noise public key.');
  }
  return bytes;
}

/// The keys a finished handshake leaves: one cipher each way.
class NoiseNkTransport {
  NoiseNkTransport({
    required this.send,
    required this.receive,
    required this.handshakeHash,
  });

  final NoiseCipherState send;
  final NoiseCipherState receive;

  /// Unique to this session; what a mailbox owner signs to prove itself on
  /// it.
  final Uint8List handshakeHash;
}

/// The client's side of `Noise_NK`: `-> e, es` then `<- e, ee`.
class NoiseNkInitiator {
  NoiseNkInitiator._(this._relayStatic, this._ephemeralSeed);

  /// Starts a handshake against [relayStaticPublic] (32 bytes).
  /// [ephemeralSeed] is for test vectors only.
  static Future<NoiseNkInitiator> start({
    required List<int> relayStaticPublic,
    List<int>? ephemeralSeed,
  }) async {
    if (relayStaticPublic.length != _keyBytes) {
      throw const FormatException('Relay session key must be 32 bytes.');
    }
    final handshake = NoiseNkInitiator._(
      Uint8List.fromList(relayStaticPublic),
      ephemeralSeed,
    );
    handshake._symmetric.initialize();
    await handshake._symmetric.mixHash(relayV2Prologue);
    await handshake._symmetric.mixHash(relayStaticPublic);
    return handshake;
  }

  final Uint8List _relayStatic;
  final List<int>? _ephemeralSeed;
  final _Symmetric _symmetric = _Symmetric();
  SimpleKeyPair? _ephemeral;
  int _step = 0;

  Uint8List get handshakeHash => Uint8List.fromList(_symmetric.h);

  /// The first message, carrying [payload] (encrypted to the relay).
  Future<Uint8List> writeMessage1(List<int> payload) async {
    if (_step != 0) throw StateError('Message 1 was written already.');
    final seed = _ephemeralSeed;
    final ephemeral = seed != null
        ? await _x25519.newKeyPairFromSeed(seed)
        : await _x25519.newKeyPair();
    _ephemeral = ephemeral;
    final e = (await ephemeral.extractPublicKey()).bytes;
    await _symmetric.mixHash(e);
    await _symmetric.mixKey(await _dh(ephemeral, _relayStatic));
    final ciphertext = await _symmetric.encryptAndHash(payload);
    _step = 1;
    return Uint8List.fromList([...e, ...ciphertext]);
  }

  /// Reads the relay's reply; returns its payload and the session's keys.
  /// Fails when the reply was not made with the relay's static key.
  Future<(Uint8List, NoiseNkTransport)> readMessage2(List<int> message) async {
    if (_step != 1) throw StateError('Message 1 comes first.');
    if (message.length < _keyBytes + _tagBytes) {
      throw const FormatException('Noise message 2 is too short.');
    }
    final re = message.sublist(0, _keyBytes);
    await _symmetric.mixHash(re);
    await _symmetric.mixKey(await _dh(_ephemeral!, re));
    final payload = await _symmetric.decryptAndHash(message.sublist(_keyBytes));
    _step = 2;
    final (first, second) = await _symmetric.split();
    return (
      payload,
      NoiseNkTransport(
        send: first,
        receive: second,
        handshakeHash: handshakeHash,
      ),
    );
  }
}

/// The relay's side (the in-app relay and tests).
class NoiseNkResponder {
  NoiseNkResponder._(this._static, this._ephemeralSeed);

  static Future<NoiseNkResponder> start({
    required SimpleKeyPair staticKeyPair,
    List<int>? ephemeralSeed,
  }) async {
    final responder = NoiseNkResponder._(staticKeyPair, ephemeralSeed);
    responder._symmetric.initialize();
    await responder._symmetric.mixHash(relayV2Prologue);
    await responder._symmetric.mixHash(
      (await staticKeyPair.extractPublicKey()).bytes,
    );
    return responder;
  }

  final SimpleKeyPair _static;
  final List<int>? _ephemeralSeed;
  final _Symmetric _symmetric = _Symmetric();
  Uint8List? _remoteEphemeral;
  int _step = 0;

  Uint8List get handshakeHash => Uint8List.fromList(_symmetric.h);

  /// Reads the client's first message; returns its payload.
  Future<Uint8List> readMessage1(List<int> message) async {
    if (_step != 0) throw StateError('Message 1 was read already.');
    if (message.length < _keyBytes + _tagBytes) {
      throw const FormatException('Noise message 1 is too short.');
    }
    final re = Uint8List.fromList(message.sublist(0, _keyBytes));
    _remoteEphemeral = re;
    await _symmetric.mixHash(re);
    await _symmetric.mixKey(await _dh(_static, re));
    final payload = await _symmetric.decryptAndHash(message.sublist(_keyBytes));
    _step = 1;
    return payload;
  }

  /// The reply carrying [payload], and the session's keys.
  Future<(Uint8List, NoiseNkTransport)> writeMessage2(List<int> payload) async {
    if (_step != 1) throw StateError('Message 1 comes first.');
    final seed = _ephemeralSeed;
    final ephemeral = seed != null
        ? await _x25519.newKeyPairFromSeed(seed)
        : await _x25519.newKeyPair();
    final e = (await ephemeral.extractPublicKey()).bytes;
    await _symmetric.mixHash(e);
    await _symmetric.mixKey(await _dh(ephemeral, _remoteEphemeral!));
    final ciphertext = await _symmetric.encryptAndHash(payload);
    _step = 2;
    final (first, second) = await _symmetric.split();
    return (
      Uint8List.fromList([...e, ...ciphertext]),
      NoiseNkTransport(
        send: second,
        receive: first,
        handshakeHash: handshakeHash,
      ),
    );
  }
}

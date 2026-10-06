import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The Noise protocol bitchat uses between two peers.
const String bitchatNoiseProtocol = 'Noise_XX_25519_ChaChaPoly_SHA256';

const int _keyBytes = 32;
const int _tagBytes = 16;

final _chacha = Chacha20.poly1305Aead();
final _x25519 = X25519();
final _sha256 = Sha256();
final _hmac = Hmac.sha256();

/// Noise's HKDF: HMAC-SHA256 with [chainingKey], two or three outputs.
Future<List<Uint8List>> _hkdf(
  List<int> chainingKey,
  List<int> input,
  int outputs,
) async {
  Future<Uint8List> mac(List<int> key, List<int> data) async =>
      Uint8List.fromList(
        (await _hmac.calculateMac(data, secretKey: SecretKey(key))).bytes,
      );
  final temp = await mac(chainingKey, input);
  final first = await mac(temp, [1]);
  final second = await mac(temp, [...first, 2]);
  if (outputs == 2) return [first, second];
  return [
    first,
    second,
    await mac(temp, [...second, 3]),
  ];
}

/// A Noise CipherState: a key and a 64-bit nonce counter.
class NoiseCipherState {
  NoiseCipherState([this._key]);

  Uint8List? _key;
  int nonce = 0;

  bool get hasKey => _key != null;

  static List<int> _nonceBytes(int value) {
    final nonce = ByteData(12)..setUint64(4, value, Endian.little);
    return nonce.buffer.asUint8List();
  }

  Future<Uint8List> encryptWithAd(List<int> ad, List<int> plaintext) async {
    final key = _key;
    if (key == null) return Uint8List.fromList(plaintext);
    final box = await _chacha.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: _nonceBytes(nonce),
      aad: ad,
    );
    nonce++;
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  Future<Uint8List> decryptWithAd(List<int> ad, List<int> ciphertext) async {
    final key = _key;
    if (key == null) return Uint8List.fromList(ciphertext);
    if (ciphertext.length < _tagBytes) {
      throw const FormatException('Noise message too short.');
    }
    final split = ciphertext.length - _tagBytes;
    try {
      final plaintext = await _chacha.decrypt(
        SecretBox(
          ciphertext.sublist(0, split),
          nonce: _nonceBytes(nonce),
          mac: Mac(ciphertext.sublist(split)),
        ),
        secretKey: SecretKey(key),
        aad: ad,
      );
      nonce++;
      return Uint8List.fromList(plaintext);
    } on SecretBoxAuthenticationError {
      throw const FormatException('Noise message failed authentication.');
    }
  }

  /// Encrypts with an explicit [nonce] (bitchat's transport framing, which
  /// carries the nonce and tolerates reordering).
  Future<Uint8List> encryptAt(int nonce, List<int> plaintext) async {
    this.nonce = nonce;
    return encryptWithAd(const [], plaintext);
  }

  Future<Uint8List> decryptAt(int nonce, List<int> ciphertext) async {
    this.nonce = nonce;
    return decryptWithAd(const [], ciphertext);
  }
}

class _SymmetricState {
  Uint8List _h = Uint8List(32);
  Uint8List _ck = Uint8List(32);
  final cipher = NoiseCipherState();

  /// A name of up to 32 bytes is used as is (zero-padded), a longer one
  /// hashed.
  Future<void> initialize(String protocolName) async {
    final name = utf8.encode(protocolName);
    _h = name.length <= 32
        ? (Uint8List(32)..setRange(0, name.length, name))
        : Uint8List.fromList((await _sha256.hash(name)).bytes);
    _ck = Uint8List.fromList(_h);
  }

  Future<void> mixHash(List<int> data) async {
    _h = Uint8List.fromList((await _sha256.hash([..._h, ...data])).bytes);
  }

  Future<void> mixKey(List<int> input) async {
    final outputs = await _hkdf(_ck, input, 2);
    _ck = outputs[0];
    cipher
      .._key = outputs[1]
      ..nonce = 0;
  }

  Future<Uint8List> encryptAndHash(List<int> plaintext) async {
    final ciphertext = await cipher.encryptWithAd(_h, plaintext);
    await mixHash(ciphertext);
    return ciphertext;
  }

  Future<Uint8List> decryptAndHash(List<int> ciphertext) async {
    final plaintext = await cipher.decryptWithAd(_h, ciphertext);
    await mixHash(ciphertext);
    return plaintext;
  }

  Future<(NoiseCipherState, NoiseCipherState)> split() async {
    final outputs = await _hkdf(_ck, const [], 2);
    return (NoiseCipherState(outputs[0]), NoiseCipherState(outputs[1]));
  }
}

/// A Noise XX handshake (25519, ChaChaPoly, SHA-256) for one side.
///
/// Messages: initiator → `e`; responder → `e, ee, s, es`; initiator →
/// `s, se`. After the third, [sendCipher] and [receiveCipher] are ready
/// and [remoteStaticKey] holds the peer's authenticated static key.
class NoiseXXHandshake {
  NoiseXXHandshake._(
    this.initiator,
    this._static,
    this._staticPublic,
    this._ephemeralSeed,
  ) : _symmetric = _SymmetricState();

  /// Starts a handshake with [staticSeed] as this side's static private
  /// key. [ephemeralSeed] is only for test vectors.
  static Future<NoiseXXHandshake> start({
    required bool initiator,
    required List<int> staticSeed,
    List<int> prologue = const [],
    List<int>? ephemeralSeed,
  }) async {
    final staticKey = await _x25519.newKeyPairFromSeed(staticSeed);
    final handshake = NoiseXXHandshake._(
      initiator,
      staticKey,
      Uint8List.fromList((await staticKey.extractPublicKey()).bytes),
      ephemeralSeed,
    );
    await handshake._symmetric.initialize(bitchatNoiseProtocol);
    await handshake._symmetric.mixHash(prologue);
    return handshake;
  }

  final bool initiator;
  final SimpleKeyPair _static;
  final Uint8List _staticPublic;
  final List<int>? _ephemeralSeed;
  final _SymmetricState _symmetric;
  SimpleKeyPair? _ephemeral;
  Uint8List? _remoteEphemeral;
  Uint8List? _remoteStatic;
  int _step = 0;
  NoiseCipherState? _send;
  NoiseCipherState? _receive;

  Uint8List get localStaticKey => _staticPublic;
  Uint8List? get remoteStaticKey => _remoteStatic;
  bool get complete => _send != null;
  NoiseCipherState? get sendCipher => _send;
  NoiseCipherState? get receiveCipher => _receive;

  /// The handshake hash, binding both sides' view of the handshake.
  Uint8List get handshakeHash => Uint8List.fromList(_symmetric._h);

  /// Whether this side writes the next handshake message.
  bool get writesNext => !complete && (_step.isEven == initiator);

  Future<Uint8List> _dh(SimpleKeyPair local, List<int> remote) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: local,
      remotePublicKey: SimplePublicKey(remote, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  Future<Uint8List> _newEphemeral() async {
    final seed = _ephemeralSeed;
    final pair = seed != null
        ? await _x25519.newKeyPairFromSeed(seed)
        : await _x25519.newKeyPair();
    _ephemeral = pair;
    return Uint8List.fromList((await pair.extractPublicKey()).bytes);
  }

  /// Writes the next handshake message carrying [payload].
  Future<Uint8List> writeMessage([List<int> payload = const []]) async {
    if (!writesNext) throw StateError('Not this side\'s turn.');
    final out = BytesBuilder(copy: false);
    switch (_step) {
      case 0:
        final e = await _newEphemeral();
        out.add(e);
        await _symmetric.mixHash(e);
      case 1:
        final e = await _newEphemeral();
        out.add(e);
        await _symmetric.mixHash(e);
        await _symmetric.mixKey(await _dh(_ephemeral!, _remoteEphemeral!));
        out.add(await _symmetric.encryptAndHash(_staticPublic));
        await _symmetric.mixKey(await _dh(_static, _remoteEphemeral!));
      case 2:
        out.add(await _symmetric.encryptAndHash(_staticPublic));
        await _symmetric.mixKey(await _dh(_static, _remoteEphemeral!));
    }
    out.add(await _symmetric.encryptAndHash(payload));
    await _advance();
    return out.takeBytes();
  }

  /// Reads the peer's next handshake message; returns its payload.
  Future<Uint8List> readMessage(List<int> message) async {
    if (complete || writesNext) throw StateError('Not the peer\'s turn.');
    var offset = 0;
    List<int> take(int count) {
      if (offset + count > message.length) {
        throw const FormatException('Noise handshake message too short.');
      }
      final part = message.sublist(offset, offset + count);
      offset += count;
      return part;
    }

    switch (_step) {
      case 0:
        _remoteEphemeral = Uint8List.fromList(take(_keyBytes));
        await _symmetric.mixHash(_remoteEphemeral!);
      case 1:
        _remoteEphemeral = Uint8List.fromList(take(_keyBytes));
        await _symmetric.mixHash(_remoteEphemeral!);
        await _symmetric.mixKey(await _dh(_ephemeral!, _remoteEphemeral!));
        _remoteStatic = await _symmetric.decryptAndHash(
          take(_keyBytes + _tagBytes),
        );
        await _symmetric.mixKey(await _dh(_ephemeral!, _remoteStatic!));
      case 2:
        _remoteStatic = await _symmetric.decryptAndHash(
          take(_keyBytes + _tagBytes),
        );
        await _symmetric.mixKey(await _dh(_ephemeral!, _remoteStatic!));
    }
    final payload = await _symmetric.decryptAndHash(message.sublist(offset));
    await _advance();
    return payload;
  }

  Future<void> _advance() async {
    _step++;
    if (_step < 3) return;
    final (first, second) = await _symmetric.split();
    // The initiator sends with the first key, the responder with the second.
    _send = initiator ? first : second;
    _receive = initiator ? second : first;
  }
}

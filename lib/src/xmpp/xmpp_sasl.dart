import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'xmpp_registration.dart' show serverText;

/// SASL mechanisms Conest offers, best first. PLAIN only ever goes over
/// TLS (the session refuses it otherwise).
const List<String> xmppSaslPreference = [
  'SCRAM-SHA-256',
  'SCRAM-SHA-1',
  'PLAIN',
];

/// The mechanism to use from what the server offers, or null when none of
/// ours is offered (or only PLAIN without TLS).
String? chooseSaslMechanism(Iterable<String> offered, {required bool secure}) {
  final set = {for (final name in offered) name.toUpperCase()};
  for (final name in xmppSaslPreference) {
    if (name == 'PLAIN' && !secure) continue;
    if (set.contains(name)) return name;
  }
  return null;
}

/// The server's SASL answer could not be checked: wrong password, a forged
/// server signature, or a malformed message.
class XmppSaslException implements Exception {
  const XmppSaslException(this.message);
  final String message;
  @override
  String toString() => 'Sign-in failed: ${serverText(message, 64)}';
}

/// The initial response for PLAIN: `\0user\0password`.
Uint8List plainInitialResponse(String username, String password) =>
    Uint8List.fromList(utf8.encode('\u0000$username\u0000$password'));

/// SCRAM (RFC 5802 / RFC 7677) without channel binding, for SHA-1 and
/// SHA-256. The server's final signature is checked, so a server that does
/// not know the password cannot pretend sign-in worked.
class ScramClient {
  ScramClient({
    required this.mechanism,
    required this.username,
    required this.password,
    String? clientNonce,
  }) : _hash = switch (mechanism) {
         'SCRAM-SHA-1' => sha1,
         'SCRAM-SHA-256' => sha256,
         _ => throw ArgumentError('Unsupported mechanism $mechanism'),
       },
       _nonce = clientNonce ?? _randomNonce();

  final String mechanism;
  final String username;
  final String password;
  final Hash _hash;
  final String _nonce;
  late String _clientFirstBare;
  Uint8List? _serverSignature;

  /// Most PBKDF2 rounds accepted from a server: more would let a hostile
  /// server keep this device busy for a long time.
  static const int maxIterations = 200000;

  /// Fewest rounds accepted: RFC 7677 asks for at least 4096.
  static const int minIterations = 4096;

  static String _randomNonce() {
    final random = Random.secure();
    return base64
        .encode(List<int>.generate(24, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  static String _saslName(String value) =>
      value.replaceAll('=', '=3D').replaceAll(',', '=2C');

  /// The client-first message.
  Uint8List first() {
    _clientFirstBare = 'n=${_saslName(username)},r=$_nonce';
    return Uint8List.fromList(utf8.encode('n,,$_clientFirstBare'));
  }

  /// The client-final message, from the server-first message.
  Uint8List respond(Uint8List serverFirstBytes) {
    final serverFirst = utf8.decode(serverFirstBytes, allowMalformed: true);
    final fields = _fields(serverFirst);
    final nonce = fields['r'];
    final saltText = fields['s'];
    final iterations = int.tryParse(fields['i'] ?? '');
    if (fields.containsKey('m')) {
      throw const XmppSaslException('unsupported SCRAM extension');
    }
    if (nonce == null ||
        !nonce.startsWith(_nonce) ||
        nonce.length == _nonce.length ||
        saltText == null ||
        iterations == null) {
      throw const XmppSaslException('malformed server challenge');
    }
    if (iterations < minIterations || iterations > maxIterations) {
      throw const XmppSaslException('unacceptable iteration count');
    }
    final Uint8List salt;
    try {
      salt = base64.decode(saltText);
    } on FormatException {
      throw const XmppSaslException('malformed salt');
    }
    final salted = pbkdf2(_hash, utf8.encode(password), salt, iterations);
    final clientKey = _hmac(salted, utf8.encode('Client Key'));
    final storedKey = _hash.convert(clientKey).bytes;
    final withoutProof = 'c=biws,r=$nonce';
    final authMessage = '$_clientFirstBare,$serverFirst,$withoutProof';
    final clientSignature = _hmac(storedKey, utf8.encode(authMessage));
    final proof = Uint8List(clientKey.length);
    for (var index = 0; index < proof.length; index++) {
      proof[index] = clientKey[index] ^ clientSignature[index];
    }
    final serverKey = _hmac(salted, utf8.encode('Server Key'));
    _serverSignature = _hmac(serverKey, utf8.encode(authMessage));
    return Uint8List.fromList(
      utf8.encode('$withoutProof,p=${base64.encode(proof)}'),
    );
  }

  /// Checks the server-final message (`v=` the server's signature).
  void verify(Uint8List serverFinalBytes) {
    final expected = _serverSignature;
    if (expected == null) {
      throw const XmppSaslException('no challenge was answered');
    }
    final fields = _fields(utf8.decode(serverFinalBytes, allowMalformed: true));
    if (fields['e'] case final error?) {
      throw XmppSaslException(serverText(error, 64));
    }
    final Uint8List signature;
    try {
      signature = base64.decode(fields['v'] ?? '');
    } on FormatException {
      throw const XmppSaslException('malformed server signature');
    }
    if (!_constantTimeEquals(signature, expected)) {
      throw const XmppSaslException('the server signature is wrong');
    }
  }

  Uint8List _hmac(List<int> key, List<int> data) =>
      Uint8List.fromList(Hmac(_hash, key).convert(data).bytes);

  static Map<String, String> _fields(String message) => {
    for (final part in message.split(','))
      if (part.length >= 2 && part[1] == '=') part[0]: part.substring(2),
  };
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var index = 0; index < a.length; index++) {
    diff |= a[index] ^ b[index];
  }
  return diff == 0;
}

/// PBKDF2 with HMAC over [hash], one block (the hash's own length).
Uint8List pbkdf2(Hash hash, List<int> password, List<int> salt, int rounds) {
  final hmac = Hmac(hash, password);
  var block = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final result = Uint8List.fromList(block);
  for (var round = 1; round < rounds; round++) {
    block = hmac.convert(block).bytes;
    for (var index = 0; index < result.length; index++) {
      result[index] ^= block[index];
    }
  }
  return result;
}

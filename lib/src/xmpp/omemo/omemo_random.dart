import 'dart:math';
import 'dart:typed_data';

/// Where OMEMO gets its random bytes. Tests script it to replay reference
/// vectors byte for byte.
abstract class OmemoRandom {
  Uint8List bytes(int length);
}

class SecureOmemoRandom implements OmemoRandom {
  SecureOmemoRandom() : _random = Random.secure();
  final Random _random;

  @override
  Uint8List bytes(int length) {
    final out = Uint8List(length);
    for (var index = 0; index < length; index++) {
      out[index] = _random.nextInt(256);
    }
    return out;
  }
}

/// Serves a fixed list of draws in order and checks each requested length.
class ScriptedOmemoRandom implements OmemoRandom {
  ScriptedOmemoRandom(Iterable<Uint8List> draws) : _draws = draws.toList();
  final List<Uint8List> _draws;
  int _next = 0;

  int get remaining => _draws.length - _next;

  @override
  Uint8List bytes(int length) {
    if (_next >= _draws.length) {
      throw StateError('The scripted randomness ran out.');
    }
    final draw = _draws[_next++];
    if (draw.length != length) {
      throw StateError(
        'Draw $_next has ${draw.length} bytes, $length were asked for.',
      );
    }
    return Uint8List.fromList(draw);
  }
}

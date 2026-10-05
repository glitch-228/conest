import 'dart:typed_data';

/// HDLC-style framing, as Reticulum's TCP interfaces (rnsd) use it.
abstract final class HdlcFraming {
  static const int flag = 0x7e;
  static const int escape = 0x7d;
  static const int escapeMask = 0x20;

  static Uint8List frame(List<int> data) {
    final out = BytesBuilder(copy: false)..addByte(flag);
    for (final byte in data) {
      if (byte == escape || byte == flag) {
        out
          ..addByte(escape)
          ..addByte(byte ^ escapeMask);
      } else {
        out.addByte(byte);
      }
    }
    out.addByte(flag);
    return out.takeBytes();
  }
}

/// KISS framing, as RNode radios use it on serial and Bluetooth links.
abstract final class KissFraming {
  static const int fend = 0xc0;
  static const int fesc = 0xdb;
  static const int tfend = 0xdc;
  static const int tfesc = 0xdd;
  static const int cmdData = 0x00;

  static Uint8List frame(int command, List<int> data) {
    final out = BytesBuilder(copy: false)
      ..addByte(fend)
      ..addByte(command);
    for (final byte in data) {
      if (byte == fend) {
        out
          ..addByte(fesc)
          ..addByte(tfend);
      } else if (byte == fesc) {
        out
          ..addByte(fesc)
          ..addByte(tfesc);
      } else {
        out.addByte(byte);
      }
    }
    out.addByte(fend);
    return out.takeBytes();
  }
}

/// Splits a byte stream into HDLC frames.
class HdlcDeframer {
  HdlcDeframer({this.maxFrame = 2048});

  /// Longest frame kept; anything longer is dropped.
  final int maxFrame;
  final BytesBuilder _current = BytesBuilder(copy: false);
  bool _inFrame = false;
  bool _escaped = false;
  bool _overflow = false;

  /// Feeds received bytes; returns the frames they complete.
  List<Uint8List> add(List<int> bytes) {
    final frames = <Uint8List>[];
    for (final byte in bytes) {
      if (byte == HdlcFraming.flag) {
        if (_inFrame && _current.isNotEmpty && !_overflow) {
          frames.add(_current.takeBytes());
        }
        _current.clear();
        _inFrame = true;
        _escaped = false;
        _overflow = false;
        continue;
      }
      if (!_inFrame) continue;
      if (byte == HdlcFraming.escape) {
        _escaped = true;
        continue;
      }
      final value = _escaped ? byte ^ HdlcFraming.escapeMask : byte;
      _escaped = false;
      if (_current.length >= maxFrame) {
        _overflow = true;
      } else {
        _current.addByte(value);
      }
    }
    return frames;
  }
}

/// Splits a byte stream into KISS frames as (command, data).
class KissDeframer {
  KissDeframer({this.maxFrame = 2048});

  final int maxFrame;
  final BytesBuilder _current = BytesBuilder(copy: false);
  int? _command;
  bool _inFrame = false;
  bool _escaped = false;
  bool _overflow = false;

  List<(int, Uint8List)> add(List<int> bytes) {
    final frames = <(int, Uint8List)>[];
    for (final byte in bytes) {
      if (byte == KissFraming.fend) {
        final command = _command;
        if (_inFrame && command != null && !_overflow) {
          frames.add((command, _current.takeBytes()));
        }
        _current.clear();
        _inFrame = true;
        _command = null;
        _escaped = false;
        _overflow = false;
        continue;
      }
      if (!_inFrame) continue;
      if (_command == null) {
        _command = byte;
        continue;
      }
      if (byte == KissFraming.fesc) {
        _escaped = true;
        continue;
      }
      var value = byte;
      if (_escaped) {
        value = byte == KissFraming.tfend
            ? KissFraming.fend
            : byte == KissFraming.tfesc
            ? KissFraming.fesc
            : byte;
        _escaped = false;
      }
      if (_current.length >= maxFrame) {
        _overflow = true;
      } else {
        _current.addByte(value);
      }
    }
    return frames;
  }
}

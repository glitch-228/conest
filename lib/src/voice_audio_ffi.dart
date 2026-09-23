import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _OpenNative = Uint64 Function();
typedef _OpenDart = int Function();
typedef _SetMutedNative = Bool Function(Uint64, Bool);
typedef _SetMutedDart = bool Function(int, bool);
typedef _SetCongestedNative = Bool Function(Uint64, Bool);
typedef _SetCongestedDart = bool Function(int, bool);
typedef _HealthyNative = Bool Function(Uint64);
typedef _HealthyDart = bool Function(int);
typedef _NextNative =
    Bool Function(Uint64, Pointer<Uint8>, UintPtr, Pointer<UintPtr>);
typedef _NextDart = bool Function(int, Pointer<Uint8>, int, Pointer<UintPtr>);
typedef _PushNative = Bool Function(Uint64, Uint64, Pointer<Uint8>, UintPtr);
typedef _PushDart = bool Function(int, int, Pointer<Uint8>, int);
typedef _CloseNative = Void Function(Uint64);
typedef _CloseDart = void Function(int);
typedef _OutputDevicesNative = Pointer<Utf8> Function();
typedef _OutputDevicesDart = Pointer<Utf8> Function();
typedef _SelectOutputNative = Bool Function(Uint64, Pointer<Utf8>);
typedef _SelectOutputDart = bool Function(int, Pointer<Utf8>);
typedef _ErrorNative = Pointer<Utf8> Function();
typedef _ErrorDart = Pointer<Utf8> Function();
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class _NativeVoiceAudioBindings {
  _NativeVoiceAudioBindings(DynamicLibrary library)
    : open = library.lookupFunction<_OpenNative, _OpenDart>(
        'conest_voice_audio_open',
      ),
      setMuted = library.lookupFunction<_SetMutedNative, _SetMutedDart>(
        'conest_voice_audio_set_muted',
      ),
      setNetworkCongested = library
          .lookupFunction<_SetCongestedNative, _SetCongestedDart>(
            'conest_voice_audio_set_network_congested',
          ),
      isHealthy = library.lookupFunction<_HealthyNative, _HealthyDart>(
        'conest_voice_audio_is_healthy',
      ),
      nextPacket = library.lookupFunction<_NextNative, _NextDart>(
        'conest_voice_audio_next_packet',
      ),
      pushPacket = library.lookupFunction<_PushNative, _PushDart>(
        'conest_voice_audio_push_packet',
      ),
      close = library.lookupFunction<_CloseNative, _CloseDart>(
        'conest_voice_audio_close',
      ),
      outputDevices = library
          .lookupFunction<_OutputDevicesNative, _OutputDevicesDart>(
            'conest_voice_audio_output_devices',
          ),
      selectOutput = library
          .lookupFunction<_SelectOutputNative, _SelectOutputDart>(
            'conest_voice_audio_set_output_device',
          ),
      lastError = library.lookupFunction<_ErrorNative, _ErrorDart>(
        'conest_last_error',
      ),
      freeString = library.lookupFunction<_FreeNative, _FreeDart>(
        'conest_string_free',
      );

  final _OpenDart open;
  final _SetMutedDart setMuted;
  final _SetCongestedDart setNetworkCongested;
  final _HealthyDart isHealthy;
  final _NextDart nextPacket;
  final _PushDart pushPacket;
  final _CloseDart close;
  final _OutputDevicesDart outputDevices;
  final _SelectOutputDart selectOutput;
  final _ErrorDart lastError;
  final _FreeDart freeString;

  String takeLastError() {
    final pointer = lastError();
    if (pointer == nullptr) return 'Native audio device failed to start.';
    try {
      return pointer.toDartString();
    } finally {
      freeString(pointer);
    }
  }
}

/// FFI access to the native bounded PCM/Opus engine. Device open and encoded
/// packet polling run on helper isolates; the audio callbacks and codec run in
/// native worker threads.
class NativeVoiceCallAudio {
  NativeVoiceCallAudio._(this._libraryPath, this._bindings);

  static const int _maximumPacketBytes = 1100;
  static const Duration _stopTimeout = Duration(seconds: 1);

  final String _libraryPath;
  final _NativeVoiceAudioBindings _bindings;
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();
  int? _handle;
  Isolate? _pollIsolate;
  ReceivePort? _pollEvents;
  SendPort? _pollStopPort;
  ReceivePort? _pollExit;
  StreamSubscription<Object?>? _pollSubscription;

  Stream<Uint8List> get frames => _frames.stream;
  bool get isOpen => _handle != null;
  int? get handle => _handle;
  bool get isHealthy {
    final handle = _handle;
    return handle != null && _bindings.isHealthy(handle);
  }

  static NativeVoiceCallAudio? tryCreate() {
    if (!Platform.isAndroid && !Platform.isLinux && !Platform.isWindows) {
      return null;
    }
    for (final candidate in _candidateLibraryPaths()) {
      try {
        final library = DynamicLibrary.open(candidate);
        return NativeVoiceCallAudio._(
          candidate,
          _NativeVoiceAudioBindings(library),
        );
      } catch (_) {
        // Keep calls unavailable when the build lacks the complete native ABI.
      }
    }
    return null;
  }

  Future<void> open() async {
    if (_handle != null) throw StateError('Voice audio is already open.');
    final libraryPath = _libraryPath;
    final handle = await Isolate.run(() => _openVoiceAudioNative(libraryPath));
    if (handle == 0) {
      throw StateError('Native microphone/audio failed to open.');
    }
    _handle = handle;
    try {
      await _startPoller(handle);
    } catch (_) {
      _handle = null;
      await _stopPollingIsolate();
      await Isolate.run(() => _closeVoiceAudioNative(libraryPath, handle));
      rethrow;
    }
  }

  Future<List<String>> availableOutputDevices() async {
    if (!Platform.isLinux && !Platform.isWindows) return const [];
    return Isolate.run(() => _voiceAudioOutputDevicesNative(_libraryPath));
  }

  Future<void> selectOutputDevice(String name) async {
    if (!Platform.isLinux && !Platform.isWindows) {
      throw StateError(
        'Manual output selection is available on desktop calls.',
      );
    }
    final handle = _handle;
    if (handle == null) throw StateError('Voice audio is not active.');
    final result = await Isolate.run(
      () => _voiceAudioSelectOutputNative(_libraryPath, handle, name),
    );
    if (!result) throw StateError('Could not select audio output device.');
  }

  bool setMuted(bool muted) {
    final handle = _handle;
    return handle != null && _bindings.setMuted(handle, muted);
  }

  bool setNetworkCongested(bool congested) {
    final handle = _handle;
    return handle != null && _bindings.setNetworkCongested(handle, congested);
  }

  bool playPacket(int sequence, Uint8List packet) {
    final handle = _handle;
    if (handle == null ||
        packet.isEmpty ||
        packet.length > _maximumPacketBytes) {
      return false;
    }
    final pointer = calloc<Uint8>(packet.length);
    try {
      pointer.asTypedList(packet.length).setAll(0, packet);
      return _bindings.pushPacket(handle, sequence, pointer, packet.length);
    } finally {
      calloc.free(pointer);
    }
  }

  Future<void> close() async {
    final handle = _handle;
    _handle = null;
    await _stopPollingIsolate();
    if (handle != null) {
      await Isolate.run(() => _closeVoiceAudioNative(_libraryPath, handle));
    }
  }

  Future<void> dispose() async {
    await close();
    await _frames.close();
  }

  void reportPlatformFailure(String reason) {
    if (!_frames.isClosed) {
      _frames.addError(StateError(reason));
    }
  }

  Future<void> _startPoller(int handle) async {
    final events = ReceivePort();
    final exit = ReceivePort();
    final ready = Completer<SendPort>();
    _pollEvents = events;
    _pollExit = exit;
    _pollSubscription = events.listen((Object? message) {
      if (message is List<Object?> && message.isNotEmpty) {
        if (message.first == 'ready' && message.length > 1) {
          ready.complete(message[1] as SendPort);
        } else if (message.first == 'packet' && message.length > 1) {
          final data = message[1];
          if (data is TransferableTypedData) {
            _frames.add(data.materialize().asUint8List());
          }
        } else if (message.first == 'error' && message.length > 1) {
          _frames.addError(StateError(message[1].toString()));
        }
      }
    });
    _pollIsolate = await Isolate.spawn<List<Object?>>(
      _voiceAudioPollEntry,
      <Object?>[_libraryPath, handle, events.sendPort],
      onExit: exit.sendPort,
      errorsAreFatal: false,
    );
    final commandPort = await ready.future.timeout(const Duration(seconds: 2));
    _pollStopPort = commandPort;
  }

  Future<void> _stopPollingIsolate() async {
    _pollStopPort?.send('stop');
    _pollStopPort = null;
    final exited = _pollExit;
    if (exited != null) {
      try {
        await exited.first.timeout(_stopTimeout);
      } on TimeoutException {
        _pollIsolate?.kill(priority: Isolate.immediate);
      }
    }
    await _pollSubscription?.cancel();
    _pollSubscription = null;
    _pollEvents?.close();
    _pollEvents = null;
    _pollExit?.close();
    _pollExit = null;
    _pollIsolate = null;
  }
}

Iterable<String> _candidateLibraryPaths() sync* {
  final override = Platform.environment['CONEST_NATIVE_LIBRARY'];
  if (override != null && override.trim().isNotEmpty) yield override.trim();
  final name = Platform.isWindows ? 'conest_native.dll' : 'libconest_native.so';
  if (Platform.isLinux || Platform.isWindows) {
    final executable = File(Platform.resolvedExecutable).parent.path;
    yield '$executable${Platform.pathSeparator}$name';
    yield '$executable${Platform.pathSeparator}lib${Platform.pathSeparator}$name';
  }
  yield name;
}

int _openVoiceAudioNative(String libraryPath) {
  final bindings = _NativeVoiceAudioBindings(DynamicLibrary.open(libraryPath));
  final handle = bindings.open();
  if (handle == 0) throw StateError(bindings.takeLastError());
  return handle;
}

List<String> _voiceAudioOutputDevicesNative(String libraryPath) {
  final bindings = _NativeVoiceAudioBindings(DynamicLibrary.open(libraryPath));
  final pointer = bindings.outputDevices();
  if (pointer == nullptr) return const [];
  try {
    final decoded = jsonDecode(pointer.toDartString());
    if (decoded is! List) return const [];
    return decoded.whereType<String>().toList(growable: false);
  } finally {
    bindings.freeString(pointer);
  }
}

bool _voiceAudioSelectOutputNative(
  String libraryPath,
  int handle,
  String name,
) {
  final bindings = _NativeVoiceAudioBindings(DynamicLibrary.open(libraryPath));
  final namePointer = name.toNativeUtf8();
  try {
    final selected = bindings.selectOutput(handle, namePointer);
    if (!selected) throw StateError(bindings.takeLastError());
    return true;
  } finally {
    calloc.free(namePointer);
  }
}

void _closeVoiceAudioNative(String libraryPath, int handle) {
  try {
    _NativeVoiceAudioBindings(DynamicLibrary.open(libraryPath)).close(handle);
  } catch (_) {}
}

void _voiceAudioPollEntry(List<Object?> startup) {
  final libraryPath = startup[0] as String;
  final handle = startup[1] as int;
  final events = startup[2] as SendPort;
  late final _NativeVoiceAudioBindings bindings;
  try {
    bindings = _NativeVoiceAudioBindings(DynamicLibrary.open(libraryPath));
  } catch (error) {
    events.send(<Object?>['error', error.toString()]);
    return;
  }
  final control = ReceivePort();
  Timer? timer;
  Timer? healthTimer;
  Pointer<Uint8>? packet;
  Pointer<UintPtr>? length;
  var cleaned = false;
  void stopTimers() {
    if (cleaned) return;
    cleaned = true;
    timer?.cancel();
    healthTimer?.cancel();
    if (packet != null) calloc.free(packet!);
    if (length != null) calloc.free(length!);
    packet = null;
    length = null;
  }

  control.listen((Object? message) {
    if (message == 'stop') {
      stopTimers();
      control.close();
    }
  });
  events.send(<Object?>['ready', control.sendPort]);
  packet = calloc<Uint8>(_NativeVoiceCallAudioPacketLimit.value);
  length = calloc<UintPtr>();
  timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
    for (var count = 0; count < 2; count++) {
      length!.value = 0;
      if (!bindings.nextPacket(
        handle,
        packet!,
        _NativeVoiceCallAudioPacketLimit.value,
        length!,
      )) {
        break;
      }
      final bytes = Uint8List.fromList(packet!.asTypedList(length!.value));
      events.send(<Object?>[
        'packet',
        TransferableTypedData.fromList(<Uint8List>[bytes]),
      ]);
    }
  });
  // The buffers live for the full isolate polling lifetime and are freed when
  // it exits, including the explicit native session teardown path.
  healthTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
    if (!bindings.isHealthy(handle)) {
      events.send(<Object?>['error', 'Audio device stream stopped.']);
      stopTimers();
      control.close();
    }
  });
}

abstract final class _NativeVoiceCallAudioPacketLimit {
  static const int value = 1100;
}

import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart' as ja;
import 'package:media_kit/media_kit.dart' as mk;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:record/record.dart';

import 'feature_models.dart';
import 'linux_mpv_player.dart';
import 'platform_bridge.dart';

enum VoiceRecordingState { idle, starting, recording, stopping, preview, error }

class VoiceRecordingSnapshot {
  const VoiceRecordingSnapshot({
    required this.state,
    required this.destinationKey,
    required this.elapsed,
    required this.waveform,
    this.error,
  });
  final VoiceRecordingState state;
  final String? destinationKey;
  final Duration elapsed;
  final List<int> waveform;
  final String? error;
}

/// Keeps recording private and separate from the transfer pipeline. Capture
/// and Opus encoding are provided by native recorder implementations; the
/// resulting Ogg file is handed to Conest only after explicit send.
class VoiceMessageService {
  VoiceMessageService({
    PlatformBridge? platformBridge,
    Future<Directory> Function()? applicationSupportDirectory,
    DateTime Function()? now,
  }) : _platformBridge = platformBridge,
       _applicationSupportDirectory =
           applicationSupportDirectory ??
           path_provider.getApplicationSupportDirectory,
       _now = now ?? DateTime.now;
  final PlatformBridge? _platformBridge;
  final Future<Directory> Function() _applicationSupportDirectory;
  final DateTime Function() _now;
  AudioRecorder? _recorder;
  AudioRecorder get _captureRecorder => _recorder ??= AudioRecorder();
  VoiceRecordingState _state = VoiceRecordingState.idle;
  String? _previewDestinationKey;
  final StreamController<VoiceRecordingState> _stateChanges =
      StreamController<VoiceRecordingState>.broadcast();
  final StreamController<VoiceRecordingSnapshot> _recordingSnapshots =
      StreamController<VoiceRecordingSnapshot>.broadcast();
  final StreamController<Duration> _playbackPositions =
      StreamController<Duration>.broadcast();
  final StreamController<String> _playbackErrors =
      StreamController<String>.broadcast();
  VoiceRecordingResult? _preview;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  StreamSubscription<RecordState>? _recorderStateSubscription;
  Timer? _durationTimer;
  Timer? _durationTickTimer;
  LinuxMpvPlayer? _linuxPlayer;
  StreamSubscription<LinuxMpvSnapshot>? _linuxPlayerSubscription;
  mk.Player? _desktopPlayer;
  ja.AudioPlayer? _mobilePlayer;
  StreamSubscription<Duration>? _mobilePositionSubscription;
  StreamSubscription<Duration>? _desktopPositionSubscription;
  String? _playingPath;
  String? _playingItemId;
  double _playbackRate = 1;
  DateTime? _startedAt;
  String? _nativeRecordingPath;
  bool _captureStarting = false;
  bool _disposed = false;
  Completer<void>? _captureStartupDone;
  Future<void>? _disposeInFlight;
  bool _interruptCaptureStartup = false;
  bool _cancelCaptureStartup = false;
  bool _ignoreRecorderStateEvents = false;
  String? _recordingError;
  String? _playbackError;
  Future<VoiceRecordingResult>? _stopInFlight;
  Future<void>? _cancelInFlight;
  final List<int> _waveform = <int>[];

  static bool _mediaKitInitialized = false;
  static const Duration maximumDuration = Duration(minutes: 10);

  /// Removes recordings abandoned by a process exit. Only files created by
  /// this service are eligible; unrelated files in the private directory are
  /// left alone. Errors are best-effort so startup remains available if the
  /// platform storage provider is temporarily unavailable.
  static Future<void> cleanupAbandonedRecordings({Directory? directory}) async {
    try {
      final recordingsDirectory =
          directory ??
          Directory(
            p.join(
              (await path_provider.getApplicationSupportDirectory()).path,
              'voice-recordings',
            ),
          );
      if (!await recordingsDirectory.exists()) return;
      await for (final entity in recordingsDirectory.list(followLinks: false)) {
        if (entity is! File ||
            !RegExp(r'^voice-\d+\.ogg$').hasMatch(p.basename(entity.path))) {
          continue;
        }
        try {
          if (await FileSystemEntity.type(entity.path, followLinks: false) ==
              FileSystemEntityType.file) {
            await entity.delete();
          }
        } catch (_) {
          // A locked/otherwise unavailable file can be retried next launch.
        }
      }
    } catch (_) {
      // Cleanup must never prevent the app from opening.
    }
  }

  VoiceRecordingState get state => _state;
  Stream<VoiceRecordingState> get states => _stateChanges.stream;
  Stream<VoiceRecordingSnapshot> get recordingSnapshots => _recordingSnapshots.stream;
  VoiceRecordingSnapshot get recordingSnapshot => VoiceRecordingSnapshot(
    state: _state,
    destinationKey: _previewDestinationKey,
    elapsed: _currentRecordingDuration(),
    waveform: List<int>.unmodifiable(_waveform),
    error: _recordingError,
  );
  VoiceRecordingResult? get preview => _preview;
  String? get previewDestinationKey => _previewDestinationKey;
  bool get isRecording => _state == VoiceRecordingState.recording;
  double get playbackRate => _playbackRate;
  String? get playingItemId => _playingItemId;
  String? get playbackError => _playbackError;
  Stream<String> get playbackErrors => _playbackErrors.stream;
  bool get isPlaying => Platform.isAndroid
      ? (_mobilePlayer?.playing ?? false)
      : Platform.isLinux
      ? (_linuxPlayer?.isPlaying ?? false)
      : (_desktopPlayer?.state.playing ?? false);

  void _setState(VoiceRecordingState value) {
    if (_state == value) return;
    _state = value;
    if (!_stateChanges.isClosed) _stateChanges.add(value);
    _emitRecordingSnapshot();
  }

  Duration _currentRecordingDuration() {
    final startedAt = _startedAt;
    if (startedAt == null || _state != VoiceRecordingState.recording) {
      return Duration.zero;
    }
    final elapsed = _now().toUtc().difference(startedAt);
    if (elapsed.isNegative) return Duration.zero;
    return elapsed > maximumDuration ? maximumDuration : elapsed;
  }

  void _emitRecordingSnapshot() {
    if (!_recordingSnapshots.isClosed) {
      _recordingSnapshots.add(recordingSnapshot);
    }
  }

  void reportRecordingError(Object error) {
    _recordingError = error.toString();
    _emitRecordingSnapshot();
  }

  List<int> _nativeWaveform(Map<String, dynamic>? result) {
    final samples = result?['waveform'];
    if (samples is! List) return List<int>.unmodifiable(_waveform);
    return samples
        .whereType<num>()
        .take(256)
        .map((sample) => sample.toInt().clamp(0, 255))
        .toList(growable: false);
  }

  Stream<Duration> get playbackPositionStream => _playbackPositions.stream;

  Future<void> start({required String destinationKey}) async {
    if (_disposed) throw StateError('Voice recorder is disposed.');
    if ((_state != VoiceRecordingState.idle &&
            _state != VoiceRecordingState.error) ||
        _captureStarting) {
      throw StateError('A voice recording is already active.');
    }
    if (destinationKey.isEmpty || destinationKey.length > 256) {
      throw ArgumentError.value(destinationKey, 'destinationKey');
    }
    final bridge = _platformBridge;
    final useNativeRecorder =
        bridge?.supportsNativeVoiceMessageRecording ?? false;
    _captureStarting = true;
    final startupDone = Completer<void>();
    _captureStartupDone = startupDone;
    _interruptCaptureStartup = false;
    _cancelCaptureStartup = false;
    _recordingError = null;
    _previewDestinationKey = destinationKey;
    _setState(VoiceRecordingState.starting);
    try {
      // Capture and playback share the device audio session. Stop any message
      // playback before opening the microphone, including while permission is
      // being requested.
      await stopPlayback();
      final AudioRecorder? recorder = useNativeRecorder
          ? null
          : _captureRecorder;
      if (recorder != null && !await recorder.hasPermission()) {
        throw StateError('Microphone permission was not granted.');
      }
      if (recorder != null &&
          !await recorder.isEncoderSupported(AudioEncoder.opus)) {
        throw StateError('Ogg/Opus recording is unavailable on this device.');
      }
      final support = await _applicationSupportDirectory();
      final directory = Directory(p.join(support.path, 'voice-recordings'));
      await directory.create(recursive: true);
      if (_interruptCaptureStartup || _cancelCaptureStartup) {
        throw StateError(
          _cancelCaptureStartup
              ? 'Voice recording was canceled during startup.'
              : 'Recording was interrupted before it started.',
        );
      }
      final path = p.join(
        directory.path,
        'voice-${_now().toUtc().microsecondsSinceEpoch}.ogg',
      );
      _waveform.clear();
      _startedAt = _now().toUtc();
      if (useNativeRecorder) {
        _nativeRecordingPath = path;
        await bridge!.startVoiceMessageRecording(path);
      } else {
        _recorderStateSubscription = recorder!.onStateChanged().listen(
          _handleRecorderState,
          onError: (Object _) {},
        );
        await recorder!.start(
          const RecordConfig(
            encoder: AudioEncoder.opus,
            bitRate: 24000,
            sampleRate: 48000,
            numChannels: 1,
            echoCancel: true,
            noiseSuppress: true,
            audioInterruption: AudioInterruptionMode.pause,
          ),
          path: path,
        );
      }
      _setState(VoiceRecordingState.recording);
      if (recorder != null) {
        _amplitudeSubscription = recorder
            .onAmplitudeChanged(const Duration(milliseconds: 100))
            .listen((amplitude) {
              if (_waveform.length >= 256) return;
              final sample = ((amplitude.current + 60) * 255 / 60)
                  .round()
                  .clamp(0, 255);
              _waveform.add(sample);
            });
      }
      _durationTimer = Timer(maximumDuration, () {
        unawaited(stopForInterruption());
      });
      _durationTickTimer?.cancel();
      _durationTickTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => _emitRecordingSnapshot(),
      );
      final interrupted = _interruptCaptureStartup;
      final canceled = _cancelCaptureStartup;
      _captureStarting = false;
      if (canceled) {
        await cancel();
        throw StateError('Voice recording was canceled during startup.');
      }
      if (interrupted) await stopForInterruption();
    } catch (error) {
      if (useNativeRecorder) {
        if (_nativeRecordingPath != null) {
          try {
            await bridge!.cancelVoiceMessageRecording();
          } catch (_) {}
          _nativeRecordingPath = null;
        }
      } else {
        try {
          await _captureRecorder.cancel();
        } catch (_) {}
      }
      _durationTimer?.cancel();
      _durationTimer = null;
      _durationTickTimer?.cancel();
      _durationTickTimer = null;
      await _amplitudeSubscription?.cancel();
      _amplitudeSubscription = null;
      await _recorderStateSubscription?.cancel();
      _recorderStateSubscription = null;
      _startedAt = null;
      final canceled = _cancelCaptureStartup ||
          error.toString().contains('was canceled during startup') ||
          error.toString().contains('was interrupted before it started');
      _recordingError = canceled ? null : error.toString();
      if (canceled) _previewDestinationKey = null;
      _setState(canceled ? VoiceRecordingState.idle : VoiceRecordingState.error);
      rethrow;
    } finally {
      _captureStarting = false;
      _interruptCaptureStartup = false;
      _cancelCaptureStartup = false;
      startupDone.complete();
      if (identical(_captureStartupDone, startupDone)) {
        _captureStartupDone = null;
      }
    }
  }

  Future<VoiceRecordingResult> stop() async {
    final inFlight = _stopInFlight;
    if (inFlight != null) return inFlight;
    if (_state != VoiceRecordingState.recording) {
      throw StateError('No voice recording is active.');
    }
    final operation = _stopAndStore();
    _stopInFlight = operation;
    try {
      return await operation;
    } catch (error) {
      _recordingError = error.toString();
      _setState(VoiceRecordingState.error);
      rethrow;
    } finally {
      if (identical(_stopInFlight, operation)) _stopInFlight = null;
    }
  }

  /// Interruptions and app backgrounding stop capture but preserve a preview;
  /// they never send audio automatically.
  Future<void> stopForInterruption() async {
    if (_captureStarting) {
      _interruptCaptureStartup = true;
      return;
    }
    if (_state != VoiceRecordingState.recording) return;
    try {
      await stop();
    } catch (_) {
      await cancel();
    }
  }

  Future<VoiceRecordingResult> _stopAndStore() async {
    final startedAt = _startedAt;
    _setState(VoiceRecordingState.stopping);
    _durationTimer?.cancel();
    _durationTimer = null;
    _durationTickTimer?.cancel();
    _durationTickTimer = null;
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    String? path;
    Map<String, dynamic>? nativeResult;
    if (_nativeRecordingPath case final nativePath?) {
      path = nativePath;
      try {
        nativeResult = await _platformBridge!.stopVoiceMessageRecording();
      } catch (_) {
        try {
          await _platformBridge!.cancelVoiceMessageRecording();
        } catch (_) {}
        _nativeRecordingPath = null;
        _startedAt = null;
        rethrow;
      }
      _nativeRecordingPath = null;
    } else {
      _ignoreRecorderStateEvents = true;
      try {
        path = await _captureRecorder.stop() ?? _preview?.path;
      } finally {
        _ignoreRecorderStateEvents = false;
        await _recorderStateSubscription?.cancel();
        _recorderStateSubscription = null;
      }
    }
    _startedAt = null;
    if (path == null) {
      throw StateError('Voice recording stopped without an audio file.');
    }
    final file = File(path);
    if (!await file.exists() || await file.length() <= 0) {
      throw StateError('Voice recording output is empty.');
    }
    final handle = await file.open();
    final signature = await handle.read(4);
    await handle.close();
    if (signature.length != 4 ||
        signature[0] != 0x4f ||
        signature[1] != 0x67 ||
        signature[2] != 0x67 ||
        signature[3] != 0x53) {
      await file.delete();
      throw StateError('The recorder did not produce an Ogg/Opus file.');
    }
    final stoppedAt = _now().toUtc();
    final elapsed = stoppedAt.difference(startedAt ?? stoppedAt);
    final durationMs = elapsed.inMilliseconds.clamp(
      1,
      maximumDuration.inMilliseconds,
    );
    if (durationMs < 1000) {
      await file.delete();
      throw StateError('Voice messages must be at least one second long.');
    }
    final result = VoiceRecordingResult(
      path: file.path,
      sizeBytes: await file.length(),
      metadata: VoiceMessageMetadata(
        durationMs: durationMs,
        waveform: List<int>.unmodifiable(_nativeWaveform(nativeResult)),
      ),
    );
    _preview = result;
    _recordingError = null;
    _setState(VoiceRecordingState.preview);
    return result;
  }

  /// Release the preview only after Conest has copied it into its normal
  /// encrypted transfer spool. A failed handoff leaves the preview intact.
  Future<void> completePreview() async {
    if (_state == VoiceRecordingState.recording) {
      throw StateError('Stop the active recording before completing it.');
    }
    final path = _preview?.path;
    if (path != null && _playingPath == path) await stopPlayback();
    _preview = null;
    _previewDestinationKey = null;
    _setState(VoiceRecordingState.idle);
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<void> playPreview() async {
    final value = _preview;
    if (value == null) throw StateError('No voice recording preview exists.');
    await togglePlayback(value.path, itemId: 'voice-preview');
  }

  Future<void> togglePlayback(String path, {String? itemId}) async {
    if (_disposed) throw StateError('Voice recorder is disposed.');
    if (_captureStarting) {
      throw StateError('Wait for the voice recording to start or cancel.');
    }
    // A new playback request interrupts capture into an unsent preview. This
    // keeps playback and microphone ownership mutually exclusive without
    // discarding a recording when the user changes focus.
    if (_state == VoiceRecordingState.recording) {
      await stopForInterruption();
    }
    _playbackError = null;
    try {
      await _ensurePlayer();
    } catch (error) {
      _reportPlaybackError(error);
      rethrow;
    }
    if (Platform.isAndroid) {
      final player = _mobilePlayer!;
      if (_playingPath == path) {
        _playingItemId = itemId;
        if (player.playing) {
          await player.pause();
        } else {
          if (player.processingState == ja.ProcessingState.completed) {
            await player.seek(Duration.zero);
          }
          await player.play();
        }
        _emitPlaybackPosition(player.position);
        return;
      }
      _playingPath = path;
      _playingItemId = itemId;
      await player.setFilePath(path);
      await player.play();
      _emitPlaybackPosition(Duration.zero);
      return;
    }
    if (Platform.isLinux) {
      final player = _linuxPlayer!;
      if (_playingPath == path) {
        _playingItemId = itemId;
        await player.toggle();
      } else {
        try {
          await player.playFile(path);
          _playingPath = path;
          _playingItemId = itemId;
        } catch (error) {
          _playingPath = null;
          _playingItemId = null;
          _reportPlaybackError(error);
          rethrow;
        }
      }
      _emitPlaybackPosition(player.snapshot.position);
      return;
    }
    final player = _desktopPlayer!;
    if (_playingPath == path) {
      _playingItemId = itemId;
      if (player.state.playing) {
        await player.pause();
      } else {
        await player.play();
      }
      _emitPlaybackPosition(player.state.position);
    } else {
      _playingPath = path;
      _playingItemId = itemId;
      await player.open(mk.Media(path));
      _emitPlaybackPosition(Duration.zero);
    }
  }

  Future<void> seekPlayback(Duration position) async {
    if (Platform.isAndroid) {
      await _mobilePlayer?.seek(position);
    } else if (Platform.isLinux) {
      await _linuxPlayer?.seek(position);
    } else {
      await _desktopPlayer?.seek(position);
    }
  }

  Future<void> setPlaybackRate(double rate) async {
    if (rate != 1 && rate != 1.5 && rate != 2) {
      throw ArgumentError.value(rate, 'rate');
    }
    await _ensurePlayer();
    if (Platform.isAndroid) {
      await _mobilePlayer!.setSpeed(rate);
    } else if (Platform.isLinux) {
      await _linuxPlayer!.setSpeed(rate);
    } else {
      await _desktopPlayer!.setRate(rate);
    }
    _playbackRate = rate;
  }

  Future<void> stopPlayback() async {
    _playingPath = null;
    _playingItemId = null;
    await _mobilePlayer?.stop();
    if (Platform.isLinux) {
      try {
        await _linuxPlayer?.stop();
      } catch (error) {
        _reportPlaybackError(error);
      }
    }
    await _desktopPlayer?.stop();
    _emitPlaybackPosition(Duration.zero);
  }

  Future<void> _ensurePlayer() async {
    if (Platform.isAndroid) {
      if (_mobilePlayer == null) {
        final player = _mobilePlayer = ja.AudioPlayer();
        _mobilePositionSubscription = player.positionStream.listen(
          _emitPlaybackPosition,
        );
      }
      return;
    }
    if (!Platform.isLinux && !Platform.isWindows) {
      throw StateError('Voice playback is unavailable on this platform.');
    }
    if (Platform.isLinux) {
      if (_linuxPlayer == null) {
        final player = _linuxPlayer = await LinuxMpvPlayer.start();
        _linuxPlayerSubscription = player.changes.listen((snapshot) {
          if (snapshot.error case final error?) {
            if (error != _playbackError) _reportPlaybackError(error);
          }
          if (snapshot.completed || (!snapshot.loaded && !snapshot.playing)) {
            _playingPath = null;
            _playingItemId = null;
          }
          _playbackRate = snapshot.speed;
          _emitPlaybackPosition(snapshot.position);
        });
      }
      return;
    }
    if (!_mediaKitInitialized) {
      mk.MediaKit.ensureInitialized();
      _mediaKitInitialized = true;
    }
    if (_desktopPlayer == null) {
      final player = _desktopPlayer = mk.Player();
      _desktopPositionSubscription = player.stream.position.listen(
        _emitPlaybackPosition,
      );
    }
  }

  void _emitPlaybackPosition(Duration position) {
    if (!_playbackPositions.isClosed) _playbackPositions.add(position);
  }

  void _reportPlaybackError(Object error) {
    final message = error.toString();
    _playbackError = message;
    if (!_playbackErrors.isClosed) _playbackErrors.add(message);
    _emitPlaybackPosition(Duration.zero);
  }

  void _handleRecorderState(RecordState state) {
    if (_ignoreRecorderStateEvents ||
        _state != VoiceRecordingState.recording ||
        (state != RecordState.pause && state != RecordState.stop)) {
      return;
    }
    unawaited(stopForInterruption());
  }

  Future<void> cancel() async {
    if (_captureStarting) {
      _cancelCaptureStartup = true;
      _interruptCaptureStartup = true;
      return;
    }
    final inFlight = _cancelInFlight;
    if (inFlight != null) return inFlight;
    final operation = _cancelRecording();
    _cancelInFlight = operation;
    try {
      await operation;
    } finally {
      if (identical(_cancelInFlight, operation)) _cancelInFlight = null;
    }
  }

  Future<void> _cancelRecording() async {
    final stopInFlight = _stopInFlight;
    if (stopInFlight != null) {
      try {
        await stopInFlight;
      } catch (_) {
        // A failed stop falls through to recorder.cancel below.
      }
    }
    _durationTimer?.cancel();
    _durationTimer = null;
    _durationTickTimer?.cancel();
    _durationTickTimer = null;
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    if (_nativeRecordingPath != null) {
      try {
        await _platformBridge?.cancelVoiceMessageRecording();
      } catch (_) {}
      _nativeRecordingPath = null;
    } else if (_state == VoiceRecordingState.recording) {
      _ignoreRecorderStateEvents = true;
      try {
        await _captureRecorder.cancel();
      } catch (_) {}
      _ignoreRecorderStateEvents = false;
    }
    await _recorderStateSubscription?.cancel();
    _recorderStateSubscription = null;
    _startedAt = null;
    _waveform.clear();
    _recordingError = null;
    await completePreview();
  }

  Future<void> dispose() => _disposeInFlight ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    final startupDone = _captureStartupDone;
    await cancel();
    // cancel() marks pending permission/native startup for cancellation. Wait
    // for its teardown before releasing devices and closing event streams.
    if (startupDone != null) await startupDone.future;
    await stopPlayback();
    await _recorder?.dispose();
    await _mobilePositionSubscription?.cancel();
    await _desktopPositionSubscription?.cancel();
    await _linuxPlayerSubscription?.cancel();
    await _mobilePlayer?.dispose();
    await _desktopPlayer?.dispose();
    await _linuxPlayer?.dispose();
    await _stateChanges.close();
    await _recordingSnapshots.close();
    await _playbackPositions.close();
    await _playbackErrors.close();
  }
}

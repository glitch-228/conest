import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart' as ja;
import 'package:media_kit/media_kit.dart' as mk;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:record/record.dart';

import 'feature_models.dart';

enum VoiceRecordingState { idle, recording, preview }

/// Keeps recording private and separate from the transfer pipeline. Capture
/// and Opus encoding are provided by native recorder implementations; the
/// resulting Ogg file is handed to Conest only after explicit send.
class VoiceMessageService {
  VoiceMessageService();
  AudioRecorder? _recorder;
  AudioRecorder get _captureRecorder => _recorder ??= AudioRecorder();
  VoiceRecordingState _state = VoiceRecordingState.idle;
  String? _previewDestinationKey;
  final StreamController<VoiceRecordingState> _stateChanges =
      StreamController<VoiceRecordingState>.broadcast();
  final StreamController<Duration> _playbackPositions =
      StreamController<Duration>.broadcast();
  VoiceRecordingResult? _preview;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  StreamSubscription<RecordState>? _recorderStateSubscription;
  Timer? _durationTimer;
  mk.Player? _desktopPlayer;
  ja.AudioPlayer? _mobilePlayer;
  StreamSubscription<Duration>? _mobilePositionSubscription;
  StreamSubscription<Duration>? _desktopPositionSubscription;
  String? _playingPath;
  String? _playingItemId;
  double _playbackRate = 1;
  DateTime? _startedAt;
  bool _captureStarting = false;
  bool _interruptCaptureStartup = false;
  bool _cancelCaptureStartup = false;
  bool _ignoreRecorderStateEvents = false;
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
  VoiceRecordingResult? get preview => _preview;
  String? get previewDestinationKey => _previewDestinationKey;
  bool get isRecording => _state == VoiceRecordingState.recording;
  double get playbackRate => _playbackRate;
  String? get playingItemId => _playingItemId;
  bool get isPlaying => Platform.isAndroid
      ? (_mobilePlayer?.playing ?? false)
      : (_desktopPlayer?.state.playing ?? false);

  void _setState(VoiceRecordingState value) {
    if (_state == value) return;
    _state = value;
    if (!_stateChanges.isClosed) _stateChanges.add(value);
  }

  Stream<Duration> get playbackPositionStream => _playbackPositions.stream;

  Future<void> start({required String destinationKey}) async {
    if (_state != VoiceRecordingState.idle || _captureStarting) {
      throw StateError('A voice recording is already active.');
    }
    if (destinationKey.isEmpty || destinationKey.length > 256) {
      throw ArgumentError.value(destinationKey, 'destinationKey');
    }
    _captureStarting = true;
    _interruptCaptureStartup = false;
    _cancelCaptureStartup = false;
    try {
      // Capture and playback share the device audio session. Stop any message
      // playback before opening the microphone, including while permission is
      // being requested.
      await stopPlayback();
      final recorder = _captureRecorder;
      if (!await recorder.hasPermission()) {
        throw StateError('Microphone permission was not granted.');
      }
      if (!await recorder.isEncoderSupported(AudioEncoder.opus)) {
        throw StateError('Ogg/Opus recording is unavailable on this device.');
      }
      final support = await path_provider.getApplicationSupportDirectory();
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
        'voice-${DateTime.now().toUtc().microsecondsSinceEpoch}.ogg',
      );
      _waveform.clear();
      _previewDestinationKey = destinationKey;
      _startedAt = DateTime.now().toUtc();
      _recorderStateSubscription = recorder.onStateChanged().listen(
        _handleRecorderState,
        onError: (Object _) {},
      );
      await recorder.start(
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
      _setState(VoiceRecordingState.recording);
      _amplitudeSubscription = recorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((amplitude) {
            if (_waveform.length >= 256) return;
            final sample = ((amplitude.current + 60) * 255 / 60).round().clamp(
              0,
              255,
            );
            _waveform.add(sample);
          });
      _durationTimer = Timer(maximumDuration, () {
        unawaited(stopForInterruption());
      });
      final interrupted = _interruptCaptureStartup;
      final canceled = _cancelCaptureStartup;
      _captureStarting = false;
      if (canceled) {
        await cancel();
        throw StateError('Voice recording was canceled during startup.');
      }
      if (interrupted) await stopForInterruption();
    } catch (_) {
      try {
        await _captureRecorder.cancel();
      } catch (_) {}
      _durationTimer?.cancel();
      _durationTimer = null;
      await _amplitudeSubscription?.cancel();
      _amplitudeSubscription = null;
      await _recorderStateSubscription?.cancel();
      _recorderStateSubscription = null;
      _startedAt = null;
      _previewDestinationKey = null;
      _setState(VoiceRecordingState.idle);
      rethrow;
    } finally {
      _captureStarting = false;
      _interruptCaptureStartup = false;
      _cancelCaptureStartup = false;
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
    _durationTimer?.cancel();
    _durationTimer = null;
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    final String? recordedPath;
    _ignoreRecorderStateEvents = true;
    try {
      recordedPath = await _captureRecorder.stop();
    } finally {
      _ignoreRecorderStateEvents = false;
      await _recorderStateSubscription?.cancel();
      _recorderStateSubscription = null;
    }
    final path = recordedPath ?? _preview?.path;
    _startedAt = null;
    if (path == null) {
      _setState(VoiceRecordingState.idle);
      _previewDestinationKey = null;
      throw StateError('Voice recording stopped without an audio file.');
    }
    final file = File(path);
    if (!await file.exists() || await file.length() <= 0) {
      _setState(VoiceRecordingState.idle);
      _previewDestinationKey = null;
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
      _setState(VoiceRecordingState.idle);
      _previewDestinationKey = null;
      throw StateError('The recorder did not produce an Ogg/Opus file.');
    }
    final elapsed = DateTime.now().toUtc().difference(
      startedAt ?? DateTime.now().toUtc(),
    );
    final durationMs = elapsed.inMilliseconds.clamp(
      1,
      maximumDuration.inMilliseconds,
    );
    if (durationMs < 1000) {
      await file.delete();
      _setState(VoiceRecordingState.idle);
      _previewDestinationKey = null;
      throw StateError('Voice messages must be at least one second long.');
    }
    final result = VoiceRecordingResult(
      path: file.path,
      sizeBytes: await file.length(),
      metadata: VoiceMessageMetadata(
        durationMs: durationMs,
        waveform: List<int>.unmodifiable(_waveform),
      ),
    );
    _preview = result;
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
    if (_captureStarting) {
      throw StateError('Wait for the voice recording to start or cancel.');
    }
    // A new playback request interrupts capture into an unsent preview. This
    // keeps playback and microphone ownership mutually exclusive without
    // discarding a recording when the user changes focus.
    if (_state == VoiceRecordingState.recording) {
      await stopForInterruption();
    }
    await _ensurePlayer();
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
    } else {
      await _desktopPlayer!.setRate(rate);
    }
    _playbackRate = rate;
  }

  Future<void> stopPlayback() async {
    _playingPath = null;
    _playingItemId = null;
    await _mobilePlayer?.stop();
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
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    if (_state == VoiceRecordingState.recording) {
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
    await completePreview();
  }

  Future<void> dispose() async {
    await cancel();
    await stopPlayback();
    await _recorder?.dispose();
    await _mobilePositionSubscription?.cancel();
    await _desktopPositionSubscription?.cancel();
    await _mobilePlayer?.dispose();
    await _desktopPlayer?.dispose();
    await _stateChanges.close();
    await _playbackPositions.close();
  }
}

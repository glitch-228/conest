import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:media_kit/media_kit.dart' as mk;
import 'package:path_provider/path_provider.dart';

import 'feature_models.dart';

/// Short sounds that mark voice call transitions.
enum VoiceCallCue {
  incomingRing(loops: true),
  outgoingRing(loops: true),
  connected(),
  reconnecting(),
  ended(),
  busy(),
  muted(),
  unmuted();

  const VoiceCallCue({this.loops = false});

  /// Ring cues repeat until the call leaves the ringing state.
  final bool loops;
}

/// Picks the cue for a call session change, or `null` when nothing new should
/// play. A looping ring that is not replaced is stopped by the caller.
VoiceCallCue? voiceCallCueFor(
  VoiceCallSession? previous,
  VoiceCallSession? next,
) {
  if (next == null) return null;
  final prior = previous != null && previous.callId == next.callId
      ? previous
      : null;
  if (prior != null &&
      prior.state == next.state &&
      next.state != VoiceCallState.ended &&
      prior.muted != next.muted) {
    return next.muted ? VoiceCallCue.muted : VoiceCallCue.unmuted;
  }
  switch (next.state) {
    case VoiceCallState.ringing:
      if (prior?.state == VoiceCallState.ringing) return null;
      return next.outgoing
          ? VoiceCallCue.outgoingRing
          : VoiceCallCue.incomingRing;
    case VoiceCallState.idle:
    case VoiceCallState.connecting:
      return null;
    case VoiceCallState.connected:
      return prior?.state == VoiceCallState.connecting ||
              prior?.state == VoiceCallState.reconnecting
          ? VoiceCallCue.connected
          : null;
    case VoiceCallState.reconnecting:
      return prior?.state == VoiceCallState.connected
          ? VoiceCallCue.reconnecting
          : null;
    case VoiceCallState.ended:
      if (prior == null || prior.state == VoiceCallState.ended) return null;
      // 'Call ended' is VoiceCallService.end()'s default, used when the
      // caller hangs up. Any other end of an unanswered outgoing call means
      // it did not go through: busy, rejected, unanswered, or failed.
      if (prior.state == VoiceCallState.ringing &&
          next.outgoing &&
          next.failureReason != 'Call ended') {
        return VoiceCallCue.busy;
      }
      return VoiceCallCue.ended;
  }
}

abstract interface class VoiceCallCuePlayer {
  /// Replaces whatever cue is playing.
  Future<void> play(VoiceCallCue cue);
  Future<void> stop();
  Future<void> dispose();
}

class SilentVoiceCallCuePlayer implements VoiceCallCuePlayer {
  const SilentVoiceCallCuePlayer();

  @override
  Future<void> play(VoiceCallCue cue) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// Follows call session changes and plays the matching cues.
class VoiceCallSoundCues {
  VoiceCallSoundCues(this._player, {void Function(Object error)? onError})
    : _onError = onError;

  final VoiceCallCuePlayer _player;
  final void Function(Object error)? _onError;
  Future<void> _queue = Future<void>.value();
  VoiceCallSession? _previous;
  bool _looping = false;
  bool _disposed = false;

  void handle(VoiceCallSession? session) {
    if (_disposed) return;
    final cue = voiceCallCueFor(_previous, session);
    final stillRinging =
        session != null &&
        session.callId == _previous?.callId &&
        session.state == VoiceCallState.ringing;
    _previous = session;
    if (cue != null) {
      _looping = cue.loops;
      _enqueue(() => _player.play(cue));
    } else if (_looping && !stillRinging) {
      _looping = false;
      _enqueue(_player.stop);
    }
  }

  /// Silences any cue, for when the call service is replaced or cleared.
  void reset() {
    if (_disposed) return;
    _previous = null;
    _looping = false;
    _enqueue(_player.stop);
  }

  Future<void> dispose() {
    if (_disposed) return _queue;
    _disposed = true;
    return _enqueue(_player.dispose);
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    // Player calls are serialized so a stop issued after a ring can never
    // overtake the ring's own start.
    return _queue = _queue.then((_) => operation()).catchError((Object error) {
      _onError?.call(error);
    });
  }
}

/// Plays cues through media_kit on desktop and just_audio on Android, using a
/// player separate from voice message playback.
class PlatformVoiceCallCuePlayer implements VoiceCallCuePlayer {
  PlatformVoiceCallCuePlayer({Future<Directory> Function()? cacheDirectory})
    : _cacheDirectory = cacheDirectory ?? getTemporaryDirectory;

  final Future<Directory> Function() _cacheDirectory;
  final Map<VoiceCallCue, String> _paths = {};
  ja.AudioPlayer? _mobilePlayer;
  mk.Player? _desktopPlayer;
  bool _disposed = false;

  static bool get supported =>
      Platform.isAndroid || Platform.isLinux || Platform.isWindows;

  @override
  Future<void> play(VoiceCallCue cue) async {
    if (_disposed) return;
    final path = await _pathFor(cue);
    if (Platform.isAndroid) {
      final player = _mobilePlayer ??= ja.AudioPlayer(
        // Cues must not take audio focus from the call or pause other apps.
        handleAudioSessionActivation: false,
      );
      await player.stop();
      await player.setAndroidAudioAttributes(
        cue == VoiceCallCue.incomingRing
            // The ringtone stream follows the phone's silent and vibrate
            // modes; signalling tones follow the in-call route.
            ? const AndroidAudioAttributes(
                contentType: AndroidAudioContentType.sonification,
                usage: AndroidAudioUsage.notificationRingtone,
              )
            : const AndroidAudioAttributes(
                contentType: AndroidAudioContentType.sonification,
                usage: AndroidAudioUsage.voiceCommunicationSignalling,
              ),
      );
      await player.setLoopMode(cue.loops ? ja.LoopMode.one : ja.LoopMode.off);
      await player.setFilePath(path);
      unawaited(player.play());
      return;
    }
    if (!Platform.isLinux && !Platform.isWindows) return;
    mk.MediaKit.ensureInitialized();
    final player = _desktopPlayer ??= mk.Player();
    await player.setPlaylistMode(
      cue.loops ? mk.PlaylistMode.single : mk.PlaylistMode.none,
    );
    await player.open(mk.Media(path));
  }

  @override
  Future<void> stop() async {
    await _mobilePlayer?.stop();
    await _desktopPlayer?.stop();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final mobile = _mobilePlayer;
    final desktop = _desktopPlayer;
    _mobilePlayer = null;
    _desktopPlayer = null;
    await mobile?.dispose();
    await desktop?.dispose();
  }

  Future<String> _pathFor(VoiceCallCue cue) async {
    final cached = _paths[cue];
    if (cached != null) return cached;
    final bytes = synthesizeVoiceCallCue(cue);
    final directory = Directory(
      '${(await _cacheDirectory()).path}${Platform.pathSeparator}'
      'conest-call-cues',
    );
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      '${cue.name}-v$_voiceCallCueVersion.wav',
    );
    if (!await file.exists() || await file.length() != bytes.length) {
      final partial = File('${file.path}.part');
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(file.path);
    }
    return _paths[cue] = file.path;
  }
}

/// Bump when the synthesized sounds change so cached files are rewritten.
const int _voiceCallCueVersion = 1;
const int voiceCallCueSampleRate = 24000;

/// Renders a cue as a 16-bit mono PCM WAV file.
Uint8List synthesizeVoiceCallCue(VoiceCallCue cue) {
  final cueSound = switch (cue) {
    // A soft three-note chime played twice per three-second cycle.
    VoiceCallCue.incomingRing =>
      _CueSound(3.0)
        ..chime(0.00, 659.25)
        ..chime(0.13, 830.61)
        ..chime(0.26, 987.77)
        ..chime(0.70, 659.25)
        ..chime(0.83, 830.61)
        ..chime(0.96, 987.77),
    // The familiar 425 Hz ringback: one second on, three off.
    VoiceCallCue.outgoingRing => _CueSound(4.0)..tone(0, 1.0, 425),
    VoiceCallCue.connected =>
      _CueSound(0.6)
        ..chime(0.00, 523.25, gain: 0.3)
        ..chime(0.12, 783.99, gain: 0.3),
    VoiceCallCue.ended =>
      _CueSound(0.7)
        ..chime(0.00, 783.99, gain: 0.3)
        ..chime(0.14, 523.25, gain: 0.3),
    VoiceCallCue.busy =>
      _CueSound(2.1)
        ..tone(0.0, 0.35, 425)
        ..tone(0.7, 0.35, 425)
        ..tone(1.4, 0.35, 425),
    VoiceCallCue.reconnecting =>
      _CueSound(0.4)
        ..tone(0.00, 0.09, 392, gain: 0.18)
        ..tone(0.16, 0.09, 392, gain: 0.18),
    VoiceCallCue.muted => _CueSound(
      0.12,
    )..tone(0, 0.09, 880, endHz: 523.25, gain: 0.2),
    VoiceCallCue.unmuted => _CueSound(
      0.12,
    )..tone(0, 0.09, 523.25, endHz: 880, gain: 0.2),
  };
  return cueSound.toWav();
}

class _CueSound {
  _CueSound(double seconds)
    : _samples = Float64List((seconds * voiceCallCueSampleRate).round());

  final Float64List _samples;

  /// A steady tone with short ramps so it starts and stops without clicks.
  /// [endHz] glides the pitch linearly across the tone.
  void tone(
    double start,
    double duration,
    double hz, {
    double? endHz,
    double gain = 0.22,
  }) {
    const ramp = 0.012;
    _render(start, duration, (t, phase) {
      final edge = math.min(t, duration - t);
      final envelope = edge >= ramp ? 1.0 : math.max(edge, 0) / ramp;
      return gain * envelope * math.sin(phase);
    }, (t) => endHz == null ? hz : hz + (endHz - hz) * (t / duration));
  }

  /// A bell-like note: a quick attack, an exponential decay, and a quiet
  /// octave partial for warmth.
  void chime(double start, double hz, {double gain = 0.24}) {
    const duration = 0.45;
    const attack = 0.004;
    _render(start, duration, (t, phase) {
      final envelope = t < attack ? t / attack : math.exp(-(t - attack) * 8);
      final release = math.min(1.0, (duration - t) / 0.02);
      return gain *
          envelope *
          release *
          (math.sin(phase) + 0.25 * math.sin(2 * phase));
    }, (_) => hz);
  }

  void _render(
    double start,
    double duration,
    double Function(double t, double phase) sample,
    double Function(double t) frequency,
  ) {
    final first = (start * voiceCallCueSampleRate).round();
    final count = (duration * voiceCallCueSampleRate).round();
    var phase = 0.0;
    for (var i = 0; i < count && first + i < _samples.length; i++) {
      final t = i / voiceCallCueSampleRate;
      _samples[first + i] += sample(t, phase);
      phase += 2 * math.pi * frequency(t) / voiceCallCueSampleRate;
    }
  }

  Uint8List toWav() {
    const headerBytes = 44;
    final dataBytes = _samples.length * 2;
    final data = ByteData(headerBytes + dataBytes);
    void ascii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        data.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little); // mono
    data.setUint32(24, voiceCallCueSampleRate, Endian.little);
    data.setUint32(28, voiceCallCueSampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, dataBytes, Endian.little);
    for (var i = 0; i < _samples.length; i++) {
      final value = (_samples[i].clamp(-1.0, 1.0) * 32767).round();
      data.setInt16(headerBytes + i * 2, value, Endian.little);
    }
    return data.buffer.asUint8List();
  }
}

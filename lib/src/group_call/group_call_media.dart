import 'dart:typed_data';
import '../platform_bridge.dart';

abstract interface class GroupCallMediaEngine {
  bool get available;
  Future<void> open(String groupId);
  Future<void> setMuted(bool muted);
  Future<void> setNoiseSuppression(bool enabled);
  void setParticipant(int index, bool active);
  void play(int index, int sequence, Uint8List opus);
  double level(int index);
  Future<void> close();
}

class PlatformGroupCallMediaEngine implements GroupCallMediaEngine {
  PlatformGroupCallMediaEngine(this.bridge);
  final PlatformBridge bridge;
  @override
  bool get available => bridge.supportsVoiceCallMedia;
  @override
  Future<void> open(String groupId) async {
    if (!await bridge.openVoiceCallMedia(
      peerDeviceId: 'group:$groupId',
      outgoing: true,
    )) {
      throw StateError('Native group audio is unavailable.');
    }
    bridge.setGroupCallParticipant(0, false);
  }

  @override
  Future<void> setMuted(bool muted) => bridge.setVoiceCallMuted(muted);
  @override
  Future<void> setNoiseSuppression(bool enabled) =>
      bridge.setVoiceCallNoiseSuppression(enabled);
  @override
  void setParticipant(int index, bool active) {
    bridge.setGroupCallParticipant(index, active);
  }

  @override
  void play(int index, int sequence, Uint8List opus) {
    bridge.playGroupCallFrame(index, sequence, opus);
  }

  @override
  double level(int index) => bridge.groupCallParticipantLevel(index);
  @override
  Future<void> close() => bridge.closeVoiceCallMedia();
}

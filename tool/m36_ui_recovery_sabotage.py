"""M36 review/UI negative checks; restores each edit before the next check."""
from pathlib import Path
import re
import subprocess

FLUTTER = '/home/glitch/.local/share/flutter-sdk/bin/flutter'


def check(path, mutation, test, file='test/group_call_recovery_test.dart'):
    path = Path(path)
    original = path.read_text()
    try:
        broken = mutation(original)
        assert broken != original, f'Sabotage anchor changed: {test}'
        path.write_text(broken)
        result = subprocess.run(
            ['rtk', 'proxy', FLUTTER, 'test', '--no-pub', file,
             '--plain-name', test, '--reporter', 'expanded'],
            capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        assert result.returncode != 0 and '[E]' in output and 'Compilation failed' not in output, output
        print(f'PASS negative check: {test}', flush=True)
    finally:
        path.write_text(original)


service = 'lib/src/group_call/group_call_service.dart'
def lose_receive_admission_guard(s):
    split = s.index('final frame = await room.cipher.decrypt(bytes);')
    return s[:split] + s[split:].replace('          !room.connected ||\n', '', 1).replace(
        'p.index == frame.index &&\n            p.version == frame.version', 'true', 1)

check(service, lose_receive_admission_guard,
      'old in-flight audio cannot poison a new admission while its key is pending')
check(service, lambda s: s.replace('_adoptAuthority(room, term, sender);', '', 1),
      'restored asymmetric links converge on one authority and working audio')
check(service, lambda s: s.replace('!room.allParticipants.contains(sender)',
      '!room.participants.any((p) => p.deviceId == sender)', 1),
      'restored full partition reconciles a leader missing from the local roster')
check(service, lambda s: s.replace('if (!room.joined) {', 'if (false && !room.joined) {', 1),
      'unjoined observer expires discovery without electing or tombstoning a live call')
check(service, lambda s: s.replace(
      'idle.epoch = room.coordinator == localDeviceId ? 0 : room.epoch;',
      'idle.epoch = room.epoch;', 1),
      'starter leaves and rejoins in the new authority term without another join')
check(service, lambda s: s.replace('room.holdingToTalk = enabled && held;',
      'room.holdingToTalk = enabled && (held || room.holdingToTalk);', 1),
      'stalled key sends cannot delay mute, PTT release or leave')
check(service, lambda s: s.replace('(payload[0] == 0 && room.microphoneMuted)',
      'false', 1),
      'muting discards audio already waiting for its sender signature')
check(service, lambda s: s.replace('jsonEncode([groupId, callId]);', 'callId;', 1),
      'terminal call identities are scoped to their group')
check(service, lambda s: s.replace('idle.outgoingAudioSequence = room.outgoingAudioSequence;', '', 1),
      'lost leave controls still permit immediate audio after rejoining')
check(service, lambda s: s.replace('p.version == peer.version', 'true', 1),
      'fresh sender admission resets retained receiver jitter state')
check(service, lambda s: s.replace('if (!_startRate.accept(now(), 8))', 'if (false)', 1),
      'start flood limits survive eviction across nine authorized groups')
check(service, lambda s: s.replace("case 'key':\n", "case 'key':\n          _considerAuthority(room, signal);\n", 1),
      'rejected higher-term keys leave current authority and audio intact')
check('lib/src/voice_call_service.dart', lambda s: re.sub(
      r'bool get mediaBusy =>.*?;\n',
      'bool get mediaBusy => _active != null && _active!.state != VoiceCallState.ended;\n',
      s, count=1, flags=re.S),
      '1:1 close retains microphone ownership until teardown completes',
      'test/group_call_media_ownership_test.dart')
controller = 'lib/src/group_call/group_call_controller.dart'
check(controller, lambda s: s.replace('room == null && _voiceCallService?.mediaBusy == true', 'false', 1),
      'empty group ticks preserve a live Android 1:1 foreground call',
      'test/messenger_controller_test.dart')
check(controller, lambda s: s.replace('_groupCallTeardown;','null;',1),
      'repeated group service replacements retain every pending hardware cleanup',
      'test/messenger_controller_test.dart')
ui = 'lib/src/ui/group_call_screen.dart'
check(ui, lambda s: s.replace('onPointerCancel: (_) => _hold(false)',
      'onPointerCancel: (_) {}', 1),
      'group screen controls capture and releases hold on pointer and keyboard',
      'test/group_call_screen_test.dart')
check(ui, lambda s: s.replace('if (event is KeyUpEvent) _hold(false);', '', 1),
      'group screen controls capture and releases hold on pointer and keyboard',
      'test/group_call_screen_test.dart')
check(ui, lambda s: s.replace('await widget.service.leave();', '', 1),
      'Leave closes capture and returns to the chat', 'test/group_call_screen_test.dart')
check(ui, lambda s: s.replace('a.at.compareTo(b.at)', 'b.at.compareTo(a.at)', 1),
      'call summary is chronological and shows starter, duration and participants',
      'test/group_call_screen_test.dart')

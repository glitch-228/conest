"""Negative tests for M36. Edits are restored even if a check fails."""
from pathlib import Path
import re
import subprocess

FLUTTER = '/home/glitch/.local/share/flutter-sdk/bin/flutter'


def check(path, mutation, test, file='test/group_call_test.dart'):
    path = Path(path)
    original = path.read_text()
    try:
        broken = mutation(original)
        assert broken != original, f'Sabotage anchor changed: {test}'
        path.write_text(broken)
        result = subprocess.run(
            ['rtk', 'proxy', FLUTTER, 'test', '--no-pub', file, '--plain-name', test],
            capture_output=True, text=True)
        output = result.stdout + result.stderr
        assert result.returncode != 0 and '[E]' in output and 'Compilation failed' not in output, output
        print(f'PASS negative check: {test}', flush=True)
    finally:
        path.write_text(original)


crypto = 'lib/src/group_call/group_call_crypto.dart'
check(crypto, lambda s: s.replace('if (!await verify(', 'if (false && !await verify(', 1),
      'a different listener cannot forge another sender signature')
check(crypto, lambda s: s[:s.index('  bool canAccept(int n)')] +
      '  bool canAccept(int n) => n > 0;\n' + s[s.index('  bool accept(int n)'):],
      'replay, stale epoch, oversized and over-rate frames are dropped')
check(crypto, lambda s: s.replace('epochGrace = Duration(milliseconds: 250)',
      'epochGrace = Duration(seconds: 250)', 1),
      'replay, stale epoch, oversized and over-rate frames are dropped')
check('lib/src/group_call/group_call_models.dart',
      lambda s: s.replace('return ++_count <= maximum;', 'return true;', 1),
      'replay, stale epoch, oversized and over-rate frames are dropped')
check('lib/src/group_call/group_call_service.dart', lambda s: re.sub(
      r'_member\(signal.groupId, authenticatedSender\)\?\.canJoin\s*!=\s*true',
      'false', s, count=1),
      'non-members, removed members and wrong call signals are refused')
check(crypto, lambda s: s[:s.index('  static Uint8List randomKey()')] +
      '  static Uint8List randomKey() => Uint8List.fromList(List.filled(32, 7));\n\n' +
      s[s.index('  Future<void> install('):],
      'leaving rotates key; leaver cannot decrypt future frames')
check(crypto, lambda s: s[:s.index('  static Uint8List randomKey()')] +
      '  static Uint8List randomKey() => Uint8List.fromList(List.filled(32, 7));\n\n' +
      s[s.index('  Future<void> install('):],
      'new joiner cannot decrypt pre-join frames')
check('lib/src/messenger_controller.dart', lambda s: s.replace(
      '      featureCapabilities: profile.featureCapabilities,\n'
      '      featureCapabilityVersion: profile.featureCapabilityVersion,\n', '', 1),
      'group-only members join encrypted voice calls over Iroh',
      'test/messenger_controller_test.dart')

check('lib/src/group_call/group_call_topology.dart',
      lambda s: s.replace('return candidates.first;', 'return candidates.last;', 1),
      'election preference and tie break are deterministic', 'test/group_call_topology_test.dart')
check('lib/src/group_call/group_call_service.dart',
      lambda s: s.replace('if (forwarding && authenticatedSender == frame.sender)',
      'if (false && forwarding && authenticatedSender == frame.sender)', 1),
      'seven participants agree on one forwarder and hear every sender', 'test/group_call_topology_test.dart')
check('lib/src/group_call/group_call_service.dart',
      lambda s: s.replace('? 1500', '? 15000', 1),
      'dropped forwarder is replaced within two seconds with lasting audio', 'test/group_call_topology_test.dart')
check('lib/src/group_call/group_call_service.dart',
      lambda s: s.replace('now().difference(room.poorSince!) >= const Duration(seconds: 3)', 'now().difference(room.poorSince!) >= const Duration(seconds: 300)', 1),
      'poor mesh links held for three seconds select a forwarder', 'test/group_call_topology_test.dart')

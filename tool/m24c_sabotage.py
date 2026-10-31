#!/usr/bin/env python3
"""Prove M24c regressions fail when individual guards are removed.

Runs only Dart tests, restores every mutation in finally, and records logs in
/tmp. Do not run concurrently with tests reading the same source files.
"""
from pathlib import Path
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FLUTTER = '/home/glitch/.local/share/flutter-sdk/bin/flutter'
UNIT = 'test/delta_leftovers_test.dart'
QUEUE = 'test/delta_download_queue_test.dart'
CONTROLLER = 'test/messenger_controller_test.dart'
CASES = []

def case(name, path, old, new, test, title):
    CASES.append((name, path, old, new, test, title))

case('metered-download', 'lib/src/delta_downloads_controller.dart',
     'if (!deltaChatEnabled || size <= 64 * 1024) return false;',
     'if (true) return false;', CONTROLLER,
     'Delta metered file waits behind Download')
case('one-save-per-batch', 'lib/src/email_carrier.dart', 'count < 20', 'count < 1',
     CONTROLLER, 'Delta fetch batch of twenty mails writes the vault once')
case('cache-cap', 'lib/src/email/delta_cache.dart',
     'var projected = _bytes - (previous?.size ?? 0) + size;', 'var projected = 0;',
     UNIT, 'Delta cache cap evicts least recently used')
case('parser-isolate', 'lib/src/email/delta_mail.dart',
     ') => Isolate.run(\n  () => DeltaMail._read', ') => Future.sync(\n  () => DeltaMail._read',
     UNIT, 'Delta 20 MiB mail is parsed and decrypted outside the UI isolate')
case('lazy-startup-avatars', 'lib/src/delta_avatar_store.dart',
     "stored = DeltaStoredAvatar(row!['avatar'] as String, budget);",
     "stored = DeltaStoredAvatar(row!['avatar'] as String, budget); stored.bytes;",
     UNIT, 'Delta startup and unchanged saves never decode avatars')
case('reused-message-json', 'lib/src/delta_chats.dart',
     "Map<String, dynamic> toJson() => _deltaJson[this] ??= {\n    'id': id,\n    'author': author,\n    'text': text,",
     "Map<String, dynamic> toJson() => {\n    'id': id,\n    'author': author,\n    'text': text,", UNIT, 'Delta saves reuse unchanged message JSON')
case('protected-identity', 'lib/src/email/delta_mail.dart',
     'content.headers.raw(name).length != 1', 'false', UNIT,
     'Delta protected identity cannot be supplied by unsigned outer headers')
case('duplicate-control-headers', 'lib/src/email/delta_mail.dart',
     'if (!seen.add(key)) return false;', 'seen.add(key);', UNIT,
     'Delta duplicate control headers and Autocrypt attributes are rejected')
case('autocrypt-attributes', 'lib/src/email/delta_mail.dart',
     'if (!seen.add(name)) return null;', 'seen.add(name);', UNIT,
     'Delta duplicate control headers and Autocrypt attributes are rejected')
case('autocrypt-size', 'lib/src/email/delta_mail.dart',
     'value.length > ((maxKeyBytes + 2) ~/ 3) * 4 + 1024', 'false', UNIT,
     'Delta duplicate control headers and Autocrypt attributes are rejected')
case('mime-header-names', 'lib/src/email/mime.dart',
     '.hasMatch(name!)', ".hasMatch('valid')", UNIT,
     'Delta MIME rejects invalid header names and oversized boundaries')
case('mime-boundary', 'lib/src/email/mime.dart',
     'boundary.length > 70', 'boundary.length > 700', UNIT,
     'Delta MIME rejects invalid header names and oversized boundaries')
case('invite-length', 'lib/src/delta_protocol.dart',
     'if (text.length > 8192) return null;', '', UNIT,
     'Delta invite and persisted token inputs have bounded counts and lengths')
case('token-count', 'lib/src/delta_protocol.dart',
     'groups.entries.take(maxGroups)', 'groups.entries', UNIT,
     'Delta invite and persisted token inputs have bounded counts and lengths')
case('token-length', 'lib/src/delta_protocol.dart',
     '!DeltaInvite._validToken(auth)', 'false', UNIT,
     'Delta invite and persisted token inputs have bounded counts and lengths')
case('overflow-progress', 'lib/src/email_carrier.dart',
     'overflow = oldest(overflow, uid);', 'return false;', QUEUE,
     'Delta full deferred list preserves overflow UIDs and delivers later mail')
case('bounded-mail-retries', 'lib/src/email_carrier.dart',
     'attempts >= maxOtherMailAttempts', 'false', QUEUE,
     'Delta unsavable mail is parked after bounded retries')
case('partial-headers', 'lib/src/email/imap.dart',
     '<0.16384>', '', QUEUE,
     'Delta optional malformed and long headers cannot block or lose a deferred UID')
case('carrier-probe', 'lib/src/email_carrier.dart',
     'prefix != null && hasCarrierPacketPrefix(prefix)', 'false', QUEUE,
     'Delta enabled preserves large Conest carrier delivery on metered links')
case('download-wake', 'lib/src/email_carrier.dart',
     '_requestedDownloads.isNotEmpty ||', '', QUEUE,
     'Delta Download queued during an active fetch runs before IDLE')
case('pruned-cache-references', 'lib/src/delta_attachments_controller.dart',
     "!r.attachmentId.startsWith('delta:') ||\n            _deltaDescriptorIndex.containsKey(r.attachmentId)", 'true', CONTROLLER,
     'Delta deleting a chat prunes its persisted cache references')
case('access-updates-lru', 'lib/src/messenger_controller.dart',
     "'delta-${attachmentStorageKey('sha256:$hash')}',\n        _now().toUtc(),",
     "attachmentStorageKey('sha256:$hash'),\n        _now().toUtc(),", CONTROLLER,
     'Delta opening a cached file updates the LRU used by admission')
case('bounded-deferred-hints', 'lib/src/email/delta_download.dart',
     "text.length <= limit ? text : ''", 'text', QUEUE,
     'Delta optional malformed and long headers cannot block or lose a deferred UID')
case('lazy-avatar-expansion', 'lib/src/email/delta_avatar.dart',
     'maxEncodedBytes: _encoded.length', 'maxEncodedBytes: maxDeltaAvatarEncodedBytes', UNIT,
     'Delta lazy avatars never expand the size admitted before later mutations')
case('pinned-legacy-cache', 'lib/src/email/delta_cache.dart',
     'if (name.isEmpty) return;', '', UNIT,
     'Delta legacy pinned caches remain readable while new admissions obey the cap')
case('actual-file-policy', 'lib/src/delta_downloads_controller.dart',
     'return read.files.every(', 'return true || read.files.every(', CONTROLLER,
     'Delta custom preset defers even tiny authenticated files on unmetered links')
case('linear-uid-discovery', 'lib/src/email_carrier.dart',
     'offset = batchStart;', 'return _readNewBatch(client, generation);', QUEUE,
     'Delta parking each batch reuses its UID discovery work')
case('legacy-migration-fallback', 'lib/src/messenger_controller.dart',
     'if (await previous.exists()) return previous;', '', CONTROLLER,
     'Delta legacy cache migration preserves files shared with archived chats on a full disk')

case('archive-cache-ownership', 'lib/src/delta_attachments_controller.dart',
     "          for (final message in _archivedMessages)\n            if (message.attachment != null)\n              attachmentStorageKey(\n                'sha256:${message.attachment!.fileHashBase64}',\n              ),\n", '', CONTROLLER,
     'Delta legacy cache migration preserves files shared with archived chats')
case('migration-storage-admission', 'lib/src/delta_attachments_controller.dart',
     'if (!_canAllocateStorage(capacity, size)) continue;', '', CONTROLLER,
     'Delta legacy cache migration preserves files shared with archived chats on a full disk')
case('uid-namespace-reset', 'lib/src/email_carrier.dart',
     'deferred: const [],', 'deferred: _config.deferred,', 'test/email_carrier_test.dart',
     'Delta UIDVALIDITY resets clear durable deferred mail before fetching')


def main():
    selected = set(sys.argv[1:]) - {'--resume'}
    result_file = Path('/tmp/m24c-sabotage-results.json')
    results = json.loads(result_file.read_text()) if result_file.exists() else []
    for name, relative, old, new, test, title in CASES:
        if selected and name not in selected:
            continue
        if '--resume' in sys.argv and any(row['name'] == name for row in results):
            continue
        path = ROOT / relative
        original = path.read_text()
        if old not in original:
            raise RuntimeError(f'{name}: mutation target missing')
        log = Path(f'/tmp/m24c-sabotage-{name}.log')
        try:
            path.write_text(original.replace(old, new, 1))
            with log.open('w') as output:
                completed = subprocess.run(['rtk', 'proxy', FLUTTER, 'test', '--no-pub', test,
                    '--plain-name', title, '--reporter', 'expanded'], cwd=ROOT,
                    stdout=output, stderr=subprocess.STDOUT, timeout=90)
            content = log.read_text()
            if completed.returncode == 0:
                raise AssertionError(f'{name}: sabotage survived')
            if 'Compilation failed' in content or 'Failed to load' in content:
                raise AssertionError(f'{name}: failed to compile instead of detecting the regression')
            if 'Some tests failed' not in content:
                raise AssertionError(f'{name}: expected an assertion/test failure; inspect {log}')
            results = [row for row in results if row['name'] != name]
            results.append({'name': name, 'detected': True, 'log': str(log)})
            result_file.write_text(json.dumps(results, indent=2) + '\n')
            print(f'{name}: detected; original restored', flush=True)
        finally:
            path.write_text(original)
    Path('/tmp/m24c-sabotage-results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(f'{len(results)} sabotage checks detected their regressions', flush=True)

if __name__ == '__main__':
    main()

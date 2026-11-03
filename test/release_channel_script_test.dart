// CI check for the release pipeline: the one rule that maps a tag to its
// channel (tool/release_channel.sh), the guards on tags, what release.yml
// does with them, and the signing tools end to end.
import 'dart:convert';
import 'dart:io';

import 'package:conest/src/release_order.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _today = '20261103';

Future<ProcessResult> _channel(
  String tag, {
  List<String> tags = const [],
  List<String> extra = const [],
}) async {
  final dir = await Directory.systemTemp.createTemp('conest-tags-');
  addTearDown(() => dir.delete(recursive: true));
  final file = File(p.join(dir.path, 'tags.txt'))
    ..writeAsStringSync('${tags.join('\n')}\n');
  return Process.run('bash', [
    'tool/release_channel.sh',
    '--tags-file',
    file.path,
    '--today',
    _today,
    ...extra,
    tag,
  ]);
}

Map<String, String> _fields(ProcessResult result) => {
  for (final line in (result.stdout as String).split('\n'))
    if (line.contains('='))
      line.substring(0, line.indexOf('=')): line.substring(
        line.indexOf('=') + 1,
      ),
};

String? _dart() {
  final root = Platform.environment['FLUTTER_ROOT'];
  for (final candidate in [
    if (root != null) p.join(root, 'bin', 'cache', 'dart-sdk', 'bin', 'dart'),
    p.join(
      Platform.environment['HOME'] ?? '',
      '.local/share/flutter-sdk/bin/cache/dart-sdk/bin/dart',
    ),
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

void main() {
  final hasBash = !Platform.isWindows;

  group('tool/release_channel.sh', () {
    test('maps tags to channels', () async {
      for (final (tag, channel, pre) in [
        ('v0.4.3-canary.20261103.1', 'canary', 'true'),
        ('v0.4.4-canary.20261103.12', 'canary', 'true'),
        ('v0.4.3-nightly.20261029.1', 'nightly', 'true'),
        ('v0.4.3-rc.1', 'nightly', 'true'),
        ('v0.4.3', 'stable', 'false'),
      ]) {
        final result = await _channel(tag);
        expect(result.exitCode, 0, reason: '$tag ${result.stderr}');
        expect(_fields(result)['channel'], channel, reason: tag);
        expect(_fields(result)['prerelease'], pre, reason: tag);
      }
    }, skip: !hasBash);

    test('refuses malformed canary tags', () async {
      for (final tag in [
        'v0.4.3-canary.1',
        'v0.4.3-canary.20261103',
        'v0.4.3-canary.20261103.1-debug',
        'v0.4.3-canary-nightly.20261103.1',
        'v0.4.3-nightly-canary.20261103.1',
        'v0.4.3-Canary.20261103.1',
        'v0.4.3-canary.20261103.100',
        'v0.4.3-canary.20261331.1',
        'v0.4.3-canary.20260230.1',
        'v0.4.3-canary.20251231.1',
        'v0.4.3-canary.20261103.1+7',
      ]) {
        expect((await _channel(tag)).exitCode, isNot(0), reason: tag);
      }
    }, skip: !hasBash);

    test(
      'guards: date in the future, before the previous canary, stable exists, core lower',
      () async {
        const tags = [
          'v0.4.2',
          'v0.4.3-nightly.20261030.1',
          'v0.4.3-canary.20261102.1',
        ];
        Future<bool> allowed(String tag) async =>
            (await _channel(tag, tags: tags)).exitCode == 0;

        expect(await allowed('v0.4.3-canary.20261102.2'), isTrue);
        expect(await allowed('v0.4.3-canary.20261103.1'), isTrue);
        expect(await allowed('v0.4.4-canary.20261103.1'), isTrue);
        // Later than today (UTC+1).
        expect(await allowed('v0.4.3-canary.20261104.1'), isFalse);
        expect(await allowed('v0.4.3-nightly.20261104.1'), isFalse);
        // Before the previous canary's date.
        expect(await allowed('v0.4.3-canary.20261101.9'), isFalse);
        // A stable of the same core exists.
        expect(await allowed('v0.4.2-canary.20261103.1'), isFalse);
        expect(await allowed('v0.4.2-nightly.20261103.1'), isFalse);
        // A canary core below the newest nightly core.
        expect(await allowed('v0.4.1-canary.20261103.1'), isFalse);
        // Not a guard for stable tags, or for the tag being re-run.
        expect(await allowed('v0.4.3'), isTrue);
        expect(
          (await _channel('v0.4.3-canary.20261102.1', tags: tags)).exitCode,
          0,
        );
        // The manifest tools only classify: no history, no clock.
        expect(
          (await _channel(
            'v0.4.3-canary.20261104.1',
            tags: tags,
            extra: ['--classify-only'],
          )).exitCode,
          0,
        );
      },
      skip: !hasBash,
    );

    test(
      'Android version codes follow the release order and only grow',
      () async {
        Future<int> code(String tag) async {
          final result = await _channel(tag);
          expect(result.exitCode, 0, reason: '$tag ${result.stderr}');
          return int.parse(_fields(result)['version_code']!);
        }

        // Same core: the code order is the updater's order.
        final tags = [
          'v0.4.3-nightly.20261029.1',
          'v0.4.3-nightly.20261029.2',
          'v0.4.3-canary.20261029.1',
          'v0.4.3-nightly.20261030.1',
          'v0.4.3-canary.20261030.1',
          'v0.4.3-canary.20261030.2',
          'v0.4.3-canary.20261103.1',
          'v0.4.3',
        ];
        final ids = [for (final t in tags) classifyRelease(t)!];
        final codes = [for (final t in tags) await code(t)];
        for (var a = 0; a < tags.length; a++) {
          for (var b = 0; b < tags.length; b++) {
            if (ids[a].compareTo(ids[b]) > 0) {
              expect(
                codes[a],
                greaterThan(codes[b]),
                reason: '${tags[a]} ${tags[b]}',
              );
            }
          }
        }
        // Above the +59 builds of today, and a stable above its nightlies.
        expect(codes.first, greaterThan(59));
        expect(await code('v0.4.3-canary.20261103.1'), 306201);
        expect(await code('v0.4.3-nightly.20261103.1'), 306101);
      },
      skip: !hasBash,
    );
  });

  group('release.yml', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();

    test('takes the channel from the script, and nowhere else', () {
      expect(workflow, contains('tool/release_channel.sh'));
      expect(workflow, isNot(contains('case "\$lowered"')));
      expect(workflow, contains('version_code='));
      expect(
        RegExp(
          r'--build-number=\$\{\{ needs\.prepare\.outputs\.version_code \}\}',
        ).hasMatch(workflow),
        isTrue,
      );
    });

    test('passes the same channel to the builds and to both signing tools', () {
      expect(
        'CONEST_BUILD_CHANNEL=\${{ needs.prepare.outputs.channel }}'.allMatches(
          workflow,
        ),
        hasLength(3),
      );
      for (final tool in ['release_manifest', 'verify_release_manifest']) {
        final at = workflow.indexOf('tool/$tool.dart');
        expect(at, greaterThan(0), reason: tool);
        expect(
          workflow.substring(at, at + 300),
          contains('--channel "\${{ needs.prepare.outputs.channel }}"'),
          reason: tool,
        );
      }
      expect(workflow, contains('--android-version-code'));
    });

    test('a canary release has only the canary pair, and is never latest', () {
      final canaryStep = workflow.substring(
        workflow.indexOf('name: Create GitHub canary release'),
        workflow.indexOf('name: Prune old canary releases'),
      );
      final otherStep = workflow.substring(
        workflow.indexOf('name: Create GitHub release'),
        workflow.indexOf('name: Create GitHub canary release'),
      );
      expect(canaryStep, contains('dist/RELEASE-MANIFEST.canary.json'));
      expect(canaryStep, contains('dist/RELEASE-MANIFEST.canary.ed25519.sig'));
      expect(canaryStep, isNot(contains('dist/RELEASE-MANIFEST.json')));
      expect(canaryStep, isNot(contains('dist/RELEASE-MANIFEST.ed25519.sig')));
      expect(canaryStep, contains("make_latest: 'false'"));
      expect(canaryStep, contains('prerelease: true'));
      expect(otherStep, contains('dist/RELEASE-MANIFEST.json'));
      expect(otherStep, isNot(contains('canary.json')));
      expect(
        otherStep,
        contains(
          "make_latest: \${{ needs.prepare.outputs.channel == 'stable' && 'true' || 'false' }}",
        ),
      );
      expect(
        workflow,
        contains("if: \${{ needs.prepare.outputs.channel == 'canary' }}"),
      );
    });

    test(
      'release notes compare a canary with canaries and the others never',
      () {
        expect(workflow, contains("--match 'v*-canary.*'"));
        expect(workflow, contains("--exclude 'v*-canary.*'"));
        // Both ways the notes are written name the files of the channel.
        expect(workflow, contains('RELEASE-MANIFEST.canary.json'));
        expect(workflow, contains(r'covered by \`$manifest_name\`'));
      },
    );

    test('pruning keeps ten canaries and every tag', () {
      final prune = workflow.substring(
        workflow.indexOf('name: Prune old canary releases'),
      );
      expect(prune, contains('keep=10'));
      expect(prune, isNot(contains('--cleanup-tag')));
      expect(prune, contains('-canary'));
      expect(prune, contains('continue-on-error: true'));
    });
  });

  group('signing tools', () {
    final dart = _dart();
    final skip = dart == null || !hasBash ? 'no dart/bash found' : null;

    Future<ProcessResult> run(List<String> args, {Map<String, String>? env}) =>
        Process.run(dart!, ['run', ...args], environment: env);

    Future<(Directory, Map<String, String>)> dist(
      String tag, {
      List<String> extraFiles = const [],
    }) async {
      final dir = await Directory.systemTemp.createTemp('conest-dist-');
      addTearDown(() => dir.delete(recursive: true));
      File(
        p.join(dir.path, 'conest-linux-x64-$tag.zip'),
      ).writeAsBytesSync([1, 2, 3]);
      for (final name in extraFiles) {
        File(p.join(dir.path, name)).writeAsStringSync('x');
      }
      return (
        dir,
        {
          'CONEST_RELEASE_MANIFEST_PRIVATE_KEY': base64Encode(
            List.filled(32, 7),
          ),
        },
      );
    }

    String publicKey(ProcessResult result) => RegExp(
      r'CONEST_RELEASE_MANIFEST_PUBLIC_KEY=(\S+)',
    ).firstMatch(result.stdout as String)!.group(1)!;

    test(
      'a canary is signed as canary with its own file names',
      () async {
        const tag = 'v0.4.3-canary.20261103.1';
        final (dir, env) = await dist(tag);
        final signed = await run([
          'tool/release_manifest.dart',
          '--dist',
          dir.path,
          '--channel',
          'canary',
          '--android-version-code',
          '306201',
          tag,
        ], env: env);
        expect(signed.exitCode, 0, reason: '${signed.stderr}');
        final names = dir.listSync().map((e) => p.basename(e.path)).toSet();
        expect(
          names,
          containsAll([
            'RELEASE-MANIFEST.canary.json',
            'RELEASE-MANIFEST.canary.ed25519.sig',
          ]),
        );
        expect(names, isNot(contains('RELEASE-MANIFEST.json')));
        expect(names, isNot(contains('RELEASE-MANIFEST.ed25519.sig')));
        final manifest =
            jsonDecode(
                  File(
                    p.join(dir.path, 'RELEASE-MANIFEST.canary.json'),
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(manifest['channel'], 'canary');
        expect(manifest['tagName'], tag);
        expect(manifest['androidVersionCode'], 306201);
        // The sums do not list the metadata of another channel.
        final sums = File(
          p.join(dir.path, 'SHA256SUMS.txt'),
        ).readAsStringSync();
        expect(sums, isNot(contains('RELEASE-MANIFEST.json')));

        final key = publicKey(signed);
        final ok = await run([
          'tool/verify_release_manifest.dart',
          '--dist',
          dir.path,
          '--channel',
          'canary',
          '--public-key',
          key,
        ]);
        expect(ok.exitCode, 0, reason: '${ok.stderr}');
        // Verified as another channel it is refused.
        for (final other in ['nightly', 'stable']) {
          final bad = await run([
            'tool/verify_release_manifest.dart',
            '--dist',
            dir.path,
            '--channel',
            other,
            '--public-key',
            key,
          ]);
          expect(bad.exitCode, isNot(0), reason: other);
        }
      },
      skip: skip,
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'stable and nightly keep the standard names',
      () async {
        for (final (tag, channel) in [
          ('v0.4.2', 'stable'),
          ('v0.4.3-nightly.20261029.1', 'nightly'),
        ]) {
          final (dir, env) = await dist(tag);
          final signed = await run([
            'tool/release_manifest.dart',
            '--dist',
            dir.path,
            '--channel',
            channel,
            tag,
          ], env: env);
          expect(signed.exitCode, 0, reason: '${signed.stderr}');
          final names = dir.listSync().map((e) => p.basename(e.path)).toSet();
          expect(
            names,
            containsAll([
              'RELEASE-MANIFEST.json',
              'RELEASE-MANIFEST.ed25519.sig',
            ]),
          );
          expect(names.any((n) => n.contains('.canary.')), isFalse);
          final ok = await run([
            'tool/verify_release_manifest.dart',
            '--dist',
            dir.path,
            '--channel',
            channel,
            '--public-key',
            publicKey(signed),
          ]);
          expect(ok.exitCode, 0, reason: '${ok.stderr}');
        }
      },
      skip: skip,
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'the channel must be the tag\'s own, for every channel',
      () async {
        for (final (tag, channel) in [
          ('v0.4.3-canary.20261103.1', 'nightly'),
          ('v0.4.3-canary.20261103.1', 'stable'),
          ('v0.4.3-nightly.20261029.1', 'canary'),
          ('v0.4.3-nightly.20261029.1', 'stable'),
          ('v0.4.2', 'canary'),
          ('v0.4.2', 'nightly'),
          ('v0.4.3-canary.1', 'canary'),
          ('v0.4.2', 'weekly'),
        ]) {
          final (dir, env) = await dist(tag);
          final signed = await run([
            'tool/release_manifest.dart',
            '--dist',
            dir.path,
            '--channel',
            channel,
            tag,
          ], env: env);
          expect(signed.exitCode, isNot(0), reason: '$tag as $channel');
          expect(
            dir.listSync().where(
              (e) => p.basename(e.path).startsWith('RELEASE-MANIFEST'),
            ),
            isEmpty,
            reason: '$tag as $channel',
          );
        }
        // No channel at all: no guessing from the tag.
        final (dir, env) = await dist('v0.4.2');
        final bare = await run([
          'tool/release_manifest.dart',
          '--dist',
          dir.path,
          'v0.4.2',
        ], env: env);
        expect(bare.exitCode, isNot(0));
      },
      skip: skip,
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'a canary dist holding the standard pair is refused',
      () async {
        const tag = 'v0.4.3-canary.20261103.1';
        final (dir, env) = await dist(
          tag,
          extraFiles: ['RELEASE-MANIFEST.json'],
        );
        final signed = await run([
          'tool/release_manifest.dart',
          '--dist',
          dir.path,
          '--channel',
          'canary',
          tag,
        ], env: env);
        expect(signed.exitCode, isNot(0));
      },
      skip: skip,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

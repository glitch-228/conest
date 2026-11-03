import 'package:conest/src/build_info.dart';
import 'package:conest/src/release_order.dart';
import 'package:flutter_test/flutter_test.dart';

ReleaseId id(String tag, {bool? pre}) => classifyRelease(
  tag,
  prerelease: pre ?? !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag),
)!;

void main() {
  group('classifyRelease', () {
    test('understands the three lines', () {
      expect(id('v0.4.2').line, ReleaseLine.stable);
      expect(id('v0.4.3-nightly.20261029.1').line, ReleaseLine.nightly);
      expect(id('v0.4.3-canary.20261030.2').line, ReleaseLine.canary);
      expect(id('v0.1.0-nightly.20260417.1').line, ReleaseLine.nightly);
    });

    test('refuses what is not one of them, or lies about its flag', () {
      for (final (tag, pre) in [
        ('v0.4.3-rc.1', true),
        ('v0.1.0-beta.20260417', true),
        ('v0.4.3-alpha', true),
        ('garbage', false),
        ('', false),
        ('v0.4.2', true), // stable-looking, flagged pre-release
        ('v0.4.3-nightly.20261029.1', false), // nightly flagged stable
        ('v0.4.3-canary.20261030.1', false), // canary flagged stable
        ('v0.4.3-canary.1', true), // old plan format
        ('v0.4.3-canary.20261030', true), // no counter
        ('v0.4.3-canary.20261030.1-debug', true),
        ('v0.4.3-canary.20261331.1', true), // not a date
        ('v0.4.3-canary.20250101.1', true), // before the project
        ('v0.4.3-canary-nightly.20261030.1', true),
        ('v0.4.3-nightly-canary.20261030.1', true),
        ('v0.4.3-nightly.canary.20261030.1', true),
        ('v0.4.3-nightly.20261399.1', true), // 8 digits, not a date
        ('v0.4.3-nightly.x.1', true),
        ('v0.4.3-nightly.20261029.1.5', true),
        ('v0.4.3-canary.20261030.1+7', true),
        ('v0.4.3+7', false),
      ]) {
        expect(classifyRelease(tag, prerelease: pre), isNull, reason: tag);
      }
    });

    test('an installed identity needs no flag and may lack the v', () {
      expect(classifyRelease('0.4.3')?.line, ReleaseLine.stable);
      expect(
        classifyRelease('v0.4.3-canary.20261030.1')?.line,
        ReleaseLine.canary,
      );
      expect(classifyRelease('debug-42'), isNull);
    });
  });

  group('order', () {
    int cmp(String a, String b) => id(a).compareTo(id(b));

    test('the core decides first, then stable above its pre-releases', () {
      expect(cmp('v0.4.4-canary.20260101.1', 'v0.4.3'), greaterThan(0));
      expect(cmp('v0.4.3', 'v0.4.3-nightly.20261030.1'), greaterThan(0));
      expect(cmp('v0.4.3', 'v0.4.3-canary.20261103.9'), greaterThan(0));
      expect(cmp('v0.4.3', 'v0.4.2'), greaterThan(0));
    });

    test('canary and nightly of one core go by date, then canary wins', () {
      expect(
        cmp('v0.4.3-canary.20261030.1', 'v0.4.3-nightly.20261029.5'),
        greaterThan(0),
      );
      expect(
        cmp('v0.4.3-nightly.20261031.1', 'v0.4.3-canary.20261030.9'),
        greaterThan(0),
      );
      // Same day: canary wins whatever the counters say.
      expect(
        cmp('v0.4.3-canary.20261030.1', 'v0.4.3-nightly.20261030.9'),
        greaterThan(0),
      );
      expect(
        cmp('v0.4.3-nightly.20261030.9', 'v0.4.3-canary.20261030.1'),
        lessThan(0),
      );
    });

    test('inside a line it is the semver order', () {
      expect(
        cmp('v0.4.3-nightly.20261030.2', 'v0.4.3-nightly.20261030.1'),
        greaterThan(0),
      );
      expect(
        cmp('v0.4.3-nightly.20261101.1', 'v0.4.3-nightly.20261030.9'),
        greaterThan(0),
      );
      expect(
        cmp('v0.4.3-canary.20261030.10', 'v0.4.3-canary.20261030.9'),
        greaterThan(0),
      );
      expect(cmp('v0.4.3', 'v0.4.3'), 0);
    });

    test('is a strict weak order over many tags (no cycles)', () {
      final tags = <String>[
        for (final core in ['0.4.2', '0.4.3', '0.5.0'])
          for (final date in [20261029, 20261030, 20261103])
            for (final n in [1, 2, 10]) ...[
              'v$core-nightly.$date.$n',
              'v$core-canary.$date.$n',
            ],
        'v0.4.2',
        'v0.4.3',
        'v0.5.0',
        'v0.4.3-nightly.20261030',
        'v0.4.3-nightly.11',
      ];
      final ids = [for (final tag in tags) id(tag)];
      for (final a in ids) {
        expect(a.compareTo(a), 0);
        for (final b in ids) {
          expect(a.compareTo(b).sign, -b.compareTo(a).sign, reason: '$a vs $b');
          for (final c in ids) {
            if (a.compareTo(b) <= 0 && b.compareTo(c) <= 0) {
              expect(a.compareTo(c), lessThanOrEqualTo(0), reason: '$a $b $c');
            }
          }
        }
      }
    });
  });

  group('lines', () {
    test('a newer line also takes the older lines, never the reverse', () {
      expect(ReleaseLine.stable.offered, {ReleaseLine.stable});
      expect(ReleaseLine.nightly.offered, {
        ReleaseLine.stable,
        ReleaseLine.nightly,
      });
      expect(ReleaseLine.canary.offered, ReleaseLine.values.toSet());
      expect(ReleaseLine.ofChannel(UpdateChannel.debug), isNull);
      expect(ReleaseLine.ofChannel(UpdateChannel.canary), ReleaseLine.canary);
    });

    final releases = [
      ('v0.4.2', false),
      ('v0.4.3-nightly.20261029.1', true),
      ('v0.4.3-canary.20261030.1', true),
      ('v0.4.3-rc.1', true),
    ];
    String? pick(ReleaseLine line, [List<(String, bool)>? list]) =>
        chooseRelease<(String, bool)>(
          list ?? releases,
          line,
          describe: (r) =>
              ReleaseCandidate(tagName: r.$1, prerelease: r.$2, draft: false),
        )?.$1.$1;

    test('each line picks its newest allowed release', () {
      expect(pick(ReleaseLine.stable), 'v0.4.2');
      expect(pick(ReleaseLine.nightly), 'v0.4.3-nightly.20261029.1');
      expect(pick(ReleaseLine.canary), 'v0.4.3-canary.20261030.1');
      // A newer nightly beats an older canary for a canary follower.
      expect(
        pick(ReleaseLine.canary, [
          ('v0.4.3-canary.20261030.1', true),
          ('v0.4.3-nightly.20261031.1', true),
        ]),
        'v0.4.3-nightly.20261031.1',
      );
    });

    test('a draft is never chosen', () {
      expect(
        chooseRelease<int>(
          [1],
          ReleaseLine.canary,
          describe: (_) => const ReleaseCandidate(
            tagName: 'v0.4.3-canary.20261030.1',
            prerelease: true,
            draft: true,
          ),
        ),
        isNull,
      );
    });

    test('newer than the installed build, never equal or older', () {
      final canary = id('v0.4.3-canary.20261030.1');
      expect(isNewerThanInstalled(canary, 'v0.4.3-canary.20261030.1'), isFalse);
      expect(isNewerThanInstalled(canary, 'v0.4.3-canary.20261031.1'), isFalse);
      expect(isNewerThanInstalled(canary, 'v0.4.3-canary.20261029.4'), isTrue);
      expect(isNewerThanInstalled(canary, 'debug-1'), isFalse);
      expect(isNewerThanInstalled(id('v0.4.3'), '0.4.3'), isFalse);
    });
  });
}

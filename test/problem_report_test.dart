import 'dart:io';

import 'package:conest/src/build_info.dart';
import 'package:conest/src/crash_catcher.dart';
import 'package:conest/src/problem_report.dart';
import 'package:conest/src/problem_report_sources.dart';
import 'package:flutter_test/flutter_test.dart';

// A fixed clock: nothing here reads the real one.
final _t = DateTime.utc(2026, 11, 3, 12);

ProblemReportInputs _inputs({
  List<ReportError> errors = const [],
  List<ReportCrash> crashes = const [],
  List<String> deny = const [],
  List<ReportTransportLine> transports = const [],
  bool errorsAvailable = true,
  bool transportsAvailable = true,
}) => ProblemReportInputs(
  generatedAt: _t,
  appVersion: '0.4.3',
  buildNumber: '306201',
  buildTag: 'v0.4.3-canary.20261103.1',
  commit: 'abc1234',
  channel: 'canary',
  updateChannel: 'nightly',
  platform: 'android Linux 5.10',
  errors: errors,
  crashes: crashes,
  denyList: deny,
  transports: transports,
  errorHistoryAvailable: errorsAvailable,
  transportsAvailable: transportsAvailable,
);

void main() {
  group('redactReportText', () {
    String r(String text, {List<String> deny = const []}) =>
        redactReportText(text, denyList: deny);

    test('replaces listed names, whole words and any case', () {
      expect(
        r(
          'Route test to Alice Smith failed; alice smith again',
          deny: ['Alice Smith'],
        ),
        'Route test to [name] failed; [name] again',
      );
      // Not inside another word.
      expect(r('Bobcat vs Bob', deny: ['Bob']), 'Bobcat vs [name]');
      // Regex characters in a name are plain text.
      expect(r('to a.b+c(d', deny: ['a.b+c(d']), 'to [name]');
      expect(r('x', deny: ['']), 'x');
    });

    test('masks tokens, keys and secrets', () {
      const key = 'AbCdEfGhIjKlMnOpQrStUvWx0123456789+/=';
      expect(r('key $key end'), isNot(contains('AbCdEf')));
      expect(r('hex ${'ab12' * 12}'), isNot(contains('ab12ab12')));
      expect(
        r('Authorization: Bearer abc.def.ghi'),
        isNot(contains('abc.def')),
      );
      expect(r('access_token=syt_verysecret'), isNot(contains('verysecret')));
      expect(r('{"password": "hunter2"}'), isNot(contains('hunter2')));
      expect(
        r('uuid 550e8400-e29b-41d4-a716-446655440000'),
        isNot(contains('550e8400')),
      );
      // Plain long identifiers stay readable.
      expect(
        r('in MessengerControllerStateNotifier now'),
        contains('MessengerControllerStateNotifier'),
      );
    });

    test('masks emails, Matrix ids and onion hosts', () {
      expect(r('mail bob@example.org failed'), 'mail [email] failed');
      expect(
        r('user @bob:matrix.org in !room:matrix.org'),
        'user [matrix-id] in [matrix-id]',
      );
      expect(
        r('via abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion'),
        'via [onion]',
      );
    });

    test('masks IP addresses and host:port', () {
      expect(
        r(
          'SocketException: Connection refused, address = 192.168.1.20, port = 51234',
        ),
        isNot(contains('192.168.1.20')),
      );
      expect(r('connect 10.0.0.7:4433 failed'), 'connect [ip] failed');
      expect(r('to 2001:db8:85a3:0:0:8a2e:370:7334 down'), 'to [ip] down');
      expect(r('to fe80::1ff:fe23:4567:890a down'), 'to [ip] down');
      expect(r('to [::1]:8080 down'), 'to [ip] down');
      expect(r('relay relay.example.net:443 slow'), 'relay [host:port] slow');
      // Versions and times are not addresses.
      expect(r('v0.4.3 at 12:30:45'), 'v0.4.3 at 12:30:45');
    });

    test('masks URLs down to their host', () {
      expect(
        r(
          'GET https://user:pw@api.example.org:8448/_matrix/client?access_token=zzz#frag',
        ),
        'GET https://api.example.org',
      );
      expect(r('http://10.1.2.3:80/x'), 'http://[host]');
    });

    test('masks phone numbers and long numbers', () {
      expect(r('call +49 170 1234567 now'), 'call [number] now');
      expect(r('call (555) 123-4567 now'), 'call [number] now');
      expect(r('call 555-123-4567 now'), 'call [number] now');
      expect(r('id 12345678901234'), 'id [number]');
      expect(r('on 2026-11-03 build 306201'), 'on 2026-11-03 build 306201');
    });

    test('masks private paths, whole', () {
      for (final path in [
        '/home/anna/Documents/tax return.pdf',
        '/Users/anna/Library/x',
        r'C:\Users\anna\AppData\Local\conest',
        '/storage/emulated/0/Download/photo.jpg',
        '/sdcard/DCIM/x.jpg',
        '/data/user/0/dev.conest.conest/files/vault',
        '/data/data/dev.conest.conest/cache',
        'file:///home/anna/.local/share/conest/vault.json',
      ]) {
        final out = r('FileSystemException: cannot open $path (errno 2)');
        expect(out, isNot(contains('anna')), reason: path);
        expect(out, isNot(contains('photo')), reason: path);
        expect(out, isNot(contains('dev.conest')), reason: path);
        expect(out, contains('[path]'), reason: path);
      }
    });

    test('is fast on hostile text', () {
      final watch = Stopwatch()..start();
      final text = List.filled(
        40,
        'a' * 1000 + '@' + 'b' * 500 + ' ' + '1.' * 500,
      ).join('\n');
      r(text);
      expect(watch.elapsedMilliseconds, lessThan(5000));
    });
  });

  group('buildProblemReport', () {
    test('has the header, transports as words only, crashes and errors', () {
      final text = buildProblemReport(
        _inputs(
          transports: const [
            ReportTransportLine('tor', 'ready'),
            ReportTransportLine('matrix', 'error'),
          ],
          crashes: [
            ReportCrash(_t, 'native', 'SIGSEGV in libconest\n#0 frame'),
          ],
          errors: [ReportError(_t, 'send', 'found no route\nsecond line')],
        ),
      );
      expect(text, contains('Version: 0.4.3 (build 306201)'));
      expect(text, contains('Tag: v0.4.3-canary.20261103.1'));
      expect(text, contains('Commit: abc1234'));
      expect(text, contains('Channel: canary'));
      expect(text, contains('Update channel followed: nightly'));
      expect(text, contains('Platform: android Linux 5.10'));
      expect(text, contains('tor: ready'));
      expect(text, contains('matrix: error'));
      expect(text, contains('SIGSEGV in libconest\n#0 frame'));
      expect(text, contains('[send] found no route'));
      expect(text, isNot(contains('second line')));
      expect(text, contains('Nothing was sent anywhere'));
    });

    test(
      'keeps no debug log, no subject, no crash forwards, only a first line',
      () {
        final text = buildProblemReport(
          _inputs(
            errors: [
              ReportError(_t, 'log', 'chatty debug line'),
              ReportError(_t, 'flutter', 'dup of a crash'),
              ReportError(
                _t,
                'receive',
                'FormatException: bad\n{"text":"SECRET-BODY"}',
              ),
            ],
          ),
        );
        expect(text, isNot(contains('chatty')));
        expect(text, isNot(contains('dup of a crash')));
        expect(text, isNot(contains('SECRET-BODY')));
        expect(text, contains('FormatException: bad'));
      },
    );

    test('names the denied things nowhere, in crashes or errors', () {
      final text = buildProblemReport(
        _inputs(
          deny: ['Annabel', 'chat.example.org'],
          errors: [
            ReportError(
              _t,
              'send',
              'Annabel found no route: SocketException: refused, address = 10.2.3.4',
            ),
            ReportError(
              _t,
              'carrier',
              'Email could not move away from chat.example.org',
            ),
          ],
          crashes: [
            ReportCrash(_t, 'zone', 'context Annabel\nat /home/annabel/x.dart'),
          ],
        ),
      );
      for (final secret in [
        'Annabel',
        'chat.example.org',
        '10.2.3.4',
        'annabel',
      ]) {
        expect(
          text.toLowerCase(),
          isNot(contains(secret.toLowerCase())),
          reason: secret,
        );
      }
    });

    test('says so when the vault is locked or no history is kept', () {
      final text = buildProblemReport(
        _inputs(
          transportsAvailable: false,
          errorsAvailable: false,
          crashes: [ReportCrash(_t, 'exit', 'closed without finishing')],
        ),
      );
      expect(text, contains('Not available until Conest is unlocked'));
      expect(text, contains('Not available (not kept on this build'));
      expect(text, contains('closed without finishing'));
    });

    test('is bounded: 5000 hostile entries, time and size', () {
      final watch = Stopwatch()..start();
      final text = buildProblemReport(
        _inputs(
          errors: [
            for (var i = 0; i < 5000; i++)
              ReportError(
                _t,
                'send',
                'entry $i ${'x' * 3000} user$i@example.org',
              ),
          ],
          crashes: [
            for (var i = 0; i < 200; i++)
              ReportCrash(_t, 'zone', 'crash $i ${'y ' * 5000}'),
          ],
        ),
      );
      expect(
        text.length,
        lessThanOrEqualTo(ProblemReportLimits.totalChars + 1),
      );
      expect(text, contains('Conest problem report'));
      expect(text, contains('== Error history =='));
      expect(watch.elapsedMilliseconds, lessThan(10000));
      // The newest entries are the ones kept.
      expect(text, contains('entry 4999'));
      expect(text, isNot(contains('entry 0 ')));
      expect(text, isNot(contains('@example.org')));
    });

    test('is built off the main isolate with the same result', () async {
      final inputs = _inputs(
        errors: [ReportError(_t, 'send', 'to Annabel failed')],
        deny: ['Annabel'],
      );
      expect(
        await buildProblemReportOffMain(inputs),
        buildProblemReport(inputs),
      );
    });
  });

  group('collectProblemReportInputs', () {
    test('without a controller: header and crash records only', () {
      final crashes = CrashCatcher(now: () => _t)..record('zone', 'boom', null);
      final info = ConestBuildInfo(
        appName: 'Conest',
        packageName: 'dev.conest.conest',
        version: '0.4.3',
        buildNumber: '5',
        channel: UpdateChannel.canary,
        isDebugBuild: false,
        buildTag: 'v0.4.3-canary.20261103.1',
      );
      final inputs = collectProblemReportInputs(
        buildInfo: info,
        updateChannel: 'canary',
        crashes: crashes,
        now: _t,
      );
      expect(inputs.transportsAvailable, isFalse);
      expect(inputs.errorHistoryAvailable, isFalse);
      expect(inputs.crashes.single.text, 'boom');
      expect(inputs.channel, 'canary');
      expect(inputs.platform, contains(Platform.operatingSystem));
      expect(buildProblemReport(inputs), contains('boom'));
    });
  });

  group('CrashCatcher.thisRun', () {
    test('is bounded to the newest 32', () {
      final crashes = CrashCatcher(now: () => _t);
      for (var i = 0; i < 50; i++) {
        crashes.record('zone', 'crash $i', null);
      }
      expect(crashes.thisRun, hasLength(32));
      expect(crashes.thisRun.last.text, 'crash 49');
      expect(crashes.thisRun.first.text, 'crash 18');
    });
  });
}

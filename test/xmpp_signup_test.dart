import 'dart:convert';
import 'dart:io';

import 'package:conest/src/xmpp/xmpp_carrier.dart';
import 'package:conest/src/xmpp/xmpp_registration.dart';
import 'package:conest/src/xmpp/xmpp_servers.dart';
import 'package:conest/src/xmpp/xmpp_socket.dart';
import 'package:conest/src/xmpp/xmpp_xml.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_xmpp_server.dart';

/// A connector that reaches the fake server of each host (a host with none
/// does not answer); only the ports in [ports] answer, when given.
XmppSocketConnector _network(
  Map<String, FakeXmppServer> servers, {
  Set<int>? ports,
}) => (host, port, {required tls, alpn}) async {
  final server = servers[host];
  if (server == null || (ports != null && !ports.contains(port))) {
    throw const SocketException('unreachable');
  }
  return server.connect(host, port, tls: tls, alpn: alpn);
};

Future<XmppCarrierConfig> _setUp(
  List<XmppServerEntry> entries,
  Map<String, FakeXmppServer> servers, {
  XmppCaptchaSolver? solver,
}) => setUpXmppCarrierAccount(
  entries,
  resource: 'conest-x',
  connector: _network(servers),
  webSocketLookup: null,
  captchaSolver: solver,
  headStart: const Duration(milliseconds: 10),
  probeTimeout: const Duration(seconds: 5),
);

void main() {
  group('creating an account', () {
    test(
      'a server with closed sign-up is skipped, the next one is used',
      () async {
        final closed = FakeXmppServer(allowRegistration: false);
        final refusing = FakeXmppServer()..forbidRegistration = true;
        final open = FakeXmppServer(domain: 'open.test');
        final config = await _setUp(
          const [
            XmppServerEntry('closed.test'),
            XmppServerEntry('refusing.test'),
            XmppServerEntry('open.test'),
          ],
          {'closed.test': closed, 'refusing.test': refusing, 'open.test': open},
        );
        expect(config.jid, endsWith('@open.test'));
        expect(open.passwords.keys, contains(config.jid.split('@').first));
        expect(closed.passwords, isEmpty);
        expect(refusing.passwords, isEmpty);
      },
    );

    test(
      'a CAPTCHA is shown to the user and the answer is submitted',
      () async {
        final server = FakeXmppServer(domain: 'captcha.test')
          ..captchaAnswer = 'k7Fq';
        XmppCaptchaChallenge? shown;
        final config = await _setUp(
          const [XmppServerEntry('captcha.test', captcha: true)],
          {'captcha.test': server},
          solver: (challenge) async {
            shown = challenge;
            return '  k7Fq ';
          },
        );
        expect(config.jid, endsWith('@captcha.test'));
        expect(shown!.image, server.captchaImage);
        expect(shown!.mimeType, 'image/png');
        expect(shown!.fieldVar, 'ocr');
        expect(shown!.instructions, contains('Enter the text you see'));
        expect(server.captchaAnswers, ['k7Fq']);
        expect(server.passwords.keys, contains(config.jid.split('@').first));
      },
    );

    test('a server without a CAPTCHA is used before one with it', () async {
      final captcha = FakeXmppServer(domain: 'captcha.test')
        ..captchaAnswer = 'x';
      final plain = FakeXmppServer(domain: 'plain.test');
      var asked = false;
      final config = await _setUp(
        const [
          XmppServerEntry('captcha.test', captcha: true),
          XmppServerEntry('plain.test'),
        ],
        {'captcha.test': captcha, 'plain.test': plain},
        solver: (_) async {
          asked = true;
          return 'x';
        },
      );
      expect(config.jid, endsWith('@plain.test'));
      expect(asked, isFalse);
    });

    test('a wrong or missing CAPTCHA answer creates no account', () async {
      final server = FakeXmppServer(domain: 'captcha.test')
        ..captchaAnswer = 'right';
      await expectLater(
        _setUp(
          const [XmppServerEntry('captcha.test', captcha: true)],
          {'captcha.test': server},
          solver: (_) async => 'wrong',
        ),
        throwsA(
          isA<XmppAccountCreationException>().having(
            (e) => e.message,
            'message',
            contains('captcha.test: asks for a CAPTCHA (answer not accepted)'),
          ),
        ),
      );
      expect(server.passwords, isEmpty);
      // The user gives up.
      await expectLater(
        _setUp(
          const [XmppServerEntry('captcha.test', captcha: true)],
          {'captcha.test': server},
          solver: (_) async => null,
        ),
        throwsA(isA<XmppAccountCreationException>()),
      );
      expect(server.passwords, isEmpty);
    });

    test('a server found only on port 443 is used', () async {
      final server = FakeXmppServer(domain: 'only443.test');
      final servers = {'only443.test': server};
      final probed = await reachableXmppServers(
        ['only443.test'],
        connector: _network(servers, ports: {443}),
        webSocketLookup: null,
        needRegistration: true,
        headStart: const Duration(milliseconds: 10),
      );
      expect(probed.single.endpoint.port, 443);
      expect(probed.single.endpoint.mode, XmppEndpointMode.directTls);
      final config = await setUpXmppCarrierAccount(
        const [XmppServerEntry('only443.test')],
        resource: 'conest-x',
        connector: _network(servers, ports: {443}),
        webSocketLookup: null,
        headStart: const Duration(milliseconds: 10),
      );
      expect(config.endpoints.single.port, 443);
      expect(server.passwords.keys, contains(config.jid.split('@').first));
    });

    test('the error says what each server answered', () async {
      final closed = FakeXmppServer(allowRegistration: false);
      final refusing = FakeXmppServer()..forbidRegistration = true;
      final web = FakeXmppServer()
        ..registrationWebPage = 'https://web.test/signup';
      final captcha = FakeXmppServer()..captchaAnswer = 'x';
      final servers = {
        'closed.test': closed,
        'refusing.test': refusing,
        'web.test': web,
        'captcha.test': captcha,
      };
      Object? thrown;
      try {
        await _setUp(const [
          XmppServerEntry('down.test'),
          XmppServerEntry('closed.test'),
          XmppServerEntry('refusing.test'),
          XmppServerEntry('web.test'),
          XmppServerEntry('captcha.test', captcha: true),
          XmppServerEntry('site.test', web: 'https://site.test/join'),
        ], servers);
      } catch (error) {
        thrown = error;
      }
      final error = thrown as XmppAccountCreationException;
      final byDomain = {for (final o in error.outcomes) o.domain: o};
      expect(byDomain['down.test']!.status, XmppServerStatus.noAnswer);
      expect(byDomain['closed.test']!.status, XmppServerStatus.closed);
      expect(byDomain['refusing.test']!.status, XmppServerStatus.forbidden);
      expect(byDomain['web.test']!.status, XmppServerStatus.webSignup);
      expect(byDomain['captcha.test']!.status, XmppServerStatus.captcha);
      expect(error.message, contains('down.test: no answer'));
      expect(error.message, contains('closed.test: sign-up closed'));
      expect(error.message, contains('refusing.test: forbidden'));
      expect(error.message, contains('captcha.test: asks for a CAPTCHA'));
      expect(error.message, endsWith('Use your own account.'));
      // The web pages are offered, those the servers named and those the
      // list knew.
      expect(error.webSignups.map((o) => o.url).toSet(), {
        'https://web.test/signup',
        'https://site.test/join',
      });
    });
  });

  group('sign-up forms from servers', () {
    XmppElement query(List<XmppElement> children) =>
        XmppElement('query', xmlns: XmppNs.register, children: children);

    test('an address that is not https is not offered', () {
      XmppElement redirect(String url) => query([
        XmppElement(
          'x',
          xmlns: XmppNs.oob,
          children: [XmppElement('url', text: url)],
        ),
      ]);
      expect(
        parseRegistrationForm(redirect('https://ok.test/join')).redirect,
        'https://ok.test/join',
      );
      for (final bad in [
        'http://ok.test/join',
        'javascript:alert(1)',
        'https://user:pw@ok.test/',
        'https://${'a' * 600}.test/',
        '',
      ]) {
        expect(
          parseRegistrationForm(redirect(bad)).redirect,
          isNull,
          reason: bad,
        );
      }
    });

    test('a huge or wrong-typed CAPTCHA image is not taken', () {
      XmppElement form(String type, int bytes) => query([
        XmppElement('username'),
        XmppElement('password'),
        XmppElement(
          'x',
          xmlns: XmppNs.dataForms,
          children: [
            XmppElement(
              'field',
              xmlns: XmppNs.dataForms,
              attributes: {'var': 'ocr'},
              children: [
                XmppElement(
                  'media',
                  xmlns: 'urn:xmpp:media-element',
                  children: [
                    XmppElement(
                      'uri',
                      xmlns: 'urn:xmpp:media-element',
                      text: 'cid:a',
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        XmppElement(
          'data',
          xmlns: 'urn:xmpp:bob',
          attributes: {'cid': 'a', 'type': type},
          text: base64.encode(List.filled(bytes, 1)),
        ),
      ]);
      expect(parseRegistrationForm(form('image/png', 100)).captcha, isNotNull);
      for (final bad in [
        form('image/png', maxCaptchaImageBytes + 1),
        form('text/html', 100),
        form('image/png', 0),
      ]) {
        final parsed = parseRegistrationForm(bad);
        expect(parsed.captcha, isNull);
        // A CAPTCHA that cannot be read cannot be answered.
        expect(parsed.unsupported, contains('captcha'));
      }
    });
  });

  group('the bundled server list', () {
    test('has servers with in-app sign-up, safe to use', () {
      final servers = parseXmppServers(
        File('assets/xmpp/servers.json').readAsStringSync(),
      );
      expect(servers.length, greaterThan(20));
      expect(servers.length, lessThanOrEqualTo(maxXmppServers));
      // More than the four it started with, and some need no CAPTCHA.
      expect(
        servers.where((s) => s.web == null && !s.captcha).length,
        greaterThan(5),
      );
      expect(servers.map((s) => s.domain).toSet().length, servers.length);
      for (final server in servers) {
        expect(server.domain, matches(RegExp(r'^[a-z0-9.-]+\.[a-z]+$')));
        if (server.web != null) expect(server.web, startsWith('https://'));
      }
    });

    test('junk in the list is skipped', () {
      expect(parseXmppServers('not json'), isEmpty);
      expect(parseXmppServers('[]'), isEmpty);
      final servers = parseXmppServers(
        jsonEncode({
          'servers': [
            {'domain': 'good.test'},
            {'domain': 'good.test'},
            {'domain': 'bad domain.test'},
            {'domain': 'localhost'},
            {'domain': 5},
            'x',
            {'domain': 'web.test', 'web': 'http://web.test/'},
            {'domain': 'ok.test', 'captcha': true, 'web': 'https://ok.test/a'},
          ],
        }),
      );
      expect(servers.map((s) => s.domain), [
        'good.test',
        'web.test',
        'ok.test',
      ]);
      expect(servers[1].web, isNull);
      expect(servers[2].captcha, isTrue);
      expect(servers[2].web, 'https://ok.test/a');
    });
  });
}

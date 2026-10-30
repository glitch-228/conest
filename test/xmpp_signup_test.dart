import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/xmpp/xmpp_captcha_image.dart';
import 'package:conest/src/xmpp/xmpp_carrier.dart';
import 'package:conest/src/xmpp/xmpp_registration.dart';
import 'package:conest/src/xmpp/xmpp_sasl.dart' show XmppSaslException;
import 'package:conest/src/xmpp/xmpp_servers.dart';
import 'package:conest/src/xmpp/xmpp_session.dart' show stanzaErrorOf;
import 'package:conest/src/xmpp/xmpp_socket.dart';
import 'package:conest/src/xmpp/xmpp_xml.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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
        throwsA(isA<XmppRegistrationCancelled>()),
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

  group('a long list of web-only servers', () {
    test('does not hide what the probed servers answered', () async {
      final closed = FakeXmppServer(allowRegistration: false);
      final web = FakeXmppServer()
        ..registrationWebPage = 'https://web.test/signup';
      Object? thrown;
      try {
        await _setUp(
          [
            for (var i = 0; i < 20; i++)
              XmppServerEntry('site$i.test', web: 'https://site$i.test/join'),
            const XmppServerEntry('down.test'),
            const XmppServerEntry('closed.test'),
            const XmppServerEntry('web.test'),
          ],
          {'closed.test': closed, 'web.test': web},
        );
      } catch (error) {
        thrown = error;
      }
      final error = thrown as XmppAccountCreationException;
      expect(error.message, contains('down.test: no answer'));
      expect(error.message, contains('closed.test: sign-up closed'));
      expect(error.message, contains('web.test: sign-up on its website'));
      expect(error.message, contains('20 more sign up on their websites'));
      expect(error.message, isNot(contains('site3.test')));
      // The link of a server that answered here comes first.
      final urls = error.webSignups.map((o) => o.url).toList();
      expect(urls.first, 'https://web.test/signup');
      expect(urls.length, 21);
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
          text: base64.encode(
            bytes == 0
                ? const <int>[]
                : [...pngHeader(100, 40), ...List.filled(bytes, 1)],
          ),
        ),
      ]);
      expect(parseRegistrationForm(form('image/png', 100)).captcha, isNotNull);
      for (final bad in [
        form('image/png', maxCaptchaImageBytes + 1),
        form('image/jpeg', 100),
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

  group('hostile CAPTCHA pictures', () {
    XmppElement formWith(List<int> bytes, String type) => XmppElement(
      'query',
      xmlns: XmppNs.register,
      children: [
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
          text: base64.encode(bytes),
        ),
      ],
    );

    test('only small pictures whose bytes match their type are taken', () {
      bool taken(List<int> bytes, String type) =>
          parseRegistrationForm(formWith(bytes, type)).captcha != null;
      expect(taken(pngHeader(300, 100), 'image/png'), isTrue);
      // 30000 x 30000 in a few bytes would take gigabytes to decode.
      expect(taken(pngHeader(30000, 30000), 'image/png'), isFalse);
      expect(taken(pngHeader(1025, 10), 'image/png'), isFalse);
      expect(taken(pngHeader(0, 10), 'image/png'), isFalse);
      // Declared PNG, but the bytes are something else.
      expect(
        taken(utf8.encode('<html>${'x' * 40}</html>'), 'image/png'),
        isFalse,
      );
      expect(taken(pngHeader(10, 10), 'image/gif'), isFalse);
      // GIF is refused whatever its header says: a decoder grows the
      // canvas to the first frame, wherever that sits (a 100 x 40 screen
      // with a 30000 x 30000 first frame decodes to 30000 x 30000).
      final gif = [...utf8.encode('GIF89a'), 100, 0, 40, 0, 0, 0, 0, 0];
      expect(taken(gif, 'image/gif'), isFalse);
      expect(taken(gif, 'image/png'), isFalse);
      // JPEG headers are read.
      final jpeg = [
        0xff,
        0xd8,
        0xff,
        0xc0,
        0,
        17,
        8,
        0,
        60,
        0,
        120,
        3,
        1,
        0x22,
        0,
        2,
        0x11,
        0,
        3,
        0x11,
        0,
      ];
      expect(readImageHeader(Uint8List.fromList(jpeg))?.width, 120);
      expect(taken(jpeg, 'image/jpeg'), isTrue);
    });
  });

  group('the decoder checks the picture too', () {
    test('only pictures the engine measures as small are shown', () async {
      Uint8List png(int w, int h) =>
          Uint8List.fromList(img.encodePng(img.Image(width: w, height: h)));
      expect(await captchaImageFitsToShow(png(200, 60)), isTrue);
      expect(await captchaImageFitsToShow(png(2000, 10)), isFalse);
      expect(await captchaImageFitsToShow(png(10, 1100)), isFalse);
      expect(
        await captchaImageFitsToShow(Uint8List.fromList([1, 2, 3])),
        isFalse,
      );
    });
  });

  group('server text in sign-in errors', () {
    test('is cleaned and cut', () {
      final text = XmppSaslException('a\u202eb\u200b${'z' * 500}').toString();
      expect(text, startsWith('Sign-in failed: ab'));
      expect(text, isNot(contains('\u202e')));
      expect(text.length, lessThan(100));
    });
  });

  group('a finished probe round', () {
    test('closes the connections of servers still being slow', () async {
      final fast = FakeXmppServer(domain: 'fast.test');
      final closed = <int>[];
      var opened = 0;
      Future<XmppByteSocket> silent() async {
        final id = opened++;
        return _SilentSocket(() => closed.add(id));
      }

      final probed = await reachableXmppServers(
        ['slow.test', 'fast.test'],
        connector: (host, port, {required tls, alpn}) async {
          if (host == 'fast.test') {
            return fast.connect(host, port, tls: tls, alpn: alpn);
          }
          if (port == 5222) return silent();
          if (port == 5223) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
            return silent();
          }
          throw const SocketException('unreachable');
        },
        webSocketLookup: null,
        enough: 1,
        parallel: 2,
        headStart: const Duration(milliseconds: 10),
        needRegistration: true,
      );
      expect(probed.map((p) => p.domain), ['fast.test']);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(opened, 2);
      expect(closed.toSet(), {0, 1});
    });
  });

  group('what servers say', () {
    test('text from a server is cleaned and cut', () {
      expect(serverText('a\u202eb\u200bc\u0085d\x00e'), 'abcde');
      expect(serverText('x' * 1000).length, 200);
      expect(serverText('x' * 1000, 64).length, 64);
    });

    test('a long error condition from a server stays short', () async {
      // The condition is the name of an element the server chose.
      final server = FakeXmppServer(domain: 'long.test');
      final long = XmppElement(
        'iq',
        attributes: {'type': 'error'},
        children: [
          XmppElement(
            'error',
            children: [XmppElement('c' * 5000, xmlns: XmppNs.stanzas)],
          ),
        ],
      );
      expect(server.domain, isNotEmpty);
      expect(stanzaErrorOf(long).condition.length, 64);
    });

    test('website links must be public https names', () {
      for (final good in [
        'https://signup.example.org/join',
        'https://a.b.c/x?y=1',
      ]) {
        expect(isPublicHttpsUrl(good), isTrue, reason: good);
      }
      for (final bad in [
        'http://example.org/',
        'https://127.0.0.1/',
        'https://192.168.1.1/x',
        'https://[::1]/',
        'https://localhost/',
        'https://localhost./',
        'https://example.org..',
        'https://0x7f.0.0.1/',
        'https://0xc0.0xa8.1.1/',
        'https://127.1/',
        'https://2130706433/',
        'https://a.b.0x10/',
        'https://printer.local/',
        'https://intranet/',
        'https://user@example.org/',
        'https://10.0.0.1.example.org.internal/',
        'ftp://example.org/',
        '',
      ]) {
        expect(isPublicHttpsUrl(bad), isFalse, reason: bad);
      }
    });
  });

  group('while the user answers a CAPTCHA', () {
    test('a server that keeps talking fails the attempt', () async {
      final server = FakeXmppServer(domain: 'chatty.test')
        ..captchaAnswer = 'x'
        ..floodAfterForm = 500;
      await expectLater(
        _setUp(
          const [XmppServerEntry('chatty.test', captcha: true)],
          {'chatty.test': server},
          solver: (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return 'x';
          },
        ),
        throwsA(isA<XmppAccountCreationException>()),
      );
      expect(server.passwords, isEmpty);
    });

    test(
      'a few huge stanzas fail the attempt (bytes, not just count)',
      () async {
        final server = FakeXmppServer(domain: 'big.test')
          ..captchaAnswer = 'x'
          ..bigAfterForm = 8;
        await expectLater(
          _setUp(
            const [XmppServerEntry('big.test', captcha: true)],
            {'big.test': server},
            solver: (_) async {
              await Future<void>.delayed(const Duration(milliseconds: 300));
              return 'x';
            },
          ),
          throwsA(isA<XmppAccountCreationException>()),
        );
        expect(server.captchaAnswers, isEmpty);
        expect(server.passwords, isEmpty);
      },
    );

    test('a stream error sent meanwhile stops it before the answer', () async {
      final server = FakeXmppServer(domain: 'bye.test')
        ..captchaAnswer = 'x'
        ..streamErrorAfterForm = true;
      await expectLater(
        _setUp(
          const [XmppServerEntry('bye.test', captcha: true)],
          {'bye.test': server},
          solver: (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return 'x';
          },
        ),
        throwsA(isA<XmppAccountCreationException>()),
      );
      expect(server.captchaAnswers, isEmpty);
      expect(server.passwords, isEmpty);
    });

    test('cancelling stops the set-up at once', () async {
      final a = FakeXmppServer(domain: 'a.test')..captchaAnswer = 'x';
      final b = FakeXmppServer(domain: 'b.test')..captchaAnswer = 'x';
      var asked = 0;
      await expectLater(
        _setUp(
          const [
            XmppServerEntry('a.test', captcha: true),
            XmppServerEntry('b.test', captcha: true),
          ],
          {'a.test': a, 'b.test': b},
          solver: (_) async {
            asked++;
            return null;
          },
        ),
        throwsA(isA<XmppRegistrationCancelled>()),
      );
      expect(asked, 1);
      expect(a.passwords, isEmpty);
      expect(b.passwords, isEmpty);
    });

    test('the dialog names the server the answer goes to', () async {
      final server = FakeXmppServer(domain: 'named.test')..captchaAnswer = 'x';
      XmppCaptchaChallenge? shown;
      await _setUp(
        const [XmppServerEntry('named.test', captcha: true)],
        {'named.test': server},
        solver: (challenge) async {
          shown = challenge;
          return 'x';
        },
      );
      expect(shown!.domain, 'named.test');
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

/// A connection that opens and then says nothing.
class _SilentSocket implements XmppByteSocket {
  _SilentSocket(this.onClose);
  final void Function() onClose;
  final StreamController<Uint8List> _input = StreamController();

  @override
  Stream<Uint8List> get input => _input.stream;
  @override
  bool get secure => true;
  @override
  void write(List<int> bytes) {}
  @override
  Future<XmppByteSocket> startTls(String host) async => this;
  @override
  Future<void> close() async {
    onClose();
    await _input.close();
  }
}

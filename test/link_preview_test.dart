import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/links/link_cleaner.dart';
import 'package:conest/src/links/link_preview.dart';
import 'package:conest/src/links/link_preview_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  group('reading a page', () {
    test('Open Graph first, then Twitter cards, then the title', () {
      final page = Uri.parse('https://news.example/a/b');
      final og = parseLinkPreviewPage('''
<html><head><title>Plain title</title>
<meta property="og:title" content="OG title">
<meta property="og:description" content="OG  text
 here">
<meta property="og:site_name" content="News">
<meta property="og:image" content="/pics/1.jpg">
<meta name="twitter:title" content="Twitter title">
</head></html>''', page);
      expect(og.title, 'OG title');
      expect(og.description, 'OG text here');
      expect(og.siteName, 'News');
      expect(og.image.toString(), 'https://news.example/pics/1.jpg');

      final twitter = parseLinkPreviewPage('''
<meta name="twitter:title" content="Tw"><meta name="description" content="D">
<meta name="twitter:image" content="javascript:alert(1)">''', page);
      expect(twitter.title, 'Tw');
      expect(twitter.description, 'D');
      expect(twitter.image, isNull, reason: 'only http(s) pictures');

      final bare = parseLinkPreviewPage(
        '<title>  Just  a title </title><p>broken <b>html',
        page,
      );
      expect(bare.title, 'Just a title');
      expect(bare.image, isNull);
    });
  });

  group('public addresses only', () {
    final cases = {
      '8.8.8.8': true,
      '172.32.0.1': true,
      '2001:4860:4860::8888': true,
      '::ffff:8.8.8.8': true,
      '10.0.0.1': false,
      '192.168.1.1': false,
      '172.16.0.1': false,
      '100.64.0.1': false,
      '127.0.0.1': false,
      '169.254.169.254': false,
      '0.0.0.0': false,
      '224.0.0.1': false,
      '255.255.255.255': false,
      '::1': false,
      '::': false,
      'fe80::1': false,
      'fd00::1': false,
      'ff02::1': false,
      '::ffff:10.0.0.1': false,
      '::ffff:127.0.0.1': false,
      '64:ff9b::a00:1': false,
      '2002:a00:1::': false,
      '2001:db8::1': false,
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      test('$key is ${value ? '' : 'not '}public', () {
        expect(isPublicAddress(InternetAddress(key)), value);
      });
    }
  });

  group('fetching', () {
    late HttpServer server;
    late int port;
    var hits = <String>[];
    Future<void> Function(HttpRequest request)? handler;

    setUp(() async {
      hits = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      server.listen((request) async {
        hits.add(request.uri.path);
        await handler!(request);
      });
    });
    tearDown(() => server.close(force: true));

    Uint8List png() =>
        Uint8List.fromList(img.encodePng(img.Image(width: 800, height: 400)));

    void page(HttpRequest request, String body) {
      request.response
        ..headers.contentType = ContentType.html
        ..write(body);
      unawaited(request.response.close());
    }

    // site.example and the server's own address are allowed; the real
    // policy refuses loopback, which the tests below rely on too.
    LinkPreviewFetcher fetcher({
      Duration timeout = const Duration(seconds: 5),
      Map<String, List<String>>? names,
    }) => LinkPreviewFetcher(
      lookup: (host) async => [
        for (final address
            in (names ??
                    {
                      'site.example': ['127.0.0.1'],
                    })[host] ??
                const <String>[])
          InternetAddress(address),
      ],
      isAllowed: (address) => address.address == '127.0.0.1',
      timeout: timeout,
    );

    test(
      'a page with its picture becomes a preview with a thumbnail',
      () async {
        handler = (request) async {
          if (request.uri.path == '/img.png') {
            request.response
              ..headers.contentType = ContentType('image', 'png')
              ..add(png());
            await request.response.close();
            return;
          }
          expect(request.headers.value('user-agent'), contains('TelegramBot'));
          page(
            request,
            '<meta property="og:title" content="Hello">'
            '<meta property="og:image" content="/img.png">',
          );
        };
        final preview = await fetcher().fetch(
          Uri.parse('http://site.example:$port/post'),
        );
        expect(preview!.title, 'Hello');
        expect(preview.siteName, 'site.example');
        expect(preview.image, isNotNull);
        expect(
          preview.image!.length,
          lessThanOrEqualTo(LinkPreviewFetcher.maxThumbnailBytes),
        );
        expect(img.decodeJpg(preview.image!)!.width, lessThanOrEqualTo(360));
      },
    );

    test('a private address is refused, by name, by number and after a '
        'redirect', () async {
      handler = (request) async => page(request, '<title>secret</title>');
      final real = LinkPreviewFetcher(
        lookup: (host) async => [InternetAddress.loopbackIPv4],
      );
      await expectLater(
        real.fetch(Uri.parse('http://router.example:$port/')),
        throwsA(isA<LinkPreviewException>()),
      );
      await expectLater(
        real.fetch(Uri.parse('http://127.0.0.1:$port/')),
        throwsA(isA<LinkPreviewException>()),
      );
      expect(hits, isEmpty, reason: 'nothing was asked of the server');

      // An allowed site redirecting inside: the hop is checked too.
      handler = (request) async {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set('location', 'http://inside.example:$port/admin');
        await request.response.close();
      };
      await expectLater(
        fetcher(
          names: {
            'site.example': ['127.0.0.1'],
            'inside.example': ['127.0.0.2'],
          },
        ).fetch(Uri.parse('http://site.example:$port/go')),
        throwsA(
          isA<LinkPreviewException>().having(
            (e) => e.message,
            'message',
            'not a public address',
          ),
        ),
      );
      expect(hits, ['/go']);
    });

    test('a name that also points inside is refused', () async {
      handler = (request) async => page(request, '<title>x</title>');
      await expectLater(
        fetcher(
          names: {
            'site.example': ['127.0.0.1', '127.0.0.2'],
          },
        ).fetch(Uri.parse('http://site.example:$port/')),
        throwsA(isA<LinkPreviewException>()),
      );
      expect(hits, isEmpty);
    });

    test('too many redirects, too slow, too large, or not a page', () async {
      handler = (request) async {
        request.response
          ..statusCode = HttpStatus.movedPermanently
          ..headers.set('location', '/again');
        await request.response.close();
      };
      await expectLater(
        fetcher().fetch(Uri.parse('http://site.example:$port/loop')),
        throwsA(isA<LinkPreviewException>()),
      );
      expect(hits.length, LinkPreviewFetcher.maxRedirects + 1);

      handler = (request) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        page(request, '<title>late</title>');
      };
      await expectLater(
        fetcher(
          timeout: const Duration(milliseconds: 300),
        ).fetch(Uri.parse('http://site.example:$port/slow')),
        throwsA(isA<LinkPreviewException>()),
      );

      handler = (request) async {
        request.response
          ..headers.contentType = ContentType.html
          ..contentLength = LinkPreviewFetcher.maxPageBytes + 1
          ..add(List.filled(LinkPreviewFetcher.maxPageBytes + 1, 32));
        await request.response.close();
      };
      await expectLater(
        fetcher().fetch(Uri.parse('http://site.example:$port/big')),
        throwsA(isA<LinkPreviewException>()),
      );

      handler = (request) async {
        request.response
          ..headers.contentType = ContentType('application', 'pdf')
          ..add([1, 2, 3]);
        await request.response.close();
      };
      await expectLater(
        fetcher().fetch(Uri.parse('http://site.example:$port/file.pdf')),
        throwsA(isA<LinkPreviewException>()),
      );
    });

    test('a long page without a length is read only up to the cap', () async {
      handler = (request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<meta property="og:title" content="Top">');
        for (var i = 0; i < 40; i++) {
          request.response.add(List.filled(64 * 1024, 32));
          await request.response.flush();
        }
        await request.response.close();
      };
      final preview = await fetcher().fetch(
        Uri.parse('http://site.example:$port/long'),
      );
      expect(preview!.title, 'Top');
    });
  });

  group('kept previews', () {
    test('a link is fetched once, however many ask', () async {
      final fake = _FakeFetcher({'https://a.example/': _preview('A')});
      final previews = LinkPreviews(fetcher: fake);
      final both = await Future.wait([
        previews.preview(Uri.parse('https://a.example/')),
        previews.preview(Uri.parse('https://a.example/')),
      ]);
      expect(both.map((p) => p?.title), ['A', 'A']);
      expect(fake.asked, ['https://a.example/']);
      expect(previews.cached(Uri.parse('https://a.example/'))?.title, 'A');
    });

    test('a link that failed is not asked again for an hour', () async {
      var now = DateTime.utc(2026, 10, 21, 12);
      final fake = _FakeFetcher({});
      final previews = LinkPreviews(fetcher: fake, now: () => now);
      final url = Uri.parse('https://gone.example/');
      expect(await previews.preview(url), isNull);
      expect(await previews.preview(url), isNull);
      expect(fake.asked, hasLength(1));
      now = now.add(const Duration(minutes: 61));
      await previews.preview(url);
      expect(fake.asked, hasLength(2));
    });

    test(
      'they survive a restart, encrypted, and not with another key',
      () async {
        final folder = await Directory.systemTemp.createTemp(
          'conest-previews-',
        );
        addTearDown(() => folder.delete(recursive: true));
        final file = File('${folder.path}/previews');
        final key = List<int>.generate(32, (i) => i);
        final first = LinkPreviews(
          fetcher: _FakeFetcher({'https://a.example/': _preview('Secret')}),
          file: file,
          key: key,
        );
        await first.preview(Uri.parse('https://a.example/'));
        await first.flush();
        expect(
          utf8.decode(await file.readAsBytes(), allowMalformed: true),
          isNot(contains('Secret')),
        );

        final again = LinkPreviews(
          fetcher: _FakeFetcher({}),
          file: file,
          key: key,
        );
        await again.load();
        expect(again.cached(Uri.parse('https://a.example/'))?.title, 'Secret');

        final stranger = LinkPreviews(
          fetcher: _FakeFetcher({}),
          file: file,
          key: List<int>.filled(32, 7),
        );
        await stranger.load();
        expect(stranger.cached(Uri.parse('https://a.example/')), isNull);
      },
    );

    test('at most 200, a week old, least recently used out first', () async {
      var now = DateTime.utc(2026, 10, 21);
      final answers = {
        for (var i = 0; i <= LinkPreviews.maxEntries; i++)
          'https://s$i.example/': _preview('$i', at: now),
      };
      final previews = LinkPreviews(
        fetcher: _FakeFetcher(answers),
        now: () => now,
      );
      for (var i = 0; i < LinkPreviews.maxEntries; i++) {
        await previews.preview(Uri.parse('https://s$i.example/'));
      }
      // The first is used again, so the second is the oldest.
      previews.cached(Uri.parse('https://s0.example/'));
      await previews.preview(
        Uri.parse('https://s${LinkPreviews.maxEntries}.example/'),
      );
      expect(previews.cached(Uri.parse('https://s0.example/')), isNotNull);
      expect(previews.cached(Uri.parse('https://s1.example/')), isNull);
      now = now.add(const Duration(days: 8));
      expect(previews.cached(Uri.parse('https://s0.example/')), isNull);
    });

    test('an embed-fixing service that gives nothing falls back, and is '
        'reported', () async {
      final fixers = LinkFilters.fromJson(
        clearUrls: File(LinkFilters.clearUrlsAsset).readAsStringSync(),
        embedFixers: File(LinkFilters.embedFixersAsset).readAsStringSync(),
      ).embedFixers;
      final failed = <String>[];
      final fake = _FakeFetcher({
        'https://fixvx.com/a/status/1': _preview('From the second'),
      });
      final previews = LinkPreviews(fetcher: fake, onServiceFailed: failed.add);
      final preview = await previews.preview(
        Uri.parse('https://fixupx.com/a/status/1'),
        fixers: fixers,
      );
      expect(preview?.title, 'From the second');
      expect(fake.asked, [
        'https://fixupx.com/a/status/1',
        'https://fixvx.com/a/status/1',
      ]);
      expect(failed, ['twitter:1']);
    });
  });
}

LinkPreview _preview(String title, {DateTime? at}) => LinkPreview(
  url: Uri.parse('https://x.example/'),
  fetchedAt: at ?? DateTime.now().toUtc(),
  title: title,
);

class _FakeFetcher extends LinkPreviewFetcher {
  _FakeFetcher(this.answers);

  final Map<String, LinkPreview> answers;
  final asked = <String>[];

  @override
  Future<LinkPreview?> fetch(
    Uri url, {
    int maxImage = LinkPreviewFetcher.maxImageBytes,
    DateTime Function() now = DateTime.now,
  }) async {
    asked.add(url.toString());
    final answer = answers[url.toString()];
    if (answer == null) throw const LinkPreviewException('nothing');
    return answer;
  }
}

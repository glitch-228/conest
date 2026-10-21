import 'dart:convert';
import 'dart:io';

import 'package:conest/src/links/clear_urls.dart';
import 'package:conest/src/links/embed_fixers.dart';
import 'package:conest/src/links/link_cleaner.dart';
import 'package:conest/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The bundled lists, as the app loads them.
  final filters = LinkFilters.fromJson(
    clearUrls: File(LinkFilters.clearUrlsAsset).readAsStringSync(),
    embedFixers: File(LinkFilters.embedFixersAsset).readAsStringSync(),
  );
  String clean(String url) =>
      filters.clearUrls.clean(Uri.parse(url)).toString();

  group('ClearURLs rules', () {
    test('the bundled list loads every provider', () {
      final raw =
          jsonDecode(
                File(LinkFilters.clearUrlsAsset).readAsStringSync(),
              )['providers']
              as Map;
      expect(filters.clearUrls.providerCount, raw.length);
    });

    test("YouTube's si and tracking parameters go, the video stays", () {
      expect(
        clean('https://youtu.be/dQw4w9WgXcQ?si=AbCdEf123'),
        'https://youtu.be/dQw4w9WgXcQ',
      );
      expect(
        clean('https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=x&t=42'),
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42',
      );
    });

    test('utm parameters go on any site, other fields stay as written', () {
      expect(
        clean(
          'https://news.example.org/a?id=7&utm_source=x&utm_medium=y&q=a%20b',
        ),
        'https://news.example.org/a?id=7&q=a%20b',
      );
    });

    test('a link with only tracking loses its question mark', () {
      expect(
        clean('https://news.example.org/a?utm_source=x'),
        'https://news.example.org/a',
      );
    });

    test('google.com/url is opened to the link it wraps', () {
      expect(
        clean(
          'https://www.google.com/url?sa=t&url=https%3A%2F%2Fexample.org%2Fpage%3Fid%3D3&usg=abc',
        ),
        'https://example.org/page?id=3',
      );
    });

    test('an exception keeps its link whole', () {
      // ClearURLs leaves YouTube's sign-in page alone.
      const signIn = 'https://www.youtube.com/signin?feature=x&next=%2F';
      expect(clean(signIn), signIn);
    });

    test('a raw rule cleans the path (Amazon)', () {
      expect(
        clean('https://www.amazon.com/dp/B000000000/ref=sr_1_1?keywords=x'),
        isNot(contains('ref=')),
      );
    });

    test('a fragment of fields is cleaned, a plain anchor stays', () {
      expect(
        clean('https://news.example.org/a#utm_source=x&part=2'),
        'https://news.example.org/a#part=2',
      );
      expect(
        clean('https://news.example.org/a?utm_source=x#section'),
        'https://news.example.org/a#section',
      );
    });

    test('a site the rules would block is only cleaned, never refused', () {
      // doubleclick is a completeProvider in ClearURLs.
      const ad = 'https://ad.doubleclick.net/ddm/x?y=1';
      expect(Uri.tryParse(clean(ad)), isNotNull);
    });

    test('very long links are left alone', () {
      final long = 'https://news.example.org/a?utm_source=x&p=${'a' * 5000}';
      expect(clean(long), long);
    });

    test('a redirect target is normalised, not split by what it decodes to', () {
      // The text path, as the message box uses it.
      final cleaned = filters.clearUrls.cleanText(
        'https://www.google.com/url?q=https%3A%2F%2Fa.example%2Fa%20b%0Ax',
      )!;
      expect(cleaned, isNot(contains(' ')));
      expect(cleaned, isNot(contains('\n')));
      expect(Uri.parse(cleaned).host, 'a.example');
    });

    test('a redirect to a non-web link is not followed', () {
      final rules = ClearUrls.fromJson({
        'providers': {
          'r': {
            'urlPattern': r'^https?://r\.example',
            'redirections': [r'^https?://r\.example/\?to=([^&]*)'],
          },
        },
      });
      final wrapped = Uri.parse('https://r.example/?to=javascript%3Aalert(1)');
      expect(rules.clean(wrapped), wrapped);
    });
  });

  group('embed fixers', () {
    final fixers = filters.embedFixers;

    test('X and Twitter posts go to their default service', () {
      expect(
        fixers.fix(Uri.parse('https://x.com/user/status/123'))?.toString(),
        'https://fixupx.com/user/status/123',
      );
      expect(
        fixers
            .fix(Uri.parse('https://twitter.com/user/status/123'))
            ?.toString(),
        'https://fxtwitter.com/user/status/123',
      );
    });

    test('a failed service is skipped for the next one', () {
      final next = fixers.fix(
        Uri.parse('https://x.com/user/status/123'),
        failed: {'twitter:1'},
      );
      expect(next?.toString(), 'https://fixvx.com/user/status/123');
      expect(
        fixers.fix(
          Uri.parse('https://x.com/user/status/123'),
          failed: {'twitter:1', 'twitter:2'},
        ),
        isNull,
      );
    });

    test('a link that is not a post, or another site, is left alone', () {
      expect(fixers.fix(Uri.parse('https://x.com/user')), isNull);
      expect(fixers.fix(Uri.parse('https://example.org/x/status/1')), isNull);
    });

    test('a service link maps back to its original', () {
      final fixed = Uri.parse('https://fixupx.com/user/status/123');
      expect(
        fixers.originalOf(fixed).toString(),
        'https://x.com/user/status/123',
      );
      expect(fixers.serviceOf(fixed), 'twitter:1');
      expect(fixers.originalOf(Uri.parse('https://example.org/a')), isNull);
    });

    test('a path prefix and a wrapped link both map back', () {
      final clip = fixers.fix(Uri.parse('https://clips.twitch.tv/SomeClip'));
      expect(clip.toString(), 'https://fxtwitch.seria.moe/clip/SomeClip');
      expect(
        fixers.originalOf(clip!).toString(),
        'https://clips.twitch.tv/SomeClip',
      );

      // A wrap naming another site is not taken for a Threads original.
      expect(
        fixers.originalOf(
          Uri.parse(
            'https://fixembed.app/embed?url=https%3A%2F%2Fphish.example%2F',
          ),
        ),
        isNull,
      );
      final post = Uri.parse('https://www.threads.net/@someone/post/abc');
      final wrapped = fixers.fix(post, failed: {'threads:20', 'threads:21'});
      expect(wrapped?.host, 'fixembed.app');
      expect(fixers.originalOf(wrapped!), post);
    });

    test('alternates are the other services, then the original', () {
      final alternates = fixers.alternatesFor(
        Uri.parse('https://fixupx.com/user/status/123'),
      );
      expect(alternates.map((uri) => uri.toString()), [
        'https://fixvx.com/user/status/123',
        'https://x.com/user/status/123',
      ]);
    });

    test('no service with ads is in the list', () {
      final raw = File(LinkFilters.embedFixersAsset).readAsStringSync();
      expect(raw, isNot(contains('EmbedEZ')));
      expect(raw, isNot(contains('kkinstagram')));
      expect(EmbedFixers.fromJson(jsonDecode(raw)).siteCount, greaterThan(10));
    });
  });

  test('the link settings survive the vault\'s JSON', () {
    final saved = VaultSnapshot.empty().copyWith(
      keepLinkTracking: true,
      keepLinkSites: true,
      failedLinkFixers: {'twitter:1': '2026-10-20T12:00:00.000Z'},
    );
    final read = VaultSnapshot.fromJson(
      jsonDecode(jsonEncode(saved.toJson())) as Map<String, dynamic>,
    );
    expect(read.keepLinkTracking, isTrue);
    expect(read.keepLinkSites, isTrue);
    expect(read.failedLinkFixers, {'twitter:1': '2026-10-20T12:00:00.000Z'});
    final previewsOff = VaultSnapshot.fromJson(
      jsonDecode(
            jsonEncode(
              VaultSnapshot.empty().copyWith(linkPreviewMode: 'off').toJson(),
            ),
          )
          as Map<String, dynamic>,
    );
    expect(previewsOff.linkPreviewMode, 'off');
    // Defaults: cleaning on.
    final fresh = VaultSnapshot.fromJson(
      jsonDecode(jsonEncode(VaultSnapshot.empty().toJson()))
          as Map<String, dynamic>,
    );
    expect(fresh.keepLinkTracking, isFalse);
    expect(fresh.keepLinkSites, isFalse);
    expect(fresh.failedLinkFixers, isEmpty);
  });

  group('cleaning a message', () {
    test('tracking goes and posts move, as the settings allow', () {
      const text =
          'look https://x.com/a/status/1?s=20&t=abc and https://youtu.be/v?si=q.';
      final changes = filters.changesIn(text, const LinkPolicy());
      expect(
        applyLinkChanges(text, changes),
        'look https://fixupx.com/a/status/1 and https://youtu.be/v.',
      );

      final trackingOnly = filters.changesIn(
        text,
        const LinkPolicy(embedFriendly: false),
      );
      expect(
        applyLinkChanges(text, trackingOnly),
        'look https://x.com/a/status/1 and https://youtu.be/v.',
      );
      expect(filters.changesIn(text, LinkPolicy.off), isEmpty);
    });

    test('a link written as an exempt original stays', () {
      const text = 'https://youtu.be/v?si=q';
      expect(
        filters.changesIn(text, const LinkPolicy(), exempt: {text}),
        isEmpty,
      );
    });

    test('a clean link is not rewritten', () {
      const text = 'see https://example.org/a?id=1 and mailto:a@b.example';
      expect(filters.changesIn(text, const LinkPolicy()), isEmpty);
    });

    test('a link someone sent is never opened somewhere else', () {
      // ClearURLs would unwrap these; opening only drops tracking fields.
      for (final link in [
        'https://www.google.com/url?q=https%3A%2F%2Fphish.example%2F',
        'https://www.instagram.com/p/X/?u=https%3A%2F%2Fphish.example%2F',
        'https://www.google.com/search?q=cats&adurl=https://phish.example/',
      ]) {
        final opened = filters.forOpening(Uri.parse(link), const LinkPolicy());
        expect(opened.host, Uri.parse(link).host, reason: link);
      }
    });

    test('a link is kept as written: letters stay letters', () {
      const text = 'https://ru.wikipedia.org/wiki/Кошка?utm_source=x';
      expect(
        applyLinkChanges(text, filters.changesIn(text, const LinkPolicy())),
        'https://ru.wikipedia.org/wiki/Кошка',
      );
    });

    test('only a removed field or a redirect counts as cleaning', () {
      for (final text in [
        'https://example.org/a?&&b=1',
        'https://example.org/a?',
        'https://example.org/a#',
        'https://example.org/a/b%20c?x=1',
      ]) {
        expect(
          filters.changesIn(text, const LinkPolicy()),
          isEmpty,
          reason: text,
        );
      }
    });

    test('at most 50 links of one text are cleaned', () {
      final text = List.filled(60, 'https://youtu.be/v?si=q').join(' ');
      expect(
        filters.changesIn(text, const LinkPolicy()),
        hasLength(LinkFilters.maxLinksPerText),
      );
    });

    test('opening removes tracking but keeps the site', () {
      final opened = filters.forOpening(
        Uri.parse('https://x.com/a/status/1?utm_source=x'),
        const LinkPolicy(),
      );
      expect(opened.host, 'x.com');
      expect(opened.query, isEmpty);
    });
  });
}

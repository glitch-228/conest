import 'dart:typed_data';

import 'package:conest/src/links/link_preview.dart';
import 'package:conest/src/ui/link_preview_card.dart';
import 'package:conest/src/ui/link_preview_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class _Source implements LinkPreviewSource {
  bool enabled = true;
  bool automatic = true;
  bool fetchedHere = true;
  bool attaches = false;
  bool mayFetchNow = true;

  @override
  bool get linkPreviewsMayFetchNow => mayFetchNow;

  @override
  bool get linkPreviewsFetchedHere => fetchedHere;

  @override
  bool get linkPreviewsAttached => attaches;
  final cached = <Uri, LinkPreview>{};
  final asked = <Uri>[];

  @override
  bool get linkPreviewsEnabled => enabled;

  @override
  bool get linkPreviewsAutomaticNow => automatic;

  @override
  LinkPreview? cachedLinkPreview(Uri url) => cached[url];

  @override
  Future<LinkPreview?> loadLinkPreview(Uri url) async {
    asked.add(url);
    return LinkPreview(
      url: url,
      fetchedAt: DateTime.utc(2026, 10, 21),
      title: 'A fine post',
      description: 'What it says',
      siteName: 'Site',
      image: Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8))),
    );
  }
}

void main() {
  late _Source source;
  late List<Uri> opened;

  setUp(() {
    source = _Source();
    opened = [];
  });

  Future<void> pump(
    WidgetTester tester,
    String text, {
    required bool trusted,
    LinkPreview? attached,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LinkPreviewCard(
          text: text,
          source: source,
          trusted: trusted,
          attached: attached,
          openUrl: (uri) async => opened.add(uri),
          accent: Colors.blue,
          textColor: Colors.black,
        ),
      ),
    ),
  );

  testWidgets('in a contact\'s chat it comes by itself, and opens the link', (
    tester,
  ) async {
    await pump(tester, 'see https://site.example/post', trusted: true);
    await tester.pump();
    expect(source.asked, [Uri.parse('https://site.example/post')]);
    expect(find.text('A fine post'), findsOneWidget);
    expect(find.text('Site'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('link-preview-card')));
    await tester.pump();
    expect(opened, [Uri.parse('https://site.example/post')]);
  });

  testWidgets('a plain http link waits for a tap, even from a contact', (
    tester,
  ) async {
    await pump(tester, 'http://site.example/post', trusted: true);
    await tester.pump();
    expect(source.asked, isEmpty);
    expect(find.byKey(const ValueKey('link-preview-load')), findsOneWidget);
  });

  testWidgets('from a stranger it waits for a tap', (tester) async {
    await pump(tester, 'https://site.example/post', trusted: false);
    await tester.pump();
    expect(source.asked, isEmpty);
    expect(find.text('A fine post'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('link-preview-load')));
    await tester.pump();
    await tester.pump();
    expect(source.asked, hasLength(1));
    expect(find.text('A fine post'), findsOneWidget);
  });

  testWidgets('in battery saver or roaming, even contacts\' wait for a tap', (
    tester,
  ) async {
    source.automatic = false;
    await pump(tester, 'https://site.example/post', trusted: true);
    await tester.pump();
    expect(source.asked, isEmpty);
    expect(find.byKey(const ValueKey('link-preview-load')), findsOneWidget);
  });

  testWidgets('a kept preview shows at once; off or no link shows nothing', (
    tester,
  ) async {
    source.cached[Uri.parse('https://site.example/kept')] = LinkPreview(
      url: Uri.parse('https://site.example/kept'),
      fetchedAt: DateTime.utc(2026, 10, 21),
      title: 'Kept one',
    );
    await pump(tester, 'https://site.example/kept', trusted: false);
    expect(find.text('Kept one'), findsOneWidget);
    expect(source.asked, isEmpty);

    source.enabled = false;
    await pump(tester, 'https://site.example/other', trusted: true);
    await tester.pump();
    expect(source.asked, isEmpty);
    expect(find.byKey(const ValueKey('link-preview-load')), findsNothing);

    source.enabled = true;
    await pump(tester, 'no link here, mailto:a@b.example', trusted: true);
    await tester.pump();
    expect(source.asked, isEmpty);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('a preview its sender attached shows as it is, even from a '
      'stranger', (tester) async {
    await pump(
      tester,
      'https://site.example/post',
      trusted: false,
      attached: LinkPreview(
        url: Uri.parse('https://site.example/post'),
        fetchedAt: DateTime.utc(2026, 10, 21),
        title: 'From the sender',
      ),
    );
    await tester.pump();
    expect(find.text('From the sender'), findsOneWidget);
    expect(source.asked, isEmpty);
  });

  testWidgets('a sent preview names the link\'s own host and its sender, '
      'and a stranger\'s picture is not shown', (tester) async {
    source.fetchedHere = false;
    final attached = LinkPreview(
      url: Uri.parse('https://site.example/post'),
      fetchedAt: DateTime.utc(2026, 10, 21),
      title: 'Headline',
      siteName: 'Some Trusted News',
      image: Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8))),
    );
    await pump(
      tester,
      'https://site.example/post',
      trusted: false,
      attached: attached,
    );
    expect(find.text('site.example · preview from the sender'), findsOneWidget);
    expect(find.text('Some Trusted News'), findsNothing);
    expect(find.byType(Image), findsNothing);

    await pump(
      tester,
      'https://site.example/post',
      trusted: true,
      attached: attached,
    );
    expect(find.byType(Image), findsOneWidget);

    // A sent preview for another link (an edit changed it) is not shown.
    await pump(
      tester,
      'https://other.example/x',
      trusted: true,
      attached: attached,
    );
    expect(find.text('Headline'), findsNothing);
  });

  testWidgets('when this device fetches too, its own replaces the sent one', (
    tester,
  ) async {
    await pump(
      tester,
      'https://site.example/post',
      trusted: true,
      attached: LinkPreview(
        url: Uri.parse('https://site.example/post'),
        fetchedAt: DateTime.utc(2026, 10, 21),
        title: 'Claimed',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(source.asked, hasLength(1));
    expect(find.text('A fine post'), findsOneWidget);
    expect(find.text('Claimed'), findsNothing);
  });

  testWidgets('when only senders attach previews, nothing is fetched here', (
    tester,
  ) async {
    source.fetchedHere = false;
    await pump(tester, 'https://site.example/post', trusted: true);
    await tester.pump();
    expect(source.asked, isEmpty);
    expect(find.byKey(const ValueKey('link-preview-load')), findsNothing);
  });

  group('the message box', () {
    late TextEditingController text;

    setUp(() => text = TextEditingController());

    Future<void> box(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              LinkPreviewComposer(
                controller: text,
                source: source,
                accent: Colors.blue,
              ),
              TextField(controller: text),
            ],
          ),
        ),
      ),
    );

    testWidgets('when this device attaches previews, one comes with the '
        'link, and can be removed', (tester) async {
      source.attaches = true;
      await box(tester);
      text.text = 'look https://site.example/post';
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('composer-link-preview')),
        findsOneWidget,
      );
      expect(composerLinkPreview(text)?.title, 'A fine post');

      await tester.tap(
        find.byKey(const ValueKey('composer-link-preview-remove')),
      );
      await tester.pump();
      expect(composerLinkPreview(text), isNull);
      expect(find.byKey(const ValueKey('composer-link-preview')), findsNothing);

      // Another link gets its own.
      text.text = 'and https://other.example/x';
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
      expect(composerLinkPreview(text), isNotNull);
    });

    testWidgets('a link half typed is not fetched; once finished it is', (
      tester,
    ) async {
      source.attaches = true;
      await box(tester);
      // Typed a character at a time, with pauses.
      const link = 'https://site.example/post';
      for (var end = 1; end <= link.length; end++) {
        text.text = link.substring(0, end);
        await tester.pump(const Duration(milliseconds: 800));
      }
      expect(source.asked, isEmpty);
      text.text = 'https://site.example/post ';
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
      expect(source.asked, [Uri.parse('https://site.example/post')]);
    });

    testWidgets(
      'in battery saver or roaming nothing is fetched while writing',
      (tester) async {
        source.attaches = true;
        source.mayFetchNow = false;
        await box(tester);
        text.text = 'look https://site.example/post ';
        await tester.pump(const Duration(milliseconds: 800));
        expect(source.asked, isEmpty);
      },
    );

    testWidgets('otherwise nothing is fetched while writing', (tester) async {
      await box(tester);
      text.text = 'look https://site.example/post';
      await tester.pump(const Duration(milliseconds: 800));
      expect(source.asked, isEmpty);
      expect(composerLinkPreview(text), isNull);
    });
  });
}

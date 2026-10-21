import 'dart:typed_data';

import 'package:conest/src/links/link_preview.dart';
import 'package:conest/src/ui/link_preview_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class _Source implements LinkPreviewSource {
  bool enabled = true;
  bool automatic = true;
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
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LinkPreviewCard(
          text: text,
          source: source,
          trusted: trusted,
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
}

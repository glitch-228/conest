import 'package:conest/l10n/app_localizations.dart';
import 'package:conest/src/ui/linked_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

List<String> links(String text) => [
  for (final link in findLinks(text)) text.substring(link.start, link.end),
];

void main() {
  group('finding links', () {
    test('links with a scheme, www and mailto', () {
      expect(links('see https://example.com/a?b=1 now'), [
        'https://example.com/a?b=1',
      ]);
      expect(links('http://x.org'), ['http://x.org']);
      expect(links('www.example.com/page'), ['www.example.com/page']);
      expect(findLinks('www.example.com').single.uri.scheme, 'https');
      expect(links('write mailto:a@b.example'), ['mailto:a@b.example']);
    });

    test('punctuation after a link stays out', () {
      expect(links('Look: https://example.com/x.'), ['https://example.com/x']);
      expect(links('(see https://example.com/x)'), ['https://example.com/x']);
      expect(links('https://en.wikipedia.org/wiki/Foo_(bar)'), [
        'https://en.wikipedia.org/wiki/Foo_(bar)',
      ]);
      expect(links('"https://example.com/q"!'), ['https://example.com/q']);
    });

    test('things that only look like links are not', () {
      expect(links('e.g. this, version 1.2.3, a.b'), isEmpty);
      expect(links('ftp://example.com and javascript:alert(1)'), isEmpty);
      expect(links('https://localhost and https://nohost.'), isEmpty);
      expect(links('xwww.example.com'), isEmpty);
    });
  });

  group('the widget', () {
    Future<List<Uri>> pump(WidgetTester tester, String text) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SelectionArea(
              child: LinkedText(text, openUrl: (uri) async => opened.add(uri)),
            ),
          ),
        ),
      );
      return opened;
    }

    Offset linkAt(WidgetTester tester, String text, String link) {
      final rect = tester.getRect(find.byType(LinkedText));
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(LinkedText),
          matching: find.byType(RichText),
        ),
      );
      final start = text.indexOf(link);
      final box = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + 3),
          )
          .first;
      return rect.topLeft + box.toRect().center;
    }

    testWidgets('a tap on a link opens it', (tester) async {
      const text = 'go to https://example.com/page please';
      final opened = await pump(tester, text);
      await tester.tapAt(linkAt(tester, text, 'https://'));
      await tester.pump();
      expect(opened, [Uri.parse('https://example.com/page')]);
    });

    testWidgets('a lookalike address asks first', (tester) async {
      const text = 'https://аpple.com/login';
      final opened = await pump(tester, text);
      await tester.tapAt(linkAt(tester, text, 'https://'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(find.text('Open this link?'), findsOneWidget);
      // The address as written, not percent-encoded.
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('аpple.com'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('open-lookalike-link')));
      await tester.pumpAndSettle();
      expect(opened, hasLength(1));
    });

    testWidgets('text without links is plain text', (tester) async {
      await pump(tester, 'nothing to open here');
      expect(find.text('nothing to open here'), findsOneWidget);
    });
  });
}

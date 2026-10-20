import 'dart:io';

import 'package:conest/src/links/link_cleaner.dart';
import 'package:conest/src/ui/composer_keys.dart';
import 'package:conest/src/ui/link_cleaning.dart';
import 'package:conest/src/ui/linked_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final filters = LinkFilters.fromJson(
    clearUrls: File(LinkFilters.clearUrlsAsset).readAsStringSync(),
    embedFixers: File(LinkFilters.embedFixersAsset).readAsStringSync(),
  );
  late TextEditingController text;
  late List<String> sent;
  late LinkPolicy policy;
  late List<String> failed;

  setUp(() {
    text = TextEditingController();
    sent = [];
    policy = const LinkPolicy();
    failed = [];
    LinkFilters.current = filters;
  });
  tearDown(() => LinkFilters.current = null);

  Future<void> pump(WidgetTester tester, {bool settings = true}) async {
    final box = ComposerKeys(
      controller: text,
      onSend: () {
        finishComposerLinks(text);
        sent.add(text.text);
      },
      child: TextField(controller: text, minLines: 1, maxLines: 5),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: settings
              ? LinkSettings(
                  policy: () => policy,
                  onServiceFailed: failed.add,
                  child: box,
                )
              : box,
        ),
      ),
    );
  }

  void type(String more) {
    final value = text.text + more;
    text.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  testWidgets('a pasted link is cleaned at once, with Undo', (tester) async {
    await pump(tester);
    type('see ');
    type('https://youtu.be/v?si=abc');
    await tester.pump();
    expect(text.text, 'see https://youtu.be/v');
    expect(text.selection.baseOffset, text.text.length);
    expect(find.byKey(const ValueKey('link-cleaned-note')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('link-cleaned-undo')));
    await tester.pump();
    expect(text.text, 'see https://youtu.be/v?si=abc');
    expect(find.byKey(const ValueKey('link-cleaned-note')), findsNothing);

    // Put back by Undo, it stays as written, also when sent.
    type(' ok');
    await tester.pump();
    finishComposerLinks(text);
    expect(text.text, 'see https://youtu.be/v?si=abc ok');
  });

  testWidgets('a typed link is cleaned when a space ends it', (tester) async {
    text.text = 'https://x.com/a/status/1?s=2';
    await pump(tester);
    type('0');
    await tester.pump();
    // Still being typed.
    expect(text.text, 'https://x.com/a/status/1?s=20');
    type(' ');
    await tester.pump();
    expect(text.text, 'https://fixupx.com/a/status/1 ');
    expect(find.byKey(const ValueKey('link-cleaned-note')), findsOneWidget);
  });

  testWidgets('a link still being typed is cleaned when sent', (tester) async {
    text.text = 'look https://youtu.be/v?si=ab';
    await pump(tester);
    type('c');
    await tester.pump();
    expect(text.text, endsWith('si=abc'));
    await tester.tap(find.byType(TextField));
    // Ctrl+Enter sends on every platform.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(sent, ['look https://youtu.be/v']);
  });

  testWidgets('a link is cleaned at send, even mid-composition', (
    tester,
  ) async {
    await pump(tester);
    const link = 'see https://youtu.be/v?si=abc';
    text.value = const TextEditingValue(
      text: link,
      selection: TextSelection.collapsed(offset: link.length),
      composing: TextRange(start: 25, end: link.length),
    );
    await tester.pump();
    finishComposerLinks(text);
    expect(text.text, 'see https://youtu.be/v');
  });

  testWidgets('a punycode address asks before opening', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinkedText(
            key: const ValueKey('body'),
            'https://xn--pple-43d.com/login',
            openUrl: (uri) async => opened.add(uri),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('body')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(opened, isEmpty);
    expect(find.byKey(const ValueKey('open-lookalike-link')), findsOneWidget);
  });

  testWidgets('nothing changes while an input method composes', (tester) async {
    await pump(tester);
    const link = 'https://youtu.be/v?si=abc';
    text.value = const TextEditingValue(
      text: link,
      selection: TextSelection.collapsed(offset: link.length),
      composing: TextRange(start: 0, end: link.length),
    );
    await tester.pump();
    expect(text.text, link);
  });

  testWidgets('with the settings off, or none above, links stay', (
    tester,
  ) async {
    policy = LinkPolicy.off;
    await pump(tester);
    type('https://youtu.be/v?si=abc');
    await tester.pump();
    expect(text.text, 'https://youtu.be/v?si=abc');

    text = TextEditingController();
    await pump(tester, settings: false);
    type('https://youtu.be/v?si=abc');
    await tester.pump();
    expect(text.text, 'https://youtu.be/v?si=abc');
  });

  testWidgets('a failed service is skipped for the next one', (tester) async {
    policy = const LinkPolicy(failedServices: {'twitter:1'});
    await pump(tester);
    type('https://x.com/a/status/1');
    await tester.pump();
    expect(text.text, 'https://fixvx.com/a/status/1');
  });

  testWidgets('a received link opens without tracking, the text unchanged', (
    tester,
  ) async {
    final opened = <Uri>[];
    const body = 'https://x.com/a/status/1?utm_source=x';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinkSettings(
            policy: () => policy,
            onServiceFailed: failed.add,
            child: LinkedText(
              key: const ValueKey('body'),
              body,
              openUrl: (uri) async => opened.add(uri),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('body')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(opened.single.toString(), 'https://x.com/a/status/1');
    expect(find.text(body, findRichText: true), findsOneWidget);
  });

  testWidgets('Open original goes to the site and skips the service', (
    tester,
  ) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinkSettings(
            policy: () => policy,
            onServiceFailed: failed.add,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => openOriginalLink(
                  context,
                  (uri) async => opened.add(uri),
                  'it is at https://fixupx.com/a/status/1 now',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    expect(embedFixedLinkIn('https://fixupx.com/a/status/1'), isNotNull);
    expect(embedFixedLinkIn('https://example.org/a'), isNull);
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(opened.single.toString(), 'https://x.com/a/status/1');
    expect(failed, ['twitter:1']);
  });
}

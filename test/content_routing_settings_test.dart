import 'package:conest/src/content_routing.dart';
import 'package:conest/src/transport_models.dart';
import 'package:conest/src/ui/content_routing_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<ContentRefusals> saved;

  setUp(() => saved = []);

  Future<void> pump(
    WidgetTester tester, {
    ContentRefusals refusals = ContentRefusals.none,
    bool showTable = false,
  }) async {
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ContentRoutingSettings(
              refusals: refusals,
              showTable: showTable,
              onChanged: saved.add,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a preset is picked from the list', (tester) async {
    await pump(tester);
    expect(find.text('Everything'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('content-routing-preset')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('Messages only (files on the local network)').last,
    );
    await tester.pumpAndSettle();
    expect(saved, [ContentRoutingPreset.messagesOnly.refusals]);
  });

  testWidgets('a hand-made table shows as Custom', (tester) async {
    await pump(
      tester,
      refusals: ContentRefusals.none.withRefused(
        TransportKind.nostr,
        ContentClass.history,
        true,
      ),
    );
    expect(find.text('Custom'), findsOneWidget);
  });

  testWidgets('the table is for Advanced mode, and sets one cell at a time', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('content-routing-table')), findsNothing);

    await pump(tester, showTable: true);
    await tester.tap(find.byKey(const ValueKey('content-routing-table')));
    await tester.pumpAndSettle();
    // What a transport cannot carry is not offered.
    expect(find.byKey(const ValueKey('content-nostr-fileSmall')), findsNothing);
    final relayFiles = find.byKey(
      const ValueKey('content-conestRelay-fileSmall'),
    );
    expect(tester.widget<Checkbox>(relayFiles).value, true);
    await tester.ensureVisible(relayFiles);
    await tester.tap(relayFiles);
    await tester.pump();
    expect(saved, hasLength(1));
    expect(
      saved.single.refuses(TransportKind.conestRelay, ContentClass.fileSmall),
      true,
    );
    expect(
      saved.single.refuses(TransportKind.conestRelay, ContentClass.fileMedium),
      false,
    );
  });
}

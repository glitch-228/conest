import 'dart:typed_data';

import 'package:conest/l10n/app_localizations.dart';
import 'package:conest/l10n/app_localizations_en.dart';
import 'package:conest/src/bitchat/direct.dart';
import 'package:conest/src/bitchat_carrier.dart';
import 'package:conest/src/messenger_controller.dart';
import 'package:conest/src/ui/bitchat_chats_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ble_mesh.dart';

void registerBitchatHiddenControllerTests({
  required Future<MessengerController> Function(
    FakeBleNeighbourhood area,
    DateTime Function() now,
  )
  create,
}) {
  Future<void> until(bool Function() done) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!done() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue, reason: 'mesh event did not arrive');
  }

  Future<
    (
      MessengerController,
      BitchatCarrierChannel,
      List<BitchatMessageReceived>,
      FakeBleNeighbourhood,
      VoidCallback,
    )
  >
  setup(DateTime Function() now) async {
    final area = FakeBleNeighbourhood()..connect('alice', 'phone');
    final controller = await create(area, now);
    var disposed = false;
    void disposeController() {
      if (disposed) return;
      disposed = true;
      controller.dispose();
    }

    addTearDown(disposeController);
    await controller.enableBitchatCarrier();
    await until(
      () => controller.bitchatChannel?.state == BitchatCarrierState.running,
    );
    final direct = await BitchatDirect.create(
      nickname: 'nearby phone',
      noiseSeed: List.filled(32, 9),
      signingSeed: List.filled(32, 19),
      now: now,
    );
    final received = <BitchatMessageReceived>[];
    direct.events.listen((event) {
      if (event is BitchatMessageReceived) received.add(event);
    });
    final phone = BitchatCarrierChannel(
      config: BitchatCarrierConfig.create(now()),
      connector: () async => area.node('phone'),
      keyFor: (_) async => [],
      onFrame: (_, _) {},
      now: now,
    )..useDirect(direct, visible: true);
    addTearDown(() async {
      await phone.stop();
      await direct.close();
    });
    phone.start();
    await until(() => controller.bitchatNearbyPeers.isNotEmpty);
    return (controller, phone, received, area, disposeController);
  }

  test(
    'hidden nearby discovery uses one mesh connection and sends nothing',
    () async {
      var clock = DateTime.now();
      final (controller, phone, _, area, _) = await setup(() => clock);
      expect(controller.bitchatChannel!.direct!.listeningOnly, isTrue);
      expect(controller.bitchatReachable, isFalse);
      expect(controller.bitchatPeerId, isNull);
      expect(controller.bitchatNearbyPeers.single.nickname, 'nearby phone');
      // Only the phone's announce crossed the link: no Conest announce or answer.
      expect(area.airtime, hasLength(1));
      expect(phone.direct!.peers, isEmpty);
      final firstListener = controller.bitchatChannel;
      await expectLater(
        controller.sendBitchatDirectMessage(phone.direct!.peerIdHex, 'blocked'),
        throwsStateError,
      );
      expect(area.airtime, hasLength(1));
      clock = clock.add(const Duration(minutes: 5));
      expect(controller.bitchatNearbyPeers, isEmpty);
      expect(controller.bitchatChannel, same(firstListener));
      await controller.disableBitchatCarrier();
      expect(controller.bitchatChannel, isNull);
      expect(controller.bitchatNearbyPeers, isEmpty);
    },
  );

  testWidgets('Message fails closed if the mesh stops during consent', (
    tester,
  ) async {
    late MessengerController controller;
    late BitchatCarrierChannel phone;
    late FakeBleNeighbourhood area;
    late VoidCallback disposeController;
    await tester.runAsync(() async {
      final pair = await setup(DateTime.now);
      controller = pair.$1;
      phone = pair.$2;
      area = pair.$4;
      disposeController = pair.$5;
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BitchatChatsScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('bitchat-message-${phone.direct!.peerIdHex}')),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(controller.disableBitchatCarrier);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Could not start this chat. Try again.'), findsOneWidget);
    expect(controller.bitchatReachable, isFalse);
    expect(controller.bitchatPeerId, isNull);
    expect(find.byKey(const ValueKey('bitchat-composer')), findsNothing);
    expect(area.airtime, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async => disposeController());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('nearby list formats only the visible part of a crowded mesh', (
    tester,
  ) async {
    late MessengerController controller;
    late VoidCallback disposeController;
    await tester.runAsync(() async {
      final pair = await setup(DateTime.now);
      controller = pair.$1;
      disposeController = pair.$5;
      final now = DateTime.now();
      controller.bitchatChannel!.direct!.adoptPeers([
        for (var i = 0; i < 256; i++)
          BitchatPeer(
            peerId: i.toRadixString(16).padLeft(16, '0'),
            nickname: 'person $i',
            noiseKey: Uint8List(32),
            signingKey: Uint8List(32),
            lastSeen: now,
          ),
      ]);
    });
    final strings = _CountingNearbyStrings();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: [
          _CountingNearbyDelegate(strings),
          ...AppLocalizations.localizationsDelegates,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: BitchatChatsScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.bitchatNearbyPeers, hasLength(256));
    // Formatting work on the first frame is limited to the viewport/cache.
    expect(strings.lastHeardCalls, lessThan(40));
    expect(strings.lastHeardCalls, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async => disposeController());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'hidden Message asks before becoming reachable and opens the chat',
    (tester) async {
      late MessengerController controller;
      late BitchatCarrierChannel phone;
      late List<BitchatMessageReceived> received;
      late FakeBleNeighbourhood area;
      late VoidCallback disposeController;
      Future<void> pumpUntil(bool Function() done) async {
        final end = DateTime.now().add(const Duration(seconds: 5));
        while (!done() && DateTime.now().isBefore(end)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(done(), isTrue, reason: 'UI action did not complete');
      }

      await tester.runAsync(() async {
        (controller, phone, received, area, disposeController) = await setup(
          DateTime.now,
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BitchatChatsScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('nearby phone'), findsOneWidget);
      expect(find.textContaining('Last heard'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bitchat-mesh-chat')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.bitchatReachable, isFalse);
      expect(area.airtime, hasLength(1));
      await tester.pageBack();
      await tester.pumpAndSettle();
      final message = find.byKey(
        ValueKey('bitchat-message-${phone.direct!.peerIdHex}'),
      );
      await tester.tap(message);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.textContaining('become visible to bitchat users nearby'),
        findsOneWidget,
      );
      expect(controller.bitchatReachable, isFalse);
      expect(area.airtime, hasLength(1));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.bitchatReachable, isFalse);
      expect(controller.bitchatPeerId, isNull);
      expect(area.airtime, hasLength(1));
      expect(find.byKey(const ValueKey('bitchat-composer')), findsNothing);

      await tester.tap(message);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await pumpUntil(
        () =>
            controller.bitchatPeerId != null &&
            !controller.bitchatChannel!.direct!.listeningOnly &&
            phone.direct!.peer(controller.bitchatPeerId!) != null &&
            find
                .byKey(const ValueKey('bitchat-composer'))
                .evaluate()
                .isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(controller.bitchatReachable, isTrue);
      expect(controller.bitchatChannel!.direct!.listeningOnly, isFalse);
      expect(find.byKey(const ValueKey('bitchat-composer')), findsOneWidget);
      // Start first with the peer learned while hidden; the phone never wrote first.
      await tester.enterText(
        find.byKey(const ValueKey('bitchat-composer')),
        'first hello',
      );
      await tester.tap(find.byTooltip('Send'));
      await pumpUntil(() => received.isNotEmpty);
      expect(received.single.text, 'first hello');
      await tester.pumpAndSettle();
      // Already reachable: reopening skips the warning.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(message);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('bitchat-composer')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      var hidden = false;
      controller.setBitchatReachable(false).then((_) => hidden = true);
      await pumpUntil(() => hidden);
      await tester.pumpAndSettle();
      final hiddenAirtime = area.airtime.length;
      // Reading saved history is still possible without becoming visible.
      await tester.tap(find.text('nearby phone'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.bitchatReachable, isFalse);
      expect(controller.bitchatPeerId, isNull);
      expect(area.airtime, hasLength(hiddenAirtime));
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bitchat-composer')))
            .enabled,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        disposeController();
        await phone.stop();
      });
      await tester.pump(const Duration(seconds: 1));
    },
  );
}

class _CountingNearbyStrings extends AppLocalizationsEn {
  int lastHeardCalls = 0;

  @override
  String bitchatLastHeard(String time) {
    lastHeardCalls++;
    return super.bitchatLastHeard(time);
  }
}

class _CountingNearbyDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _CountingNearbyDelegate(this.strings);
  final _CountingNearbyStrings strings;

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'en';

  @override
  Future<AppLocalizations> load(Locale locale) async => strings;

  @override
  bool shouldReload(_CountingNearbyDelegate old) => false;
}

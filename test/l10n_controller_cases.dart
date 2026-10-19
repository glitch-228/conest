part of 'messenger_controller_test.dart';

void _localizationControllerTests() {
  for (final code in appLanguageNames.keys) {
    testWidgets('localized screens fit a phone in $code', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late MessengerController alice;
      late MessengerController bob;
      late ContactInvite invite;
      late GroupRecord group;
      await tester.runAsync(() async {
        final relay = _FakeRelayClient();
        alice = await _createController(
          relayClient: relay,
          displayName: 'Alice',
        );
        bob = await _createController(relayClient: relay, displayName: 'Bob');
        await _pairControllers(alice, bob);
        await alice.setUserMode(UserMode.normal);
        await alice.sendMessage(
          contact: alice.contacts.single,
          body: 'outgoing sample',
        );
        await bob.pollNow();
        await bob.sendMessage(
          contact: bob.contacts.single,
          body: 'incoming sample',
        );
        await alice.pollNow();
        group = await alice.createGroup(
          title: 'Group sample',
          members: alice.contacts,
        );
        await bob.pollNow();
        await alice.sendGroupMessage(
          groupId: group.groupId,
          body: 'outgoing group',
        );
        await bob.pollNow();
        await bob.sendGroupMessage(
          groupId: group.groupId,
          body: 'incoming group',
        );
        await alice.pollNow();
        invite = await alice.buildInvite();
      });
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      final updates = _createUpdateService();
      final theme = app.ConestThemeController.memory();
      addTearDown(updates.dispose);
      addTearDown(theme.dispose);
      final strings = lookupAppLocalizations(Locale(code));
      final rtl = {'ar', 'fa'}.contains(code);

      Future<void> show(Widget child) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(code),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: child,
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.takeException(),
          isNull,
          reason: '$code: ${child.runtimeType}',
        );
      }

      await show(
        app.HomeScreen(
          controller: alice,
          updateService: updates,
          buildInfo: _createBuildInfo(),
          themeController: theme,
          palette: app.ConestPalette(),
        ),
      );
      final row = find.byKey(
        ValueKey('courier-chat-${bob.identity!.deviceId}'),
      );
      expect(row, findsOneWidget);
      expect(
        Directionality.of(tester.element(row)),
        rtl ? TextDirection.rtl : TextDirection.ltr,
      );
      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 300));
      final text = find.text('outgoing sample').last;
      expect(text, findsOneWidget);
      // Measure the actual decorated message, not the full-width gesture row.
      final bubble = find
          .ancestor(of: text, matching: find.byType(AnimatedContainer))
          .first;
      final incoming = find
          .ancestor(
            of: find.text('incoming sample').last,
            matching: find.byType(AnimatedContainer),
          )
          .first;
      expect(
        tester.getCenter(bubble).dx,
        rtl ? lessThan(180) : greaterThan(180),
      );
      expect(
        tester.getCenter(incoming).dx,
        rtl ? greaterThan(180) : lessThan(180),
      );
      expect(tester.takeException(), isNull, reason: '$code: chat');

      await show(
        app.HomeScreen(
          controller: alice,
          updateService: updates,
          buildInfo: _createBuildInfo(),
          themeController: theme,
          palette: app.ConestPalette(),
        ),
      );
      final groupRow = find.byKey(ValueKey('courier-chat-${group.groupId}'));
      await tester.ensureVisible(groupRow);
      await tester.tap(groupRow);
      await tester.pump(const Duration(milliseconds: 300));
      final groupOutgoing = find
          .ancestor(
            of: find.text('outgoing group').last,
            matching: find.byType(AnimatedContainer),
          )
          .first;
      final groupIncoming = find
          .ancestor(
            of: find.text('incoming group').last,
            matching: find.byType(AnimatedContainer),
          )
          .first;
      expect(
        tester.getCenter(groupOutgoing).dx,
        rtl ? lessThan(180) : greaterThan(180),
      );
      expect(
        tester.getCenter(groupIncoming).dx,
        rtl ? greaterThan(180) : lessThan(180),
      );
      expect(tester.takeException(), isNull, reason: '$code: group chat');

      await show(
        Scaffold(
          body: app.ContactProfileDialog(
            fullscreenOnMobile: true,
            controller: alice,
            contact: alice.contacts.single,
            palette: app.ConestPalette(),
          ),
        ),
      );
      expect(find.text(strings.uiContactProfile1B3A0E), findsOneWidget);

      await show(
        Scaffold(
          body: app.SettingsDialog(
            fullscreenOnMobile: true,
            controller: alice,
            updateService: updates,
            themeController: theme,
            palette: app.ConestPalette(),
          ),
        ),
      );
      // Every settings page, opened from its category.
      for (final title in [
        'Personal / Preferences',
        'Devices',
        'Connectivity',
        'Network / Relay',
        'Storage',
        'Updates',
        'Danger',
      ]) {
        final category = find.byKey(ValueKey('settings-category-$title'));
        await tester.ensureVisible(category);
        await tester.tap(category);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester.takeException(),
          isNull,
          reason: '$code: Settings $title',
        );
        final back = find.byKey(const ValueKey('settings-back'));
        if (back.evaluate().isNotEmpty) {
          await tester.tap(back);
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await show(
        Scaffold(
          body: CallsList(controller: alice, onOpenContact: (_) {}),
        ),
      );
      expect(find.text(strings.callsEmpty), findsOneWidget);
      await show(
        app.InviteScreen(
          controller: alice,
          invite: invite,
          palette: app.ConestPalette(),
        ),
      );
      expect(find.text(strings.uiShareInviteDBCC1E), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    });
  }
}

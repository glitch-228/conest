import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conest/main.dart' as app;
import 'package:conest/src/app_storage.dart';

void main() {
  app.ConestPalette testPalette() {
    return app.ConestPalette.resolve(
      mode: app.ConestThemeMode.dark,
      platformBrightness: Brightness.light,
    );
  }

  testWidgets('desktop first launch shows default and ghost storage choices', (
    tester,
  ) async {
    final selections = <app.BootstrapProfileSelection>[];

    await tester.pumpWidget(
      MaterialApp(
        home: app.FirstLaunchStorageScreen(
          palette: testPalette(),
          portableSupported: true,
          createProfile: ({required mode, required unlockMode}) async {
            return AppStorageProfile(
              mode: mode,
              unlockMode: unlockMode,
              dataRoot: Directory.systemTemp,
            );
          },
          onProfileReady: selections.add,
        ),
      ),
    );

    expect(find.text('Default on this device'), findsOneWidget);
    expect(find.text('Ghost/portable beside the app'), findsOneWidget);
    expect(find.textContaining('best-effort privacy'), findsOneWidget);
    expect(find.textContaining('OS launch history'), findsOneWidget);
  });

  testWidgets(
    'phone first launch hides portable storage but offers passphrase',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: app.FirstLaunchStorageScreen(
            palette: testPalette(),
            portableSupported: false,
            createProfile: ({required mode, required unlockMode}) async {
              return AppStorageProfile(
                mode: mode,
                unlockMode: unlockMode,
                dataRoot: Directory.systemTemp,
              );
            },
            onProfileReady: (_) {},
          ),
        ),
      );

      expect(find.text('Default on this device'), findsOneWidget);
      expect(find.text('Ghost/portable beside the app'), findsNothing);
      expect(find.text('Passphrase unlock'), findsOneWidget);
    },
  );

  testWidgets('passphrase confirmation mismatch blocks setup', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: app.FirstLaunchStorageScreen(
          palette: testPalette(),
          portableSupported: true,
          createProfile: ({required mode, required unlockMode}) async {
            return AppStorageProfile(
              mode: mode,
              unlockMode: unlockMode,
              dataRoot: Directory.systemTemp,
              passphraseKdf: PassphraseKdfConfig(
                saltBase64: base64Encode(List<int>.filled(16, 1)),
                memory: 64,
                iterations: 1,
                parallelism: 1,
              ),
            );
          },
          onProfileReady: (_) {},
        ),
      ),
    );

    await tester.tap(find.text('Passphrase unlock'));
    await tester.pump();
    await tester.enterText(
      find.byKey(app.firstLaunchPassphraseFieldKey),
      'one',
    );
    await tester.enterText(
      find.byKey(app.firstLaunchConfirmPassphraseFieldKey),
      'two',
    );
    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(find.text('Passphrases do not match.'), findsOneWidget);
  });

  testWidgets(
    'passphrase profile shows unlock screen before app initialization',
    (tester) async {
      String? submittedPassphrase;
      final profile = AppStorageProfile(
        mode: AppStorageMode.device,
        unlockMode: VaultUnlockMode.passphrase,
        dataRoot: Directory.systemTemp,
        passphraseKdf: PassphraseKdfConfig(
          saltBase64: base64Encode(List<int>.filled(16, 2)),
          memory: 64,
          iterations: 1,
          parallelism: 1,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: app.PassphraseUnlockScreen(
            palette: testPalette(),
            profile: profile,
            onUnlock: (passphrase) {
              submittedPassphrase = passphrase;
            },
          ),
        ),
      );

      expect(find.text('Unlock Conest'), findsOneWidget);
      await tester.enterText(
        find.byKey(app.unlockPassphraseFieldKey),
        'secret',
      );
      await tester.tap(find.text('Unlock'));
      await tester.pump();

      expect(submittedPassphrase, 'secret');
    },
  );
}

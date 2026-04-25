import 'dart:io';

import 'package:conest/src/conest_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('theme mode storage codec falls back safely', () {
    expect(ConestThemeMode.fromStorage('light'), ConestThemeMode.light);
    expect(ConestThemeMode.fromStorage('dark'), ConestThemeMode.dark);
    expect(ConestThemeMode.fromStorage('adaptive'), ConestThemeMode.adaptive);
    expect(ConestThemeMode.fromStorage('missing'), ConestThemeMode.system);
    expect(ConestThemeMode.fromStorage(null), ConestThemeMode.system);
  });

  test('theme preference store persists selected mode', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conest_theme_test_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/theme.json');
    final store = ThemePreferenceStore(fileProvider: () async => file);

    expect(await store.loadThemeMode(), ConestThemeMode.system);

    await store.saveThemeMode(ConestThemeMode.dark);

    expect(await store.loadThemeMode(), ConestThemeMode.dark);
  });

  test(
    'theme controller loads, saves, and resolves concrete palettes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'conest_theme_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/theme.json');
      final store = ThemePreferenceStore(fileProvider: () async => file);
      final controller = ConestThemeController(store: store);
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(controller.mode, ConestThemeMode.system);

      await controller.setMode(ConestThemeMode.dark);
      expect(await store.loadThemeMode(), ConestThemeMode.dark);

      final palette = controller.resolve(platformBrightness: Brightness.light);
      expect(palette.brightness, Brightness.dark);
      expect(palette.isDark, isTrue);
    },
  );

  test(
    'adaptive theme uses dynamic colors when available and branded fallback otherwise',
    () {
      final dynamicScheme = ColorScheme.fromSeed(
        seedColor: Colors.teal,
        brightness: Brightness.light,
      );

      final dynamicPalette = ConestPalette.resolve(
        mode: ConestThemeMode.adaptive,
        platformBrightness: Brightness.light,
        lightDynamic: dynamicScheme,
      );
      expect(dynamicPalette.usingDynamicColor, isTrue);
      expect(dynamicPalette.primary, dynamicScheme.primary);

      final fallbackPalette = ConestPalette.resolve(
        mode: ConestThemeMode.adaptive,
        platformBrightness: Brightness.light,
      );
      expect(fallbackPalette.usingDynamicColor, isFalse);
      expect(fallbackPalette.primary, ConestPalette.mint);
      expect(fallbackPalette.secondary, ConestPalette.pink);
    },
  );

  testWidgets('resolved palette drives Material theme colors', (tester) async {
    final palette = ConestPalette.resolve(
      mode: ConestThemeMode.dark,
      platformBrightness: Brightness.light,
    );
    late ThemeData resolvedTheme;

    await tester.pumpWidget(
      MaterialApp(
        theme: palette.themeData(),
        home: Builder(
          builder: (context) {
            resolvedTheme = Theme.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(resolvedTheme.brightness, Brightness.dark);
    expect(resolvedTheme.colorScheme.primary, palette.primary);
    expect(resolvedTheme.scaffoldBackgroundColor, palette.appBackground);
  });
}

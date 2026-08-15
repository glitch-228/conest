import 'dart:io';

import 'package:conest/src/conest_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('theme mode storage codec falls back safely', () {
    expect(ConestThemeMode.fromStorage('light'), ConestThemeMode.light);
    expect(ConestThemeMode.fromStorage('dark'), ConestThemeMode.dark);
    expect(ConestThemeMode.fromStorage('black'), ConestThemeMode.black);
    expect(ConestThemeMode.fromStorage('adaptive'), ConestThemeMode.adaptive);
    expect(ConestThemeMode.fromStorage('missing'), ConestThemeMode.system);
    expect(ConestThemeMode.fromStorage(null), ConestThemeMode.system);
  });

  test('Signature tiers expose the design tokens', () {
    final dark = ConestPalette.resolve(
      mode: ConestThemeMode.dark,
      platformBrightness: Brightness.light,
    );
    expect(dark.tier, SignatureBrightness.dark);
    expect(dark.appBackground, const Color(0xFF0E1116));
    expect(dark.primary, ConestPalette.mint);
    expect(dark.glow, isTrue);

    final light = ConestPalette.resolve(
      mode: ConestThemeMode.light,
      platformBrightness: Brightness.dark,
    );
    expect(light.tier, SignatureBrightness.light);
    expect(light.brightness, Brightness.light);
    expect(light.appBackground, const Color(0xFFF4F2EC));
    // Light tier darkens the mint anchor for AA contrast on cream.
    expect(light.primary, const Color(0xFF00B86E));
    expect(light.glow, isFalse);

    final black = ConestPalette.resolve(
      mode: ConestThemeMode.black,
      platformBrightness: Brightness.light,
    );
    expect(black.tier, SignatureBrightness.black);
    expect(black.brightness, Brightness.dark);
    expect(black.appBackground, const Color(0xFF000000));
    expect(black.glow, isTrue);
  });

  test('decoration intensity persists and clamps', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conest_theme_deco_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/theme.json');
    final store = ThemePreferenceStore(fileProvider: () async => file);
    final controller = ConestThemeController(store: store);
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(
      controller.decorationIntensity,
      ThemePreferences.defaultDecorationIntensity,
    );

    await controller.setDecorationIntensity(9.0);
    expect(controller.decorationIntensity, 1.5); // clamped to max

    // Round-trips through the store independently of the mode.
    await controller.setMode(ConestThemeMode.black);
    final reloaded = await store.load();
    expect(reloaded.decorationIntensity, 1.5);
    expect(reloaded.mode, ConestThemeMode.black);
  });

  test('home layout persists and survives reload', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conest_theme_home_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/theme.json');
    final store = ThemePreferenceStore(fileProvider: () async => file);
    final controller = ConestThemeController(store: store);
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(controller.homeLayout, ConestHomeLayout.signalCards);

    await controller.setHomeLayout(ConestHomeLayout.stationFeed);
    expect(controller.homeLayout, ConestHomeLayout.stationFeed);

    final reloaded = await store.load();
    expect(reloaded.homeLayout, ConestHomeLayout.stationFeed);

    expect(ConestHomeLayout.fromStorage('classic'), ConestHomeLayout.classic);
    expect(ConestHomeLayout.fromStorage('bogus'), ConestHomeLayout.signalCards);
  });

  test('shell persists and survives reload', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conest_theme_shell_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/theme.json');
    final store = ThemePreferenceStore(fileProvider: () async => file);
    final controller = ConestThemeController(store: store);
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(controller.shell, ConestShell.signature);

    await controller.setShell(ConestShell.courier);
    expect(controller.shell, ConestShell.courier);

    // Shell, mode, decoration and home layout all coexist in the same file.
    await controller.setMode(ConestThemeMode.dark);
    final reloaded = await store.load();
    expect(reloaded.shell, ConestShell.courier);
    expect(reloaded.mode, ConestThemeMode.dark);

    expect(ConestShell.fromStorage('garrison'), ConestShell.garrison);
    expect(ConestShell.fromStorage('bogus'), ConestShell.signature);
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
      // The Signature light tier darkens the brand anchors for AA contrast on
      // cream; that is the correct no-wallpaper fallback on a light surface.
      expect(fallbackPalette.primary, const Color(0xFF00B86E));
      expect(fallbackPalette.secondary, const Color(0xFFE60068));

      final darkFallback = ConestPalette.resolve(
        mode: ConestThemeMode.adaptive,
        platformBrightness: Brightness.dark,
      );
      expect(darkFallback.usingDynamicColor, isFalse);
      expect(darkFallback.primary, ConestPalette.mint);
      expect(darkFallback.secondary, ConestPalette.pink);
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

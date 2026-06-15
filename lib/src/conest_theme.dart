import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Brightness tier of the Signature theme family. Material's [Brightness] only
/// distinguishes light/dark, but the design ships three modes — Dark, Light,
/// and Black (OLED) — that share the dark Material brightness while differing
/// in surface depth and glow. [SignatureBrightness] carries that third state.
enum SignatureBrightness { light, dark, black }

/// Structural layout of the peer/chats home, per the design's "Home layout"
/// tweak. [signalCards] is the dashboard of rich link tiles (default),
/// [stationFeed] is the operator packet-log, [classic] is the compact list.
enum ConestHomeLayout {
  signalCards,
  stationFeed,
  classic;

  static ConestHomeLayout fromStorage(String? value) {
    for (final layout in values) {
      if (layout.name == value) {
        return layout;
      }
    }
    return ConestHomeLayout.signalCards;
  }

  String get label => switch (this) {
    ConestHomeLayout.signalCards => 'Signal Cards',
    ConestHomeLayout.stationFeed => 'Station Feed',
    ConestHomeLayout.classic => 'Classic rows',
  };

  String get blurb => switch (this) {
    ConestHomeLayout.signalCards => 'Peers as dashboard link tiles.',
    ConestHomeLayout.stationFeed => 'A chronological packet/activity log.',
    ConestHomeLayout.classic => 'A compact one-line list.',
  };
}

/// Overall navigation shell. [signature] is Conest's native sidebar (whose
/// inner list is the [ConestHomeLayout]); [garrison] is a Discord-shaped rail
/// of cells; [courier] is a Telegram-shaped unified conversation list. All
/// reuse the same chat panels and speak Conest's vocabulary.
enum ConestShell {
  signature,
  garrison,
  courier;

  static ConestShell fromStorage(String? value) {
    for (final shell in values) {
      if (shell.name == value) {
        return shell;
      }
    }
    return ConestShell.signature;
  }

  String get label => switch (this) {
    ConestShell.signature => 'Signature',
    ConestShell.garrison => 'Garrison',
    ConestShell.courier => 'Courier',
  };

  String get blurb => switch (this) {
    ConestShell.signature => 'Conest\'s native dashboard sidebar.',
    ConestShell.garrison => 'Discord-shaped: a rail of cells + conversations.',
    ConestShell.courier => 'Telegram-shaped: one clean conversation list.',
  };
}

enum ConestThemeMode {
  system,
  light,
  dark,
  black,
  adaptive;

  static ConestThemeMode fromStorage(String? value) {
    for (final mode in values) {
      if (mode.name == value) {
        return mode;
      }
    }
    return ConestThemeMode.system;
  }

  String get label => switch (this) {
    ConestThemeMode.system => 'System',
    ConestThemeMode.light => 'Signature · Light',
    ConestThemeMode.dark => 'Signature · Dark',
    ConestThemeMode.black => 'Signature · Black (OLED)',
    ConestThemeMode.adaptive => 'Adaptive (wallpaper)',
  };
}

class ThemePreferenceStore {
  ThemePreferenceStore({required Future<File> Function() fileProvider})
    : _fileProvider = fileProvider;

  factory ThemePreferenceStore.app() {
    return ThemePreferenceStore.forRootProvider(getApplicationSupportDirectory);
  }

  factory ThemePreferenceStore.forRoot(Directory root) {
    return ThemePreferenceStore.forRootProvider(() async => root);
  }

  factory ThemePreferenceStore.forRootProvider(
    Future<Directory> Function() rootProvider,
  ) {
    return ThemePreferenceStore(
      fileProvider: () async {
        final directory = await rootProvider();
        return File(p.join(directory.path, 'conest_theme.json'));
      },
    );
  }

  final Future<File> Function() _fileProvider;

  Future<ThemePreferences> load() async {
    try {
      final file = await _fileProvider();
      if (!await file.exists()) {
        return const ThemePreferences.defaults();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, Object?>) {
        return ThemePreferences(
          mode: ConestThemeMode.fromStorage(decoded['themeMode'] as String?),
          decorationIntensity: _readIntensity(decoded['decorationIntensity']),
          homeLayout: ConestHomeLayout.fromStorage(
            decoded['homeLayout'] as String?,
          ),
          shell: ConestShell.fromStorage(decoded['shell'] as String?),
        );
      }
    } catch (_) {
      // Theme preferences are non-critical; corrupt or unavailable files fall
      // back to the safe default instead of blocking app startup.
    }
    return const ThemePreferences.defaults();
  }

  /// Back-compat shim retained for existing callers/tests that only care about
  /// the mode.
  Future<ConestThemeMode> loadThemeMode() async => (await load()).mode;

  Future<void> save(ThemePreferences prefs) async {
    final file = await _fileProvider();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'themeMode': prefs.mode.name,
        'decorationIntensity': prefs.decorationIntensity,
        'homeLayout': prefs.homeLayout.name,
        'shell': prefs.shell.name,
      }),
    );
  }

  Future<void> saveThemeMode(ConestThemeMode mode) async {
    final current = await load();
    await save(current.copyWith(mode: mode));
  }

  static double _readIntensity(Object? raw) {
    if (raw is num) {
      return raw.toDouble().clamp(0.0, 1.5);
    }
    return ThemePreferences.defaultDecorationIntensity;
  }
}

/// User-facing theme preferences persisted in `conest_theme.json`.
class ThemePreferences {
  const ThemePreferences({
    required this.mode,
    required this.decorationIntensity,
    this.homeLayout = ConestHomeLayout.signalCards,
    this.shell = ConestShell.signature,
  });

  const ThemePreferences.defaults()
    : mode = ConestThemeMode.system,
      decorationIntensity = defaultDecorationIntensity,
      homeLayout = ConestHomeLayout.signalCards,
      shell = ConestShell.signature;

  /// Subtle-by-default Signature ambience. 0 = clean, 1.5 = full atmosphere.
  static const double defaultDecorationIntensity = 1.0;

  final ConestThemeMode mode;
  final double decorationIntensity;
  final ConestHomeLayout homeLayout;
  final ConestShell shell;

  ThemePreferences copyWith({
    ConestThemeMode? mode,
    double? decorationIntensity,
    ConestHomeLayout? homeLayout,
    ConestShell? shell,
  }) {
    return ThemePreferences(
      mode: mode ?? this.mode,
      decorationIntensity: decorationIntensity ?? this.decorationIntensity,
      homeLayout: homeLayout ?? this.homeLayout,
      shell: shell ?? this.shell,
    );
  }
}

class ConestThemeController extends ChangeNotifier {
  ConestThemeController({required ThemePreferenceStore store}) : _store = store;

  ConestThemeController.memory({
    ConestThemeMode initialMode = ConestThemeMode.system,
    double initialDecorationIntensity =
        ThemePreferences.defaultDecorationIntensity,
  }) : _store = ThemePreferenceStore(
         fileProvider: () async =>
             File('${Directory.systemTemp.path}/conest_theme_memory.json'),
       ),
       _prefs = ThemePreferences(
         mode: initialMode,
         decorationIntensity: initialDecorationIntensity,
       );

  final ThemePreferenceStore _store;
  ThemePreferences _prefs = const ThemePreferences.defaults();
  bool _initialized = false;

  ConestThemeMode get mode => _prefs.mode;
  double get decorationIntensity => _prefs.decorationIntensity;
  ConestHomeLayout get homeLayout => _prefs.homeLayout;
  ConestShell get shell => _prefs.shell;
  bool get initialized => _initialized;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _prefs = await _store.load();
    _initialized = true;
    notifyListeners();
  }

  Future<void> setMode(ConestThemeMode mode) async {
    if (_prefs.mode == mode) {
      return;
    }
    _prefs = _prefs.copyWith(mode: mode);
    notifyListeners();
    await _store.save(_prefs);
  }

  Future<void> setDecorationIntensity(double intensity) async {
    final clamped = intensity.clamp(0.0, 1.5);
    if (_prefs.decorationIntensity == clamped) {
      return;
    }
    _prefs = _prefs.copyWith(decorationIntensity: clamped);
    notifyListeners();
    await _store.save(_prefs);
  }

  Future<void> setHomeLayout(ConestHomeLayout layout) async {
    if (_prefs.homeLayout == layout) {
      return;
    }
    _prefs = _prefs.copyWith(homeLayout: layout);
    notifyListeners();
    await _store.save(_prefs);
  }

  Future<void> setShell(ConestShell shell) async {
    if (_prefs.shell == shell) {
      return;
    }
    _prefs = _prefs.copyWith(shell: shell);
    notifyListeners();
    await _store.save(_prefs);
  }

  ConestPalette resolve({
    required Brightness platformBrightness,
    ColorScheme? lightDynamic,
    ColorScheme? darkDynamic,
  }) {
    return ConestPalette.resolve(
      mode: _prefs.mode,
      platformBrightness: platformBrightness,
      lightDynamic: lightDynamic,
      darkDynamic: darkDynamic,
    );
  }
}

class ConestPalette {
  factory ConestPalette({
    ConestThemeMode mode = ConestThemeMode.system,
    Brightness brightness = Brightness.light,
  }) {
    return ConestPalette.resolve(mode: mode, platformBrightness: brightness);
  }

  // ── Brand anchors + design tokens (shared across the Signature family) ──
  static const mint = Color(0xFF0EFF9A);
  static const pink = Color(0xFFFF0E73);

  /// Signature geometry — radii 10 / 4 / 18.
  static const double radius = 10;
  static const double radiusSm = 4;
  static const double radiusLg = 18;

  /// Bundled OFL families (see assets/fonts). [displayFont] is body + display;
  /// [monoFont] backs the mono section labels, chips, and message receipts.
  static const String displayFont = 'SpaceGrotesk';
  static const String monoFont = 'JetBrainsMono';

  final ConestThemeMode mode;
  final Brightness brightness;

  /// Which of the three Signature tiers produced this palette. Drives the
  /// decoration overlay (light skips scanlines, black gets stronger glow).
  final SignatureBrightness tier;

  /// True when the theme wants mint/pink glow (drop shadows, bloom). Off on
  /// the light tier where glow reads as muddy on cream surfaces.
  final bool glow;

  final bool usingDynamicColor;
  final Color appBackground;
  final Color backgroundGlowStart;
  final Color backgroundGlowEnd;
  final Color panel;
  final Color panelStrong;
  final Color panel2;
  final Color panel3;
  final Color surface;
  final Color surfaceElevated;
  final Color border;
  final Color borderStrong;
  final Color textPrimary;
  final Color textMuted;
  final Color textFaint;
  final Color primary;
  final Color onPrimary;
  final Color secondary;
  final Color onSecondary;
  final Color accent2;
  final Color success;
  final Color warning;
  final Color danger;
  final Color unread;
  final Color selection;
  final Color chipBackground;
  final Color inputFill;
  final Color outboundBubble;
  final Color outboundBubbleEnd;
  final Color outboundText;
  final Color outboundMeta;
  final Color inboundBubble;
  final Color inboundText;
  final Color inboundMeta;
  final Color qrInk;
  final Color shadow;

  Color get paper => surface;
  Color get paperStrong => panel;
  Color get ink => textPrimary;
  Color get inkSoft => textMuted;
  Color get inkFaint => textFaint;
  Color get ember => secondary;
  Color get stroke => border;
  bool get isDark => brightness == Brightness.dark;
  bool get isLight => brightness == Brightness.light;

  /// Mint→teal gradient for the outbound (self) chat bubble. Falls back to a
  /// flat fill where a gradient isn't wanted via [outboundBubble].
  LinearGradient get outboundBubbleGradient => LinearGradient(
    colors: [outboundBubble, outboundBubbleEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  LinearGradient get appGradient => LinearGradient(
    colors: [backgroundGlowStart, appBackground, backgroundGlowEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static ConestPalette resolve({
    required ConestThemeMode mode,
    required Brightness platformBrightness,
    ColorScheme? lightDynamic,
    ColorScheme? darkDynamic,
  }) {
    final tier = switch (mode) {
      ConestThemeMode.light => SignatureBrightness.light,
      ConestThemeMode.dark => SignatureBrightness.dark,
      ConestThemeMode.black => SignatureBrightness.black,
      ConestThemeMode.system || ConestThemeMode.adaptive =>
        platformBrightness == Brightness.dark
            ? SignatureBrightness.dark
            : SignatureBrightness.light,
    };
    if (mode == ConestThemeMode.adaptive) {
      final dynamicScheme = tier == SignatureBrightness.light
          ? lightDynamic
          : darkDynamic;
      if (dynamicScheme != null) {
        return _branded(
          mode: mode,
          tier: tier,
          primary: dynamicScheme.primary,
          secondary: dynamicScheme.secondary,
          usingDynamicColor: true,
        );
      }
    }
    return _branded(mode: mode, tier: tier);
  }

  static ConestPalette _branded({
    required ConestThemeMode mode,
    required SignatureBrightness tier,
    Color? primary,
    Color? secondary,
    bool usingDynamicColor = false,
  }) {
    switch (tier) {
      case SignatureBrightness.light:
        return _signatureLight(
          mode: mode,
          primary: primary,
          secondary: secondary,
          usingDynamicColor: usingDynamicColor,
        );
      case SignatureBrightness.dark:
        return _signatureDark(
          mode: mode,
          primary: primary,
          secondary: secondary,
          usingDynamicColor: usingDynamicColor,
        );
      case SignatureBrightness.black:
        return _signatureBlack(
          mode: mode,
          primary: primary,
          secondary: secondary,
          usingDynamicColor: usingDynamicColor,
        );
    }
  }

  // ── Signature · Dark — graphite #0E1116, mint/pink anchors, glow on ──
  static ConestPalette _signatureDark({
    required ConestThemeMode mode,
    Color? primary,
    Color? secondary,
    bool usingDynamicColor = false,
  }) {
    final accent = primary ?? mint;
    final emphasis = secondary ?? pink;
    const bg = Color(0xFF0E1116);
    return ConestPalette._raw(
      mode: mode,
      brightness: Brightness.dark,
      tier: SignatureBrightness.dark,
      glow: true,
      usingDynamicColor: usingDynamicColor,
      appBackground: bg,
      backgroundGlowStart: Color.alphaBlend(accent.withValues(alpha: 0.07), bg),
      backgroundGlowEnd: Color.alphaBlend(emphasis.withValues(alpha: 0.05), bg),
      panel: const Color(0xFF161A21),
      panelStrong: const Color(0xFF1D222B),
      panel2: const Color(0xFF1D222B),
      panel3: const Color(0xFF262B36),
      surface: bg,
      surfaceElevated: const Color(0xFF262B36),
      border: const Color(0xFF262C36),
      borderStrong: const Color(0xFF3A4150),
      textPrimary: const Color(0xFFE8ECF1),
      textMuted: const Color(0xFF8E96A2),
      textFaint: const Color(0xFF5C6470),
      primary: accent,
      onPrimary: const Color(0xFF001A10),
      secondary: emphasis,
      onSecondary: Colors.white,
      accent2: const Color(0xFF00D4FF),
      success: accent,
      warning: const Color(0xFFFFCB47),
      danger: const Color(0xFFFF5A6A),
      unread: emphasis,
      selection: accent.withValues(alpha: 0.16),
      chipBackground: const Color(0xFF1D222B),
      inputFill: const Color(0xFF1D222B),
      outboundBubble: accent,
      outboundBubbleEnd: const Color(0xFF0BD685),
      outboundText: const Color(0xFF001A10),
      outboundMeta: const Color(0xCC001A10),
      inboundBubble: const Color(0xFF1D222B),
      inboundText: const Color(0xFFE8ECF1),
      inboundMeta: const Color(0xFF8E96A2),
      qrInk: const Color(0xFF111111),
      shadow: Colors.black.withValues(alpha: 0.40),
    );
  }

  // ── Signature · Black (OLED) — true black, elevated panels, full glow ──
  static ConestPalette _signatureBlack({
    required ConestThemeMode mode,
    Color? primary,
    Color? secondary,
    bool usingDynamicColor = false,
  }) {
    final accent = primary ?? mint;
    final emphasis = secondary ?? pink;
    const bg = Color(0xFF000000);
    return ConestPalette._raw(
      mode: mode,
      brightness: Brightness.dark,
      tier: SignatureBrightness.black,
      glow: true,
      usingDynamicColor: usingDynamicColor,
      appBackground: bg,
      backgroundGlowStart: Color.alphaBlend(accent.withValues(alpha: 0.10), bg),
      backgroundGlowEnd: Color.alphaBlend(emphasis.withValues(alpha: 0.07), bg),
      panel: const Color(0xFF070707),
      panelStrong: const Color(0xFF0D0D0D),
      panel2: const Color(0xFF0D0D0D),
      panel3: const Color(0xFF141414),
      surface: bg,
      surfaceElevated: const Color(0xFF141414),
      border: const Color(0xFF1C1C1C),
      borderStrong: const Color(0xFF2C2C2C),
      textPrimary: const Color(0xFFF2F3F5),
      textMuted: const Color(0xFF8E96A2),
      textFaint: const Color(0xFF5C6470),
      primary: accent,
      onPrimary: const Color(0xFF001A10),
      secondary: emphasis,
      onSecondary: Colors.white,
      accent2: const Color(0xFF00D4FF),
      success: accent,
      warning: const Color(0xFFFFCB47),
      danger: const Color(0xFFFF5A6A),
      unread: emphasis,
      selection: accent.withValues(alpha: 0.18),
      chipBackground: const Color(0xFF0D0D0D),
      inputFill: const Color(0xFF0D0D0D),
      outboundBubble: accent,
      outboundBubbleEnd: const Color(0xFF0BD685),
      outboundText: const Color(0xFF001A10),
      outboundMeta: const Color(0xCC001A10),
      inboundBubble: const Color(0xFF0D0D0D),
      inboundText: const Color(0xFFF2F3F5),
      inboundMeta: const Color(0xFF8E96A2),
      qrInk: const Color(0xFF111111),
      shadow: Colors.black.withValues(alpha: 0.55),
    );
  }

  // ── Signature · Light — warm off-white #F4F2EC, AA-darkened mint/pink ──
  static ConestPalette _signatureLight({
    required ConestThemeMode mode,
    Color? primary,
    Color? secondary,
    bool usingDynamicColor = false,
  }) {
    // Light tier darkens the brand anchors for AA contrast on cream surfaces.
    final accent = primary ?? const Color(0xFF00B86E);
    final emphasis = secondary ?? const Color(0xFFE60068);
    const bg = Color(0xFFF4F2EC);
    return ConestPalette._raw(
      mode: mode,
      brightness: Brightness.light,
      tier: SignatureBrightness.light,
      glow: false,
      usingDynamicColor: usingDynamicColor,
      appBackground: bg,
      backgroundGlowStart: Color.alphaBlend(accent.withValues(alpha: 0.10), bg),
      backgroundGlowEnd: Color.alphaBlend(emphasis.withValues(alpha: 0.06), bg),
      panel: const Color(0xFFFBFAF6),
      panelStrong: const Color(0xFFEDEAE0),
      panel2: const Color(0xFFEDEAE0),
      panel3: const Color(0xFFDCD7C8),
      surface: bg,
      surfaceElevated: const Color(0xFFFBFAF6),
      border: const Color(0xFFD5D0C0),
      borderStrong: const Color(0xFF2A2620),
      textPrimary: const Color(0xFF0E0F11),
      textMuted: const Color(0xFF5A5651),
      textFaint: const Color(0xFF8A8580),
      primary: accent,
      onPrimary: Colors.white,
      secondary: emphasis,
      onSecondary: Colors.white,
      accent2: const Color(0xFF0078A8),
      success: const Color(0xFF00B86E),
      warning: const Color(0xFFB68213),
      danger: const Color(0xFFB81A2B),
      unread: emphasis,
      selection: accent.withValues(alpha: 0.18),
      chipBackground: const Color(0xFFEDEAE0),
      inputFill: const Color(0xFFFBFAF6),
      outboundBubble: accent,
      outboundBubbleEnd: const Color(0xFF009E5C),
      outboundText: Colors.white,
      outboundMeta: const Color(0xE6FFFFFF),
      inboundBubble: const Color(0xFFFBFAF6),
      inboundText: const Color(0xFF0E0F11),
      inboundMeta: const Color(0xFF5A5651),
      qrInk: const Color(0xFF111111),
      shadow: const Color(0x1F111827),
    );
  }

  const ConestPalette._raw({
    required this.mode,
    required this.brightness,
    required this.tier,
    required this.glow,
    required this.usingDynamicColor,
    required this.appBackground,
    required this.backgroundGlowStart,
    required this.backgroundGlowEnd,
    required this.panel,
    required this.panelStrong,
    required this.panel2,
    required this.panel3,
    required this.surface,
    required this.surfaceElevated,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textMuted,
    required this.textFaint,
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.onSecondary,
    required this.accent2,
    required this.success,
    required this.warning,
    required this.danger,
    required this.unread,
    required this.selection,
    required this.chipBackground,
    required this.inputFill,
    required this.outboundBubble,
    required this.outboundBubbleEnd,
    required this.outboundText,
    required this.outboundMeta,
    required this.inboundBubble,
    required this.inboundText,
    required this.inboundMeta,
    required this.qrInk,
    required this.shadow,
  });

  ThemeData themeData() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: brightness,
        ).copyWith(
          primary: primary,
          onPrimary: onPrimary,
          secondary: secondary,
          onSecondary: onSecondary,
          surface: surface,
          onSurface: textPrimary,
          error: danger,
          outline: border,
        );
    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radiusLg),
      side: BorderSide(color: border),
    );
    final inputShape = OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: border),
    );
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    final baseTextTheme = ThemeData(brightness: brightness).textTheme.apply(
      bodyColor: textPrimary,
      displayColor: textPrimary,
      fontFamily: displayFont,
    );
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: appBackground,
      colorScheme: scheme,
      fontFamily: displayFont,
      useMaterial3: true,
      dividerTheme: DividerThemeData(color: border, thickness: 1),
      cardTheme: CardThemeData(
        elevation: 0,
        color: panel,
        surfaceTintColor: Colors.transparent,
        shadowColor: shadow,
        shape: cardShape,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
        ),
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          fontFamily: displayFont,
        ),
      ),
      textTheme: baseTextTheme,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputFill,
        labelStyle: TextStyle(color: textMuted),
        hintStyle: TextStyle(color: textMuted),
        border: inputShape,
        enabledBorder: inputShape,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          disabledBackgroundColor: textMuted.withValues(alpha: 0.22),
          disabledForegroundColor: textMuted,
          shape: buttonShape,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: BorderSide(color: borderStrong),
          shape: buttonShape,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          shape: buttonShape,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: chipBackground,
        selectedColor: selection,
        disabledColor: textMuted.withValues(alpha: 0.12),
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        labelStyle: TextStyle(color: textPrimary),
        secondaryLabelStyle: TextStyle(color: textPrimary),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: textPrimary),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surfaceElevated,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(color: textPrimary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primary;
          }
          return textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primary.withValues(alpha: 0.32);
          }
          return border;
        }),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return selection;
            }
            return chipBackground;
          }),
          foregroundColor: WidgetStatePropertyAll(textPrimary),
          side: WidgetStatePropertyAll(BorderSide(color: border)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
          ),
        ),
      ),
    );
  }
}

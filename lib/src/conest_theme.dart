import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum ConestThemeMode {
  system,
  light,
  dark,
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
    ConestThemeMode.light => 'Light',
    ConestThemeMode.dark => 'Dark',
    ConestThemeMode.adaptive => 'Adaptive',
  };
}

class ThemePreferenceStore {
  ThemePreferenceStore({required Future<File> Function() fileProvider})
    : _fileProvider = fileProvider;

  factory ThemePreferenceStore.app() {
    return ThemePreferenceStore(
      fileProvider: () async {
        final directory = await getApplicationSupportDirectory();
        return File(p.join(directory.path, 'conest_theme.json'));
      },
    );
  }

  final Future<File> Function() _fileProvider;

  Future<ConestThemeMode> loadThemeMode() async {
    try {
      final file = await _fileProvider();
      if (!await file.exists()) {
        return ConestThemeMode.system;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, Object?>) {
        return ConestThemeMode.fromStorage(decoded['themeMode'] as String?);
      }
    } catch (_) {
      // Theme preferences are non-critical; corrupt or unavailable files fall
      // back to the safe default instead of blocking app startup.
    }
    return ConestThemeMode.system;
  }

  Future<void> saveThemeMode(ConestThemeMode mode) async {
    final file = await _fileProvider();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({'themeMode': mode.name}),
    );
  }
}

class ConestThemeController extends ChangeNotifier {
  ConestThemeController({required ThemePreferenceStore store}) : _store = store;

  ConestThemeController.memory({
    ConestThemeMode initialMode = ConestThemeMode.system,
  }) : _store = ThemePreferenceStore(
         fileProvider: () async =>
             File('${Directory.systemTemp.path}/conest_theme_memory.json'),
       ),
       _mode = initialMode;

  final ThemePreferenceStore _store;
  ConestThemeMode _mode = ConestThemeMode.system;
  bool _initialized = false;

  ConestThemeMode get mode => _mode;
  bool get initialized => _initialized;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _mode = await _store.loadThemeMode();
    _initialized = true;
    notifyListeners();
  }

  Future<void> setMode(ConestThemeMode mode) async {
    if (_mode == mode) {
      return;
    }
    _mode = mode;
    notifyListeners();
    await _store.saveThemeMode(mode);
  }

  ConestPalette resolve({
    required Brightness platformBrightness,
    ColorScheme? lightDynamic,
    ColorScheme? darkDynamic,
  }) {
    return ConestPalette.resolve(
      mode: _mode,
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

  static const mint = Color(0xFF0EFF9A);
  static const pink = Color(0xFFFF0E73);

  final ConestThemeMode mode;
  final Brightness brightness;
  final bool usingDynamicColor;
  final Color appBackground;
  final Color backgroundGlowStart;
  final Color backgroundGlowEnd;
  final Color panel;
  final Color panelStrong;
  final Color surface;
  final Color surfaceElevated;
  final Color border;
  final Color borderStrong;
  final Color textPrimary;
  final Color textMuted;
  final Color primary;
  final Color onPrimary;
  final Color secondary;
  final Color onSecondary;
  final Color success;
  final Color warning;
  final Color danger;
  final Color unread;
  final Color selection;
  final Color chipBackground;
  final Color inputFill;
  final Color outboundBubble;
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
  Color get ember => secondary;
  Color get stroke => border;
  bool get isDark => brightness == Brightness.dark;

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
    final brightness = switch (mode) {
      ConestThemeMode.light => Brightness.light,
      ConestThemeMode.dark => Brightness.dark,
      ConestThemeMode.system || ConestThemeMode.adaptive => platformBrightness,
    };
    if (mode == ConestThemeMode.adaptive) {
      final dynamicScheme = brightness == Brightness.dark
          ? darkDynamic
          : lightDynamic;
      if (dynamicScheme != null) {
        return _branded(
          mode: mode,
          brightness: brightness,
          primary: dynamicScheme.primary,
          secondary: dynamicScheme.secondary,
          usingDynamicColor: true,
        );
      }
    }
    return _branded(mode: mode, brightness: brightness);
  }

  static ConestPalette _branded({
    required ConestThemeMode mode,
    required Brightness brightness,
    Color? primary,
    Color? secondary,
    bool usingDynamicColor = false,
  }) {
    final accent = primary ?? mint;
    final emphasis = secondary ?? pink;
    if (brightness == Brightness.dark) {
      return ConestPalette._raw(
        mode: mode,
        brightness: brightness,
        usingDynamicColor: usingDynamicColor,
        appBackground: const Color(0xFF080B0F),
        backgroundGlowStart: Color.alphaBlend(
          accent.withValues(alpha: 0.13),
          const Color(0xFF07100E),
        ),
        backgroundGlowEnd: Color.alphaBlend(
          emphasis.withValues(alpha: 0.13),
          const Color(0xFF120811),
        ),
        panel: const Color(0xFF111821),
        panelStrong: const Color(0xFF18212E),
        surface: const Color(0xFF0D131B),
        surfaceElevated: const Color(0xFF202B39),
        border: const Color(0xFF2D394A),
        borderStrong: accent.withValues(alpha: 0.42),
        textPrimary: const Color(0xFFEAF7F1),
        textMuted: const Color(0xFFA2AFBF),
        primary: accent,
        onPrimary: const Color(0xFF03120C),
        secondary: emphasis,
        onSecondary: Colors.white,
        success: accent,
        warning: const Color(0xFFFFC857),
        danger: const Color(0xFFFF5C7C),
        unread: emphasis,
        selection: accent.withValues(alpha: 0.16),
        chipBackground: const Color(0xFF131D28),
        inputFill: const Color(0xFF0A1118),
        outboundBubble: const Color(0xFF102A24),
        outboundText: const Color(0xFFEFFFF8),
        outboundMeta: const Color(0xFFA7D7C6),
        inboundBubble: const Color(0xFF1A2330),
        inboundText: const Color(0xFFEAF7F1),
        inboundMeta: const Color(0xFFA2AFBF),
        qrInk: const Color(0xFF111111),
        shadow: Colors.black.withValues(alpha: 0.34),
      );
    }
    return ConestPalette._raw(
      mode: mode,
      brightness: brightness,
      usingDynamicColor: usingDynamicColor,
      appBackground: const Color(0xFFF6F2EB),
      backgroundGlowStart: Color.alphaBlend(
        accent.withValues(alpha: 0.17),
        const Color(0xFFF8FFF9),
      ),
      backgroundGlowEnd: Color.alphaBlend(
        emphasis.withValues(alpha: 0.12),
        const Color(0xFFFFF6F7),
      ),
      panel: const Color(0xFFFFFBF4),
      panelStrong: Colors.white,
      surface: const Color(0xFFF9F4EC),
      surfaceElevated: Colors.white,
      border: const Color(0xFFD8CEC1),
      borderStrong: const Color(0xFF92C8B1),
      textPrimary: const Color(0xFF151B24),
      textMuted: const Color(0xFF657182),
      primary: accent,
      onPrimary: const Color(0xFF03120C),
      secondary: emphasis,
      onSecondary: Colors.white,
      success: const Color(0xFF168A59),
      warning: const Color(0xFFB56A00),
      danger: const Color(0xFFD12E54),
      unread: emphasis,
      selection: accent.withValues(alpha: 0.18),
      chipBackground: Colors.white.withValues(alpha: 0.72),
      inputFill: Colors.white,
      outboundBubble: const Color(0xFF172232),
      outboundText: Colors.white,
      outboundMeta: const Color(0xFFB9C4D2),
      inboundBubble: Colors.white,
      inboundText: const Color(0xFF151B24),
      inboundMeta: const Color(0xFF657182),
      qrInk: const Color(0xFF111111),
      shadow: const Color(0x1F111827),
    );
  }

  const ConestPalette._raw({
    required this.mode,
    required this.brightness,
    required this.usingDynamicColor,
    required this.appBackground,
    required this.backgroundGlowStart,
    required this.backgroundGlowEnd,
    required this.panel,
    required this.panelStrong,
    required this.surface,
    required this.surfaceElevated,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textMuted,
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.onSecondary,
    required this.success,
    required this.warning,
    required this.danger,
    required this.unread,
    required this.selection,
    required this.chipBackground,
    required this.inputFill,
    required this.outboundBubble,
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
    final rounded = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
    );
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: appBackground,
      colorScheme: scheme,
      fontFamily: 'monospace',
      useMaterial3: true,
      dividerTheme: DividerThemeData(color: border, thickness: 1),
      cardTheme: CardThemeData(
        elevation: 0,
        color: panel,
        surfaceTintColor: Colors.transparent,
        shadowColor: shadow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(color: border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          fontFamily: 'monospace',
        ),
      ),
      textTheme: ThemeData(brightness: brightness).textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
        fontFamily: 'monospace',
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputFill,
        labelStyle: TextStyle(color: textMuted),
        hintStyle: TextStyle(color: textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          disabledBackgroundColor: textMuted.withValues(alpha: 0.22),
          disabledForegroundColor: textMuted,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: BorderSide(color: borderStrong),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: chipBackground,
        selectedColor: selection,
        disabledColor: textMuted.withValues(alpha: 0.12),
        side: BorderSide(color: border),
        shape: rounded,
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
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
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          ),
        ),
      ),
    );
  }
}

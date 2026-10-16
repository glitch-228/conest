import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_locales.dart';
import '../messenger_controller.dart';
import '../models.dart';

/// After creating an identity: how much of Conest to show, then (unless
/// the simplest mode was chosen) a word on the ways Conest can reach people.
class UserModeScreen extends StatefulWidget {
  const UserModeScreen({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<UserModeScreen> createState() => _UserModeScreenState();
}

class _UserModeScreenState extends State<UserModeScreen> {
  UserMode _mode = UserMode.normal;
  bool _showRoutes = false;
  bool _saving = false;

  Future<void> _finish() async {
    setState(() => _saving = true);
    try {
      await widget.controller.setUserMode(_mode);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = l10nOf(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: _showRoutes
                  ? _routes(theme, l10n)
                  : _modes(theme, l10n),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _modes(ThemeData theme, AppLocalizations l10n) => [
    Text(l10n.modeChooseTitle, style: theme.textTheme.headlineSmall),
    const SizedBox(height: 8),
    Text(l10n.modeChangeLater, style: theme.textTheme.bodyMedium),
    const SizedBox(height: 20),
    for (final mode in UserMode.values)
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _ModeCard(
          mode: mode,
          selected: _mode == mode,
          onTap: () => setState(() => _mode = mode),
        ),
      ),
    const SizedBox(height: 12),
    FilledButton(
      key: const ValueKey('user-mode-continue'),
      onPressed: _saving
          ? null
          : () {
              if (_mode == UserMode.minimal) {
                _finish();
              } else {
                setState(() => _showRoutes = true);
              }
            },
      child: Text(
        _mode == UserMode.minimal ? l10n.actionStart : l10n.actionContinue,
      ),
    ),
  ];

  List<Widget> _routes(ThemeData theme, AppLocalizations l10n) => [
    Text(l10n.routesTitle, style: theme.textTheme.headlineSmall),
    const SizedBox(height: 12),
    Text(l10n.routesDirect),
    const SizedBox(height: 12),
    Text(l10n.routesOthers),
    if (_mode == UserMode.advanced) ...[
      const SizedBox(height: 12),
      Text(l10n.routesAdvanced),
    ],
    const SizedBox(height: 24),
    Row(
      children: [
        TextButton(
          onPressed: _saving ? null : () => setState(() => _showRoutes = false),
          child: Text(l10n.actionBack),
        ),
        const Spacer(),
        FilledButton(
          key: const ValueKey('user-mode-start'),
          onPressed: _saving ? null : _finish,
          child: Text(l10n.actionStart),
        ),
      ],
    ),
  ];
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final UserMode mode;
  final bool selected;
  final VoidCallback onTap;

  static String title(AppLocalizations l10n, UserMode mode) => switch (mode) {
    UserMode.minimal => l10n.modeSimple,
    UserMode.normal => l10n.modeStandard,
    UserMode.advanced => l10n.modeAdvanced,
  };

  static String description(AppLocalizations l10n, UserMode mode) =>
      switch (mode) {
        UserMode.minimal => l10n.modeSimpleDescription,
        UserMode.normal => l10n.modeStandardDescription,
        UserMode.advanced => l10n.modeAdvancedDescription,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = l10nOf(context);
    return Card(
      key: ValueKey('user-mode-${mode.name}'),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? theme.colorScheme.primary : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title(l10n, mode), style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(description(l10n, mode)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The mode picker in Settings.
class UserModeSelector extends StatelessWidget {
  const UserModeSelector({super.key, required this.controller});

  final MessengerController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    return SegmentedButton<UserMode>(
      key: const ValueKey('user-mode-selector'),
      segments: [
        for (final mode in UserMode.values)
          ButtonSegment(value: mode, label: Text(_ModeCard.title(l10n, mode))),
      ],
      selected: {controller.userMode},
      onSelectionChanged: (selection) =>
          controller.setUserMode(selection.single),
    );
  }
}

/// The language picker in Settings, with a note when the language was
/// translated with AI.
class LanguageSelector extends StatelessWidget {
  const LanguageSelector({
    super.key,
    required this.controller,
    required this.languages,
    required this.aiTranslated,
  });

  final MessengerController controller;

  /// Language codes and their own names.
  final Map<String, String> languages;
  final Set<String> aiTranslated;

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final shown = Localizations.localeOf(context).languageCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String?>(
          isExpanded: true,
          key: const ValueKey('language-selector'),
          initialValue: controller.localeCode,
          decoration: InputDecoration(labelText: l10n.settingsLanguage),
          items: [
            DropdownMenuItem(
              value: null,
              child: Text(l10n.settingsLanguageSystem),
            ),
            for (final MapEntry(key: code, value: name) in languages.entries)
              DropdownMenuItem(value: code, child: Text(name)),
          ],
          onChanged: controller.setLocaleCode,
        ),
        if (aiTranslated.contains(shown))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              l10n.settingsAiTranslated,
              key: const ValueKey('ai-translated-note'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

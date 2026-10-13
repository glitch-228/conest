import 'package:flutter/material.dart';

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
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: _showRoutes ? _routes(theme) : _modes(theme),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _modes(ThemeData theme) => [
    Text('How should Conest look?', style: theme.textTheme.headlineSmall),
    const SizedBox(height: 8),
    Text(
      'You can change this any time in Settings.',
      style: theme.textTheme.bodyMedium,
    ),
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
      child: Text(_mode == UserMode.minimal ? 'Start' : 'Continue'),
    ),
  ];

  List<Widget> _routes(ThemeData theme) => [
    Text('How Conest reaches people', style: theme.textTheme.headlineSmall),
    const SizedBox(height: 12),
    const Text(
      'Conest sends messages straight to your contacts over your network '
      'and the internet, with no server in between. That is on now.',
    ),
    const SizedBox(height: 12),
    const Text(
      'When those are blocked or missing, Conest can also use relays, Tor, '
      'Nostr, email, Matrix, a Bluetooth mesh of nearby phones or LoRa '
      'radios. Each is off until you turn it on in Settings → '
      'Connectivity.',
    ),
    if (_mode == UserMode.advanced) ...[
      const SizedBox(height: 12),
      const Text(
        'In advanced mode each message shows the routes it took, and a '
        "contact's profile can test every route.",
      ),
    ],
    const SizedBox(height: 24),
    Row(
      children: [
        TextButton(
          onPressed: _saving ? null : () => setState(() => _showRoutes = false),
          child: const Text('Back'),
        ),
        const Spacer(),
        FilledButton(
          key: const ValueKey('user-mode-start'),
          onPressed: _saving ? null : _finish,
          child: const Text('Start'),
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

  static String title(UserMode mode) => switch (mode) {
    UserMode.minimal => 'Simple',
    UserMode.normal => 'Standard',
    UserMode.advanced => 'Advanced',
  };

  static String description(UserMode mode) => switch (mode) {
    UserMode.minimal =>
      'One list of chats, large text and only the settings you need. '
          'Messages show sent, delivered and read.',
    UserMode.normal =>
      'Like the messengers you know: chats, groups, calls and files, with '
          'delivered and read ticks.',
    UserMode.advanced =>
      'Everything, including the routes each message took, every '
          'transport and diagnostics.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                    Text(title(mode), style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(description(mode)),
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
    return SegmentedButton<UserMode>(
      key: const ValueKey('user-mode-selector'),
      segments: [
        for (final mode in UserMode.values)
          ButtonSegment(value: mode, label: Text(_ModeCard.title(mode))),
      ],
      selected: {controller.userMode},
      onSelectionChanged: (selection) =>
          controller.setUserMode(selection.single),
    );
  }
}

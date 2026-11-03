import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../build_info.dart';
import '../update_service.dart';

/// Settings → Updates: which releases this install takes. Stable, nightly or
/// canary, each with a line of explanation. Changing it checks again at once.
/// Reads cached getters of the service only.
class UpdateChannelPicker extends StatelessWidget {
  const UpdateChannelPicker({super.key, required this.updateService});

  final UpdateService updateService;

  static const _choices = [
    UpdateChannel.stable,
    UpdateChannel.nightly,
    UpdateChannel.canary,
  ];

  String _name(BuildContext context, UpdateChannel channel) =>
      switch (channel) {
        UpdateChannel.nightly => l10nOf(context).updateChannelNightly,
        UpdateChannel.canary => l10nOf(context).updateChannelCanary,
        _ => l10nOf(context).updateChannelStable,
      };

  String _help(BuildContext context, UpdateChannel channel) =>
      switch (channel) {
        UpdateChannel.nightly => l10nOf(context).updateChannelNightlyHelp,
        UpdateChannel.canary => l10nOf(context).updateChannelCanaryHelp,
        _ => l10nOf(context).updateChannelStableHelp,
      };

  Future<void> _choose(BuildContext context, UpdateChannel channel) async {
    if (channel == updateService.updateChannel) return;
    if (channel == UpdateChannel.canary) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10nOf(dialog).canaryConfirmTitle),
          content: Text(l10nOf(dialog).canaryConfirmBody),
          actions: [
            TextButton(
              key: const ValueKey('update-channel-confirm-cancel'),
              onPressed: () => Navigator.of(dialog).pop(false),
              child: Text(l10nOf(dialog).actionCancel),
            ),
            FilledButton(
              key: const ValueKey('update-channel-confirm-switch'),
              onPressed: () => Navigator.of(dialog).pop(true),
              child: Text(l10nOf(dialog).uiSwitch3E44C9),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await updateService.setUpdateChannel(channel);
  }

  @override
  Widget build(BuildContext context) {
    final busy = updateService.isChecking || updateService.isDownloading;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            l10nOf(context).updateChannelTitle,
            style: theme.textTheme.titleSmall,
          ),
        ),
        RadioGroup<UpdateChannel>(
          groupValue: updateService.updateChannel,
          onChanged: (value) {
            if (busy || value == null) return;
            _choose(context, value);
          },
          child: Column(
            children: [
              for (final channel in _choices)
                RadioListTile<UpdateChannel>(
                  key: ValueKey('update-channel-${channel.label}'),
                  contentPadding: EdgeInsets.zero,
                  enabled: !busy,
                  value: channel,
                  title: Text(_name(context, channel)),
                  subtitle: Text(_help(context, channel)),
                ),
            ],
          ),
        ),
        if (updateService.waitingForNewerThanInstalled)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l10nOf(context).updateChannelWaiting,
              key: const ValueKey('update-channel-waiting'),
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// "Canary: new features, may break": shown on canary builds only.
class CanaryBanner extends StatelessWidget {
  const CanaryBanner({super.key, required this.buildInfo});

  final ConestBuildInfo buildInfo;

  @override
  Widget build(BuildContext context) {
    if (buildInfo.channel != UpdateChannel.canary) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('canary-banner'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.science_outlined, color: scheme.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10nOf(context).canaryBanner,
              style: TextStyle(
                color: scheme.onTertiaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

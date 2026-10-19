import '../app_locales.dart';
import 'package:flutter/material.dart';

import '../messenger_controller.dart';
import '../tor_carrier.dart';

/// Tor in Settings: on or off, with bridge lines for where Tor is blocked.
class TorCarrierPanel extends StatefulWidget {
  const TorCarrierPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<TorCarrierPanel> createState() => _TorCarrierPanelState();
}

class _TorCarrierPanelState extends State<TorCarrierPanel> {
  final _bridges = TextEditingController();
  bool _busy = false;
  String? _error;
  bool? _transports;

  @override
  void initState() {
    super.initState();
    _bridges.text =
        widget.controller.torCarrierConfig?.bridges.join('\n') ?? '';
    widget.controller.addListener(_changed);
    widget.controller.torPluggableTransportsAvailable().then((available) {
      if (mounted) setState(() => _transports = available);
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _bridges.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<String> get _lines => _bridges.text.split('\n');

  Future<void> _enable() => widget.controller.enableTorCarrier(bridges: _lines);

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (!controller.torAvailable) return const SizedBox.shrink();
    final config = controller.torCarrierConfig;
    final channel = controller.torChannel;
    final theme = Theme.of(context);
    final status = switch (channel?.state) {
      TorCarrierState.connected => 'Connected',
      TorCarrierState.connecting =>
        'Connecting (${(channel!.progress * 100).round()}%)',
      TorCarrierState.failed => 'Cannot reach Tor; retrying',
      _ => 'Off',
    };
    // Plain Tor stuck or refused, with no bridges: the network blocks it.
    final blocked =
        config != null &&
        config.bridges.isEmpty &&
        channel != null &&
        channel.state != TorCarrierState.connected &&
        (channel.state == TorCarrierState.failed ||
            '${channel.lastError ?? ''} ${channel.progressDetail ?? ''}'
                .toLowerCase()
                .contains('filtered'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('tor-carrier-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10nOf(context).uiTorED7088),
          subtitle: Text(l10nOf(context).uiReachContactsThroughTorOnion8B8A98),
          value: config != null,
          onChanged: _busy
              ? null
              : (on) => _run(on ? _enable : controller.disableTorCarrier),
        ),
        TextField(
          key: const ValueKey('tor-bridges'),
          controller: _bridges,
          minLines: 2,
          maxLines: 6,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: l10nOf(context).uiBridgesOptionalOnePerLine110291,
            hintText: _transports == false
                ? l10nOf(context).uiEEFEBFE80B7A
                : l10nOf(context).uiObfsEEFEAD0EDF,
            hintMaxLines: 3,
            helperText: switch (_transports) {
              true => l10nOf(context).uiLinesFromBridgesTorprojectOrgF08389,
              false => l10nOf(context).uiPlainBridgesOnlyAddressAnd7F0B60,
              null => null,
            },
            helperMaxLines: 2,
          ),
        ),
        if (blocked)
          Padding(
            key: const ValueKey('tor-blocked-hint'),
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              l10nOf(context).torBlockedHint,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ExpansionTile(
          key: const ValueKey('tor-get-bridges'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          initiallyExpanded: blocked,
          title: Text(l10nOf(context).torGetBridgesTitle),
          children: [
            Text(l10nOf(context).torGetBridgesIntro),
            const SizedBox(height: 4),
            for (final way in [
              l10nOf(context).torGetBridgesWeb,
              l10nOf(context).torGetBridgesTelegram,
              l10nOf(context).torGetBridgesEmail,
            ])
              SelectableText('• $way'),
            const SizedBox(height: 4),
            Text(l10nOf(context).torGetBridgesFriend),
          ],
        ),
        if (config != null)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              key: const ValueKey('tor-bridges-save'),
              onPressed: _busy ? null : () => _run(_enable),
              child: Text(l10nOf(context).uiUseTheseBridgesC1FA11),
            ),
          ),
        if (config != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.circle,
              size: 12,
              color: switch (channel?.state) {
                TorCarrierState.connected => Colors.green,
                TorCarrierState.connecting => Colors.amber,
                _ => theme.colorScheme.error,
              },
            ),
            title: Text(status),
            subtitle: channel?.lastError == null
                ? null
                : Text(channel!.lastError!, maxLines: 2),
          ),
        if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }
}

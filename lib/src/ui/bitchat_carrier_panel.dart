import 'package:flutter/material.dart';

import '../bitchat_carrier.dart';
import '../messenger_controller.dart';

/// The Bluetooth mesh in Settings.
class BitchatCarrierPanel extends StatefulWidget {
  const BitchatCarrierPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<BitchatCarrierPanel> createState() => _BitchatCarrierPanelState();
}

class _BitchatCarrierPanelState extends State<BitchatCarrierPanel> {
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _set(bool on) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      on
          ? await widget.controller.enableBitchatCarrier()
          : await widget.controller.disableBitchatCarrier();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (!controller.bitchatAvailable) return const SizedBox.shrink();
    final config = controller.bitchatCarrierConfig;
    final channel = controller.bitchatChannel;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('bitchat-carrier-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Bluetooth mesh'),
          subtitle: const Text(
            'Reach contacts nearby without any network: messages hop from '
            'phone to phone over Bluetooth, through Conest and bitchat '
            'users alike, and this phone relays for others. This phone does '
            'not show up in bitchat, and what it sends looks like any '
            'bitchat private message, with ids that change every hour.',
          ),
          value: config != null,
          onChanged: _busy ? null : _set,
        ),
        if (config != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.circle,
              size: 12,
              color: switch (channel?.state) {
                BitchatCarrierState.running => Colors.green,
                BitchatCarrierState.starting => Colors.amber,
                _ => theme.colorScheme.error,
              },
            ),
            title: Text(switch (channel?.state) {
              BitchatCarrierState.running => 'Bluetooth mesh on',
              BitchatCarrierState.starting => 'Starting Bluetooth',
              _ => 'Bluetooth unavailable',
            }),
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

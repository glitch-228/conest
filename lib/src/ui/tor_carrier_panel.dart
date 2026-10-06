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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('tor-carrier-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Tor'),
          subtitle: const Text(
            'Reach contacts through Tor onion services: neither side nor '
            'the network learns where the other is. Slower than other '
            'routes; add bridges where Tor is blocked.',
          ),
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
            labelText: 'Bridges (optional, one per line)',
            hintText: _transports == false
                ? '192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413'
                : 'obfs4 192.0.2.1:443 '
                      '4352E58420E68F5E40BF7C74FADDCCD9D1349413 '
                      'cert=… iat-mode=0',
            hintMaxLines: 3,
            helperText: switch (_transports) {
              true =>
                'Lines from bridges.torproject.org, starting with the '
                    'type: obfs4, webtunnel, snowflake or meek_lite (or '
                    'plain bridges: address and fingerprint).',
              false =>
                'Plain bridges only (address and fingerprint) in '
                    'this build.',
              null => null,
            },
            helperMaxLines: 2,
          ),
        ),
        if (config != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('tor-bridges-save'),
              onPressed: _busy ? null : () => _run(_enable),
              child: const Text('Use these bridges'),
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

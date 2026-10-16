import '../app_locales.dart';
import 'package:flutter/material.dart';

import '../messenger_controller.dart';
import '../network_errors.dart';
import '../nostr/relay.dart';
import '../nostr_carrier.dart';

/// The Nostr carrier in Settings: turn it on, choose the relays this device
/// reads from, and see whether each one is connected.
class NostrCarrierPanel extends StatefulWidget {
  const NostrCarrierPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<NostrCarrierPanel> createState() => _NostrCarrierPanelState();
}

class _NostrCarrierPanelState extends State<NostrCarrierPanel> {
  final _relays = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _relays.text =
        (widget.controller.nostrCarrierConfig?.relays ?? defaultNostrRelays)
            .join('\n');
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _relays.dispose();
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
      if (mounted) {
        setState(() => _error = describeActionError(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<String> get _relayLines => _relays.text
      .split(RegExp(r'[\s,]+'))
      .where((line) => line.isNotEmpty)
      .toList();

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final config = controller.nostrCarrierConfig;
    final channel = controller.nostrChannel;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('nostr-carrier-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10nOf(context).uiNostrRelaysBD8BAD),
          subtitle: Text(
            l10nOf(context).uiCarryMessagesThroughPublicNostr729B94,
          ),
          value: config != null,
          onChanged: _busy
              ? null
              : (on) => _run(
                  on
                      ? () => controller.enableNostrCarrier(relays: _relayLines)
                      : controller.disableNostrCarrier,
                ),
        ),
        if (config != null) ...[
          for (final MapEntry(key: url, value: (state, error, reading))
              in (channel?.relayStates ?? const {}).entries)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.circle,
                size: 12,
                color: switch (state) {
                  // Connected but not (yet) served: signing in, or refused.
                  NostrRelayState.connected when !reading => Colors.amber,
                  NostrRelayState.connected => Colors.green,
                  NostrRelayState.connecting => Colors.amber,
                  NostrRelayState.disconnected => theme.colorScheme.error,
                },
              ),
              title: Text(url.toString()),
              subtitle: error == null ? null : Text(error, maxLines: 2),
            ),
        ],
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('nostr-relays-field'),
          controller: _relays,
          enabled: !_busy,
          minLines: 2,
          maxLines: maxNostrAddressRelays,
          decoration: InputDecoration(
            labelText: l10nOf(context).uiRelaysYouReadFromOne020C0A,
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            if (config != null)
              FilledButton.tonal(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () =>
                            controller.enableNostrCarrier(relays: _relayLines),
                      ),
                child: Text(l10nOf(context).uiSaveRelays91CBA8),
              ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(
                      () => _relays.text = defaultNostrRelays.join('\n'),
                    ),
              child: Text(l10nOf(context).uiDefaultRelays5C909F),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}

import '../app_locales.dart';
import 'package:flutter/material.dart';

import '../bitchat_carrier.dart';
import '../messenger_controller.dart';
import 'bitchat_chats_screen.dart';
import 'carrier_switch.dart';
import '../transport_models.dart';

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

  Future<void> _editNickname() async {
    final field = TextEditingController(
      text: widget.controller.bitchatNickname,
    );
    final nickname = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiNameBitchatUsersSee1CE7E3),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('bitchat-nickname-field'),
              controller: field,
              autofocus: true,
              maxLength: BitchatCarrierConfig.maxNicknameLength,
            ),
            Text(l10nOf(context).uiANameYouChooseStays17E677),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(field.text),
            child: Text(l10nOf(context).uiSaveEFC007),
          ),
        ],
      ),
    );
    field.dispose();
    if (nickname != null) {
      await _run(() => widget.controller.setBitchatNickname(nickname));
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
        CarrierSwitch(
          switchKey: const ValueKey('bitchat-carrier-switch'),
          controller: controller,
          kind: TransportKind.bitchat,
          title: l10nOf(context).uiBluetoothMeshC8B7F1,
          subtitle: l10nOf(context).uiReachContactsNearbyWithoutAny9E9649,
          configured: config != null,
          busy: _busy,
          run: _run,
          onSetUp: controller.enableBitchatCarrier,
          onRemove: controller.disableBitchatCarrier,
        ),
        if (config != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.circle,
              size: 12,
              color: switch (channel?.state) {
                BitchatCarrierState.running when channel?.lastError == null =>
                  Colors.green,
                BitchatCarrierState.starting => Colors.amber,
                _ => theme.colorScheme.error,
              },
            ),
            title: Text(switch (channel?.state) {
              BitchatCarrierState.running when channel?.lastError == null =>
                l10nOf(context).uiBluetoothMeshOn5A96FE,
              BitchatCarrierState.running => l10nOf(
                context,
              ).bluetoothMeshNeedsAttention,
              BitchatCarrierState.starting => l10nOf(
                context,
              ).uiStartingBluetoothE6928A,
              _ => l10nOf(context).uiBluetoothUnavailableF4B751,
            }),
            subtitle:
                channel?.lastError == null && channel?.adapterStatus == null
                ? null
                : Text(
                    [
                      ?channel?.adapterStatus,
                      ?channel?.lastError,
                    ].join('\n'),
                  ),
          ),
        if (config != null)
          SwitchListTile.adaptive(
            key: const ValueKey('bitchat-reachable-switch'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10nOf(context).uiReachableByBitchatUsers568021),
            subtitle: Text(
              controller.bitchatReachable
                  ? l10nOf(context).uiBitchatUsersNearbySeeYou1B54FC(
                      (controller.bitchatNickname).toString(),
                    )
                  : l10nOf(context).uiOffBitchatUsersDoNot054F9A,
            ),
            value: controller.bitchatReachable,
            onChanged: _busy
                ? null
                : (value) => _run(() => controller.setBitchatReachable(value)),
          ),
        if (config != null && controller.bitchatReachable)
          SwitchListTile.adaptive(
            key: const ValueKey('bitchat-gateway-switch'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10nOf(context).uiShareInternetWithBitchatUsers572F90),
            subtitle: Text(
              controller.bitchatGateway
                  ? l10nOf(context).uiPhonesNearbyWithoutInternetCan27CC7F(
                      (controller.bitchatGatewayCells.isEmpty
                              ? ''
                              : ' (now ${controller.bitchatGatewayCells.length})')
                          .toString(),
                    )
                  : l10nOf(context).uiOffBitchatUsersNearbyWithout030CFB,
            ),
            value: controller.bitchatGateway,
            onChanged: _busy
                ? null
                : (value) => _run(() => controller.setBitchatGateway(value)),
          ),
        if (config != null && controller.bitchatReachable)
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.edit_outlined),
                label: Text(l10nOf(context).uiChangeNameE46692),
                onPressed: _busy ? null : _editNickname,
              ),
              TextButton.icon(
                icon: const Icon(Icons.autorenew),
                label: Text(l10nOf(context).uiNewIdentityA119CF),
                onPressed: _busy
                    ? null
                    : () => _run(controller.newBitchatIdentity),
              ),
            ],
          ),
        if (config != null)
          ListTile(
            key: const ValueKey('bitchat-chats'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.forum_outlined),
            title: Text(l10nOf(context).uiBitchatChatsC74EC3),
            subtitle: Text(
              l10nOf(context).uiValueNearbyTheMeshChat31C0CA(
                (controller.bitchatNearbyPeers.length),
              ),
            ),
            trailing: controller.bitchatChats.totalUnread == 0
                ? const Icon(Icons.chevron_right)
                : Badge(
                    label: Text("${(controller.bitchatChats.totalUnread)}"),
                  ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => BitchatChatsScreen(controller: controller),
              ),
            ),
          ),
        if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }
}

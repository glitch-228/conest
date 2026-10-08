import 'package:flutter/material.dart';

import '../bitchat_carrier.dart';
import '../messenger_controller.dart';
import 'bitchat_chats_screen.dart';

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

  Future<void> _set(bool on) => _run(
    () => on
        ? widget.controller.enableBitchatCarrier()
        : widget.controller.disableBitchatCarrier(),
  );

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
        title: const Text('Name bitchat users see'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('bitchat-nickname-field'),
              controller: field,
              autofocus: true,
              maxLength: BitchatCarrierConfig.maxNicknameLength,
            ),
            const Text(
              'A name you choose stays when your identity changes, so '
              'people nearby can tell it is still you. Leave it empty for '
              'a new "anon" name with each identity.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(field.text),
            child: const Text('Save'),
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
                BitchatCarrierState.running when channel?.lastError == null =>
                  Colors.green,
                BitchatCarrierState.starting => Colors.amber,
                _ => theme.colorScheme.error,
              },
            ),
            title: Text(switch (channel?.state) {
              BitchatCarrierState.running when channel?.lastError == null =>
                'Bluetooth mesh on',
              BitchatCarrierState.starting => 'Starting Bluetooth',
              _ => 'Bluetooth unavailable',
            }),
            subtitle: channel?.lastError == null
                ? null
                : Text(channel!.lastError!, maxLines: 2),
          ),
        if (config != null)
          SwitchListTile.adaptive(
            key: const ValueKey('bitchat-reachable-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Reachable by bitchat users'),
            subtitle: Text(
              controller.bitchatReachable
                  ? 'bitchat users nearby see you as '
                        '"${controller.bitchatNickname}" while you are in '
                        'range, and can write to you. The identity they see '
                        'is new every week and has nothing to do with your '
                        'Conest identity.'
                  : 'Off: bitchat users do not see this phone. You can '
                        'still read the mesh chat.',
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
            title: const Text('Share internet with bitchat users'),
            subtitle: Text(
              controller.bitchatGateway
                  ? 'Phones nearby without internet can use bitchat\'s '
                        'location channels through this phone. Only those '
                        'public, signed messages pass. This phone connects '
                        'to the relays of the areas they use'
                        '${controller.bitchatGatewayCells.isEmpty ? '' : ' (now ${controller.bitchatGatewayCells.length})'}'
                        ': those relays see your internet address and the '
                        'area, so they can tell roughly where you are.'
                  : 'Off: bitchat users nearby without internet cannot '
                        'reach location channels through you.',
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
                label: const Text('Change name'),
                onPressed: _busy ? null : _editNickname,
              ),
              TextButton.icon(
                icon: const Icon(Icons.autorenew),
                label: const Text('New identity'),
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
            title: const Text('bitchat chats'),
            subtitle: Text(
              '${controller.bitchatNearbyPeers.length} nearby · the mesh '
              'chat and private chats',
            ),
            trailing: controller.bitchatChats.totalUnread == 0
                ? const Icon(Icons.chevron_right)
                : Badge(label: Text('${controller.bitchatChats.totalUnread}')),
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

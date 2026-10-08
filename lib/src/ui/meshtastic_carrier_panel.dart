import 'dart:io';

import 'package:flutter/material.dart';

import '../meshtastic_carrier.dart';
import '../messenger_controller.dart';
import '../network_errors.dart';
import '../radio/android_radio_link.dart';
import 'radio_chats_screen.dart';

/// The Meshtastic carrier in Settings: the radio to use and its state.
class MeshtasticCarrierPanel extends StatefulWidget {
  const MeshtasticCarrierPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<MeshtasticCarrierPanel> createState() => _MeshtasticCarrierPanelState();
}

class _MeshtasticCarrierPanelState extends State<MeshtasticCarrierPanel> {
  late MeshtasticLink _link =
      widget.controller.meshtasticCarrierConfig?.link ?? MeshtasticLink.serial;
  late final _host = TextEditingController(
    text: widget.controller.meshtasticCarrierConfig?.host ?? '',
  );
  late final _port = TextEditingController(
    text:
        '${widget.controller.meshtasticCarrierConfig?.port ?? defaultMeshtasticPort}',
  );
  List<(String, String)> _devices = const [];
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
    _host.dispose();
    _port.dispose();
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

  Future<void> _findDevices() async {
    final found = Platform.isAndroid
        ? [
            for (final device in await AndroidRadioLinks.listUsb())
              if (device.supported) (device.id, device.name),
          ]
        : [
            for (final entry in Directory('/dev').listSync())
              if (RegExp(
                r'^/dev/(ttyACM\d+|ttyUSB\d+|cu\.usb\S+)$',
              ).hasMatch(entry.path))
                (entry.path, entry.path),
          ];
    if (mounted) setState(() => _devices = found);
  }

  Future<void> _save() => widget.controller.enableMeshtasticCarrier(
    link: _link,
    host: _host.text,
    port: _link == MeshtasticLink.tcp
        ? int.tryParse(_port.text.trim()) ?? -1
        : defaultMeshtasticPort,
  );

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final config = controller.meshtasticCarrierConfig;
    final channel = controller.meshtasticChannel;
    final theme = Theme.of(context);
    final serialAvailable =
        Platform.isLinux || Platform.isMacOS || Platform.isAndroid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('meshtastic-carrier-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Meshtastic'),
          subtitle: const Text(
            'Carry short messages over a Meshtastic LoRa mesh, without the '
            'internet, through your Meshtastic radio. Contacts need Conest '
            'with a radio in the same mesh.',
          ),
          value: config != null,
          onChanged: _busy
              ? null
              : (on) => _run(on ? _save : controller.disableMeshtasticCarrier),
        ),
        if (config != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.circle,
              size: 12,
              color: switch (channel?.state) {
                MeshtasticCarrierState.connected => Colors.green,
                MeshtasticCarrierState.connecting => Colors.amber,
                _ => theme.colorScheme.error,
              },
            ),
            title: Text(
              channel?.nodeNum == null
                  ? config.label
                  : '${config.label} · !${meshtasticAddress(channel!.nodeNum!)}',
            ),
            subtitle: channel?.lastError == null
                ? null
                : Text(channel!.lastError!, maxLines: 2),
          ),
        SegmentedButton<MeshtasticLink>(
          segments: [
            if (serialAvailable)
              const ButtonSegment(
                value: MeshtasticLink.serial,
                label: Text('USB'),
              ),
            const ButtonSegment(
              value: MeshtasticLink.tcp,
              label: Text('Network'),
            ),
          ],
          selected: {_link},
          onSelectionChanged: _busy
              ? null
              : (selected) => setState(() {
                  _link = selected.first;
                  _devices = const [];
                }),
        ),
        const SizedBox(height: 8),
        if (_link == MeshtasticLink.serial)
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run(_findDevices),
                icon: const Icon(Icons.search, size: 18),
                label: const Text('Find devices'),
              ),
              for (final (id, name) in _devices)
                ActionChip(
                  label: Text(name),
                  onPressed: () => setState(() => _host.text = id),
                ),
            ],
          ),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _host,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: _link == MeshtasticLink.serial
                      ? 'USB device'
                      : 'Radio address',
                  isDense: true,
                ),
              ),
            ),
            if (_link == MeshtasticLink.tcp) ...[
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _port,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'TCP port',
                    isDense: true,
                  ),
                ),
              ),
            ],
          ],
        ),
        if (config != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FilledButton.tonal(
              onPressed: _busy ? null : () => _run(_save),
              child: const Text('Save'),
            ),
          ),
        if (config != null)
          SwitchListTile.adaptive(
            key: const ValueKey('meshtastic-app-messages'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Messages with Meshtastic app users'),
            subtitle: const Text(
              'Read and write the Meshtastic apps\' own messages through this '
              'radio: direct ones, and its channels as group chats. They are '
              'protected only as Meshtastic protects them.',
            ),
            value: widget.controller.meshtasticAppMessages,
            onChanged: _busy
                ? null
                : (value) => _run(
                    () => widget.controller.setMeshtasticAppMessages(value),
                  ),
          ),
        if (config != null && widget.controller.meshtasticAppMessages)
          ListTile(
            key: const ValueKey('meshtastic-chats'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.forum_outlined),
            title: const Text('Meshtastic chats'),
            trailing: widget.controller.meshtasticChats.totalUnread == 0
                ? const Icon(Icons.chevron_right)
                : Badge(
                    label: Text(
                      '${widget.controller.meshtasticChats.totalUnread}',
                    ),
                  ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RadioChatsScreen(
                  controller: widget.controller,
                  access: meshtasticChatsAccess(widget.controller),
                ),
              ),
            ),
          ),
        if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }
}

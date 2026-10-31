import '../app_locales.dart';
import 'dart:io';

import 'package:flutter/material.dart';

import '../meshcore_carrier.dart';
import '../messenger_controller.dart';
import '../transport_models.dart';
import 'airtime_budget_line.dart';
import '../network_errors.dart';
import '../radio/android_radio_link.dart';
import 'radio_chats_screen.dart';

/// The MeshCore carrier in Settings: the companion radio and its state.
class MeshCoreCarrierPanel extends StatefulWidget {
  const MeshCoreCarrierPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<MeshCoreCarrierPanel> createState() => _MeshCoreCarrierPanelState();
}

class _MeshCoreCarrierPanelState extends State<MeshCoreCarrierPanel> {
  late MeshCoreLink _link =
      widget.controller.meshCoreCarrierConfig?.link ?? MeshCoreLink.serial;
  late final _host = TextEditingController(
    text: widget.controller.meshCoreCarrierConfig?.host ?? '',
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
    final found = switch (_link) {
      MeshCoreLink.bluetooth => [
        for (final device in await AndroidRadioLinks.scanBle())
          (device.address, device.name.isEmpty ? device.address : device.name),
      ],
      MeshCoreLink.serial when Platform.isAndroid => [
        for (final device in await AndroidRadioLinks.listUsb())
          if (device.supported) (device.id, device.name),
      ],
      MeshCoreLink.serial => [
        for (final entry in Directory('/dev').listSync())
          if (RegExp(
            r'^/dev/(ttyACM\d+|ttyUSB\d+|cu\.usb\S+)$',
          ).hasMatch(entry.path))
            (entry.path, entry.path),
      ],
    };
    if (mounted) setState(() => _devices = found);
  }

  Future<void> _save() =>
      widget.controller.enableMeshCoreCarrier(link: _link, host: _host.text);

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final config = controller.meshCoreCarrierConfig;
    final channel = controller.meshCoreChannel;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('meshcore-carrier-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10nOf(context).uiMeshCoreBA58A2),
          subtitle: Text(l10nOf(context).uiCarryShortMessagesOverAFA94B6),
          value: config != null,
          onChanged: _busy
              ? null
              : (on) => _run(on ? _save : controller.disableMeshCoreCarrier),
        ),
        if (config != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.circle,
              size: 12,
              color: switch (channel?.state) {
                MeshCoreCarrierState.connected => Colors.green,
                MeshCoreCarrierState.connecting => Colors.amber,
                _ => theme.colorScheme.error,
              },
            ),
            title: Text(config.host),
            subtitle: channel?.lastError == null
                ? null
                : Text(channel!.lastError!, maxLines: 2),
          ),
        if (config != null)
          AirtimeBudgetLine(
            controller: controller,
            kind: TransportKind.meshCore,
          ),
        SegmentedButton<MeshCoreLink>(
          segments: [
            ButtonSegment(
              value: MeshCoreLink.serial,
              label: Text(l10nOf(context).uiUSB09716C),
            ),
            if (Platform.isAndroid)
              ButtonSegment(
                value: MeshCoreLink.bluetooth,
                label: Text(l10nOf(context).uiBluetoothC3B414),
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
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _run(_findDevices),
              icon: const Icon(Icons.search, size: 18),
              label: Text(
                _link == MeshCoreLink.bluetooth
                    ? l10nOf(context).uiScanForRadios2B185E
                    : l10nOf(context).uiFindDevices98771A,
              ),
            ),
            for (final (id, name) in _devices)
              ActionChip(
                label: Text(name),
                onPressed: () => setState(() => _host.text = id),
              ),
          ],
        ),
        TextField(
          controller: _host,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: _link == MeshCoreLink.bluetooth
                ? l10nOf(context).uiBluetoothAddress0E2BED
                : l10nOf(context).uiUSBDeviceB47FF0,
            isDense: true,
          ),
        ),
        if (config != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FilledButton.tonal(
              onPressed: _busy ? null : () => _run(_save),
              child: Text(l10nOf(context).uiSaveEFC007),
            ),
          ),
        if (config != null)
          SwitchListTile.adaptive(
            key: const ValueKey('meshcore-app-messages'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10nOf(context).uiMessagesWithMeshCoreAppUsersDE77BA),
            subtitle: Text(l10nOf(context).uiReadAndWriteTheMeshCore98E60E),
            value: controller.meshCoreAppMessages,
            onChanged: _busy
                ? null
                : (value) =>
                      _run(() => controller.setMeshCoreAppMessages(value)),
          ),
        if (config != null && controller.meshCoreAppMessages)
          ListTile(
            key: const ValueKey('meshcore-chats'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.forum_outlined),
            title: Text(l10nOf(context).uiMeshCoreChats82C29C),
            trailing: controller.meshCoreChats.totalUnread == 0
                ? const Icon(Icons.chevron_right)
                : Badge(
                    label: Text("${(controller.meshCoreChats.totalUnread)}"),
                  ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RadioChatsScreen(
                  controller: controller,
                  access: meshCoreChatsAccess(controller),
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

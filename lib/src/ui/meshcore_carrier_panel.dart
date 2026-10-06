import 'dart:io';

import 'package:flutter/material.dart';

import '../meshcore_carrier.dart';
import '../messenger_controller.dart';
import '../network_errors.dart';
import '../radio/android_radio_link.dart';

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
          title: const Text('MeshCore'),
          subtitle: const Text(
            'Carry short messages over a MeshCore LoRa mesh through your '
            'companion radio, without the internet. Conest adds your '
            'contacts to the radio so it accepts their messages.',
          ),
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
        SegmentedButton<MeshCoreLink>(
          segments: [
            const ButtonSegment(value: MeshCoreLink.serial, label: Text('USB')),
            if (Platform.isAndroid)
              const ButtonSegment(
                value: MeshCoreLink.bluetooth,
                label: Text('Bluetooth'),
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
                    ? 'Scan for radios'
                    : 'Find devices',
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
                ? 'Bluetooth address'
                : 'USB device',
            isDense: true,
          ),
        ),
        if (config != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FilledButton.tonal(
              onPressed: _busy ? null : () => _run(_save),
              child: const Text('Save'),
            ),
          ),
        if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }
}

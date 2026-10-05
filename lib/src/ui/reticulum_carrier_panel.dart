import 'dart:io';

import 'package:flutter/material.dart';

import '../messenger_controller.dart';
import '../reticulum/rnode_interface.dart';
import '../reticulum_carrier.dart';

/// The Reticulum carrier in Settings: the node to connect through and its
/// state.
class ReticulumCarrierPanel extends StatefulWidget {
  const ReticulumCarrierPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<ReticulumCarrierPanel> createState() => _ReticulumCarrierPanelState();
}

class _ReticulumCarrierPanelState extends State<ReticulumCarrierPanel> {
  late final _host = TextEditingController(
    text: widget.controller.reticulumCarrierConfig?.host ?? '',
  );
  late final _port = TextEditingController(
    text:
        '${widget.controller.reticulumCarrierConfig?.port ?? defaultReticulumPort}',
  );
  late ReticulumLink _link =
      widget.controller.reticulumCarrierConfig?.link ?? ReticulumLink.rnsd;
  late final _radio = widget.controller.reticulumCarrierConfig?.radio;
  late final _frequency = TextEditingController(
    text: _mhz((_radio ?? RnodeConfig.eu869).frequency),
  );
  late final _bandwidth = TextEditingController(
    text: '${(_radio ?? RnodeConfig.eu869).bandwidth ~/ 1000}',
  );
  late final _spreading = TextEditingController(
    text: '${(_radio ?? RnodeConfig.eu869).spreadingFactor}',
  );
  late final _coding = TextEditingController(
    text: '${(_radio ?? RnodeConfig.eu869).codingRate}',
  );
  late final _power = TextEditingController(
    text: '${(_radio ?? RnodeConfig.eu869).txPower}',
  );
  bool _busy = false;
  String? _error;

  static String _mhz(int hz) => (hz / 1000000).toStringAsFixed(3);

  static bool get _serialAvailable => Platform.isLinux || Platform.isMacOS;

  /// Serial devices that may be an RNode.
  static List<String> _serialDevices() {
    try {
      return Directory('/dev')
          .listSync()
          .map((entry) => entry.path)
          .where(
            (path) => RegExp(
              r'^/dev/(ttyACM\d+|ttyUSB\d+|cu\.usb\S+)$',
            ).hasMatch(path),
          )
          .toList()
        ..sort();
    } catch (_) {
      return const [];
    }
  }

  void _usePreset(RnodeConfig preset) => setState(() {
    _frequency.text = _mhz(preset.frequency);
    _bandwidth.text = '${preset.bandwidth ~/ 1000}';
    _spreading.text = '${preset.spreadingFactor}';
    _coding.text = '${preset.codingRate}';
    _power.text = '${preset.txPower}';
  });

  RnodeConfig? _radioSettings() {
    final mhz = double.tryParse(_frequency.text.trim());
    final khz = double.tryParse(_bandwidth.text.trim());
    final sf = int.tryParse(_spreading.text.trim());
    final cr = int.tryParse(_coding.text.trim());
    final power = int.tryParse(_power.text.trim());
    if (mhz == null ||
        khz == null ||
        sf == null ||
        cr == null ||
        power == null) {
      return null;
    }
    final frequency = (mhz * 1000000).round();
    return RnodeConfig(
      frequency: frequency,
      bandwidth: (khz * 1000).round(),
      txPower: power,
      spreadingFactor: sf,
      codingRate: cr,
      // The EU 869.4–869.65 MHz sub-band allows 10% airtime, the rest of
      // EU868 1%.
      longTermAirtimeLimit: frequency >= 863000000 && frequency <= 870000000
          ? (frequency >= 869400000 && frequency <= 869650000 ? 10 : 1)
          : null,
    );
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    for (final field in [
      _host,
      _port,
      _frequency,
      _bandwidth,
      _spreading,
      _coding,
      _power,
    ]) {
      field.dispose();
    }
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
        setState(
          () => _error = error is ArgumentError ? '${error.message}' : '$error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() {
    final radio = _link == ReticulumLink.rnsd ? null : _radioSettings();
    if (_link != ReticulumLink.rnsd && radio == null) {
      throw ArgumentError('Enter all radio settings as numbers.');
    }
    return widget.controller.enableReticulumCarrier(
      host: _host.text,
      port: _link == ReticulumLink.rnodeSerial
          ? defaultReticulumPort
          : int.tryParse(_port.text.trim()) ?? -1,
      link: _link,
      radio: radio,
    );
  }

  Widget _number(TextEditingController text, String label) => Expanded(
    child: Padding(
      padding: const EdgeInsets.only(right: 8),
      child: TextField(
        controller: text,
        enabled: !_busy,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, isDense: true),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final config = controller.reticulumCarrierConfig;
    final channel = controller.reticulumChannel;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('reticulum-carrier-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Reticulum'),
          subtitle: const Text(
            'Carry messages over a Reticulum network, for example LoRa '
            'radios (RNode) without the internet, through a node running '
            'rnsd with a TCP server interface. Conest keeps a Reticulum '
            'identity of its own; your contacts learn it automatically.',
          ),
          value: config != null,
          onChanged: _busy
              ? null
              : (on) => _run(on ? _save : controller.disableReticulumCarrier),
        ),
        if (config != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.circle,
              size: 12,
              color: switch (channel?.state) {
                ReticulumCarrierState.connected => Colors.green,
                ReticulumCarrierState.connecting => Colors.amber,
                _ => theme.colorScheme.error,
              },
            ),
            title: Text(config.label),
            subtitle: channel?.lastError == null
                ? null
                : Text(channel!.lastError!, maxLines: 2),
          ),
        SegmentedButton<ReticulumLink>(
          segments: [
            const ButtonSegment(
              value: ReticulumLink.rnsd,
              label: Text('Node (rnsd)'),
            ),
            if (_serialAvailable)
              const ButtonSegment(
                value: ReticulumLink.rnodeSerial,
                label: Text('RNode on USB'),
              ),
            const ButtonSegment(
              value: ReticulumLink.rnodeTcp,
              label: Text('RNode on Wi-Fi'),
            ),
          ],
          selected: {_link},
          onSelectionChanged: _busy
              ? null
              : (selected) => setState(() => _link = selected.first),
        ),
        const SizedBox(height: 8),
        if (_link == ReticulumLink.rnodeSerial)
          Wrap(
            spacing: 8,
            children: [
              for (final device in _serialDevices())
                ActionChip(
                  label: Text(device),
                  onPressed: () => setState(() => _host.text = device),
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
                  labelText: switch (_link) {
                    ReticulumLink.rnsd => 'Node address (rnsd)',
                    ReticulumLink.rnodeSerial => 'Serial device',
                    ReticulumLink.rnodeTcp => 'RNode address',
                  },
                  isDense: true,
                ),
              ),
            ),
            if (_link != ReticulumLink.rnodeSerial) ...[
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
        if (_link != ReticulumLink.rnsd) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              _number(_frequency, 'MHz'),
              _number(_bandwidth, 'kHz'),
              _number(_spreading, 'SF'),
              _number(_coding, 'CR'),
              _number(_power, 'dBm'),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: _busy ? null : () => _usePreset(RnodeConfig.eu869),
                child: const Text('EU 869.525'),
              ),
              TextButton(
                onPressed: _busy ? null : () => _usePreset(RnodeConfig.us915),
                child: const Text('US 914.875'),
              ),
            ],
          ),
          Text(
            'Use the same frequency, bandwidth and spreading factor as the '
            'Reticulum network the radio joins.',
            style: theme.textTheme.bodySmall,
          ),
        ],
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

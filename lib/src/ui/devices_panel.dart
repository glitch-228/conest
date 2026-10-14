import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../messenger_controller.dart';

/// Settings → Devices: this account's devices, linking a new one, and
/// revoking a lost one.
class DevicesPanel extends StatelessWidget {
  const DevicesPanel({super.key, required this.controller, this.onScan});

  final MessengerController controller;

  /// Opens the camera to scan a code; null where there is no camera.
  final Future<String?> Function()? onScan;

  String _date(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  Future<void> _revoke(
    BuildContext context,
    String deviceId,
    String name,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $name?'),
        content: const Text(
          'Your contacts will stop accepting anything from that device. '
          'It cannot be added back; link it again as a new device instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.revokeAccountDevice(deviceId);
    } catch (error) {
      controller.setStatus('$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = controller.identity;
    final devices = controller.accountDevices?.devices ?? const [];
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      key: const ValueKey('devices-panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          devices.length > 1
              ? 'This account is on ${devices.length} devices.'
              : 'Use Conest on more than one device: link a phone, tablet or '
                    'computer to this account. Your contacts see one person.',
          style: muted,
        ),
        for (final device in devices)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.devices_other),
            title: Text(device.name),
            subtitle: Text(
              device.deviceId == me?.deviceId
                  ? 'This device'
                  : 'Linked ${_date(device.linkedAt)}',
            ),
            trailing: device.deviceId == me?.deviceId
                ? null
                : IconButton(
                    tooltip: 'Remove device',
                    icon: const Icon(Icons.link_off),
                    onPressed: controller.mayManageAccountDevices
                        ? () => _revoke(context, device.deviceId, device.name)
                        : null,
                  ),
          ),
        if (devices.length > 1 && !controller.mayManageAccountDevices)
          Text(
            'This device was linked less than a day ago, so it cannot add or '
            'remove devices yet.',
            style: muted,
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('link-a-device'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) =>
                    LinkExistingDialog(controller: controller, onScan: onScan),
              ),
              icon: const Icon(Icons.add_link),
              label: const Text('Link a device'),
            ),
            if (devices.length <= 1)
              TextButton.icon(
                key: const ValueKey('link-this-device'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => LinkNewDeviceDialog(controller: controller),
                ),
                icon: const Icon(Icons.qr_code),
                label: const Text('Link this device to my account'),
              ),
          ],
        ),
      ],
    );
  }
}

/// The code comparison shared by both sides.
class _CompareCode extends StatelessWidget {
  const _CompareCode({required this.code, required this.onConfirm});

  final String code;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final grouped = '${code.substring(0, 3)} ${code.substring(3)}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Check that both devices show this code:'),
        const SizedBox(height: 12),
        Text(
          grouped,
          key: const ValueKey('link-code'),
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const ValueKey('link-codes-match'),
          onPressed: onConfirm,
          child: const Text('The codes match'),
        ),
      ],
    );
  }
}

/// On the device already in the account: scan the new device's code.
class LinkExistingDialog extends StatefulWidget {
  const LinkExistingDialog({super.key, required this.controller, this.onScan});

  final MessengerController controller;
  final Future<String?> Function()? onScan;

  @override
  State<LinkExistingDialog> createState() => _LinkExistingDialogState();
}

class _LinkExistingDialogState extends State<LinkExistingDialog> {
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _start(String text) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.startLinkFromQrCode(text);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final state = widget.controller.linkState;
        final code = widget.controller.linkCode;
        return AlertDialog(
          title: const Text('Link a device'),
          content: SingleChildScrollView(
            child: switch (state) {
              LinkState.linked => const Text(
                'Linked. The new device now has your account and contacts; '
                'your contacts will see it as you.',
              ),
              LinkState.waitingForOtherDevice => const Text(
                'Confirm the code on the new device too.',
              ),
              LinkState.compareCode when code != null => _CompareCode(
                code: code,
                onConfirm: () => widget.controller.confirmLinkCode(),
              ),
              _ => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'On the new device, open Settings → Devices → Link this '
                    'device to my account, then scan the code it shows.',
                  ),
                  const SizedBox(height: 12),
                  if (widget.onScan != null)
                    FilledButton.icon(
                      onPressed: _busy
                          ? null
                          : () async {
                              final text = await widget.onScan!();
                              if (text != null) await _start(text);
                            },
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Scan code'),
                    ),
                  TextField(
                    key: const ValueKey('link-code-input'),
                    controller: _code,
                    decoration: const InputDecoration(
                      labelText: 'Or paste the code',
                    ),
                    onSubmitted: _start,
                  ),
                  if (_error case final error?)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            },
          ),
          actions: [
            if (state == LinkState.none)
              TextButton(
                onPressed: _busy ? null : () => _start(_code.text),
                child: const Text('Continue'),
              ),
            TextButton(
              onPressed: () {
                if (state != LinkState.linked) widget.controller.cancelLink();
                Navigator.pop(context);
              },
              child: Text(state == LinkState.linked ? 'Done' : 'Cancel'),
            ),
          ],
        );
      },
    );
  }
}

/// On the new device: show a code for the existing device to scan.
class LinkNewDeviceDialog extends StatefulWidget {
  const LinkNewDeviceDialog({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<LinkNewDeviceDialog> createState() => _LinkNewDeviceDialogState();
}

class _LinkNewDeviceDialogState extends State<LinkNewDeviceDialog> {
  String? _qr;

  @override
  void initState() {
    super.initState();
    // After the first frame: starting notifies listeners, which must not
    // happen while this dialog is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.startLinkAsNewDevice().then((qr) {
        if (mounted) setState(() => _qr = qr);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final state = widget.controller.linkState;
        final code = widget.controller.linkCode;
        final qr = _qr;
        return AlertDialog(
          title: const Text('Link this device'),
          content: SingleChildScrollView(
            child: switch (state) {
              LinkState.linked => const Text(
                'This device is now linked to your account.',
              ),
              LinkState.waitingForOtherDevice => const Text(
                'Waiting for the other device…',
              ),
              LinkState.compareCode when code != null => _CompareCode(
                code: code,
                onConfirm: () => widget.controller.confirmLinkCode(),
              ),
              _ => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'On the device you already use, open Settings → Devices → '
                    'Link a device and scan this code. Both devices should be '
                    'on the same network or online.',
                  ),
                  const SizedBox(height: 12),
                  if (qr == null)
                    const CircularProgressIndicator()
                  else ...[
                    SizedBox.square(
                      dimension: 240,
                      child: QrImageView(
                        data: qr,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      qr,
                      key: const ValueKey('link-qr-text'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (state != LinkState.linked) widget.controller.cancelLink();
                Navigator.pop(context);
              },
              child: Text(state == LinkState.linked ? 'Done' : 'Cancel'),
            ),
          ],
        );
      },
    );
  }
}

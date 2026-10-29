import '../app_locales.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../link/link_choice.dart';
import '../messenger_controller.dart';
import '../transfer/own_device_sync_policy.dart' show SyncSpeed;

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

  String _subtitle(
    String deviceId, {
    required bool isThis,
    required DateTime linkedAt,
    DateTime? outOfTouchSince,
  }) {
    if (isThis) return 'This device';
    if (outOfTouchSince != null) {
      return 'Out of touch since ${_date(outOfTouchSince)}: nothing syncs '
          'with it until you confirm it is still yours.';
    }
    return 'Linked ${_date(linkedAt)}';
  }

  Future<void> _revoke(
    BuildContext context,
    String deviceId,
    String name,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiRemoveValueF4FE4B((name).toString())),
        content: Text(l10nOf(context).uiYourContactsWillStopAccepting5B0F03),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10nOf(context).uiRemoveE96390),
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

  Future<void> _setSyncSpeed(BuildContext context, SyncSpeed speed) async {
    var confirmed = false;
    if (speed == SyncSpeed.fast) {
      final l10n = l10nOf(context);
      final answer = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.devicesSyncFast),
          content: Text(l10n.devicesSyncFastWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.actionCancel),
            ),
            FilledButton(
              key: const ValueKey('sync-fast-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.devicesSyncFastTurnOn),
            ),
          ],
        ),
      );
      if (answer != true) return;
      confirmed = true;
    }
    try {
      await controller.setOwnDeviceSyncSpeed(speed, confirmFast: confirmed);
    } catch (error) {
      controller.setStatus('$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = controller.identity;
    final devices = controller.accountDevices?.devices ?? const [];
    final unconfirmed = <String, DateTime>{
      for (final device in controller.unconfirmedOwnDevices)
        device.deviceId: device.inTouchAt ?? device.trustedAt,
    };
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      key: const ValueKey('devices-panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          devices.length > 1
              ? l10nOf(context).uiThisAccountIsOnValueB78C80((devices.length))
              : l10nOf(context).uiUseConestOnMoreThanD2AA6A,
          style: muted,
        ),
        for (final device in devices)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              unconfirmed.containsKey(device.deviceId)
                  ? Icons.sync_disabled
                  : Icons.devices_other,
            ),
            title: Text(device.name),
            subtitle: Text(
              _subtitle(
                device.deviceId,
                isThis: device.deviceId == me?.deviceId,
                linkedAt: device.linkedAt,
                outOfTouchSince: unconfirmed[device.deviceId],
              ),
            ),
            trailing: device.deviceId == me?.deviceId
                ? null
                : unconfirmed.containsKey(device.deviceId)
                // Possibly not theirs any more: both choices.
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        key: ValueKey('confirm-device-${device.deviceId}'),
                        onPressed: () =>
                            controller.confirmOwnDevice(device.deviceId),
                        child: Text(l10nOf(context).uiStillMine38C8AE),
                      ),
                      IconButton(
                        tooltip: l10nOf(context).uiRemoveDeviceA9C39D,
                        icon: const Icon(Icons.link_off),
                        onPressed: controller.mayManageAccountDevices
                            ? () =>
                                  _revoke(context, device.deviceId, device.name)
                            : null,
                      ),
                    ],
                  )
                : IconButton(
                    tooltip: l10nOf(context).uiRemoveDeviceA9C39D,
                    icon: const Icon(Icons.link_off),
                    onPressed: controller.mayManageAccountDevices
                        ? () => _revoke(context, device.deviceId, device.name)
                        : null,
                  ),
          ),
        if (devices.length > 1 && !controller.mayManageAccountDevices)
          Text(l10nOf(context).uiThisDeviceWasLinkedLess2E5122, style: muted),
        if (devices.length > 1)
          Row(
            children: [
              Expanded(
                child: Text(
                  l10nOf(context).uiPauseSyncingWithADevice89642E,
                  style: muted,
                ),
              ),
              DropdownButton<int>(
                key: const ValueKey('device-touch-days'),
                value: me?.ownDeviceTouchDays,
                items: [
                  for (final days in {
                    3,
                    7,
                    14,
                    30,
                    me?.ownDeviceTouchDays ?? 7,
                  })
                    DropdownMenuItem(
                      value: days,
                      child: Text(l10nOf(context).uiValueDaysEE919A((days))),
                    ),
                ],
                onChanged: (days) {
                  if (days != null) controller.setOwnDeviceTouchDays(days);
                },
              ),
            ],
          ),
        if (devices.length > 1) ...[
          const SizedBox(height: 8),
          Text(l10nOf(context).devicesSyncSpeed, style: muted),
          const SizedBox(height: 4),
          SegmentedButton<SyncSpeed>(
            key: const ValueKey('sync-speed'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: SyncSpeed.steady,
                label: Text(l10nOf(context).devicesSyncSteady),
              ),
              ButtonSegment(
                value: SyncSpeed.fast,
                label: Text(l10nOf(context).devicesSyncFast),
              ),
              ButtonSegment(
                value: SyncSpeed.paused,
                label: Text(l10nOf(context).devicesSyncPaused),
              ),
            ],
            selected: {me?.connectivity.syncSpeed ?? SyncSpeed.steady},
            onSelectionChanged: (picked) =>
                _setSyncSpeed(context, picked.single),
          ),
          SwitchListTile(
            key: const ValueKey('share-settings'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10nOf(context).devicesShareSettings),
            subtitle: Text(l10nOf(context).devicesShareSettingsHint),
            value: me?.connectivity.shareSettings ?? false,
            onChanged: (on) => controller.setShareSettings(on),
          ),
        ],
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
              label: Text(l10nOf(context).uiLinkADeviceE71635),
            ),
            // Also with other devices: this one may move to another account
            // (the dialog warns first).
            TextButton.icon(
              key: const ValueKey('link-this-device'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => LinkNewDeviceDialog(controller: controller),
              ),
              icon: const Icon(Icons.qr_code),
              label: Text(l10nOf(context).uiLinkThisDeviceToMy888A1A),
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
        Text(l10nOf(context).uiCheckThatBothDevicesShow031E51),
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
          child: Text(l10nOf(context).uiTheCodesMatch32C407),
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
          title: Text(l10nOf(context).uiLinkADeviceE71635),
          content: SingleChildScrollView(
            child: switch (state) {
              LinkState.linked => Text(
                l10nOf(context).uiLinkedTheNewDeviceNow9900E5,
              ),
              LinkState.waitingForOtherDevice => Text(
                l10nOf(context).uiConfirmTheCodeOnThe17BB1F,
              ),
              LinkState.connecting => Text(
                l10nOf(context).uiWaitingForTheNewDevice75283F,
              ),
              LinkState.compareCode when code != null => _CompareCode(
                code: code,
                onConfirm: () => widget.controller.confirmLinkCode(),
              ),
              _ => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10nOf(context).uiOnTheNewDeviceOpen29AF5E),
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
                      label: Text(l10nOf(context).uiScanCode4596C2),
                    ),
                  TextField(
                    key: const ValueKey('link-code-input'),
                    controller: _code,
                    decoration: InputDecoration(
                      labelText: l10nOf(context).uiOrPasteTheCodeE72792,
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
                child: Text(l10nOf(context).actionContinue),
              ),
            TextButton(
              onPressed: () {
                if (state != LinkState.linked) widget.controller.cancelLink();
                Navigator.pop(context);
              },
              child: Text(
                state == LinkState.linked
                    ? l10nOf(context).uiDoneE9B450
                    : l10nOf(context).actionCancel,
              ),
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

  /// The user read what linking does to this device and agreed.
  bool _started = false;
  LinkMode _mode = LinkMode.merge;
  LinkSettingsChoice _settings = LinkSettingsChoice.keepMine;

  Future<void> _pickMode(LinkMode mode) async {
    if (mode == LinkMode.replace) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(l10nOf(context).linkModeReplaceConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10nOf(context).actionCancel),
            ),
            FilledButton(
              key: const ValueKey('link-replace-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10nOf(context).actionContinue),
            ),
          ],
        ),
      );
      if (yes != true) return;
    }
    setState(() => _mode = mode);
    _applyChoice();
  }

  void _applyChoice() {
    try {
      widget.controller.chooseLinkMode(
        _mode,
        settings: _settings,
        confirmReplace: _mode == LinkMode.replace,
      );
    } catch (_) {}
  }

  Widget _choices(BuildContext context) {
    final l10n = l10nOf(context);
    final summary = widget.controller.linkSummary();
    String line(String side, int c, int ch, int g, int f) =>
        l10n.linkSummaryLine(side, c, ch, g, f);
    Widget mode(LinkMode value, String title, String? hint) => ListTile(
      key: ValueKey('link-mode-${value.name}'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        _mode == value
            ? Icons.radio_button_checked
            : Icons.radio_button_unchecked,
      ),
      title: Text(title),
      subtitle: hint == null ? null : Text(hint),
      enabled: value != LinkMode.separateProfile,
      onTap: value == LinkMode.separateProfile ? null : () => _pickMode(value),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          line(
            l10n.linkSideThisDevice,
            summary.thisContacts,
            summary.thisChats,
            summary.thisGroups,
            summary.thisFiles,
          ),
        ),
        Text(
          line(
            l10n.linkSideAccount,
            summary.accountContacts,
            summary.accountChats,
            summary.accountGroups,
            summary.accountFiles,
          ),
        ),
        for (final c in summary.conflicts)
          Text(
            c.isGroup
                ? l10n.linkConflictGroup(c.thisName)
                : l10n.linkConflictContact(c.thisName, c.accountName),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 8),
        mode(LinkMode.merge, l10n.linkModeMerge, l10n.linkModeMergeHint),
        mode(
          LinkMode.bringMine,
          l10n.linkModeBringMine,
          l10n.linkModeBringMineHint,
        ),
        mode(LinkMode.replace, l10n.linkModeReplace, l10n.linkModeReplaceHint),
        mode(LinkMode.separateProfile, l10n.linkModeSeparate, null),
        if (_mode != LinkMode.bringMine) ...[
          const SizedBox(height: 4),
          SegmentedButton<LinkSettingsChoice>(
            key: const ValueKey('link-settings-choice'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: LinkSettingsChoice.keepMine,
                label: Text(l10n.linkSettingsKeep),
              ),
              ButtonSegment(
                value: LinkSettingsChoice.takeAccount,
                label: Text(l10n.linkSettingsTake),
              ),
            ],
            selected: {_settings},
            onSelectionChanged: (picked) {
              setState(() => _settings = picked.single);
              _applyChoice();
            },
          ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }

  void _start({bool leaveAccount = false}) {
    setState(() => _started = true);
    // After the first frame: starting notifies listeners, which must not
    // happen while this dialog is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller
          .startLinkAsNewDevice(leaveCurrentAccount: leaveAccount)
          .then((qr) {
            if (mounted) setState(() => _qr = qr);
          });
    });
  }

  Widget _beforeLinking(BuildContext context, DeviceLinkPreview preview) {
    final l10n = l10nOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.linkKeepsThisDevice(
            preview.chats,
            preview.contacts,
            preview.groups,
          ),
        ),
        if (preview.joinsOtherAccount) ...[
          const SizedBox(height: 12),
          Text(
            l10n.linkLeavesAccount(preview.otherAccountDevices),
            key: const ValueKey('link-leaves-account'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final state = widget.controller.linkState;
        final code = widget.controller.linkCode;
        final qr = _qr;
        final preview = widget.controller.deviceLinkPreview();
        return AlertDialog(
          title: Text(l10nOf(context).uiLinkThisDeviceBF5E5C),
          content: SingleChildScrollView(
            child: switch (state) {
              LinkState.none when !_started => _beforeLinking(context, preview),
              LinkState.linked => Text(
                l10nOf(context).uiThisDeviceIsNowLinked7EA826,
              ),
              LinkState.waitingForOtherDevice => Text(
                l10nOf(context).uiWaitingForTheOtherDeviceB39C3F,
              ),
              LinkState.compareCode when code != null => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _choices(context),
                  _CompareCode(
                    code: code,
                    onConfirm: () => widget.controller.confirmLinkCode(),
                  ),
                ],
              ),
              _ => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10nOf(context).uiOnTheDeviceYouAlready92C421),
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
            if (!_started && state == LinkState.none)
              FilledButton(
                key: const ValueKey('link-continue'),
                onPressed: () =>
                    _start(leaveAccount: preview.joinsOtherAccount),
                child: Text(
                  preview.joinsOtherAccount
                      ? l10nOf(context).linkLeaveAndContinue
                      : l10nOf(context).actionContinue,
                ),
              ),
            TextButton(
              onPressed: () {
                if (state != LinkState.linked) widget.controller.cancelLink();
                Navigator.pop(context);
              },
              child: Text(
                state == LinkState.linked
                    ? l10nOf(context).uiDoneE9B450
                    : l10nOf(context).actionCancel,
              ),
            ),
          ],
        );
      },
    );
  }
}

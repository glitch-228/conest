import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_locales.dart';
import '../messenger_controller.dart';
import '../qr_scan_screen.dart';
import '../xmpp/omemo/omemo_engine.dart';
import '../xmpp/omemo/omemo_suite.dart';
import '../xmpp/xmpp_chats.dart';
import '../xmpp/xmpp_omemo.dart';

/// Whether every known device of the chat's contact is verified.
bool xmppChatVerified(MessengerController controller, XmppChat chat) =>
    !chat.room &&
    (controller.xmppChatClient?.omemo?.engine?.allDevicesVerified(chat.jid) ??
        false);

bool _isOmemo2(XmppSecurity? security) =>
    security == XmppSecurity.omemo2 || security == XmppSecurity.omemo2Verified;

/// What the chat header says about encryption. OMEMO 2 is "encrypted,
/// unverified" unless every device of the contact is verified; legacy OMEMO
/// is never called "encrypted" until that code has been reviewed.
String xmppEncryptionLabel(
  BuildContext context,
  XmppChat chat, {
  bool verified = false,
}) {
  final l10n = l10nOf(context);
  if (chat.room) return l10n.xmppNotEncrypted;
  final last = chat.messages
      .where((m) => m.security != XmppSecurity.plain)
      .lastOrNull;
  if (_isOmemo2(last?.security)) {
    return verified ? l10n.xmppEncOmemo2 : l10n.xmppEncOmemo2Unverified;
  }
  if (last?.security == XmppSecurity.legacyOmemo) return l10n.xmppEncLegacy;
  return switch (chat.encryption) {
    XmppChatEncryption.auto => l10n.xmppEncAuto,
    XmppChatEncryption.on => l10n.xmppEncRequired,
    XmppChatEncryption.off => l10n.xmppNotEncrypted,
  };
}

/// A lock beside the header only for OMEMO 2 messages.
bool xmppShowsLock(XmppChat chat) =>
    !chat.room &&
    _isOmemo2(
      chat.messages
          .where((m) => m.security != XmppSecurity.plain)
          .lastOrNull
          ?.security,
    );

/// What a message shows instead of (or beside) its text, if anything.
String? xmppSecurityNote(BuildContext context, XmppChatMessage message) {
  final l10n = l10nOf(context);
  if (message.securityNote == xmppEditNotAppliedNote) {
    return l10n.xmppEditNotApplied;
  }
  return switch (message.security) {
    XmppSecurity.unreadable => l10n.xmppUnreadable,
    XmppSecurity.untrusted => l10n.xmppUntrustedMsg,
    XmppSecurity.unconfirmed => l10n.xmppUnconfirmedMsg,
    XmppSecurity.legacyOmemo => l10n.xmppEncLegacy,
    _ => null,
  };
}

/// Lets the user choose how the chat [jid] is encrypted.
Future<void> showXmppEncryptionDialog(
  BuildContext context,
  MessengerController controller,
  String jid,
) async {
  final client = controller.xmppChatClient;
  final chat = controller.xmppChats.chats[jid];
  if (client == null || chat == null) return;
  final l10n = l10nOf(context);
  final choice = await showDialog<XmppChatEncryption>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(l10n.xmppEncryptionTitle),
      children: [
        for (final (mode, label) in [
          (XmppChatEncryption.auto, l10n.xmppEncryptionAuto),
          (XmppChatEncryption.on, l10n.xmppEncryptionOn),
          (XmppChatEncryption.off, l10n.xmppEncryptionOff),
        ])
          ListTile(
            title: Text(label),
            trailing: mode == chat.encryption ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(context, mode),
          ),
        ListTile(
          key: const ValueKey('xmpp-open-keys'),
          leading: const Icon(Icons.key_outlined),
          title: Text(l10n.xmppKeysTitle),
          onTap: () {
            Navigator.pop(context);
            unawaited(
              Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) =>
                      XmppKeysScreen(controller: controller, jid: jid),
                ),
              ),
            );
          },
        ),
      ],
    ),
  );
  if (choice != null) client.setEncryption(jid, choice);
}

/// The keys of a chat: this device's fingerprint and code, and the
/// contact's devices to verify, refuse or forget.
class XmppKeysScreen extends StatefulWidget {
  const XmppKeysScreen({
    super.key,
    required this.controller,
    required this.jid,
  });

  final MessengerController controller;
  final String jid;

  @override
  State<XmppKeysScreen> createState() => _XmppKeysScreenState();
}

class _XmppKeysScreenState extends State<XmppKeysScreen> {
  bool _busy = false;
  String? _message;

  XmppOmemo? get _omemo => widget.controller.xmppChatClient?.omemo;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final omemo = _omemo;
    if (omemo == null) return;
    setState(() => _busy = true);
    try {
      await omemo.refreshDevices(widget.jid);
    } catch (_) {
      // Shown as an empty list; the user can try again.
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _scan() async {
    final omemo = _omemo;
    if (omemo == null) return;
    final value = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (value == null || !mounted) return;
    final result = omemo.verifyFromUri(widget.jid, value);
    final l10n = l10nOf(context);
    setState(() {
      _message = result.mismatched > 0
          ? l10n.xmppKeysScanMismatch
          : l10n.xmppKeysScanMatch('${result.verified}');
    });
  }

  String _trustLabel(OmemoTrust trust) {
    final l10n = l10nOf(context);
    return switch (trust) {
      OmemoTrust.blind => l10n.xmppTrustBlind,
      OmemoTrust.verified => l10n.xmppTrustVerified,
      OmemoTrust.distrusted => l10n.xmppTrustRefused,
      OmemoTrust.pending => l10n.xmppTrustPending,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final omemo = _omemo;
    final theme = Theme.of(context);
    final devices = omemo?.knownDevices(widget.jid) ?? const [];
    final mono = theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace');
    return Scaffold(
      appBar: AppBar(title: Text(l10n.xmppKeysTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.xmppKeysYours, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (omemo?.ownUri case final uri?)
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: QrImageView(data: uri, size: 180),
              ),
            ),
          const SizedBox(height: 8),
          SelectableText(
            omemo?.ownFingerprint ?? '…',
            key: const ValueKey('xmpp-own-fingerprint'),
            style: mono,
          ),
          const SizedBox(height: 4),
          Text(l10n.xmppKeysYoursHint, style: theme.textTheme.bodySmall),
          const Divider(height: 32),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.xmppKeysTheirs(widget.jid),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: l10n.xmppKeysRefresh,
                onPressed: _busy ? null : _refresh,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
              IconButton(
                key: const ValueKey('xmpp-scan-keys'),
                tooltip: l10n.xmppKeysScan,
                onPressed: _scan,
                icon: const Icon(Icons.qr_code_scanner),
              ),
            ],
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_message!, key: const ValueKey('xmpp-scan-result')),
            ),
          if (devices.isEmpty && !_busy) Text(l10n.xmppKeysNone),
          for (final device in devices)
            Card(
              key: ValueKey('xmpp-device-${device.id}'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '#${device.id}'
                            '${device.versions.contains(OmemoVersion.v2) ? '' : ' · OMEMO (legacy)'}',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        Chip(
                          label: Text(_trustLabel(device.trust)),
                          avatar: Icon(
                            device.trust == OmemoTrust.verified
                                ? Icons.verified_outlined
                                : device.trust == OmemoTrust.distrusted
                                ? Icons.block
                                : device.trust == OmemoTrust.pending
                                ? Icons.new_releases_outlined
                                : Icons.help_outline,
                            size: 16,
                          ),
                        ),
                      ],
                    ),
                    if (device.fingerprint.isNotEmpty)
                      SelectableText(device.fingerprint, style: mono),
                    if (device.changed)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          l10n.xmppKeysChanged,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (device.trust != OmemoTrust.verified &&
                            device.fingerprint.isNotEmpty)
                          TextButton(
                            onPressed: () => setState(
                              () => omemo?.setTrust(
                                widget.jid,
                                device.id,
                                OmemoTrust.verified,
                              ),
                            ),
                            child: Text(l10n.xmppTrustVerify),
                          ),
                        if (device.trust == OmemoTrust.distrusted ||
                            device.trust == OmemoTrust.pending)
                          TextButton(
                            onPressed: () => setState(
                              () => omemo?.setTrust(
                                widget.jid,
                                device.id,
                                OmemoTrust.blind,
                              ),
                            ),
                            child: Text(l10n.xmppTrustAllow),
                          )
                        else if (device.fingerprint.isNotEmpty)
                          TextButton(
                            onPressed: () => setState(
                              () => omemo?.setTrust(
                                widget.jid,
                                device.id,
                                OmemoTrust.distrusted,
                              ),
                            ),
                            child: Text(l10n.xmppTrustRefuse),
                          ),
                        if (device.fingerprint.isNotEmpty)
                          TextButton(
                            onPressed: () => setState(
                              () => omemo?.forgetDevice(widget.jid, device.id),
                            ),
                            child: Text(l10n.xmppKeysForget),
                          ),
                        if (device.fingerprint.isNotEmpty)
                          IconButton(
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).copyButtonLabel,
                            icon: const Icon(Icons.copy, size: 18),
                            onPressed: () => Clipboard.setData(
                              ClipboardData(text: device.fingerprint),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The legacy OMEMO switch of the XMPP chats panel.
class XmppLegacyOmemoTile extends StatelessWidget {
  const XmppLegacyOmemoTile({super.key, required this.controller});

  final MessengerController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    return SwitchListTile(
      key: const ValueKey('xmpp-legacy-omemo'),
      contentPadding: EdgeInsets.zero,
      title: Text(l10n.xmppLegacySwitch),
      subtitle: Text(l10n.xmppLegacyHint),
      value: controller.xmppLegacyOmemo,
      onChanged: (value) => unawaited(controller.setXmppLegacyOmemo(value)),
    );
  }
}

import '../app_locales.dart';
import 'package:flutter/material.dart';

import '../email_carrier.dart';
import '../messenger_controller.dart';
import '../network_errors.dart';
import 'carrier_switch.dart';
import '../transport_models.dart';

/// The email carrier in Settings: a new chatmail account in one tap, or an
/// existing mail account, and the connection state.
class EmailCarrierPanel extends StatefulWidget {
  const EmailCarrierPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<EmailCarrierPanel> createState() => _EmailCarrierPanelState();
}

class _EmailCarrierPanelState extends State<EmailCarrierPanel> {
  // Empty: the server that answers fastest on this network.
  final _domain = TextEditingController();
  final _mail = TextEditingController();
  final _password = TextEditingController();
  final _imapHost = TextEditingController();
  final _imapPort = TextEditingController(text: '993');
  final _smtpHost = TextEditingController();
  final _smtpPort = TextEditingController(text: '465');
  bool _ownAccount = false;
  bool _busy = false;

  /// Changing the account in use (the setup form, filled in).
  bool _editing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    for (final field in [
      _domain,
      _mail,
      _password,
      _imapHost,
      _imapPort,
      _smtpHost,
      _smtpPort,
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
        setState(() => _error = describeActionError(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Sets up (or changes to) the account the form describes.
  Future<void> _setUp() async {
    await (_ownAccount
        ? _useOwnAccount()
        : widget.controller.enableChatmailCarrier(_domain.text));
    if (mounted) setState(() => _editing = false);
  }

  /// The form, filled in with the account in use.
  void _startEditing(EmailCarrierConfig config) => setState(() {
    _editing = true;
    _error = null;
    _ownAccount = !config.chatmail;
    if (config.chatmail) {
      _domain.text = '';
    } else {
      _mail.text = config.mail;
      _password.text = config.password;
      _imapHost.text = config.imapHost;
      _imapPort.text = '${config.imapPort}';
      _smtpHost.text = config.smtpHost;
      _smtpPort.text = '${config.smtpPort}';
    }
  });

  Future<void> _useOwnAccount() => widget.controller.enableOwnEmailCarrier(
    mail: _mail.text,
    password: _password.text,
    imapHost: _imapHost.text,
    imapPort: int.tryParse(_imapPort.text) ?? 993,
    smtpHost: _smtpHost.text,
    smtpPort: int.tryParse(_smtpPort.text) ?? 465,
  );

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final config = controller.emailCarrierConfig;
    final channel = controller.emailChannel;
    final theme = Theme.of(context);
    Widget field(
      TextEditingController text,
      String label, {
      bool obscure = false,
      TextInputType? keyboard,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: text,
        enabled: !_busy,
        obscureText: obscure,
        keyboardType: keyboard,
        decoration: InputDecoration(labelText: label, isDense: true),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CarrierSwitch(
          switchKey: const ValueKey('email-carrier-switch'),
          controller: controller,
          kind: TransportKind.deltaChat,
          title: l10nOf(context).uiEmail84ADD5,
          subtitle: l10nOf(context).uiCarryMessagesAsEncryptedEmail0D19EA,
          configured: config != null,
          busy: _busy,
          run: _run,
          onSetUp: _setUp,
          onRemove: controller.disableEmailCarrier,
        ),
        if (config != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.circle,
              size: 12,
              color: switch (channel?.state) {
                EmailCarrierState.connected => Colors.green,
                EmailCarrierState.connecting => Colors.amber,
                _ => theme.colorScheme.error,
              },
            ),
            title: SelectableText(config.mail),
            subtitle: channel?.lastError == null
                ? null
                : Text(channel!.lastError!, maxLines: 2),
          ),
        if (config != null && !_editing)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('email-change-account'),
              onPressed: _busy ? null : () => _startEditing(config),
              icon: const Icon(Icons.edit_outlined),
              label: Text(
                config.chatmail
                    ? l10nOf(context).emailOtherServer
                    : l10nOf(context).emailChangeAccount,
              ),
            ),
          ),
        if (config == null || _editing) ...[
          if (!_ownAccount)
            field(
              _domain,
              'Chatmail server (empty: the fastest one reachable here)',
            ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _ownAccount,
            onChanged: _busy
                ? null
                : (value) => setState(() => _ownAccount = value ?? false),
            title: Text(l10nOf(context).uiUseMyOwnEmailAccountE78C1D),
          ),
          if (_ownAccount) ...[
            field(_mail, 'Email address', keyboard: TextInputType.emailAddress),
            field(_password, 'Password or app password', obscure: true),
            field(_imapHost, 'IMAP server (TLS)'),
            field(_imapPort, 'IMAP port', keyboard: TextInputType.number),
            field(_smtpHost, 'SMTP server (TLS)'),
            field(_smtpPort, 'SMTP port', keyboard: TextInputType.number),
          ],
          if (_editing)
            Row(
              children: [
                FilledButton(
                  key: const ValueKey('email-save-account'),
                  onPressed: _busy ? null : () => _run(_setUp),
                  child: Text(l10nOf(context).actionSave),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _editing = false),
                  child: Text(l10nOf(context).actionCancel),
                ),
              ],
            ),
        ],
        if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }
}

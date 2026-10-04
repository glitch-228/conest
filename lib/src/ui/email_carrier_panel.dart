import 'package:flutter/material.dart';

import '../email_carrier.dart';
import '../messenger_controller.dart';

/// The email carrier in Settings: a new chatmail account in one tap, or an
/// existing mail account, and the connection state.
class EmailCarrierPanel extends StatefulWidget {
  const EmailCarrierPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<EmailCarrierPanel> createState() => _EmailCarrierPanelState();
}

class _EmailCarrierPanelState extends State<EmailCarrierPanel> {
  final _domain = TextEditingController(text: defaultChatmailDomains.first);
  final _mail = TextEditingController();
  final _password = TextEditingController();
  final _imapHost = TextEditingController();
  final _imapPort = TextEditingController(text: '993');
  final _smtpHost = TextEditingController();
  final _smtpPort = TextEditingController(text: '465');
  bool _ownAccount = false;
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
        setState(
          () => _error = error is ArgumentError ? '${error.message}' : '$error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
        SwitchListTile.adaptive(
          key: const ValueKey('email-carrier-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Email'),
          subtitle: const Text(
            'Carry messages as encrypted email when other routes fail, '
            'like Delta Chat. The mail servers see both addresses and when, '
            'not what. Your contacts learn the address automatically.',
          ),
          value: config != null,
          onChanged: _busy
              ? null
              : (on) => _run(
                  on
                      ? (_ownAccount
                            ? _useOwnAccount
                            : () => controller.enableChatmailCarrier(
                                _domain.text,
                              ))
                      : controller.disableEmailCarrier,
                ),
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
            title: Text(config.mail),
            subtitle: channel?.lastError == null
                ? null
                : Text(channel!.lastError!, maxLines: 2),
          )
        else ...[
          if (!_ownAccount)
            field(_domain, 'Chatmail server (a new account is created)'),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _ownAccount,
            onChanged: _busy
                ? null
                : (value) => setState(() => _ownAccount = value ?? false),
            title: const Text('Use my own email account instead'),
          ),
          if (_ownAccount) ...[
            field(_mail, 'Email address', keyboard: TextInputType.emailAddress),
            field(_password, 'Password or app password', obscure: true),
            field(_imapHost, 'IMAP server (TLS)'),
            field(_imapPort, 'IMAP port', keyboard: TextInputType.number),
            field(_smtpHost, 'SMTP server (TLS)'),
            field(_smtpPort, 'SMTP port', keyboard: TextInputType.number),
          ],
        ],
        if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../messenger_controller.dart';
import '../network_errors.dart';
import '../transport_models.dart';
import '../xmpp/xmpp_carrier.dart';
import '../xmpp/xmpp_registration.dart';
import 'carrier_switch.dart';

/// The XMPP carrier in Settings → Connectivity: an account Conest creates
/// on a public server that answers here, or the user's own, and the
/// connection state.
class XmppCarrierPanel extends StatefulWidget {
  const XmppCarrierPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<XmppCarrierPanel> createState() => _XmppCarrierPanelState();
}

class _XmppCarrierPanelState extends State<XmppCarrierPanel> {
  // Empty: whichever public server answers first here.
  final _server = TextEditingController();
  final _jid = TextEditingController();
  final _password = TextEditingController();
  bool _ownAccount = false;
  bool _busy = false;
  bool _editing = false;
  String? _error;

  // Servers that sign people up on a website, after a failed set-up.
  List<XmppServerOutcome> _webSignups = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _server.dispose();
    _jid.dispose();
    _password.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _webSignups = const [];
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = describeActionError(error);
          if (error is XmppAccountCreationException) {
            _webSignups = error.webSignups.take(5).toList();
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setUp() async {
    final server = _server.text.trim().toLowerCase();
    if (_ownAccount) {
      await widget.controller.enableXmppCarrier(
        jid: _jid.text,
        password: _password.text,
      );
    } else {
      await widget.controller.enableXmppCarrier(
        servers: server.isEmpty ? null : [server],
        captchaSolver: _askCaptcha,
      );
    }
    if (mounted) {
      setState(() {
        _editing = false;
        _password.clear();
      });
    }
  }

  /// Shows a server's CAPTCHA picture; what the user typed, or null.
  Future<String?> _askCaptcha(XmppCaptchaChallenge challenge) async {
    if (!mounted) return null;
    final l10n = l10nOf(context);
    final answer = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(l10n.xmppCaptchaTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (challenge.instructions case final text?) ...[
                Text(text),
                const SizedBox(height: 8),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 140),
                child: Image.memory(
                  challenge.image,
                  key: const ValueKey('xmpp-captcha-image'),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('xmpp-captcha-answer'),
                controller: answer,
                autofocus: true,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: l10n.xmppCaptchaAnswerField,
                  isDense: true,
                ),
                onSubmitted: (value) => Navigator.pop(context, value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.actionCancel),
            ),
            FilledButton(
              key: const ValueKey('xmpp-captcha-send'),
              onPressed: () => Navigator.pop(context, answer.text),
              child: Text(l10n.actionContinue),
            ),
          ],
        ),
      );
    } finally {
      answer.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final controller = widget.controller;
    final config = controller.xmppCarrierConfig;
    final channel = controller.xmppChannel;
    final theme = Theme.of(context);
    Widget field(
      TextEditingController text,
      String label, {
      bool obscure = false,
      Key? key,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: key,
        controller: text,
        enabled: !_busy,
        obscureText: obscure,
        autocorrect: false,
        decoration: InputDecoration(labelText: label, isDense: true),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CarrierSwitch(
          switchKey: const ValueKey('xmpp-carrier-switch'),
          controller: controller,
          kind: TransportKind.xmpp,
          title: 'XMPP',
          subtitle: l10n.xmppCarrierSubtitle,
          configured: config != null,
          busy: _busy,
          run: _run,
          onSetUp: _setUp,
          onRemove: controller.disableXmppCarrier,
        ),
        if (config != null)
          ListTile(
            key: const ValueKey('xmpp-carrier-status'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.circle,
              size: 12,
              color: switch (channel?.state) {
                XmppCarrierState.connected => Colors.green,
                XmppCarrierState.connecting => Colors.amber,
                _ => theme.colorScheme.error,
              },
            ),
            title: SelectableText(config.jid),
            subtitle: Text(
              [
                config.created ? l10n.xmppCreatedAccount : l10n.xmppOwnAccount,
                if (channel?.session?.endpoint case final endpoint?)
                  endpoint.label,
                ?channel?.lastError,
              ].join(' · '),
              maxLines: 3,
            ),
          ),
        if (config != null && !_editing)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('xmpp-change-account'),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _editing = true;
                      _error = null;
                      _ownAccount = !config.created;
                      if (!config.created) _jid.text = config.jid;
                    }),
              icon: const Icon(Icons.edit_outlined),
              label: Text(l10n.xmppChangeAccount),
            ),
          ),
        if (config == null || _editing) ...[
          if (!_ownAccount)
            field(
              _server,
              l10n.xmppServerField,
              key: const ValueKey('xmpp-server-field'),
            ),
          CheckboxListTile(
            key: const ValueKey('xmpp-own-account'),
            contentPadding: EdgeInsets.zero,
            value: _ownAccount,
            onChanged: _busy
                ? null
                : (value) => setState(() => _ownAccount = value ?? false),
            title: Text(l10n.xmppUseOwnAccount),
            subtitle: Text(l10n.xmppOwnAccountNote),
          ),
          if (_ownAccount) ...[
            field(
              _jid,
              l10n.xmppAddressField,
              key: const ValueKey('xmpp-jid-field'),
            ),
            field(
              _password,
              l10n.xmppPasswordField,
              obscure: true,
              key: const ValueKey('xmpp-password-field'),
            ),
          ],
          if (_editing)
            Row(
              children: [
                FilledButton(
                  key: const ValueKey('xmpp-save-account'),
                  onPressed: _busy ? null : () => _run(_setUp),
                  child: Text(l10n.actionSave),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _editing = false),
                  child: Text(l10n.actionCancel),
                ),
              ],
            ),
        ],
        if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        if (_webSignups.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(l10n.xmppSignUpOnWebsite),
          for (final server in _webSignups)
            ListTile(
              key: ValueKey('xmpp-web-signup-${server.domain}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(server.domain),
              subtitle: SelectableText(server.url!),
              trailing: TextButton(
                onPressed: () =>
                    controller.openExternalUrl(Uri.parse(server.url!)),
                child: Text(l10n.xmppOpenWebsite),
              ),
            ),
        ],
      ],
    );
  }
}

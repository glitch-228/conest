import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../messenger_controller.dart';
import '../network_errors.dart';
import '../transport_models.dart';
import '../xmpp/xmpp_carrier.dart';
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
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = describeActionError(error));
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
        servers: server.isEmpty ? defaultXmppServers : [server],
      );
    }
    if (mounted) {
      setState(() {
        _editing = false;
        _password.clear();
      });
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
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../messenger_controller.dart';
import '../models.dart';

/// Shows who may use [relay] (as its health said) and, where it takes
/// registrations, a Register step asking for an invite code or the
/// password when needed.
Future<void> showRelayAccessDialog(
  BuildContext context,
  MessengerController controller,
  PeerEndpoint relay,
) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _RelayAccessDialog(controller: controller, relay: relay),
  );
}

class _RelayAccessDialog extends StatefulWidget {
  const _RelayAccessDialog({required this.controller, required this.relay});

  final MessengerController controller;
  final PeerEndpoint relay;

  @override
  State<_RelayAccessDialog> createState() => _RelayAccessDialogState();
}

class _RelayAccessDialogState extends State<_RelayAccessDialog> {
  final _secret = TextEditingController();
  bool _busy = false;
  String? _outcome;

  @override
  void dispose() {
    _secret.dispose();
    super.dispose();
  }

  Future<void> _register(String? registration) async {
    setState(() {
      _busy = true;
      _outcome = null;
    });
    final l10n = l10nOf(context);
    try {
      await widget.controller.registerWithRelay(
        widget.relay,
        invite: registration == 'invite' ? _secret.text : null,
        password: registration == 'password' ? _secret.text : null,
      );
      _outcome = l10n.relayAccessRegisteredNow;
    } on Object catch (error) {
      _outcome = l10n.relayAccessFailed(
        error.toString().replaceFirst('Bad state: ', ''),
      );
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final info = widget.controller.relayAccessFor(widget.relay);
    final until = widget.controller.relayRegisteredUntil(widget.relay);
    final registration = info?.registration;
    final lines = <String>[
      if (info == null || (info.tier1 == null && registration == null))
        l10n.relayAccessUnknown,
      if (info != null && info.sessions) l10n.relayAccessSessions,
      switch (info?.tier1) {
        'open' => l10n.relayAccessMessagesOpen,
        'registered' => l10n.relayAccessMessagesRegistered,
        'off' => l10n.relayAccessMessagesOff,
        _ => '',
      },
      switch (registration) {
        'open' => l10n.relayAccessRegistrationOpen,
        'invite' => l10n.relayAccessRegistrationInvite,
        'password' => l10n.relayAccessRegistrationPassword,
        'closed' => l10n.relayAccessRegistrationClosed,
        _ => '',
      },
      if (until != null)
        l10n.relayAccessRegistered(
          MaterialLocalizations.of(context).formatMediumDate(until.toLocal()),
        ),
    ].where((line) => line.isNotEmpty).toList();
    final canRegister =
        info != null &&
        info.sessions &&
        (registration == 'open' ||
            registration == 'invite' ||
            registration == 'password' ||
            until != null);
    return AlertDialog(
      title: Text(l10n.relayAccessTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(line),
              ),
            if (canRegister &&
                until == null &&
                (registration == 'invite' || registration == 'password'))
              TextField(
                key: const ValueKey('relay-access-secret'),
                controller: _secret,
                obscureText: registration == 'password',
                decoration: InputDecoration(
                  labelText: registration == 'invite'
                      ? l10n.relayAccessInviteLabel
                      : l10n.relayAccessPasswordLabel,
                ),
              ),
            if (_outcome case final outcome?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(outcome),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
        if (canRegister)
          FilledButton(
            key: const ValueKey('relay-access-register'),
            onPressed: _busy ? null : () => _register(registration),
            child: Text(l10n.relayAccessRegister),
          ),
      ],
    );
  }
}

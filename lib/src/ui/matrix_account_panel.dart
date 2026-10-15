import '../app_locales.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../matrix_service.dart';
import '../messenger_controller.dart';
import 'matrix_verification_dialog.dart';

/// The Matrix account: password and browser sign-in, sign-out, recovery
/// and session verification. Shown in Settings and on the Matrix-only home.
class MatrixAccountPanel extends StatefulWidget {
  const MatrixAccountPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<MatrixAccountPanel> createState() => _MatrixAccountPanelState();
}

class _MatrixAccountPanelState extends State<MatrixAccountPanel> {
  final _matrixHomeserverController = TextEditingController();
  final _matrixUserController = TextEditingController();
  final _matrixPasswordController = TextEditingController();

  /// The account page a browser sign-in is waiting on.
  Uri? _matrixBrowserUrl;
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
    _matrixHomeserverController.dispose();
    _matrixUserController.dispose();
    _matrixPasswordController.dispose();
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
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOutOfMatrix() async {
    Object? failure;
    await _run(() async {
      try {
        await widget.controller.signOutOfMatrix();
      } catch (error) {
        if (widget.controller.matrixClient == null) rethrow;
        failure = error;
      }
    });
    if (failure == null || !mounted) return;
    final text = '$failure';
    // A server that answered but has no sign-out here (sessions handled by a
    // separate account service) is not a network problem.
    final refused =
        text.contains('M_UNRECOGNIZED') ||
        text.contains('404') ||
        text.contains('M_FORBIDDEN');
    final force = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          refused
              ? l10nOf(context).uiServerRefusedSignOut66337B
              : l10nOf(context).uiServerNotReached62FED2,
        ),
        content: Text(
          refused
              ? l10nOf(context).uiThisServerDoesNotLet9EEC1F((text).toString())
              : l10nOf(
                  context,
                ).uiConestCouldNotSignThis3C1074((text).toString()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10nOf(context).uiKeepSignedIn611A13),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10nOf(context).uiSignOutHereA6F129),
          ),
        ],
      ),
    );
    if (force == true) {
      await _run(() => widget.controller.signOutOfMatrix(force: true));
    }
  }

  Future<String?> _askMatrixPassword() async {
    final input = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiMatrixPassword34E218),
        content: TextField(
          controller: input,
          autofocus: true,
          obscureText: true,
          decoration: InputDecoration(
            labelText: l10nOf(context).uiPassword8BE3C9,
            helperText: l10nOf(context).uiYourServerAsksForIt1594FA,
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: Text(l10nOf(context).actionContinue),
          ),
        ],
      ),
    );
    input.dispose();
    return password == null || password.isEmpty ? null : password;
  }

  /// Creates the recovery key that unlocks encrypted Matrix history on a
  /// new device, and shows it once.
  Future<void> _setUpMatrixRecovery(MatrixClientService client) async {
    final state = await client.recoveryState().catchError(
      (Object _) => (recovery: 'Unknown', crossSigning: false),
    );
    if (!mounted) return;
    if (state.recovery == 'Enabled' || state.recovery == 'Incomplete') {
      // A new key would replace the one the user already has.
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10nOf(context).uiRecoveryIsAlreadySetUp371F7F),
          content: Text(
            state.recovery == l10nOf(context).uiEnabledDF174A
                ? l10nOf(context).uiYourEncryptedMatrixHistoryIsC16CD2
                : l10nOf(context).uiThisAccountAlreadyHasA0CF3D8,
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10nOf(context).uiOK9CE3BD),
            ),
          ],
        ),
      );
      return;
    }
    String? key;
    await _run(() async {
      try {
        key = await client.enableRecovery();
      } on MatrixPasswordRequired {
        final password = await _askMatrixPassword();
        if (password == null) return;
        key = await client.enableRecovery(password: password);
      }
    });
    final recoveryKey = key;
    if (!mounted || recoveryKey == null) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiSaveYourRecoveryKey7851B3),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10nOf(context).uiKeepThisKeySomewhereSafe0C0DFE),
            const SizedBox(height: 12),
            SelectableText(
              recoveryKey,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: recoveryKey)),
            child: Text(l10nOf(context).uiCopyAF74F7),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10nOf(context).uiISavedIt3E2255),
          ),
        ],
      ),
    );
  }

  Future<void> _verifyMatrixSession(MatrixClientService client) async {
    String? flowId;
    await _run(() async => flowId = await client.verifyOwnSession());
    final flow = flowId;
    final userId = client.userId;
    if (flow == null || userId == null || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MatrixVerificationDialog(
        client: client,
        userId: userId,
        flowId: flow,
        weStarted: true,
      ),
    );
  }

  Future<void> _enterMatrixRecoveryKey(MatrixClientService client) async {
    final input = TextEditingController();
    final key = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiEnterRecoveryKey4521B6),
        content: TextField(
          controller: input,
          autofocus: true,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: l10nOf(context).uiEsTFromAnotherMatrixAppFCA0C9,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: Text(l10nOf(context).uiUnlock1526A1),
          ),
        ],
      ),
    );
    input.dispose();
    if (key == null || key.trim().isEmpty) return;
    await _run(() => client.recover(key));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _content(context),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  Widget _content(BuildContext context) {
    final status = widget.controller.matrixStatus;
    final client = widget.controller.matrixClient;
    // The full client is the account; the carrier status covers builds
    // without it (and has no session in Matrix-only mode).
    final signedIn = client?.signedIn ?? status?.signedIn == true;
    final userId = client?.userId ?? status?.userId;
    final carrier = widget.controller.conestActive;
    final privacy = carrier
        ? 'Used when LAN and Iroh cannot reach a contact who also linked '
              'Matrix. Messages stay end-to-end encrypted; the homeserver '
              'sees which accounts talk and when, never content.'
        : 'Your Matrix chats, with end-to-end encryption in encrypted '
              'rooms.';
    if (signedIn) {
      final error = client?.lastError ?? status?.lastError;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              l10nOf(context).uiMatrixValueED6C29((userId).toString()),
            ),
            subtitle: Text(
              "${(client == null || !carrier ? privacy : 'Your Matrix chats appear in the chat list. $privacy')}${(error == null ? '' : '\nLast error: $error')}",
            ),
            trailing: TextButton(
              onPressed: _busy ? null : _signOutOfMatrix,
              child: Text(l10nOf(context).uiSignOutDC1649),
            ),
          ),
          if (client != null && client.signedIn)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _setUpMatrixRecovery(client),
                  icon: const Icon(Icons.key_outlined),
                  label: Text(l10nOf(context).uiSetUpRecoveryFD3804),
                ),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _enterMatrixRecoveryKey(client),
                  icon: const Icon(Icons.lock_open_outlined),
                  label: Text(l10nOf(context).uiEnterRecoveryKey4521B6),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _verifyMatrixSession(client),
                  icon: const Icon(Icons.verified_user_outlined),
                  label: Text(l10nOf(context).uiVerifyWithAnotherSession9ED031),
                ),
              ],
            ),
          if (client != null && client.signedIn)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10nOf(context).uiShowJoinsLeavesAndProfile9FA764),
              subtitle: Text(
                l10nOf(context).uiInMatrixRoomsCollapsedIntoD20CAB,
              ),
              value: widget.controller.matrixShowMembership,
              onChanged: (value) =>
                  _run(() => widget.controller.setMatrixShowMembership(value)),
            ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            carrier
                ? l10nOf(context).uiMatrixFallbackAA082C
                : l10nOf(context).uiMatrixAccountD69140,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(privacy),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _matrixUserController,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: l10nOf(context).uiMatrixUser70A560,
                    helperText: l10nOf(context).uiForExampleNameMatrixOrg63C60A,
                  ),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _matrixPasswordController,
                  enabled: !_busy,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l10nOf(context).uiPassword8BE3C9,
                  ),
                ),
              ),
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _matrixHomeserverController,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: l10nOf(context).uiHomeserverOptional70DF85,
                    helperText: l10nOf(context).uiFoundFromTheUserId69A3AB,
                  ),
                ),
              ),
              FilledButton.tonal(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        try {
                          await widget.controller.signInToMatrix(
                            homeserver: _matrixHomeserverController.text,
                            user: _matrixUserController.text,
                            password: _matrixPasswordController.text,
                          );
                        } finally {
                          _matrixPasswordController.clear();
                        }
                      }),
                child: Text(l10nOf(context).uiSignInToMatrix652C8F),
              ),
              if (widget.controller.matrixClient != null)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _signInToMatrixWithBrowser,
                  icon: const Icon(Icons.open_in_browser),
                  label: Text(l10nOf(context).uiSignInWithBrowserC995DF),
                ),
            ],
          ),
          const SizedBox(height: 4),
          if (widget.controller.matrixClient != null)
            Text(
              l10nOf(context).uiAccountsThatSignInThrough64868A,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (_matrixBrowserUrl case final url?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(l10nOf(context).uiFinishSigningInInYour9F41A4),
                  TextButton(
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: url.toString())),
                    child: Text(l10nOf(context).uiCopyLink2F84EE),
                  ),
                  TextButton(
                    onPressed: widget.controller.cancelMatrixBrowserSignIn,
                    child: Text(l10nOf(context).actionCancel),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _signInToMatrixWithBrowser() async {
    try {
      await _run(
        () => widget.controller.signInToMatrixWithBrowser(
          homeserver: _matrixHomeserverController.text,
          user: _matrixUserController.text,
          openUrl: (url) async {
            if (mounted) setState(() => _matrixBrowserUrl = url);
            try {
              await widget.controller.openExternalUrl(url);
            } catch (_) {
              // The link stays available to copy.
            }
          },
        ),
      );
    } finally {
      if (mounted) setState(() => _matrixBrowserUrl = null);
    }
  }
}

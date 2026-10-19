import 'dart:async';

import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../messenger_controller.dart';
import '../network_errors.dart';
import '../transport_models.dart';

/// The transports step of onboarding: what reaches people beyond this
/// network, checked on the network the device is on now. Ways that answer
/// here and need no setup (Nostr, email) are offered ticked; at least one
/// is needed, three are recommended, and finishing with none asks first.
class TransportsStep extends StatefulWidget {
  const TransportsStep({
    super.key,
    required this.controller,
    required this.onBack,
    required this.onDone,
  });

  final MessengerController controller;
  final VoidCallback onBack;

  /// Called once the chosen ways are switched on (or skipped).
  final Future<void> Function() onDone;

  @override
  State<TransportsStep> createState() => _TransportsStepState();
}

class _TransportsStepState extends State<TransportsStep> {
  List<InternetTransportCheck>? _checks;
  final Set<TransportKind> _chosen = {};
  final List<String> _errors = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    List<InternetTransportCheck> checks;
    try {
      checks = await widget.controller.checkInternetTransports();
    } catch (_) {
      checks = const [];
    }
    if (!mounted) return;
    setState(() {
      _checks = checks;
      _chosen
        ..clear()
        ..addAll([
          for (final check in checks)
            if (check.state == InternetTransportState.works) check.kind,
        ]);
    });
  }

  int get _count => [
    for (final check in _checks ?? const <InternetTransportCheck>[])
      if (check.state == InternetTransportState.on ||
          _chosen.contains(check.kind))
        check,
  ].length;

  Future<void> _finish() async {
    final l10n = l10nOf(context);
    if (_count == 0) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.transportsSkipTitle),
          content: Text(l10n.transportsSkipBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.actionBack),
            ),
            FilledButton(
              key: const ValueKey('transports-skip-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.transportsSkipConfirm),
            ),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    setState(() {
      _busy = true;
      _errors.clear();
    });
    for (final kind in _chosen) {
      try {
        switch (kind) {
          case TransportKind.nostr:
            await widget.controller.enableNostrCarrier();
          case TransportKind.deltaChat:
            await widget.controller.enableChatmailCarrier();
          default:
            break;
        }
      } catch (error) {
        _errors.add(
          l10n.transportsTurnOnFailed(kind.label, describeActionError(error)),
        );
      }
    }
    if (!mounted) return;
    if (_errors.isNotEmpty) {
      // Shown; the user can go on or try again.
      setState(() => _busy = false);
      await _check();
      return;
    }
    await widget.onDone();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = l10nOf(context);
    final checks = _checks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.transportsTitle, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 12),
        Text(l10n.transportsIntro),
        const SizedBox(height: 16),
        if (checks == null)
          Row(
            children: [
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(l10n.transportsChecking)),
            ],
          )
        else ...[
          for (final check in checks) _row(theme, check),
          const SizedBox(height: 12),
          Text(
            l10n.transportsCount(_count),
            key: const ValueKey('transports-count'),
            style: theme.textTheme.titleSmall?.copyWith(
              color: _count == 0 ? theme.colorScheme.error : null,
            ),
          ),
        ],
        for (final error in _errors)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        const SizedBox(height: 24),
        Row(
          children: [
            TextButton(
              onPressed: _busy ? null : widget.onBack,
              child: Text(l10n.actionBack),
            ),
            const Spacer(),
            FilledButton(
              key: const ValueKey('transports-start'),
              onPressed: _busy || checks == null ? null : _finish,
              child: Text(l10n.actionStart),
            ),
          ],
        ),
      ],
    );
  }

  Widget _row(ThemeData theme, InternetTransportCheck check) {
    final l10n = l10nOf(context);
    final (label, color) = switch (check.state) {
      InternetTransportState.on => (l10n.transportStateOn, Colors.green),
      InternetTransportState.works => (l10n.transportStateWorks, Colors.green),
      InternetTransportState.blocked => (
        l10n.transportStateBlocked,
        theme.colorScheme.error,
      ),
      InternetTransportState.needsSetup => (
        l10n.transportStateNeedsSetup,
        theme.colorScheme.outline,
      ),
    };
    final status = Text(
      label,
      style: theme.textTheme.bodySmall?.copyWith(color: color),
    );
    final note = check.kind == TransportKind.deltaChat
        ? l10n.transportsEmailCost
        : null;
    if (check.state == InternetTransportState.works) {
      return CheckboxListTile(
        key: ValueKey('transport-${check.kind.name}'),
        contentPadding: EdgeInsets.zero,
        value: _chosen.contains(check.kind),
        onChanged: _busy
            ? null
            : (on) => setState(
                () => on == true
                    ? _chosen.add(check.kind)
                    : _chosen.remove(check.kind),
              ),
        title: Text(check.kind.label),
        subtitle: note == null
            ? status
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [status, Text(note)],
              ),
      );
    }
    return ListTile(
      key: ValueKey('transport-${check.kind.name}'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        check.state == InternetTransportState.on
            ? Icons.check_circle
            : check.state == InternetTransportState.blocked
            ? Icons.block
            : Icons.settings_outlined,
        color: color,
      ),
      title: Text(check.kind.label),
      subtitle: status,
    );
  }
}

/// Above the chats while no way beyond this network works: only devices on
/// it can reach this one. Waits a while first (Iroh and the carriers take a
/// moment after start), and can be put away for this session.
class InternetReachBanner extends StatefulWidget {
  const InternetReachBanner({
    super.key,
    required this.controller,
    required this.onSetUp,
    this.grace = const Duration(seconds: 20),
  });

  final MessengerController controller;
  final VoidCallback onSetUp;
  final Duration grace;

  @override
  State<InternetReachBanner> createState() => _InternetReachBannerState();
}

class _InternetReachBannerState extends State<InternetReachBanner> {
  Timer? _timer;
  bool _due = false;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _timer?.cancel();
    super.dispose();
  }

  void _changed() {
    final unreachable = widget.controller.internetTransportsWorking == 0;
    if (!unreachable) {
      _timer?.cancel();
      _timer = null;
      if (_due && mounted) setState(() => _due = false);
      return;
    }
    if (_due || _timer != null) return;
    _timer = Timer(widget.grace, () {
      _timer = null;
      if (mounted && widget.controller.internetTransportsWorking == 0) {
        setState(() => _due = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_due || _dismissed) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final l10n = l10nOf(context);
    return Material(
      key: const ValueKey('internet-reach-banner'),
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.wifi_off, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.transportsBanner,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _dismissed = true),
              child: Text(l10n.transportsBannerDismiss),
            ),
            FilledButton.tonal(
              key: const ValueKey('internet-reach-set-up'),
              onPressed: widget.onSetUp,
              child: Text(l10n.transportsBannerAction),
            ),
          ],
        ),
      ),
    );
  }
}

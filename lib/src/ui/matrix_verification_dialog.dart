import 'dart:async';

import 'package:flutter/material.dart';

import '../matrix_service.dart';

/// Follows one interactive verification between two sessions of the same
/// Matrix account: waits for the other side, shows the seven emojis to
/// compare, and reports the result.
class MatrixVerificationDialog extends StatefulWidget {
  const MatrixVerificationDialog({
    super.key,
    required this.client,
    required this.userId,
    required this.flowId,
    required this.weStarted,
    this.startDelay = const Duration(seconds: 2),
    this.otherName,
  });

  /// Set when verifying another person (their name), rather than another
  /// session of this account.
  final String? otherName;

  final MatrixClientService client;
  final String userId;
  final String flowId;

  /// The side that requested verification starts the emoji comparison once
  /// the other side is ready.
  final bool weStarted;

  /// How long the requesting side waits for the other to start the emoji
  /// comparison before starting it.
  final Duration startDelay;

  @override
  State<MatrixVerificationDialog> createState() =>
      _MatrixVerificationDialogState();
}

class _MatrixVerificationDialogState extends State<MatrixVerificationDialog> {
  StreamSubscription<Map<String, dynamic>>? _events;
  List<({String symbol, String description})> _emojis = const [];
  late String _status = 'Waiting for $_other…';

  String get _other => widget.otherName ?? 'your other session';
  bool _finished = false;
  bool _busy = false;
  bool _confirmed = false;
  bool _comparisonStarted = false;

  @override
  void initState() {
    super.initState();
    _events = widget.client.verificationEvents.listen(_handle);
  }

  void _handle(Map<String, dynamic> event) {
    if (event['type'] != 'verification' || event['flowId'] != widget.flowId) {
      return;
    }
    switch (event['state']) {
      case 'ready':
        if (widget.weStarted) {
          setState(() => _status = 'Starting emoji comparison…');
          // Element may start the comparison itself; starting at the same
          // moment makes one side give way, so leave it a moment first.
          Timer(widget.startDelay, () {
            if (!mounted || _comparisonStarted || _finished) return;
            unawaited(
              widget.client
                  .startEmojiVerification(widget.userId, widget.flowId)
                  .catchError((Object error) => _fail('$error')),
            );
          });
        }
      case 'started':
        _comparisonStarted = true;
      case 'emojis':
        setState(() {
          _emojis = [
            for (final emoji in (event['emojis'] as List? ?? const []))
              if (emoji is Map)
                (
                  symbol: emoji['symbol'] as String? ?? '?',
                  description: emoji['description'] as String? ?? '',
                ),
          ];
          _status =
              'Do these emojis appear on the screen of $_other, in the '
              'same order?';
        });
      case 'done':
        setState(() {
          _finished = true;
          _emojis = const [];
          _status = widget.otherName == null
              ? 'Verified. This session can now read your encrypted '
                    'messages and is trusted by your other sessions.'
              : 'Verified. Your chats with ${widget.otherName} show as '
                    'verified, and a change of their keys will be flagged.';
        });
      case 'cancelled':
        _fail(event['reason'] as String? ?? 'Verification was cancelled.');
    }
  }

  void _fail(String reason) {
    if (!mounted) return;
    setState(() {
      _finished = true;
      _emojis = const [];
      _status = 'Not verified: $reason';
    });
  }

  Future<void> _answer({required bool match}) async {
    setState(() => _busy = true);
    try {
      await widget.client.confirmVerification(
        widget.userId,
        widget.flowId,
        match: match,
      );
      if (!match) _fail('the emojis did not match.');
      if (match && mounted) {
        // The other side may never confirm: Cancel stays available.
        setState(() {
          _confirmed = true;
          _status = 'Waiting for $_other to confirm…';
        });
      }
    } catch (error) {
      _fail('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    if (!_finished) {
      unawaited(
        widget.client
            .cancelVerification(widget.userId, widget.flowId)
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.otherName == null
            ? 'Verify this session'
            : 'Verify ${widget.otherName}',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_status),
          if (_emojis.isNotEmpty) ...[
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final emoji in _emojis)
                  SizedBox(
                    width: 64,
                    child: Column(
                      children: [
                        Text(
                          emoji.symbol,
                          style: const TextStyle(fontSize: 32),
                        ),
                        Text(
                          emoji.description,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
          if (!_finished && (_emojis.isEmpty || _confirmed)) ...[
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
          ],
        ],
      ),
      actions: [
        if (_emojis.isNotEmpty && !_finished && !_confirmed) ...[
          TextButton(
            onPressed: _busy ? null : () => _answer(match: false),
            child: const Text("They don't match"),
          ),
          FilledButton(
            onPressed: _busy ? null : () => _answer(match: true),
            child: const Text('They match'),
          ),
        ] else
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_finished ? 'Close' : 'Cancel'),
          ),
      ],
    );
  }
}

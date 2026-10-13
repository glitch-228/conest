import 'package:flutter/material.dart';

import '../messenger_controller.dart';
import '../models.dart';
import '../route_test.dart';

/// "Test Routes" in a contact's profile: times a probe out and back on each
/// route, and lists the answers.
class RouteTestPanel extends StatefulWidget {
  const RouteTestPanel({
    super.key,
    required this.controller,
    required this.contact,
  });

  final MessengerController controller;
  final ContactRecord contact;

  @override
  State<RouteTestPanel> createState() => _RouteTestPanelState();
}

class _RouteTestPanelState extends State<RouteTestPanel> {
  bool _running = false;
  String? _error;

  Future<void> _test() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      await widget.controller.testContactRoutes(widget.contact);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  static String describe(RouteTestResult result) {
    final roundTrip = result.roundTrip;
    if (roundTrip != null) {
      return '${result.label}: ${roundTrip.inMilliseconds} ms there and back';
    }
    if (result.stored) {
      return '${result.label}: left on the relay (answers once they fetch it)';
    }
    return '${result.label}: no answer';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final supported = widget.controller.canTestRoutes(widget.contact);
    final report = widget.controller.routeTestReportFor(
      widget.contact.deviceId,
    );
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const ValueKey('test-routes'),
            onPressed: !supported || _running ? null : _test,
            icon: _running
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.speed),
            label: Text(_running ? 'Testing routes…' : 'Test Routes'),
          ),
        ),
        if (!supported)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Route tests need a newer Conest on their side.',
              style: muted,
            ),
          ),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (report != null) ...[
          const SizedBox(height: 8),
          if (report.results.isEmpty)
            Text('No route took the test.', style: muted)
          else
            for (final result in report.results)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Icon(
                      result.answered
                          ? Icons.check_circle_outline
                          : result.stored
                          ? Icons.schedule
                          : Icons.highlight_off,
                      size: 16,
                      color: result.answered
                          ? Colors.green
                          : result.stored
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: Text(describe(result))),
                  ],
                ),
              ),
          const SizedBox(height: 4),
          Text(
            'Tested ${TimeOfDay.fromDateTime(report.measuredAt.toLocal()).format(context)}. '
            'Routes that answer go first for messages.',
            style: muted,
          ),
        ],
      ],
    );
  }
}

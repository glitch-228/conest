import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A reply gesture that moves a message temporarily without dismissing it.
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({
    super.key,
    required this.child,
    required this.onReply,
    required this.color,
    this.enabled = true,
  });
  final Widget child;
  final VoidCallback onReply;
  final Color color;
  final bool enabled;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> {
  double _distance = 0;
  bool _dragging = false;
  double get _direction =>
      Directionality.of(context) == TextDirection.rtl ? 1 : -1;

  void _finish({bool cancelled = false}) {
    final reply = !cancelled && widget.enabled && _distance >= 64;
    setState(() {
      _distance = 0;
      _dragging = false;
    });
    if (reply) {
      HapticFeedback.selectionClick();
      widget.onReply();
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onHorizontalDragStart: widget.enabled
        ? (_) => setState(() => _dragging = true)
        : null,
    onHorizontalDragUpdate: widget.enabled
        ? (event) => setState(() {
            _distance = (_distance + event.delta.dx * _direction).clamp(
              0.0,
              88.0,
            );
          })
        : null,
    onHorizontalDragEnd: widget.enabled ? (_) => _finish() : null,
    onHorizontalDragCancel: widget.enabled
        ? () => _finish(cancelled: true)
        : null,
    child: Stack(
      alignment: AlignmentDirectional.centerEnd,
      children: [
        if (_distance > 0)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 16),
            child: Opacity(
              opacity: (_distance / 64).clamp(0.0, 1.0),
              child: Icon(Icons.reply_rounded, color: widget.color),
            ),
          ),
        AnimatedContainer(
          duration: _dragging
              ? Duration.zero
              : const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(_distance * _direction, 0, 0),
          child: widget.child,
        ),
      ],
    ),
  );
}

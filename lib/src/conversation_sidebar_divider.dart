import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A desktop pane divider usable by pointer, keyboard and assistive technology.
class ConversationSidebarDivider extends StatefulWidget {
  const ConversationSidebarDivider({
    super.key,
    required this.onResize,
    required this.onReset,
    required this.color,
    this.onResizeEnd,
  });

  final ValueChanged<double> onResize;
  final VoidCallback onReset;
  final Color color;
  final VoidCallback? onResizeEnd;

  @override
  State<ConversationSidebarDivider> createState() =>
      _ConversationSidebarDividerState();
}

class _ConversationSidebarDividerState
    extends State<ConversationSidebarDivider> {
  final _focus = FocusNode(debugLabel: 'Conversation sidebar width');
  bool _focused = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Conversation sidebar width',
      hint: 'Drag to resize. Use arrow keys when focused. Double tap to reset.',
      onIncrease: () {
        widget.onResize(24);
        widget.onResizeEnd?.call();
      },
      onDecrease: () {
        widget.onResize(-24);
        widget.onResizeEnd?.call();
      },
      child: Focus(
        focusNode: _focus,
        onFocusChange: (value) => setState(() => _focused = value),
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final direction = Directionality.of(context) == TextDirection.rtl
              ? -1.0
              : 1.0;
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            widget.onResize(-24 * direction);
          } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            widget.onResize(24 * direction);
          } else if (event.logicalKey == LogicalKeyboardKey.home) {
            widget.onReset();
          } else {
            return KeyEventResult.ignored;
          }
          widget.onResizeEnd?.call();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _focus.requestFocus,
            onDoubleTap: widget.onReset,
            onHorizontalDragEnd: (_) => widget.onResizeEnd?.call(),
            onHorizontalDragCancel: () => widget.onResizeEnd?.call(),
            onHorizontalDragStart: (_) => _focus.requestFocus(),
            onHorizontalDragUpdate: (event) => widget.onResize(
              event.delta.dx *
                  (Directionality.of(context) == TextDirection.rtl ? -1 : 1),
            ),
            child: SizedBox(
              width: 8,
              height: double.infinity,
              child: Center(
                child: Container(width: _focused ? 3 : 1, color: widget.color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A row of chips that scrolls sideways on every platform: a mouse can drag
/// it, the vertical wheel scrolls it sideways, and desktop shows a thin
/// scrollbar. (Flutter's default scrolls a horizontal list with touch only,
/// and a wheel turn moves nothing.)
class HorizontalChipRow extends StatefulWidget {
  const HorizontalChipRow({
    super.key,
    required this.children,
    this.padding = EdgeInsets.zero,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  State<HorizontalChipRow> createState() => _HorizontalChipRowState();
}

class _HorizontalChipRowState extends State<HorizontalChipRow> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    final position = _controller.position;
    // A sideways wheel or Shift+wheel already scrolls the row itself.
    if (event.scrollDelta.dy == 0 || position.maxScrollExtent <= 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final scroll = event as PointerScrollEvent;
      _controller.jumpTo(
        (position.pixels + scroll.scrollDelta.dy).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    final desktop = switch (Theme.of(context).platform) {
      TargetPlatform.linux ||
      TargetPlatform.windows ||
      TargetPlatform.macOS => true,
      _ => false,
    };
    Widget row = SingleChildScrollView(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      padding: widget.padding,
      child: Row(children: widget.children),
    );
    if (desktop) {
      row = Scrollbar(controller: _controller, thickness: 4, child: row);
    }
    return Listener(
      onPointerSignal: _wheel,
      child: ScrollConfiguration(
        behavior: behavior.copyWith(
          scrollbars: false,
          dragDevices: {...behavior.dragDevices, PointerDeviceKind.mouse},
        ),
        child: row,
      ),
    );
  }
}

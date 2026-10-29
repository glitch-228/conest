import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../conest_theme.dart';

/// Selectable text inside a chat bubble. Our own bubbles are filled with the
/// accent colour, which is also the selection colour, so the default
/// highlight is invisible on them: they get the bubble's text colour,
/// translucent, instead.
class BubbleSelectionArea extends StatelessWidget {
  const BubbleSelectionArea({
    super.key,
    required this.outbound,
    required this.palette,
    required this.child,
    this.onSelectionChanged,
    this.contextMenuBuilder,
  });

  final bool outbound;
  final ConestPalette palette;
  final Widget child;
  final ValueChanged<SelectedContent?>? onSelectionChanged;
  final SelectableRegionContextMenuBuilder? contextMenuBuilder;

  /// The highlight on an own bubble.
  static Color outboundSelectionColor(ConestPalette palette) =>
      palette.outboundText.withValues(alpha: 0.28);

  @override
  Widget build(BuildContext context) {
    return DefaultSelectionStyle.merge(
      selectionColor: outbound ? outboundSelectionColor(palette) : null,
      child: SelectionArea(
        onSelectionChanged: onSelectionChanged,
        contextMenuBuilder: contextMenuBuilder,
        child: child,
      ),
    );
  }
}

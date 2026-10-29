import 'package:conest/src/conest_theme.dart';
import 'package:conest/src/ui/bubble_selection_area.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Color _over(Color top, Color bottom) => Color.alphaBlend(top, bottom);

void main() {
  final palette = ConestPalette();

  Future<(RenderParagraph, List<String>)> pump(
    WidgetTester tester, {
    required bool outbound,
  }) async {
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Scaffold(
          body: Center(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: outbound ? palette.outboundBubbleGradient : null,
                color: outbound ? null : palette.inboundBubble,
              ),
              child: BubbleSelectionArea(
                outbound: outbound,
                palette: palette,
                onSelectionChanged: (content) =>
                    selected.add(content?.plainText ?? ''),
                child: const Text('pick this word'),
              ),
            ),
          ),
        ),
      ),
    );
    return (
      tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text('pick this word'),
          matching: find.byType(RichText),
        ),
      ),
      selected,
    );
  }

  testWidgets('an own bubble can be selected by dragging with the mouse', (
    tester,
  ) async {
    final (_, selected) = await pump(tester, outbound: true);
    final rect = tester.getRect(find.text('pick this word'));
    final gesture = await tester.startGesture(
      Offset(rect.left + 1, rect.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(Offset(rect.left + 30, rect.center.dy));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(selected, isNotEmpty);
    expect(selected.last, isNotEmpty);
  });

  testWidgets('the highlight on an own bubble shows against its fill', (
    tester,
  ) async {
    final (paragraph, _) = await pump(tester, outbound: true);
    final highlight = paragraph.selectionColor!;
    for (final fill in [palette.outboundBubble, palette.outboundBubbleEnd]) {
      final shown = _over(highlight, fill);
      // Visibly different from the bubble itself.
      final difference = (shown.computeLuminance() - fill.computeLuminance())
          .abs();
      expect(difference, greaterThan(0.1));
    }
  });

  testWidgets('a received bubble keeps the theme highlight', (tester) async {
    final (paragraph, _) = await pump(tester, outbound: false);
    expect(
      paragraph.selectionColor,
      isNot(BubbleSelectionArea.outboundSelectionColor(palette)),
    );
  });
}

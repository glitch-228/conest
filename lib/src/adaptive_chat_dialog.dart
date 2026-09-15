import 'package:flutter/material.dart';

/// Dialog on desktop, full-screen editing page on narrow Courier layouts.
/// The content keeps ownership of its scrolling and form controllers.
class AdaptiveChatDialog extends StatelessWidget {
  const AdaptiveChatDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
    this.scrollable = false,
    this.insetPadding = const EdgeInsets.symmetric(
      horizontal: 40,
      vertical: 24,
    ),
    this.fullscreenOnMobile = false,
  });
  final Widget title;
  final Widget content;
  final List<Widget> actions;
  final bool scrollable;
  final EdgeInsets insetPadding;
  final bool fullscreenOnMobile;

  @override
  Widget build(BuildContext context) {
    if (!fullscreenOnMobile || MediaQuery.sizeOf(context).width >= 700) {
      return AlertDialog(
        title: title,
        content: content,
        actions: actions,
        scrollable: scrollable,
        insetPadding: insetPadding,
      );
    }
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: title,
          leading: IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: SizedBox(width: double.infinity, child: content),
                ),
              ),
              if (actions.isNotEmpty) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: OverflowBar(
                    alignment: MainAxisAlignment.end,
                    spacing: 8,
                    overflowSpacing: 4,
                    children: actions,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

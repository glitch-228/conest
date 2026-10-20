import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Ctrl+V (Cmd+V) in an open chat pastes into it ([onPaste]) wherever the
/// focus is, unless a text field has it: that field pastes as usual.
class ChatPasteScope extends StatelessWidget {
  const ChatPasteScope({
    super.key,
    required this.active,
    required this.onPaste,
    required this.child,
  });

  /// Whether a chat is open.
  final bool Function() active;
  final VoidCallback onPaste;
  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const <ShortcutActivator, Intent>{
      SingleActivator(LogicalKeyboardKey.keyV, control: true):
          _ChatPasteIntent(),
      SingleActivator(LogicalKeyboardKey.keyV, meta: true): _ChatPasteIntent(),
    },
    child: Actions(
      actions: <Type, Action<Intent>>{
        _ChatPasteIntent: _ChatPasteAction(active, onPaste),
      },
      child: child,
    ),
  );
}

class _ChatPasteIntent extends Intent {
  const _ChatPasteIntent();
}

class _ChatPasteAction extends Action<_ChatPasteIntent> {
  _ChatPasteAction(this.active, this.onPaste);

  final bool Function() active;
  final VoidCallback onPaste;

  @override
  bool isEnabled(_ChatPasteIntent intent) {
    if (!active()) return false;
    // Disabled: the key goes on to the focused text field's own paste.
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused == null ||
        (focused.widget is! EditableText &&
            focused.findAncestorStateOfType<EditableTextState>() == null);
  }

  @override
  Object? invoke(_ChatPasteIntent intent) {
    onPaste();
    return null;
  }
}

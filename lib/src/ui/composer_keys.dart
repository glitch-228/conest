import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'link_cleaning.dart';

/// Whether Enter sends messages, for every message box below it.
class ComposerSettings extends InheritedWidget {
  const ComposerSettings({
    super.key,
    required this.enterSends,
    required super.child,
  });

  final bool enterSends;

  /// The setting above [context]; without one, Enter sends on desktops.
  static bool enterSendsOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ComposerSettings>()
          ?.enterSends ??
      switch (defaultTargetPlatform) {
        TargetPlatform.windows ||
        TargetPlatform.linux ||
        TargetPlatform.macOS => true,
        _ => false,
      };

  @override
  bool updateShouldNotify(ComposerSettings oldWidget) =>
      enterSends != oldWidget.enterSends;
}

/// The send keys of a message box: with Enter sending, Enter sends (and
/// Shift+Enter, left alone, starts a new line); without, Enter starts a
/// new line. Ctrl+Enter (Cmd+Enter) sends either way.
Map<ShortcutActivator, Intent> composerSendShortcuts(BuildContext context) => {
  if (ComposerSettings.enterSendsOf(context)) ...{
    const SingleActivator(LogicalKeyboardKey.enter): const _SendIntent(),
    const SingleActivator(LogicalKeyboardKey.numpadEnter): const _SendIntent(),
  },
  const SingleActivator(LogicalKeyboardKey.enter, control: true):
      const _SendIntent(),
  const SingleActivator(LogicalKeyboardKey.enter, meta: true):
      const _SendIntent(),
};

/// What the [composerSendShortcuts] do: [onSend], unless an input method
/// is still composing in [controller] (Enter is then its own).
Map<Type, Action<Intent>> composerSendActions(
  TextEditingController controller,
  VoidCallback onSend,
) => {_SendIntent: _SendAction(controller, onSend)};

/// A message box ([child], editing [controller]) with the send keys, and
/// its links cleaned as they are written ([LinkCleanedNote]).
class ComposerKeys extends StatelessWidget {
  const ComposerKeys({
    super.key,
    required this.controller,
    required this.onSend,
    required this.child,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      LinkCleanedNote(controller: controller),
      Shortcuts(
        shortcuts: composerSendShortcuts(context),
        child: Actions(
          actions: composerSendActions(controller, onSend),
          child: child,
        ),
      ),
    ],
  );
}

class _SendIntent extends Intent {
  const _SendIntent();
}

class _SendAction extends Action<_SendIntent> {
  _SendAction(this.controller, this.onSend);

  final TextEditingController controller;
  final VoidCallback onSend;

  // Disabled while composing: the key goes on to the input method.
  @override
  bool isEnabled(_SendIntent intent) => !controller.value.composing.isValid;

  @override
  Object? invoke(_SendIntent intent) {
    onSend();
    return null;
  }
}

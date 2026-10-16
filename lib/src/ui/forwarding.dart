import 'package:flutter/widgets.dart';

/// Set by the app: forwards text from a network chat (Matrix, Delta Chat,
/// …) into a Conest chat, group or Saved messages. Null where the app has
/// not set it (screens then offer no Forward).
Future<void> Function(BuildContext context, String text)? forwardTextToConest;

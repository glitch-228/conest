import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../app_locales.dart';

/// A link found in a message: where it is in the text, and what it opens.
typedef FoundLink = ({int start, int end, Uri uri});

final _linkPattern = RegExp(
  r'(?:https?://|mailto:|www\.)[^\s<>"]+',
  caseSensitive: false,
);

/// Characters a link does not end with ("see https://a.example/x.").
const _trailing = '.,;:!?\'"*';

/// The links in [text]: http(s) and mailto, and `www.` addresses (opened
/// over https). Punctuation after a link, and a closing bracket it did not
/// open, are left out.
List<FoundLink> findLinks(String text) {
  final links = <FoundLink>[];
  for (final match in _linkPattern.allMatches(text)) {
    final start = match.start;
    // Part of a longer word ("xwww.example"): not a link.
    if (start > 0 && RegExp(r'[\w@./]').hasMatch(text[start - 1])) continue;
    var end = match.end;
    while (end > start) {
      final last = text[end - 1];
      final candidate = text.substring(start, end);
      if (_trailing.contains(last)) {
        end--;
      } else if (_closesUnopened(candidate, last)) {
        end--;
      } else {
        break;
      }
    }
    var raw = text.substring(start, end);
    if (raw.toLowerCase().startsWith('www.')) raw = 'https://$raw';
    final uri = Uri.tryParse(raw);
    if (uri == null) continue;
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'mailto') {
      if (uri.path.contains('@')) links.add((start: start, end: end, uri: uri));
    } else if ((scheme == 'http' || scheme == 'https') &&
        uri.host.contains('.') &&
        !uri.host.endsWith('.')) {
      links.add((start: start, end: end, uri: uri));
    }
  }
  return links;
}

bool _closesUnopened(String text, String last) {
  const pairs = {')': '(', ']': '[', '}': '{'};
  final open = pairs[last];
  if (open == null) return false;
  return last.allMatches(text).length > open.allMatches(text).length;
}

/// Whether [uri]'s host has letters outside ASCII (Dart keeps them
/// percent-encoded): it may be made to look like another site, so opening
/// it asks first.
bool hasLookalikeHost(Uri uri) =>
    uri.host.contains('%') || uri.host.runes.any((rune) => rune > 0x7f);

String _readableHost(Uri uri) {
  try {
    return Uri.decodeComponent(uri.host);
  } catch (_) {
    return uri.host;
  }
}

/// Opens [uri] with [openUrl] (the system browser), asking first when its
/// host has letters outside ASCII.
Future<void> openMessageLink(
  BuildContext context,
  Future<void> Function(Uri uri) openUrl,
  Uri uri,
) async {
  if (hasLookalikeHost(uri)) {
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).linkLookalikeTitle),
        content: Text(l10nOf(context).linkLookalikeBody(_readableHost(uri))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            key: const ValueKey('open-lookalike-link'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10nOf(context).linkOpen),
          ),
        ],
      ),
    );
    if (open != true) return;
  }
  try {
    await openUrl(uri);
  } catch (error) {
    debugPrint('Opening a link failed: $error');
  }
}

/// [text] with its links underlined and opening on a tap or click (inside a
/// [SelectionArea], the text stays selectable). A press that starts and
/// ends on a link opens it at once: it is read from the pointer itself, so
/// a message's own taps, double taps and text selection do not hold it up.
class LinkedText extends StatefulWidget {
  const LinkedText(
    this.text, {
    super.key,
    required this.openUrl,
    this.style,
    this.linkColor,
  });

  final String text;

  /// Opens a link (the system browser).
  final Future<void> Function(Uri uri) openUrl;
  final TextStyle? style;

  /// The links' colour; the theme's primary colour when null.
  final Color? linkColor;

  @override
  State<LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<LinkedText> {
  final _textKey = GlobalKey();
  FoundLink? _pressed;
  Offset _pressedAt = Offset.zero;
  (FoundLink, DateTime)? _lastOpened;

  /// The link under [position] (global), if the pointer is on its text.
  FoundLink? _linkAt(Offset position, List<FoundLink> links) {
    final paragraph = _paragraphIn(_textKey.currentContext?.findRenderObject());
    if (paragraph == null || !paragraph.attached) return null;
    final local = paragraph.globalToLocal(position);
    final offset = paragraph.getPositionForOffset(local).offset;
    for (final link in links) {
      if (offset < link.start || offset > link.end) continue;
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: link.start, extentOffset: link.end),
      );
      if (boxes.any((box) => box.toRect().inflate(2).contains(local))) {
        return link;
      }
    }
    return null;
  }

  /// The text's paragraph (under a [SelectionArea] it sits inside a mouse
  /// region).
  static RenderParagraph? _paragraphIn(RenderObject? root) {
    if (root == null || root is RenderParagraph) {
      return root as RenderParagraph?;
    }
    RenderParagraph? found;
    root.visitChildren((child) => found ??= _paragraphIn(child));
    return found;
  }

  void _open(FoundLink link) {
    final now = DateTime.now();
    // A double click is one opening.
    if (_lastOpened case (
      final last,
      final at,
    ) when last == link && now.difference(at) < const Duration(seconds: 1)) {
      return;
    }
    _lastOpened = (link, now);
    unawaited(openMessageLink(context, widget.openUrl, link.uri));
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final links = findLinks(text);
    if (links.isEmpty) return Text(text, style: widget.style);
    final linkStyle = TextStyle(
      color: widget.linkColor ?? Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    final spans = <InlineSpan>[];
    var at = 0;
    for (final link in links) {
      if (link.start > at) {
        spans.add(TextSpan(text: text.substring(at, link.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(link.start, link.end),
          style: linkStyle,
          mouseCursor: SystemMouseCursors.click,
        ),
      );
      at = link.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Listener(
      onPointerDown: (event) {
        _pressed = event.buttons == kPrimaryButton
            ? _linkAt(event.position, links)
            : null;
        _pressedAt = event.position;
      },
      onPointerUp: (event) {
        final link = _pressed;
        _pressed = null;
        // A drag (selecting text) opens nothing.
        if (link == null ||
            (event.position - _pressedAt).distance > 8 ||
            _linkAt(event.position, links) != link) {
          return;
        }
        _open(link);
      },
      onPointerCancel: (_) => _pressed = null,
      child: Text.rich(
        TextSpan(children: spans),
        key: _textKey,
        style: widget.style,
      ),
    );
  }
}

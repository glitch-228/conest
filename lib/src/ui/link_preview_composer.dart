import 'dart:async';

import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../links/link_preview_data.dart';
import 'link_preview_card.dart';
import 'linked_text.dart';

final _attached = Expando<_LinkPreviewComposerState>('link preview');

/// The preview that goes with the text in [controller] when it is sent, if
/// this device sends previews ([LinkPreviewComposer]): one for the text's
/// first link, not removed.
LinkPreview? composerLinkPreview(TextEditingController controller) =>
    _attached[controller]?._current;

/// Above a message box, when this device sends previews with its messages
/// ([LinkPreviewSource.linkPreviewsAttached]): the preview of the first
/// link written, fetched here, which goes with the message unless removed.
class LinkPreviewComposer extends StatefulWidget {
  const LinkPreviewComposer({
    super.key,
    required this.controller,
    required this.source,
    required this.accent,
  });

  final TextEditingController controller;
  final LinkPreviewSource source;
  final Color accent;

  @override
  State<LinkPreviewComposer> createState() => _LinkPreviewComposerState();
}

class _LinkPreviewComposerState extends State<LinkPreviewComposer> {
  Uri? _link;
  LinkPreview? _preview;
  final _removed = <Uri>{};
  Timer? _debounce;

  /// The preview to send now: for the text's first link, not removed.
  LinkPreview? get _current {
    final preview = _preview;
    final link = _link;
    if (preview == null || link == null || _removed.contains(link)) return null;
    return _firstWebLink(widget.controller.text) == link ? preview : null;
  }

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _attached[widget.controller] = this;
    widget.controller.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(LinkPreviewComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      if (identical(_attached[oldWidget.controller], this)) {
        _attached[oldWidget.controller] = null;
      }
      _attach();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_changed);
    if (identical(_attached[widget.controller], this)) {
      _attached[widget.controller] = null;
    }
    super.dispose();
  }

  static Uri? _firstWebLink(String text) {
    for (final link in findLinks(text)) {
      if (link.uri.scheme == 'https' || link.uri.scheme == 'http') {
        return link.uri;
      }
    }
    return null;
  }

  void _changed() {
    if (!widget.source.linkPreviewsAttached) return;
    final link = _firstWebLink(widget.controller.text);
    if (link == _link) return;
    _debounce?.cancel();
    _link = link;
    _preview = null;
    if (mounted) setState(() {});
    if (link == null || _removed.contains(link)) return;
    // Once the link has been still for a moment (not every keystroke).
    _debounce = Timer(const Duration(milliseconds: 700), () async {
      final cached = widget.source.cachedLinkPreview(link);
      final preview = cached ?? await widget.source.loadLinkPreview(link);
      if (!mounted || _link != link) return;
      setState(() => _preview = preview);
    });
  }

  @override
  Widget build(BuildContext context) {
    final preview = _current;
    if (preview == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        key: const ValueKey('composer-link-preview'),
        children: [
          Container(width: 3, height: 36, color: widget.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  preview.siteName ?? preview.url.host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: widget.accent,
                  ),
                ),
                Text(
                  preview.title ?? preview.description ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (preview.image case final image?)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.memory(
                  image,
                  width: 36,
                  height: 36,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          IconButton(
            key: const ValueKey('composer-link-preview-remove'),
            tooltip: l10nOf(context).linkPreviewRemove,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _removed.add(_link!)),
          ),
        ],
      ),
    );
  }
}

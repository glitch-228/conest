import 'dart:async';

import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../links/link_preview.dart';
import '../messenger_controller.dart';
import 'linked_text.dart';

/// Where a [LinkPreviewCard] gets previews (the messenger controller).
abstract interface class LinkPreviewSource {
  bool get linkPreviewsEnabled;

  /// Whether this device fetches previews of links it gets (not only shows
  /// those their senders attached).
  bool get linkPreviewsFetchedHere;

  /// Whether this device sends previews with its messages.
  bool get linkPreviewsAttached;

  /// Whether a preview may be fetched now without being asked.
  bool get linkPreviewsAutomaticNow;

  LinkPreview? cachedLinkPreview(Uri url);
  Future<LinkPreview?> loadLinkPreview(Uri url);
}

/// The preview of the first link in [text], under a message: the site, the
/// title, two lines of description and a thumbnail; a tap opens the link.
/// From a [trusted] sender an https link's preview is fetched by itself
/// (when [LinkPreviewSource.linkPreviewsAutomaticNow]); otherwise a "Show
/// link preview" button asks first, as the fetch shows the site this
/// device's address.
class LinkPreviewCard extends StatefulWidget {
  const LinkPreviewCard({
    super.key,
    required this.text,
    required this.source,
    required this.trusted,
    required this.openUrl,
    required this.accent,
    required this.textColor,
    this.attached,
  });

  final String text;

  /// The preview its sender sent with the message (checked when it came):
  /// shown as it is, nothing fetched.
  final LinkPreview? attached;
  final LinkPreviewSource source;
  final bool trusted;
  final Future<void> Function(Uri uri) openUrl;
  final Color accent;
  final Color textColor;

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  Uri? _link;
  LinkPreview? _preview;
  bool _loading = false;
  bool _tried = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(LinkPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.attached != widget.attached) {
      _preview = null;
      _tried = false;
      _start();
    }
  }

  void _start() {
    _link = _firstWebLink(widget.text);
    final link = _link;
    if (link == null || !widget.source.linkPreviewsEnabled) return;
    if (widget.attached case final attached?) {
      _preview = attached;
      return;
    }
    if (!widget.source.linkPreviewsFetchedHere) return;
    _preview = widget.source.cachedLinkPreview(link);
    if (_preview == null && _automatic) unawaited(_load());
  }

  /// Fetched without a tap: in a trusted chat, when previews may come by
  /// themselves now, and only over https (the address of a plain http link
  /// would be seen on the way).
  bool get _automatic =>
      widget.trusted &&
      widget.source.linkPreviewsAutomaticNow &&
      _link?.scheme == 'https';

  static Uri? _firstWebLink(String text) {
    for (final link in findLinks(text)) {
      if (link.uri.scheme == 'https' || link.uri.scheme == 'http') {
        return link.uri;
      }
    }
    return null;
  }

  Future<void> _load() async {
    final link = _link;
    if (link == null || _loading) return;
    setState(() => _loading = true);
    LinkPreview? preview;
    try {
      preview = await widget.source.loadLinkPreview(link);
    } catch (_) {
      preview = null;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _tried = true;
      _preview = preview;
    });
  }

  @override
  Widget build(BuildContext context) {
    final link = _link;
    if (link == null || !widget.source.linkPreviewsEnabled) {
      return const SizedBox.shrink();
    }
    final preview = _preview;
    final theme = Theme.of(context);
    if (preview == null) {
      if (_tried || _automatic || !widget.source.linkPreviewsFetchedHere) {
        // Nothing to show (or on its way): no space taken.
        return const SizedBox.shrink();
      }
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          key: const ValueKey('link-preview-load'),
          onPressed: _loading ? null : _load,
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            foregroundColor: widget.accent,
          ),
          icon: const Icon(Icons.preview_outlined, size: 16),
          label: Text(l10nOf(context).linkPreviewShow),
        ),
      );
    }
    final muted = widget.textColor.withValues(alpha: 0.72);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        key: const ValueKey('link-preview-card'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => openMessageLink(context, widget.openUrl, link),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 6, 6),
            decoration: BoxDecoration(
              border: BorderDirectional(
                start: BorderSide(color: widget.accent, width: 3),
              ),
              color: widget.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if ((preview.siteName ?? '').isNotEmpty)
                        Text(
                          preview.siteName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: widget.accent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if ((preview.title ?? '').isNotEmpty)
                        Text(
                          preview.title!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: widget.textColor,
                          ),
                        ),
                      if ((preview.description ?? '').isNotEmpty)
                        Text(
                          preview.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                    ],
                  ),
                ),
                if (preview.image case final image?) ...[
                  const SizedBox(width: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(
                      image,
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The messenger's previews, for [LinkPreviewCard].
class MessengerLinkPreviews implements LinkPreviewSource {
  const MessengerLinkPreviews(this.controller);

  final MessengerController controller;

  @override
  bool get linkPreviewsEnabled => controller.linkPreviewsEnabled;

  @override
  bool get linkPreviewsAutomaticNow => controller.linkPreviewsAutomaticNow;

  @override
  bool get linkPreviewsFetchedHere => controller.linkPreviewsFetchedHere;

  @override
  bool get linkPreviewsAttached => controller.linkPreviewsAttached;

  @override
  LinkPreview? cachedLinkPreview(Uri url) => controller.cachedLinkPreview(url);

  @override
  Future<LinkPreview?> loadLinkPreview(Uri url) =>
      controller.loadLinkPreview(url);
}

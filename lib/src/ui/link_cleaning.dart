import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../links/link_cleaner.dart';
import 'linked_text.dart';

/// Where the link settings come from, for every message box and link
/// below it. Read when a link is cleaned or opened, so a change in Settings
/// applies at once without rebuilding.
class LinkSettings extends InheritedWidget {
  const LinkSettings({
    super.key,
    required this.policy,
    required this.onServiceFailed,
    required super.child,
  });

  final LinkPolicy Function() policy;

  /// An embed-fixing service ("twitter:1") did not work for a link.
  final void Function(String service) onServiceFailed;

  static LinkSettings? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<LinkSettings>();

  @override
  bool updateShouldNotify(LinkSettings oldWidget) => false;
}

final _cleanings = Expando<ComposerLinkCleaning>('link cleaning');

/// Cleans the links still in [controller] (as typed, not yet cleaned) just
/// before its text is sent.
void finishComposerLinks(TextEditingController controller) =>
    _cleanings[controller]?.cleanAll();

/// Cleans links in a message box as they are written: a pasted link at
/// once, a typed one when a space or new line follows it, and the rest
/// when the message is sent ([finishComposerLinks]). The last change can be
/// undone, and a link put back by Undo is not cleaned again.
class ComposerLinkCleaning extends ChangeNotifier {
  ComposerLinkCleaning(this.controller, this.policy, {LinkFilters? filters})
    : _filters = filters,
      _lastText = controller.text {
    controller.addListener(_changed);
    _cleanings[controller] = this;
  }

  final TextEditingController controller;
  LinkPolicy Function() policy;
  final LinkFilters? _filters;

  String _lastText;
  bool _applying = false;
  final Set<String> _exempt = {};
  List<LinkChange> _shown = const [];

  LinkFilters? get filters => _filters ?? LinkFilters.current;

  /// The links cleaned last, while they are still in the text.
  List<LinkChange> get shown => _shown;

  void _changed() {
    if (_applying) return;
    final value = controller.value;
    final text = value.text;
    final previous = _lastText;
    _lastText = text;
    _dropGoneChanges();
    if (value.composing.isValid || text.length <= previous.length) return;
    // What this edit inserted: text between the common start and end.
    var head = 0;
    while (head < previous.length && text[head] == previous[head]) {
      head++;
    }
    var tail = 0;
    while (tail < previous.length - head &&
        text[text.length - 1 - tail] == previous[previous.length - 1 - tail]) {
      tail++;
    }
    final end = text.length - tail;
    final inserted = text.substring(head, end);
    if (inserted.length > 1) {
      // A paste: the links it brought in.
      _clean((link) => link.end > head && link.start < end);
    } else if (inserted.trim().isEmpty && inserted.isNotEmpty) {
      // A space or new line typed right after a link ends it.
      _clean((link) => link.end == head);
    }
  }

  /// Cleans every link not cleaned yet, as the text is sent: also while an
  /// input method is still composing (the text goes as it is now).
  void cleanAll() => _clean(null, evenComposing: true);

  void _clean(
    bool Function(({int start, int end, Uri uri}) link)? include, {
    bool evenComposing = false,
  }) {
    final filters = this.filters;
    if (filters == null) return;
    final value = controller.value;
    if (value.composing.isValid && !evenComposing) return;
    final changes = filters.changesIn(
      value.text,
      policy(),
      include: include,
      exempt: _exempt,
    );
    if (changes.isEmpty) return;
    final text = applyLinkChanges(value.text, changes);
    var shift = 0;
    final placed = <LinkChange>[];
    for (final change in changes) {
      final start = change.start + shift;
      placed.add((
        start: start,
        end: start + change.cleaned.length,
        original: change.original,
        cleaned: change.cleaned,
      ));
      shift += change.cleaned.length - (change.end - change.start);
    }
    _replace(text, value.selection, changes);
    _shown = placed;
    notifyListeners();
  }

  /// Puts the last cleaned links back as they were written.
  void undo() {
    if (_shown.isEmpty) return;
    final value = controller.value;
    var text = value.text;
    final restored = <LinkChange>[];
    for (final change in _shown.reversed) {
      final at = _find(text, change);
      if (at < 0) continue;
      text = text.replaceRange(at, at + change.cleaned.length, change.original);
      restored.add((
        start: at,
        end: at + change.cleaned.length,
        original: change.cleaned,
        cleaned: change.original,
      ));
      _exempt.add(change.original);
    }
    _shown = const [];
    _replace(
      text,
      value.selection,
      restored..sort((a, b) => a.start.compareTo(b.start)),
    );
    notifyListeners();
  }

  int _find(String text, LinkChange change) {
    if (change.end <= text.length &&
        text.substring(change.start, change.end) == change.cleaned) {
      return change.start;
    }
    return text.indexOf(change.cleaned);
  }

  /// Sets [text], keeping the caret where it was relative to the text
  /// around the [changes] (positions in the old text).
  void _replace(
    String text,
    TextSelection selection,
    List<LinkChange> changes,
  ) {
    int moved(int offset) {
      var shift = 0;
      for (final change in changes) {
        if (offset >= change.end) {
          shift += change.cleaned.length - (change.end - change.start);
        } else if (offset > change.start) {
          // Inside a link that changed: to its end.
          return (change.start + shift + change.cleaned.length).clamp(
            0,
            text.length,
          );
        } else {
          break;
        }
      }
      return (offset + shift).clamp(0, text.length);
    }

    _applying = true;
    try {
      controller.value = TextEditingValue(
        text: text,
        selection: selection.isValid
            ? TextSelection(
                baseOffset: moved(selection.baseOffset),
                extentOffset: moved(selection.extentOffset),
              )
            : TextSelection.collapsed(offset: text.length),
      );
      _lastText = text;
    } finally {
      _applying = false;
    }
  }

  void _dropGoneChanges() {
    if (_shown.isEmpty) return;
    final text = controller.text;
    if (_shown.every((change) => !text.contains(change.cleaned))) {
      _shown = const [];
      notifyListeners();
    }
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    if (identical(_cleanings[controller], this)) _cleanings[controller] = null;
    super.dispose();
  }
}

/// Cleans links in the message box [controller] edits, and shows "Link
/// cleaned · Undo" above it after a link changed. Without [LinkSettings]
/// above it, links stay as written.
class LinkCleanedNote extends StatefulWidget {
  const LinkCleanedNote({super.key, required this.controller, this.filters});

  final TextEditingController controller;

  /// For tests: the lists to use instead of [LinkFilters.current].
  final LinkFilters? filters;

  @override
  State<LinkCleanedNote> createState() => _LinkCleanedNoteState();
}

class _LinkCleanedNoteState extends State<LinkCleanedNote> {
  ComposerLinkCleaning? _cleaning;

  LinkPolicy _policy() =>
      LinkSettings.maybeOf(context)?.policy() ?? LinkPolicy.off;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _cleaning = ComposerLinkCleaning(
      widget.controller,
      _policy,
      filters: widget.filters,
    )..addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(LinkCleanedNote oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.filters != widget.filters) {
      _cleaning?.dispose();
      _attach();
    }
  }

  @override
  void dispose() {
    _cleaning?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _cleaning?.shown ?? const [];
    if (shown.isEmpty) return const SizedBox.shrink();
    final l10n = l10nOf(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8, bottom: 2),
      child: Row(
        key: const ValueKey('link-cleaned-note'),
        children: [
          Icon(
            Icons.cleaning_services_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Tooltip(
              message: shown.map((change) => change.original).join('\n'),
              child: Text(
                l10n.linkCleaned,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('link-cleaned-undo'),
            onPressed: _cleaning?.undo,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(l10n.linkCleanedUndo),
          ),
        ],
      ),
    );
  }
}

/// The first link in [text] that goes through an embed-fixing service,
/// with its original; null when there is none (or the lists are not read).
({Uri original, String service})? embedFixedLinkIn(String text) {
  final fixers = LinkFilters.current?.embedFixers;
  if (fixers == null) return null;
  for (final link in findLinks(text)) {
    final service = fixers.serviceOf(link.uri);
    final original = fixers.originalOf(link.uri);
    if (service != null && original != null) {
      return (original: original, service: service);
    }
  }
  return null;
}

/// Opens the original of the embed-fixed link in [text]: what to do when
/// the service does not work, so it is skipped for a while (see
/// [LinkSettings.onServiceFailed]).
Future<void> openOriginalLink(
  BuildContext context,
  Future<void> Function(Uri uri) openUrl,
  String text,
) async {
  final found = embedFixedLinkIn(text);
  if (found == null) return;
  LinkSettings.maybeOf(context)?.onServiceFailed(found.service);
  await openMessageLink(context, openUrl, found.original);
}

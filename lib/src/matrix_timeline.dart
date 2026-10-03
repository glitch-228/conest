/// Turns raw Matrix room events into display items: edits replace the
/// original's content, reactions and redactions attach to their targets, and
/// events that could not be decrypted become placeholders.
library;

enum MatrixItemKind {
  text,
  notice,
  emote,
  image,
  file,
  audio,
  video,
  location,
  undecryptable,
  redacted,
  unsupported,
}

/// A message-like event as the UI shows it.
class MatrixTimelineItem {
  MatrixTimelineItem({
    required this.eventId,
    required this.sender,
    required this.timestamp,
    required this.kind,
    this.body = '',
    this.replyToEventId,
    this.media,
    this.mimeType,
    this.fileName,
    this.sizeBytes,
    this.edited = false,
  });

  final String eventId;
  final String sender;
  final DateTime timestamp;
  MatrixItemKind kind;
  String body;
  String? replyToEventId;

  /// The content's `url`/`file` pair, passed back to the native download.
  Map<String, dynamic>? media;
  String? mimeType;
  String? fileName;
  int? sizeBytes;
  bool edited;

  /// Server time of the edit currently shown; an older edit arriving later
  /// (history loads newest first) never overrides it.
  int _editedAtMs = -1;

  /// Reaction key → senders.
  final Map<String, Set<String>> reactions = {};
}

class MatrixTimeline {
  final List<MatrixTimelineItem> _items = [];
  final Map<String, MatrixTimelineItem> _byId = {};

  /// The event id of [sender]'s [key] reaction on [eventId], if any.
  String? reactionEventId(String eventId, String key, String sender) {
    for (final entry in _reactions.entries) {
      if (entry.value == (eventId, key, sender)) return entry.key;
    }
    return null;
  }

  /// Reaction event id → (target id, key, sender), so a redacted reaction can
  /// be removed again.
  final Map<String, (String, String, String)> _reactions = {};

  /// Edits, reactions and redactions whose target has not been seen yet
  /// (older history not loaded); applied when the target arrives.
  final Map<String, List<Map<String, dynamic>>> _orphans = {};
  final Set<String> _seen = {};

  /// Oldest first.
  List<MatrixTimelineItem> get items => List.unmodifiable(_items);

  MatrixTimelineItem? operator [](String eventId) => _byId[eventId];

  /// Adds newer events (sync) in order.
  void appendAll(Iterable<Map<String, dynamic>> events) {
    for (final event in events) {
      _add(event, older: false);
    }
  }

  /// Adds a page of older events, as `/messages` returns them (newest
  /// first).
  void prependPage(Iterable<Map<String, dynamic>> newestFirst) {
    for (final event in newestFirst) {
      _add(event, older: true);
    }
  }

  void _add(Map<String, dynamic> event, {required bool older}) {
    final eventId = event['event_id'];
    final type = event['type'];
    if (eventId is! String || type is! String || !_seen.add(eventId)) return;
    final content = event['content'];
    final relation = content is Map<String, dynamic>
        ? content['m.relates_to']
        : null;
    final relType = relation is Map<String, dynamic>
        ? relation['rel_type']
        : null;
    final target = relation is Map<String, dynamic>
        ? relation['event_id']
        : null;

    if (type == 'm.reaction' || type == 'm.room.redaction') {
      final targetId = type == 'm.room.redaction'
          ? (event['redacts'] ??
                (content is Map<String, dynamic> ? content['redacts'] : null))
          : target;
      if (targetId is String) _applyOrPark(targetId, event);
      return;
    }
    if (type == 'm.room.message' &&
        relType == 'm.replace' &&
        target is String) {
      _applyOrPark(target, event);
      return;
    }
    final item = _itemFor(event, eventId, type);
    if (item == null) return;
    _byId[eventId] = item;
    if (older) {
      _items.insert(0, item);
    } else {
      _items.add(item);
    }
    for (final pending in _orphans.remove(eventId) ?? const []) {
      _apply(item, pending);
    }
  }

  void _applyOrPark(String targetId, Map<String, dynamic> event) {
    final item = _byId[targetId];
    if (item != null) {
      _apply(item, event);
      return;
    }
    final reaction = _reactions[targetId];
    if (reaction != null && event['type'] == 'm.room.redaction') {
      final (itemId, key, sender) = reaction;
      _byId[itemId]?.reactions[key]?.remove(sender);
      _byId[itemId]?.reactions.removeWhere((_, senders) => senders.isEmpty);
      _reactions.remove(targetId);
      return;
    }
    _orphans.putIfAbsent(targetId, () => []).add(event);
  }

  void _apply(MatrixTimelineItem item, Map<String, dynamic> event) {
    final content = event['content'];
    switch (event['type']) {
      case 'm.reaction':
        final key = (content as Map?)?['m.relates_to']?['key'];
        final sender = event['sender'];
        final reactionId = event['event_id'];
        if (key is String && sender is String) {
          item.reactions.putIfAbsent(key, () => {}).add(sender);
          if (reactionId is String) {
            _reactions[reactionId] = (item.eventId, key, sender);
          }
        }
      case 'm.room.redaction':
        item
          ..kind = MatrixItemKind.redacted
          ..body = ''
          ..media = null
          ..replyToEventId = null;
        item.reactions.clear();
      case 'm.room.message':
        // Only the original sender may edit a message.
        if (event['sender'] != item.sender ||
            item.kind == MatrixItemKind.redacted) {
          return;
        }
        final replacement = (content as Map?)?['m.new_content'];
        final editedAt = event['origin_server_ts'];
        if (replacement is Map<String, dynamic> &&
            editedAt is int &&
            editedAt >= item._editedAtMs) {
          final reply = item.replyToEventId;
          _fill(item, replacement);
          item
            ..replyToEventId = reply
            ..edited = true
            .._editedAtMs = editedAt;
        }
    }
  }

  MatrixTimelineItem? _itemFor(
    Map<String, dynamic> event,
    String eventId,
    String type,
  ) {
    final sender = event['sender'];
    final ts = event['origin_server_ts'];
    if (sender is! String || ts is! int) return null;
    final item = MatrixTimelineItem(
      eventId: eventId,
      sender: sender,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
      kind: MatrixItemKind.unsupported,
    );
    final content = event['content'];
    if (type == 'm.room.encrypted') {
      item.kind = MatrixItemKind.undecryptable;
      return item;
    }
    if (type != 'm.room.message' && type != 'm.sticker') return null;
    if (content is! Map<String, dynamic> || content.isEmpty) {
      // A redacted message keeps its id but loses its content.
      item.kind = MatrixItemKind.redacted;
      return item;
    }
    _fill(item, content, sticker: type == 'm.sticker');
    final reply = content['m.relates_to']?['m.in_reply_to']?['event_id'];
    if (reply is String) item.replyToEventId = reply;
    return item;
  }

  void _fill(
    MatrixTimelineItem item,
    Map<String, dynamic> content, {
    bool sticker = false,
  }) {
    final body = content['body'];
    item.body = body is String ? _stripReplyFallback(body) : '';
    final msgtype = sticker ? 'm.image' : content['msgtype'];
    item.kind = switch (msgtype) {
      'm.text' => MatrixItemKind.text,
      'm.notice' => MatrixItemKind.notice,
      'm.emote' => MatrixItemKind.emote,
      'm.image' => MatrixItemKind.image,
      'm.file' => MatrixItemKind.file,
      'm.audio' => MatrixItemKind.audio,
      'm.video' => MatrixItemKind.video,
      'm.location' => MatrixItemKind.location,
      _ => MatrixItemKind.unsupported,
    };
    final url = content['url'];
    final file = content['file'];
    item.media = file is Map<String, dynamic>
        ? {'file': file}
        : url is String
        ? {'url': url}
        : null;
    final info = content['info'];
    if (info is Map<String, dynamic>) {
      item.mimeType = info['mimetype'] as String?;
      item.sizeBytes = (info['size'] as num?)?.toInt();
    }
    final fileName = content['filename'];
    item.fileName = fileName is String
        ? fileName
        : item.media != null
        ? item.body
        : null;
  }

  /// Replies quote the original as `> ...` lines followed by a blank line;
  /// the reply itself is shown separately.
  static String _stripReplyFallback(String body) {
    if (!body.startsWith('> ')) return body;
    final lines = body.split('\n');
    var index = 0;
    while (index < lines.length && lines[index].startsWith('>')) {
      index++;
    }
    if (index < lines.length && lines[index].isEmpty) index++;
    return lines.sublist(index).join('\n');
  }
}

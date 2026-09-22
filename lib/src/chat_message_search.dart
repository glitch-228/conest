import 'dart:async';

import 'package:flutter/material.dart';
import 'models.dart';

/// Searches messages already available to this conversation on this device.
class ChatMessageSearch extends StatefulWidget {
  const ChatMessageSearch({
    super.key,
    required this.messages,
    required this.changes,
    this.loadOlder,
    this.searchRemote,
  });
  final List<ChatMessage> Function() messages;
  final Listenable changes;
  final Future<void> Function()? loadOlder;
  final Future<List<ChatMessage>> Function(String query)? searchRemote;

  @override
  State<ChatMessageSearch> createState() => _ChatMessageSearchState();
}

class _ChatMessageSearchState extends State<ChatMessageSearch> {
  final _query = TextEditingController();
  bool _loading = false;
  bool _searching = false;
  String? _error;
  List<ChatMessage> _remoteMatches = const <ChatMessage>[];
  int _searchGeneration = 0;
  Timer? _searchDebounce;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() {});
    final query = value.trim();
    final search = widget.searchRemote;
    _searchDebounce?.cancel();
    if (search == null || query.length < 2) {
      _searchGeneration++;
      if (_remoteMatches.isNotEmpty || _searching) {
        setState(() {
          _remoteMatches = const <ChatMessage>[];
          _searching = false;
        });
      }
      return;
    }
    final generation = ++_searchGeneration;
    setState(() {
      _searching = true;
      _remoteMatches = const <ChatMessage>[];
    });
    _searchDebounce = Timer(const Duration(milliseconds: 180), () {
      unawaited(() async {
        try {
          final matches = await search(query);
          if (!mounted || generation != _searchGeneration) return;
          setState(() {
            _remoteMatches = matches;
            _searching = false;
          });
        } catch (_) {
          if (!mounted || generation != _searchGeneration) return;
          setState(() {
            _remoteMatches = const <ChatMessage>[];
            _searching = false;
          });
        }
      }());
    });
  }

  Widget _highlight(String value, String query, TextStyle? style) {
    if (query.isEmpty) {
      return Text(
        value,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    final lower = value.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (start < value.length) {
      final hit = lower.indexOf(query, start);
      if (hit < 0) {
        spans.add(TextSpan(text: value.substring(start)));
        break;
      }
      if (hit > start) spans.add(TextSpan(text: value.substring(start, hit)));
      spans.add(
        TextSpan(
          text: value.substring(hit, hit + query.length),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      );
      start = hit + query.length;
    }
    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _query,
                      autofocus: true,
                      onChanged: _onQueryChanged,
                      decoration: const InputDecoration(
                        hintText: 'Search messages',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close search',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: widget.changes,
                builder: (context, _) {
                  final query = _query.text.trim().toLowerCase();
                  final combined = <String, ChatMessage>{};
                  if (query.isNotEmpty) {
                    final terms = query
                        .split(RegExp(r'\s+'))
                        .where((term) => term.isNotEmpty)
                        .toList(growable: false);
                    for (final message in widget.messages()) {
                      final text = message.body.isEmpty
                          ? message.groupFile?.fileName ??
                                message.attachment?.fileName ??
                                ''
                          : message.body;
                      final lower = text.toLowerCase();
                      if (terms.every(lower.contains)) {
                        combined[message.id] = message;
                      }
                    }
                    for (final message in _remoteMatches) {
                      combined[message.id] = message;
                    }
                  }
                  final matches = combined.values.toList()
                    ..sort(
                      (left, right) =>
                          right.createdAt.compareTo(left.createdAt),
                    );
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          query.isEmpty
                              ? 'Search text or filenames on this device'
                              : _searching
                              ? 'Searching retained history…'
                              : '${matches.length} matching messages',
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: matches.length,
                          itemBuilder: (context, index) {
                            final message = matches[index];
                            return ListTile(
                              leading: Icon(
                                message.hasAttachment ||
                                        message.groupFile != null
                                    ? Icons.attach_file
                                    : Icons.chat_bubble_outline,
                              ),
                              title: _highlight(
                                message.body.isEmpty
                                    ? message.groupFile?.fileName ??
                                          message.attachment?.fileName ??
                                          ''
                                    : message.body,
                                query,
                                Theme.of(context).textTheme.bodyLarge,
                              ),
                              subtitle: Text(
                                message.createdAt.toLocal().toString(),
                              ),
                              onTap: () => Navigator.pop(context, message),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (_error != null) Text(_error!),
            if (widget.loadOlder != null)
              TextButton.icon(
                icon: const Icon(Icons.history),
                label: Text(
                  _loading ? 'Loading…' : 'Load older messages to search',
                ),
                onPressed: _loading
                    ? null
                    : () async {
                        setState(() {
                          _loading = true;
                          _error = null;
                        });
                        try {
                          await widget.loadOlder!();
                        } catch (_) {
                          if (mounted) _error = 'Could not load older messages';
                        } finally {
                          if (mounted) setState(() => _loading = false);
                        }
                      },
              ),
          ],
        ),
      ),
    ),
  );
}

/// Locates a lazily built, variable-height row by progressively seeking its
/// index. Each correction yields a frame; no history-wide widget build is needed.
Future<bool> revealChatMessage({
  required ScrollController scroll,
  required Map<String, GlobalKey> keys,
  required List<ChatMessage> messages,
  required String messageId,
  required bool Function() isCurrent,
}) async {
  final indices = {
    for (var i = 0; i < messages.length; i++)
      messages[i].id: messages.length - 1 - i,
  };
  final target = indices[messageId];
  if (target == null) return false;
  for (var attempt = 0; attempt < 48 && isCurrent(); attempt++) {
    if (!scroll.hasClients) return false;
    final context = keys[messageId]?.currentContext;
    if (context != null && context.mounted) {
      await Scrollable.ensureVisible(
        context,
        alignment: .5,
        duration: const Duration(milliseconds: 180),
      );
      return isCurrent();
    }
    final mountedRows = <int>[];
    for (final entry in keys.entries) {
      final index = indices[entry.key];
      if (index != null && entry.value.currentContext != null) {
        mountedRows.add(index);
      }
    }
    mountedRows.sort();
    final extent = scroll.position.maxScrollExtent;
    double next;
    if (mountedRows.isEmpty) {
      next = messages.length < 2 ? 0 : extent * target / (messages.length - 1);
    } else {
      final first = mountedRows.first;
      final last = mountedRows.last;
      final average = scroll.position.viewportDimension / (last - first + 1);
      final delta = target < first
          ? target - first
          : target > last
          ? target - last
          : target - (first + last) / 2;
      next = scroll.offset + delta * average.clamp(40.0, 240.0);
    }
    scroll.jumpTo(next.clamp(0.0, extent).toDouble());
    await WidgetsBinding.instance.endOfFrame;
  }
  return false;
}

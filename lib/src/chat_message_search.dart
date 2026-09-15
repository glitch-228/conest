import 'package:flutter/material.dart';
import 'models.dart';

/// Searches messages already available to this conversation on this device.
class ChatMessageSearch extends StatefulWidget {
  const ChatMessageSearch({
    super.key,
    required this.messages,
    required this.changes,
    this.loadOlder,
  });
  final List<ChatMessage> Function() messages;
  final Listenable changes;
  final Future<void> Function()? loadOlder;

  @override
  State<ChatMessageSearch> createState() => _ChatMessageSearchState();
}

class _ChatMessageSearchState extends State<ChatMessageSearch> {
  final _query = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
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
                      onChanged: (_) => setState(() {}),
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
                  final matches = query.isEmpty
                      ? <ChatMessage>[]
                      : widget
                            .messages()
                            .reversed
                            .where(
                              (message) =>
                                  message.body.toLowerCase().contains(query) ||
                                  (message.attachment?.fileName
                                          .toLowerCase()
                                          .contains(query) ??
                                      false),
                            )
                            .toList();
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          query.isEmpty
                              ? 'Search text or filenames on this device'
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
                                message.hasAttachment
                                    ? Icons.attach_file
                                    : Icons.chat_bubble_outline,
                              ),
                              title: Text(
                                message.body.isEmpty
                                    ? message.attachment?.fileName ?? ''
                                    : message.body,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
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

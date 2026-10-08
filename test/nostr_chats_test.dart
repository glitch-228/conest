import 'package:conest/src/nostr_chats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 8, 12);
  NostrChatMessage message(
    String id, {
    String author = 'b',
    int minute = 0,
    bool outgoing = false,
  }) => NostrChatMessage(
    id: id,
    author: author,
    text: 'text $id',
    at: start.add(Duration(minutes: minute)),
    outgoing: outgoing,
  );

  test('strangers cannot push out the user\'s own chats', () {
    var chats = const NostrChats().start(['bob']);
    chats = chats.add(['bob'], message('real'));
    // Many strangers, each with chats dated far ahead.
    for (var i = 0; i < 80; i++) {
      chats = chats.add([
        's$i',
      ], message('spam$i', author: 's$i', minute: 1000 + i));
    }
    expect(chats.chats['bob']!.messages.single.id, 'real');
    expect(
      chats.chats.values.where((chat) => !chat.kept),
      hasLength(NostrChats.maxRequests),
    );
    // A stranger's chat holds few messages until the user opens it.
    for (var i = 0; i < 80; i++) {
      chats = chats.add([
        's79',
      ], message('more$i', author: 's79', minute: 2000 + i));
    }
    expect(
      chats.chats['s79']!.messages,
      hasLength(NostrChats.maxMessagesPerRequest),
    );
    // Unread never counts more than is kept, and requests stay out of the
    // total.
    expect(
      chats.chats['s79']!.unread,
      lessThanOrEqualTo(NostrChats.maxMessagesPerRequest),
    );
    expect(chats.totalUnread, 1);
    // Reading alone does not keep a stranger's chat; replying does.
    chats = chats.markRead('s79');
    expect(chats.chats['s79']!.kept, isFalse);
    chats = chats.add([
      's79',
    ], message('reply', author: 'me', outgoing: true, minute: 3000));
    expect(chats.chats['s79']!.kept, isTrue);
  });

  test('a one-to-one chat takes no title from the other side', () {
    var chats = const NostrChats().add(
      ['bob'],
      message('1'),
      subject: 'Bob (verified)',
    );
    expect(chats.chats['bob']!.subject, isNull);
    chats = chats.add(['bob', 'carol'], message('2'), subject: 'Weekend');
    expect(chats.chats['bob,carol']!.subject, 'Weekend');
  });

  test('a deleted chat stays deleted when old messages come again', () {
    var chats = const NostrChats().add(['spam'], message('1', author: 'spam'));
    chats = chats.withoutChat('spam', start.add(const Duration(minutes: 5)));
    // Read again after a restart: still gone.
    final restored = NostrChats.fromJson(chats.toJson());
    expect(restored.add(['spam'], message('1', author: 'spam')).chats, isEmpty);
    // Starting it again does not bring the old messages back either.
    expect(
      restored
          .start(['spam'])
          .add(['spam'], message('1', author: 'spam'))
          .chats['spam']!
          .messages,
      isEmpty,
    );
    // Something new is a new chat.
    expect(
      restored
          .add(['spam'], message('2', author: 'spam', minute: 10))
          .chats
          .keys,
      ['spam'],
    );
  });

  test('relays from a pasted profile are kept with the chat', () {
    final chats = NostrChats.fromJson(
      const NostrChats()
          .start(
            ['bob'],
            relays: {
              'bob': [
                Uri.parse('wss://one.example'),
                Uri.parse('wss://two.example'),
                Uri.parse('wss://three.example'),
                Uri.parse('wss://four.example'),
              ],
            },
          )
          .toJson(),
    );
    expect(chats.hints['bob'], [
      'wss://one.example',
      'wss://two.example',
      'wss://three.example',
    ]);
  });
}

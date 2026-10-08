import 'package:conest/src/radio_chats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 8, 12);
  RadioChatMessage message(
    String id, {
    int minute = 0,
    bool outgoing = false,
  }) => RadioChatMessage(
    id: id,
    from: 'node',
    name: 'Node',
    text: 'text $id',
    at: start.add(Duration(minutes: minute)),
    outgoing: outgoing,
  );

  test('strangers fill the chats without breaking or pushing out ours', () {
    var chats = const RadioChats()
        .start(RadioChats.direct('friend'))
        .add(RadioChats.direct('friend'), message('hi', outgoing: true));
    // An empty chat the user opened, an empty one saved by an older
    // version (not marked as the user's), then many strangers.
    chats = chats.start(RadioChats.direct('empty'));
    chats = RadioChats(
      chats: {...chats.chats, RadioChats.direct('old'): const []},
      unread: chats.unread,
      kept: chats.kept,
    );
    for (var i = 0; i < RadioChats.maxChats + 20; i++) {
      chats = chats.add(RadioChats.direct('s$i'), message('m$i', minute: i));
    }
    // Still storing, and the user's chats are all there.
    chats = chats.add(RadioChats.direct('s0'), message('again', minute: 999));
    expect(chats.chats.containsKey(RadioChats.direct('friend')), isTrue);
    expect(chats.chats.containsKey(RadioChats.direct('empty')), isTrue);
    expect(
      chats.chats.keys.where((key) => !chats.kept.contains(key)),
      hasLength(RadioChats.maxChats),
    );
    final restored = RadioChats.fromJson(chats.toJson());
    expect(restored.kept, chats.kept);
  });

  test('a refused message is marked as not delivered', () {
    final chats = const RadioChats()
        .add(RadioChats.direct('n'), message('1', outgoing: true))
        .markDelivered(RadioChats.direct('n'), '1', failed: true);
    expect(
      chats.chats[RadioChats.direct('n')]!.single.state,
      RadioMessageState.failed,
    );
  });
}

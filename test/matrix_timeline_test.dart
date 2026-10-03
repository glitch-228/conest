import 'package:conest/src/matrix_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> message(
  String id,
  String body, {
  String sender = '@a:x',
  int ts = 1,
  Map<String, dynamic> extra = const {},
}) => {
  'event_id': id,
  'type': 'm.room.message',
  'sender': sender,
  'origin_server_ts': ts,
  'content': {'msgtype': 'm.text', 'body': body, ...extra},
};

Map<String, dynamic> edit(
  String id,
  String target,
  String body, {
  String sender = '@a:x',
  int ts = 5,
}) => {
  'event_id': id,
  'type': 'm.room.message',
  'sender': sender,
  'origin_server_ts': ts,
  'content': {
    'msgtype': 'm.text',
    'body': '* $body',
    'm.new_content': {'msgtype': 'm.text', 'body': body},
    'm.relates_to': {'rel_type': 'm.replace', 'event_id': target},
  },
};

Map<String, dynamic> reaction(
  String id,
  String target,
  String key, {
  String sender = '@b:x',
}) => {
  'event_id': id,
  'type': 'm.reaction',
  'sender': sender,
  'origin_server_ts': 9,
  'content': {
    'm.relates_to': {
      'rel_type': 'm.annotation',
      'event_id': target,
      'key': key,
    },
  },
};

Map<String, dynamic> redaction(String id, String target) => {
  'event_id': id,
  'type': 'm.room.redaction',
  'sender': '@a:x',
  'origin_server_ts': 10,
  'redacts': target,
  'content': <String, dynamic>{},
};

void main() {
  test('edits replace content, keep the reply and ignore other senders', () {
    final timeline = MatrixTimeline()
      ..appendAll([
        message(
          '\$1',
          '> <@b:x> original\n\nhello',
          extra: {
            'm.relates_to': {
              'm.in_reply_to': {'event_id': '\$0'},
            },
          },
        ),
        edit('\$2', '\$1', 'hello there'),
        edit('\$3', '\$1', 'hijacked', sender: '@evil:x', ts: 6),
      ]);
    final item = timeline.items.single;
    expect(item.body, 'hello there');
    expect(item.edited, isTrue);
    expect(item.replyToEventId, '\$0');
  });

  test('history loaded newest first keeps the newest edit', () {
    final timeline = MatrixTimeline()
      ..prependPage([
        edit('\$3', '\$1', 'second edit', ts: 7),
        edit('\$2', '\$1', 'first edit', ts: 5),
        message('\$1', 'original'),
      ]);
    expect(timeline.items.single.body, 'second edit');
  });

  test('reactions attach and a redacted reaction is removed', () {
    final timeline = MatrixTimeline()
      ..appendAll([
        message('\$1', 'hi'),
        reaction('\$r1', '\$1', '👍'),
        reaction('\$r2', '\$1', '👍', sender: '@c:x'),
      ]);
    expect(timeline['\$1']!.reactions['👍'], {'@b:x', '@c:x'});
    timeline.appendAll([redaction('\$x', '\$r1')]);
    expect(timeline['\$1']!.reactions['👍'], {'@c:x'});
  });

  test('a redacted message loses its content and reactions', () {
    final timeline = MatrixTimeline()
      ..appendAll([
        message('\$1', 'secret'),
        reaction('\$r', '\$1', '❤'),
        redaction('\$x', '\$1'),
      ]);
    final item = timeline['\$1']!;
    expect(item.kind, MatrixItemKind.redacted);
    expect(item.body, isEmpty);
    expect(item.reactions, isEmpty);
  });

  test('media and undecryptable events become items', () {
    final timeline = MatrixTimeline()
      ..appendAll([
        {
          'event_id': '\$img',
          'type': 'm.room.message',
          'sender': '@a:x',
          'origin_server_ts': 1,
          'content': {
            'msgtype': 'm.image',
            'body': 'cat.png',
            'file': {'url': 'mxc://x/abc', 'v': 'v2'},
            'info': {'mimetype': 'image/png', 'size': 123},
          },
        },
        {
          'event_id': '\$enc',
          'type': 'm.room.encrypted',
          'sender': '@a:x',
          'origin_server_ts': 2,
          'content': {'algorithm': 'm.megolm.v1.aes-sha2'},
        },
        {
          'event_id': '\$state',
          'type': 'm.room.member',
          'sender': '@a:x',
          'origin_server_ts': 3,
          'content': {'membership': 'join'},
        },
      ]);
    expect(timeline.items.map((item) => item.kind), [
      MatrixItemKind.image,
      MatrixItemKind.undecryptable,
    ]);
    final image = timeline['\$img']!;
    expect(image.media, {
      'file': {'url': 'mxc://x/abc', 'v': 'v2'},
    });
    expect(image.mimeType, 'image/png');
    expect(image.sizeBytes, 123);
    expect(image.fileName, 'cat.png');
  });

  test('duplicates are ignored and order is kept', () {
    final timeline = MatrixTimeline()
      ..appendAll([message('\$2', 'b', ts: 2)])
      ..prependPage([message('\$1', 'a')])
      ..appendAll([message('\$2', 'b', ts: 2), message('\$3', 'c', ts: 3)]);
    expect(timeline.items.map((item) => item.body), ['a', 'b', 'c']);
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/delta_chats.dart';
import 'package:conest/src/delta_protocol.dart';
import 'package:conest/src/email/delta_cache.dart';
import 'package:conest/src/email/delta_content.dart';
import 'package:conest/src/email/delta_mail.dart';
import 'package:conest/src/email/mime.dart';
import 'package:conest/src/email/openpgp.dart';
import 'package:conest/src/email/pgp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test(
    'Delta cache cap evicts least recently used and restores metadata order',
    () async {
      final dir = await Directory.systemTemp.createTemp('delta-lru');
      addTearDown(() => dir.delete(recursive: true));
      final evicted = <String>[];
      final cache = DeltaAttachmentCache(
        dir,
        maxBytes: 12,
        maxFiles: 3,
        onEvicted: evicted.add,
      );
      final now = DateTime.utc(2026, 10, 31);
      for (final name in ['a', 'b']) {
        await cache.reserve(name, 4, {});
        await File('${dir.path}/$name').writeAsBytes([1, 2, 3, 4]);
        await cache.record(name, 4, now);
      }
      await cache.touch('a', now.add(const Duration(seconds: 1)));
      final restored = DeltaAttachmentCache(
        dir,
        maxBytes: 12,
        onEvicted: evicted.add,
      );
      await restored.load(['a', 'b']);
      await restored.reserve('c', 8, {});
      await File('${dir.path}/c').writeAsBytes(List.filled(8, 9));
      await restored.record('c', 8, now.add(const Duration(seconds: 2)));
      expect(evicted, ['b']);
      expect(await File('${dir.path}/a').exists(), isTrue);
      expect(await File('${dir.path}/b').exists(), isFalse);
      expect(restored.sizeBytes, 12);
      await expectLater(
        restored.reserve('d', 13, {}),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        restored.reserve('d', 8, {'a', 'c'}),
        throwsA(isA<FileSystemException>()),
      );
      expect(restored.sizeBytes, 12);
    },
  );

  test(
    'Delta legacy pinned caches remain readable while new admissions obey the cap',
    () async {
      final dir = await Directory.systemTemp.createTemp('delta-pinned');
      addTearDown(() => dir.delete(recursive: true));
      for (final name in ['a', 'b']) {
        await File('${dir.path}/$name').writeAsBytes(List.filled(4, 1));
      }
      final cache = DeltaAttachmentCache(
        dir,
        maxBytes: 4,
        onEvicted: (_) => fail('pinned file evicted'),
      );
      await cache.load(['a', 'b']);
      await cache.reserve('', 0, {'a', 'b'});
      expect(await File('${dir.path}/a').readAsBytes(), List.filled(4, 1));
      await expectLater(
        cache.reserve('c', 1, {'a', 'b'}),
        throwsA(isA<FileSystemException>()),
      );
      expect(cache.sizeBytes, 8);
    },
  );

  test('Delta startup and unchanged saves never decode avatars', () {
    final avatar = base64Encode(img.encodePng(img.Image(width: 2, height: 2)));
    final store = DeltaChats.fromJson({
      'peers': [
        {
          'fingerprint': 'A' * 40,
          'addr': 'alice@example.org',
          'avatar': avatar,
        },
      ],
      'chats': [
        {'key': 'g:avatar', 'members': <String>[], 'avatar': avatar},
      ],
    });
    final peer = store.peers.values.single;
    final chat = store.chats.values.single;
    expect(peer.avatarLoaded, isFalse);
    expect(chat.avatarLoaded, isFalse);
    final copied = store.copyWith(
      chats: {...store.chats, 'g:avatar': chat.copyWith(unread: 1)},
    );
    copied.toJson();
    expect(peer.avatarLoaded, isFalse);
    expect(copied.chats['g:avatar']!.avatarLoaded, isFalse);
    final bytes = peer.avatar;
    expect(bytes, isNotNull);
    expect(peer.avatarLoaded, isTrue);
    expect(identical(peer.copyWith(name: 'Alice').avatar, bytes), isTrue);
  });

  test(
    'Delta lazy avatars never expand the size admitted before later mutations',
    () {
      final noisy = img.Image(width: 64, height: 64);
      final random = Random(24);
      for (final pixel in noisy) {
        pixel.setRgb(
          random.nextInt(256),
          random.nextInt(256),
          random.nextInt(256),
        );
      }
      final jpeg = Uint8List.fromList(img.encodeJpg(noisy, quality: 25));
      final encoded = base64Encode(jpeg);
      var store = DeltaChats.fromJson({
        'peers': [
          {
            'fingerprint': 'A' * 40,
            'addr': 'alice@example.org',
            'avatar': encoded,
          },
        ],
      });
      final before = store.peers.values.single.avatarEncodedSize;
      store = store.withPeer(
        DeltaPeer(
          fingerprint: 'B' * 40,
          addr: 'bob@example.org',
          avatar: Uint8List.fromList(
            img.encodePng(img.Image(width: 2, height: 2)),
          ),
        ),
      );
      final avatar = store.peers['A' * 40]!.avatar;
      expect(avatar, isNotNull);
      expect(base64Encode(avatar!).length, lessThanOrEqualTo(before));
    },
  );

  test('Delta saves reuse unchanged message JSON', () {
    final first = DeltaChatMessage(
      id: 'first@example.org',
      author: 'A' * 40,
      text: 'first',
      at: DateTime.utc(2026),
    );
    var store = DeltaChats(
      chats: {
        'chat': DeltaChat(
          key: 'chat',
          members: const [],
          kept: true,
          messages: [first],
        ),
      },
    );
    final old = (store.toJson()['chats'] as List).single['messages'].single;
    store = store.add(
      'chat',
      DeltaChatMessage(
        id: 'next@example.org',
        author: 'A' * 40,
        text: 'next',
        at: DateTime.utc(2026, 2),
      ),
      create: () => throw StateError('exists'),
    );
    final next = (store.toJson()['chats'] as List).single['messages'].first;
    expect(identical(old, next), isTrue);
  });

  test(
    'Delta invite and persisted token inputs have bounded counts and lengths',
    () {
      expect(
        DeltaInvite.parse(
          'https://i.delta.chat/#${'A' * 40}&a=a@example.org&s=valid&n=${'x' * 9000}',
        ),
        isNull,
      );
      final tokens = DeltaTokens.fromJson({
        'invitenumber': 'invite',
        'auth': 'secret',
        'groups': {
          for (var i = 0; i < 100; i++) 'g$i': ['invite', 'secret'],
        },
      })!;
      expect(tokens.groups, hasLength(DeltaTokens.maxGroups));
      expect(
        DeltaTokens.fromJson({'invitenumber': 'i', 'auth': 'a' * 1000}),
        isNull,
      );
    },
  );

  test('Delta MIME rejects invalid header names and oversized boundaries', () {
    expect(
      () => MimeHeaders.parse('From : <alice@example.org>'),
      throwsFormatException,
    );
    expect(
      () => MimeHeaders.parse('Chat-Delete\x00: <target@example.org>'),
      throwsFormatException,
    );
    expect(
      () => MimeEntity.parse(
        Uint8List.fromList(
          ascii.encode(
            'Content-Type: multipart/mixed; boundary="${'b' * 71}"\r\n\r\n',
          ),
        ),
      ),
      throwsFormatException,
    );
  });

  late PgpSecretKey alice, bob;
  setUpAll(() async {
    alice = await PgpSecretKey.generate('<alice@example.org>');
    bob = await PgpSecretKey.generate('<bob@example.org>');
  });

  Future<Uint8List> envelope(String protected) async {
    final cipher = await Pgp.encrypt(
      Uint8List.fromList(utf8.encode(protected)),
      [bob.publicKey],
      signer: alice,
    );
    return Uint8List.fromList(
      ascii.encode(
        'From: <alice@example.org>\r\nMessage-ID: <outer@example.org>\r\nChat-Version: 1.0\r\nContent-Type: multipart/encrypted; boundary=outer\r\n\r\n--outer\r\nContent-Type: application/octet-stream\r\n\r\n${OpenPgpArmor.encode(cipher)}\r\n--outer--\r\n',
      ),
    );
  }

  test(
    'Delta protected identity cannot be supplied by unsigned outer headers',
    () async {
      for (final missing in ['From', 'Message-ID', 'Chat-Version']) {
        final inner = [
          'Content-Type: text/plain',
          if (missing != 'From') 'From: <alice@example.org>',
          'To: <bob@example.org>',
          if (missing != 'Message-ID') 'Message-ID: <inner@example.org>',
          if (missing != 'Chat-Version') 'Chat-Version: 1.0',
          '',
          'hello',
        ].join('\r\n');
        expect(
          await DeltaMail.read(await envelope(inner), bob),
          isNull,
          reason: missing,
        );
      }
    },
  );

  test(
    'Delta duplicate control headers and Autocrypt attributes are rejected',
    () async {
      final mail = await DeltaMail.build(
        key: alice,
        from: 'alice@example.org',
        to: [(addr: 'bob@example.org', key: bob.publicKey)],
        text: 'edit',
        messageId: 'duplicate@example.org',
        date: DateTime.now(),
        extraHeaders: [
          ('Chat-Edit', '<first@example.org>'),
          ('Chat-Edit', '<second@example.org>'),
        ],
      );
      expect(
        await DeltaMail.read(Uint8List.fromList(ascii.encode(mail)), bob),
        isNull,
      );
      expect(
        AutocryptHeader.parse(
          'addr=alice@example.org; addr=bob@example.org; keydata=YQ==',
        ),
        isNull,
      );
      expect(
        AutocryptHeader.parse(
          'addr=alice@example.org; keydata=${'Y' * (100 * 1024)}',
        ),
        isNull,
      );
    },
  );

  test(
    'Delta 20 MiB mail is parsed and decrypted outside the UI isolate',
    () async {
      final bytes = Uint8List(20 * 1024 * 1024)..[0] = 17;
      final mail = await DeltaMail.build(
        key: alice,
        from: 'alice@example.org',
        to: [(addr: 'bob@example.org', key: bob.publicKey)],
        text: '',
        messageId: 'large@example.org',
        date: DateTime.now(),
        files: [DeltaFile(name: 'large.bin', bytes: bytes)],
        random: Random(24),
      );
      final read = (await DeltaMail.read(
        Uint8List.fromList(ascii.encode(mail)),
        bob,
      ))!;
      expect(read.parserIsolate, isNot(Isolate.current.hashCode));
      expect(read.files.single.bytes, bytes);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/delta_chats.dart';
import 'package:conest/src/email/delta_content.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  final stamp = DateTime.utc(2026, 10, 14);
  String fingerprint(int i) =>
      i.toRadixString(16).padLeft(40, '0').toUpperCase();
  DeltaPeer peer(int i, Uint8List avatar, {bool verified = false}) => DeltaPeer(
    fingerprint: fingerprint(i),
    addr: 'person$i@example.org',
    avatar: avatar,
    avatarAt: stamp,
    verified: verified,
  );
  DeltaChat group(int i, Uint8List avatar, {bool kept = false}) => DeltaChat(
    key: 'g:group$i',
    groupId: 'group$i',
    members: [fingerprint(i)],
    kept: kept,
    avatar: avatar,
    avatarAt: stamp,
  );
  List<Uint8List> images(DeltaChats store) => [
    for (final p in store.peers.values) ?p.avatar,
    for (final c in store.chats.values) ?c.avatar,
  ];
  void bounded(DeltaChats store) {
    final retained = images(store);
    expect(retained.length, lessThanOrEqualTo(DeltaChats.maxAvatars));
    final encodedBytes = retained.fold<int>(
      0,
      (sum, image) => sum + ((image.length + 2) ~/ 3) * 4,
    );
    expect(encodedBytes, lessThanOrEqualTo(DeltaChats.maxAvatarEncodedBytes));
  }

  test(
    'avatar bytes share a budget across peers and groups on every mutation',
    () {
      final avatar = Uint8List(180 * 1024);
      var store = const DeltaChats();
      for (var i = 0; i < 100; i++) {
        store = store.withPeer(peer(i, avatar));
        store = store.withChat(group(i, avatar, kept: true));
        bounded(store);
      }
      expect(store.peers, hasLength(100));
      expect(store.chats, hasLength(100));
      expect(images(store), isNotEmpty);
      expect(store.peers.values.where((p) => p.avatar == null), isNotEmpty);
      expect(store.chats.values.where((c) => c.avatar == null), isNotEmpty);
      // Evicted image timestamps survive both pruning and serialization.
      expect(store.peers.values.every((p) => p.avatarAt == stamp), isTrue);
      expect(store.chats.values.every((c) => c.avatarAt == stamp), isTrue);
    },
  );

  test(
    'avatar count favors verified contacts and kept chats over requests',
    () {
      final avatar = Uint8List.fromList(
        img.encodePng(img.Image(width: 2, height: 2)),
      );
      var store = const DeltaChats();
      for (var i = 0; i < 160; i++) {
        store = store.withPeer(peer(i, avatar));
      }
      store = store.withPeer(peer(900, avatar, verified: true));
      store = store
          .withPeer(peer(901, avatar))
          .withChat(
            DeltaChat(
              key: fingerprint(901),
              members: [fingerprint(901)],
              kept: true,
            ),
          );
      // The peer is learned before its chat, so present it once more now that
      // the user has kept that chat; the same ordering is used by signed mail.
      store = store.withPeer(peer(901, avatar));
      store = store.withChat(group(902, avatar, kept: true));
      for (var i = 200; i < 350; i++) {
        store = store.withPeer(peer(i, avatar));
      }
      bounded(store);
      expect(images(store), hasLength(DeltaChats.maxAvatars));
      expect(store.peers[fingerprint(900)]!.avatar, avatar);
      expect(store.peers[fingerprint(901)]!.avatar, avatar);
      expect(store.chats['g:group902']!.avatar, avatar);
      expect(
        store.peers.values.any((p) => p.avatar == null && p.avatarAt == stamp),
        isTrue,
      );
    },
  );

  test(
    'restoring legacy avatar stores shares count and preserves trusted priorities',
    () {
      final avatar = Uint8List.fromList(
        img.encodePng(img.Image(width: 2, height: 2)),
      );
      // Deliberately serialize an old, unbounded store, with trusted entries
      // last. Restoration must choose its budget before decoding all entries.
      final old = DeltaChats(
        peers: {
          for (var i = 0; i < 180; i++) fingerprint(i): peer(i, avatar),
          fingerprint(900): peer(900, avatar, verified: true),
          fingerprint(901): peer(901, avatar),
        },
        chats: {
          fingerprint(901): DeltaChat(
            key: fingerprint(901),
            members: [fingerprint(901)],
            kept: true,
          ),
          'g:group902': group(902, avatar, kept: true),
        },
      );
      final store = DeltaChats.fromJson(old.toJson());
      bounded(store);
      expect(images(store), hasLength(DeltaChats.maxAvatars));
      expect(store.peers[fingerprint(900)]!.avatar, avatar);
      expect(store.peers[fingerprint(901)]!.avatar, avatar);
      expect(store.chats['g:group902']!.avatar, avatar);
      final restored = DeltaChats.fromJson(store.toJson());
      expect(jsonEncode(restored.toJson()), jsonEncode(store.toJson()));
    },
  );

  test('restoring legacy large avatars enforces one encoded byte budget', () {
    final random = Random(24);
    final image = img.Image(width: 240, height: 240, numChannels: 3);
    for (final pixel in image) {
      pixel.setRgb(
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
      );
    }
    final avatar = Uint8List.fromList(img.encodePng(image));
    expect(
      base64Encode(avatar).length,
      lessThan(DeltaLimits.avatarEncodedBytes),
    );
    final old = DeltaChats(
      peers: {for (var i = 0; i < 35; i++) fingerprint(i): peer(i, avatar)},
      chats: {
        for (var i = 0; i < 35; i++) 'g:group$i': group(i, avatar, kept: true),
      },
    );
    final store = DeltaChats.fromJson(old.toJson());
    bounded(store);
    expect(images(store), isNotEmpty);
    expect(images(store).length, lessThan(70));
    expect(store.peers.values.every((p) => p.avatarAt == stamp), isTrue);
    expect(store.chats.values.every((c) => c.avatarAt == stamp), isTrue);
  });
}

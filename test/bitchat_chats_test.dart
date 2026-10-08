import 'dart:convert';

import 'package:conest/src/bitchat_chats.dart';
import 'package:conest/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 8, 12);
  BitchatChatMessage message(
    String id, {
    String peer = 'p1',
    bool outgoing = false,
    int minute = 0,
  }) => BitchatChatMessage(
    id: id,
    peerId: peer,
    nickname: 'nick-$peer',
    text: 'text $id',
    at: start.add(Duration(minutes: minute)),
    outgoing: outgoing,
  );

  test('chats count unread, drop copies and survive the vault', () {
    var chats = const BitchatChats()
        .addMesh(message('m1'))
        .addMesh(message('m1'))
        .addMesh(message('m2', outgoing: true, minute: 1))
        .addDirect(message('d1'))
        .addDirect(message('d2', outgoing: true, minute: 2));
    expect(chats.mesh.map((m) => m.id), ['m1', 'm2']);
    expect(chats.unread, {BitchatChats.meshKey: 1, 'p1': 1});
    chats = chats.markOutgoing('p1', 'd2', BitchatMessageState.read);
    // States only go forward.
    chats = chats.markOutgoing('p1', 'd2', BitchatMessageState.delivered);
    expect(chats.direct['p1']!.last.state, BitchatMessageState.read);
    chats = chats.markRead('p1');
    expect(chats.unread, {BitchatChats.meshKey: 1});
    expect(chats.nicknameOf('p1'), 'nick-p1');

    final snapshot = VaultSnapshot.fromJson(
      jsonDecode(
            jsonEncode(
              VaultSnapshot.fromJson({
                'networkChats': {'bitchat': chats.toJson()},
              }).toJson(),
            ),
          )
          as Map<String, dynamic>,
    );
    final restored = BitchatChats.fromJson(snapshot.networkChats['bitchat']);
    expect(restored.mesh.map((m) => m.id), ['m1', 'm2']);
    expect(restored.direct['p1']!.map((m) => m.state), [
      BitchatMessageState.sent,
      BitchatMessageState.read,
    ]);
    expect(restored.unread, {BitchatChats.meshKey: 1});
    expect(restored.withoutChat('p1').direct, isEmpty);
  });

  test('chats keep the newest messages and chats', () {
    var chats = const BitchatChats();
    for (var i = 0; i < BitchatChats.maxMeshMessages + 3; i++) {
      chats = chats.addMesh(message('m$i', minute: i));
    }
    expect(chats.mesh, hasLength(BitchatChats.maxMeshMessages));
    expect(chats.mesh.first.id, 'm3');
    // A week later the mesh chat starts over.
    chats = chats.addMesh(message('late', minute: 8 * 24 * 60));
    expect(chats.mesh.map((m) => m.id), ['late']);
    for (var i = 0; i < BitchatChats.maxChats + 2; i++) {
      chats = chats.addDirect(message('d$i', peer: 'p$i', minute: i));
    }
    expect(chats.direct, hasLength(BitchatChats.maxChats));
    expect(chats.direct.containsKey('p0'), isFalse);
    expect(chats.unread.containsKey('p0'), isFalse);
  });
}

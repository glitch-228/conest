part of 'delta_chats.dart';

typedef _AvatarSlot = ({String key, bool peer, int cost});

int _avatarCost(Uint8List bytes) => ((bytes.length + 2) ~/ 3) * 4;

/// Only the current bounded snapshot retains image data. Dropping an image
/// keeps its signed timestamp, so an older mail cannot restore it by replay.
DeltaChats _boundedDeltaAvatars(
  DeltaChats store, {
  Map<String, Map<String, dynamic>>? peerRows,
  Map<String, Map<String, dynamic>>? chatRows,
}) {
  final restoring = peerRows != null;
  final slots = <_AvatarSlot>[];
  for (final peer in store.peers.values) {
    final value = peerRows?[peer.fingerprint]?['avatar'];
    final cost = restoring
        ? (value is String ? value.length : 0)
        : (peer.avatar == null ? 0 : _avatarCost(peer.avatar!));
    if (cost > 0) slots.add((key: peer.fingerprint, peer: true, cost: cost));
  }
  for (final chat in store.chats.values) {
    final value = chatRows?[chat.key]?['avatar'];
    final cost = restoring
        ? (value is String ? value.length : 0)
        : (chat.avatar == null ? 0 : _avatarCost(chat.avatar!));
    if (cost > 0) slots.add((key: chat.key, peer: false, cost: cost));
  }
  if (!restoring &&
      slots.length <= DeltaChats.maxAvatars &&
      slots.every((s) => s.cost <= DeltaLimits.avatarEncodedBytes) &&
      slots.fold<int>(0, (sum, s) => sum + s.cost) <=
          DeltaChats.maxAvatarEncodedBytes) {
    return store;
  }

  final inChats = {for (final c in store.chats.values) ...c.members};
  final inKept = {
    for (final c in store.chats.values)
      if (c.kept) ...c.members,
  };
  int rank(_AvatarSlot s) => s.peer
      ? store.peers[s.key]!.verified
            ? 0
            : inKept.contains(s.key)
            ? 1
            : inChats.contains(s.key)
            ? 2
            : 3
      : store.chats[s.key]!.kept
      ? 1
      : 2;
  DateTime date(_AvatarSlot s) =>
      (s.peer ? store.peers[s.key]!.avatarAt : store.chats[s.key]!.avatarAt) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  slots.sort((a, b) {
    final priority = rank(a).compareTo(rank(b));
    if (priority != 0) return priority;
    final newer = date(b).compareTo(date(a));
    if (newer != 0) return newer;
    final kind = (a.peer ? 0 : 1).compareTo(b.peer ? 0 : 1);
    return kind != 0 ? kind : a.key.compareTo(b.key);
  });
  var bytes = 0;
  var count = 0;
  final peers = {...store.peers};
  final chats = {...store.chats};
  for (final slot in slots) {
    Uint8List? image;
    if (slot.cost <= DeltaLimits.avatarEncodedBytes &&
        count < DeltaChats.maxAvatars &&
        slot.cost <= DeltaChats.maxAvatarEncodedBytes - bytes) {
      // Charge before decoding on restore. Even invalid images spend the
      // shared count/byte budget; a legacy vault cannot trigger 2,000 decodes.
      count++;
      bytes += slot.cost;
      if (restoring) {
        final row = slot.peer ? peerRows[slot.key] : chatRows?[slot.key];
        image = deltaAvatar('base64:${row!['avatar']}');
        if (image != null) {
          final extra = max(0, _avatarCost(image) - slot.cost);
          if (extra > DeltaChats.maxAvatarEncodedBytes - bytes) {
            image = null;
          } else {
            bytes += extra;
          }
        }
      } else {
        image = slot.peer ? peers[slot.key]!.avatar : chats[slot.key]!.avatar;
      }
    }
    if (slot.peer) {
      peers[slot.key] = peers[slot.key]!.copyWith(
        avatar: image,
        clearAvatar: image == null,
      );
    } else {
      chats[slot.key] = chats[slot.key]!.copyWith(
        avatar: image,
        clearAvatar: image == null,
      );
    }
  }
  return DeltaChats(
    peers: peers,
    chats: chats,
    joins: store.joins,
    deleted: store.deleted,
    detachedControls: store.detachedControls,
  );
}

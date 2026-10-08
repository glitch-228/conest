import 'dart:async';

import 'package:flutter/material.dart';

import '../bitchat_chats.dart';
import '../messenger_controller.dart';
import '../conest_theme.dart';
import '../models.dart';
import 'bitchat_chats_screen.dart';
import 'matrix_room_screen.dart';
import 'nostr_chats_screen.dart';

/// A chat on another network, as the chat list shows it.
class NetworkChat {
  const NetworkChat({
    required this.network,
    required this.id,
    required this.title,
    required this.preview,
    required this.open,
    this.at,
    this.unread = 0,
    this.isGroup = false,
    this.memberCount = 0,
    this.searchText,
  });

  /// The [NetworkChatSource.id] it comes from.
  final String network;

  /// Unique within its network.
  final String id;
  final String title;
  final String preview;
  final DateTime? at;
  final int unread;
  final bool isGroup;
  final int memberCount;

  /// What a search also looks through (message texts), built only when
  /// searching.
  final String Function()? searchText;
  final void Function(BuildContext context) open;

  bool matches(String query) =>
      query.isEmpty ||
      title.toLowerCase().contains(query) ||
      (searchText?.call().toLowerCase().contains(query) ?? false);
}

/// One network whose chats the chat list can show beside Conest's.
abstract class NetworkChatSource {
  const NetworkChatSource();

  /// A stable id, used for filters and the "show in chat list" setting.
  String get id;

  /// The name in chips and badges.
  String get label;

  /// Whether it has chats to show right now (signed in, turned on).
  bool get active;

  List<NetworkChat> chats();
}

/// The networks available to [controller], whether shown or not.
List<NetworkChatSource> networkChatSources(
  MessengerController controller,
  ConestPalette palette,
) => [
  MatrixChatSource(controller, palette),
  NostrChatSource(controller),
  BitchatChatSource(controller),
];

/// Nostr private chats (NIP-17).
class NostrChatSource extends NetworkChatSource {
  const NostrChatSource(this.controller);

  final MessengerController controller;

  @override
  String get id => 'nostr';

  @override
  String get label => 'Nostr';

  @override
  bool get active =>
      controller.conestActive && controller.nostrDirectConfig != null;

  @override
  List<NetworkChat> chats() => [
    if (active)
      for (final chat in controller.nostrChats.chats.values)
        NetworkChat(
          network: id,
          id: chat.key,
          title: nostrChatTitle(controller, chat),
          preview: chat.messages.lastOrNull?.text ?? 'New chat',
          at: chat.messages.lastOrNull?.at.toLocal(),
          unread: chat.unread,
          isGroup: chat.isGroup,
          memberCount: chat.isGroup ? chat.people.length + 1 : 0,
          searchText: () =>
              chat.messages.map((message) => message.text).join('\n'),
          open: (context) => openNostrChat(context, controller, chat.key),
        ),
  ];
}

/// Matrix rooms and DMs from the full Matrix client.
class MatrixChatSource extends NetworkChatSource {
  const MatrixChatSource(this.controller, this.palette);

  final MessengerController controller;
  final ConestPalette palette;

  @override
  String get id => 'matrix';

  @override
  String get label => 'Matrix';

  @override
  bool get active =>
      controller.appMode != AppMode.conest &&
      (controller.matrixClient?.signedIn ?? false);

  @override
  List<NetworkChat> chats() {
    final matrix = controller.matrixClient;
    if (matrix == null || !active) return const [];
    return [
      for (final room in matrix.rooms)
        () {
          final last = matrix.lastVisible(room.roomId);
          return NetworkChat(
            network: id,
            id: room.roomId,
            title: room.invited ? 'Invitation: ${room.name}' : room.name,
            preview: room.invited
                ? 'Matrix invitation'
                : last == null
                ? (room.encrypted ? 'Encrypted Matrix chat' : 'Matrix chat')
                : matrixPreview(last),
            at: last?.timestamp.toLocal(),
            unread: room.unread,
            isGroup: !room.direct,
            memberCount: room.direct ? 0 : room.members,
            searchText: () => matrix
                .timeline(room.roomId)
                .items
                .map((item) => item.body)
                .join('\n'),
            open: (context) => unawaited(
              Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => MatrixRoomScreen(
                    client: matrix,
                    roomId: room.roomId,
                    palette: palette,
                  ),
                ),
              ),
            ),
          );
        }(),
    ];
  }
}

/// bitchat's mesh chat and private chats with bitchat users nearby.
class BitchatChatSource extends NetworkChatSource {
  const BitchatChatSource(this.controller);

  final MessengerController controller;

  @override
  String get id => 'bitchat';

  @override
  String get label => 'bitchat';

  @override
  bool get active => controller.bitchatCarrierConfig != null;

  @override
  List<NetworkChat> chats() {
    if (!active) return const [];
    final chats = controller.bitchatChats;
    final nearby = {
      for (final peer in controller.bitchatNearbyPeers)
        peer.peerId: peer.nickname,
    };
    String name(String peer) =>
        nearby[peer] ?? chats.nicknameOf(peer) ?? peer.substring(0, 8);
    return [
      NetworkChat(
        network: id,
        id: BitchatChats.meshKey,
        title: 'Mesh chat (nearby)',
        preview: chats.mesh.isEmpty
            ? 'Everyone in Bluetooth range'
            : '${chats.mesh.last.outgoing ? 'You' : chats.mesh.last.nickname}: '
                  '${chats.mesh.last.text}',
        at: chats.mesh.lastOrNull?.at.toLocal(),
        unread: chats.unread[BitchatChats.meshKey] ?? 0,
        isGroup: true,
        memberCount: nearby.length,
        searchText: () => chats.mesh.map((message) => message.text).join('\n'),
        open: (context) => openBitchatChat(
          context,
          controller,
          BitchatChats.meshKey,
          'Mesh chat',
        ),
      ),
      for (final MapEntry(key: peer, value: messages) in chats.direct.entries)
        NetworkChat(
          network: id,
          id: peer,
          title: name(peer),
          preview: messages.last.text,
          at: messages.last.at.toLocal(),
          unread: chats.unread[peer] ?? 0,
          searchText: () => messages.map((message) => message.text).join('\n'),
          open: (context) =>
              openBitchatChat(context, controller, peer, name(peer)),
        ),
    ];
  }
}

/// Settings: which networks' chats the chat list shows beside Conest's.
class NetworkChatsSettings extends StatelessWidget {
  const NetworkChatsSettings({
    super.key,
    required this.controller,
    required this.palette,
  });

  final MessengerController controller;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    final sources = [
      for (final source in networkChatSources(controller, palette))
        if (source.active) source,
    ];
    if (sources.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(
          'Chats from other networks',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        for (final source in sources)
          SwitchListTile.adaptive(
            key: ValueKey('network-chats-${source.id}'),
            contentPadding: EdgeInsets.zero,
            title: Text('Show ${source.label} chats in the chat list'),
            subtitle: const Text(
              'With a filter of their own. Off: open them from the '
              'network\'s settings only.',
            ),
            value: controller.showsChatNetwork(source.id),
            onChanged: (value) =>
                unawaited(controller.setShowsChatNetwork(source.id, value)),
          ),
      ],
    );
  }
}

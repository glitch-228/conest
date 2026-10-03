import 'dart:async';

import 'package:flutter/material.dart';

import '../conest_theme.dart';
import '../matrix_service.dart';
import '../messenger_controller.dart';
import '../models.dart';
import 'app_mode_selector.dart';
import 'matrix_account_panel.dart';
import 'matrix_room_screen.dart';

/// The app in Matrix-only mode: the account until signed in, then the room
/// list. Needs no Conest identity.
class MatrixHomeScreen extends StatefulWidget {
  const MatrixHomeScreen({
    super.key,
    required this.controller,
    required this.palette,
  });

  final MessengerController controller;
  final ConestPalette palette;

  @override
  State<MatrixHomeScreen> createState() => _MatrixHomeScreenState();
}

class _MatrixHomeScreenState extends State<MatrixHomeScreen> {
  final _search = TextEditingController();

  MatrixClientService? get _client => widget.controller.matrixClient;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _search.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _search.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _openRoom(MatrixClientService client, String roomId) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => MatrixRoomScreen(
            client: client,
            roomId: roomId,
            palette: widget.palette,
          ),
        ),
      ),
    );
  }

  Future<void> _openSettings() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => _MatrixSettingsScreen(controller: widget.controller),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final client = _client;
    final signedIn = client?.signedIn == true;
    return Scaffold(
      backgroundColor: widget.palette.panel,
      appBar: AppBar(
        title: const Text('Matrix'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      floatingActionButton: signedIn
          ? FloatingActionButton(
              tooltip: 'New Matrix chat',
              onPressed: () =>
                  startMatrixChat(context, client!, widget.palette),
              backgroundColor: widget.palette.primary,
              foregroundColor: widget.palette.onPrimary,
              child: const Icon(Icons.edit_outlined),
            )
          : null,
      body: signedIn
          ? _rooms(client!)
          : client == null
          ? _unavailable()
          // The panel stays mounted while signing in: it holds the browser
          // sign-in's link and Cancel, and shows errors.
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sign in to your Matrix account',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      if (client.state == MatrixClientState.signingIn)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: LinearProgressIndicator(),
                        ),
                      MatrixAccountPanel(controller: widget.controller),
                      const SizedBox(height: 24),
                      AppModeSelector(controller: widget.controller),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  /// Matrix-only mode in a build, or on a device, without the Matrix
  /// client: Conest stays off until the user picks it again.
  Widget _unavailable() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'The Matrix client is not available on this device, so Conest '
            'cannot run in Matrix-only mode here.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => widget.controller.setAppMode(AppMode.conest),
            child: const Text('Use Conest'),
          ),
        ],
      ),
    ),
  );

  Widget _rooms(MatrixClientService client) {
    final query = _search.text.trim().toLowerCase();
    final rooms = [
      for (final room in client.rooms)
        if (query.isEmpty || room.name.toLowerCase().contains(query)) room,
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search rooms',
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: rooms.isEmpty
              ? Center(
                  child: Text(
                    query.isEmpty ? 'No Matrix chats yet' : 'No rooms found',
                  ),
                )
              : ListView.builder(
                  itemCount: rooms.length,
                  itemBuilder: (context, index) {
                    final room = rooms[index];
                    final last = client.lastVisible(room.roomId);
                    return ListTile(
                      key: ValueKey('matrix-room-${room.roomId}'),
                      leading: CircleAvatar(
                        child: Icon(
                          room.direct
                              ? Icons.person_outline
                              : Icons.group_outlined,
                        ),
                      ),
                      title: Text(
                        room.invited ? 'Invitation: ${room.name}' : room.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        room.invited
                            ? 'Matrix invitation'
                            : last == null
                            ? (room.encrypted ? 'Encrypted chat' : 'Chat')
                            : matrixPreview(last),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: room.unread > 0
                          ? Badge(label: Text('${room.unread}'))
                          : null,
                      onTap: () => _openRoom(client, room.roomId),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _MatrixSettingsScreen extends StatelessWidget {
  const _MatrixSettingsScreen({required this.controller});

  final MessengerController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
            MatrixAccountPanel(controller: controller),
            const Divider(height: 32),
            AppModeSelector(controller: controller),
          ],
        ),
      ),
    );
  }
}

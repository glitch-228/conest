import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../conest_theme.dart';
import '../messenger_controller.dart';
import '../models.dart';
import 'app_mode_selector.dart';
import 'matrix_home_screen.dart';
import 'xmpp_chats_screen.dart';

/// The home screen of a client-only mode (Conest dormant), or null in the
/// Conest modes.
Widget? clientOnlyHome(MessengerController controller, ConestPalette palette) =>
    switch (controller.appMode) {
      AppMode.matrixOnly => MatrixHomeScreen(
        controller: controller,
        palette: palette,
      ),
      AppMode.xmppOnly => XmppHomeScreen(
        controller: controller,
        palette: palette,
      ),
      AppMode.conest || AppMode.both => null,
    };

/// Onboarding: use the app as a client of another network instead, with no
/// Conest identity.
class ClientOnlyChoices extends StatelessWidget {
  const ClientOnlyChoices({super.key, required this.controller});

  final MessengerController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('onboarding-xmpp-only'),
          onPressed: () => controller.setAppMode(AppMode.xmppOnly),
          icon: const Icon(Icons.chat_bubble_outline),
          label: Text(l10n.onbXmppInstead),
        ),
      ],
    );
  }
}

/// XMPP-only mode: the account's chats and nothing of Conest.
class XmppHomeScreen extends StatelessWidget {
  const XmppHomeScreen({
    super.key,
    required this.controller,
    required this.palette,
  });

  final MessengerController controller;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final client = controller.xmppChatClient;
        final chats = controller.xmppChats.chats.values.toList()
          ..sort(
            (a, b) => (b.messages.lastOrNull?.at ?? DateTime(0)).compareTo(
              a.messages.lastOrNull?.at ?? DateTime(0),
            ),
          );
        return Scaffold(
          backgroundColor: palette.panel,
          appBar: AppBar(
            title: const Text('XMPP'),
            actions: [
              IconButton(
                tooltip: l10n.tabSettings,
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: Text(l10n.tabSettings)),
                      body: ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          XmppChatsPanel(controller: controller),
                          const SizedBox(height: 24),
                          AppModeSelector(controller: controller),
                        ],
                      ),
                    ),
                  ),
                ),
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
          floatingActionButton: client == null
              ? null
              : FloatingActionButton(
                  tooltip: l10n.xmppNewChat,
                  onPressed: () => startXmppChat(context, controller),
                  child: const Icon(Icons.edit_outlined),
                ),
          body: controller.xmppClientConfig == null
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.xmppSignIn,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      XmppChatsPanel(controller: controller),
                      const SizedBox(height: 24),
                      AppModeSelector(controller: controller),
                    ],
                  ),
                )
              : chats.isEmpty
              ? Center(child: Text(l10n.xmppNoChats))
              : ListView(
                  children: [
                    for (final chat in chats)
                      ListTile(
                        key: ValueKey('xmpp-chat-${chat.jid}'),
                        leading: CircleAvatar(
                          child: Icon(
                            chat.room
                                ? Icons.group_outlined
                                : Icons.person_outline,
                          ),
                        ),
                        title: Text(
                          xmppChatTitle(controller, chat),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          chat.request
                              ? l10n.xmppRequestShort
                              : xmppPreview(context, chat.messages.lastOrNull),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: chat.unread > 0
                            ? Badge(label: Text('${chat.unread}'))
                            : null,
                        onTap: () =>
                            openXmppChat(context, controller, chat.jid),
                      ),
                  ],
                ),
        );
      },
    );
  }
}

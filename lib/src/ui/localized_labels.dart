import 'package:flutter/widgets.dart';

import '../app_locales.dart';
import '../models.dart';
import '../conest_theme.dart';

// Presentation belongs here; stored enum values and protocol labels stay stable.
String deliveryStateLabel(BuildContext? context, DeliveryState value) =>
    switch (value) {
      DeliveryState.pending => l10nOf(context).deliveryPending,
      DeliveryState.local => l10nOf(context).deliveryLocal,
      DeliveryState.relayed => l10nOf(context).deliveryRelayed,
      DeliveryState.delivered => l10nOf(context).deliveryDelivered,
      DeliveryState.read => l10nOf(context).deliveryRead,
      DeliveryState.canceled => l10nOf(context).uiCanceledF840AC,
      DeliveryState.failed => l10nOf(context).callFailed,
    };

String reachabilityLabel(
  BuildContext? context,
  ContactReachabilityState value,
) => switch (value) {
  ContactReachabilityState.online => l10nOf(context).reachabilityOnline,
  ContactReachabilityState.seenRecently => l10nOf(context).reachabilityRecent,
  ContactReachabilityState.known => l10nOf(context).reachabilityKnown,
  ContactReachabilityState.unknown => l10nOf(context).statusUnknown,
};

String transferPhaseLabel(BuildContext? context, TransferPhase value) =>
    switch (value) {
      TransferPhase.preparing => l10nOf(context).uiPreparing96A9B7,
      TransferPhase.queued => l10nOf(context).uiQueued6A5998,
      TransferPhase.awaitingApproval => l10nOf(context).transferApproval,
      TransferPhase.waitingForPeer => l10nOf(context).transferPeer,
      TransferPhase.transferring => l10nOf(context).uiTransferring73F753,
      TransferPhase.reconnecting => l10nOf(context).uiReconnecting9D80F9,
      TransferPhase.paused => l10nOf(context).uiPausedC7DFB6,
      TransferPhase.verifying => l10nOf(context).uiVerifying536244,
      TransferPhase.completed => l10nOf(context).uiComplete1F5A1A,
      TransferPhase.failed => l10nOf(context).callFailed,
      TransferPhase.canceled => l10nOf(context).uiCanceledF840AC,
      TransferPhase.unavailable => l10nOf(context).uiUnavailable2C9C1F,
    };

String messageRouteLabel(BuildContext? context, MessageRoute value) =>
    switch (value) {
      MessageRoute.lanDirect => l10nOf(context).routeLanDirect,
      MessageRoute.lanRelay => l10nOf(context).uiLANRelayA05D48,
      MessageRoute.lanLobby => l10nOf(context).uiLANLobbyC16DC8,
      MessageRoute.internetDirect => l10nOf(context).routeInternetDirect,
      MessageRoute.irohDirect => l10nOf(context).routeIrohDirect,
      MessageRoute.irohRelay => l10nOf(context).uiIrohRelayB128EA,
      MessageRoute.conestRelay => l10nOf(context).routeConestRelay,
      MessageRoute.matrixCarrier => l10nOf(context).uiMatrix58947E,
      MessageRoute.plainMatrix => l10nOf(context).uiPlainMatrixBA9DE1,
      MessageRoute.nostrCarrier => l10nOf(context).uiNostr4D3AD8,
      MessageRoute.emailCarrier => l10nOf(context).uiEmail84ADD5,
      MessageRoute.reticulum => l10nOf(context).uiReticulumC27E52,
      MessageRoute.meshtastic => l10nOf(context).uiMeshtastic29C887,
      MessageRoute.meshCore => l10nOf(context).uiMeshCoreBA58A2,
      MessageRoute.bitchat => l10nOf(context).uiBluetoothMeshC8B7F1,
      MessageRoute.torOnion => l10nOf(context).uiTorED7088,
      MessageRoute.viaContact => l10nOf(context).routeViaContact,
      MessageRoute.viaOwnDevice => l10nOf(context).routeViaOwnDevice,
      MessageRoute.xmppCarrier => 'XMPP',
      MessageRoute.telegramCarrier => 'Telegram',
    };

String themeModeLabel(BuildContext? context, ConestThemeMode value) =>
    switch (value) {
      ConestThemeMode.system => l10nOf(context).themeSystem,
      ConestThemeMode.light => l10nOf(context).themeLight,
      ConestThemeMode.dark => l10nOf(context).themeDark,
      ConestThemeMode.black => l10nOf(context).themeBlack,
      ConestThemeMode.adaptive => l10nOf(context).themeAdaptive,
    };

String homeLayoutLabel(BuildContext? context, ConestHomeLayout value) =>
    switch (value) {
      ConestHomeLayout.signalCards => l10nOf(context).layoutSignalCards,
      ConestHomeLayout.stationFeed => l10nOf(context).layoutStationFeed,
      ConestHomeLayout.classic => l10nOf(context).layoutClassic,
    };

String groupRoleLabel(BuildContext? context, GroupMemberRole value) =>
    switch (value) {
      GroupMemberRole.owner => l10nOf(context).uiOwner89FF31,
      GroupMemberRole.admin => l10nOf(context).roleAdmin,
      GroupMemberRole.moderator => l10nOf(context).roleModerator,
      GroupMemberRole.member => l10nOf(context).roleMember,
    };

String homeLayoutDescription(BuildContext? context, ConestHomeLayout value) =>
    switch (value) {
      ConestHomeLayout.signalCards => l10nOf(context).layoutSignalDescription,
      ConestHomeLayout.stationFeed => l10nOf(context).layoutFeedDescription,
      ConestHomeLayout.classic => l10nOf(context).layoutClassicDescription,
    };

String shellDescription(BuildContext? context, ConestShell value) =>
    switch (value) {
      ConestShell.signature => l10nOf(context).shellSignatureDescription,
      ConestShell.garrison => l10nOf(context).shellGarrisonDescription,
      ConestShell.courier => l10nOf(context).shellCourierDescription,
    };

String messageRouteDescription(BuildContext? context, MessageRoute value) =>
    switch (value) {
      MessageRoute.lanDirect => l10nOf(context).routeLanDirectDescription,
      MessageRoute.lanRelay => l10nOf(context).routeLanRelayDescription,
      MessageRoute.lanLobby => l10nOf(context).routeLanLobbyDescription,
      MessageRoute.internetDirect => l10nOf(
        context,
      ).routeInternetDirectDescription,
      MessageRoute.irohDirect => l10nOf(context).routeIrohDirectDescription,
      MessageRoute.irohRelay => l10nOf(context).routeIrohRelayDescription,
      MessageRoute.conestRelay => l10nOf(context).routeConestRelayDescription,
      MessageRoute.matrixCarrier => l10nOf(context).routeMatrixDescription,
      MessageRoute.plainMatrix => l10nOf(context).routePlainMatrixDescription,
      MessageRoute.nostrCarrier => l10nOf(context).routeNostrDescription,
      MessageRoute.emailCarrier => l10nOf(context).routeEmailDescription,
      MessageRoute.reticulum => l10nOf(context).routeReticulumDescription,
      MessageRoute.meshtastic => l10nOf(context).routeMeshtasticDescription,
      MessageRoute.meshCore => l10nOf(context).routeMeshCoreDescription,
      MessageRoute.bitchat => l10nOf(context).routeBluetoothDescription,
      MessageRoute.torOnion => l10nOf(context).routeTorDescription,
      MessageRoute.viaContact => l10nOf(context).routeContactDescription,
      MessageRoute.viaOwnDevice => l10nOf(context).routeOwnDeviceDescription,
      MessageRoute.xmppCarrier => l10nOf(context).routeXmppDescription,
      MessageRoute.telegramCarrier => l10nOf(context).routeTelegramDescription,
    };

String transportKindLabel(BuildContext? context, TransportKind value) =>
    switch (value) {
      TransportKind.conestRelay => l10nOf(context).routeConestRelay,
      TransportKind.optical => l10nOf(context).routeOptical,
      TransportKind.deltaChat => l10nOf(context).uiEmail84ADD5,
      TransportKind.bitchat => l10nOf(context).uiBluetoothMeshC8B7F1,
      _ => value.label,
    };

// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get modeChooseTitle => 'How should Conest look?';

  @override
  String get modeChangeLater => 'You can change this any time in Settings.';

  @override
  String get modeSimple => 'Simple';

  @override
  String get modeStandard => 'Standard';

  @override
  String get modeAdvanced => 'Advanced';

  @override
  String get modeSimpleDescription =>
      'One list of chats, large text and only the settings you need. Messages show sent, delivered and read.';

  @override
  String get modeStandardDescription =>
      'Like the messengers you know: chats, groups, calls and files, with delivered and read ticks.';

  @override
  String get modeAdvancedDescription =>
      'Everything, including the routes each message took, every transport and diagnostics.';

  @override
  String get actionContinue => 'Continue';

  @override
  String get actionStart => 'Start';

  @override
  String get actionBack => 'Back';

  @override
  String get actionClose => 'Close';

  @override
  String get routesTitle => 'How Conest reaches people';

  @override
  String get routesDirect =>
      'Conest sends messages straight to your contacts over your network and the internet, with no server in between. That is on now.';

  @override
  String get routesOthers =>
      'When those are blocked or missing, Conest can also use relays, Tor, Nostr, email, Matrix, a Bluetooth mesh of nearby phones or LoRa radios. Each is off until you turn it on in Settings → Connectivity.';

  @override
  String get routesAdvanced =>
      'In advanced mode each message shows the routes it took, and a contact\'s profile can test every route.';

  @override
  String get tabChats => 'Chats';

  @override
  String get tabCalls => 'Calls';

  @override
  String get tabSettings => 'Settings';

  @override
  String get callsEmpty => 'No calls yet. Open a chat and tap the call button.';

  @override
  String get callOutgoing => 'Outgoing';

  @override
  String get callIncoming => 'Incoming';

  @override
  String get callMissed => 'Missed';

  @override
  String get callDeclined => 'Declined';

  @override
  String get callCancelled => 'Cancelled';

  @override
  String get callFailed => 'Failed';

  @override
  String callDuration(int minutes, int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes min $seconds s',
      zero: '$seconds s',
    );
    return '$_temp0';
  }

  @override
  String get unknownContact => 'Unknown contact';

  @override
  String get messageDetails => 'Message details';

  @override
  String messageSentAt(String time) {
    return 'Sent $time';
  }

  @override
  String messageReceivedAt(String time) {
    return 'Received $time';
  }

  @override
  String messageDeliveredAt(String time) {
    return 'Delivered $time';
  }

  @override
  String messageReadAt(String time) {
    return 'Read $time';
  }

  @override
  String memberDeliveredAt(String time) {
    return 'delivered $time';
  }

  @override
  String memberReadAt(String time) {
    return 'read $time';
  }

  @override
  String get messageRoutes => 'Routes';

  @override
  String get messageArrivedBy => 'Arrived by';

  @override
  String get settingsShowAll => 'Show all settings';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsLanguageSystem => 'Same as the device';

  @override
  String get settingsAiTranslated =>
      'This translation was made with AI and may contain mistakes. You can help improve it on Weblate.';

  @override
  String get menuReply => 'Reply';

  @override
  String get menuReact => 'React 👍';

  @override
  String get menuForward => 'Forward';

  @override
  String get menuCopyMessage => 'Copy message';

  @override
  String get menuDownloadAttachment => 'Download attachment';

  @override
  String get menuSaveAttachment => 'Save attachment';

  @override
  String get menuCopyImage => 'Copy image';

  @override
  String get menuFreeUpSpace => 'Free up local space';

  @override
  String get menuCancelTransfer => 'Cancel transfer';

  @override
  String get menuRetryTransfer => 'Retry transfer';

  @override
  String get menuForwardAttachment => 'Forward attachment';

  @override
  String get menuCancelSending => 'Cancel sending';

  @override
  String get menuEditMessage => 'Edit message';

  @override
  String get menuDeleteMessage => 'Delete message';

  @override
  String get menuEdit => 'Edit';

  @override
  String get menuDelete => 'Delete';

  @override
  String get composerAttach => 'Attach a file or image';

  @override
  String get composerSchedule => 'Schedule message';

  @override
  String get composerSend => 'Send';

  @override
  String get searchChatsAndMessages => 'Search chats and messages';

  @override
  String get searchChats => 'Search chats';

  @override
  String get searchContacts => 'Search contacts';

  @override
  String get archivedChats => 'Archived chats';

  @override
  String get actionSearch => 'Search';

  @override
  String get settingsPersonal => 'Personal';

  @override
  String get settingsStorage => 'Storage';

  @override
  String get settingsConnectivity => 'Connectivity';

  @override
  String get settingsRelays => 'Relays';

  @override
  String get settingsUpdates => 'Updates';

  @override
  String get settingsAccount => 'Account';

  @override
  String get onbNameRequired =>
      'Enter a display name and a valid local relay port.';

  @override
  String get onbRelayPortInvalid =>
      'If you set an internet relay host, the relay port must be valid too.';

  @override
  String get onbRelayDesktop =>
      'Desktop nodes relay by default and advertise nearby LAN routes automatically.';

  @override
  String get onbRelayAndroid =>
      'Android starts with relay mode off. Enable it in Settings only when you want this device to relay.';

  @override
  String get onbRelayOther =>
      'Relay mode can be enabled in Settings when this device should help carry traffic.';

  @override
  String get onbTagline =>
      'Reach contacts directly over your network or the internet, end-to-end encrypted with forward secrecy. When the usual routes are blocked, Conest falls back to relays, Matrix, Nostr, email, Tor, LoRa radios or a Bluetooth mesh of nearby phones.';

  @override
  String get onbFeatureForwardSecret => 'Forward-secret chats';

  @override
  String get onbFeatureDirect => 'Direct over LAN and internet';

  @override
  String get onbFeatureFallbacks => 'Tor, mesh and radio fallbacks';

  @override
  String get onbFeatureMatrix => 'Also a Matrix client';

  @override
  String get onbCreateTitle => 'Create your first device';

  @override
  String get onbCreateHelp =>
      'Only a display name is needed. The local port is for nearby (LAN) delivery and codephrase pairing. An internet relay is optional: contacts are reached over the internet without one. Turn on more routes later under Settings → Connectivity.';

  @override
  String get onbDisplayName => 'Display name';

  @override
  String get onbLocalPort => 'Local relay / LAN port';

  @override
  String get onbRelayHost => 'Internet relay host / URL (optional)';

  @override
  String get onbRelayPort => 'Internet relay port';

  @override
  String get onbCreateButton => 'Create encrypted device';

  @override
  String get onbMatrixInstead => 'Use as a Matrix client instead';

  @override
  String get onbMatrixHelp =>
      'Matrix chats only, with no Conest identity. You can switch to Both (Conest and Matrix side by side) later under Settings → Connectivity → App mode.';
}

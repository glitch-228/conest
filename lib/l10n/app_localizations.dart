import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';
import 'app_localizations_fa.dart';
import 'app_localizations_id.dart';
import 'app_localizations_ru.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en'),
    Locale('fa'),
    Locale('id'),
    Locale('ru'),
    Locale('zh'),
  ];

  /// Heading of the screen where a new user picks Simple, Standard or Advanced mode.
  ///
  /// In en, this message translates to:
  /// **'How should Conest look?'**
  String get modeChooseTitle;

  /// Under the mode choice heading.
  ///
  /// In en, this message translates to:
  /// **'You can change this any time in Settings.'**
  String get modeChangeLater;

  /// Name of the simplest user mode.
  ///
  /// In en, this message translates to:
  /// **'Simple'**
  String get modeSimple;

  /// Name of the middle user mode, like popular messengers.
  ///
  /// In en, this message translates to:
  /// **'Standard'**
  String get modeStandard;

  /// Name of the mode that shows everything, including network routes.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get modeAdvanced;

  /// Explains Simple mode on the mode choice card.
  ///
  /// In en, this message translates to:
  /// **'One list of chats, large text and only the settings you need. Messages show sent, delivered and read.'**
  String get modeSimpleDescription;

  /// Explains Standard mode on the mode choice card.
  ///
  /// In en, this message translates to:
  /// **'Like the messengers you know: chats, groups, calls and files, with delivered and read ticks.'**
  String get modeStandardDescription;

  /// Explains Advanced mode on the mode choice card.
  ///
  /// In en, this message translates to:
  /// **'Everything, including the routes each message took, every transport and diagnostics.'**
  String get modeAdvancedDescription;

  /// Button that goes to the next step.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get actionContinue;

  /// Button that finishes setup and opens the app.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get actionStart;

  /// Button that goes to the previous step.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get actionBack;

  /// Button that closes a dialog.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get actionClose;

  /// Heading of the setup step that explains how messages travel.
  ///
  /// In en, this message translates to:
  /// **'How Conest reaches people'**
  String get routesTitle;

  /// First paragraph of the setup step about how messages travel.
  ///
  /// In en, this message translates to:
  /// **'Conest sends messages straight to your contacts over your network and the internet, with no server in between. That is on now.'**
  String get routesDirect;

  /// Second paragraph: the other ways messages can travel. Keep the names Tor, Nostr, Matrix, LoRa as they are. 'Settings → Connectivity' must match the Settings screen.
  ///
  /// In en, this message translates to:
  /// **'When those are blocked or missing, Conest can also use relays, Tor, Nostr, email, Matrix, a Bluetooth mesh of nearby phones or LoRa radios. Each is off until you turn it on in Settings → Connectivity.'**
  String get routesOthers;

  /// Shown only when Advanced mode was chosen.
  ///
  /// In en, this message translates to:
  /// **'In advanced mode each message shows the routes it took, and a contact\'s profile can test every route.'**
  String get routesAdvanced;

  /// Bottom tab on phones: the chat list.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get tabChats;

  /// Bottom tab on phones: recent calls.
  ///
  /// In en, this message translates to:
  /// **'Calls'**
  String get tabCalls;

  /// Bottom tab on phones: settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get tabSettings;

  /// The Calls tab when there are no calls.
  ///
  /// In en, this message translates to:
  /// **'No calls yet. Open a chat and tap the call button.'**
  String get callsEmpty;

  /// A completed call you made.
  ///
  /// In en, this message translates to:
  /// **'Outgoing'**
  String get callOutgoing;

  /// A completed call you received.
  ///
  /// In en, this message translates to:
  /// **'Incoming'**
  String get callIncoming;

  /// A call nobody answered.
  ///
  /// In en, this message translates to:
  /// **'Missed'**
  String get callMissed;

  /// A call that was declined.
  ///
  /// In en, this message translates to:
  /// **'Declined'**
  String get callDeclined;

  /// A call cancelled before it was answered.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get callCancelled;

  /// A call that could not connect.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get callFailed;

  /// How long a call lasted.
  ///
  /// In en, this message translates to:
  /// **'{minutes, plural, =0{{seconds} s} other{{minutes} min {seconds} s}}'**
  String callDuration(int minutes, int seconds);

  /// Name shown when a call or message is from someone no longer in the contacts.
  ///
  /// In en, this message translates to:
  /// **'Unknown contact'**
  String get unknownContact;

  /// Title of the dialog with a message's delivery details, and its menu item.
  ///
  /// In en, this message translates to:
  /// **'Message details'**
  String get messageDetails;

  /// When a message was sent.
  ///
  /// In en, this message translates to:
  /// **'Sent {time}'**
  String messageSentAt(String time);

  /// When a message was received.
  ///
  /// In en, this message translates to:
  /// **'Received {time}'**
  String messageReceivedAt(String time);

  /// When a message reached the other person.
  ///
  /// In en, this message translates to:
  /// **'Delivered {time}'**
  String messageDeliveredAt(String time);

  /// When the other person read the message.
  ///
  /// In en, this message translates to:
  /// **'Read {time}'**
  String messageReadAt(String time);

  /// In a group, after a member's name: when the message reached them.
  ///
  /// In en, this message translates to:
  /// **'delivered {time}'**
  String memberDeliveredAt(String time);

  /// In a group, after a member's name: when they read the message.
  ///
  /// In en, this message translates to:
  /// **'read {time}'**
  String memberReadAt(String time);

  /// Heading over the list of network routes an outgoing message took (advanced mode).
  ///
  /// In en, this message translates to:
  /// **'Routes'**
  String get messageRoutes;

  /// Heading over the list of network routes copies of an incoming message came by (advanced mode).
  ///
  /// In en, this message translates to:
  /// **'Arrived by'**
  String get messageArrivedBy;

  /// Switch in Simple mode that brings back every settings section.
  ///
  /// In en, this message translates to:
  /// **'Show all settings'**
  String get settingsShowAll;

  /// Label of the language picker in Settings.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// Language choice that follows the device's language.
  ///
  /// In en, this message translates to:
  /// **'Same as the device'**
  String get settingsLanguageSystem;

  /// Shown under the language picker when an AI-made translation is in use. Translate naturally; keep 'Weblate'.
  ///
  /// In en, this message translates to:
  /// **'This translation was made with AI and may contain mistakes. You can help improve it on Weblate.'**
  String get settingsAiTranslated;

  /// Message menu: reply to this message.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get menuReply;

  /// Message menu: react with a thumbs-up. Keep the emoji.
  ///
  /// In en, this message translates to:
  /// **'React 👍'**
  String get menuReact;

  /// Message menu: forward to another chat.
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get menuForward;

  /// Message menu: copy the text.
  ///
  /// In en, this message translates to:
  /// **'Copy message'**
  String get menuCopyMessage;

  /// Message menu: download a received file.
  ///
  /// In en, this message translates to:
  /// **'Download attachment'**
  String get menuDownloadAttachment;

  /// Message menu: save a file to the device.
  ///
  /// In en, this message translates to:
  /// **'Save attachment'**
  String get menuSaveAttachment;

  /// Message menu: copy the picture to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy image'**
  String get menuCopyImage;

  /// Message menu: delete this device's copy of a file (it can be downloaded again).
  ///
  /// In en, this message translates to:
  /// **'Free up local space'**
  String get menuFreeUpSpace;

  /// Message menu: stop a file that is being sent or received.
  ///
  /// In en, this message translates to:
  /// **'Cancel transfer'**
  String get menuCancelTransfer;

  /// Message menu: try a failed file transfer again.
  ///
  /// In en, this message translates to:
  /// **'Retry transfer'**
  String get menuRetryTransfer;

  /// Message menu: forward the file to another chat.
  ///
  /// In en, this message translates to:
  /// **'Forward attachment'**
  String get menuForwardAttachment;

  /// Message menu: stop a message that has not gone out yet.
  ///
  /// In en, this message translates to:
  /// **'Cancel sending'**
  String get menuCancelSending;

  /// Message menu: change the text of your message.
  ///
  /// In en, this message translates to:
  /// **'Edit message'**
  String get menuEditMessage;

  /// Message menu: delete the message.
  ///
  /// In en, this message translates to:
  /// **'Delete message'**
  String get menuDeleteMessage;

  /// Menu item: change something.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get menuEdit;

  /// Menu item: delete something.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get menuDelete;

  /// Tooltip of the paperclip button in the message box.
  ///
  /// In en, this message translates to:
  /// **'Attach a file or image'**
  String get composerAttach;

  /// Tooltip: send the message later at a chosen time.
  ///
  /// In en, this message translates to:
  /// **'Schedule message'**
  String get composerSchedule;

  /// Tooltip of the send button.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get composerSend;

  /// Hint in the search box of the chat list.
  ///
  /// In en, this message translates to:
  /// **'Search chats and messages'**
  String get searchChatsAndMessages;

  /// Hint in a search box for chats.
  ///
  /// In en, this message translates to:
  /// **'Search chats'**
  String get searchChats;

  /// Hint in a search box for contacts.
  ///
  /// In en, this message translates to:
  /// **'Search contacts'**
  String get searchContacts;

  /// Entry that opens the archived chats.
  ///
  /// In en, this message translates to:
  /// **'Archived chats'**
  String get archivedChats;

  /// Tooltip of a search button.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get actionSearch;

  /// Settings section and tab: profile, look, language, privacy.
  ///
  /// In en, this message translates to:
  /// **'Personal'**
  String get settingsPersonal;

  /// Settings section and tab: space used by files.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get settingsStorage;

  /// Settings section and tab: the ways Conest reaches contacts (networks, transports). Other texts refer to it as Settings → Connectivity.
  ///
  /// In en, this message translates to:
  /// **'Connectivity'**
  String get settingsConnectivity;

  /// Settings section and tab: relay servers.
  ///
  /// In en, this message translates to:
  /// **'Relays'**
  String get settingsRelays;

  /// Settings section and tab: app updates.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get settingsUpdates;

  /// Settings section and tab: resetting or removing this identity.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get settingsAccount;

  /// Error on the first screen when the name or port is missing.
  ///
  /// In en, this message translates to:
  /// **'Enter a display name and a valid local relay port.'**
  String get onbNameRequired;

  /// Error on the first screen.
  ///
  /// In en, this message translates to:
  /// **'If you set an internet relay host, the relay port must be valid too.'**
  String get onbRelayPortInvalid;

  /// Note on the first screen on desktops.
  ///
  /// In en, this message translates to:
  /// **'Desktop nodes relay by default and advertise nearby LAN routes automatically.'**
  String get onbRelayDesktop;

  /// Note on the first screen on Android.
  ///
  /// In en, this message translates to:
  /// **'Android starts with relay mode off. Enable it in Settings only when you want this device to relay.'**
  String get onbRelayAndroid;

  /// Note on the first screen on other platforms.
  ///
  /// In en, this message translates to:
  /// **'Relay mode can be enabled in Settings when this device should help carry traffic.'**
  String get onbRelayOther;

  /// Introduction on the first screen. Keep the names Matrix, Nostr, Tor, LoRa.
  ///
  /// In en, this message translates to:
  /// **'Reach contacts directly over your network or the internet, end-to-end encrypted with forward secrecy. When the usual routes are blocked, Conest falls back to relays, Matrix, Nostr, email, Tor, LoRa radios or a Bluetooth mesh of nearby phones.'**
  String get onbTagline;

  /// Short feature label on the first screen.
  ///
  /// In en, this message translates to:
  /// **'Forward-secret chats'**
  String get onbFeatureForwardSecret;

  /// Short feature label on the first screen.
  ///
  /// In en, this message translates to:
  /// **'Direct over LAN and internet'**
  String get onbFeatureDirect;

  /// Short feature label on the first screen.
  ///
  /// In en, this message translates to:
  /// **'Tor, mesh and radio fallbacks'**
  String get onbFeatureFallbacks;

  /// Short feature label on the first screen.
  ///
  /// In en, this message translates to:
  /// **'Also a Matrix client'**
  String get onbFeatureMatrix;

  /// Heading of the form that creates the user's identity.
  ///
  /// In en, this message translates to:
  /// **'Create your first device'**
  String get onbCreateTitle;

  /// Help text above the first-screen form.
  ///
  /// In en, this message translates to:
  /// **'Only a display name is needed. The local port is for nearby (LAN) delivery and codephrase pairing. An internet relay is optional: contacts are reached over the internet without one. Turn on more routes later under Settings → Connectivity.'**
  String get onbCreateHelp;

  /// Form field: the name contacts see.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get onbDisplayName;

  /// Form field: network port for nearby delivery.
  ///
  /// In en, this message translates to:
  /// **'Local relay / LAN port'**
  String get onbLocalPort;

  /// Form field: an optional relay server address.
  ///
  /// In en, this message translates to:
  /// **'Internet relay host / URL (optional)'**
  String get onbRelayHost;

  /// Form field: the relay server's port.
  ///
  /// In en, this message translates to:
  /// **'Internet relay port'**
  String get onbRelayPort;

  /// Button that creates the identity.
  ///
  /// In en, this message translates to:
  /// **'Create encrypted device'**
  String get onbCreateButton;

  /// Button: use the app only for Matrix chats.
  ///
  /// In en, this message translates to:
  /// **'Use as a Matrix client instead'**
  String get onbMatrixInstead;

  /// Explains the Matrix-only choice.
  ///
  /// In en, this message translates to:
  /// **'Matrix chats only, with no Conest identity. You can switch to Both (Conest and Matrix side by side) later under Settings → Connectivity → App mode.'**
  String get onbMatrixHelp;

  /// Title of the dialog that creates a group.
  ///
  /// In en, this message translates to:
  /// **'Create group'**
  String get groupCreate;

  /// Field: the group's name.
  ///
  /// In en, this message translates to:
  /// **'Group title'**
  String get groupTitle;

  /// Group role: an ordinary member.
  ///
  /// In en, this message translates to:
  /// **'Member'**
  String get roleMember;

  /// Group role: can manage messages.
  ///
  /// In en, this message translates to:
  /// **'Moderator'**
  String get roleModerator;

  /// Group role: can manage the group and members.
  ///
  /// In en, this message translates to:
  /// **'Admin'**
  String get roleAdmin;

  /// Button that cancels a dialog.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// Button that creates something (a group).
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get actionCreate;

  /// The create button while it works.
  ///
  /// In en, this message translates to:
  /// **'Creating'**
  String get actionCreating;

  /// Title of the dialog, and its button, that adds a contact.
  ///
  /// In en, this message translates to:
  /// **'Add contact'**
  String get contactAdd;

  /// Field: the name you give the new contact.
  ///
  /// In en, this message translates to:
  /// **'Alias'**
  String get contactAlias;

  /// Field: the invite text (from a link or a QR code).
  ///
  /// In en, this message translates to:
  /// **'Invite payload or scanned QR'**
  String get contactInvitePayload;

  /// Button that opens the camera to scan an invite QR code.
  ///
  /// In en, this message translates to:
  /// **'Scan QR'**
  String get contactScanQr;

  /// Field: a short codephrase to find a nearby contact instead of an invite.
  ///
  /// In en, this message translates to:
  /// **'Codephrase only'**
  String get contactCodephrase;

  /// Button when an invite was pasted or scanned.
  ///
  /// In en, this message translates to:
  /// **'Trust QR / payload'**
  String get contactTrustPayload;

  /// Button when a codephrase was entered.
  ///
  /// In en, this message translates to:
  /// **'Find by codephrase'**
  String get contactFindCodephrase;

  /// Title when your invite could not be sent back to the new contact.
  ///
  /// In en, this message translates to:
  /// **'Automatic exchange failed'**
  String get contactExchangeFailed;

  /// Explains a contact added only on one side.
  ///
  /// In en, this message translates to:
  /// **'You added {alias}, but your invite could not be sent back automatically. Ask the other user to scan or enter your invite from their side, or abort and remove this one-sided contact now.'**
  String contactExchangeFailedBody(String alias);

  /// Button: undo what was just done.
  ///
  /// In en, this message translates to:
  /// **'Abort'**
  String get actionAbort;

  /// Button: keep the one-sided contact.
  ///
  /// In en, this message translates to:
  /// **'Keep Contact'**
  String get contactKeep;

  /// App-owned interface/status text in lib/main.dart:700. English: Passphrase
  ///
  /// In en, this message translates to:
  /// **'Passphrase'**
  String get uiPassphrase89950C;

  /// App-owned interface/status text in lib/main.dart:709. English: Confirm passphrase
  ///
  /// In en, this message translates to:
  /// **'Confirm passphrase'**
  String get uiConfirmPassphraseEBAAC0;

  /// App-owned interface/status text in lib/main.dart:851. English: Unlock
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get uiUnlock1526A1;

  /// App-owned interface/status text in lib/main.dart:1161. English: Update Available
  ///
  /// In en, this message translates to:
  /// **'Update Available'**
  String get uiUpdateAvailable67FD3A;

  /// App-owned interface/status text in lib/main.dart:1230. English: Later
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get uiLater56E2F5;

  /// App-owned interface/status text in lib/main.dart:1453. English: host auto-detects TCP/UDP; udp://host:port forces UDP
  ///
  /// In en, this message translates to:
  /// **'host auto-detects TCP/UDP; udp://host:port forces UDP'**
  String get uiHostAutoDetectsTCPUDP663D30;

  /// App-owned interface/status text in lib/main.dart:1598. English: Verification request
  ///
  /// In en, this message translates to:
  /// **'Verification request'**
  String get uiVerificationRequestDA06F9;

  /// App-owned interface/status text in lib/main.dart:1611. English: Ignore
  ///
  /// In en, this message translates to:
  /// **'Ignore'**
  String get uiIgnore98F55D;

  /// App-owned interface/status text in lib/main.dart:1615. English: Verify
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get uiVerifyDDA6AC;

  /// App-owned interface/status text in lib/main.dart:1756. English: Could not read {value}: {value2}
  ///
  /// In en, this message translates to:
  /// **'Could not read {value}: {value2}'**
  String uiCouldNotReadValueValue695755(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:1775. English: Could not share {value}: {value2}
  ///
  /// In en, this message translates to:
  /// **'Could not share {value}: {value2}'**
  String uiCouldNotShareValueValue7BA3A3(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:1871. English: Could not save sidebar width: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not save sidebar width: {value}'**
  String uiCouldNotSaveSidebarWidthB4DACB(String value);

  /// App-owned interface/status text in lib/main.dart:1894. English: No audio output devices were found.
  ///
  /// In en, this message translates to:
  /// **'No audio output devices were found.'**
  String get uiNoAudioOutputDevicesWere17E473;

  /// App-owned interface/status text in lib/main.dart:1900. English: Call audio output
  ///
  /// In en, this message translates to:
  /// **'Call audio output'**
  String get uiCallAudioOutput0C276F;

  /// App-owned interface/status text in lib/main.dart:1924. English: Call audio routed to {value}.
  ///
  /// In en, this message translates to:
  /// **'Call audio routed to {value}.'**
  String uiCallAudioRoutedToValueFFFBE8(String value);

  /// App-owned interface/status text in lib/main.dart:1926. English: Could not change call audio output: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not change call audio output: {value}'**
  String uiCouldNotChangeCallAudio6CE7B1(String value);

  /// App-owned interface/status text in lib/main.dart:2047. English: Could not open invite: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not open invite: {value}'**
  String uiCouldNotOpenInviteValue6C4D06(String value);

  /// App-owned interface/status text in lib/main.dart:2270. English: Could not send attachment: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not send attachment: {value}'**
  String uiCouldNotSendAttachmentValueEFF771(String value);

  /// App-owned interface/status text in lib/main.dart:2285. English: Could not send message: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not send message: {value}'**
  String uiCouldNotSendMessageValue042C4F(String value);

  /// App-owned interface/status text in lib/main.dart:2325. English: Send from original
  ///
  /// In en, this message translates to:
  /// **'Send from original'**
  String get uiSendFromOriginalFFF29A;

  /// App-owned interface/status text in lib/main.dart:2348. English: Could not send group message: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not send group message: {value}'**
  String uiCouldNotSendGroupMessageB6C7D1(String value);

  /// App-owned interface/status text in lib/main.dart:2362. English: Could not send LAN lobby message: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not send LAN lobby message: {value}'**
  String uiCouldNotSendLANLobby8E7487(String value);

  /// App-owned interface/status text in lib/main.dart:2393. English: Could not stage {value}: pathless drops are limited to 8 MB to protect memory.
  ///
  /// In en, this message translates to:
  /// **'Could not stage {value}: pathless drops are limited to 8 MB to protect memory.'**
  String uiCouldNotStageValuePathless514094(String value);

  /// App-owned interface/status text in lib/main.dart:2591. English: Select a group before dropping files.
  ///
  /// In en, this message translates to:
  /// **'Select a group before dropping files.'**
  String get uiSelectAGroupBeforeDropping9DAB4C;

  /// App-owned interface/status text in lib/main.dart:2599. English: {value}: local file path unavailable.
  ///
  /// In en, this message translates to:
  /// **'{value}: local file path unavailable.'**
  String uiValueLocalFilePathUnavailable217177(String value);

  /// App-owned interface/status text in lib/main.dart:2696. English: {value} Sent without it.
  ///
  /// In en, this message translates to:
  /// **'{value} Sent without it.'**
  String uiValueSentWithoutIt7E0635(String value);

  /// App-owned interface/status text in lib/main.dart:2804. English: Group file scheduled.
  ///
  /// In en, this message translates to:
  /// **'Group file scheduled.'**
  String get uiGroupFileScheduledB1DC66;

  /// App-owned interface/status text in lib/main.dart:2806. English: Could not schedule {value}: {value2}
  ///
  /// In en, this message translates to:
  /// **'Could not schedule {value}: {value2}'**
  String uiCouldNotScheduleValueValue25CED3(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:2823. English: Could not open file picker: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not open file picker: {value}'**
  String uiCouldNotOpenFilePicker8FF0C0(String value);

  /// App-owned interface/status text in lib/main.dart:2844. English: {value}: picker returned no data.
  ///
  /// In en, this message translates to:
  /// **'{value}: picker returned no data.'**
  String uiValuePickerReturnedNoData4670CA(String value);

  /// App-owned interface/status text in lib/main.dart:2912. English: Only the first {value} files will be staged (got {value2}).
  ///
  /// In en, this message translates to:
  /// **'Only the first {value} files will be staged (got {value2}).'**
  String uiOnlyTheFirstValueFiles45FC47(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:2923. English: {value} skipped: {value2} MB exceeds the {value} MB cap.
  ///
  /// In en, this message translates to:
  /// **'{value} skipped: {value2} MB exceeds the {value} MB cap.'**
  String uiValueSkippedValueMBExceeds487B2A(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:3066. English: Transfers
  ///
  /// In en, this message translates to:
  /// **'Transfers'**
  String get uiTransfers812412;

  /// App-owned interface/status text in lib/main.dart:3458. English: {value}
  ///
  /// In en, this message translates to:
  /// **'{value}'**
  String uiValue75CED7(String value);

  /// App-owned interface/status text in lib/main.dart:3511. English: Preparing call…
  ///
  /// In en, this message translates to:
  /// **'Preparing call…'**
  String get uiPreparingCallE86D6C;

  /// App-owned interface/status text in lib/main.dart:3513. English: Calling…
  ///
  /// In en, this message translates to:
  /// **'Calling…'**
  String get uiCallingACD4A6;

  /// App-owned interface/status text in lib/main.dart:3514. English: Incoming voice call
  ///
  /// In en, this message translates to:
  /// **'Incoming voice call'**
  String get uiIncomingVoiceCallF68FD3;

  /// App-owned interface/status text in lib/main.dart:3515. English: Connecting…
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get uiConnectingFD3E79;

  /// App-owned interface/status text in lib/main.dart:3517. English: Reconnecting…
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get uiReconnecting8A8B95;

  /// App-owned interface/status text in lib/main.dart:3518. English: Call ended
  ///
  /// In en, this message translates to:
  /// **'Call ended'**
  String get uiCallEnded9933A4;

  /// App-owned interface/status text in lib/main.dart:3529. English: Voice call: {value}
  ///
  /// In en, this message translates to:
  /// **'Voice call: {value}'**
  String uiVoiceCallValue06FE1F(String value);

  /// App-owned interface/status text in lib/main.dart:3559. English: Minimize call
  ///
  /// In en, this message translates to:
  /// **'Minimize call'**
  String get uiMinimizeCall6CB0F0;

  /// App-owned interface/status text in lib/main.dart:3606. English: Accept
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get uiAcceptBB54DB;

  /// App-owned interface/status text in lib/main.dart:3614. English: Reject
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get uiReject2B03B5;

  /// App-owned interface/status text in lib/main.dart:3628. English: Noise suppression
  ///
  /// In en, this message translates to:
  /// **'Noise suppression'**
  String get uiNoiseSuppression71DE3C;

  /// App-owned interface/status text in lib/main.dart:3663. English: Audio output
  ///
  /// In en, this message translates to:
  /// **'Audio output'**
  String get uiAudioOutput2B89CC;

  /// App-owned interface/status text in lib/main.dart:3669. English: Done
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get uiDoneE9B450;

  /// App-owned interface/status text in lib/main.dart:3739. English: Hang up
  ///
  /// In en, this message translates to:
  /// **'Hang up'**
  String get uiHangUp66BE99;

  /// App-owned interface/status text in lib/main.dart:3790. English: Close details
  ///
  /// In en, this message translates to:
  /// **'Close details'**
  String get uiCloseDetails433DA6;

  /// App-owned interface/status text in lib/main.dart:3848. English: Open full profile
  ///
  /// In en, this message translates to:
  /// **'Open full profile'**
  String get uiOpenFullProfile35063C;

  /// App-owned interface/status text in lib/main.dart:3953. English: Open group settings
  ///
  /// In en, this message translates to:
  /// **'Open group settings'**
  String get uiOpenGroupSettings0B568E;

  /// App-owned interface/status text in lib/main.dart:4116. English: New folder
  ///
  /// In en, this message translates to:
  /// **'New folder'**
  String get uiNewFolderA71199;

  /// App-owned interface/status text in lib/main.dart:4121. English: Folder name
  ///
  /// In en, this message translates to:
  /// **'Folder name'**
  String get uiFolderNameB2CE02;

  /// App-owned interface/status text in lib/main.dart:4176. English: Move earlier
  ///
  /// In en, this message translates to:
  /// **'Move earlier'**
  String get uiMoveEarlier07DD6F;

  /// App-owned interface/status text in lib/main.dart:4182. English: Move later
  ///
  /// In en, this message translates to:
  /// **'Move later'**
  String get uiMoveLaterBB4C84;

  /// Button that saves changes, including the name shown to nearby bitchat users.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get uiSaveEFC007;

  /// App-owned interface/status text in lib/main.dart:4310. English: Add to folder
  ///
  /// In en, this message translates to:
  /// **'Add to folder'**
  String get uiAddToFolderBFAD96;

  /// App-owned interface/status text in lib/main.dart:4684. English: New message
  ///
  /// In en, this message translates to:
  /// **'New message'**
  String get uiNewMessage1ED2E7;

  /// App-owned interface/status text in lib/main.dart:4697. English: Back to chats
  ///
  /// In en, this message translates to:
  /// **'Back to chats'**
  String get uiBackToChats8DE6F6;

  /// App-owned interface/status text in lib/main.dart:4697. English: Navigation menu
  ///
  /// In en, this message translates to:
  /// **'Navigation menu'**
  String get uiNavigationMenu6609F1;

  /// App-owned interface/status text in lib/main.dart:4756. English: All chats
  ///
  /// In en, this message translates to:
  /// **'All chats'**
  String get uiAllChats398E5B;

  /// App-owned interface/status text in lib/main.dart:4799. English: Search all chats
  ///
  /// In en, this message translates to:
  /// **'Search all chats'**
  String get uiSearchAllChatsC825C8;

  /// App-owned interface/status text in lib/main.dart:4815. English: Clear search
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get uiClearSearch67300D;

  /// App-owned interface/status text in lib/main.dart:4841. English: Contact requests
  ///
  /// In en, this message translates to:
  /// **'Contact requests'**
  String get uiContactRequests082691;

  /// App-owned interface/status text in lib/main.dart:4842. English: Review people who want to connect
  ///
  /// In en, this message translates to:
  /// **'Review people who want to connect'**
  String get uiReviewPeopleWhoWantTo24A8CB;

  /// App-owned interface/status text in lib/main.dart:4881. English: No chats found
  ///
  /// In en, this message translates to:
  /// **'No chats found'**
  String get uiNoChatsFoundC6BD82;

  /// App-owned interface/status text in lib/main.dart:4883. English: No archived chats
  ///
  /// In en, this message translates to:
  /// **'No archived chats'**
  String get uiNoArchivedChatsEAE7F0;

  /// App-owned interface/status text in lib/main.dart:4885. English: No Matrix chats yet
  ///
  /// In en, this message translates to:
  /// **'No Matrix chats yet'**
  String get uiNoMatrixChatsYet23B023;

  /// App-owned interface/status text in lib/main.dart:5011. English: New group
  ///
  /// In en, this message translates to:
  /// **'New group'**
  String get uiNewGroupF9850C;

  /// App-owned interface/status text in lib/main.dart:5021. English: Add with Conest Beam
  ///
  /// In en, this message translates to:
  /// **'Add with Conest Beam'**
  String get uiAddWithConestBeam19D1E2;

  /// App-owned interface/status text in lib/main.dart:5476. English: Direct messages
  ///
  /// In en, this message translates to:
  /// **'Direct messages'**
  String get uiDirectMessagesE7596A;

  /// App-owned interface/status text in lib/main.dart:5538. English: Conest Beam
  ///
  /// In en, this message translates to:
  /// **'Conest Beam'**
  String get uiConestBeamE98B77;

  /// App-owned interface/status text in lib/main.dart:5543. English: My invite
  ///
  /// In en, this message translates to:
  /// **'My invite'**
  String get uiMyInviteF80A7A;

  /// App-owned interface/status text in lib/main.dart:5635. English: Group details
  ///
  /// In en, this message translates to:
  /// **'Group details'**
  String get uiGroupDetailsDF844A;

  /// App-owned interface/status text in lib/main.dart:6025. English: Debug
  ///
  /// In en, this message translates to:
  /// **'Debug'**
  String get uiDebugBD604D;

  /// App-owned interface/status text in lib/main.dart:6084. English: Add
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get uiAdd61CC55;

  /// App-owned interface/status text in lib/main.dart:6102. English: Poll routes now
  ///
  /// In en, this message translates to:
  /// **'Poll routes now'**
  String get uiPollRoutesNow22318F;

  /// App-owned interface/status text in lib/main.dart:6435. English: Contact profile
  ///
  /// In en, this message translates to:
  /// **'Contact profile'**
  String get uiContactProfile1B3A0E;

  /// App-owned interface/status text in lib/main.dart:6694. English: History for new members
  ///
  /// In en, this message translates to:
  /// **'History for new members'**
  String get uiHistoryForNewMembersF419F2;

  /// App-owned interface/status text in lib/main.dart:6803. English: Choose how to wind down this group. Transferring ownership keeps the group alive under a new owner and demotes you to admin. Deleting for everyone removes the group from every member's list and cannot be undone.
  ///
  /// In en, this message translates to:
  /// **'Choose how to wind down this group. Transferring ownership keeps the group alive under a new owner and demotes you to admin. Deleting for everyone removes the group from every member\'s list and cannot be undone.'**
  String get uiChooseHowToWindDownF7399D;

  /// App-owned interface/status text in lib/main.dart:6817. English: Transfer ownership…
  ///
  /// In en, this message translates to:
  /// **'Transfer ownership…'**
  String get uiTransferOwnershipA563C9;

  /// App-owned interface/status text in lib/main.dart:6826. English: Delete for everyone
  ///
  /// In en, this message translates to:
  /// **'Delete for everyone'**
  String get uiDeleteForEveryoneE055A8;

  /// App-owned interface/status text in lib/main.dart:6851. English: No other active members to transfer ownership to.
  ///
  /// In en, this message translates to:
  /// **'No other active members to transfer ownership to.'**
  String get uiNoOtherActiveMembersToF9DE12;

  /// App-owned interface/status text in lib/main.dart:6861. English: Transfer ownership
  ///
  /// In en, this message translates to:
  /// **'Transfer ownership'**
  String get uiTransferOwnershipA6819E;

  /// App-owned interface/status text in lib/main.dart:6894. English: Transfer
  ///
  /// In en, this message translates to:
  /// **'Transfer'**
  String get uiTransferCBB4CC;

  /// App-owned interface/status text in lib/main.dart:6910. English: Ownership transferred to {value}.
  ///
  /// In en, this message translates to:
  /// **'Ownership transferred to {value}.'**
  String uiOwnershipTransferredToValue14A10D(String value);

  /// App-owned interface/status text in lib/main.dart:6926. English: Every member will be removed from the group and the group will be marked left in each member's list. Local message history is not deleted automatically — each member can clear it via Remove from list. This cannot be undone.
  ///
  /// In en, this message translates to:
  /// **'Every member will be removed from the group and the group will be marked left in each member\'s list. Local message history is not deleted automatically — each member can clear it via Remove from list. This cannot be undone.'**
  String get uiEveryMemberWillBeRemoved75A3FC;

  /// App-owned interface/status text in lib/main.dart:6964. English: Remove this group?
  ///
  /// In en, this message translates to:
  /// **'Remove this group?'**
  String get uiRemoveThisGroup38C4E8;

  /// App-owned interface/status text in lib/main.dart:6966. English: Remove this group from your list? This deletes the local message history. Other members will not be notified — they already see you as having left.
  ///
  /// In en, this message translates to:
  /// **'Remove this group from your list? This deletes the local message history. Other members will not be notified — they already see you as having left.'**
  String get uiRemoveThisGroupFromYourDA7898;

  /// App-owned interface/status text in lib/main.dart:6981. English: Remove
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get uiRemoveE96390;

  /// App-owned interface/status text in lib/main.dart:7022. English: Change role
  ///
  /// In en, this message translates to:
  /// **'Change role'**
  String get uiChangeRole2B9BFD;

  /// App-owned interface/status text in lib/main.dart:7042. English: Remove member
  ///
  /// In en, this message translates to:
  /// **'Remove member'**
  String get uiRemoveMember1C31D1;

  /// App-owned interface/status text in lib/main.dart:7107. English: Choose what future members can catch up on
  ///
  /// In en, this message translates to:
  /// **'Choose what future members can catch up on'**
  String get uiChooseWhatFutureMembersCanC38992;

  /// App-owned interface/status text in lib/main.dart:7159. English: Add member
  ///
  /// In en, this message translates to:
  /// **'Add member'**
  String get uiAddMember170AD0;

  /// App-owned interface/status text in lib/main.dart:7176. English: Delete group…
  ///
  /// In en, this message translates to:
  /// **'Delete group…'**
  String get uiDeleteGroup043336;

  /// App-owned interface/status text in lib/main.dart:7184. English: Leave
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get uiLeave7E3520;

  /// App-owned interface/status text in lib/main.dart:7195. English: Remove from list
  ///
  /// In en, this message translates to:
  /// **'Remove from list'**
  String get uiRemoveFromList23A976;

  /// App-owned interface/status text in lib/main.dart:7232. English: Forward message
  ///
  /// In en, this message translates to:
  /// **'Forward message'**
  String get uiForwardMessage482959;

  /// App-owned interface/status text in lib/main.dart:7262. English: Saved messages
  ///
  /// In en, this message translates to:
  /// **'Saved messages'**
  String get uiSavedMessagesC0FA7E;

  /// App-owned interface/status text in lib/main.dart:7337. English: This attachment is not available locally yet.
  ///
  /// In en, this message translates to:
  /// **'This attachment is not available locally yet.'**
  String get uiThisAttachmentIsNotAvailableFE641A;

  /// App-owned interface/status text in lib/main.dart:7364. English: Download this file before forwarding it.
  ///
  /// In en, this message translates to:
  /// **'Download this file before forwarding it.'**
  String get uiDownloadThisFileBeforeForwarding60D7B5;

  /// App-owned interface/status text in lib/main.dart:7595. English: Search messages
  ///
  /// In en, this message translates to:
  /// **'Search messages'**
  String get uiSearchMessagesABEA65;

  /// App-owned interface/status text in lib/main.dart:7601. English: Start voice call (experimental)
  ///
  /// In en, this message translates to:
  /// **'Start voice call (experimental)'**
  String get uiStartVoiceCallExperimental6DE320;

  /// App-owned interface/status text in lib/main.dart:7606. English: Chat options
  ///
  /// In en, this message translates to:
  /// **'Chat options'**
  String get uiChatOptionsA40D0F;

  /// App-owned interface/status text in lib/main.dart:7756. English: Pause preview
  ///
  /// In en, this message translates to:
  /// **'Pause preview'**
  String get uiPausePreview805180;

  /// App-owned interface/status text in lib/main.dart:7756. English: Play preview
  ///
  /// In en, this message translates to:
  /// **'Play preview'**
  String get uiPlayPreview47BB44;

  /// App-owned interface/status text in lib/main.dart:7776. English: Unmute preview
  ///
  /// In en, this message translates to:
  /// **'Unmute preview'**
  String get uiUnmutePreview12A31A;

  /// App-owned interface/status text in lib/main.dart:7776. English: Mute preview
  ///
  /// In en, this message translates to:
  /// **'Mute preview'**
  String get uiMutePreviewCE44BD;

  /// App-owned interface/status text in lib/main.dart:7838. English: Pause voice message
  ///
  /// In en, this message translates to:
  /// **'Pause voice message'**
  String get uiPauseVoiceMessageECD12D;

  /// App-owned interface/status text in lib/main.dart:7839. English: Play voice message
  ///
  /// In en, this message translates to:
  /// **'Play voice message'**
  String get uiPlayVoiceMessageB16684;

  /// App-owned interface/status text in lib/main.dart:7869. English: Playback speed
  ///
  /// In en, this message translates to:
  /// **'Playback speed'**
  String get uiPlaybackSpeed6FF42B;

  /// App-owned interface/status text in lib/main.dart:7986. English: Stop recording
  ///
  /// In en, this message translates to:
  /// **'Stop recording'**
  String get uiStopRecordingEE0D9D;

  /// App-owned interface/status text in lib/main.dart:7991. English: Delete recording
  ///
  /// In en, this message translates to:
  /// **'Delete recording'**
  String get uiDeleteRecording8B58CE;

  /// App-owned interface/status text in lib/main.dart:8129. English: Could not load older group history: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not load older group history: {value}'**
  String uiCouldNotLoadOlderGroup1A192E(String value);

  /// App-owned interface/status text in lib/main.dart:8189. English: Message scheduled for {value}.
  ///
  /// In en, this message translates to:
  /// **'Message scheduled for {value}.'**
  String uiMessageScheduledForValueD2D788(String value);

  /// App-owned interface/status text in lib/main.dart:8302. English: New poll
  ///
  /// In en, this message translates to:
  /// **'New poll'**
  String get uiNewPoll6D62BD;

  /// App-owned interface/status text in lib/main.dart:8308. English: Question
  ///
  /// In en, this message translates to:
  /// **'Question'**
  String get uiQuestion002FF5;

  /// App-owned interface/status text in lib/main.dart:8315. English: Options (one per line)
  ///
  /// In en, this message translates to:
  /// **'Options (one per line)'**
  String get uiOptionsOnePerLine62FF3D;

  /// App-owned interface/status text in lib/main.dart:8374. English: Delete message?
  ///
  /// In en, this message translates to:
  /// **'Delete message?'**
  String get uiDeleteMessageD536CF;

  /// App-owned interface/status text in lib/main.dart:8524. English: Delete selected messages?
  ///
  /// In en, this message translates to:
  /// **'Delete selected messages?'**
  String get uiDeleteSelectedMessages190A5F;

  /// App-owned interface/status text in lib/main.dart:8550. English: Delete failed for one message: {value}
  ///
  /// In en, this message translates to:
  /// **'Delete failed for one message: {value}'**
  String uiDeleteFailedForOneMessage26C302(String value);

  /// App-owned interface/status text in lib/main.dart:8573. English: Nothing to copy from the selected messages.
  ///
  /// In en, this message translates to:
  /// **'Nothing to copy from the selected messages.'**
  String get uiNothingToCopyFromTheEC27E3;

  /// App-owned interface/status text in lib/main.dart:8577. English: Copied {value} message(s).
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{Copied {value} message.} other{Copied {value} messages.}}'**
  String uiCopiedValueMessageSC97E6E(int value);

  /// App-owned interface/status text in lib/main.dart:8590. English: No selected attachment is ready yet — still transferring.
  ///
  /// In en, this message translates to:
  /// **'No selected attachment is ready yet — still transferring.'**
  String get uiNoSelectedAttachmentIsReady536B54;

  /// App-owned interface/status text in lib/main.dart:8738. English: Copied message text.
  ///
  /// In en, this message translates to:
  /// **'Copied message text.'**
  String get uiCopiedMessageText9DC18F;

  /// App-owned interface/status text in lib/main.dart:8745. English: The group file is not available locally.
  ///
  /// In en, this message translates to:
  /// **'The group file is not available locally.'**
  String get uiTheGroupFileIsNotF8A236;

  /// App-owned interface/status text in lib/main.dart:8773. English: Saved {value}.
  ///
  /// In en, this message translates to:
  /// **'Saved {value}.'**
  String uiSavedValue0463E5(String value);

  /// App-owned interface/status text in lib/main.dart:8777. English: Could not save {value}: {value2}
  ///
  /// In en, this message translates to:
  /// **'Could not save {value}: {value2}'**
  String uiCouldNotSaveValueValue178005(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:8780. English: The Android file saver is unavailable.
  ///
  /// In en, this message translates to:
  /// **'The Android file saver is unavailable.'**
  String get uiTheAndroidFileSaverIsDF910B;

  /// App-owned interface/status text in lib/main.dart:8791. English: Opening files is unavailable on this platform.
  ///
  /// In en, this message translates to:
  /// **'Opening files is unavailable on this platform.'**
  String get uiOpeningFilesIsUnavailableOnC6ADA2;

  /// App-owned interface/status text in lib/main.dart:8794. English: Could not open {value}: {value2}
  ///
  /// In en, this message translates to:
  /// **'Could not open {value}: {value2}'**
  String uiCouldNotOpenValueValue283326(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:8800. English: You
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get uiYou905CB3;

  /// App-owned interface/status text in lib/main.dart:8812. English: Message
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get uiMessage68F414;

  /// App-owned interface/status text in lib/main.dart:9171. English: Message actions
  ///
  /// In en, this message translates to:
  /// **'Message actions'**
  String get uiMessageActions949184;

  /// App-owned interface/status text in lib/main.dart:9218. English: The attachment is still downloading.
  ///
  /// In en, this message translates to:
  /// **'The attachment is still downloading.'**
  String get uiTheAttachmentIsStillDownloadingF77317;

  /// App-owned interface/status text in lib/main.dart:9633. English: Share or schedule a group file
  ///
  /// In en, this message translates to:
  /// **'Share or schedule a group file'**
  String get uiShareOrScheduleAGroup2989F0;

  /// App-owned interface/status text in lib/main.dart:9704. English: Recording belongs to another conversation
  ///
  /// In en, this message translates to:
  /// **'Recording belongs to another conversation'**
  String get uiRecordingBelongsToAnotherConversation87E802;

  /// App-owned interface/status text in lib/main.dart:9706. English: Finish the voice preview in its original chat
  ///
  /// In en, this message translates to:
  /// **'Finish the voice preview in its original chat'**
  String get uiFinishTheVoicePreviewIn142571;

  /// App-owned interface/status text in lib/main.dart:9708. English: Review unsent voice message
  ///
  /// In en, this message translates to:
  /// **'Review unsent voice message'**
  String get uiReviewUnsentVoiceMessage24931C;

  /// App-owned interface/status text in lib/main.dart:9710. English: Cancel microphone startup
  ///
  /// In en, this message translates to:
  /// **'Cancel microphone startup'**
  String get uiCancelMicrophoneStartup9E9F8A;

  /// App-owned interface/status text in lib/main.dart:9712. English: Release to discard recording
  ///
  /// In en, this message translates to:
  /// **'Release to discard recording'**
  String get uiReleaseToDiscardRecording4C5C71;

  /// App-owned interface/status text in lib/main.dart:9714. English: Recording locked · tap to finish
  ///
  /// In en, this message translates to:
  /// **'Recording locked · tap to finish'**
  String get uiRecordingLockedTapToFinish40CD88;

  /// App-owned interface/status text in lib/main.dart:9716. English: Release to stop · slide left to cancel · slide up to lock
  ///
  /// In en, this message translates to:
  /// **'Release to stop · slide left to cancel · slide up to lock'**
  String get uiReleaseToStopSlideLeft4686F1;

  /// App-owned interface/status text in lib/main.dart:9717. English: Hold to record a group voice message
  ///
  /// In en, this message translates to:
  /// **'Hold to record a group voice message'**
  String get uiHoldToRecordAGroupC11B32;

  /// App-owned interface/status text in lib/main.dart:9746. English: Create poll
  ///
  /// In en, this message translates to:
  /// **'Create poll'**
  String get uiCreatePoll8F5663;

  /// App-owned interface/status text in lib/main.dart:9785. English: Write to group
  ///
  /// In en, this message translates to:
  /// **'Write to group'**
  String get uiWriteToGroup5878DB;

  /// App-owned interface/status text in lib/main.dart:9786. English: Write a reply
  ///
  /// In en, this message translates to:
  /// **'Write a reply'**
  String get uiWriteAReply0A58E1;

  /// App-owned interface/status text in lib/main.dart:9787. English: You are no longer in this group
  ///
  /// In en, this message translates to:
  /// **'You are no longer in this group'**
  String get uiYouAreNoLongerIn571DA7;

  /// App-owned interface/status text in lib/main.dart:9932. English: Vote
  ///
  /// In en, this message translates to:
  /// **'Vote'**
  String get uiVote64F872;

  /// App-owned interface/status text in lib/main.dart:10034. English: Choose options
  ///
  /// In en, this message translates to:
  /// **'Choose options'**
  String get uiChooseOptionsEA120E;

  /// App-owned interface/status text in lib/main.dart:10057. English: Retract vote
  ///
  /// In en, this message translates to:
  /// **'Retract vote'**
  String get uiRetractVoteA5DA11;

  /// App-owned interface/status text in lib/main.dart:10094. English: Close poll
  ///
  /// In en, this message translates to:
  /// **'Close poll'**
  String get uiClosePollA6A189;

  /// App-owned interface/status text in lib/main.dart:10180. English: Schedule one attachment at a time.
  ///
  /// In en, this message translates to:
  /// **'Schedule one attachment at a time.'**
  String get uiScheduleOneAttachmentAtAC580C3;

  /// App-owned interface/status text in lib/main.dart:10988. English: Not delivered yet. Send via Matrix…
  ///
  /// In en, this message translates to:
  /// **'Not delivered yet. Send via Matrix…'**
  String get uiNotDeliveredYetSendViaF056E1;

  /// App-owned interface/status text in lib/main.dart:11298. English: Voice calls are turned off. Enable them in Settings to call.
  ///
  /// In en, this message translates to:
  /// **'Voice calls are turned off. Enable them in Settings to call.'**
  String get uiVoiceCallsAreTurnedOff692843;

  /// App-owned interface/status text in lib/main.dart:11305. English: Voice-call audio is unavailable in this build.
  ///
  /// In en, this message translates to:
  /// **'Voice-call audio is unavailable in this build.'**
  String get uiVoiceCallAudioIsUnavailable0B6C43;

  /// App-owned interface/status text in lib/main.dart:11378. English: Route inspector
  ///
  /// In en, this message translates to:
  /// **'Route inspector'**
  String get uiRouteInspector0E65DE;

  /// App-owned interface/status text in lib/main.dart:11630. English: This contact request is blocked.
  ///
  /// In en, this message translates to:
  /// **'This contact request is blocked.'**
  String get uiThisContactRequestIsBlocked944F7D;

  /// App-owned interface/status text in lib/main.dart:11632. English: Message saved here until the contact accepts.
  ///
  /// In en, this message translates to:
  /// **'Message saved here until the contact accepts.'**
  String get uiMessageSavedHereUntilTheA49A2C;

  /// App-owned interface/status text in lib/main.dart:11636. English: Write an encrypted message
  ///
  /// In en, this message translates to:
  /// **'Write an encrypted message'**
  String get uiWriteAnEncryptedMessage9F7705;

  /// App-owned interface/status text in lib/main.dart:11637. English: Write a reply or add a caption
  ///
  /// In en, this message translates to:
  /// **'Write a reply or add a caption'**
  String get uiWriteAReplyOrAddFC0A42;

  /// App-owned interface/status text in lib/main.dart:11717. English: Hold to record a voice message
  ///
  /// In en, this message translates to:
  /// **'Hold to record a voice message'**
  String get uiHoldToRecordAVoice06B1B5;

  /// App-owned interface/status text in lib/main.dart:12081. English: Write to nearby LAN users
  ///
  /// In en, this message translates to:
  /// **'Write to nearby LAN users'**
  String get uiWriteToNearbyLANUsers291142;

  /// App-owned interface/status text in lib/main.dart:12090. English: Broadcast
  ///
  /// In en, this message translates to:
  /// **'Broadcast'**
  String get uiBroadcast77CA3F;

  /// App-owned interface/status text in lib/main.dart:12254. English: This removes the local contact and message history. The app will also try to send a removal notice so this contact disappears on the other side.
  ///
  /// In en, this message translates to:
  /// **'This removes the local contact and message history. The app will also try to send a removal notice so this contact disappears on the other side.'**
  String get uiThisRemovesTheLocalContact0D6D1E;

  /// App-owned interface/status text in lib/main.dart:12324. English: Description / bio
  ///
  /// In en, this message translates to:
  /// **'Description / bio'**
  String get uiDescriptionBio505243;

  /// App-owned interface/status text in lib/main.dart:12366. English: Check Paths
  ///
  /// In en, this message translates to:
  /// **'Check Paths'**
  String get uiCheckPaths917FF3;

  /// App-owned interface/status text in lib/main.dart:12374. English: Copy State
  ///
  /// In en, this message translates to:
  /// **'Copy State'**
  String get uiCopyState9BFD16;

  /// App-owned interface/status text in lib/main.dart:12426. English: Remove Contact
  ///
  /// In en, this message translates to:
  /// **'Remove Contact'**
  String get uiRemoveContact7F9A8A;

  /// App-owned interface/status text in lib/main.dart:12434. English: Save Profile
  ///
  /// In en, this message translates to:
  /// **'Save Profile'**
  String get uiSaveProfile909BF3;

  /// App-owned interface/status text in lib/main.dart:12924. English: Show as Beam
  ///
  /// In en, this message translates to:
  /// **'Show as Beam'**
  String get uiShowAsBeam74375F;

  /// App-owned interface/status text in lib/main.dart:12929. English: Show the QR anyway
  ///
  /// In en, this message translates to:
  /// **'Show the QR anyway'**
  String get uiShowTheQRAnyway0B0CDF;

  /// App-owned interface/status text in lib/main.dart:12977. English: Open Fullscreen QR
  ///
  /// In en, this message translates to:
  /// **'Open Fullscreen QR'**
  String get uiOpenFullscreenQRC5418D;

  /// App-owned interface/status text in lib/main.dart:13023. English: Show QR
  ///
  /// In en, this message translates to:
  /// **'Show QR'**
  String get uiShowQRCFBAC6;

  /// App-owned interface/status text in lib/main.dart:13076. English: Legacy invite
  ///
  /// In en, this message translates to:
  /// **'Legacy invite'**
  String get uiLegacyInviteC61C5D;

  /// App-owned interface/status text in lib/main.dart:13078. English: For contacts on Conest 0.3.11 or older. It leaves out your routes for blocked networks; they arrive once you are connected.
  ///
  /// In en, this message translates to:
  /// **'For contacts on Conest 0.3.11 or older. It leaves out your routes for blocked networks; they arrive once you are connected.'**
  String get uiForContactsOnConestOr486754;

  /// App-owned interface/status text in lib/main.dart:13098. English: Rotate Codephrase Now
  ///
  /// In en, this message translates to:
  /// **'Rotate Codephrase Now'**
  String get uiRotateCodephraseNow89B2D5;

  /// App-owned interface/status text in lib/main.dart:13205. English: Encrypt for contact
  ///
  /// In en, this message translates to:
  /// **'Encrypt for contact'**
  String get uiEncryptForContactE07450;

  /// App-owned interface/status text in lib/main.dart:13239. English: Public optical transfer
  ///
  /// In en, this message translates to:
  /// **'Public optical transfer'**
  String get uiPublicOpticalTransfer58E3F4;

  /// App-owned interface/status text in lib/main.dart:13241. English: Anyone who can see the display may reconstruct this file. It is signed for integrity but it is not confidential.
  ///
  /// In en, this message translates to:
  /// **'Anyone who can see the display may reconstruct this file. It is signed for integrity but it is not confidential.'**
  String get uiAnyoneWhoCanSeeTheFAB2D0;

  /// App-owned interface/status text in lib/main.dart:13251. English: Choose public file
  ///
  /// In en, this message translates to:
  /// **'Choose public file'**
  String get uiChoosePublicFile6E2739;

  /// App-owned interface/status text in lib/main.dart:13521. English: Keep this screen visible until the receiver reports 100%.
  ///
  /// In en, this message translates to:
  /// **'Keep this screen visible until the receiver reports 100%.'**
  String get uiKeepThisScreenVisibleUntil2261B8;

  /// App-owned interface/status text in lib/main.dart:13705. English: Receive Conest Beam
  ///
  /// In en, this message translates to:
  /// **'Receive Conest Beam'**
  String get uiReceiveConestBeamB05BCB;

  /// App-owned interface/status text in lib/main.dart:13731. English: Desktop camera active
  ///
  /// In en, this message translates to:
  /// **'Desktop camera active'**
  String get uiDesktopCameraActiveDA0F15;

  /// App-owned interface/status text in lib/main.dart:13779. English: Paste one cb1 frame
  ///
  /// In en, this message translates to:
  /// **'Paste one cb1 frame'**
  String get uiPasteOneCbFrame66EA2B;

  /// App-owned interface/status text in lib/main.dart:13788. English: Add frame
  ///
  /// In en, this message translates to:
  /// **'Add frame'**
  String get uiAddFrame2BBA30;

  /// App-owned interface/status text in lib/main.dart:13890. English: Contact alias
  ///
  /// In en, this message translates to:
  /// **'Contact alias'**
  String get uiContactAliasE07C25;

  /// App-owned interface/status text in lib/main.dart:13895. English: We compared this fingerprint in person
  ///
  /// In en, this message translates to:
  /// **'We compared this fingerprint in person'**
  String get uiWeComparedThisFingerprintIn952BEB;

  /// App-owned interface/status text in lib/main.dart:13901. English: Trust and add contact
  ///
  /// In en, this message translates to:
  /// **'Trust and add contact'**
  String get uiTrustAndAddContact0962A2;

  /// App-owned interface/status text in lib/main.dart:13913. English: Saved in private Conest storage:
  ///
  /// In en, this message translates to:
  /// **'Saved in private Conest storage:'**
  String get uiSavedInPrivateConestStorage4C1334;

  /// App-owned interface/status text in lib/main.dart:14143. English: Reset identity
  ///
  /// In en, this message translates to:
  /// **'Reset identity'**
  String get uiResetIdentity8B0224;

  /// App-owned interface/status text in lib/main.dart:14145. English: This clears the encrypted vault, removes contacts and messages, and returns the app to the first-launch state.
  ///
  /// In en, this message translates to:
  /// **'This clears the encrypted vault, removes contacts and messages, and returns the app to the first-launch state.'**
  String get uiThisClearsTheEncryptedVault864B3D;

  /// App-owned interface/status text in lib/main.dart:14154. English: Reset
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get uiReset44C57A;

  /// App-owned interface/status text in lib/main.dart:14191. English: No identity is active.
  ///
  /// In en, this message translates to:
  /// **'No identity is active.'**
  String get uiNoIdentityIsActive6B2EE3;

  /// App-owned interface/status text in lib/main.dart:14296. English: Save Name
  ///
  /// In en, this message translates to:
  /// **'Save Name'**
  String get uiSaveNameE73831;

  /// App-owned interface/status text in lib/main.dart:14325. English: Save Bio
  ///
  /// In en, this message translates to:
  /// **'Save Bio'**
  String get uiSaveBioBE2711;

  /// App-owned interface/status text in lib/main.dart:14339. English: Message notifications
  ///
  /// In en, this message translates to:
  /// **'Message notifications'**
  String get uiMessageNotifications595635;

  /// App-owned interface/status text in lib/main.dart:14341. English: Show a system notification when a direct message arrives.
  ///
  /// In en, this message translates to:
  /// **'Show a system notification when a direct message arrives.'**
  String get uiShowASystemNotificationWhen90113B;

  /// App-owned interface/status text in lib/main.dart:14367. English: Experimental voice calls
  ///
  /// In en, this message translates to:
  /// **'Experimental voice calls'**
  String get uiExperimentalVoiceCalls51098B;

  /// App-owned interface/status text in lib/main.dart:14396. English: Experimental Android background receive
  ///
  /// In en, this message translates to:
  /// **'Experimental Android background receive'**
  String get uiExperimentalAndroidBackgroundReceive60828A;

  /// App-owned interface/status text in lib/main.dart:14399. English: Disabled in release builds: the foreground service does not yet host a headless Flutter receiver.
  ///
  /// In en, this message translates to:
  /// **'Disabled in release builds: the foreground service does not yet host a headless Flutter receiver.'**
  String get uiDisabledInReleaseBuildsThe45B7DF;

  /// App-owned interface/status text in lib/main.dart:14434. English: Allow voice calls in background
  ///
  /// In en, this message translates to:
  /// **'Allow voice calls in background'**
  String get uiAllowVoiceCallsInBackground73C5C5;

  /// App-owned interface/status text in lib/main.dart:14437. English: Keeps call signaling active and shows an ongoing call notification while the Conest service runs. Requires Experimental voice calls; Android battery policy or force-stop can still end availability.
  ///
  /// In en, this message translates to:
  /// **'Keeps call signaling active and shows an ongoing call notification while the Conest service runs. Requires Experimental voice calls; Android battery policy or force-stop can still end availability.'**
  String get uiKeepsCallSignalingActiveAndC0A342;

  /// App-owned interface/status text in lib/main.dart:14451. English: Don't send read confirmations
  ///
  /// In en, this message translates to:
  /// **'Don\'t send read confirmations'**
  String get uiDonTSendReadConfirmations230076;

  /// App-owned interface/status text in lib/main.dart:14454. English: Debug-only. Delivery acknowledgements still send; incoming read confirmations are still processed.
  ///
  /// In en, this message translates to:
  /// **'Debug-only. Delivery acknowledgements still send; incoming read confirmations are still processed.'**
  String get uiDebugOnlyDeliveryAcknowledgementsStill7D6A9C;

  /// App-owned interface/status text in lib/main.dart:14466. English: Remove metadata from files
  ///
  /// In en, this message translates to:
  /// **'Remove metadata from files'**
  String get uiRemoveMetadataFromFilesA4860E;

  /// App-owned interface/status text in lib/main.dart:14468. English: Before sending, removes location, camera, author and date details from photos, videos, PDFs and office documents. Pictures are not re-compressed. Other files are sent as they are.
  ///
  /// In en, this message translates to:
  /// **'Before sending, removes location, camera, author and date details from photos, videos, PDFs and office documents. Pictures are not re-compressed. Other files are sent as they are.'**
  String get uiBeforeSendingRemovesLocationCamera4E390D;

  /// App-owned interface/status text in lib/main.dart:14486. English: Send files under random names
  ///
  /// In en, this message translates to:
  /// **'Send files under random names'**
  String get uiSendFilesUnderRandomNames5F79D4;

  /// App-owned interface/status text in lib/main.dart:14489. English: Replaces file names with random letters (the type, such as .jpg, stays), for you and the recipient.
  ///
  /// In en, this message translates to:
  /// **'Replaces file names with random letters (the type, such as .jpg, stays), for you and the recipient.'**
  String get uiReplacesFileNamesWithRandom16F099;

  /// App-owned interface/status text in lib/main.dart:14546. English: Keep 10% of storage free
  ///
  /// In en, this message translates to:
  /// **'Keep 10% of storage free'**
  String get uiKeepOfStorageFreeF00434;

  /// App-owned interface/status text in lib/main.dart:14548. English: Reserve free space for other apps. When off, transfers can use this space but must still fit on disk.
  ///
  /// In en, this message translates to:
  /// **'Reserve free space for other apps. When off, transfers can use this space but must still fit on disk.'**
  String get uiReserveFreeSpaceForOther1AC9CF;

  /// App-owned interface/status text in lib/main.dart:14574. English: LAN
  ///
  /// In en, this message translates to:
  /// **'LAN'**
  String get uiLAN2ECD17;

  /// App-owned interface/status text in lib/main.dart:14576. English: Same-network listener, pairing beacons, LAN delivery.
  ///
  /// In en, this message translates to:
  /// **'Same-network listener, pairing beacons, LAN delivery.'**
  String get uiSameNetworkListenerPairingBeacons5CF0A2;

  /// App-owned interface/status text in lib/main.dart:14592. English: Online
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get uiOnlineC3E839;

  /// App-owned interface/status text in lib/main.dart:14594. English: Iroh messaging and file transfers over the internet. Custom Conest relays are optional.
  ///
  /// In en, this message translates to:
  /// **'Iroh messaging and file transfers over the internet. Custom Conest relays are optional.'**
  String get uiIrohMessagingAndFileTransfersC4D635;

  /// App-owned interface/status text in lib/main.dart:14611. English: Iroh relay fallback
  ///
  /// In en, this message translates to:
  /// **'Iroh relay fallback'**
  String get uiIrohRelayFallbackE954F7;

  /// App-owned interface/status text in lib/main.dart:14613. English: Use Iroh’s built-in relays for messages and files when direct connections cannot get through. Both peers must be online.
  ///
  /// In en, this message translates to:
  /// **'Use Iroh’s built-in relays for messages and files when direct connections cannot get through. Both peers must be online.'**
  String get uiUseIrohSBuiltIn631E03;

  /// App-owned interface/status text in lib/main.dart:14630. English: Limit Iroh files to 100 MiB (recommended)
  ///
  /// In en, this message translates to:
  /// **'Limit Iroh files to 100 MiB (recommended)'**
  String get uiLimitIrohFilesToMiBB58353;

  /// App-owned interface/status text in lib/main.dart:14633. English: Applies to direct online and Iroh relay transfers. Disable for larger files; they may take a long time. LAN transfers keep their larger limit.
  ///
  /// In en, this message translates to:
  /// **'Applies to direct online and Iroh relay transfers. Disable for larger files; they may take a long time. LAN transfers keep their larger limit.'**
  String get uiAppliesToDirectOnlineAnd28F6F1;

  /// App-owned interface/status text in lib/main.dart:14651. English: Share email and Matrix addresses with group members
  ///
  /// In en, this message translates to:
  /// **'Share email and Matrix addresses with group members'**
  String get uiShareEmailAndMatrixAddressesD762EE;

  /// App-owned interface/status text in lib/main.dart:14654. English: Lets members of your groups who are not your contacts reach you by email or Matrix. Off: they only learn your Nostr, Tor and radio addresses, which do not name you. Turning it off stops sharing from now on; members who already saw an address may keep it.
  ///
  /// In en, this message translates to:
  /// **'Lets members of your groups who are not your contacts reach you by email or Matrix. Off: they only learn your Nostr, Tor and radio addresses, which do not name you. Turning it off stops sharing from now on; members who already saw an address may keep it.'**
  String get uiLetsMembersOfYourGroups9912A5;

  /// App-owned interface/status text in lib/main.dart:14659. English: Automatic downloads
  ///
  /// In en, this message translates to:
  /// **'Automatic downloads'**
  String get uiAutomaticDownloads5E777B;

  /// App-owned interface/status text in lib/main.dart:14661. English: Verified contacts only. Limits adapt to Wi-Fi/Ethernet, cellular, and roaming.
  ///
  /// In en, this message translates to:
  /// **'Verified contacts only. Limits adapt to Wi-Fi/Ethernet, cellular, and roaming.'**
  String get uiVerifiedContactsOnlyLimitsAdapt8A1876;

  /// App-owned interface/status text in lib/main.dart:14717. English: Custom Iroh relay URLs
  ///
  /// In en, this message translates to:
  /// **'Custom Iroh relay URLs'**
  String get uiCustomIrohRelayURLsDBF979;

  /// App-owned interface/status text in lib/main.dart:14719. English: One HTTPS URL per line; blank uses the standard N0 relay set.
  ///
  /// In en, this message translates to:
  /// **'One HTTPS URL per line; blank uses the standard N0 relay set.'**
  String get uiOneHTTPSURLPerLineDA8E70;

  /// App-owned interface/status text in lib/main.dart:14751. English: Save Iroh relays
  ///
  /// In en, this message translates to:
  /// **'Save Iroh relays'**
  String get uiSaveIrohRelaysC144AD;

  /// App-owned interface/status text in lib/main.dart:14872. English: Check Availability
  ///
  /// In en, this message translates to:
  /// **'Check Availability'**
  String get uiCheckAvailabilityFCC1A6;

  /// App-owned interface/status text in lib/main.dart:14884. English: Run this device as a relay
  ///
  /// In en, this message translates to:
  /// **'Run this device as a relay'**
  String get uiRunThisDeviceAsA9DEA14;

  /// App-owned interface/status text in lib/main.dart:14886. English: Allow trusted contacts to use this device as a relay.
  ///
  /// In en, this message translates to:
  /// **'Allow trusted contacts to use this device as a relay.'**
  String get uiAllowTrustedContactsToUse001771;

  /// App-owned interface/status text in lib/main.dart:14898. English: Auto-use contacts as relays
  ///
  /// In en, this message translates to:
  /// **'Auto-use contacts as relays'**
  String get uiAutoUseContactsAsRelaysC62C06;

  /// App-owned interface/status text in lib/main.dart:14914. English: Local relay port
  ///
  /// In en, this message translates to:
  /// **'Local relay port'**
  String get uiLocalRelayPort28A73C;

  /// App-owned interface/status text in lib/main.dart:14934. English: Save Port
  ///
  /// In en, this message translates to:
  /// **'Save Port'**
  String get uiSavePort1876F6;

  /// App-owned interface/status text in lib/main.dart:14996. English: Relay host / URL
  ///
  /// In en, this message translates to:
  /// **'Relay host / URL'**
  String get uiRelayHostURLF11441;

  /// App-owned interface/status text in lib/main.dart:15007. English: Relay port
  ///
  /// In en, this message translates to:
  /// **'Relay port'**
  String get uiRelayPortEA05DA;

  /// App-owned interface/status text in lib/main.dart:15032. English: Detect & Add Relay
  ///
  /// In en, this message translates to:
  /// **'Detect & Add Relay'**
  String get uiDetectAddRelayE825AD;

  /// App-owned interface/status text in lib/main.dart:15082. English: Error history
  ///
  /// In en, this message translates to:
  /// **'Error history'**
  String get uiErrorHistory25AFF8;

  /// App-owned interface/status text in lib/main.dart:15084. English: What went wrong, kept across restarts on this build, to copy for a bug report.
  ///
  /// In en, this message translates to:
  /// **'What went wrong, kept across restarts on this build, to copy for a bug report.'**
  String get uiWhatWentWrongKeptAcross27FC1F;

  /// App-owned interface/status text in lib/main.dart:15110. English: Receive unstable updates
  ///
  /// In en, this message translates to:
  /// **'Receive unstable updates'**
  String get uiReceiveUnstableUpdatesBF7122;

  /// App-owned interface/status text in lib/main.dart:15113. English: Also offer nightly builds: newer features, less tested. A newer stable release is always offered.
  ///
  /// In en, this message translates to:
  /// **'Also offer nightly builds: newer features, less tested. A newer stable release is always offered.'**
  String get uiAlsoOfferNightlyBuildsNewerA7FAB0;

  /// App-owned interface/status text in lib/main.dart:15199. English: Reset App Identity
  ///
  /// In en, this message translates to:
  /// **'Reset App Identity'**
  String get uiResetAppIdentity2E0F86;

  /// App-owned interface/status text in lib/main.dart:15272. English: Trust new key
  ///
  /// In en, this message translates to:
  /// **'Trust new key'**
  String get uiTrustNewKeyA181BE;

  /// App-owned interface/status text in lib/main.dart:15446. English: Verify the person and compare this safety number through another channel before accepting.
  ///
  /// In en, this message translates to:
  /// **'Verify the person and compare this safety number through another channel before accepting.'**
  String get uiVerifyThePersonAndCompare738F28;

  /// App-owned interface/status text in lib/main.dart:15539. English: Review
  ///
  /// In en, this message translates to:
  /// **'Review'**
  String get uiReviewE29A79;

  /// App-owned interface/status text in lib/main.dart:15628. English: Discard chat
  ///
  /// In en, this message translates to:
  /// **'Discard chat'**
  String get uiDiscardChat319267;

  /// App-owned interface/status text in lib/main.dart:15654. English: Confirm identity replacement?
  ///
  /// In en, this message translates to:
  /// **'Confirm identity replacement?'**
  String get uiConfirmIdentityReplacement0219C5;

  /// App-owned interface/status text in lib/main.dart:15672. English: It's them
  ///
  /// In en, this message translates to:
  /// **'It\'s them'**
  String get uiItSThem394960;

  /// App-owned interface/status text in lib/main.dart:15692. English: Reject this identity?
  ///
  /// In en, this message translates to:
  /// **'Reject this identity?'**
  String get uiRejectThisIdentityCB604F;

  /// App-owned interface/status text in lib/main.dart:15694. English: This deletes the new contact and any held inbound messages. Use this if you believe this is impersonation.
  ///
  /// In en, this message translates to:
  /// **'This deletes the new contact and any held inbound messages. Use this if you believe this is impersonation.'**
  String get uiThisDeletesTheNewContactBB4444;

  /// App-owned interface/status text in lib/main.dart:15760. English: Not them
  ///
  /// In en, this message translates to:
  /// **'Not them'**
  String get uiNotThem685593;

  /// App-owned interface/status text in lib/main.dart:15819. English: Remove imported list?
  ///
  /// In en, this message translates to:
  /// **'Remove imported list?'**
  String get uiRemoveImportedList36FC81;

  /// App-owned interface/status text in lib/main.dart:15863. English: No bundled Conest relays. Online connections use Iroh; you can also configure your own relay.
  ///
  /// In en, this message translates to:
  /// **'No bundled Conest relays. Online connections use Iroh; you can also configure your own relay.'**
  String get uiNoBundledConestRelaysOnline46529B;

  /// App-owned interface/status text in lib/main.dart:15885. English: Import from URL…
  ///
  /// In en, this message translates to:
  /// **'Import from URL…'**
  String get uiImportFromURL3F7B77;

  /// App-owned interface/status text in lib/main.dart:15957. English: Import relay list from URL
  ///
  /// In en, this message translates to:
  /// **'Import relay list from URL'**
  String get uiImportRelayListFromURL86E363;

  /// App-owned interface/status text in lib/main.dart:15966. English: JSON URL
  ///
  /// In en, this message translates to:
  /// **'JSON URL'**
  String get uiJSONURL6918BA;

  /// App-owned interface/status text in lib/main.dart:15974. English: Operator's public key (optional, base64)
  ///
  /// In en, this message translates to:
  /// **'Operator\'s public key (optional, base64)'**
  String get uiOperatorSPublicKeyOptionalA80E7A;

  /// App-owned interface/status text in lib/main.dart:16001. English: Import
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get uiImportD6FBC9;

  /// App-owned interface/status text in lib/main.dart:16373. English: CLEAN
  ///
  /// In en, this message translates to:
  /// **'CLEAN'**
  String get uiCLEAN2F3D27;

  /// App-owned interface/status text in lib/main.dart:16374. English: SUBTLE
  ///
  /// In en, this message translates to:
  /// **'SUBTLE'**
  String get uiSUBTLEBB048B;

  /// App-owned interface/status text in lib/main.dart:16375. English: DEFAULT
  ///
  /// In en, this message translates to:
  /// **'DEFAULT'**
  String get uiDEFAULTC18920;

  /// App-owned interface/status text in lib/main.dart:16376. English: FULL
  ///
  /// In en, this message translates to:
  /// **'FULL'**
  String get uiFULLCC0A74;

  /// App-owned interface/status text in lib/main.dart:17622. English: LAN first
  ///
  /// In en, this message translates to:
  /// **'LAN first'**
  String get uiLANFirstB360D1;

  /// App-owned interface/status text in lib/main.dart:17628. English: LAN only
  ///
  /// In en, this message translates to:
  /// **'LAN only'**
  String get uiLANOnly94945D;

  /// App-owned interface/status text in lib/main.dart:17634. English: Online first
  ///
  /// In en, this message translates to:
  /// **'Online first'**
  String get uiOnlineFirst346B6D;

  /// App-owned interface/status text in lib/main.dart:17640. English: Online only
  ///
  /// In en, this message translates to:
  /// **'Online only'**
  String get uiOnlineOnlyF79CB9;

  /// App-owned interface/status text in lib/main.dart:17645. English: Offline
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get uiOfflineE01FA7;

  /// App-owned interface/status text in lib/main.dart:17751. English: Uses LAN when available, falls back to Online.
  ///
  /// In en, this message translates to:
  /// **'Uses LAN when available, falls back to Online.'**
  String get uiUsesLANWhenAvailableFallsA810EF;

  /// App-owned interface/status text in lib/main.dart:17753. English: Uses LAN only. No relay traffic for this contact.
  ///
  /// In en, this message translates to:
  /// **'Uses LAN only. No relay traffic for this contact.'**
  String get uiUsesLANOnlyNoRelay589D55;

  /// App-owned interface/status text in lib/main.dart:17755. English: Uses Online when available, falls back to LAN.
  ///
  /// In en, this message translates to:
  /// **'Uses Online when available, falls back to LAN.'**
  String get uiUsesOnlineWhenAvailableFallsCE2CAF;

  /// App-owned interface/status text in lib/main.dart:17757. English: Uses Online only. No LAN traffic for this contact.
  ///
  /// In en, this message translates to:
  /// **'Uses Online only. No LAN traffic for this contact.'**
  String get uiUsesOnlineOnlyNoLAN193810;

  /// App-owned interface/status text in lib/main.dart:17760. English: No transport selected — this contact is unreachable.
  ///
  /// In en, this message translates to:
  /// **'No transport selected — this contact is unreachable.'**
  String get uiNoTransportSelectedThisContact7969EB;

  /// App-owned interface/status text in lib/main.dart:17761. English: Global connectivity is off — adjust Settings to send.
  ///
  /// In en, this message translates to:
  /// **'Global connectivity is off — adjust Settings to send.'**
  String get uiGlobalConnectivityIsOffAdjustA7C644;

  /// App-owned interface/status text in lib/main.dart:17781. English: Same-network delivery
  ///
  /// In en, this message translates to:
  /// **'Same-network delivery'**
  String get uiSameNetworkDelivery94E793;

  /// App-owned interface/status text in lib/main.dart:17782. English: Disabled by global setting
  ///
  /// In en, this message translates to:
  /// **'Disabled by global setting'**
  String get uiDisabledByGlobalSetting2CB06C;

  /// App-owned interface/status text in lib/main.dart:17790. English: Allow Iroh relay fallback
  ///
  /// In en, this message translates to:
  /// **'Allow Iroh relay fallback'**
  String get uiAllowIrohRelayFallback35227B;

  /// App-owned interface/status text in lib/main.dart:17793. English: Visible and online-only; direct Iroh is preferred.
  ///
  /// In en, this message translates to:
  /// **'Visible and online-only; direct Iroh is preferred.'**
  String get uiVisibleAndOnlineOnlyDirectEA8902;

  /// App-owned interface/status text in lib/main.dart:17814. English: Relay / internet delivery
  ///
  /// In en, this message translates to:
  /// **'Relay / internet delivery'**
  String get uiRelayInternetDeliveryD64AB6;

  /// App-owned interface/status text in lib/main.dart:17820. English: Prefer
  ///
  /// In en, this message translates to:
  /// **'Prefer'**
  String get uiPrefer13F662;

  /// App-owned interface/status text in lib/main.dart:17839. English: Carry their messages
  ///
  /// In en, this message translates to:
  /// **'Carry their messages'**
  String get uiCarryTheirMessages22FD33;

  /// App-owned interface/status text in lib/main.dart:17841. English: When this contact cannot reach someone but this device can, pass their messages on. You see only who they are for and when; the content stays encrypted.
  ///
  /// In en, this message translates to:
  /// **'When this contact cannot reach someone but this device can, pass their messages on. You see only who they are for and when; the content stays encrypted.'**
  String get uiWhenThisContactCannotReach5C3FF8;

  /// App-owned interface/status text in lib/main.dart:18137. English: Save {value} file(s) to…
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{Save {value} file to…} other{Save {value} files to…}}'**
  String uiSaveValueFileSToB46C57(int value);

  /// App-owned interface/status text in lib/main.dart:18141. English: Save canceled.
  ///
  /// In en, this message translates to:
  /// **'Save canceled.'**
  String get uiSaveCanceled1939D0;

  /// App-owned interface/status text in lib/main.dart:18327. English: Album actions
  ///
  /// In en, this message translates to:
  /// **'Album actions'**
  String get uiAlbumActions7B6D70;

  /// App-owned interface/status text in lib/main.dart:18432. English: Cancel selection
  ///
  /// In en, this message translates to:
  /// **'Cancel selection'**
  String get uiCancelSelectionF7F56C;

  /// App-owned interface/status text in lib/main.dart:18443. English: Copy
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get uiCopyAF74F7;

  /// App-owned interface/status text in lib/main.dart:18448. English: Save attachments
  ///
  /// In en, this message translates to:
  /// **'Save attachments'**
  String get uiSaveAttachments5A74EA;

  /// App-owned interface/status text in lib/main.dart:18512. English: Cancel and clear all transfers?
  ///
  /// In en, this message translates to:
  /// **'Cancel and clear all transfers?'**
  String get uiCancelAndClearAllTransfers01B81D;

  /// App-owned interface/status text in lib/main.dart:18519. English: Keep transfers
  ///
  /// In en, this message translates to:
  /// **'Keep transfers'**
  String get uiKeepTransfersDB8CC7;

  /// App-owned interface/status text in lib/main.dart:18523. English: Cancel and clear
  ///
  /// In en, this message translates to:
  /// **'Cancel and clear'**
  String get uiCancelAndClearCCF59C;

  /// App-owned interface/status text in lib/main.dart:18558. English: Pause all
  ///
  /// In en, this message translates to:
  /// **'Pause all'**
  String get uiPauseAll6F6099;

  /// App-owned interface/status text in lib/main.dart:18568. English: Resume all
  ///
  /// In en, this message translates to:
  /// **'Resume all'**
  String get uiResumeAll039916;

  /// App-owned interface/status text in lib/main.dart:18575. English: Cancel and clear all transfers
  ///
  /// In en, this message translates to:
  /// **'Cancel and clear all transfers'**
  String get uiCancelAndClearAllTransfersACEBB3;

  /// App-owned interface/status text in lib/main.dart:18587. English: Clear completed
  ///
  /// In en, this message translates to:
  /// **'Clear completed'**
  String get uiClearCompletedE63FC1;

  /// App-owned interface/status text in lib/main.dart:18718. English: Move to top
  ///
  /// In en, this message translates to:
  /// **'Move to top'**
  String get uiMoveToTop44AFA6;

  /// App-owned interface/status text in lib/main.dart:18728. English: Preparing download
  ///
  /// In en, this message translates to:
  /// **'Preparing download'**
  String get uiPreparingDownloadF9B13B;

  /// App-owned interface/status text in lib/main.dart:18729. English: Download
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get uiDownloadA479C9;

  /// App-owned interface/status text in lib/main.dart:18746. English: Resume
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get uiResumeB3BD0B;

  /// App-owned interface/status text in lib/main.dart:18753. English: Pause
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get uiPause781961;

  /// App-owned interface/status text in lib/main.dart:18764. English: Retry
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get uiRetry9F5CD8;

  /// App-owned interface/status text in lib/main.dart:18819. English: Continue over Iroh relay
  ///
  /// In en, this message translates to:
  /// **'Continue over Iroh relay'**
  String get uiContinueOverIrohRelay949702;

  /// App-owned interface/status text in lib/main.dart:18850. English: Download anyway
  ///
  /// In en, this message translates to:
  /// **'Download anyway'**
  String get uiDownloadAnyway42859F;

  /// App-owned interface/status text in lib/main.dart:18896. English: Preparing
  ///
  /// In en, this message translates to:
  /// **'Preparing'**
  String get uiPreparing96A9B7;

  /// App-owned interface/status text in lib/main.dart:18897. English: Queued
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get uiQueued6A5998;

  /// App-owned interface/status text in lib/main.dart:18899. English: Waiting
  ///
  /// In en, this message translates to:
  /// **'Waiting'**
  String get uiWaiting33D306;

  /// App-owned interface/status text in lib/main.dart:18900. English: Transferring
  ///
  /// In en, this message translates to:
  /// **'Transferring'**
  String get uiTransferring73F753;

  /// App-owned interface/status text in lib/main.dart:18901. English: Reconnecting
  ///
  /// In en, this message translates to:
  /// **'Reconnecting'**
  String get uiReconnecting9D80F9;

  /// App-owned interface/status text in lib/main.dart:18902. English: Paused
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get uiPausedC7DFB6;

  /// App-owned interface/status text in lib/main.dart:18903. English: Verifying
  ///
  /// In en, this message translates to:
  /// **'Verifying'**
  String get uiVerifying536244;

  /// App-owned interface/status text in lib/main.dart:18904. English: Complete
  ///
  /// In en, this message translates to:
  /// **'Complete'**
  String get uiComplete1F5A1A;

  /// App-owned interface/status text in lib/main.dart:18906. English: Canceled
  ///
  /// In en, this message translates to:
  /// **'Canceled'**
  String get uiCanceledF840AC;

  /// App-owned interface/status text in lib/main.dart:18907. English: Unavailable
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get uiUnavailable2C9C1F;

  /// App-owned interface/status text in lib/main.dart:19007. English: Saved {value} to {value2}.
  ///
  /// In en, this message translates to:
  /// **'Saved {value} to {value2}.'**
  String uiSavedValueToValue08F152(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:19019. English: Gallery save failed ({value}); falling back to file dialog.
  ///
  /// In en, this message translates to:
  /// **'Gallery save failed ({value}); falling back to file dialog.'**
  String uiGallerySaveFailedValueFalling0B82BB(String value);

  /// App-owned interface/status text in lib/main.dart:19026. English: Save {value}
  ///
  /// In en, this message translates to:
  /// **'Save {value}'**
  String uiSaveValue5769AA(String value);

  /// App-owned interface/status text in lib/main.dart:19041. English: Save failed: {value}
  ///
  /// In en, this message translates to:
  /// **'Save failed: {value}'**
  String uiSaveFailedValue534182(String value);

  /// App-owned interface/status text in lib/main.dart:19057. English: The attachment file is not available locally.
  ///
  /// In en, this message translates to:
  /// **'The attachment file is not available locally.'**
  String get uiTheAttachmentFileIsNotA67009;

  /// App-owned interface/status text in lib/main.dart:19123. English: Copied {value} to clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied {value} to clipboard.'**
  String uiCopiedValueToClipboard669D0B(String value);

  /// App-owned interface/status text in lib/main.dart:19142. English: Copied "{value}" (text only — system clipboard binary surface unavailable).
  ///
  /// In en, this message translates to:
  /// **'Copied \"{value}\" (text only — system clipboard binary surface unavailable).'**
  String uiCopiedValueTextOnlySystemB51B8D(String value);

  /// App-owned interface/status text in lib/main.dart:19194. English: Copy failed: {value}. Filename copied as text fallback.
  ///
  /// In en, this message translates to:
  /// **'Copy failed: {value}. Filename copied as text fallback.'**
  String uiCopyFailedValueFilenameCopiedF71C87(String value);

  /// App-owned interface/status text in lib/main.dart:19233. English: Cache path is not ready yet — still transferring.
  ///
  /// In en, this message translates to:
  /// **'Cache path is not ready yet — still transferring.'**
  String get uiCachePathIsNotReady0404B5;

  /// App-owned interface/status text in lib/main.dart:19237. English: Cache path copied: {value}
  ///
  /// In en, this message translates to:
  /// **'Cache path copied: {value}'**
  String uiCachePathCopiedValue4CC1C4(String value);

  /// App-owned interface/status text in lib/main.dart:19257. English: Video isn't cached locally yet — wait for the transfer to finish.
  ///
  /// In en, this message translates to:
  /// **'Video isn\'t cached locally yet — wait for the transfer to finish.'**
  String get uiVideoIsnTCachedLocally8920DD;

  /// App-owned interface/status text in lib/main.dart:19271. English: Could not open video in the system player: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not open video in the system player: {value}'**
  String uiCouldNotOpenVideoIn054087(String value);

  /// App-owned interface/status text in lib/main.dart:19348. English: Image is not available locally.
  ///
  /// In en, this message translates to:
  /// **'Image is not available locally.'**
  String get uiImageIsNotAvailableLocally12017F;

  /// App-owned interface/status text in lib/main.dart:19606. English: Video still transferring ({value}%).
  ///
  /// In en, this message translates to:
  /// **'Video still transferring ({value}%).'**
  String uiVideoStillTransferringValue3F4049(String value);

  /// App-owned interface/status text in lib/main.dart:19787. English: Voice message bytes are not ready.
  ///
  /// In en, this message translates to:
  /// **'Voice message bytes are not ready.'**
  String get uiVoiceMessageBytesAreNotF8339B;

  /// App-owned interface/status text in lib/main.dart:20261. English: Send mode
  ///
  /// In en, this message translates to:
  /// **'Send mode'**
  String get uiSendMode265A2D;

  /// App-owned interface/status text in lib/main.dart:20715. English: LAN relay
  ///
  /// In en, this message translates to:
  /// **'LAN relay'**
  String get uiLANRelayA05D48;

  /// App-owned interface/status text in lib/main.dart:20716. English: Lobby
  ///
  /// In en, this message translates to:
  /// **'Lobby'**
  String get uiLobbyFDB6D9;

  /// App-owned interface/status text in lib/main.dart:20717. English: Direct
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get uiDirectBC8152;

  /// App-owned interface/status text in lib/main.dart:20718. English: Iroh
  ///
  /// In en, this message translates to:
  /// **'Iroh'**
  String get uiIroh84642D;

  /// App-owned interface/status text in lib/main.dart:20719. English: Iroh relay
  ///
  /// In en, this message translates to:
  /// **'Iroh relay'**
  String get uiIrohRelayB128EA;

  /// App-owned interface/status text in lib/main.dart:20720. English: Relay
  ///
  /// In en, this message translates to:
  /// **'Relay'**
  String get uiRelay9F537F;

  /// App-owned interface/status text in lib/main.dart:20721. English: Matrix
  ///
  /// In en, this message translates to:
  /// **'Matrix'**
  String get uiMatrix58947E;

  /// App-owned interface/status text in lib/main.dart:20722. English: Plain Matrix
  ///
  /// In en, this message translates to:
  /// **'Plain Matrix'**
  String get uiPlainMatrixBA9DE1;

  /// App-owned interface/status text in lib/main.dart:20723. English: Nostr
  ///
  /// In en, this message translates to:
  /// **'Nostr'**
  String get uiNostr4D3AD8;

  /// App-owned interface/status text in lib/main.dart:20724. English: Email
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get uiEmail84ADD5;

  /// App-owned interface/status text in lib/main.dart:20725. English: Reticulum
  ///
  /// In en, this message translates to:
  /// **'Reticulum'**
  String get uiReticulumC27E52;

  /// App-owned interface/status text in lib/main.dart:20726. English: Meshtastic
  ///
  /// In en, this message translates to:
  /// **'Meshtastic'**
  String get uiMeshtastic29C887;

  /// App-owned interface/status text in lib/main.dart:20727. English: MeshCore
  ///
  /// In en, this message translates to:
  /// **'MeshCore'**
  String get uiMeshCoreBA58A2;

  /// App-owned interface/status text in lib/main.dart:20728. English: Bluetooth
  ///
  /// In en, this message translates to:
  /// **'Bluetooth'**
  String get uiBluetoothC3B414;

  /// App-owned interface/status text in lib/main.dart:20729. English: Tor
  ///
  /// In en, this message translates to:
  /// **'Tor'**
  String get uiTorED7088;

  /// App-owned interface/status text in lib/main.dart:20730. English: Via contact
  ///
  /// In en, this message translates to:
  /// **'Via contact'**
  String get uiViaContactCF1F8E;

  /// App-owned interface/status text in lib/main.dart:20747. English: Send via Matrix?
  ///
  /// In en, this message translates to:
  /// **'Send via Matrix?'**
  String get uiSendViaMatrix062A08;

  /// App-owned interface/status text in lib/main.dart:20758. English: Keep waiting
  ///
  /// In en, this message translates to:
  /// **'Keep waiting'**
  String get uiKeepWaiting9BE1AB;

  /// App-owned interface/status text in lib/main.dart:20762. English: Send via Matrix
  ///
  /// In en, this message translates to:
  /// **'Send via Matrix'**
  String get uiSendViaMatrix638038;

  /// App-owned interface/status text in lib/main.dart:20774. English: Not sent via Matrix: {value}
  ///
  /// In en, this message translates to:
  /// **'Not sent via Matrix: {value}'**
  String uiNotSentViaMatrixValue99F62C(String value);

  /// App-owned interface/status text in lib/main.dart:20786. English: Message routes
  ///
  /// In en, this message translates to:
  /// **'Message routes'**
  String get uiMessageRoutesFBF32C;

  /// App-owned interface/status text in lib/main.dart:20787. English: What the coloured marks on messages mean
  ///
  /// In en, this message translates to:
  /// **'What the coloured marks on messages mean'**
  String get uiWhatTheColouredMarksOnA10C8E;

  /// App-owned interface/status text in lib/main.dart:21118. English: Open in default player
  ///
  /// In en, this message translates to:
  /// **'Open in default player'**
  String get uiOpenInDefaultPlayerE64C20;

  /// App-owned interface/status text in lib/main.dart:21363. English: Cancel reply
  ///
  /// In en, this message translates to:
  /// **'Cancel reply'**
  String get uiCancelReplyBD62D2;

  /// App-owned interface/status text in lib/main.dart:21406. English: Scheduled messages
  ///
  /// In en, this message translates to:
  /// **'Scheduled messages'**
  String get uiScheduledMessages98CEF4;

  /// App-owned interface/status text in lib/main.dart:21453. English: Edit scheduled message
  ///
  /// In en, this message translates to:
  /// **'Edit scheduled message'**
  String get uiEditScheduledMessage62AF88;

  /// App-owned interface/status text in lib/main.dart:21462. English: Caption
  ///
  /// In en, this message translates to:
  /// **'Caption'**
  String get uiCaption3428D9;

  /// App-owned interface/status text in lib/main.dart:21622. English: No chats to share into yet.
  ///
  /// In en, this message translates to:
  /// **'No chats to share into yet.'**
  String get uiNoChatsToShareIntoB50F2F;

  /// App-owned interface/status text in lib/main.dart:21749. English: Let devices on this network reach this PC
  ///
  /// In en, this message translates to:
  /// **'Let devices on this network reach this PC'**
  String get uiLetDevicesOnThisNetwork42E2F0;

  /// App-owned interface/status text in lib/main.dart:21763. English: Allow
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get uiAllow3AD0E3;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:100. English: Keep signed in
  ///
  /// In en, this message translates to:
  /// **'Keep signed in'**
  String get uiKeepSignedIn611A13;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:104. English: Sign out here
  ///
  /// In en, this message translates to:
  /// **'Sign out here'**
  String get uiSignOutHereA6F129;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:119. English: Matrix password
  ///
  /// In en, this message translates to:
  /// **'Matrix password'**
  String get uiMatrixPassword34E218;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:125. English: Password
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get uiPassword8BE3C9;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:126. English: Your server asks for it to create signing keys.
  ///
  /// In en, this message translates to:
  /// **'Your server asks for it to create signing keys.'**
  String get uiYourServerAsksForIt1594FA;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:158. English: Recovery is already set up
  ///
  /// In en, this message translates to:
  /// **'Recovery is already set up'**
  String get uiRecoveryIsAlreadySetUp371F7F;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:170. English: OK
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get uiOK9CE3BD;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:193. English: Save your recovery key
  ///
  /// In en, this message translates to:
  /// **'Save your recovery key'**
  String get uiSaveYourRecoveryKey7851B3;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:199. English: Keep this key somewhere safe. You need it to read encrypted Matrix history on a new device. It is shown only once.
  ///
  /// In en, this message translates to:
  /// **'Keep this key somewhere safe. You need it to read encrypted Matrix history on a new device. It is shown only once.'**
  String get uiKeepThisKeySomewhereSafe0C0DFE;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:217. English: I saved it
  ///
  /// In en, this message translates to:
  /// **'I saved it'**
  String get uiISavedIt3E2255;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:247. English: Enter recovery key
  ///
  /// In en, this message translates to:
  /// **'Enter recovery key'**
  String get uiEnterRecoveryKey4521B6;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:254. English: EsT… (from another Matrix app or this one)
  ///
  /// In en, this message translates to:
  /// **'EsT… (from another Matrix app or this one)'**
  String get uiEsTFromAnotherMatrixAppFCA0C9;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:320. English: Sign out
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get uiSignOutDC1649;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:331. English: Set up recovery
  ///
  /// In en, this message translates to:
  /// **'Set up recovery'**
  String get uiSetUpRecoveryFD3804;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:343. English: Verify with another session
  ///
  /// In en, this message translates to:
  /// **'Verify with another session'**
  String get uiVerifyWithAnotherSession9ED031;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:350. English: Show joins, leaves and profile changes
  ///
  /// In en, this message translates to:
  /// **'Show joins, leaves and profile changes'**
  String get uiShowJoinsLeavesAndProfile9FA764;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:351. English: In Matrix rooms, collapsed into one line
  ///
  /// In en, this message translates to:
  /// **'In Matrix rooms, collapsed into one line'**
  String get uiInMatrixRoomsCollapsedIntoD20CAB;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:384. English: Matrix user
  ///
  /// In en, this message translates to:
  /// **'Matrix user'**
  String get uiMatrixUser70A560;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:385. English: For example @name:matrix.org
  ///
  /// In en, this message translates to:
  /// **'For example @name:matrix.org'**
  String get uiForExampleNameMatrixOrg63C60A;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:405. English: Homeserver (optional)
  ///
  /// In en, this message translates to:
  /// **'Homeserver (optional)'**
  String get uiHomeserverOptional70DF85;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:406. English: Found from the user id when blank
  ///
  /// In en, this message translates to:
  /// **'Found from the user id when blank'**
  String get uiFoundFromTheUserId69A3AB;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:424. English: Sign in to Matrix
  ///
  /// In en, this message translates to:
  /// **'Sign in to Matrix'**
  String get uiSignInToMatrix652C8F;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:430. English: Sign in with browser
  ///
  /// In en, this message translates to:
  /// **'Sign in with browser'**
  String get uiSignInWithBrowserC995DF;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:448. English: Finish signing in in your browser.
  ///
  /// In en, this message translates to:
  /// **'Finish signing in in your browser.'**
  String get uiFinishSigningInInYour9F41A4;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:452. English: Copy link
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get uiCopyLink2F84EE;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:28. English: This device
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get uiThisDeviceFA5A6D;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:30. English: Out of touch since {value}: nothing syncs with it until you confirm it is still yours.
  ///
  /// In en, this message translates to:
  /// **'Out of touch since {value}: nothing syncs with it until you confirm it is still yours.'**
  String uiOutOfTouchSinceValueA037FD(String value);

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:33. English: Linked {value}
  ///
  /// In en, this message translates to:
  /// **'Linked {value}'**
  String uiLinkedValueDCADF7(String value);

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:46. English: Your contacts will stop accepting anything from that device. It cannot be added back; link it again as a new device instead.
  ///
  /// In en, this message translates to:
  /// **'Your contacts will stop accepting anything from that device. It cannot be added back; link it again as a new device instead.'**
  String get uiYourContactsWillStopAccepting5B0F03;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:120. English: Still mine
  ///
  /// In en, this message translates to:
  /// **'Still mine'**
  String get uiStillMine38C8AE;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:123. English: Remove device
  ///
  /// In en, this message translates to:
  /// **'Remove device'**
  String get uiRemoveDeviceA9C39D;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:187. English: Link a device
  ///
  /// In en, this message translates to:
  /// **'Link a device'**
  String get uiLinkADeviceE71635;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:197. English: Link this device to my account
  ///
  /// In en, this message translates to:
  /// **'Link this device to my account'**
  String get uiLinkThisDeviceToMy888A1A;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:219. English: Check that both devices show this code:
  ///
  /// In en, this message translates to:
  /// **'Check that both devices show this code:'**
  String get uiCheckThatBothDevicesShow031E51;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:230. English: The codes match
  ///
  /// In en, this message translates to:
  /// **'The codes match'**
  String get uiTheCodesMatch32C407;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:285. English: Linked. The new device now has your account and contacts; your contacts will see it as you.
  ///
  /// In en, this message translates to:
  /// **'Linked. The new device now has your account and contacts; your contacts will see it as you.'**
  String get uiLinkedTheNewDeviceNow9900E5;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:289. English: Confirm the code on the new device too.
  ///
  /// In en, this message translates to:
  /// **'Confirm the code on the new device too.'**
  String get uiConfirmTheCodeOnThe17BB1F;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:292. English: Waiting for the new device to answer. If no code appears, make sure the new device still shows its code, and that both are on the same network or online.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the new device to answer. If no code appears, make sure the new device still shows its code, and that both are on the same network or online.'**
  String get uiWaitingForTheNewDevice75283F;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:305. English: On the new device, open Settings → Devices → Link this device to my account, then scan the code it shows.
  ///
  /// In en, this message translates to:
  /// **'On the new device, open Settings → Devices → Link this device to my account, then scan the code it shows.'**
  String get uiOnTheNewDeviceOpen29AF5E;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:318. English: Scan code
  ///
  /// In en, this message translates to:
  /// **'Scan code'**
  String get uiScanCode4596C2;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:324. English: Or paste the code
  ///
  /// In en, this message translates to:
  /// **'Or paste the code'**
  String get uiOrPasteTheCodeE72792;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:397. English: Link this device
  ///
  /// In en, this message translates to:
  /// **'Link this device'**
  String get uiLinkThisDeviceBF5E5C;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:401. English: This device is now linked to your account.
  ///
  /// In en, this message translates to:
  /// **'This device is now linked to your account.'**
  String get uiThisDeviceIsNowLinked7EA826;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:404. English: Waiting for the other device…
  ///
  /// In en, this message translates to:
  /// **'Waiting for the other device…'**
  String get uiWaitingForTheOtherDeviceB39C3F;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:414. English: On the device you already use, open Settings → Devices → Link a device and scan this code. Both devices should be on the same network or online.
  ///
  /// In en, this message translates to:
  /// **'On the device you already use, open Settings → Devices → Link a device and scan this code. Both devices should be on the same network or online.'**
  String get uiOnTheDeviceYouAlready92C421;

  /// App-owned interface/status text in lib/src/ui/network_chat_sources.dart:176. English: Delta Chat
  ///
  /// In en, this message translates to:
  /// **'Delta Chat'**
  String get uiDeltaChat8BDA67;

  /// App-owned interface/status text in lib/src/ui/network_chat_sources.dart:272. English: bitchat
  ///
  /// In en, this message translates to:
  /// **'bitchat'**
  String get uiBitchatA99B50;

  /// App-owned interface/status text in lib/src/ui/network_chat_sources.dart:358. English: With a filter of their own. Off: open them from the network's settings only.
  ///
  /// In en, this message translates to:
  /// **'With a filter of their own. Off: open them from the network\'s settings only.'**
  String get uiWithAFilterOfTheir4FD18E;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:76. English: Your Delta Chat invite
  ///
  /// In en, this message translates to:
  /// **'Your Delta Chat invite'**
  String get uiYourDeltaChatInviteEE073F;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:78. English: Show the QR code to a Delta Chat user, or send the link. Whoever has it can start a verified chat with you.
  ///
  /// In en, this message translates to:
  /// **'Show the QR code to a Delta Chat user, or send the link. Whoever has it can start a verified chat with you.'**
  String get uiShowTheQRCodeTo0769AD;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:84. English: Show QR code
  ///
  /// In en, this message translates to:
  /// **'Show QR code'**
  String get uiShowQRCode2DF2DD;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:105. English: Delta Chat chats
  ///
  /// In en, this message translates to:
  /// **'Delta Chat chats'**
  String get uiDeltaChatChats8EBCBC;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:162. English: Group
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get uiGroup171A06;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:176. English: Join with an invite
  ///
  /// In en, this message translates to:
  /// **'Join with an invite'**
  String get uiJoinWithAnInviteC76024;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:194. English: Join
  ///
  /// In en, this message translates to:
  /// **'Join'**
  String get uiJoinE0D731;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:324. English: New Delta Chat group
  ///
  /// In en, this message translates to:
  /// **'New Delta Chat group'**
  String get uiNewDeltaChatGroup7D5142;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:332. English: Group name
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get uiGroupNameEBB7E1;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:569. English: Members
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get uiMembers1CB449;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:574. English: Group invite
  ///
  /// In en, this message translates to:
  /// **'Group invite'**
  String get uiGroupInviteD64669;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:713. English: You are not in this group
  ///
  /// In en, this message translates to:
  /// **'You are not in this group'**
  String get uiYouAreNotInThisCF5BD5;

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:63. English: Start group call
  ///
  /// In en, this message translates to:
  /// **'Start group call'**
  String get uiStartGroupCallC2A083;

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:64. English: Join group call
  ///
  /// In en, this message translates to:
  /// **'Join group call'**
  String get uiJoinGroupCallC9ECF8;

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:305. English: Push-to-talk
  ///
  /// In en, this message translates to:
  /// **'Push-to-talk'**
  String get uiPushToTalk032E78;

  /// App-owned interface/status text in lib/src/ui/reticulum_carrier_panel.dart:216. English: Carry messages over a Reticulum network, for example LoRa radios (RNode) without the internet, through a node running rnsd with a TCP server interface. Conest keeps a Reticulum identity of its own; your contacts learn it automatically.
  ///
  /// In en, this message translates to:
  /// **'Carry messages over a Reticulum network, for example LoRa radios (RNode) without the internet, through a node running rnsd with a TCP server interface. Conest keeps a Reticulum identity of its own; your contacts learn it automatically.'**
  String get uiCarryMessagesOverAReticulum1CE915;

  /// App-owned interface/status text in lib/src/ui/reticulum_carrier_panel.dart:305. English: Node address (rnsd)
  ///
  /// In en, this message translates to:
  /// **'Node address (rnsd)'**
  String get uiNodeAddressRnsdCD61E2;

  /// App-owned interface/status text in lib/src/ui/reticulum_carrier_panel.dart:306. English: USB device
  ///
  /// In en, this message translates to:
  /// **'USB device'**
  String get uiUSBDeviceB47FF0;

  /// App-owned interface/status text in lib/src/ui/reticulum_carrier_panel.dart:307. English: RNode address
  ///
  /// In en, this message translates to:
  /// **'RNode address'**
  String get uiRNodeAddress691283;

  /// App-owned interface/status text in lib/src/ui/reticulum_carrier_panel.dart:308. English: Bluetooth address
  ///
  /// In en, this message translates to:
  /// **'Bluetooth address'**
  String get uiBluetoothAddress0E2BED;

  /// App-owned interface/status text in lib/src/ui/reticulum_carrier_panel.dart:323. English: TCP port
  ///
  /// In en, this message translates to:
  /// **'TCP port'**
  String get uiTCPPortDE05BE;

  /// App-owned interface/status text in lib/src/ui/reticulum_carrier_panel.dart:347. English: EU 869.525
  ///
  /// In en, this message translates to:
  /// **'EU 869.525'**
  String get uiEU233558;

  /// App-owned interface/status text in lib/src/ui/reticulum_carrier_panel.dart:351. English: US 914.875
  ///
  /// In en, this message translates to:
  /// **'US 914.875'**
  String get uiUS5ED166;

  /// App-owned interface/status text in lib/src/ui/app_mode_selector.dart:66. English: Use Conest as a Matrix client only?
  ///
  /// In en, this message translates to:
  /// **'Use Conest as a Matrix client only?'**
  String get uiUseConestAsAMatrix6A44C5;

  /// App-owned interface/status text in lib/src/ui/app_mode_selector.dart:68. English: Your Conest chats are hidden and Conest stops connecting on this device until you switch back. Nothing is deleted. Contacts cannot reach you over Conest meanwhile; their apps keep retrying and deliver when you switch back.
  ///
  /// In en, this message translates to:
  /// **'Your Conest chats are hidden and Conest stops connecting on this device until you switch back. Nothing is deleted. Contacts cannot reach you over Conest meanwhile; their apps keep retrying and deliver when you switch back.'**
  String get uiYourConestChatsAreHiddenCFD853;

  /// App-owned interface/status text in lib/src/ui/app_mode_selector.dart:80. English: Switch
  ///
  /// In en, this message translates to:
  /// **'Switch'**
  String get uiSwitch3E44C9;

  /// App-owned interface/status text in lib/src/ui/seal_avatar.dart:23. English: Seal (animated rings)
  ///
  /// In en, this message translates to:
  /// **'Seal (animated rings)'**
  String get uiSealAnimatedRings29BE2D;

  /// App-owned interface/status text in lib/src/ui/seal_avatar.dart:24. English: Sigil (rune)
  ///
  /// In en, this message translates to:
  /// **'Sigil (rune)'**
  String get uiSigilRuneA0B8A7;

  /// App-owned interface/status text in lib/src/ui/seal_avatar.dart:25. English: Blockie (pixel hash)
  ///
  /// In en, this message translates to:
  /// **'Blockie (pixel hash)'**
  String get uiBlockiePixelHashA265BA;

  /// App-owned interface/status text in lib/src/ui/seal_avatar.dart:26. English: Monogram (initials)
  ///
  /// In en, this message translates to:
  /// **'Monogram (initials)'**
  String get uiMonogramInitials8C6019;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:26. English: New Matrix chat
  ///
  /// In en, this message translates to:
  /// **'New Matrix chat'**
  String get uiNewMatrixChatC065C8;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:32. English: @name:matrix.org
  ///
  /// In en, this message translates to:
  /// **'@name:matrix.org'**
  String get uiNameMatrixOrgD0BB06;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:43. English: Start chat
  ///
  /// In en, this message translates to:
  /// **'Start chat'**
  String get uiStartChat18BB58;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:275. English: Copy text
  ///
  /// In en, this message translates to:
  /// **'Copy text'**
  String get uiCopyText06A76C;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:381. English: Verify {value}
  ///
  /// In en, this message translates to:
  /// **'Verify {value}'**
  String uiVerifyValue1B6B79(String value);

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:505. English: Attach a file
  ///
  /// In en, this message translates to:
  /// **'Attach a file'**
  String get uiAttachAFileAE85E4;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:612. English: Message deleted
  ///
  /// In en, this message translates to:
  /// **'Message deleted'**
  String get uiMessageDeleted3271A7;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:613. English: Unable to decrypt
  ///
  /// In en, this message translates to:
  /// **'Unable to decrypt'**
  String get uiUnableToDecryptFDF88B;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:614. English: 📷 {value}
  ///
  /// In en, this message translates to:
  /// **'📷 {value}'**
  String uiValueCF9C0A(String value);

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:617. English: 📎 {value}
  ///
  /// In en, this message translates to:
  /// **'📎 {value}'**
  String uiValue134796(String value);

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:625. English: {value}: {value2}
  ///
  /// In en, this message translates to:
  /// **'{value}: {value2}'**
  String uiValueValue6EF45D(String value, String value2);

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:686. English: Decline
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get uiDeclineB59CF9;

  /// App-owned interface/status text in lib/src/ui/email_carrier_panel.dart:111. English: Carry messages as encrypted email when other routes fail, like Delta Chat. The mail servers see both addresses and when, not what. Your contacts learn the address automatically.
  ///
  /// In en, this message translates to:
  /// **'Carry messages as encrypted email when other routes fail, like Delta Chat. The mail servers see both addresses and when, not what. Your contacts learn the address automatically.'**
  String get uiCarryMessagesAsEncryptedEmail0D19EA;

  /// App-owned interface/status text in lib/src/ui/email_carrier_panel.dart:155. English: Use my own email account instead
  ///
  /// In en, this message translates to:
  /// **'Use my own email account instead'**
  String get uiUseMyOwnEmailAccountE78C1D;

  /// App-owned interface/status text in lib/src/ui/nostr_carrier_panel.dart:77. English: Nostr relays
  ///
  /// In en, this message translates to:
  /// **'Nostr relays'**
  String get uiNostrRelaysBD8BAD;

  /// App-owned interface/status text in lib/src/ui/nostr_carrier_panel.dart:79. English: Carry messages through public Nostr relays when other routes fail. Relays see that someone writes to you and when, not who or what. Uses a separate key; your contacts learn it automatically.
  ///
  /// In en, this message translates to:
  /// **'Carry messages through public Nostr relays when other routes fail. Relays see that someone writes to you and when, not who or what. Uses a separate key; your contacts learn it automatically.'**
  String get uiCarryMessagesThroughPublicNostr729B94;

  /// App-owned interface/status text in lib/src/ui/nostr_carrier_panel.dart:122. English: Relays you read from (one per line, up to 4)
  ///
  /// In en, this message translates to:
  /// **'Relays you read from (one per line, up to 4)'**
  String get uiRelaysYouReadFromOne020C0A;

  /// App-owned interface/status text in lib/src/ui/nostr_carrier_panel.dart:138. English: Save relays
  ///
  /// In en, this message translates to:
  /// **'Save relays'**
  String get uiSaveRelays91CBA8;

  /// App-owned interface/status text in lib/src/ui/nostr_carrier_panel.dart:146. English: Default relays
  ///
  /// In en, this message translates to:
  /// **'Default relays'**
  String get uiDefaultRelays5C909F;

  /// App-owned interface/status text in lib/src/ui/radio_chats_screen.dart:122. English: New chat
  ///
  /// In en, this message translates to:
  /// **'New chat'**
  String get uiNewChat009BF6;

  /// App-owned interface/status text in lib/src/ui/radio_chats_screen.dart:130. English: Node address
  ///
  /// In en, this message translates to:
  /// **'Node address'**
  String get uiNodeAddress896F20;

  /// App-owned interface/status text in lib/src/ui/radio_chats_screen.dart:304. English: Delete chat
  ///
  /// In en, this message translates to:
  /// **'Delete chat'**
  String get uiDeleteChatDB9121;

  /// App-owned interface/status text in lib/src/ui/radio_chats_screen.dart:405. English: Turn on app messages to write
  ///
  /// In en, this message translates to:
  /// **'Turn on app messages to write'**
  String get uiTurnOnAppMessagesTo7DCA13;

  /// App-owned interface/status text in lib/src/ui/bitchat_chats_screen.dart:39. English: bitchat nearby
  ///
  /// In en, this message translates to:
  /// **'bitchat nearby'**
  String get uiBitchatNearbyD0C416;

  /// App-owned interface/status text in lib/src/ui/bitchat_chats_screen.dart:55. English: Mesh chat
  ///
  /// In en, this message translates to:
  /// **'Mesh chat'**
  String get uiMeshChat7BF668;

  /// App-owned interface/status text in lib/src/ui/bitchat_chats_screen.dart:333. English: Hidden: turn on "Reachable by bitchat users"
  ///
  /// In en, this message translates to:
  /// **'Hidden: turn on \"Reachable by bitchat users\"'**
  String get uiHiddenTurnOnReachableBy0103C9;

  /// App-owned interface/status text in lib/src/ui/matrix_verification_dialog.dart:203. English: They don't match
  ///
  /// In en, this message translates to:
  /// **'They don\'t match'**
  String get uiTheyDonTMatch27EF0C;

  /// App-owned interface/status text in lib/src/ui/matrix_verification_dialog.dart:207. English: They match
  ///
  /// In en, this message translates to:
  /// **'They match'**
  String get uiTheyMatch6FB8EB;

  /// Settings → Connectivity, Bluetooth mesh: Name bitchat users see
  ///
  /// In en, this message translates to:
  /// **'Name bitchat users see'**
  String get uiNameBitchatUsersSee1CE7E3;

  /// Settings → Connectivity, Bluetooth mesh: A name you choose stays when your identity changes, so people nearby can tell it is still you. Leave it empty for a new "anon" name with each identity.
  ///
  /// In en, this message translates to:
  /// **'A name you choose stays when your identity changes, so people nearby can tell it is still you. Leave it empty for a new \"anon\" name with each identity.'**
  String get uiANameYouChooseStays17E677;

  /// Settings → Connectivity, Bluetooth mesh: Bluetooth mesh
  ///
  /// In en, this message translates to:
  /// **'Bluetooth mesh'**
  String get uiBluetoothMeshC8B7F1;

  /// Settings → Connectivity, Bluetooth mesh: Reach contacts nearby without any network: messages hop from device to device over Bluetooth, through Conest and bitchat users alike, and this device relays for others. This device does not show up in bitchat, and what it sends looks like any bitchat private message, with ids that change every hour.
  ///
  /// In en, this message translates to:
  /// **'Reach contacts nearby without any network: messages hop from device to device over Bluetooth, through Conest and bitchat users alike, and this device relays for others. This device does not show up in bitchat, and what it sends looks like any bitchat private message, with ids that change every hour.'**
  String get uiReachContactsNearbyWithoutAny9E9649;

  /// Settings → Connectivity, Bluetooth mesh: Reachable by bitchat users
  ///
  /// In en, this message translates to:
  /// **'Reachable by bitchat users'**
  String get uiReachableByBitchatUsers568021;

  /// Settings → Connectivity, Bluetooth mesh: Share internet with bitchat users
  ///
  /// In en, this message translates to:
  /// **'Share internet with bitchat users'**
  String get uiShareInternetWithBitchatUsers572F90;

  /// Settings → Connectivity, Bluetooth mesh: Change name
  ///
  /// In en, this message translates to:
  /// **'Change name'**
  String get uiChangeNameE46692;

  /// Settings → Connectivity, Bluetooth mesh: New identity
  ///
  /// In en, this message translates to:
  /// **'New identity'**
  String get uiNewIdentityA119CF;

  /// Settings → Connectivity, Bluetooth mesh: bitchat chats
  ///
  /// In en, this message translates to:
  /// **'bitchat chats'**
  String get uiBitchatChatsC74EC3;

  /// App-owned interface/status text in lib/src/ui/matrix_home_screen.dart:142. English: The Matrix client is not available on this device, so Conest cannot run in Matrix-only mode here.
  ///
  /// In en, this message translates to:
  /// **'The Matrix client is not available on this device, so Conest cannot run in Matrix-only mode here.'**
  String get uiTheMatrixClientIsNot01A5B4;

  /// App-owned interface/status text in lib/src/ui/matrix_home_screen.dart:149. English: Use Conest
  ///
  /// In en, this message translates to:
  /// **'Use Conest'**
  String get uiUseConest12EEF3;

  /// App-owned interface/status text in lib/src/ui/matrix_home_screen.dart:170. English: Search rooms
  ///
  /// In en, this message translates to:
  /// **'Search rooms'**
  String get uiSearchRoomsCCE4F9;

  /// App-owned interface/status text in lib/src/ui/tor_carrier_panel.dart:84. English: Reach contacts through Tor onion services: neither side nor the network learns where the other is. Slower than other routes; add bridges where Tor is blocked.
  ///
  /// In en, this message translates to:
  /// **'Reach contacts through Tor onion services: neither side nor the network learns where the other is. Slower than other routes; add bridges where Tor is blocked.'**
  String get uiReachContactsThroughTorOnion8B8A98;

  /// App-owned interface/status text in lib/src/ui/tor_carrier_panel.dart:100. English: Bridges (optional, one per line)
  ///
  /// In en, this message translates to:
  /// **'Bridges (optional, one per line)'**
  String get uiBridgesOptionalOnePerLine110291;

  /// App-owned interface/status text in lib/src/ui/tor_carrier_panel.dart:102. English: 192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413
  ///
  /// In en, this message translates to:
  /// **'192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413'**
  String get uiEEFEBFE80B7A;

  /// App-owned interface/status text in lib/src/ui/tor_carrier_panel.dart:103. English: obfs4 192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413 cert=… iat-mode=0
  ///
  /// In en, this message translates to:
  /// **'obfs4 192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413 cert=… iat-mode=0'**
  String get uiObfsEEFEAD0EDF;

  /// App-owned interface/status text in lib/src/ui/tor_carrier_panel.dart:109. English: Lines from bridges.torproject.org, starting with the type: obfs4, webtunnel, snowflake or meek_lite (or plain bridges: address and fingerprint).
  ///
  /// In en, this message translates to:
  /// **'Lines from bridges.torproject.org, starting with the type: obfs4, webtunnel, snowflake or meek_lite (or plain bridges: address and fingerprint).'**
  String get uiLinesFromBridgesTorprojectOrgF08389;

  /// App-owned interface/status text in lib/src/ui/tor_carrier_panel.dart:113. English: Plain bridges only (address and fingerprint) in this build.
  ///
  /// In en, this message translates to:
  /// **'Plain bridges only (address and fingerprint) in this build.'**
  String get uiPlainBridgesOnlyAddressAnd7F0B60;

  /// App-owned interface/status text in lib/src/ui/tor_carrier_panel.dart:126. English: Use these bridges
  ///
  /// In en, this message translates to:
  /// **'Use these bridges'**
  String get uiUseTheseBridgesC1FA11;

  /// App-owned interface/status text in lib/src/ui/nostr_chats_screen.dart:52. English: Nostr private messages
  ///
  /// In en, this message translates to:
  /// **'Nostr private messages'**
  String get uiNostrPrivateMessagesDF74A3;

  /// App-owned interface/status text in lib/src/ui/nostr_chats_screen.dart:54. English: Chat with anyone on Nostr (0xchat, Amethyst, Damus and other apps that use NIP-17), one to one or in small groups. A Nostr account of its own, never linked to your Conest contacts. End-to-end encrypted, but without forward secrecy.
  ///
  /// In en, this message translates to:
  /// **'Chat with anyone on Nostr (0xchat, Amethyst, Damus and other apps that use NIP-17), one to one or in small groups. A Nostr account of its own, never linked to your Conest contacts. End-to-end encrypted, but without forward secrecy.'**
  String get uiChatWithAnyoneOnNostrA867BC;

  /// App-owned interface/status text in lib/src/ui/nostr_chats_screen.dart:72. English: Your Nostr address
  ///
  /// In en, this message translates to:
  /// **'Your Nostr address'**
  String get uiYourNostrAddress5CF7C6;

  /// App-owned interface/status text in lib/src/ui/nostr_chats_screen.dart:75. English: Copy (with your relays)
  ///
  /// In en, this message translates to:
  /// **'Copy (with your relays)'**
  String get uiCopyWithYourRelaysD49669;

  /// App-owned interface/status text in lib/src/ui/nostr_chats_screen.dart:86. English: Nostr chats
  ///
  /// In en, this message translates to:
  /// **'Nostr chats'**
  String get uiNostrChats3D786C;

  /// App-owned interface/status text in lib/src/ui/nostr_chats_screen.dart:122. English: New Nostr chat
  ///
  /// In en, this message translates to:
  /// **'New Nostr chat'**
  String get uiNewNostrChat68199C;

  /// App-owned interface/status text in lib/src/ui/nostr_chats_screen.dart:130. English: npub1… (several for a group)
  ///
  /// In en, this message translates to:
  /// **'npub1… (several for a group)'**
  String get uiNpubSeveralForAGroupE6ED77;

  /// App-owned interface/status text in lib/src/ui/meshcore_carrier_panel.dart:102. English: Carry short messages over a MeshCore LoRa mesh through your companion radio, without the internet. Conest adds your contacts to the radio so it accepts their messages.
  ///
  /// In en, this message translates to:
  /// **'Carry short messages over a MeshCore LoRa mesh through your companion radio, without the internet. Conest adds your contacts to the radio so it accepts their messages.'**
  String get uiCarryShortMessagesOverAFA94B6;

  /// App-owned interface/status text in lib/src/ui/meshcore_carrier_panel.dart:189. English: Messages with MeshCore app users
  ///
  /// In en, this message translates to:
  /// **'Messages with MeshCore app users'**
  String get uiMessagesWithMeshCoreAppUsersDE77BA;

  /// App-owned interface/status text in lib/src/ui/meshcore_carrier_panel.dart:191. English: Read and write the MeshCore apps' own messages through this radio: with its contacts, and on its channels as group chats. They are protected only as MeshCore protects them.
  ///
  /// In en, this message translates to:
  /// **'Read and write the MeshCore apps\' own messages through this radio: with its contacts, and on its channels as group chats. They are protected only as MeshCore protects them.'**
  String get uiReadAndWriteTheMeshCore98E60E;

  /// App-owned interface/status text in lib/src/ui/meshcore_carrier_panel.dart:206. English: MeshCore chats
  ///
  /// In en, this message translates to:
  /// **'MeshCore chats'**
  String get uiMeshCoreChats82C29C;

  /// App-owned interface/status text in lib/src/ui/file_metadata_consent.dart:13. English: Send with its details?
  ///
  /// In en, this message translates to:
  /// **'Send with its details?'**
  String get uiSendWithItsDetailsF287FB;

  /// App-owned interface/status text in lib/src/ui/file_metadata_consent.dart:22. English: Send anyway
  ///
  /// In en, this message translates to:
  /// **'Send anyway'**
  String get uiSendAnyway911263;

  /// App-owned interface/status text in lib/src/ui/error_history_screen.dart:60. English: Save the error history
  ///
  /// In en, this message translates to:
  /// **'Save the error history'**
  String get uiSaveTheErrorHistory0B3413;

  /// App-owned interface/status text in lib/src/ui/error_history_screen.dart:68. English: Saved the error history to {value}.
  ///
  /// In en, this message translates to:
  /// **'Saved the error history to {value}.'**
  String uiSavedTheErrorHistoryTo5271C5(String value);

  /// App-owned interface/status text in lib/src/ui/error_history_screen.dart:70. English: Saving the error history failed: {value}
  ///
  /// In en, this message translates to:
  /// **'Saving the error history failed: {value}'**
  String uiSavingTheErrorHistoryFailed72A33A(String value);

  /// App-owned interface/status text in lib/src/ui/error_history_screen.dart:88. English: Save to a file
  ///
  /// In en, this message translates to:
  /// **'Save to a file'**
  String get uiSaveToAFile5BB648;

  /// App-owned interface/status text in lib/src/ui/error_history_screen.dart:93. English: Clear
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get uiClear719EA3;

  /// App-owned interface/status text in lib/src/ui/error_history_screen.dart:120. English: Filter
  ///
  /// In en, this message translates to:
  /// **'Filter'**
  String get uiFilterD7DECF;

  /// App-owned interface/status text in lib/src/ui/error_history_screen.dart:128. English: Errors only (hide the debug log)
  ///
  /// In en, this message translates to:
  /// **'Errors only (hide the debug log)'**
  String get uiErrorsOnlyHideTheDebugECA1DD;

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:65. English: {value} h
  ///
  /// In en, this message translates to:
  /// **'{value} h'**
  String uiValueH171B92(String value);

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:66. English: {value} min
  ///
  /// In en, this message translates to:
  /// **'{value} min'**
  String uiValueMin439C52(String value);

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:67. English: Their clock is about {value} {value}; times here are by this device.
  ///
  /// In en, this message translates to:
  /// **'Their clock is about {value} {value}; times here are by this device.'**
  String uiTheirClockIsAboutValueF406F1(String value);

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:73. English: {value} B
  ///
  /// In en, this message translates to:
  /// **'{value} B'**
  String uiValueB7CFB44(String value);

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:74. English: {value} KB
  ///
  /// In en, this message translates to:
  /// **'{value} KB'**
  String uiValueKB554C06(String value);

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:76. English: {value} MB
  ///
  /// In en, this message translates to:
  /// **'{value} MB'**
  String uiValueMBDB5A1C(String value);

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:78. English: {value} GB
  ///
  /// In en, this message translates to:
  /// **'{value} GB'**
  String uiValueGB0A98F3(String value);

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:83. English: sent
  ///
  /// In en, this message translates to:
  /// **'sent'**
  String get uiSent27E770;

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:84. English: waiting on the relay
  ///
  /// In en, this message translates to:
  /// **'waiting on the relay'**
  String get uiWaitingOnTheRelayED66FF;

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:85. English: reached their device
  ///
  /// In en, this message translates to:
  /// **'reached their device'**
  String get uiReachedTheirDevice0FE289;

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:86. English: delivered
  ///
  /// In en, this message translates to:
  /// **'delivered'**
  String get uiDeliveredF81891;

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:86. English: received
  ///
  /// In en, this message translates to:
  /// **'received'**
  String get uiReceived38428A;

  /// App-owned interface/status text in lib/src/ui/meshtastic_carrier_panel.dart:109. English: Carry short messages over a Meshtastic LoRa mesh, without the internet, through your Meshtastic radio. Contacts need Conest with a radio in the same mesh.
  ///
  /// In en, this message translates to:
  /// **'Carry short messages over a Meshtastic LoRa mesh, without the internet, through your Meshtastic radio. Contacts need Conest with a radio in the same mesh.'**
  String get uiCarryShortMessagesOverADD8570;

  /// App-owned interface/status text in lib/src/ui/meshtastic_carrier_panel.dart:169. English: Find devices
  ///
  /// In en, this message translates to:
  /// **'Find devices'**
  String get uiFindDevices98771A;

  /// App-owned interface/status text in lib/src/ui/meshtastic_carrier_panel.dart:188. English: Radio address
  ///
  /// In en, this message translates to:
  /// **'Radio address'**
  String get uiRadioAddressD288E6;

  /// App-owned interface/status text in lib/src/ui/meshtastic_carrier_panel.dart:221. English: Messages with Meshtastic app users
  ///
  /// In en, this message translates to:
  /// **'Messages with Meshtastic app users'**
  String get uiMessagesWithMeshtasticAppUsers812B3A;

  /// App-owned interface/status text in lib/src/ui/meshtastic_carrier_panel.dart:223. English: Read and write the Meshtastic apps' own messages through this radio: direct ones, and its channels as group chats. They are protected only as Meshtastic protects them.
  ///
  /// In en, this message translates to:
  /// **'Read and write the Meshtastic apps\' own messages through this radio: direct ones, and its channels as group chats. They are protected only as Meshtastic protects them.'**
  String get uiReadAndWriteTheMeshtastic995E5D;

  /// App-owned interface/status text in lib/src/ui/meshtastic_carrier_panel.dart:239. English: Meshtastic chats
  ///
  /// In en, this message translates to:
  /// **'Meshtastic chats'**
  String get uiMeshtasticChats46BEF8;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:748. English: Clear selection
  ///
  /// In en, this message translates to:
  /// **'Clear selection'**
  String get uiClearSelection247FD6;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:787. English: Browse files…
  ///
  /// In en, this message translates to:
  /// **'Browse files…'**
  String get uiBrowseFilesAF7C13;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:847. English: Select more
  ///
  /// In en, this message translates to:
  /// **'Select more'**
  String get uiSelectMoreE38EF3;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:851. English: Allow all
  ///
  /// In en, this message translates to:
  /// **'Allow all'**
  String get uiAllowAllA16326;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:905. English: Caption…
  ///
  /// In en, this message translates to:
  /// **'Caption…'**
  String get uiCaptionDA5C59;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:951. English: Open settings
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get uiOpenSettingsFD7108;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:1159. English: Discard changes?
  ///
  /// In en, this message translates to:
  /// **'Discard changes?'**
  String get uiDiscardChangesD3F0B4;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:1161. English: Your edits will be lost. The original image stays in your gallery.
  ///
  /// In en, this message translates to:
  /// **'Your edits will be lost. The original image stays in your gallery.'**
  String get uiYourEditsWillBeLostB34663;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:1166. English: Keep editing
  ///
  /// In en, this message translates to:
  /// **'Keep editing'**
  String get uiKeepEditingD4D9E3;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:1170. English: Discard
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get uiDiscard36FFF6;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:1269. English: Rotate left
  ///
  /// In en, this message translates to:
  /// **'Rotate left'**
  String get uiRotateLeft6F72F3;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:1274. English: Rotate right
  ///
  /// In en, this message translates to:
  /// **'Rotate right'**
  String get uiRotateRightB75F23;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:1281. English: Apply crop
  ///
  /// In en, this message translates to:
  /// **'Apply crop'**
  String get uiApplyCropA43CCF;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:1281. English: Crop
  ///
  /// In en, this message translates to:
  /// **'Crop'**
  String get uiCropC5DB3D;

  /// App-owned interface/status text in lib/src/group_file_tile.dart:98. English: Verified download progress
  ///
  /// In en, this message translates to:
  /// **'Verified download progress'**
  String get uiVerifiedDownloadProgressBED7C2;

  /// App-owned interface/status text in lib/src/group_file_tile.dart:107. English: Sharing with group
  ///
  /// In en, this message translates to:
  /// **'Sharing with group'**
  String get uiSharingWithGroup2AED71;

  /// App-owned interface/status text in lib/src/group_file_tile.dart:115. English: Open
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get uiOpenCF9B77;

  /// App-owned interface/status text in lib/src/group_file_tile.dart:132. English: Stop sharing
  ///
  /// In en, this message translates to:
  /// **'Stop sharing'**
  String get uiStopSharing0E45AE;

  /// App-owned interface/status text in lib/src/group_file_tile.dart:137. English: Remove local copy
  ///
  /// In en, this message translates to:
  /// **'Remove local copy'**
  String get uiRemoveLocalCopy80FA01;

  /// App-owned interface/status text in lib/src/qr_scan_screen.dart:39. English: Scan Invite
  ///
  /// In en, this message translates to:
  /// **'Scan Invite'**
  String get uiScanInviteEFC78A;

  /// App-owned interface/status text in lib/src/messenger_controller.dart:1124. English: {value}:{value2}
  ///
  /// In en, this message translates to:
  /// **'{value}:{value2}'**
  String uiValueValue176D15(String value, String value2);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:1128. English: default relay {value}
  ///
  /// In en, this message translates to:
  /// **'default relay {value}'**
  String uiDefaultRelayValueBD3FD1(String value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:1222. English: samples={value} slowOver100ms={value2} maxTotalMs={value} maxBuildMs={value} maxRasterMs={value}
  ///
  /// In en, this message translates to:
  /// **'samples={value} slowOver100ms={value2} maxTotalMs={value} maxBuildMs={value} maxRasterMs={value}'**
  String uiSamplesValueSlowOverMsValueAE2EBF(String value, String value2);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:12706. English: Conversation
  ///
  /// In en, this message translates to:
  /// **'Conversation'**
  String get uiConversation2A20C7;

  /// App-owned interface/status text in lib/src/messenger_controller.dart:14462. English: Shared {value} with the group as a regular attachment; some members need an update for voice playback.
  ///
  /// In en, this message translates to:
  /// **'Shared {value} with the group as a regular attachment; some members need an update for voice playback.'**
  String uiSharedValueWithTheGroup163418(String value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:14463. English: Shared {value} with the group.
  ///
  /// In en, this message translates to:
  /// **'Shared {value} with the group.'**
  String uiSharedValueWithTheGroupAE4134(String value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:28120. English: {value} backoff {value2}s streak {value3}
  ///
  /// In en, this message translates to:
  /// **'{value} backoff {value2}s streak {value3}'**
  String uiValueBackoffValueSStreak25FF09(
    String value,
    String value2,
    String value3,
  );

  /// App-owned interface/status text in lib/src/messenger_controller.dart:28127. English: (none)
  ///
  /// In en, this message translates to:
  /// **'(none)'**
  String get uiNone3C6B18;

  /// App-owned interface/status text in lib/src/messenger_controller.dart:28574. English: LAN node :{value} on
  ///
  /// In en, this message translates to:
  /// **'LAN node :{value} on'**
  String uiLANNodeValueOn5D539E(String value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:28575. English: LAN node unavailable
  ///
  /// In en, this message translates to:
  /// **'LAN node unavailable'**
  String get uiLANNodeUnavailable9CFA32;

  /// App-owned interface/status text in lib/src/messenger_controller.dart:28578. English: LAN {value}
  ///
  /// In en, this message translates to:
  /// **'LAN {value}'**
  String uiLANValueA8EEF3(String value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:28588. English: relay {value} down
  ///
  /// In en, this message translates to:
  /// **'relay {value} down'**
  String uiRelayValueDownD6B267(String value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:28589. English: relay {value}
  ///
  /// In en, this message translates to:
  /// **'relay {value}'**
  String uiRelayValueA6D70A(String value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:28592. English: no internet relay
  ///
  /// In en, this message translates to:
  /// **'no internet relay'**
  String get uiNoInternetRelay55D2CE;

  /// App-owned interface/status text in lib/src/messenger_controller.dart:28628. English: {value}={value2}
  ///
  /// In en, this message translates to:
  /// **'{value}={value2}'**
  String uiValueValue42DC94(String value, String value2);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:30566. English: {value} has been out of touch for a while: nothing syncs with it until you confirm it in Settings → Devices.
  ///
  /// In en, this message translates to:
  /// **'{value} has been out of touch for a while: nothing syncs with it until you confirm it in Settings → Devices.'**
  String uiValueHasBeenOutOf039D48(String value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:30628. English: {value} is one of your own devices now; its old chat is no longer listed.
  ///
  /// In en, this message translates to:
  /// **'{value} is one of your own devices now; its old chat is no longer listed.'**
  String uiValueIsOneOfYourE4FD9C(String value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:30893. English: Your devices disagree on which devices are in the account, and together there would be more than {value}. Remove one in Settings → Devices.
  ///
  /// In en, this message translates to:
  /// **'Your devices disagree on which devices are in the account, and together there would be more than {value}. Remove one in Settings → Devices.'**
  String uiYourDevicesDisagreeOnWhich2E7001(String value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:31294. English: {value} added a device: {value2}.
  ///
  /// In en, this message translates to:
  /// **'{value} added a device: {value2}.'**
  String uiValueAddedADeviceValue710908(String value, String value2);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:32181. English: Unknown {value}
  ///
  /// In en, this message translates to:
  /// **'Unknown {value}'**
  String uiUnknownValue9B520C(String value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:32220. English: Read by all {value}
  ///
  /// In en, this message translates to:
  /// **'Read by all {value}'**
  String uiReadByAllValue43BA5A(String value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:32223. English: Delivered to all {value}
  ///
  /// In en, this message translates to:
  /// **'Delivered to all {value}'**
  String uiDeliveredToAllValue71E077(String value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:32226. English: Accepted by {value} of {value2}
  ///
  /// In en, this message translates to:
  /// **'Accepted by {value} of {value2}'**
  String uiAcceptedByValueOfValue826A0E(String value, String value2);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:32231. English: Waiting for {value} member(s)
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{Waiting for {value} member} other{Waiting for {value} members}}'**
  String uiWaitingForValueMemberS5A8BA6(int value);

  /// App-owned interface/status text in lib/main.dart:333. English: Conest
  ///
  /// In en, this message translates to:
  /// **'Conest'**
  String get uiConest26885B;

  /// App-owned interface/status text in lib/main.dart:2434. English: {value}{value2}{value3}
  ///
  /// In en, this message translates to:
  /// **'{value}{value2}{value3}'**
  String uiValueValueValueE9AA4A(String value, String value2, String value3);

  /// App-owned interface/status text in lib/main.dart:2923. English: {value} skipped: {value2} MB exceeds the {value3} MB cap.
  ///
  /// In en, this message translates to:
  /// **'{value} skipped: {value2} MB exceeds the {value3} MB cap.'**
  String uiValueSkippedValueMBExceedsD0800C(
    String value,
    String value2,
    String value3,
  );

  /// App-owned interface/status text in lib/main.dart:3830. English: Route
  ///
  /// In en, this message translates to:
  /// **'Route'**
  String get uiRoute499952;

  /// App-owned interface/status text in lib/main.dart:3832. English: Safety number
  ///
  /// In en, this message translates to:
  /// **'Safety number'**
  String get uiSafetyNumber5ED2D3;

  /// App-owned interface/status text in lib/main.dart:3836. English: Iroh endpoint
  ///
  /// In en, this message translates to:
  /// **'Iroh endpoint'**
  String get uiIrohEndpoint72F674;

  /// App-owned interface/status text in lib/main.dart:3840. English: Device
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get uiDeviceA5A74A;

  /// App-owned interface/status text in lib/main.dart:4870. English: LAN lobby
  ///
  /// In en, this message translates to:
  /// **'LAN lobby'**
  String get uiLANLobbyC16DC8;

  /// App-owned interface/status text in lib/main.dart:5657. English: Members · {value}
  ///
  /// In en, this message translates to:
  /// **'Members · {value}'**
  String uiMembersValue541E72(String value);

  /// App-owned interface/status text in lib/main.dart:5972. English: Node · online
  ///
  /// In en, this message translates to:
  /// **'Node · online'**
  String get uiNodeOnlineFAC64A;

  /// App-owned interface/status text in lib/main.dart:6064. English: safety {value}
  ///
  /// In en, this message translates to:
  /// **'safety {value}'**
  String uiSafetyValueC542B8(String value);

  /// App-owned interface/status text in lib/main.dart:7791. English: {value}%
  ///
  /// In en, this message translates to:
  /// **'{value}%'**
  String uiValue3072D4(String value);

  /// App-owned interface/status text in lib/main.dart:9423. English: {value} members
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{{value} member} other{{value} members}}'**
  String uiValueMembersCEF563(int value);

  /// App-owned interface/status text in lib/main.dart:9466. English: pairwise
  ///
  /// In en, this message translates to:
  /// **'pairwise'**
  String get uiPairwise64A0EF;

  /// App-owned interface/status text in lib/main.dart:9801. English: Paste media
  ///
  /// In en, this message translates to:
  /// **'Paste media'**
  String get uiPasteMedia4831DE;

  /// App-owned interface/status text in lib/main.dart:10377. English: RELAY
  ///
  /// In en, this message translates to:
  /// **'RELAY'**
  String get uiRELAYA1C0CF;

  /// App-owned interface/status text in lib/main.dart:11003. English: Sent as a plain Matrix message
  ///
  /// In en, this message translates to:
  /// **'Sent as a plain Matrix message'**
  String get uiSentAsAPlainMatrixAAE694;

  /// App-owned interface/status text in lib/main.dart:11278. English: Only on this device
  ///
  /// In en, this message translates to:
  /// **'Only on this device'**
  String get uiOnlyOnThisDevice7D64C4;

  /// App-owned interface/status text in lib/main.dart:12590. English: Connectivity is off. Turn on LAN or Online to exchange this invite.
  ///
  /// In en, this message translates to:
  /// **'Connectivity is off. Turn on LAN or Online to exchange this invite.'**
  String get uiConnectivityIsOffTurnOnE42D4A;

  /// App-owned interface/status text in lib/main.dart:12876. English: Connectivity is off. Turn on LAN or Online before sharing this invite.
  ///
  /// In en, this message translates to:
  /// **'Connectivity is off. Turn on LAN or Online before sharing this invite.'**
  String get uiConnectivityIsOffTurnOnFA573F;

  /// App-owned interface/status text in lib/main.dart:13348. English: Receive Beam
  ///
  /// In en, this message translates to:
  /// **'Receive Beam'**
  String get uiReceiveBeam2CB58B;

  /// App-owned interface/status text in lib/main.dart:13357. English: Send encrypted file
  ///
  /// In en, this message translates to:
  /// **'Send encrypted file'**
  String get uiSendEncryptedFile99D424;

  /// App-owned interface/status text in lib/main.dart:13364. English: Send public file
  ///
  /// In en, this message translates to:
  /// **'Send public file'**
  String get uiSendPublicFileF81389;

  /// App-owned interface/status text in lib/main.dart:13372. English: Beam contact invite
  ///
  /// In en, this message translates to:
  /// **'Beam contact invite'**
  String get uiBeamContactInvite2BAB4C;

  /// App-owned interface/status text in lib/main.dart:14517. English: Devices
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get uiDevicesDF485C;

  /// App-owned interface/status text in lib/main.dart:16148. English: WARN
  ///
  /// In en, this message translates to:
  /// **'WARN'**
  String get uiWARNC2FD77;

  /// App-owned interface/status text in lib/main.dart:16156. English: DOWN
  ///
  /// In en, this message translates to:
  /// **'DOWN'**
  String get uiDOWN30E504;

  /// App-owned interface/status text in lib/main.dart:16164. English: AVG RTT
  ///
  /// In en, this message translates to:
  /// **'AVG RTT'**
  String get uiAVGRTTE96B26;

  /// App-owned interface/status text in lib/main.dart:17666. English: Routing — {value}
  ///
  /// In en, this message translates to:
  /// **'Routing — {value}'**
  String uiRoutingValueFC4557(String value);

  /// App-owned interface/status text in lib/main.dart:18601. English: Active ({value})
  ///
  /// In en, this message translates to:
  /// **'Active ({value})'**
  String uiActiveValueC78B63(String value);

  /// App-owned interface/status text in lib/main.dart:18614. English: Recent ({value})
  ///
  /// In en, this message translates to:
  /// **'Recent ({value})'**
  String uiRecentValueB82237(String value);

  /// App-owned interface/status text in lib/main.dart:20641. English: direct
  ///
  /// In en, this message translates to:
  /// **'direct'**
  String get uiDirect24A173;

  /// App-owned interface/status text in lib/main.dart:20649. English: relay
  ///
  /// In en, this message translates to:
  /// **'relay'**
  String get uiRelayBD28B2;

  /// App-owned interface/status text in lib/main.dart:20653. English: routing
  ///
  /// In en, this message translates to:
  /// **'routing'**
  String get uiRoutingECF60A;

  /// App-owned interface/status text in lib/src/ui/network_chat_sources.dart:230. English: Invitation: {value}
  ///
  /// In en, this message translates to:
  /// **'Invitation: {value}'**
  String uiInvitationValue6F0633(String value);

  /// App-owned interface/status text in lib/src/ui/network_chat_sources.dart:291. English: Mesh chat (nearby)
  ///
  /// In en, this message translates to:
  /// **'Mesh chat (nearby)'**
  String get uiMeshChatNearbyA35A63;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:560. English: Verified with an invite
  ///
  /// In en, this message translates to:
  /// **'Verified with an invite'**
  String get uiVerifiedWithAnInviteBD826F;

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:337. English: Hold to talk, or hold Space
  ///
  /// In en, this message translates to:
  /// **'Hold to talk, or hold Space'**
  String get uiHoldToTalkOrHold74FC22;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:358. English: End-to-end encrypted (Matrix)
  ///
  /// In en, this message translates to:
  /// **'End-to-end encrypted (Matrix)'**
  String get uiEndToEndEncryptedMatrix9E4418;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:373. English: Verified
  ///
  /// In en, this message translates to:
  /// **'Verified'**
  String get uiVerifiedAED3B8;

  /// App-owned interface/status text in lib/src/ui/signature_panels.dart:319. English: {value} · {value2}
  ///
  /// In en, this message translates to:
  /// **'{value} · {value2}'**
  String uiValueValue64684F(String value, String value2);

  /// App-owned interface/status text in lib/src/ui/radio_chats_screen.dart:54. English: Primary channel
  ///
  /// In en, this message translates to:
  /// **'Primary channel'**
  String get uiPrimaryChannel53B8E1;

  /// App-owned interface/status text in lib/src/ui/radio_chats_screen.dart:55. English: Channel {value}
  ///
  /// In en, this message translates to:
  /// **'Channel {value}'**
  String uiChannelValue76ED1D(String value);

  /// App-owned interface/status text in lib/src/ui/radio_chats_screen.dart:80. English: Public channel
  ///
  /// In en, this message translates to:
  /// **'Public channel'**
  String get uiPublicChannelA9795B;

  /// App-owned interface/status text in lib/src/ui/matrix_verification_dialog.dart:87. English: description
  ///
  /// In en, this message translates to:
  /// **'description'**
  String get uiDescriptionCB3291;

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:67. English: Their clock is about {value} {value2}; times here are by this device.
  ///
  /// In en, this message translates to:
  /// **'Their clock is about {value} {value2}; times here are by this device.'**
  String uiTheirClockIsAboutValue7DB956(String value, String value2);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:1222. English: samples={value} slowOver100ms={value2} maxTotalMs={value3} maxBuildMs={value4} maxRasterMs={value5}
  ///
  /// In en, this message translates to:
  /// **'samples={value} slowOver100ms={value2} maxTotalMs={value3} maxBuildMs={value4} maxRasterMs={value5}'**
  String uiSamplesValueSlowOverMsValue45CEDE(
    String value,
    String value2,
    String value3,
    String value4,
    String value5,
  );

  /// App-owned interface/status text in lib/src/messenger_controller.dart:4874. English: {value}…
  ///
  /// In en, this message translates to:
  /// **'{value}…'**
  String uiValueF36340(String value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:17708. English: Conest transfer
  ///
  /// In en, this message translates to:
  /// **'Conest transfer'**
  String get uiConestTransfer406028;

  /// App-owned interface/status text in lib/src/messenger_controller.dart:17709. English: {value} Conest transfers
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{{value} Conest transfers} other{{value} Conest transfers}}'**
  String uiValueConestTransfersF846F8(int value);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:25880. English: via {value} ({value2})
  ///
  /// In en, this message translates to:
  /// **'via {value} ({value2})'**
  String uiViaValueValue37232D(String value, String value2);

  /// App-owned interface/status text in lib/src/messenger_controller.dart:25904. English: back through the contact who passed their message on
  ///
  /// In en, this message translates to:
  /// **'back through the contact who passed their message on'**
  String get uiBackThroughTheContactWhoD09BD0;

  /// App-owned interface/status text in lib/src/messenger_controller.dart:33313. English: Conest relay {value}
  ///
  /// In en, this message translates to:
  /// **'Conest relay {value}'**
  String uiConestRelayValue4FB2DB(String value);

  /// App-owned interface/status text in lib/main.dart:358. English: Conest is already running
  ///
  /// In en, this message translates to:
  /// **'Conest is already running'**
  String get uiConestIsAlreadyRunningEE8037;

  /// App-owned interface/status text in lib/main.dart:364. English: Close the existing Conest window first. A second instance would race the local relay port and encrypted vault.
  ///
  /// In en, this message translates to:
  /// **'Close the existing Conest window first. A second instance would race the local relay port and encrypted vault.'**
  String get uiCloseTheExistingConestWindow83B30B;

  /// App-owned interface/status text in lib/main.dart:615. English: Choose where Conest stores data
  ///
  /// In en, this message translates to:
  /// **'Choose where Conest stores data'**
  String get uiChooseWhereConestStoresData0CF613;

  /// App-owned interface/status text in lib/main.dart:621. English: Ghost mode is best-effort privacy: OS launch history, crash logs, network metadata, shell history, recent files, and platform caches are outside app control.
  ///
  /// In en, this message translates to:
  /// **'Ghost mode is best-effort privacy: OS launch history, crash logs, network metadata, shell history, recent files, and platform caches are outside app control.'**
  String get uiGhostModeIsBestEffort694912;

  /// App-owned interface/status text in lib/main.dart:636. English: Default on this device
  ///
  /// In en, this message translates to:
  /// **'Default on this device'**
  String get uiDefaultOnThisDevice10343F;

  /// App-owned interface/status text in lib/main.dart:638. English: Use the normal app data folder and this device keychain when auto-unlock is selected.
  ///
  /// In en, this message translates to:
  /// **'Use the normal app data folder and this device keychain when auto-unlock is selected.'**
  String get uiUseTheNormalAppDataF44F79;

  /// App-owned interface/status text in lib/main.dart:644. English: Ghost/portable beside the app
  ///
  /// In en, this message translates to:
  /// **'Ghost/portable beside the app'**
  String get uiGhostPortableBesideTheApp31A40D;

  /// App-owned interface/status text in lib/main.dart:646. English: Store Conest-controlled files in a conest_data folder next to the app.
  ///
  /// In en, this message translates to:
  /// **'Store Conest-controlled files in a conest_data folder next to the app.'**
  String get uiStoreConestControlledFilesIn7DA307;

  /// App-owned interface/status text in lib/main.dart:654. English: Vault unlock
  ///
  /// In en, this message translates to:
  /// **'Vault unlock'**
  String get uiVaultUnlock602BF6;

  /// App-owned interface/status text in lib/main.dart:671. English: Key file auto-unlock
  ///
  /// In en, this message translates to:
  /// **'Key file auto-unlock'**
  String get uiKeyFileAutoUnlock66AC4A;

  /// App-owned interface/status text in lib/main.dart:673. English: Keeps the key beside the vault. Anyone with the folder can open it.
  ///
  /// In en, this message translates to:
  /// **'Keeps the key beside the vault. Anyone with the folder can open it.'**
  String get uiKeepsTheKeyBesideTheB045D9;

  /// App-owned interface/status text in lib/main.dart:679. English: Auto-unlock with this device
  ///
  /// In en, this message translates to:
  /// **'Auto-unlock with this device'**
  String get uiAutoUnlockWithThisDeviceE7F781;

  /// App-owned interface/status text in lib/main.dart:681. English: Stores the vault key in the platform secure store.
  ///
  /// In en, this message translates to:
  /// **'Stores the vault key in the platform secure store.'**
  String get uiStoresTheVaultKeyInC7B1CD;

  /// App-owned interface/status text in lib/main.dart:686. English: Passphrase unlock
  ///
  /// In en, this message translates to:
  /// **'Passphrase unlock'**
  String get uiPassphraseUnlock13B14C;

  /// App-owned interface/status text in lib/main.dart:688. English: Ask for a passphrase on each launch. Forgotten passphrases cannot be recovered.
  ///
  /// In en, this message translates to:
  /// **'Ask for a passphrase on each launch. Forgotten passphrases cannot be recovered.'**
  String get uiAskForAPassphraseOn4BA25C;

  /// App-owned interface/status text in lib/main.dart:816. English: Unlock Conest
  ///
  /// In en, this message translates to:
  /// **'Unlock Conest'**
  String get uiUnlockConest033EB6;

  /// App-owned interface/status text in lib/main.dart:822. English: Enter the passphrase for this vault.
  ///
  /// In en, this message translates to:
  /// **'Enter the passphrase for this vault.'**
  String get uiEnterThePassphraseForThis891200;

  /// App-owned interface/status text in lib/main.dart:1147. English: No update is available right now.
  ///
  /// In en, this message translates to:
  /// **'No update is available right now.'**
  String get uiNoUpdateIsAvailableRightA5EB48;

  /// App-owned interface/status text in lib/main.dart:1170. English: {value} is available on the {value2} channel.
  ///
  /// In en, this message translates to:
  /// **'{value} is available on the {value2} channel.'**
  String uiValueIsAvailableOnTheD338C4(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:1174. English: Current build: {value}
  ///
  /// In en, this message translates to:
  /// **'Current build: {value}'**
  String uiCurrentBuildValue2FD415(String value);

  /// App-owned interface/status text in lib/main.dart:1179. English: What's new
  ///
  /// In en, this message translates to:
  /// **'What\'s new'**
  String get uiWhatSNew4D8DC5;

  /// App-owned interface/status text in lib/main.dart:1365. English: ◢ SERVERLESS SECURE MESSENGER
  ///
  /// In en, this message translates to:
  /// **'◢ SERVERLESS SECURE MESSENGER'**
  String get uiSERVERLESSSECUREMESSENGER1E1891;

  /// App-owned interface/status text in lib/main.dart:1602. English: Your Matrix session {value} wants to verify this one. Accept only if you started it.
  ///
  /// In en, this message translates to:
  /// **'Your Matrix session {value} wants to verify this one. Accept only if you started it.'**
  String uiYourMatrixSessionValueWants580E45(String value);

  /// App-owned interface/status text in lib/main.dart:1604. English: {value} wants to verify you, comparing emojis. Check the whole address: look-alike ones exist. Accept only if you can compare with them in person or on a call; verifying marks their keys as trusted.
  ///
  /// In en, this message translates to:
  /// **'{value} wants to verify you, comparing emojis. Check the whole address: look-alike ones exist. Accept only if you can compare with them in person or on a call; verifying marks their keys as trusted.'**
  String uiValueWantsToVerifyYou61FD9D(String value);

  /// App-owned interface/status text in lib/main.dart:1634. English: Could not verify: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not verify: {value}'**
  String uiCouldNotVerifyValue3AE1C4(String value);

  /// App-owned interface/status text in lib/main.dart:2309. English: Send without resumable copy?
  ///
  /// In en, this message translates to:
  /// **'Send without resumable copy?'**
  String get uiSendWithoutResumableCopy0475F4;

  /// App-owned interface/status text in lib/main.dart:2312. English: {value} could not be copied into private transfer storage.
  ///
  /// {value2}
  ///
  /// The app can read the original file directly, but the transfer cannot resume after restart if that file moves or its permission expires.{value3}
  ///
  /// In en, this message translates to:
  /// **'{value} could not be copied into private transfer storage.\n\n{value2}\n\nThe app can read the original file directly, but the transfer cannot resume after restart if that file moves or its permission expires.{value3}'**
  String uiValueCouldNotBeCopied06F61A(
    String value,
    String value2,
    String value3,
  );

  /// App-owned interface/status text in lib/main.dart:3625. English: Unmute
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get uiUnmute7044C3;

  /// App-owned interface/status text in lib/main.dart:3625. English: Mute
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get uiMute0F0973;

  /// App-owned interface/status text in lib/main.dart:3655. English: Speaker on
  ///
  /// In en, this message translates to:
  /// **'Speaker on'**
  String get uiSpeakerOn93982E;

  /// App-owned interface/status text in lib/main.dart:3656. English: Speaker off
  ///
  /// In en, this message translates to:
  /// **'Speaker off'**
  String get uiSpeakerOff97823A;

  /// App-owned interface/status text in lib/main.dart:3685. English: Cancel call
  ///
  /// In en, this message translates to:
  /// **'Cancel call'**
  String get uiCancelCallCE6C16;

  /// App-owned interface/status text in lib/main.dart:3734. English: {value}{value2} · Return to call
  ///
  /// In en, this message translates to:
  /// **'{value}{value2} · Return to call'**
  String uiValueValueReturnToCall49F82C(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:3783. English: Contact details
  ///
  /// In en, this message translates to:
  /// **'Contact details'**
  String get uiContactDetailsD4EC65;

  /// App-owned interface/status text in lib/main.dart:3924. English: {value} active member{value2}
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{{value} active member} other{{value} active members}}'**
  String uiValueActiveMemberValue6700F2(int value);

  /// App-owned interface/status text in lib/main.dart:3947. English: Owner
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get uiOwner89FF31;

  /// App-owned interface/status text in lib/main.dart:4158. English: Edit {value}
  ///
  /// In en, this message translates to:
  /// **'Edit {value}'**
  String uiEditValue75BE00(String value);

  /// App-owned interface/status text in lib/main.dart:4371. English: Could not save chat settings: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not save chat settings: {value}'**
  String uiCouldNotSaveChatSettings2372B2(String value);

  /// App-owned interface/status text in lib/main.dart:5032. English: Add a contact to start a conversation
  ///
  /// In en, this message translates to:
  /// **'Add a contact to start a conversation'**
  String get uiAddAContactToStart165431;

  /// App-owned interface/status text in lib/main.dart:5033. English: No contacts found
  ///
  /// In en, this message translates to:
  /// **'No contacts found'**
  String get uiNoContactsFound816015;

  /// App-owned interface/status text in lib/main.dart:5651. English: Open #{value}
  ///
  /// In en, this message translates to:
  /// **'Open #{value}'**
  String uiOpenValue8DF02B(String value);

  /// App-owned interface/status text in lib/main.dart:5791. English: No messages yet
  ///
  /// In en, this message translates to:
  /// **'No messages yet'**
  String get uiNoMessagesYetC04921;

  /// App-owned interface/status text in lib/main.dart:5842. English: No activity yet — pair a contact to start the log.
  ///
  /// In en, this message translates to:
  /// **'No activity yet — pair a contact to start the log.'**
  String get uiNoActivityYetPairA7F5366;

  /// App-owned interface/status text in lib/main.dart:5913. English: SENT
  ///
  /// In en, this message translates to:
  /// **'SENT'**
  String get uiSENT5AD0CD;

  /// App-owned interface/status text in lib/main.dart:5913. English: RECV
  ///
  /// In en, this message translates to:
  /// **'RECV'**
  String get uiRECVBFC296;

  /// App-owned interface/status text in lib/main.dart:6015. English: device {value}
  ///
  /// In en, this message translates to:
  /// **'device {value}'**
  String uiDeviceValue11AEA9(String value);

  /// App-owned interface/status text in lib/main.dart:6156. English: Free-for-all local chat • untrusted
  ///
  /// In en, this message translates to:
  /// **'Free-for-all local chat • untrusted'**
  String get uiFreeForAllLocalChat5485CC;

  /// App-owned interface/status text in lib/main.dart:6181. English: Groups
  ///
  /// In en, this message translates to:
  /// **'Groups'**
  String get uiGroupsAE9629;

  /// App-owned interface/status text in lib/main.dart:6206. English: Add trusted contacts before creating a group.
  ///
  /// In en, this message translates to:
  /// **'Add trusted contacts before creating a group.'**
  String get uiAddTrustedContactsBeforeCreating1084CC;

  /// App-owned interface/status text in lib/main.dart:6207. English: No groups yet.
  ///
  /// In en, this message translates to:
  /// **'No groups yet.'**
  String get uiNoGroupsYet5009C6;

  /// App-owned interface/status text in lib/main.dart:6283. English: {value} member(s)
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{{value} member} other{{value} members}}'**
  String uiValueMemberSE75249(int value);

  /// App-owned interface/status text in lib/main.dart:6328. English: Contacts
  ///
  /// In en, this message translates to:
  /// **'Contacts'**
  String get uiContactsB0DD61;

  /// App-owned interface/status text in lib/main.dart:6700. English: Applies to future admissions. History already received cannot be withdrawn.
  ///
  /// In en, this message translates to:
  /// **'Applies to future admissions. History already received cannot be withdrawn.'**
  String get uiAppliesToFutureAdmissionsHistory78E3A0;

  /// App-owned interface/status text in lib/main.dart:6705. English: {value}All retained history
  ///
  /// In en, this message translates to:
  /// **'{value}All retained history'**
  String uiValueAllRetainedHistory5E25F4(String value);

  /// App-owned interface/status text in lib/main.dart:6709. English: {value}Since admission
  ///
  /// In en, this message translates to:
  /// **'{value}Since admission'**
  String uiValueSinceAdmissionB2617B(String value);

  /// App-owned interface/status text in lib/main.dart:6802. English: Delete "{value}"
  ///
  /// In en, this message translates to:
  /// **'Delete \"{value}\"'**
  String uiDeleteValueF0396B(String value);

  /// App-owned interface/status text in lib/main.dart:6922. English: Delete "{value}" for everyone?
  ///
  /// In en, this message translates to:
  /// **'Delete \"{value}\" for everyone?'**
  String uiDeleteValueForEveryone12E724(String value);

  /// App-owned interface/status text in lib/main.dart:7080. English: {value} member(s) • owner {value2}
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{{value} member • owner {value2}} other{{value} members • owner {value2}}}'**
  String uiValueMemberSOwnerValueE42E13(int value, String value2);

  /// App-owned interface/status text in lib/main.dart:7125. English: // GROUP TRUST FANOUT · mint = paired
  ///
  /// In en, this message translates to:
  /// **'// GROUP TRUST FANOUT · mint = paired'**
  String get uiGROUPTRUSTFANOUTMintPaired5DDF6E;

  /// App-owned interface/status text in lib/main.dart:7138. English: Add trusted contact
  ///
  /// In en, this message translates to:
  /// **'Add trusted contact'**
  String get uiAddTrustedContact126717;

  /// App-owned interface/status text in lib/main.dart:7259. English: No available chats
  ///
  /// In en, this message translates to:
  /// **'No available chats'**
  String get uiNoAvailableChats1FAA40;

  /// App-owned interface/status text in lib/main.dart:7310. English: Forwarded message queued
  ///
  /// In en, this message translates to:
  /// **'Forwarded message queued'**
  String get uiForwardedMessageQueuedC82DA4;

  /// App-owned interface/status text in lib/main.dart:7316. English: Could not forward: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not forward: {value}'**
  String uiCouldNotForwardValue80193D(String value);

  /// App-owned interface/status text in lib/main.dart:7499. English: Forwarded attachment queued
  ///
  /// In en, this message translates to:
  /// **'Forwarded attachment queued'**
  String get uiForwardedAttachmentQueued57C88B;

  /// App-owned interface/status text in lib/main.dart:7505. English: Could not forward attachment: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not forward attachment: {value}'**
  String uiCouldNotForwardAttachmentValue5165FD(String value);

  /// App-owned interface/status text in lib/main.dart:7606. English: Chat details
  ///
  /// In en, this message translates to:
  /// **'Chat details'**
  String get uiChatDetails15DAEC;

  /// App-owned interface/status text in lib/main.dart:7611. English: Connection details
  ///
  /// In en, this message translates to:
  /// **'Connection details'**
  String get uiConnectionDetailsAB30A5;

  /// App-owned interface/status text in lib/main.dart:7763. English: {value} / {value2}
  ///
  /// In en, this message translates to:
  /// **'{value} / {value2}'**
  String uiValueValue270519(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:7859. English: Voice message · {value}
  ///
  /// In en, this message translates to:
  /// **'Voice message · {value}'**
  String uiVoiceMessageValue2F0300(String value);

  /// App-owned interface/status text in lib/main.dart:7885. English: Playback failed: {value}
  ///
  /// In en, this message translates to:
  /// **'Playback failed: {value}'**
  String uiPlaybackFailedValue1C0E1A(String value);

  /// App-owned interface/status text in lib/main.dart:7962. English: Preparing microphone…
  ///
  /// In en, this message translates to:
  /// **'Preparing microphone…'**
  String get uiPreparingMicrophone0BBF4A;

  /// App-owned interface/status text in lib/main.dart:7964. English: Preparing preview…
  ///
  /// In en, this message translates to:
  /// **'Preparing preview…'**
  String get uiPreparingPreview312E7B;

  /// App-owned interface/status text in lib/main.dart:7966. English: Voice message preview · {value}
  ///
  /// In en, this message translates to:
  /// **'Voice message preview · {value}'**
  String uiVoiceMessagePreviewValue8235CB(String value);

  /// App-owned interface/status text in lib/main.dart:7967. English: Recording{value} · {value2}
  ///
  /// In en, this message translates to:
  /// **'Recording{value} · {value2}'**
  String uiRecordingValueValue111FF1(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:7991. English: Sending…
  ///
  /// In en, this message translates to:
  /// **'Sending…'**
  String get uiSendingCF7655;

  /// App-owned interface/status text in lib/main.dart:8044. English: {value}×
  ///
  /// In en, this message translates to:
  /// **'{value}×'**
  String uiValue72F816(String value);

  /// App-owned interface/status text in lib/main.dart:8318. English: Single choice
  ///
  /// In en, this message translates to:
  /// **'Single choice'**
  String get uiSingleChoice68E3E0;

  /// App-owned interface/status text in lib/main.dart:8322. English: Multiple choice
  ///
  /// In en, this message translates to:
  /// **'Multiple choice'**
  String get uiMultipleChoiceB88936;

  /// App-owned interface/status text in lib/main.dart:8369. English: This removes the message for group members when they synchronize.{value}
  ///
  /// In en, this message translates to:
  /// **'This removes the message for group members when they synchronize.{value}'**
  String uiThisRemovesTheMessageFor2247A2(String value);

  /// App-owned interface/status text in lib/main.dart:8457. English: Could not locate this message in the current chat
  ///
  /// In en, this message translates to:
  /// **'Could not locate this message in the current chat'**
  String get uiCouldNotLocateThisMessage220E83;

  /// App-owned interface/status text in lib/main.dart:8519. English: Delete {value} message{value2} for the group?
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{Delete {value} message for the group?} other{Delete {value} messages for the group?}}'**
  String uiDeleteValueMessageValueForABA7AC(int value);

  /// App-owned interface/status text in lib/main.dart:9086. English: {value} {value2}
  ///
  /// In en, this message translates to:
  /// **'{value} {value2}'**
  String uiValueValue29C8B9(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:9124. English: new
  ///
  /// In en, this message translates to:
  /// **'new'**
  String get uiNewC2A6B0;

  /// App-owned interface/status text in lib/main.dart:9135. English: edited
  ///
  /// In en, this message translates to:
  /// **'edited'**
  String get uiEditedA22FCA;

  /// App-owned interface/status text in lib/main.dart:9321. English: Copy cache path
  ///
  /// In en, this message translates to:
  /// **'Copy cache path'**
  String get uiCopyCachePathC23134;

  /// App-owned interface/status text in lib/main.dart:9327. English: Stop keeping offline
  ///
  /// In en, this message translates to:
  /// **'Stop keeping offline'**
  String get uiStopKeepingOfflineAABFC7;

  /// App-owned interface/status text in lib/main.dart:9328. English: Keep offline
  ///
  /// In en, this message translates to:
  /// **'Keep offline'**
  String get uiKeepOffline123286;

  /// App-owned interface/status text in lib/main.dart:9358. English: Forward file
  ///
  /// In en, this message translates to:
  /// **'Forward file'**
  String get uiForwardFileC4B5CB;

  /// App-owned interface/status text in lib/main.dart:9519. English: Loading history…
  ///
  /// In en, this message translates to:
  /// **'Loading history…'**
  String get uiLoadingHistory02CB12;

  /// App-owned interface/status text in lib/main.dart:9520. English: Load older messages
  ///
  /// In en, this message translates to:
  /// **'Load older messages'**
  String get uiLoadOlderMessages07471F;

  /// App-owned interface/status text in lib/main.dart:9638. English: Share file now
  ///
  /// In en, this message translates to:
  /// **'Share file now'**
  String get uiShareFileNow96E2A2;

  /// App-owned interface/status text in lib/main.dart:9642. English: Schedule file
  ///
  /// In en, this message translates to:
  /// **'Schedule file'**
  String get uiScheduleFile690A92;

  /// App-owned interface/status text in lib/main.dart:9866. English: Drop to share this file with the group
  ///
  /// In en, this message translates to:
  /// **'Drop to share this file with the group'**
  String get uiDropToShareThisFile0B73E8;

  /// App-owned interface/status text in lib/main.dart:10054. English: Closed
  ///
  /// In en, this message translates to:
  /// **'Closed'**
  String get uiClosed88D86B;

  /// App-owned interface/status text in lib/main.dart:10054. English: Visible votes
  ///
  /// In en, this message translates to:
  /// **'Visible votes'**
  String get uiVisibleVotes460E7A;

  /// App-owned interface/status text in lib/main.dart:10061. English: {value} vote(s) were not in the creator’s close checkpoint.
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{{value} vote were not in the creator’s close checkpoint.} other{{value} votes were not in the creator’s close checkpoint.}}'**
  String uiValueVoteSWereNot02CC9A(int value);

  /// App-owned interface/status text in lib/main.dart:10068. English: Voting is unavailable with this Conest version.
  ///
  /// In en, this message translates to:
  /// **'Voting is unavailable with this Conest version.'**
  String get uiVotingIsUnavailableWithThis9B92E7;

  /// App-owned interface/status text in lib/main.dart:10695. English: This removes the message here and asks the contact to remove their copy if reachable.
  ///
  /// In en, this message translates to:
  /// **'This removes the message here and asks the contact to remove their copy if reachable.'**
  String get uiThisRemovesTheMessageHere61D27C;

  /// App-owned interface/status text in lib/main.dart:10696. English: This removes the message from this device.
  ///
  /// In en, this message translates to:
  /// **'This removes the message from this device.'**
  String get uiThisRemovesTheMessageFrom6A47E2;

  /// App-owned interface/status text in lib/main.dart:11205. English: Send via Matrix…
  ///
  /// In en, this message translates to:
  /// **'Send via Matrix…'**
  String get uiSendViaMatrix3868FE;

  /// App-owned interface/status text in lib/main.dart:11340. English: Notes, files and forwards, only on this device
  ///
  /// In en, this message translates to:
  /// **'Notes, files and forwards, only on this device'**
  String get uiNotesFilesAndForwardsOnlyB0145F;

  /// App-owned interface/status text in lib/main.dart:11341. English: {value} • safety {value2}
  ///
  /// In en, this message translates to:
  /// **'{value} • safety {value2}'**
  String uiValueSafetyValue82C755(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:11809. English: Drop files to send (max {value})
  ///
  /// In en, this message translates to:
  /// **'Drop files to send (max {value})'**
  String uiDropFilesToSendMax106011(String value);

  /// App-owned interface/status text in lib/main.dart:11941. English: Free-for-all local chat. Messages are session-signed but people here are not trusted contacts.
  ///
  /// In en, this message translates to:
  /// **'Free-for-all local chat. Messages are session-signed but people here are not trusted contacts.'**
  String get uiFreeForAllLocalChatBC90D2;

  /// App-owned interface/status text in lib/main.dart:11965. English: No LAN lobby messages yet. Nearby Conest peers will receive messages while they are on this LAN.
  ///
  /// In en, this message translates to:
  /// **'No LAN lobby messages yet. Nearby Conest peers will receive messages while they are on this LAN.'**
  String get uiNoLANLobbyMessagesYetBCDC4B;

  /// App-owned interface/status text in lib/main.dart:12010. English: {value} • untrusted
  ///
  /// In en, this message translates to:
  /// **'{value} • untrusted'**
  String uiValueUntrusted519A32(String value);

  /// App-owned interface/status text in lib/main.dart:12244. English: Remove {value}?
  ///
  /// In en, this message translates to:
  /// **'Remove {value}?'**
  String uiRemoveValueF4FE4B(String value);

  /// App-owned interface/status text in lib/main.dart:12350. English: Available paths
  ///
  /// In en, this message translates to:
  /// **'Available paths'**
  String get uiAvailablePaths6EE503;

  /// App-owned interface/status text in lib/main.dart:12373. English: Run a check to measure latency, availability, and reachability freshness. Paths are sorted by best direct/LAN route first, then relay fallback.
  ///
  /// In en, this message translates to:
  /// **'Run a check to measure latency, availability, and reachability freshness. Paths are sorted by best direct/LAN route first, then relay fallback.'**
  String get uiRunACheckToMeasure5D76A5;

  /// App-owned interface/status text in lib/main.dart:12380. English: No route hints are advertised for this contact.
  ///
  /// In en, this message translates to:
  /// **'No route hints are advertised for this contact.'**
  String get uiNoRouteHintsAreAdvertisedB25540;

  /// App-owned interface/status text in lib/main.dart:12624. English: Either input is enough on its own. Scan or paste a QR invite to trust it directly, or enter only the current codephrase to discover the sender over nearby LAN routes or the configured relay. If automatic exchange fails, the app will suggest asking the other side to add you back or aborting.
  ///
  /// In en, this message translates to:
  /// **'Either input is enough on its own. Scan or paste a QR invite to trust it directly, or enter only the current codephrase to discover the sender over nearby LAN routes or the configured relay. If automatic exchange fails, the app will suggest asking the other side to add you back or aborting.'**
  String get uiEitherInputIsEnoughOn020B90;

  /// App-owned interface/status text in lib/main.dart:12635. English: Invite preview
  ///
  /// In en, this message translates to:
  /// **'Invite preview'**
  String get uiInvitePreview6433A0;

  /// App-owned interface/status text in lib/main.dart:12645. English: {value}{value2} • {value3}
  ///
  /// In en, this message translates to:
  /// **'{value}{value2} • {value3}'**
  String uiValueValueValue98AECE(String value, String value2, String value3);

  /// App-owned interface/status text in lib/main.dart:12851. English: Share invite
  ///
  /// In en, this message translates to:
  /// **'Share invite'**
  String get uiShareInviteDBCC1E;

  /// App-owned interface/status text in lib/main.dart:12875. English: This invite works only on the same network: no internet route is on. Turn on Iroh relays, a Conest relay or a carrier (Nostr, email) in Settings → Connectivity so contacts can add you from anywhere.
  ///
  /// In en, this message translates to:
  /// **'This invite works only on the same network: no internet route is on. Turn on Iroh relays, a Conest relay or a carrier (Nostr, email) in Settings → Connectivity so contacts can add you from anywhere.'**
  String get uiThisInviteWorksOnlyOnB106B0;

  /// App-owned interface/status text in lib/main.dart:12904. English: This invite also lists your routes for blocked networks, which makes it too large for one QR code. Show it as Beam, an animated QR the other camera reads in a few seconds.
  ///
  /// In en, this message translates to:
  /// **'This invite also lists your routes for blocked networks, which makes it too large for one QR code. Show it as Beam, an animated QR the other camera reads in a few seconds.'**
  String get uiThisInviteAlsoListsYourEF3A4F;

  /// App-owned interface/status text in lib/main.dart:12998. English: QR rendering is deferred on Windows.
  ///
  /// In en, this message translates to:
  /// **'QR rendering is deferred on Windows.'**
  String get uiQRRenderingIsDeferredOn8A6997;

  /// App-owned interface/status text in lib/main.dart:13005. English: Use the codephrase below, or render the QR after this page is open.
  ///
  /// In en, this message translates to:
  /// **'Use the codephrase below, or render the QR after this page is open.'**
  String get uiUseTheCodephraseBelowOrB6A588;

  /// App-owned interface/status text in lib/main.dart:13043. English: Scanning the compact QR is enough on its own. If the camera still struggles, open it full screen or use only the current codephrase.
  ///
  /// In en, this message translates to:
  /// **'Scanning the compact QR is enough on its own. If the camera still struggles, open it full screen or use only the current codephrase.'**
  String get uiScanningTheCompactQRIs9459D9;

  /// App-owned interface/status text in lib/main.dart:13050. English: QR payload: {value} characters
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{QR payload: {value} character} other{QR payload: {value} characters}}'**
  String uiQRPayloadValueCharactersBABEDF(int value);

  /// App-owned interface/status text in lib/main.dart:13058. English: Also lists your addresses on: {value}.
  ///
  /// In en, this message translates to:
  /// **'Also lists your addresses on: {value}.'**
  String uiAlsoListsYourAddressesOnC5D815(String value);

  /// App-owned interface/status text in lib/main.dart:13211. English: Pinned · {value}
  ///
  /// In en, this message translates to:
  /// **'Pinned · {value}'**
  String uiPinnedValue834309(String value);

  /// App-owned interface/status text in lib/main.dart:13219. English: No verified ci6 contacts are available yet.
  ///
  /// In en, this message translates to:
  /// **'No verified ci6 contacts are available yet.'**
  String get uiNoVerifiedCiContactsAre3FD190;

  /// App-owned interface/status text in lib/main.dart:13321. English: Close-up transfer
  ///
  /// In en, this message translates to:
  /// **'Close-up transfer'**
  String get uiCloseUpTransferE6BA46;

  /// App-owned interface/status text in lib/main.dart:13328. English: A looping LT fountain stream survives missed, duplicate, and out-of-order QR frames. The final file is hash-checked before you can accept it.
  ///
  /// In en, this message translates to:
  /// **'A looping LT fountain stream survives missed, duplicate, and out-of-order QR frames. The final file is hash-checked before you can accept it.'**
  String get uiALoopingLTFountainStream840218;

  /// App-owned interface/status text in lib/main.dart:13487. English: PUBLIC · visible to anyone nearby
  ///
  /// In en, this message translates to:
  /// **'PUBLIC · visible to anyone nearby'**
  String get uiPUBLICVisibleToAnyoneNearbyA775C2;

  /// App-owned interface/status text in lib/main.dart:13489. English: CONTACT ENCRYPTED
  ///
  /// In en, this message translates to:
  /// **'CONTACT ENCRYPTED'**
  String get uiCONTACTENCRYPTED879896;

  /// App-owned interface/status text in lib/main.dart:13490. English: SIGNED CONTACT INVITE
  ///
  /// In en, this message translates to:
  /// **'SIGNED CONTACT INVITE'**
  String get uiSIGNEDCONTACTINVITE752317;

  /// App-owned interface/status text in lib/main.dart:13499. English: Frame {value} · {value2} source blocks · {value3}
  ///
  /// In en, this message translates to:
  /// **'{value2, plural, one{Frame {value} · {value2} source blocks · {value3}} other{Frame {value} · {value2} source blocks · {value3}}}'**
  String uiFrameValueValueSourceBlocks9C37CB(
    String value,
    int value2,
    String value3,
  );

  /// App-owned interface/status text in lib/main.dart:13725. English: Point this camera at the animated Beam QR. Only decoded cb1 frames leave the native scanner.
  ///
  /// In en, this message translates to:
  /// **'Point this camera at the animated Beam QR. Only decoded cb1 frames leave the native scanner.'**
  String get uiPointThisCameraAtThe2EA3F7;

  /// App-owned interface/status text in lib/main.dart:13741. English: Native desktop camera capture is unavailable. Paste cb1 frames below; the protocol decoder and verification path are identical.
  ///
  /// In en, this message translates to:
  /// **'Native desktop camera capture is unavailable. Paste cb1 frames below; the protocol decoder and verification path are identical.'**
  String get uiNativeDesktopCameraCaptureIs4619C8;

  /// App-owned interface/status text in lib/main.dart:13757. English: {value}/{value2} blocks · {value3} frames · {value4} invalid
  ///
  /// In en, this message translates to:
  /// **'{value}/{value2} blocks · {value3} frames · {value4} invalid'**
  String uiValueValueBlocksValueFrames66F819(
    String value,
    String value2,
    String value3,
    String value4,
  );

  /// App-owned interface/status text in lib/main.dart:13850. English: Signed contact invite
  ///
  /// In en, this message translates to:
  /// **'Signed contact invite'**
  String get uiSignedContactInviteA7CC8B;

  /// App-owned interface/status text in lib/main.dart:13859. English: PUBLIC / UNTRUSTED. The signature proves that all frames came from one key; it does not prove who owns that key.
  ///
  /// In en, this message translates to:
  /// **'PUBLIC / UNTRUSTED. The signature proves that all frames came from one key; it does not prove who owns that key.'**
  String get uiPUBLICUNTRUSTEDTheSignatureProves96FA7F;

  /// App-owned interface/status text in lib/main.dart:13862. English: Encrypted and authenticated as a pinned Conest contact.
  ///
  /// In en, this message translates to:
  /// **'Encrypted and authenticated as a pinned Conest contact.'**
  String get uiEncryptedAndAuthenticatedAsA68B7E4;

  /// App-owned interface/status text in lib/main.dart:13863. English: Signature valid. Compare the fingerprint in person.
  ///
  /// In en, this message translates to:
  /// **'Signature valid. Compare the fingerprint in person.'**
  String get uiSignatureValidCompareTheFingerprintA8A1FE;

  /// App-owned interface/status text in lib/main.dart:13897. English: Accept and save public file
  ///
  /// In en, this message translates to:
  /// **'Accept and save public file'**
  String get uiAcceptAndSavePublicFile852517;

  /// App-owned interface/status text in lib/main.dart:13897. English: Save file
  ///
  /// In en, this message translates to:
  /// **'Save file'**
  String get uiSaveFileBEDC84;

  /// App-owned interface/status text in lib/main.dart:13986. English: Fullscreen compact invite QR
  ///
  /// In en, this message translates to:
  /// **'Fullscreen compact invite QR'**
  String get uiFullscreenCompactInviteQRCF6B8B;

  /// App-owned interface/status text in lib/main.dart:14004. English: {value} characters. Increase screen brightness if scanning is unreliable.
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{{value} character. Increase screen brightness if scanning is unreliable.} other{{value} characters. Increase screen brightness if scanning is unreliable.}}'**
  String uiValueCharactersIncreaseScreenBrightnessA5AF7D(int value);

  /// App-owned interface/status text in lib/main.dart:14203. English: Personal / Preferences
  ///
  /// In en, this message translates to:
  /// **'Personal / Preferences'**
  String get uiPersonalPreferencesBD0D61;

  /// App-owned interface/status text in lib/main.dart:14212. English: Network / Relay
  ///
  /// In en, this message translates to:
  /// **'Network / Relay'**
  String get uiNetworkRelay4F9A27;

  /// App-owned interface/status text in lib/main.dart:14218. English: Danger
  ///
  /// In en, this message translates to:
  /// **'Danger'**
  String get uiDanger58D175;

  /// App-owned interface/status text in lib/main.dart:14364. English: Allows one-to-one Iroh voice calls on this device. Turn off to stop placing and receiving calls.
  ///
  /// In en, this message translates to:
  /// **'Allows one-to-one Iroh voice calls on this device. Turn off to stop placing and receiving calls.'**
  String get uiAllowsOneToOneIroh45EEF1;

  /// App-owned interface/status text in lib/main.dart:14448. English: Privacy of files you send
  ///
  /// In en, this message translates to:
  /// **'Privacy of files you send'**
  String get uiPrivacyOfFilesYouSend4E4A5B;

  /// App-owned interface/status text in lib/main.dart:14673. English: Low
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get uiLowA12494;

  /// App-owned interface/status text in lib/main.dart:14677. English: Medium
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get uiMediumD40496;

  /// App-owned interface/status text in lib/main.dart:14681. English: High
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get uiHighB1A595;

  /// App-owned interface/status text in lib/main.dart:14775. English: Transport policy
  ///
  /// In en, this message translates to:
  /// **'Transport policy'**
  String get uiTransportPolicy088D79;

  /// App-owned interface/status text in lib/main.dart:14792. English: Per-contact routing is intersected with these flags. Turning off either restricts traffic; turning off both makes the app idle.
  ///
  /// In en, this message translates to:
  /// **'Per-contact routing is intersected with these flags. Turning off either restricts traffic; turning off both makes the app idle.'**
  String get uiPerContactRoutingIsIntersected88E292;

  /// App-owned interface/status text in lib/main.dart:14793. English: Connectivity is fully off — the app will not send or receive.
  ///
  /// In en, this message translates to:
  /// **'Connectivity is fully off — the app will not send or receive.'**
  String get uiConnectivityIsFullyOffTheB12483;

  /// App-owned interface/status text in lib/main.dart:14884. English: {value} candidate route(s) are available right now.
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{{value} candidate route are available right now.} other{{value} candidate routes are available right now.}}'**
  String uiValueCandidateRouteSAre175673(int value);

  /// App-owned interface/status text in lib/main.dart:14937. English: Configured relays
  ///
  /// In en, this message translates to:
  /// **'Configured relays'**
  String get uiConfiguredRelays3CA0DE;

  /// App-owned interface/status text in lib/main.dart:14944. English: No relays added yet.
  ///
  /// In en, this message translates to:
  /// **'No relays added yet.'**
  String get uiNoRelaysAddedYetF791E7;

  /// App-owned interface/status text in lib/main.dart:15044. English: Current build: {value} • {value2}
  ///
  /// In en, this message translates to:
  /// **'Current build: {value} • {value2}'**
  String uiCurrentBuildValueValue9A675D(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:15052. English: commit {value}
  ///
  /// In en, this message translates to:
  /// **'commit {value}'**
  String uiCommitValue2E080C(String value);

  /// App-owned interface/status text in lib/main.dart:15102. English: Available: {value}
  ///
  /// In en, this message translates to:
  /// **'Available: {value}'**
  String uiAvailableValue4B15F7(String value);

  /// App-owned interface/status text in lib/main.dart:15150. English: Checking...
  ///
  /// In en, this message translates to:
  /// **'Checking...'**
  String get uiChecking494D0F;

  /// App-owned interface/status text in lib/main.dart:15151. English: Check for Updates
  ///
  /// In en, this message translates to:
  /// **'Check for Updates'**
  String get uiCheckForUpdates8604FF;

  /// App-owned interface/status text in lib/main.dart:15231. English: Trust new identity for {value}?
  ///
  /// In en, this message translates to:
  /// **'Trust new identity for {value}?'**
  String uiTrustNewIdentityForValue8B0612(String value);

  /// App-owned interface/status text in lib/main.dart:15233. English: The relay is now signing with a different Ed25519 public key ({value}). Only continue if the operator has confirmed they rotated the key — otherwise this could be a man-in-the-middle.
  ///
  /// In en, this message translates to:
  /// **'The relay is now signing with a different Ed25519 public key ({value}). Only continue if the operator has confirmed they rotated the key — otherwise this could be a man-in-the-middle.'**
  String uiTheRelayIsNowSigningFF71FD(String value);

  /// App-owned interface/status text in lib/main.dart:15293. English: Relay identity changed
  ///
  /// In en, this message translates to:
  /// **'Relay identity changed'**
  String get uiRelayIdentityChanged097638;

  /// App-owned interface/status text in lib/main.dart:15301. English: A configured relay is signing with a new key. Verify with the operator before trusting it.
  ///
  /// In en, this message translates to:
  /// **'A configured relay is signing with a new key. Verify with the operator before trusting it.'**
  String get uiAConfiguredRelayIsSigning60EED0;

  /// App-owned interface/status text in lib/main.dart:15315. English: {value} → {value2}
  ///
  /// In en, this message translates to:
  /// **'{value} → {value2}'**
  String uiValueValue66746D(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:15367. English: No pending contact requests
  ///
  /// In en, this message translates to:
  /// **'No pending contact requests'**
  String get uiNoPendingContactRequests697615;

  /// App-owned interface/status text in lib/main.dart:15412. English: Could not review request: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not review request: {value}'**
  String uiCouldNotReviewRequestValue82B3D5(String value);

  /// App-owned interface/status text in lib/main.dart:15421. English: Add {value}?
  ///
  /// In en, this message translates to:
  /// **'Add {value}?'**
  String uiAddValueF034EE(String value);

  /// App-owned interface/status text in lib/main.dart:15455. English: Could not add contact: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not add contact: {value}'**
  String uiCouldNotAddContactValue7F6C38(String value);

  /// App-owned interface/status text in lib/main.dart:15465. English: Could not reject request: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not reject request: {value}'**
  String uiCouldNotRejectRequestValue2EFD58(String value);

  /// App-owned interface/status text in lib/main.dart:15473. English: Contact request rejected.
  ///
  /// In en, this message translates to:
  /// **'Contact request rejected.'**
  String get uiContactRequestRejected447EE8;

  /// App-owned interface/status text in lib/main.dart:15499. English: Contact request from {value}
  ///
  /// In en, this message translates to:
  /// **'Contact request from {value}'**
  String uiContactRequestFromValue50B6AC(String value);

  /// App-owned interface/status text in lib/main.dart:15511. English: Unverified · {value}
  ///
  /// In en, this message translates to:
  /// **'Unverified · {value}'**
  String uiUnverifiedValueC1937C(String value);

  /// App-owned interface/status text in lib/main.dart:15554. English: Contact request failed: {value}
  ///
  /// In en, this message translates to:
  /// **'Contact request failed: {value}'**
  String uiContactRequestFailedValue28DD81(String value);

  /// App-owned interface/status text in lib/main.dart:15590. English: Request again
  ///
  /// In en, this message translates to:
  /// **'Request again'**
  String get uiRequestAgain7B0434;

  /// App-owned interface/status text in lib/main.dart:15638. English: Trust {value} as a fresh contact? Verify the safety number out of band first — accepting now archives any previous "{value2}" entries as read-only.
  ///
  /// In en, this message translates to:
  /// **'Trust {value} as a fresh contact? Verify the safety number out of band first — accepting now archives any previous \"{value2}\" entries as read-only.'**
  String uiTrustValueAsAFresh7BF87F(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:15641. English: Trust this as a reinstall of "{value}"? The previous contact will be archived (history kept read-only); the new contact takes over. This cannot be undone.
  ///
  /// In en, this message translates to:
  /// **'Trust this as a reinstall of \"{value}\"? The previous contact will be archived (history kept read-only); the new contact takes over. This cannot be undone.'**
  String uiTrustThisAsAReinstallCBA4CC(String value);

  /// App-owned interface/status text in lib/main.dart:15665. English: Confirm failed: {value}
  ///
  /// In en, this message translates to:
  /// **'Confirm failed: {value}'**
  String uiConfirmFailedValueBDE200(String value);

  /// App-owned interface/status text in lib/main.dart:15704. English: Reject failed: {value}
  ///
  /// In en, this message translates to:
  /// **'Reject failed: {value}'**
  String uiRejectFailedValue5F5917(String value);

  /// App-owned interface/status text in lib/main.dart:15726. English: This contact may be a reset of "{value}". Verify their safety number out of band before exchanging messages.
  ///
  /// In en, this message translates to:
  /// **'This contact may be a reset of \"{value}\". Verify their safety number out of band before exchanging messages.'**
  String uiThisContactMayBeAD1405D(String value);

  /// App-owned interface/status text in lib/main.dart:15780. English: Imported relays from {value}.
  ///
  /// In en, this message translates to:
  /// **'Imported relays from {value}.'**
  String uiImportedRelaysFromValue37C175(String value);

  /// App-owned interface/status text in lib/main.dart:15787. English: Import failed: {value}
  ///
  /// In en, this message translates to:
  /// **'Import failed: {value}'**
  String uiImportFailedValueBAFB4A(String value);

  /// App-owned interface/status text in lib/main.dart:15801. English: This will remove {value} relay route(s) imported from {value2}.
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{This will remove {value} relay route imported from {value2}.} other{This will remove {value} relay routes imported from {value2}.}}'**
  String uiThisWillRemoveValueRelay330EEB(int value, String value2);

  /// App-owned interface/status text in lib/main.dart:15822. English: Remove failed: {value}
  ///
  /// In en, this message translates to:
  /// **'Remove failed: {value}'**
  String uiRemoveFailedValue58F348(String value);

  /// App-owned interface/status text in lib/main.dart:15850. English: Imported relay lists
  ///
  /// In en, this message translates to:
  /// **'Imported relay lists'**
  String get uiImportedRelayListsB0BD8B;

  /// App-owned interface/status text in lib/main.dart:15872. English: No imported lists.
  ///
  /// In en, this message translates to:
  /// **'No imported lists.'**
  String get uiNoImportedLists6CBC34;

  /// App-owned interface/status text in lib/main.dart:15886. English: {value} · {value2} · {value3} route(s)
  ///
  /// In en, this message translates to:
  /// **'{value3, plural, one{{value} · {value2} · {value3} route} other{{value} · {value2} · {value3} routes}}'**
  String uiValueValueValueRouteS40FB98(String value, String value2, int value3);

  /// App-owned interface/status text in lib/main.dart:15958. English: Leave blank to import unsigned (untrusted; pre-flight probes still gate use). Provide the operator's key for cryptographically trusted imports — the signature is fetched from <URL>.ed25519.sig.
  ///
  /// In en, this message translates to:
  /// **'Leave blank to import unsigned (untrusted; pre-flight probes still gate use). Provide the operator\'s key for cryptographically trusted imports — the signature is fetched from <URL>.ed25519.sig.'**
  String get uiLeaveBlankToImportUnsigned0D354E;

  /// App-owned interface/status text in lib/main.dart:16023. English: // {value}
  ///
  /// In en, this message translates to:
  /// **'// {value}'**
  String uiValueF7CD86(String value);

  /// App-owned interface/status text in lib/main.dart:16217. English: Theme
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get uiThemeA797E3;

  /// App-owned interface/status text in lib/main.dart:16245. English: Adaptive is using system dynamic colors.
  ///
  /// In en, this message translates to:
  /// **'Adaptive is using system dynamic colors.'**
  String get uiAdaptiveIsUsingSystemDynamicBAA149;

  /// App-owned interface/status text in lib/main.dart:16246. English: Mint and pink remain the Conest fallback accents.
  ///
  /// In en, this message translates to:
  /// **'Mint and pink remain the Conest fallback accents.'**
  String get uiMintAndPinkRemainTheC846F3;

  /// App-owned interface/status text in lib/main.dart:16255. English: Decoration
  ///
  /// In en, this message translates to:
  /// **'Decoration'**
  String get uiDecoration2DB87A;

  /// App-owned interface/status text in lib/main.dart:16282. English: Ambient grid, scanlines, corner reticles and the status readout. Clean ↔ full atmosphere.
  ///
  /// In en, this message translates to:
  /// **'Ambient grid, scanlines, corner reticles and the status readout. Clean ↔ full atmosphere.'**
  String get uiAmbientGridScanlinesCornerReticles45D5C5;

  /// App-owned interface/status text in lib/main.dart:16290. English: Shell
  ///
  /// In en, this message translates to:
  /// **'Shell'**
  String get uiShellBDC1FD;

  /// App-owned interface/status text in lib/main.dart:16319. English: Home layout
  ///
  /// In en, this message translates to:
  /// **'Home layout'**
  String get uiHomeLayoutE19685;

  /// App-owned interface/status text in lib/main.dart:17232. English: CONEST · ci5 · {value}
  ///
  /// In en, this message translates to:
  /// **'CONEST · ci5 · {value}'**
  String uiCONESTCiValue7964DC(String value);

  /// App-owned interface/status text in lib/main.dart:17273. English: QR unavailable
  ///
  /// In en, this message translates to:
  /// **'QR unavailable'**
  String get uiQRUnavailable12869A;

  /// App-owned interface/status text in lib/main.dart:17280. English: Use the codephrase or payload below.
  ///
  /// In en, this message translates to:
  /// **'Use the codephrase or payload below.'**
  String get uiUseTheCodephraseOrPayload187111;

  /// App-owned interface/status text in lib/main.dart:17351. English: two-way confirmed{value}
  ///
  /// In en, this message translates to:
  /// **'two-way confirmed{value}'**
  String uiTwoWayConfirmedValueE5A1A1(String value);

  /// App-owned interface/status text in lib/main.dart:17353. English: path accepts send; waiting for peer reply{value}
  ///
  /// In en, this message translates to:
  /// **'path accepts send; waiting for peer reply{value}'**
  String uiPathAcceptsSendWaitingFor10B4B0(String value);

  /// App-owned interface/status text in lib/main.dart:17354. English: unavailable
  ///
  /// In en, this message translates to:
  /// **'unavailable'**
  String get uiUnavailable1D5EE3;

  /// App-owned interface/status text in lib/main.dart:17366. English: usable
  ///
  /// In en, this message translates to:
  /// **'usable'**
  String get uiUsable829A7C;

  /// App-owned interface/status text in lib/main.dart:17368. English: one-way
  ///
  /// In en, this message translates to:
  /// **'one-way'**
  String get uiOneWay5EF4D0;

  /// App-owned interface/status text in lib/main.dart:17369. English: skip
  ///
  /// In en, this message translates to:
  /// **'skip'**
  String get uiSkipC7E168;

  /// App-owned interface/status text in lib/main.dart:17397. English: Share your invite, then either scan the QR code or enter only the current codephrase on the other device to add the contact.
  ///
  /// In en, this message translates to:
  /// **'Share your invite, then either scan the QR code or enter only the current codephrase on the other device to add the contact.'**
  String get uiShareYourInviteThenEither5FEF78;

  /// App-owned interface/status text in lib/main.dart:17437. English: Start with one trusted contact
  ///
  /// In en, this message translates to:
  /// **'Start with one trusted contact'**
  String get uiStartWithOneTrustedContact650B80;

  /// App-owned interface/status text in lib/main.dart:17444. English: This release pairs through a QR invite alone or through a codephrase alone, prefers nearby LAN routes, and falls back to internet relay routes after that.
  ///
  /// In en, this message translates to:
  /// **'This release pairs through a QR invite alone or through a codephrase alone, prefers nearby LAN routes, and falls back to internet relay routes after that.'**
  String get uiThisReleasePairsThroughA883AA2;

  /// App-owned interface/status text in lib/main.dart:17636. English: Connectivity is off. Enable LAN or Online in Settings.
  ///
  /// In en, this message translates to:
  /// **'Connectivity is off. Enable LAN or Online in Settings.'**
  String get uiConnectivityIsOffEnableLAN39990E;

  /// App-owned interface/status text in lib/main.dart:17887. English: Automatic
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get uiAutomaticAC9041;

  /// App-owned interface/status text in lib/main.dart:17888. English: Preferred
  ///
  /// In en, this message translates to:
  /// **'Preferred'**
  String get uiPreferred0A3E0D;

  /// App-owned interface/status text in lib/main.dart:17889. English: Disabled
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get uiDisabledF4F447;

  /// App-owned interface/status text in lib/main.dart:17890. English: Ask first
  ///
  /// In en, this message translates to:
  /// **'Ask first'**
  String get uiAskFirst1AEB84;

  /// App-owned interface/status text in lib/main.dart:18286. English: Retry failed
  ///
  /// In en, this message translates to:
  /// **'Retry failed'**
  String get uiRetryFailed7B6CA4;

  /// App-owned interface/status text in lib/main.dart:18326. English: Cancel album
  ///
  /// In en, this message translates to:
  /// **'Cancel album'**
  String get uiCancelAlbumDB0A07;

  /// App-owned interface/status text in lib/main.dart:18330. English: Delete album
  ///
  /// In en, this message translates to:
  /// **'Delete album'**
  String get uiDeleteAlbum52E30F;

  /// Album menu: forward every item of the album, as one album, to another chat.
  ///
  /// In en, this message translates to:
  /// **'Forward album'**
  String get menuForwardAlbum;

  /// Menu item: select this message or file (selection mode).
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get menuSelect;

  /// Album menu: select every file of the album.
  ///
  /// In en, this message translates to:
  /// **'Select album'**
  String get menuSelectAlbum;

  /// App-owned interface/status text in lib/main.dart:18413. English: {value} selected
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{{value} selected} other{{value} selected}}'**
  String uiValueSelectedB1DFAF(int value);

  /// App-owned interface/status text in lib/main.dart:18491. English: This will cancel {value} active transfer{value2} and clear the transfer list. Chat messages and completed downloaded files will stay.
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{This will cancel {value} active transfer and clear the transfer list. Chat messages and completed downloaded files will stay.} other{This will cancel {value} active transfers and clear the transfer list. Chat messages and completed downloaded files will stay.}}'**
  String uiThisWillCancelValueActiveB3425E(int value);

  /// App-owned interface/status text in lib/main.dart:18573. English: No transfers yet.
  ///
  /// In en, this message translates to:
  /// **'No transfers yet.'**
  String get uiNoTransfersYetB8E5C1;

  /// App-owned interface/status text in lib/main.dart:19369. English: Attachment metadata unavailable
  ///
  /// In en, this message translates to:
  /// **'Attachment metadata unavailable'**
  String get uiAttachmentMetadataUnavailableE2C31D;

  /// App-owned interface/status text in lib/main.dart:19437. English: {value} MB · preparing download…
  ///
  /// In en, this message translates to:
  /// **'{value} MB · preparing download…'**
  String uiValueMBPreparingDownload799D4A(String value);

  /// App-owned interface/status text in lib/main.dart:19440. English: {value} MB · direct route required
  ///
  /// In en, this message translates to:
  /// **'{value} MB · direct route required'**
  String uiValueMBDirectRouteRequired6379F0(String value);

  /// App-owned interface/status text in lib/main.dart:19441. English: {value} MB · tap to download
  ///
  /// In en, this message translates to:
  /// **'{value} MB · tap to download'**
  String uiValueMBTapToDownload432280(String value);

  /// App-owned interface/status text in lib/main.dart:19467. English: Preparing download…
  ///
  /// In en, this message translates to:
  /// **'Preparing download…'**
  String get uiPreparingDownload8CB769;

  /// App-owned interface/status text in lib/main.dart:19662. English: Transferring · {value}% · {value2}
  ///
  /// In en, this message translates to:
  /// **'Transferring · {value}% · {value2}'**
  String uiTransferringValueValue10EEBE(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:19664. English: Transferring · {value}
  ///
  /// In en, this message translates to:
  /// **'Transferring · {value}'**
  String uiTransferringValue9D7F13(String value);

  /// App-owned interface/status text in lib/main.dart:19815. English: Voice message
  ///
  /// In en, this message translates to:
  /// **'Voice message'**
  String get uiVoiceMessage999DEB;

  /// App-owned interface/status text in lib/main.dart:20249. English: Send as media
  ///
  /// In en, this message translates to:
  /// **'Send as media'**
  String get uiSendAsMedia061D87;

  /// App-owned interface/status text in lib/main.dart:20253. English: Send as file
  ///
  /// In en, this message translates to:
  /// **'Send as file'**
  String get uiSendAsFileB50EAF;

  /// App-owned interface/status text in lib/main.dart:20267. English: MEDIA
  ///
  /// In en, this message translates to:
  /// **'MEDIA'**
  String get uiMEDIAB85FA2;

  /// App-owned interface/status text in lib/main.dart:20268. English: FILE
  ///
  /// In en, this message translates to:
  /// **'FILE'**
  String get uiFILEB4915D;

  /// App-owned interface/status text in lib/main.dart:20379. English: Paused by peer
  ///
  /// In en, this message translates to:
  /// **'Paused by peer'**
  String get uiPausedByPeer63BD05;

  /// App-owned interface/status text in lib/main.dart:20458. English: Could not decode this image.
  ///
  /// In en, this message translates to:
  /// **'Could not decode this image.'**
  String get uiCouldNotDecodeThisImage3EAA16;

  /// App-owned interface/status text in lib/main.dart:20535. English: {value}  ·  {value2}/{value3}
  ///
  /// In en, this message translates to:
  /// **'{value}  ·  {value2}/{value3}'**
  String uiValueValueValueDAEE95(String value, String value2, String value3);

  /// App-owned interface/status text in lib/main.dart:20726. English: {value} cannot be reached over Conest right now. Send this message to {value2} as an ordinary Matrix message instead?
  ///
  /// It goes to your Matrix direct chat with them, not through Conest encryption: the homeserver can read it unless that chat is encrypted. Conest stops trying to deliver it.
  ///
  /// In en, this message translates to:
  /// **'{value} cannot be reached over Conest right now. Send this message to {value2} as an ordinary Matrix message instead?\n\nIt goes to your Matrix direct chat with them, not through Conest encryption: the homeserver can read it unless that chat is encrypted. Conest stops trying to deliver it.'**
  String uiValueCannotBeReachedOver14E8C2(String value, String value2);

  /// App-owned interface/status text in lib/main.dart:20836. English: +{value}
  ///
  /// In en, this message translates to:
  /// **'+{value}'**
  String uiValueF69855(String value);

  /// App-owned interface/status text in lib/main.dart:21087. English: Could not play this video: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not play this video: {value}'**
  String uiCouldNotPlayThisVideoF7D318(String value);

  /// App-owned interface/status text in lib/main.dart:21180. English: You left
  ///
  /// In en, this message translates to:
  /// **'You left'**
  String get uiYouLeft9F2CDB;

  /// App-owned interface/status text in lib/main.dart:21319. English: Replying to {value}
  ///
  /// In en, this message translates to:
  /// **'Replying to {value}'**
  String uiReplyingToValue645786(String value);

  /// App-owned interface/status text in lib/main.dart:21395. English: No scheduled messages
  ///
  /// In en, this message translates to:
  /// **'No scheduled messages'**
  String get uiNoScheduledMessages1DDB60;

  /// App-owned interface/status text in lib/main.dart:21414. English: Scheduled attachment
  ///
  /// In en, this message translates to:
  /// **'Scheduled attachment'**
  String get uiScheduledAttachment08DB0E;

  /// App-owned interface/status text in lib/main.dart:21420. English: {value} • {value2}
  /// {value3}
  ///
  /// In en, this message translates to:
  /// **'{value} • {value2}\n{value3}'**
  String uiValueValueValue209DD2(String value, String value2, String value3);

  /// App-owned interface/status text in lib/main.dart:21502. English: Send now
  ///
  /// In en, this message translates to:
  /// **'Send now'**
  String get uiSendNowDAE330;

  /// App-owned interface/status text in lib/main.dart:21505. English: Reschedule
  ///
  /// In en, this message translates to:
  /// **'Reschedule'**
  String get uiReschedule34B2DC;

  /// App-owned interface/status text in lib/main.dart:21591. English: Share text to…
  ///
  /// In en, this message translates to:
  /// **'Share text to…'**
  String get uiShareTextTo7B5086;

  /// App-owned interface/status text in lib/main.dart:21593. English: Share {value} to…
  ///
  /// In en, this message translates to:
  /// **'Share {value} to…'**
  String uiShareValueTo6E3BDD(String value);

  /// App-owned interface/status text in lib/main.dart:21594. English: Share {value} files to…
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{Share {value} file to…} other{Share {value} files to…}}'**
  String uiShareValueFilesToA46E17(int value);

  /// App-owned interface/status text in lib/main.dart:21729. English: If messages and files from a phone on the same network never arrive (but yours reach it), Windows Firewall is blocking them. This lets other devices on any network reach Conest on this PC; Windows asks to confirm.
  ///
  /// In en, this message translates to:
  /// **'If messages and files from a phone on the same network never arrive (but yours reach it), Windows Firewall is blocking them. This lets other devices on any network reach Conest on this PC; Windows asks to confirm.'**
  String get uiIfMessagesAndFilesFrom3DED27;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:86. English: Server refused sign-out
  ///
  /// In en, this message translates to:
  /// **'Server refused sign-out'**
  String get uiServerRefusedSignOut66337B;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:86. English: Server not reached
  ///
  /// In en, this message translates to:
  /// **'Server not reached'**
  String get uiServerNotReached62FED2;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:89. English: This server does not let Conest end its session ({value}). It may manage sessions on its own account page.
  ///
  /// Sign out on this device anyway? Then remove the Conest session from your account page or another Matrix app.
  ///
  /// In en, this message translates to:
  /// **'This server does not let Conest end its session ({value}). It may manage sessions on its own account page.\n\nSign out on this device anyway? Then remove the Conest session from your account page or another Matrix app.'**
  String uiThisServerDoesNotLet9EEC1F(String value);

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:93. English: Conest could not sign this device out on the server ({value}).
  ///
  /// Sign out on this device anyway? The session stays valid on the server until you remove it from another Matrix app.
  ///
  /// In en, this message translates to:
  /// **'Conest could not sign this device out on the server ({value}).\n\nSign out on this device anyway? The session stays valid on the server until you remove it from another Matrix app.'**
  String uiConestCouldNotSignThis3C1074(String value);

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:161. English: Enabled
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get uiEnabledDF174A;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:162. English: Your encrypted Matrix history is already backed up. Use "Enter recovery key" on a new device.
  ///
  /// In en, this message translates to:
  /// **'Your encrypted Matrix history is already backed up. Use \"Enter recovery key\" on a new device.'**
  String get uiYourEncryptedMatrixHistoryIsC16CD2;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:164. English: This account already has a recovery key. Use "Enter recovery key" or "Verify with another session" to unlock your encrypted history on this device.
  ///
  /// In en, this message translates to:
  /// **'This account already has a recovery key. Use \"Enter recovery key\" or \"Verify with another session\" to unlock your encrypted history on this device.'**
  String get uiThisAccountAlreadyHasA0CF3D8;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:313. English: Matrix: {value}
  ///
  /// In en, this message translates to:
  /// **'Matrix: {value}'**
  String uiMatrixValueED6C29(String value);

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:315. English: {value}{value2}
  ///
  /// In en, this message translates to:
  /// **'{value}{value2}'**
  String uiValueValueB5F18A(String value, String value2);

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:365. English: Matrix fallback
  ///
  /// In en, this message translates to:
  /// **'Matrix fallback'**
  String get uiMatrixFallbackAA082C;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:365. English: Matrix account
  ///
  /// In en, this message translates to:
  /// **'Matrix account'**
  String get uiMatrixAccountD69140;

  /// App-owned interface/status text in lib/src/ui/matrix_account_panel.dart:437. English: Accounts that sign in through Google, GitHub or another provider, or through matrix.org, use the browser.
  ///
  /// In en, this message translates to:
  /// **'Accounts that sign in through Google, GitHub or another provider, or through matrix.org, use the browser.'**
  String get uiAccountsThatSignInThrough64868A;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:87. English: This account is on {value} devices.
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{This account is on {value} device.} other{This account is on {value} devices.}}'**
  String uiThisAccountIsOnValueB78C80(int value);

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:88. English: Use Conest on more than one device: link a phone, tablet or computer to this account. Your contacts see one person.
  ///
  /// In en, this message translates to:
  /// **'Use Conest on more than one device: link a phone, tablet or computer to this account. Your contacts see one person.'**
  String get uiUseConestOnMoreThanD2AA6A;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:142. English: This device was linked less than a day ago, so it cannot add or remove devices yet.
  ///
  /// In en, this message translates to:
  /// **'This device was linked less than a day ago, so it cannot add or remove devices yet.'**
  String get uiThisDeviceWasLinkedLess2E5122;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:151. English: Pause syncing with a device out of touch for
  ///
  /// In en, this message translates to:
  /// **'Pause syncing with a device out of touch for'**
  String get uiPauseSyncingWithADevice89642E;

  /// App-owned interface/status text in lib/src/ui/devices_panel.dart:166. English: {value} days
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{{value} day} other{{value} days}}'**
  String uiValueDaysEE919A(int value);

  /// App-owned interface/status text in lib/src/ui/network_chat_sources.dart:348. English: Chats from other networks
  ///
  /// In en, this message translates to:
  /// **'Chats from other networks'**
  String get uiChatsFromOtherNetworks13CDCD;

  /// App-owned interface/status text in lib/src/ui/network_chat_sources.dart:357. English: Show {value} chats in the chat list
  ///
  /// In en, this message translates to:
  /// **'Show {value} chats in the chat list'**
  String uiShowValueChatsInTheBC0E41(String value);

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:58. English: Chat with Delta Chat users through your email account. Set up Email above first.
  ///
  /// In en, this message translates to:
  /// **'Chat with Delta Chat users through your email account. Set up Email above first.'**
  String get uiChatWithDeltaChatUsers3B8607;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:60. English: Chat with Delta Chat users as {value}, one to one and in groups. End-to-end encrypted (OpenPGP, without forward secrecy); the mail servers see who writes to whom and when.
  ///
  /// In en, this message translates to:
  /// **'Chat with Delta Chat users as {value}, one to one and in groups. End-to-end encrypted (OpenPGP, without forward secrecy); the mail servers see who writes to whom and when.'**
  String uiChatWithDeltaChatUsersABD3F5(String value);

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:267. English: No Delta Chat chats yet. Share your invite, or join with someone's.
  ///
  /// In en, this message translates to:
  /// **'No Delta Chat chats yet. Share your invite, or join with someone\'s.'**
  String get uiNoDeltaChatChatsYetF4C538;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:284. English: Request: {value}
  ///
  /// In en, this message translates to:
  /// **'Request: {value}'**
  String uiRequestValueE6C033(String value);

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:338. English: Nobody to add yet: start a chat first. You can share the group's invite once it exists.
  ///
  /// In en, this message translates to:
  /// **'Nobody to add yet: start a chat first. You can share the group\'s invite once it exists.'**
  String get uiNobodyToAddYetStart0983BB;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:346. English: verified
  ///
  /// In en, this message translates to:
  /// **'verified'**
  String get uiVerifiedEC734B;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:502. English: Add {value}
  ///
  /// In en, this message translates to:
  /// **'Add {value}'**
  String uiAddValueF546E5(String value);

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:534. English: Chat deleted
  ///
  /// In en, this message translates to:
  /// **'Chat deleted'**
  String get uiChatDeleted73DC61;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:604. English: Leave group
  ///
  /// In en, this message translates to:
  /// **'Leave group'**
  String get uiLeaveGroup925789;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:620. English: Waiting for the invite to be answered; this can take a minute.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the invite to be answered; this can take a minute.'**
  String get uiWaitingForTheInviteTo1C712D;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:623. English: Encrypted with OpenPGP (Delta Chat), without forward secrecy. The mail servers see who writes to whom and when.
  ///
  /// In en, this message translates to:
  /// **'Encrypted with OpenPGP (Delta Chat), without forward secrecy. The mail servers see who writes to whom and when.'**
  String get uiEncryptedWithOpenPGPDeltaChat9C6326;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:626. English: A request from someone you have not chatted with. Replying accepts it.
  ///
  /// In en, this message translates to:
  /// **'A request from someone you have not chatted with. Replying accepts it.'**
  String get uiARequestFromSomeoneYouAE0967;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:675. English: read
  ///
  /// In en, this message translates to:
  /// **'read'**
  String get uiReadA7AFDD;

  /// App-owned interface/status text in lib/src/ui/delta_chats_screen.dart:676. English: not sent
  ///
  /// In en, this message translates to:
  /// **'not sent'**
  String get uiNotSentBE2B9D;

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:45. English: Could not join the call. Check your route or leave the current call.
  ///
  /// In en, this message translates to:
  /// **'Could not join the call. Check your route or leave the current call.'**
  String get uiCouldNotJoinTheCall252D45;

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:102. English: Call in {value}
  ///
  /// In en, this message translates to:
  /// **'Call in {value}'**
  String uiCallInValue16F998(String value);

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:103. English: {value} started a call in {value2}
  ///
  /// In en, this message translates to:
  /// **'{value} started a call in {value2}'**
  String uiValueStartedACallIn278E96(String value, String value2);

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:113. English: Return
  ///
  /// In en, this message translates to:
  /// **'Return'**
  String get uiReturn24F096;

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:180. English: Could not update the call.
  ///
  /// In en, this message translates to:
  /// **'Could not update the call.'**
  String get uiCouldNotUpdateTheCall33517D;

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:250. English: Voice call
  ///
  /// In en, this message translates to:
  /// **'Voice call'**
  String get uiVoiceCallB8499D;

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:258. English: Call via {value}
  ///
  /// In en, this message translates to:
  /// **'Call via {value}'**
  String uiCallViaValue0A68E8(String value);

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:278. English: {value} (you)
  ///
  /// In en, this message translates to:
  /// **'{value} (you)'**
  String uiValueYouEFED9A(String value);

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:357. English: Talking…
  ///
  /// In en, this message translates to:
  /// **'Talking…'**
  String get uiTalkingC34D84;

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:358. English: Hold to talk · Space
  ///
  /// In en, this message translates to:
  /// **'Hold to talk · Space'**
  String get uiHoldToTalkSpace869505;

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:440. English: Voice call · {value}
  ///
  /// In en, this message translates to:
  /// **'Voice call · {value}'**
  String uiVoiceCallValueBD3141(String value);

  /// App-owned interface/status text in lib/src/ui/group_call_screen.dart:442. English: Started by {value} · {value2} participants
  ///
  /// In en, this message translates to:
  /// **'{value2, plural, one{Started by {value} · {value2} participant} other{Started by {value} · {value2} participants}}'**
  String uiStartedByValueValueParticipants99F03D(String value, int value2);

  /// App-owned interface/status text in lib/src/ui/reticulum_carrier_panel.dart:246. English: Node (rnsd)
  ///
  /// In en, this message translates to:
  /// **'Node (rnsd)'**
  String get uiNodeRnsd0D8EEC;

  /// App-owned interface/status text in lib/src/ui/reticulum_carrier_panel.dart:251. English: RNode on USB
  ///
  /// In en, this message translates to:
  /// **'RNode on USB'**
  String get uiRNodeOnUSBF00220;

  /// App-owned interface/status text in lib/src/ui/reticulum_carrier_panel.dart:256. English: RNode on Bluetooth
  ///
  /// In en, this message translates to:
  /// **'RNode on Bluetooth'**
  String get uiRNodeOnBluetooth13657D;

  /// App-owned interface/status text in lib/src/ui/reticulum_carrier_panel.dart:260. English: RNode on Wi-Fi
  ///
  /// In en, this message translates to:
  /// **'RNode on Wi-Fi'**
  String get uiRNodeOnWiFiC18593;

  /// App-owned interface/status text in lib/src/ui/reticulum_carrier_panel.dart:283. English: Scan for radios
  ///
  /// In en, this message translates to:
  /// **'Scan for radios'**
  String get uiScanForRadios2B185E;

  /// App-owned interface/status text in lib/src/ui/reticulum_carrier_panel.dart:354. English: Use the same frequency, bandwidth and spreading factor as the Reticulum network the radio joins.
  ///
  /// In en, this message translates to:
  /// **'Use the same frequency, bandwidth and spreading factor as the Reticulum network the radio joins.'**
  String get uiUseTheSameFrequencyBandwidthFC1A9F;

  /// App-owned interface/status text in lib/src/ui/app_mode_selector.dart:34. English: App mode
  ///
  /// In en, this message translates to:
  /// **'App mode'**
  String get uiAppMode2965FD;

  /// App-owned interface/status text in lib/src/ui/app_mode_selector.dart:43. English: Both
  ///
  /// In en, this message translates to:
  /// **'Both'**
  String get uiBoth1F4698;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:64. English: Could not start the chat: {value}
  ///
  /// In en, this message translates to:
  /// **'Could not start the chat: {value}'**
  String uiCouldNotStartTheChatAE2F54(String value);

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:395. English: Messages are end-to-end encrypted, but your homeserver and theirs see who talks to whom and when. Verify {value} to be sure it is them.
  ///
  /// In en, this message translates to:
  /// **'Messages are end-to-end encrypted, but your homeserver and theirs see who talks to whom and when. Verify {value} to be sure it is them.'**
  String uiMessagesAreEndToEndE786B5(String value);

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:398. English: This chat is not encrypted: your homeserver and theirs can read it.
  ///
  /// In en, this message translates to:
  /// **'This chat is not encrypted: your homeserver and theirs can read it.'**
  String get uiThisChatIsNotEncrypted799D99;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:435. English: Loading…
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get uiLoading33CE41;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:435. English: Load earlier messages
  ///
  /// In en, this message translates to:
  /// **'Load earlier messages'**
  String get uiLoadEarlierMessages4AC08D;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:479. English: Editing
  ///
  /// In en, this message translates to:
  /// **'Editing'**
  String get uiEditing3B9BA1;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:480. English: Reply to {value}: {value2}
  ///
  /// In en, this message translates to:
  /// **'Reply to {value}: {value2}'**
  String uiReplyToValueValue666B4E(String value, String value2);

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:686. English: You were invited to this Matrix chat.
  ///
  /// In en, this message translates to:
  /// **'You were invited to this Matrix chat.'**
  String get uiYouWereInvitedToThisE30D1E;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:768. English: edited ·
  ///
  /// In en, this message translates to:
  /// **'edited · '**
  String get uiEdited0E3C32;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:823. English: Unable to decrypt this message yet
  ///
  /// In en, this message translates to:
  /// **'Unable to decrypt this message yet'**
  String get uiUnableToDecryptThisMessage8A31CC;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:838. English: Unsupported message
  ///
  /// In en, this message translates to:
  /// **'Unsupported message'**
  String get uiUnsupportedMessage9E48EB;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:895. English: Image unavailable: {value}
  ///
  /// In en, this message translates to:
  /// **'Image unavailable: {value}'**
  String uiImageUnavailableValueB024FC(String value);

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:954. English: Download failed: {value}
  ///
  /// In en, this message translates to:
  /// **'Download failed: {value}'**
  String uiDownloadFailedValueB18BB6(String value);

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:985. English: File
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get uiFile2C3CAF;

  /// App-owned interface/status text in lib/src/ui/matrix_room_screen.dart:986. English: {value} KiB
  ///
  /// In en, this message translates to:
  /// **'{value} KiB'**
  String uiValueKiBEC48AF(String value);

  /// App-owned interface/status text in lib/src/ui/signature_panels.dart:48. English: CODEPHRASE
  ///
  /// In en, this message translates to:
  /// **'CODEPHRASE'**
  String get uiCODEPHRASEE2C724;

  /// App-owned interface/status text in lib/src/ui/signature_panels.dart:70. English: ROTATES IN {value}s
  ///
  /// In en, this message translates to:
  /// **'ROTATES IN {value}s'**
  String uiROTATESINValueS5745B8(String value);

  /// App-owned interface/status text in lib/src/ui/signature_panels.dart:188. English: ROUTE INSPECTOR
  ///
  /// In en, this message translates to:
  /// **'ROUTE INSPECTOR'**
  String get uiROUTEINSPECTOR321AA4;

  /// App-owned interface/status text in lib/src/ui/signature_panels.dart:198. English: ● LIVE
  ///
  /// In en, this message translates to:
  /// **'● LIVE'**
  String get uiLIVE67B40B;

  /// App-owned interface/status text in lib/src/ui/radio_chats_screen.dart:182. English: {value} chats
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{{value} chat} other{{value} chats}}'**
  String uiValueChatsAD9A3B(int value);

  /// App-owned interface/status text in lib/src/ui/radio_chats_screen.dart:350. English: {value} ({value2})
  ///
  /// In en, this message translates to:
  /// **'{value} ({value2})'**
  String uiValueValue167E51(String value, String value2);

  /// App-owned interface/status text in lib/src/ui/radio_chats_screen.dart:365. English: not delivered (their radio could not read it)
  ///
  /// In en, this message translates to:
  /// **'not delivered (their radio could not read it)'**
  String get uiNotDeliveredTheirRadioCould75D581;

  /// App-owned interface/status text in lib/src/ui/radio_chats_screen.dart:372. English: sender not verified
  ///
  /// In en, this message translates to:
  /// **'sender not verified'**
  String get uiSenderNotVerified2BB0FA;

  /// App-owned interface/status text in lib/src/ui/bitchat_chats_screen.dart:46. English: You are hidden
  ///
  /// In en, this message translates to:
  /// **'You are hidden'**
  String get uiYouAreHidden56DCC1;

  /// App-owned interface/status text in lib/src/ui/bitchat_chats_screen.dart:48. English: You read the mesh chat, but bitchat users cannot see you or write to you. Turn on "Reachable by bitchat users" in Settings → Connectivity to write.
  ///
  /// In en, this message translates to:
  /// **'You read the mesh chat, but bitchat users cannot see you or write to you. Turn on \"Reachable by bitchat users\" in Settings → Connectivity to write.'**
  String get uiYouReadTheMeshChatAEACC5;

  /// App-owned interface/status text in lib/src/ui/bitchat_chats_screen.dart:59. English: Everyone nearby, over Bluetooth
  ///
  /// In en, this message translates to:
  /// **'Everyone nearby, over Bluetooth'**
  String get uiEveryoneNearbyOverBluetooth7B8D63;

  /// App-owned interface/status text in lib/src/ui/bitchat_chats_screen.dart:70. English: No bitchat users nearby yet
  ///
  /// In en, this message translates to:
  /// **'No bitchat users nearby yet'**
  String get uiNoBitchatUsersNearbyYetD30471;

  /// App-owned interface/status text in lib/src/ui/bitchat_chats_screen.dart:72. English: Phones in Bluetooth range that announce themselves show up here.
  ///
  /// In en, this message translates to:
  /// **'Phones in Bluetooth range that announce themselves show up here.'**
  String get uiPhonesInBluetoothRangeThatDCCC0D;

  /// App-owned interface/status text in lib/src/ui/bitchat_chats_screen.dart:86. English: Nearby
  ///
  /// In en, this message translates to:
  /// **'Nearby'**
  String get uiNearbyF1536C;

  /// App-owned interface/status text in lib/src/ui/bitchat_chats_screen.dart:227. English: Everyone in Bluetooth range reads this chat, and anyone can relay it. Messages are signed, not encrypted.
  ///
  /// In en, this message translates to:
  /// **'Everyone in Bluetooth range reads this chat, and anyone can relay it. Messages are signed, not encrypted.'**
  String get uiEveryoneInBluetoothRangeReadsA7628A;

  /// App-owned interface/status text in lib/src/ui/bitchat_chats_screen.dart:235. English: Encrypted between the two phones (bitchat's Noise), with forward secrecy only while you are both nearby.
  ///
  /// In en, this message translates to:
  /// **'Encrypted between the two phones (bitchat\'s Noise), with forward secrecy only while you are both nearby.'**
  String get uiEncryptedBetweenTheTwoPhones3871C4;

  /// App-owned interface/status text in lib/src/ui/bitchat_chats_screen.dart:243. English: This chat was with an earlier bitchat identity of yours. Writing now tells them your new one is the same person.
  ///
  /// In en, this message translates to:
  /// **'This chat was with an earlier bitchat identity of yours. Writing now tells them your new one is the same person.'**
  String get uiThisChatWasWithAn0507F9;

  /// App-owned interface/status text in lib/src/ui/bitchat_chats_screen.dart:280. English: {value}#{value2}
  ///
  /// In en, this message translates to:
  /// **'{value}#{value2}'**
  String uiValueValue64C067(String value, String value2);

  /// App-owned interface/status text in lib/src/ui/matrix_verification_dialog.dart:160. English: Verify this session
  ///
  /// In en, this message translates to:
  /// **'Verify this session'**
  String get uiVerifyThisSessionB5065C;

  /// Settings → Connectivity, Bluetooth mesh: Bluetooth mesh on
  ///
  /// In en, this message translates to:
  /// **'Bluetooth mesh on'**
  String get uiBluetoothMeshOn5A96FE;

  /// Settings → Connectivity, Bluetooth mesh: Starting Bluetooth
  ///
  /// In en, this message translates to:
  /// **'Starting Bluetooth'**
  String get uiStartingBluetoothE6928A;

  /// Settings → Connectivity, Bluetooth mesh: Bluetooth unavailable
  ///
  /// In en, this message translates to:
  /// **'Bluetooth unavailable'**
  String get uiBluetoothUnavailableF4B751;

  /// Explains public bitchat visibility. value is the chosen nickname; preserve it exactly.
  ///
  /// In en, this message translates to:
  /// **'bitchat users nearby see you as \"{value}\" while you are in range, and can write to you. The identity they see is new every week and has nothing to do with your Conest identity.'**
  String uiBitchatUsersNearbySeeYou1B54FC(String value);

  /// Settings → Connectivity, Bluetooth mesh: Off: bitchat users do not see this device. You can still read the mesh chat.
  ///
  /// In en, this message translates to:
  /// **'Off: bitchat users do not see this device. You can still read the mesh chat.'**
  String get uiOffBitchatUsersDoNot054F9A;

  /// Explains internet sharing and its privacy tradeoff. value is an optional localized area-count suffix, including spacing.
  ///
  /// In en, this message translates to:
  /// **'Phones nearby without internet can use bitchat\'s location channels through this device. Only those public, signed messages pass. This device connects to the relays of the areas they use{value}: those relays see your internet address and the area, so they can tell roughly where you are.'**
  String uiPhonesNearbyWithoutInternetCan27CC7F(String value);

  /// Settings → Connectivity, Bluetooth mesh: Off: bitchat users nearby without internet cannot reach location channels through you.
  ///
  /// In en, this message translates to:
  /// **'Off: bitchat users nearby without internet cannot reach location channels through you.'**
  String get uiOffBitchatUsersNearbyWithout030CFB;

  /// App-owned interface/status text in lib/src/ui/bitchat_carrier_panel.dart:209. English: {value} nearby · the mesh chat and private chats
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{{value} nearby · the mesh chat and private chats} other{{value} nearby · the mesh chat and private chats}}'**
  String uiValueNearbyTheMeshChat31C0CA(int value);

  /// App-owned interface/status text in lib/src/ui/matrix_home_screen.dart:114. English: Sign in to your Matrix account
  ///
  /// In en, this message translates to:
  /// **'Sign in to your Matrix account'**
  String get uiSignInToYourMatrix8D0037;

  /// App-owned interface/status text in lib/src/ui/matrix_home_screen.dart:179. English: No rooms found
  ///
  /// In en, this message translates to:
  /// **'No rooms found'**
  String get uiNoRoomsFoundAD2C3E;

  /// App-owned interface/status text in lib/src/ui/matrix_home_screen.dart:203. English: Matrix invitation
  ///
  /// In en, this message translates to:
  /// **'Matrix invitation'**
  String get uiMatrixInvitation525106;

  /// App-owned interface/status text in lib/src/ui/matrix_home_screen.dart:205. English: Encrypted chat
  ///
  /// In en, this message translates to:
  /// **'Encrypted chat'**
  String get uiEncryptedChat0D7563;

  /// App-owned interface/status text in lib/src/ui/matrix_home_screen.dart:205. English: Chat
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get uiChat2CED57;

  /// App-owned interface/status text in lib/src/ui/nostr_chats_screen.dart:175. English: No Nostr chats yet
  ///
  /// In en, this message translates to:
  /// **'No Nostr chats yet'**
  String get uiNoNostrChatsYet0A95D0;

  /// App-owned interface/status text in lib/src/ui/nostr_chats_screen.dart:303. English: Encrypted on Nostr (NIP-17); relays see neither who wrote nor when. No forward secrecy.
  ///
  /// In en, this message translates to:
  /// **'Encrypted on Nostr (NIP-17); relays see neither who wrote nor when. No forward secrecy.'**
  String get uiEncryptedOnNostrNIPRelaysA51F70;

  /// App-owned interface/status text in lib/src/ui/route_test_panel.dart:109. English: Testing routes…
  ///
  /// In en, this message translates to:
  /// **'Testing routes…'**
  String get uiTestingRoutes19C586;

  /// App-owned interface/status text in lib/src/ui/route_test_panel.dart:109. English: Test Routes
  ///
  /// In en, this message translates to:
  /// **'Test Routes'**
  String get uiTestRoutes52770A;

  /// App-owned interface/status text in lib/src/ui/route_test_panel.dart:117. English: Checking whether their app can take route tests…
  ///
  /// In en, this message translates to:
  /// **'Checking whether their app can take route tests…'**
  String get uiCheckingWhetherTheirAppCan51E401;

  /// App-owned interface/status text in lib/src/ui/route_test_panel.dart:118. English: Their app did not say it can take route tests. If they run this version too, they may not be reachable right now.
  ///
  /// In en, this message translates to:
  /// **'Their app did not say it can take route tests. If they run this version too, they may not be reachable right now.'**
  String get uiTheirAppDidNotSay758036;

  /// App-owned interface/status text in lib/src/ui/route_test_panel.dart:137. English: No route took the test.
  ///
  /// In en, this message translates to:
  /// **'No route took the test.'**
  String get uiNoRouteTookTheTestF2F6CB;

  /// App-owned interface/status text in lib/src/ui/route_test_panel.dart:164. English: Tested {value}. Routes that answer go first for messages.
  ///
  /// In en, this message translates to:
  /// **'Tested {value}. Routes that answer go first for messages.'**
  String uiTestedValueRoutesThatAnswer70B842(String value);

  /// App-owned interface/status text in lib/src/ui/meshcore_carrier_panel.dart:130. English: USB
  ///
  /// In en, this message translates to:
  /// **'USB'**
  String get uiUSB09716C;

  /// App-owned interface/status text in lib/src/ui/error_history_screen.dart:50. English: Copied the error history.
  ///
  /// In en, this message translates to:
  /// **'Copied the error history.'**
  String get uiCopiedTheErrorHistoryCE02E2;

  /// App-owned interface/status text in lib/src/ui/error_history_screen.dart:135. English: Nothing recorded.
  ///
  /// In en, this message translates to:
  /// **'Nothing recorded.'**
  String get uiNothingRecordedA27006;

  /// App-owned interface/status text in lib/src/ui/error_history_screen.dart:144. English: {value}  ·  {value2}
  ///
  /// In en, this message translates to:
  /// **'{value}  ·  {value2}'**
  String uiValueValue1C180E(String value, String value2);

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:111. English: {value}: {value2} {value3}{value4}
  ///
  /// In en, this message translates to:
  /// **'{value}: {value2} {value3}{value4}'**
  String uiValueValueValueValue56C1C1(
    String value,
    String value2,
    String value3,
    String value4,
  );

  /// App-owned interface/status text in lib/src/ui/message_info_dialog.dart:176. English: Route: {value}
  ///
  /// In en, this message translates to:
  /// **'Route: {value}'**
  String uiRouteValue9D8426(String value);

  /// App-owned interface/status text in lib/src/ui/meshtastic_carrier_panel.dart:133. English: {value} · !{value2}
  ///
  /// In en, this message translates to:
  /// **'{value} · !{value2}'**
  String uiValueValue7B4608(String value, String value2);

  /// App-owned interface/status text in lib/src/ui/meshtastic_carrier_panel.dart:148. English: Network
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get uiNetwork53EBC5;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:642. English: Image is larger than the {value} MB cap.
  ///
  /// In en, this message translates to:
  /// **'Image is larger than the {value} MB cap.'**
  String uiImageIsLargerThanTheEE56C5(String value);

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:706. English: File is larger than the {value} MB cap.
  ///
  /// In en, this message translates to:
  /// **'File is larger than the {value} MB cap.'**
  String uiFileIsLargerThanTheAF488F(String value);

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:767. English: Send {value}
  ///
  /// In en, this message translates to:
  /// **'Send {value}'**
  String uiSendValueBF4C3C(String value);

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:811. English: Recent
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get uiRecent76EEC7;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:839. English: Conest sees only the photos you picked.
  ///
  /// In en, this message translates to:
  /// **'Conest sees only the photos you picked.'**
  String get uiConestSeesOnlyThePhotosEE1926;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:943. English: Photos permission denied. Use "Browse files…" to send any file, or grant access in system settings.
  ///
  /// In en, this message translates to:
  /// **'Photos permission denied. Use \"Browse files…\" to send any file, or grant access in system settings.'**
  String get uiPhotosPermissionDeniedUseBrowseD672EE;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:963. English: No photos or videos here.
  ///
  /// In en, this message translates to:
  /// **'No photos or videos here.'**
  String get uiNoPhotosOrVideosHereC729D1;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:1220. English: Could not decode the image to rotate it.
  ///
  /// In en, this message translates to:
  /// **'Could not decode the image to rotate it.'**
  String get uiCouldNotDecodeTheImage69AC9D;

  /// App-owned interface/status text in lib/src/media_picker_sheet.dart:1240. English: Rotation failed: {value}
  ///
  /// In en, this message translates to:
  /// **'Rotation failed: {value}'**
  String uiRotationFailedValue176CC6(String value);

  /// App-owned interface/status text in lib/src/group_file_tile.dart:102. English: {value} of {value2} verified
  ///
  /// In en, this message translates to:
  /// **'{value} of {value2} verified'**
  String uiValueOfValueVerified63B11D(String value, String value2);

  /// App-owned interface/status text in lib/src/qr_scan_screen.dart:62. English: Point the camera at a Conest invite QR code.
  ///
  /// In en, this message translates to:
  /// **'Point the camera at a Conest invite QR code.'**
  String get uiPointTheCameraAtA9BAFAF;

  /// App-owned controller status shown in the status line or an action notice. Matrix rooms show joins and leaves.
  ///
  /// In en, this message translates to:
  /// **'Matrix rooms show joins and leaves.'**
  String get statusMatrixRoomsShowJoinsAndE8AC9E;

  /// App-owned controller status shown in the status line or an action notice. Matrix rooms hide joins and leaves.
  ///
  /// In en, this message translates to:
  /// **'Matrix rooms hide joins and leaves.'**
  String get statusMatrixRoomsHideJoinsAndE00610;

  /// App-owned controller status shown in the status line or an action notice. App mode: {value}.
  ///
  /// In en, this message translates to:
  /// **'App mode: {value}.'**
  String statusAppMode95B48F(String value);

  /// App-owned controller status shown in the status line or an action notice. Calling {value}…
  ///
  /// In en, this message translates to:
  /// **'Calling {value}…'**
  String statusCalling7A8C67(String value);

  /// App-owned controller status shown in the status line or an action notice. Updated history visibility for future group members.
  ///
  /// In en, this message translates to:
  /// **'Updated history visibility for future group members.'**
  String get statusUpdatedHistoryVisibilityForFutureDA1A23;

  /// App-owned controller status shown in the status line or an action notice. Vault unlock failed: {value}
  ///
  /// In en, this message translates to:
  /// **'Vault unlock failed: {value}'**
  String statusVaultUnlockFailedAE7813(String value);

  /// App-owned controller status shown in the status line or an action notice. Direct online transport is unavailable; relay fallback remains active.
  ///
  /// In en, this message translates to:
  /// **'Direct online transport is unavailable; relay fallback remains active.'**
  String get statusDirectOnlineTransportIsUnavailableB1EFAE;

  /// App-owned controller status shown in the status line or an action notice. Nostr carrier set up.
  ///
  /// In en, this message translates to:
  /// **'Nostr carrier set up.'**
  String get statusNostrCarrierSetUpE82998;

  /// App-owned controller status shown in the status line or an action notice. Nostr carrier removed.
  ///
  /// In en, this message translates to:
  /// **'Nostr carrier removed.'**
  String get statusNostrCarrierRemovedCB968A;

  /// App-owned controller status shown in the status line or an action notice. Nostr relays updated: a relay shut down.
  ///
  /// In en, this message translates to:
  /// **'Nostr relays updated: a relay shut down.'**
  String get statusNostrRelaysUpdatedARelay03F8F3;

  /// App-owned controller status shown in the status line or an action notice. Tor carrier set up.
  ///
  /// In en, this message translates to:
  /// **'Tor carrier set up.'**
  String get statusTorCarrierSetUp3D2304;

  /// App-owned controller status shown in the status line or an action notice. Tor carrier removed.
  ///
  /// In en, this message translates to:
  /// **'Tor carrier removed.'**
  String get statusTorCarrierRemovedAAC23E;

  /// App-owned controller status shown in the status line or an action notice. Bluetooth mesh on.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth mesh on.'**
  String get statusBluetoothMeshOn11FD21;

  /// App-owned controller status shown in the status line or an action notice. Bluetooth mesh off.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth mesh off.'**
  String get statusBluetoothMeshOff2CE954;

  /// App-owned controller status shown in the status line or an action notice. Nostr messages on.
  ///
  /// In en, this message translates to:
  /// **'Nostr messages on.'**
  String get statusNostrMessagesOn35ABF5;

  /// App-owned controller status shown in the status line or an action notice. Nostr messages off.
  ///
  /// In en, this message translates to:
  /// **'Nostr messages off.'**
  String get statusNostrMessagesOff16BCA7;

  /// App-owned controller status shown in the status line or an action notice. Delta Chat on.
  ///
  /// In en, this message translates to:
  /// **'Delta Chat on.'**
  String get statusDeltaChatOn1F38AA;

  /// App-owned controller status shown in the status line or an action notice. Delta Chat off.
  ///
  /// In en, this message translates to:
  /// **'Delta Chat off.'**
  String get statusDeltaChatOff8BDBD4;

  /// App-owned controller status shown in the status line or an action notice. bitchat users nearby can now see you as {value}.
  ///
  /// In en, this message translates to:
  /// **'bitchat users nearby can now see you as {value}.'**
  String statusBitchatUsersNearbyCanNow5536CD(String value);

  /// App-owned controller status shown in the status line or an action notice. bitchat users no longer see you.
  ///
  /// In en, this message translates to:
  /// **'bitchat users no longer see you.'**
  String get statusBitchatUsersNoLongerSee68B46D;

  /// App-owned controller status shown in the status line or an action notice. MeshCore carrier set up through {value}.
  ///
  /// In en, this message translates to:
  /// **'MeshCore carrier set up through {value}.'**
  String statusMeshcoreCarrierSetUpThroughE51369(String value);

  /// App-owned controller status shown in the status line or an action notice. MeshCore carrier removed.
  ///
  /// In en, this message translates to:
  /// **'MeshCore carrier removed.'**
  String get statusMeshcoreCarrierRemoved38FC35;

  /// App-owned controller status shown in the status line or an action notice. Meshtastic carrier set up through {value}.
  ///
  /// In en, this message translates to:
  /// **'Meshtastic carrier set up through {value}.'**
  String statusMeshtasticCarrierSetUpThroughAFA24A(String value);

  /// App-owned controller status shown in the status line or an action notice. Meshtastic carrier removed.
  ///
  /// In en, this message translates to:
  /// **'Meshtastic carrier removed.'**
  String get statusMeshtasticCarrierRemoved66387E;

  /// App-owned controller status shown in the status line or an action notice. Meshtastic app messages on.
  ///
  /// In en, this message translates to:
  /// **'Meshtastic app messages on.'**
  String get statusMeshtasticAppMessagesOn2C1888;

  /// App-owned controller status shown in the status line or an action notice. Meshtastic app messages off.
  ///
  /// In en, this message translates to:
  /// **'Meshtastic app messages off.'**
  String get statusMeshtasticAppMessagesOffAFB9E8;

  /// App-owned controller status shown in the status line or an action notice. MeshCore app messages on.
  ///
  /// In en, this message translates to:
  /// **'MeshCore app messages on.'**
  String get statusMeshcoreAppMessagesOn2BF1E3;

  /// App-owned controller status shown in the status line or an action notice. MeshCore app messages off.
  ///
  /// In en, this message translates to:
  /// **'MeshCore app messages off.'**
  String get statusMeshcoreAppMessagesOffE59C90;

  /// App-owned controller status shown in the status line or an action notice. Reticulum carrier set up through {value}.
  ///
  /// In en, this message translates to:
  /// **'Reticulum carrier set up through {value}.'**
  String statusReticulumCarrierSetUpThrough7EB41E(String value);

  /// App-owned controller status shown in the status line or an action notice. Reticulum carrier removed.
  ///
  /// In en, this message translates to:
  /// **'Reticulum carrier removed.'**
  String get statusReticulumCarrierRemoved301C05;

  /// App-owned controller status shown in the status line or an action notice. Email carrier set up as {value}.
  ///
  /// In en, this message translates to:
  /// **'Email carrier set up as {value}.'**
  String statusEmailCarrierSetUpAs8427FD(String value);

  /// App-owned controller status shown in the status line or an action notice. Email carrier removed.
  ///
  /// In en, this message translates to:
  /// **'Email carrier removed.'**
  String get statusEmailCarrierRemoved036E51;

  /// App-owned controller status shown in the status line or an action notice. Imported {value} relay(s) from {value2}.
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{Imported {value} relay from {value2}.} other{Imported {value} relays from {value2}.}}'**
  String statusImportedRelaySFromB1DB2D(int value, String value2);

  /// App-owned controller status shown in the status line or an action notice. Removed imported relay source {value}.
  ///
  /// In en, this message translates to:
  /// **'Removed imported relay source {value}.'**
  String statusRemovedImportedRelaySource3F4540(String value);

  /// App-owned controller status shown in the status line or an action notice. Pairing code rotated and advertised.
  ///
  /// In en, this message translates to:
  /// **'Pairing code rotated and advertised.'**
  String get statusPairingCodeRotatedAndAdvertised722FB9;

  /// App-owned controller status shown in the status line or an action notice. Checked {value} route(s); {value2} available. {value3}
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{Checked {value} route; {value2} available. {value3}} other{Checked {value} routes; {value2} available. {value3}}}'**
  String statusCheckedRouteSAvailableE9B9D6(
    int value,
    int value2,
    String value3,
  );

  /// App-owned controller status shown in the status line or an action notice. Checked Iroh path(s) for {value}; reachability is {value2}. {value3}
  ///
  /// In en, this message translates to:
  /// **'Checked Iroh path(s) for {value}; reachability is {value2}. {value3}'**
  String statusCheckedIrohPathSFor038B43(
    String value,
    String value2,
    String value3,
  );

  /// App-owned controller status shown in the status line or an action notice. No paths are advertised for {value}.
  ///
  /// In en, this message translates to:
  /// **'No paths are advertised for {value}.'**
  String statusNoPathsAreAdvertisedForA37EA3(String value);

  /// App-owned controller status shown in the status line or an action notice. Checked {value} path(s) for {value2}; {value3} available{value4}. Reachability is {value5}. {value6}
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{Checked {value} path for {value2}; {value3} available{value4}. Reachability is {value5}. {value6}} other{Checked {value} paths for {value2}; {value3} available{value4}. Reachability is {value5}. {value6}}}'**
  String statusCheckedPathSForAvailable0970F6(
    int value,
    String value2,
    int value3,
    String value4,
    String value5,
    String value6,
  );

  /// App-owned controller status shown in the status line or an action notice. Display name updated.
  ///
  /// In en, this message translates to:
  /// **'Display name updated.'**
  String get statusDisplayNameUpdated3BD31A;

  /// App-owned controller status shown in the status line or an action notice. Bio cleared.
  ///
  /// In en, this message translates to:
  /// **'Bio cleared.'**
  String get statusBioCleared543896;

  /// App-owned controller status shown in the status line or an action notice. Bio updated.
  ///
  /// In en, this message translates to:
  /// **'Bio updated.'**
  String get statusBioUpdated440110;

  /// App-owned controller status shown in the status line or an action notice. Contact profile updated.
  ///
  /// In en, this message translates to:
  /// **'Contact profile updated.'**
  String get statusContactProfileUpdated47ECF6;

  /// App-owned controller status shown in the status line or an action notice. Relay mode enabled.
  ///
  /// In en, this message translates to:
  /// **'Relay mode enabled.'**
  String get statusRelayModeEnabledB9ACB8;

  /// App-owned controller status shown in the status line or an action notice. Relay mode disabled.
  ///
  /// In en, this message translates to:
  /// **'Relay mode disabled.'**
  String get statusRelayModeDisabled723F4D;

  /// App-owned controller status shown in the status line or an action notice. Contacts can now contribute relay routes automatically.
  ///
  /// In en, this message translates to:
  /// **'Contacts can now contribute relay routes automatically.'**
  String get statusContactsCanNowContributeRelay147ECE;

  /// App-owned controller status shown in the status line or an action notice. Automatic contact relay usage disabled.
  ///
  /// In en, this message translates to:
  /// **'Automatic contact relay usage disabled.'**
  String get statusAutomaticContactRelayUsageDisabledE762A7;

  /// App-owned controller status shown in the status line or an action notice. Notifications enabled.
  ///
  /// In en, this message translates to:
  /// **'Notifications enabled.'**
  String get statusNotificationsEnabledF70668;

  /// App-owned controller status shown in the status line or an action notice. Notifications disabled for this device.
  ///
  /// In en, this message translates to:
  /// **'Notifications disabled for this device.'**
  String get statusNotificationsDisabledForThisDeviceE10A46;

  /// App-owned controller status shown in the status line or an action notice. Experimental voice calls enabled on this device.
  ///
  /// In en, this message translates to:
  /// **'Experimental voice calls enabled on this device.'**
  String get statusExperimentalVoiceCallsEnabledOn4081DE;

  /// App-owned controller status shown in the status line or an action notice. Experimental voice calls disabled on this device.
  ///
  /// In en, this message translates to:
  /// **'Experimental voice calls disabled on this device.'**
  String get statusExperimentalVoiceCallsDisabledOn19A5AE;

  /// App-owned controller status shown in the status line or an action notice. Android background runtime enabled. If system battery/background access is blocked, notifications can still be late or never arrive.
  ///
  /// In en, this message translates to:
  /// **'Android background runtime enabled. If system battery/background access is blocked, notifications can still be late or never arrive.'**
  String get statusAndroidBackgroundRuntimeEnabledIfAA5168;

  /// App-owned controller status shown in the status line or an action notice. Android background runtime disabled.
  ///
  /// In en, this message translates to:
  /// **'Android background runtime disabled.'**
  String get statusAndroidBackgroundRuntimeDisabled5FC9A0;

  /// App-owned controller status shown in the status line or an action notice. Background voice-call availability enabled for this device. Calls can arrive only while the Conest service is allowed to run.
  ///
  /// In en, this message translates to:
  /// **'Background voice-call availability enabled for this device. Calls can arrive only while the Conest service is allowed to run.'**
  String get statusBackgroundVoiceCallAvailabilityEnabledA87223;

  /// App-owned controller status shown in the status line or an action notice. Background voice-call availability disabled.
  ///
  /// In en, this message translates to:
  /// **'Background voice-call availability disabled.'**
  String get statusBackgroundVoiceCallAvailabilityDisabledA71AD1;

  /// App-owned controller status shown in the status line or an action notice. 10% free-space reserve enabled.
  ///
  /// In en, this message translates to:
  /// **'10% free-space reserve enabled.'**
  String get statusFreeSpaceReserveEnabledD7CE0E;

  /// App-owned controller status shown in the status line or an action notice. 10% free-space reserve disabled.
  ///
  /// In en, this message translates to:
  /// **'10% free-space reserve disabled.'**
  String get statusFreeSpaceReserveDisabledD3E635;

  /// App-owned controller status shown in the status line or an action notice. Routing preferences updated for {value}.
  ///
  /// In en, this message translates to:
  /// **'Routing preferences updated for {value}.'**
  String statusRoutingPreferencesUpdatedFor05867B(String value);

  /// App-owned controller status shown in the status line or an action notice. Local relay port updated to {value}.
  ///
  /// In en, this message translates to:
  /// **'Local relay port updated to {value}.'**
  String statusLocalRelayPortUpdatedTo7F815D(String value);

  /// App-owned controller status shown in the status line or an action notice. Relay {value} added.
  ///
  /// In en, this message translates to:
  /// **'Relay {value} added.'**
  String statusRelayAdded800692(String value);

  /// App-owned controller status shown in the status line or an action notice. Relay {value}:{value2} added for {value3}.
  ///
  /// In en, this message translates to:
  /// **'Relay {value}:{value2} added for {value3}.'**
  String statusRelayAddedFor087398(String value, String value2, String value3);

  /// App-owned controller status shown in the status line or an action notice. Relay {value} removed.
  ///
  /// In en, this message translates to:
  /// **'Relay {value} removed.'**
  String statusRelayRemoved546A15(String value);

  /// App-owned controller status shown in the status line or an action notice. Trusted new identity for relay {value}.
  ///
  /// In en, this message translates to:
  /// **'Trusted new identity for relay {value}.'**
  String statusTrustedNewIdentityForRelay4CDBFE(String value);

  /// App-owned controller status shown in the status line or an action notice. Contact removed.
  ///
  /// In en, this message translates to:
  /// **'Contact removed.'**
  String get statusContactRemovedE31CE0;

  /// App-owned controller status shown in the status line or an action notice. Contact removed locally. Sending a removal notice in the background.
  ///
  /// In en, this message translates to:
  /// **'Contact removed locally. Sending a removal notice in the background.'**
  String get statusContactRemovedLocallySendingA40D607;

  /// App-owned controller status shown in the status line or an action notice. Device created. Share a QR invite or the current codephrase to add this contact.
  ///
  /// In en, this message translates to:
  /// **'Device created. Share a QR invite or the current codephrase to add this contact.'**
  String get statusDeviceCreatedShareAQr06E7B6;

  /// App-owned controller status shown in the status line or an action notice. Contact {value} accepted. Sending approval over available routes.
  ///
  /// In en, this message translates to:
  /// **'Contact {value} accepted. Sending approval over available routes.'**
  String statusContactAcceptedSendingApprovalOverDAD10C(String value);

  /// App-owned controller status shown in the status line or an action notice. Contact {value} saved. Waiting for the other person to approve the request.
  ///
  /// In en, this message translates to:
  /// **'Contact {value} saved. Waiting for the other person to approve the request.'**
  String statusContactSavedWaitingForThe41F77D(String value);

  /// App-owned controller status shown in the status line or an action notice. Reconnected with {value}.
  ///
  /// In en, this message translates to:
  /// **'Reconnected with {value}.'**
  String statusReconnectedWithBC62EC(String value);

  /// App-owned controller status shown in the status line or an action notice. Asking {value} to reconnect.
  ///
  /// In en, this message translates to:
  /// **'Asking {value} to reconnect.'**
  String statusAskingToReconnectE93389(String value);

  /// App-owned controller status shown in the status line or an action notice. Confirmed identity replacement for {value}.
  ///
  /// In en, this message translates to:
  /// **'Confirmed identity replacement for {value}.'**
  String statusConfirmedIdentityReplacementForC93359(String value);

  /// App-owned controller status shown in the status line or an action notice. Rejected identity replacement for {value}.
  ///
  /// In en, this message translates to:
  /// **'Rejected identity replacement for {value}.'**
  String statusRejectedIdentityReplacementForDEC894(String value);

  /// App-owned controller status shown in the status line or an action notice. Contact request cancelled. Queued items remain blocked.
  ///
  /// In en, this message translates to:
  /// **'Contact request cancelled. Queued items remain blocked.'**
  String get statusContactRequestCancelledQueuedItemsEC2567;

  /// App-owned controller status shown in the status line or an action notice. Saved.
  ///
  /// In en, this message translates to:
  /// **'Saved.'**
  String get statusSaved9D4AF6;

  /// App-owned controller status shown in the status line or an action notice. Message saved locally. It will send after {value} accepts the contact request.
  ///
  /// In en, this message translates to:
  /// **'Message saved locally. It will send after {value} accepts the contact request.'**
  String statusMessageSavedLocallyItWill0DBD03(String value);

  /// App-owned controller status shown in the status line or an action notice. Trying LAN first, then relay for {value}.
  ///
  /// In en, this message translates to:
  /// **'Trying LAN first, then relay for {value}.'**
  String statusTryingLanFirstThenRelay1F5BEC(String value);

  /// App-owned controller status shown in the status line or an action notice. Message queued. The app will retry direct routes and relays while polling.
  ///
  /// In en, this message translates to:
  /// **'Message queued. The app will retry direct routes and relays while polling.'**
  String get statusMessageQueuedTheAppWillA89BCC;

  /// App-owned controller status shown in the status line or an action notice. Attachment is waiting for a route: {value}
  ///
  /// In en, this message translates to:
  /// **'Attachment is waiting for a route: {value}'**
  String statusAttachmentIsWaitingForA3F032B(String value);

  /// App-owned controller status shown in the status line or an action notice. Could not prepare {value} for download.
  ///
  /// In en, this message translates to:
  /// **'Could not prepare {value} for download.'**
  String statusCouldNotPrepareForDownloadE8FB18(String value);

  /// App-owned controller status shown in the status line or an action notice. Created group {value}.
  ///
  /// In en, this message translates to:
  /// **'Created group {value}.'**
  String statusCreatedGroupF5D335(String value);

  /// App-owned controller status shown in the status line or an action notice. Updated group {value}.
  ///
  /// In en, this message translates to:
  /// **'Updated group {value}.'**
  String statusUpdatedGroup2140B7(String value);

  /// App-owned controller status shown in the status line or an action notice. Removed a member from {value}.
  ///
  /// In en, this message translates to:
  /// **'Removed a member from {value}.'**
  String statusRemovedAMemberFrom68CF04(String value);

  /// App-owned controller status shown in the status line or an action notice. Left group {value}.
  ///
  /// In en, this message translates to:
  /// **'Left group {value}.'**
  String statusLeftGroup9E3412(String value);

  /// App-owned controller status shown in the status line or an action notice. Removed group {value} from your list.
  ///
  /// In en, this message translates to:
  /// **'Removed group {value} from your list.'**
  String statusRemovedGroupFromYourList047F4B(String value);

  /// App-owned controller status shown in the status line or an action notice. Transferred ownership of {value} to {value2}.
  ///
  /// In en, this message translates to:
  /// **'Transferred ownership of {value} to {value2}.'**
  String statusTransferredOwnershipOfToA126A1(String value, String value2);

  /// App-owned controller status shown in the status line or an action notice. Deleted group {value} for everyone.
  ///
  /// In en, this message translates to:
  /// **'Deleted group {value} for everyone.'**
  String statusDeletedGroupForEveryoneDB26F8(String value);

  /// App-owned controller status shown in the status line or an action notice. Updated {value} in {value2}.
  ///
  /// In en, this message translates to:
  /// **'Updated {value} in {value2}.'**
  String statusUpdatedIn642C0A(String value, String value2);

  /// App-owned controller status shown in the status line or an action notice. Sending group message to {value}.
  ///
  /// In en, this message translates to:
  /// **'Sending group message to {value}.'**
  String statusSendingGroupMessageToD77236(String value);

  /// App-owned controller status shown in the status line or an action notice. Sent to {value} as a plain Matrix message.
  ///
  /// In en, this message translates to:
  /// **'Sent to {value} as a plain Matrix message.'**
  String statusSentToAsAPlainAF2DE6(String value);

  /// App-owned controller status shown in the status line or an action notice. Canceled and deleted pending message to {value}.
  ///
  /// In en, this message translates to:
  /// **'Canceled and deleted pending message to {value}.'**
  String statusCanceledAndDeletedPendingMessageCDCA88(String value);

  /// App-owned controller status shown in the status line or an action notice. Message deleted locally.
  ///
  /// In en, this message translates to:
  /// **'Message deleted locally.'**
  String get statusMessageDeletedLocallyCE90EE;

  /// App-owned controller status shown in the status line or an action notice. Message deleted here and deletion was sent to {value}.
  ///
  /// In en, this message translates to:
  /// **'Message deleted here and deletion was sent to {value}.'**
  String statusMessageDeletedHereAndDeletion7C4E80(String value);

  /// App-owned controller status shown in the status line or an action notice. Message deleted here. Remote deletion could not be sent yet.
  ///
  /// In en, this message translates to:
  /// **'Message deleted here. Remote deletion could not be sent yet.'**
  String get statusMessageDeletedHereRemoteDeletionB6AE62;

  /// App-owned controller status shown in the status line or an action notice. Message edited locally.
  ///
  /// In en, this message translates to:
  /// **'Message edited locally.'**
  String get statusMessageEditedLocally187334;

  /// App-owned controller status shown in the status line or an action notice. Message edit queued to {value}.
  ///
  /// In en, this message translates to:
  /// **'Message edit queued to {value}.'**
  String statusMessageEditQueuedTo695B15(String value);

  /// App-owned controller status shown in the status line or an action notice. Reaction updated locally.
  ///
  /// In en, this message translates to:
  /// **'Reaction updated locally.'**
  String get statusReactionUpdatedLocally97D795;

  /// App-owned controller status shown in the status line or an action notice. Reaction queued to {value}.
  ///
  /// In en, this message translates to:
  /// **'Reaction queued to {value}.'**
  String statusReactionQueuedToD43BED(String value);

  /// App-owned controller status shown in the status line or an action notice. LAN lobby message saved locally; no nearby LAN participants were reachable.
  ///
  /// In en, this message translates to:
  /// **'LAN lobby message saved locally; no nearby LAN participants were reachable.'**
  String get statusLanLobbyMessageSavedLocallyFDE86E;

  /// App-owned controller status shown in the status line or an action notice. LAN lobby message sent to {value} nearby route(s).
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{LAN lobby message sent to {value} nearby route.} other{LAN lobby message sent to {value} nearby routes.}}'**
  String statusLanLobbyMessageSentTo82F0B0(int value);

  /// App-owned controller status shown in the status line or an action notice. Group {value} membership ack from {value2}.
  ///
  /// In en, this message translates to:
  /// **'Group {value} membership ack from {value2}.'**
  String statusGroupMembershipAckFrom43FCF1(String value, String value2);

  /// App-owned controller status shown in the status line or an action notice. Received {value} item(s) via {value2}.
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{Received {value} item via {value2}.} other{Received {value} items via {value2}.}}'**
  String statusReceivedItemSVia58B082(int value, String value2);

  /// App-owned controller status shown in the status line or an action notice. Route poll failed: {value}
  ///
  /// In en, this message translates to:
  /// **'Route poll failed: {value}'**
  String statusRoutePollFailedA1FD0C(String value);

  /// App-owned controller status shown in the status line or an action notice. LAN receiving is off: port {value} is in use. Pick another local relay port in Settings.
  ///
  /// In en, this message translates to:
  /// **'LAN receiving is off: port {value} is in use. Pick another local relay port in Settings.'**
  String statusLanReceivingIsOffPort5F04CB(String value);

  /// App-owned controller status shown in the status line or an action notice. Rediscovered LAN route {value} for {value2}.
  ///
  /// In en, this message translates to:
  /// **'Rediscovered LAN route {value} for {value2}.'**
  String statusRediscoveredLanRouteFor587829(String value, String value2);

  /// App-owned controller status shown in the status line or an action notice. LAN discovery unavailable: {value}
  ///
  /// In en, this message translates to:
  /// **'LAN discovery unavailable: {value}'**
  String statusLanDiscoveryUnavailable0E99AE(String value);

  /// App-owned controller status shown in the status line or an action notice. Updated nearby LAN routes.
  ///
  /// In en, this message translates to:
  /// **'Updated nearby LAN routes.'**
  String get statusUpdatedNearbyLanRoutesF8CAFC;

  /// App-owned controller status shown in the status line or an action notice. Rejected malformed attachment offer from {value}.
  ///
  /// In en, this message translates to:
  /// **'Rejected malformed attachment offer from {value}.'**
  String statusRejectedMalformedAttachmentOfferFrom9FC96A(String value);

  /// App-owned controller status shown in the status line or an action notice. Rejected invalid attachment metadata.
  ///
  /// In en, this message translates to:
  /// **'Rejected invalid attachment metadata.'**
  String get statusRejectedInvalidAttachmentMetadata849465;

  /// App-owned controller status shown in the status line or an action notice. {value} declined the request. Queued messages and files remain blocked.
  ///
  /// In en, this message translates to:
  /// **'{value} declined the request. Queued messages and files remain blocked.'**
  String statusDeclinedTheRequestQueuedMessagesABFFCB(String value);

  /// App-owned controller status shown in the status line or an action notice. New contact request from {value}.
  ///
  /// In en, this message translates to:
  /// **'New contact request from {value}.'**
  String statusNewContactRequestFromCF70B9(String value);

  /// App-owned controller status shown in the status line or an action notice. {value} left {value2}.
  ///
  /// In en, this message translates to:
  /// **'{value} left {value2}.'**
  String statusLeftF4FE32(String value, String value2);

  /// App-owned controller status shown in the status line or an action notice. {value} removed you. The conversation remains archived locally.
  ///
  /// In en, this message translates to:
  /// **'{value} removed you. The conversation remains archived locally.'**
  String statusRemovedYouTheConversationRemains3BB516(String value);

  /// App-owned controller status shown in the status line or an action notice. Updated edited message from {value}.
  ///
  /// In en, this message translates to:
  /// **'Updated edited message from {value}.'**
  String statusUpdatedEditedMessageFrom1AB90D(String value);

  /// App-owned controller status shown in the status line or an action notice. Deleted message removed by {value}.
  ///
  /// In en, this message translates to:
  /// **'Deleted message removed by {value}.'**
  String statusDeletedMessageRemovedBy5A9E79(String value);

  /// App-owned controller status shown in the status line or an action notice. Applied a reaction from {value}.
  ///
  /// In en, this message translates to:
  /// **'Applied a reaction from {value}.'**
  String statusAppliedAReactionFrom41011B(String value);

  /// App-owned controller status shown in the status line or an action notice. Applied deferred direct reactions.
  ///
  /// In en, this message translates to:
  /// **'Applied deferred direct reactions.'**
  String get statusAppliedDeferredDirectReactions1414C8;

  /// App-owned controller status shown in the status line or an action notice. Encrypted message stored for {value} via {value2}.
  ///
  /// In en, this message translates to:
  /// **'Encrypted message stored for {value} via {value2}.'**
  String statusEncryptedMessageStoredForVia029324(String value, String value2);

  /// App-owned controller status shown in the status line or an action notice. Sent to {value} via {value2}; waiting for a delivery receipt.
  ///
  /// In en, this message translates to:
  /// **'Sent to {value} via {value2}; waiting for a delivery receipt.'**
  String statusSentToViaWaitingForEA766D(String value, String value2);

  /// App-owned controller status shown in the status line or an action notice. Delivery retry pending: {value}
  ///
  /// In en, this message translates to:
  /// **'Delivery retry pending: {value}'**
  String statusDeliveryRetryPending93EAA3(String value);

  /// App-owned controller status shown in the status line or an action notice. Group delivery retry pending: {value}
  ///
  /// In en, this message translates to:
  /// **'Group delivery retry pending: {value}'**
  String statusGroupDeliveryRetryPending691CA4(String value);

  /// App-owned controller status shown in the status line or an action notice. Relay {value} identity changed — verify with the operator.
  ///
  /// In en, this message translates to:
  /// **'Relay {value} identity changed — verify with the operator.'**
  String statusRelayIdentityChangedVerifyWith6F3689(String value);

  /// App-owned controller status shown in the status line or an action notice. Relay {value}:{value2} identity mismatch — verify with the operator.
  ///
  /// In en, this message translates to:
  /// **'Relay {value}:{value2} identity mismatch — verify with the operator.'**
  String statusRelayIdentityMismatchVerifyWith2D3B10(
    String value,
    String value2,
  );

  /// App-owned controller status shown in the status line or an action notice. The Matrix sign-in expired. Sign in again to use Matrix.
  ///
  /// In en, this message translates to:
  /// **'The Matrix sign-in expired. Sign in again to use Matrix.'**
  String get statusTheMatrixSignInExpired76ABA4;

  /// App-owned controller status shown in the status line or an action notice. Signed in to Matrix as {value}.
  ///
  /// In en, this message translates to:
  /// **'Signed in to Matrix as {value}.'**
  String statusSignedInToMatrixAs5103D2(String value);

  /// App-owned controller status shown in the status line or an action notice. Signed out of Matrix.
  ///
  /// In en, this message translates to:
  /// **'Signed out of Matrix.'**
  String get statusSignedOutOfMatrix1D1860;

  /// App-owned controller status shown in the status line or an action notice. {value}'s other devices have not heard from {value2} for a while: messages from it may not be theirs.
  ///
  /// In en, this message translates to:
  /// **'{value}\'s other devices have not heard from {value2} for a while: messages from it may not be theirs.'**
  String statusSOtherDevicesHaveNot07F30F(String value, String value2);

  /// App-owned controller status shown in the status line or an action notice. Received {value} item(s) instantly via local relay.
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{Received {value} item instantly via local relay.} other{Received {value} items instantly via local relay.}}'**
  String statusReceivedItemSInstantlyViaA7773B(int value);

  /// App-owned controller status shown in the status line or an action notice. Received {value} item(s) via local inbox.
  ///
  /// In en, this message translates to:
  /// **'{value, plural, one{Received {value} item via local inbox.} other{Received {value} items via local inbox.}}'**
  String statusReceivedItemSViaLocal71A104(int value);

  /// UI label or app-owned status atom: No new relay protocols detected.
  ///
  /// In en, this message translates to:
  /// **'No new relay protocols detected.'**
  String get statusNoNewProtocols;

  /// UI label or app-owned status atom: Route info exchange requested.
  ///
  /// In en, this message translates to:
  /// **'Route info exchange requested.'**
  String get statusRouteExchangeRequested;

  /// UI label or app-owned status atom: Route info exchange could not be sent yet.
  ///
  /// In en, this message translates to:
  /// **'Route info exchange could not be sent yet.'**
  String get statusRouteExchangePending;

  /// UI label or app-owned status atom: known routes
  ///
  /// In en, this message translates to:
  /// **'known routes'**
  String get statusKnownRoutes;

  /// UI label or app-owned status atom: reachable
  ///
  /// In en, this message translates to:
  /// **'reachable'**
  String get statusReachable;

  /// UI label or app-owned status atom: unreachable
  ///
  /// In en, this message translates to:
  /// **'unreachable'**
  String get statusUnreachable;

  /// UI label or app-owned status atom: unknown
  ///
  /// In en, this message translates to:
  /// **'unknown'**
  String get statusUnknown;

  /// UI label or app-owned status atom: stale
  ///
  /// In en, this message translates to:
  /// **'stale'**
  String get statusExpired;

  /// UI label or app-owned status atom: Connections
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get connectionsTitle;

  /// UI label or app-owned status atom: Which devices reach which, both ways or one way.
  ///
  /// In en, this message translates to:
  /// **'Which devices reach which, both ways or one way.'**
  String get connectionsDescription;

  /// UI label or app-owned status atom: udp://host:port forces UDP
  ///
  /// In en, this message translates to:
  /// **'udp://host:port forces UDP'**
  String get relayUdpHint;

  /// UI label or app-owned status atom: File actions
  ///
  /// In en, this message translates to:
  /// **'File actions'**
  String get deltaFileActions;

  /// UI label or app-owned status atom: Forward
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get deltaForward;

  /// UI label or app-owned status atom: Attach
  ///
  /// In en, this message translates to:
  /// **'Attach'**
  String get deltaAttach;

  /// UI label or app-owned status atom: Send voice message
  ///
  /// In en, this message translates to:
  /// **'Send voice message'**
  String get deltaSendVoice;

  /// UI label or app-owned status atom: Discard voice message
  ///
  /// In en, this message translates to:
  /// **'Discard voice message'**
  String get deltaDiscardVoice;

  /// UI label or app-owned status atom: Record voice message
  ///
  /// In en, this message translates to:
  /// **'Record voice message'**
  String get deltaRecordVoice;

  /// UI label or app-owned status atom: React
  ///
  /// In en, this message translates to:
  /// **'React'**
  String get deltaReact;

  /// UI label or app-owned status atom: Notes, files and forwards for yourself
  ///
  /// In en, this message translates to:
  /// **'Notes, files and forwards for yourself'**
  String get savedMessagesPreview;

  /// User-facing network chat label: {network} chats
  ///
  /// In en, this message translates to:
  /// **'{network} chats'**
  String networkChatsTitle(String network);

  /// User-facing network chat label: Encrypted Matrix chat
  ///
  /// In en, this message translates to:
  /// **'Encrypted Matrix chat'**
  String get networkEncryptedMatrixChat;

  /// User-facing network chat label: Matrix chat
  ///
  /// In en, this message translates to:
  /// **'Matrix chat'**
  String get networkMatrixChat;

  /// User-facing network chat label: Everyone in Bluetooth range
  ///
  /// In en, this message translates to:
  /// **'Everyone in Bluetooth range'**
  String get networkEveryoneBluetooth;

  /// User-facing network chat label: no routes advertised
  ///
  /// In en, this message translates to:
  /// **'no routes advertised'**
  String get inviteNoRoutes;

  /// Label for an app-owned state or display option: Waiting for a reachable path
  ///
  /// In en, this message translates to:
  /// **'Waiting for a reachable path'**
  String get deliveryPending;

  /// Label for an app-owned state or display option: Sent over LAN; waiting for delivery receipt
  ///
  /// In en, this message translates to:
  /// **'Sent over LAN; waiting for delivery receipt'**
  String get deliveryLocal;

  /// Label for an app-owned state or display option: Queued on a relay; waiting for delivery receipt
  ///
  /// In en, this message translates to:
  /// **'Queued on a relay; waiting for delivery receipt'**
  String get deliveryRelayed;

  /// Label for an app-owned state or display option: Delivered
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get deliveryDelivered;

  /// Label for an app-owned state or display option: Read
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get deliveryRead;

  /// Label for an app-owned state or display option: online
  ///
  /// In en, this message translates to:
  /// **'online'**
  String get reachabilityOnline;

  /// Label for an app-owned state or display option: seen recently
  ///
  /// In en, this message translates to:
  /// **'seen recently'**
  String get reachabilityRecent;

  /// Label for an app-owned state or display option: known
  ///
  /// In en, this message translates to:
  /// **'known'**
  String get reachabilityKnown;

  /// Label for an app-owned state or display option: Waiting for approval
  ///
  /// In en, this message translates to:
  /// **'Waiting for approval'**
  String get transferApproval;

  /// Label for an app-owned state or display option: Waiting for peer
  ///
  /// In en, this message translates to:
  /// **'Waiting for peer'**
  String get transferPeer;

  /// Label for an app-owned state or display option: LAN direct
  ///
  /// In en, this message translates to:
  /// **'LAN direct'**
  String get routeLanDirect;

  /// Label for an app-owned state or display option: Internet direct
  ///
  /// In en, this message translates to:
  /// **'Internet direct'**
  String get routeInternetDirect;

  /// Label for an app-owned state or display option: Iroh direct
  ///
  /// In en, this message translates to:
  /// **'Iroh direct'**
  String get routeIrohDirect;

  /// Label for an app-owned state or display option: Conest relay
  ///
  /// In en, this message translates to:
  /// **'Conest relay'**
  String get routeConestRelay;

  /// Label for an app-owned state or display option: Optical
  ///
  /// In en, this message translates to:
  /// **'Optical'**
  String get routeOptical;

  /// Label for an app-owned state or display option: Via a contact
  ///
  /// In en, this message translates to:
  /// **'Via a contact'**
  String get routeViaContact;

  /// Label for an app-owned state or display option: System
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get themeSystem;

  /// Label for an app-owned state or display option: Signature · Light
  ///
  /// In en, this message translates to:
  /// **'Signature · Light'**
  String get themeLight;

  /// Label for an app-owned state or display option: Signature · Dark
  ///
  /// In en, this message translates to:
  /// **'Signature · Dark'**
  String get themeDark;

  /// Label for an app-owned state or display option: Signature · Black (OLED)
  ///
  /// In en, this message translates to:
  /// **'Signature · Black (OLED)'**
  String get themeBlack;

  /// Label for an app-owned state or display option: Adaptive (wallpaper)
  ///
  /// In en, this message translates to:
  /// **'Adaptive (wallpaper)'**
  String get themeAdaptive;

  /// Label for an app-owned state or display option: Signal Cards
  ///
  /// In en, this message translates to:
  /// **'Signal Cards'**
  String get layoutSignalCards;

  /// Label for an app-owned state or display option: Station Feed
  ///
  /// In en, this message translates to:
  /// **'Station Feed'**
  String get layoutStationFeed;

  /// Label for an app-owned state or display option: Classic rows
  ///
  /// In en, this message translates to:
  /// **'Classic rows'**
  String get layoutClassic;

  /// Label for an app-owned state or display option: Peers as dashboard link tiles.
  ///
  /// In en, this message translates to:
  /// **'Peers as dashboard link tiles.'**
  String get layoutSignalDescription;

  /// Label for an app-owned state or display option: A chronological packet/activity log.
  ///
  /// In en, this message translates to:
  /// **'A chronological packet/activity log.'**
  String get layoutFeedDescription;

  /// Label for an app-owned state or display option: A compact one-line list.
  ///
  /// In en, this message translates to:
  /// **'A compact one-line list.'**
  String get layoutClassicDescription;

  /// Label for an app-owned state or display option: Conest's native dashboard sidebar.
  ///
  /// In en, this message translates to:
  /// **'Conest\'s native dashboard sidebar.'**
  String get shellSignatureDescription;

  /// Label for an app-owned state or display option: Discord-shaped: a rail of cells + conversations.
  ///
  /// In en, this message translates to:
  /// **'Discord-shaped: a rail of cells + conversations.'**
  String get shellGarrisonDescription;

  /// Label for an app-owned state or display option: Telegram-shaped: one clean conversation list.
  ///
  /// In en, this message translates to:
  /// **'Telegram-shaped: one clean conversation list.'**
  String get shellCourierDescription;

  /// Label for an app-owned state or display option: both ways
  ///
  /// In en, this message translates to:
  /// **'both ways'**
  String get connectionsBothWays;

  /// Label for an app-owned state or display option: only from them
  ///
  /// In en, this message translates to:
  /// **'only from them'**
  String get connectionsInbound;

  /// Label for an app-owned state or display option: failing
  ///
  /// In en, this message translates to:
  /// **'failing'**
  String get connectionsFailing;

  /// Label for an app-owned state or display option: no recent word
  ///
  /// In en, this message translates to:
  /// **'no recent word'**
  String get connectionsUnknown;

  /// Label for an app-owned state or display option: Connected · {time}
  ///
  /// In en, this message translates to:
  /// **'Connected · {time}'**
  String voiceConnected(String time);

  /// Label for an app-owned state or display option: Their clock is about {amount} ahead; times here are by this device.
  ///
  /// In en, this message translates to:
  /// **'Their clock is about {amount} ahead; times here are by this device.'**
  String messageClockAhead(String amount);

  /// Label for an app-owned state or display option: Their clock is about {amount} behind; times here are by this device.
  ///
  /// In en, this message translates to:
  /// **'Their clock is about {amount} behind; times here are by this device.'**
  String messageClockBehind(String amount);

  /// Label for an app-owned state or display option: Not recently confirmed: their other devices last counted this one as theirs on {date}.
  ///
  /// In en, this message translates to:
  /// **'Not recently confirmed: their other devices last counted this one as theirs on {date}.'**
  String messageNotRecentlyConfirmed(String date);

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Straight to the other device on your local network.'**
  String get routeLanDirectDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Through another device\'s relay node on your local network.'**
  String get routeLanRelayDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'The LAN lobby\'s shared mailbox; anyone on the network can read it.'**
  String get routeLanLobbyDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Straight to the other device\'s relay node over the internet.'**
  String get routeInternetDirectDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Peer to peer over Iroh, end-to-end encrypted.'**
  String get routeIrohDirectDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Through an Iroh relay server, which sees only encrypted traffic.'**
  String get routeIrohRelayDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Stored and forwarded by a Conest relay server, which sees only encrypted envelopes.'**
  String get routeConestRelayDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Carried by Matrix, still end-to-end encrypted by Conest; the homeserver sees who talks and when.'**
  String get routeMatrixDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Sent as an ordinary Matrix message; the homeserver can read it unless the room is encrypted.'**
  String get routePlainMatrixDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Carried by Nostr relays, still end-to-end encrypted by Conest; relays see the recipient and when, not the sender.'**
  String get routeNostrDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Carried by email, still end-to-end encrypted by Conest; the mail servers see both addresses and when.'**
  String get routeEmailDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Over Reticulum, by radio or a Reticulum network, end-to-end encrypted.'**
  String get routeReticulumDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Over a Meshtastic radio mesh, end-to-end encrypted.'**
  String get routeMeshtasticDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Over a MeshCore radio mesh, end-to-end encrypted.'**
  String get routeMeshCoreDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Over the Bluetooth mesh through nearby devices, end-to-end encrypted.'**
  String get routeBluetoothDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Between onion services over Tor; no one on the way sees who talks to whom.'**
  String get routeTorDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Passed on by a contact who could reach the other device; still end-to-end encrypted, the contact saw only who it was for and when.'**
  String get routeContactDescription;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'{route}: {ms} ms there and back'**
  String routeTestRoundTrip(String route, String ms);

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'{route}: left on the relay (answers once they fetch it)'**
  String routeTestStored(String route);

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'{route}: no answer'**
  String routeTestNoAnswer(String route);

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'{time} left'**
  String transferTimeLeft(String time);

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'queue #{position}'**
  String transferQueuePosition(String position);

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'tap to retry'**
  String get transferTapRetry;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Rerouting'**
  String get transferRerouting;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Lobby'**
  String get routeShortLobby;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get routeShortDirect;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Relay'**
  String get routeShortRelay;

  /// Presentation text for message route information or attachment transfer progress.
  ///
  /// In en, this message translates to:
  /// **'Via contact'**
  String get routeShortContact;

  /// Chat list preview for a locally saved unsent draft.
  ///
  /// In en, this message translates to:
  /// **'Draft: {text}'**
  String chatDraftPreview(String text);

  /// Route inspector note: automatic fallback is enabled.
  ///
  /// In en, this message translates to:
  /// **'automatic fallback ✓'**
  String get routeAutomaticFallback;

  /// App-owned fallback or state label within a release, call, contact, relay or file sharing screen.
  ///
  /// In en, this message translates to:
  /// **'nightly'**
  String get releaseNightly;

  /// App-owned fallback or state label within a release, call, contact, relay or file sharing screen.
  ///
  /// In en, this message translates to:
  /// **'stable'**
  String get releaseStable;

  /// App-owned fallback or state label within a release, call, contact, relay or file sharing screen.
  ///
  /// In en, this message translates to:
  /// **'Call active'**
  String get callActive;

  /// App-owned fallback or state label within a release, call, contact, relay or file sharing screen.
  ///
  /// In en, this message translates to:
  /// **'Call'**
  String get callGeneric;

  /// App-owned fallback or state label within a release, call, contact, relay or file sharing screen.
  ///
  /// In en, this message translates to:
  /// **'Not pinned'**
  String get contactNotPinned;

  /// App-owned fallback or state label within a release, call, contact, relay or file sharing screen.
  ///
  /// In en, this message translates to:
  /// **'A member'**
  String get groupUnknownMember;

  /// App-owned fallback or state label within a release, call, contact, relay or file sharing screen.
  ///
  /// In en, this message translates to:
  /// **'signed'**
  String get relaySourceSigned;

  /// App-owned fallback or state label within a release, call, contact, relay or file sharing screen.
  ///
  /// In en, this message translates to:
  /// **'unsigned'**
  String get relaySourceUnsigned;

  /// App-owned fallback or state label within a release, call, contact, relay or file sharing screen.
  ///
  /// In en, this message translates to:
  /// **'fingerprint unavailable'**
  String get beamFingerprintUnavailable;

  /// App-owned fallback or state label within a release, call, contact, relay or file sharing screen.
  ///
  /// In en, this message translates to:
  /// **'Its location, camera, author and date details will be sent with it.'**
  String get fileOriginalMetadataWarning;

  /// Delivery progress after a route name in message details; lowercase in English.
  ///
  /// In en, this message translates to:
  /// **'sent'**
  String get routeMarkSent;

  /// Delivery progress after a route name in message details; lowercase in English.
  ///
  /// In en, this message translates to:
  /// **'waiting on the relay'**
  String get routeMarkStored;

  /// Delivery progress after a route name in message details; lowercase in English.
  ///
  /// In en, this message translates to:
  /// **'reached their device'**
  String get routeMarkReached;

  /// Delivery progress after a route name in message details; lowercase in English.
  ///
  /// In en, this message translates to:
  /// **'delivered'**
  String get routeMarkDelivered;

  /// Delivery progress after a route name in message details; lowercase in English.
  ///
  /// In en, this message translates to:
  /// **'received'**
  String get routeMarkReceived;

  /// Settings → Relays: the field taking a relay's host, URL, or the conest-relay:// link its installer prints
  ///
  /// In en, this message translates to:
  /// **'Relay host, URL or link'**
  String get relayHostOrLinkLabel;

  /// Hint under the relay field: the link the relay installer prints (keep conest-relay:// as is)
  ///
  /// In en, this message translates to:
  /// **'conest-relay://… from its installer'**
  String get relayLinkHint;

  /// Shown in place of a part of the screen that failed to draw (release builds)
  ///
  /// In en, this message translates to:
  /// **'Something went wrong here.'**
  String get brokenPartNotice;

  /// Banner at start after Conest closed unexpectedly; nothing is sent anywhere
  ///
  /// In en, this message translates to:
  /// **'Conest closed unexpectedly last time. The details stay on this device; you can copy them into a bug report.'**
  String get crashNoticeBody;

  /// Banner button: show the crash details
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get crashNoticeDetails;

  /// Banner button: hide the crash notice for good
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get crashNoticeDismiss;

  /// Title of the dialog with the crash details
  ///
  /// In en, this message translates to:
  /// **'What happened'**
  String get crashReportTitle;

  /// Crash details dialog: copy them
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get crashReportCopy;

  /// Crash details dialog: close it
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get crashReportClose;

  /// Connections screen: heading of the list of networks (Wi-Fi, mobile…) this device remembers
  ///
  /// In en, this message translates to:
  /// **'Networks this device has been on'**
  String get connectionsNetworks;

  /// Connections screen: the network in use right now
  ///
  /// In en, this message translates to:
  /// **'In use now'**
  String get connectionsNetworkNow;

  /// Connections screen: when a remembered network was last in use
  ///
  /// In en, this message translates to:
  /// **'Last seen {date}'**
  String connectionsNetworkLastSeen(String date);

  /// Connections screen: a route (relay, Iroh, Nostr…) that worked on this network
  ///
  /// In en, this message translates to:
  /// **'works'**
  String get connectionsRouteWorks;

  /// Connections screen: a route this network seems to block
  ///
  /// In en, this message translates to:
  /// **'blocked on this network'**
  String get connectionsRouteBlocked;

  /// Connections screen: a route that failed lately on this network
  ///
  /// In en, this message translates to:
  /// **'failing'**
  String get connectionsRouteFailing;

  /// Connections screen: how old another device's report about a link is
  ///
  /// In en, this message translates to:
  /// **'as of {when}'**
  String connectionsAsOf(String when);

  /// Bluetooth mesh settings: it runs, but the adapter reports a problem (shown below)
  ///
  /// In en, this message translates to:
  /// **'Bluetooth mesh needs attention'**
  String get bluetoothMeshNeedsAttention;

  /// Forward dialog title for several selected messages
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Forward 1 message} other{Forward {count} messages}}'**
  String forwardSelectedTitle(int count);

  /// After forwarding several messages
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 message forwarded} other{{count} messages forwarded}}'**
  String forwardedSummary(int count);

  /// Selected files that could not be forwarded because they have not been downloaded
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 file is not on this device yet and was left out} other{{count} files are not on this device yet and were left out}}'**
  String forwardSkipped(int count);

  /// Tor settings: shown when Tor seems blocked and no bridges are set.
  ///
  /// In en, this message translates to:
  /// **'Tor looks blocked on this network. Bridges get around that, but the public ones are often blocked too: get your own (below).'**
  String get torBlockedHint;

  /// Tor settings: title of the help on getting bridges.
  ///
  /// In en, this message translates to:
  /// **'How to get your own bridges'**
  String get torGetBridgesTitle;

  /// Tor settings: introduction to the ways of getting bridges.
  ///
  /// In en, this message translates to:
  /// **'The Tor Project hands out bridges in these ways. Ask for obfs4 or webtunnel bridges, then paste the lines above.'**
  String get torGetBridgesIntro;

  /// Tor settings: get bridges from the Tor Project website (keep the address as is).
  ///
  /// In en, this message translates to:
  /// **'Website: bridges.torproject.org'**
  String get torGetBridgesWeb;

  /// Tor settings: get bridges from the Tor Project's Telegram bot (keep the bot name as is).
  ///
  /// In en, this message translates to:
  /// **'Telegram: write to @GetBridgesBot'**
  String get torGetBridgesTelegram;

  /// Tor settings: get bridges by email from the Tor Project (keep the addresses as is).
  ///
  /// In en, this message translates to:
  /// **'Email: write to bridges@torproject.org from a Gmail or Riseup address'**
  String get torGetBridgesEmail;

  /// Tor settings: getting a bridge from a trusted person.
  ///
  /// In en, this message translates to:
  /// **'Or ask someone you trust who uses Tor to share a bridge line with you.'**
  String get torGetBridgesFriend;

  /// Onboarding transports step: title.
  ///
  /// In en, this message translates to:
  /// **'Reach people beyond this network'**
  String get transportsTitle;

  /// Onboarding transports step: why internet transports matter.
  ///
  /// In en, this message translates to:
  /// **'Devices on this network reach you directly. For anyone else, Conest needs at least one way over the internet, and three are better, since networks block some of them. Here is what works on this network now.'**
  String get transportsIntro;

  /// Onboarding transports step: shown while probing.
  ///
  /// In en, this message translates to:
  /// **'Checking what works on this network…'**
  String get transportsChecking;

  /// Onboarding transports step: how many internet transports will be set up.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{None set up yet: 1 needed, 3 recommended} one{{count} set up: 3 recommended} other{{count} set up: 3 recommended}}'**
  String transportsCount(int count);

  /// Onboarding transports step: already working.
  ///
  /// In en, this message translates to:
  /// **'Working'**
  String get transportStateOn;

  /// Onboarding transports step: answers here, can be switched on now.
  ///
  /// In en, this message translates to:
  /// **'Works here'**
  String get transportStateWorks;

  /// Onboarding transports step: does not answer on this network.
  ///
  /// In en, this message translates to:
  /// **'Blocked here'**
  String get transportStateBlocked;

  /// Onboarding transports step: needs an address, account or bridges, in Settings.
  ///
  /// In en, this message translates to:
  /// **'Set up later in Settings'**
  String get transportStateNeedsSetup;

  /// Onboarding transports step: cost note for the email transport.
  ///
  /// In en, this message translates to:
  /// **'Checks a mailbox: a little more data and battery.'**
  String get transportsEmailCost;

  /// Onboarding transports step: warning title when finishing with no internet transport.
  ///
  /// In en, this message translates to:
  /// **'Only nearby devices could reach you'**
  String get transportsSkipTitle;

  /// Onboarding transports step: warning text when finishing with no internet transport.
  ///
  /// In en, this message translates to:
  /// **'Without a way over the internet, only devices on this network can reach you, and you only them. You can set one up later in Settings, under Connectivity.'**
  String get transportsSkipBody;

  /// Onboarding transports step: continue without an internet transport.
  ///
  /// In en, this message translates to:
  /// **'Continue anyway'**
  String get transportsSkipConfirm;

  /// Chat list banner when no internet transport works.
  ///
  /// In en, this message translates to:
  /// **'Only devices on this network can reach you now. Set up a way over the internet.'**
  String get transportsBanner;

  /// Chat list banner: opens Settings to set up an internet transport.
  ///
  /// In en, this message translates to:
  /// **'Set up'**
  String get transportsBannerAction;

  /// Chat list banner: hide it for now.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get transportsBannerDismiss;

  /// Onboarding transports step: a transport could not be switched on.
  ///
  /// In en, this message translates to:
  /// **'{name} could not be switched on: {error}'**
  String transportsTurnOnFailed(String name, String error);

  /// Onboarding transports step: link to the user guide page on choosing routes.
  ///
  /// In en, this message translates to:
  /// **'How to choose'**
  String get transportsHowToChoose;

  /// Settings: opens the online user guide.
  ///
  /// In en, this message translates to:
  /// **'User guide'**
  String get settingsUserGuide;

  /// Settings switch: Enter sends a message (Shift+Enter: new line).
  ///
  /// In en, this message translates to:
  /// **'Enter sends the message'**
  String get settingsEnterSends;

  /// Settings: explains the Enter-sends switch.
  ///
  /// In en, this message translates to:
  /// **'Shift+Enter starts a new line. Off: Enter starts a new line and Ctrl+Enter sends.'**
  String get settingsEnterSendsHelp;

  /// Message menu: copy the text selected in the message.
  ///
  /// In en, this message translates to:
  /// **'Copy selected text'**
  String get menuCopySelection;

  /// Dialog title before opening a link whose host has non-ASCII letters.
  ///
  /// In en, this message translates to:
  /// **'Open this link?'**
  String get linkLookalikeTitle;

  /// Dialog body: the link host may imitate another site.
  ///
  /// In en, this message translates to:
  /// **'The address {host} uses letters from other alphabets. It may imitate a site you know.'**
  String linkLookalikeBody(String host);

  /// Button: open the link.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get linkOpen;

  /// Button: forget a carrier account (address, keys).
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get carrierRemove;

  /// Dialog title before forgetting a carrier account.
  ///
  /// In en, this message translates to:
  /// **'Remove {name}?'**
  String carrierRemoveTitle(String name);

  /// Dialog body: what removing a carrier account means.
  ///
  /// In en, this message translates to:
  /// **'Contacts will no longer reach you over {name}, and what this device keeps for it is forgotten. Setting it up again gives you a new address. To stop it for a while, turn its switch off instead.'**
  String carrierRemoveBody(String name);

  /// A carrier switched off by the user, its account kept.
  ///
  /// In en, this message translates to:
  /// **'Paused: kept, not used. Turn on to use it again.'**
  String get carrierPaused;

  /// Button: edit the email account the email carrier uses.
  ///
  /// In en, this message translates to:
  /// **'Change account'**
  String get emailChangeAccount;

  /// Button: move the email carrier to another chatmail server (a new address).
  ///
  /// In en, this message translates to:
  /// **'Use another server'**
  String get emailOtherServer;

  /// Button: save changes.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get actionSave;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
    'ar',
    'en',
    'fa',
    'id',
    'ru',
    'zh',
  ].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
    case 'en':
      return AppLocalizationsEn();
    case 'fa':
      return AppLocalizationsFa();
    case 'id':
      return AppLocalizationsId();
    case 'ru':
      return AppLocalizationsRu();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}

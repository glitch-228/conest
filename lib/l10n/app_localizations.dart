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

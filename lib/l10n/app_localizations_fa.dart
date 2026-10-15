// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Persian (`fa`).
class AppLocalizationsFa extends AppLocalizations {
  AppLocalizationsFa([String locale = 'fa']) : super(locale);

  @override
  String get modeChooseTitle => 'Conest چطور نمایش داده شود؟';

  @override
  String get modeChangeLater =>
      'هر زمان در تنظیمات می‌توانید این را تغییر دهید.';

  @override
  String get modeSimple => 'ساده';

  @override
  String get modeStandard => 'استاندارد';

  @override
  String get modeAdvanced => 'پیشرفته';

  @override
  String get modeSimpleDescription =>
      'یک فهرست گفتگو، متن بزرگ و فقط تنظیماتی که لازم دارید. پیام‌ها نشان می‌دهند ارسال، تحویل و خوانده شده‌اند.';

  @override
  String get modeStandardDescription =>
      'مثل پیام‌رسان‌هایی که می‌شناسید: گفتگوها، گروه‌ها، تماس‌ها و فایل‌ها با تیک‌های تحویل و خواندن.';

  @override
  String get modeAdvancedDescription =>
      'همه‌چیز، از جمله مسیرهایی که هر پیام طی کرده، همه راه‌های ارتباط و عیب‌یابی.';

  @override
  String get actionContinue => 'ادامه';

  @override
  String get actionStart => 'شروع';

  @override
  String get actionBack => 'بازگشت';

  @override
  String get actionClose => 'بستن';

  @override
  String get routesTitle => 'Conest چطور به دیگران می‌رسد';

  @override
  String get routesDirect =>
      'Conest پیام‌ها را مستقیم و بدون هیچ سروری در میان، از راه شبکه شما و اینترنت به مخاطبانتان می‌فرستد. این الان روشن است.';

  @override
  String get routesOthers =>
      'وقتی این راه‌ها مسدود یا در دسترس نباشند، Conest می‌تواند از رله‌ها، Tor، Nostr، ایمیل، Matrix، شبکه بلوتوث گوشی‌های نزدیک یا رادیوهای LoRa هم استفاده کند. هر کدام خاموش است تا وقتی آن را در «تنظیمات ← اتصال» روشن کنید.';

  @override
  String get routesAdvanced =>
      'در حالت پیشرفته هر پیام مسیرهایی را که طی کرده نشان می‌دهد و در نمایه مخاطب می‌توان همه مسیرها را آزمود.';

  @override
  String get tabChats => 'گفتگوها';

  @override
  String get tabCalls => 'تماس‌ها';

  @override
  String get tabSettings => 'تنظیمات';

  @override
  String get callsEmpty =>
      'هنوز تماسی نیست. یک گفتگو را باز کنید و دکمه تماس را بزنید.';

  @override
  String get callOutgoing => 'خروجی';

  @override
  String get callIncoming => 'ورودی';

  @override
  String get callMissed => 'بی‌پاسخ';

  @override
  String get callDeclined => 'رد شده';

  @override
  String get callCancelled => 'لغو شده';

  @override
  String get callFailed => 'ناموفق';

  @override
  String callDuration(int minutes, int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes دقیقه و $seconds ثانیه',
      zero: '$seconds ثانیه',
    );
    return '$_temp0';
  }

  @override
  String get unknownContact => 'مخاطب ناشناس';

  @override
  String get messageDetails => 'جزئیات پیام';

  @override
  String messageSentAt(String time) {
    return 'ارسال: $time';
  }

  @override
  String messageReceivedAt(String time) {
    return 'دریافت: $time';
  }

  @override
  String messageDeliveredAt(String time) {
    return 'تحویل: $time';
  }

  @override
  String messageReadAt(String time) {
    return 'خوانده شد: $time';
  }

  @override
  String memberDeliveredAt(String time) {
    return 'تحویل $time';
  }

  @override
  String memberReadAt(String time) {
    return 'خوانده شد $time';
  }

  @override
  String get messageRoutes => 'مسیرها';

  @override
  String get messageArrivedBy => 'رسیده از راه';

  @override
  String get settingsShowAll => 'نمایش همه تنظیمات';

  @override
  String get settingsLanguage => 'زبان';

  @override
  String get settingsLanguageSystem => 'مانند دستگاه';

  @override
  String get settingsAiTranslated =>
      'این ترجمه با هوش مصنوعی انجام شده و ممکن است اشتباه داشته باشد. می‌توانید در Weblate به بهتر شدن آن کمک کنید.';

  @override
  String get menuReply => 'پاسخ';

  @override
  String get menuReact => 'واکنش 👍';

  @override
  String get menuForward => 'بازارسال';

  @override
  String get menuCopyMessage => 'کپی پیام';

  @override
  String get menuDownloadAttachment => 'دانلود پیوست';

  @override
  String get menuSaveAttachment => 'ذخیره پیوست';

  @override
  String get menuCopyImage => 'کپی تصویر';

  @override
  String get menuFreeUpSpace => 'آزادسازی فضا';

  @override
  String get menuCancelTransfer => 'لغو انتقال';

  @override
  String get menuRetryTransfer => 'تلاش دوباره انتقال';

  @override
  String get menuForwardAttachment => 'بازارسال پیوست';

  @override
  String get menuCancelSending => 'لغو ارسال';

  @override
  String get menuEditMessage => 'ویرایش پیام';

  @override
  String get menuDeleteMessage => 'حذف پیام';

  @override
  String get menuEdit => 'ویرایش';

  @override
  String get menuDelete => 'حذف';

  @override
  String get composerAttach => 'پیوست فایل یا تصویر';

  @override
  String get composerSchedule => 'زمان‌بندی پیام';

  @override
  String get composerSend => 'ارسال';

  @override
  String get searchChatsAndMessages => 'جستجو در گفتگوها و پیام‌ها';

  @override
  String get searchChats => 'جستجوی گفتگوها';

  @override
  String get searchContacts => 'جستجوی مخاطبان';

  @override
  String get archivedChats => 'گفتگوهای بایگانی‌شده';

  @override
  String get actionSearch => 'جستجو';

  @override
  String get settingsPersonal => 'شخصی';

  @override
  String get settingsStorage => 'فضای ذخیره‌سازی';

  @override
  String get settingsConnectivity => 'اتصال';

  @override
  String get settingsRelays => 'رله‌ها';

  @override
  String get settingsUpdates => 'به‌روزرسانی‌ها';

  @override
  String get settingsAccount => 'حساب';

  @override
  String get onbNameRequired =>
      'یک نام نمایشی و یک درگاه محلی معتبر وارد کنید.';

  @override
  String get onbRelayPortInvalid =>
      'اگر نشانی رله اینترنتی را وارد کرده‌اید، درگاه آن هم باید معتبر باشد.';

  @override
  String get onbRelayDesktop =>
      'رایانه‌ها به‌طور پیش‌فرض رله می‌کنند و مسیرهای شبکه محلی را خودکار اعلام می‌کنند.';

  @override
  String get onbRelayAndroid =>
      'در اندروید حالت رله خاموش است. فقط وقتی می‌خواهید این دستگاه رله کند آن را در تنظیمات روشن کنید.';

  @override
  String get onbRelayOther =>
      'اگر می‌خواهید این دستگاه در جابه‌جایی پیام‌ها کمک کند، حالت رله را در تنظیمات روشن کنید.';

  @override
  String get onbTagline =>
      'مستقیم و از راه شبکه خودتان یا اینترنت به مخاطبان برسید، با رمزگذاری سرتاسری و محرمانگی پیشرو. وقتی راه‌های معمول مسدود باشند، Conest از رله‌ها، Matrix، Nostr، ایمیل، Tor، رادیوهای LoRa یا شبکه بلوتوث گوشی‌های نزدیک استفاده می‌کند.';

  @override
  String get onbFeatureForwardSecret => 'گفتگو با محرمانگی پیشرو';

  @override
  String get onbFeatureDirect => 'مستقیم از شبکه محلی و اینترنت';

  @override
  String get onbFeatureFallbacks => 'راه‌های جایگزین Tor، مش و رادیو';

  @override
  String get onbFeatureMatrix => 'کلاینت Matrix هم هست';

  @override
  String get onbCreateTitle => 'نخستین دستگاه خود را بسازید';

  @override
  String get onbCreateHelp =>
      'فقط یک نام نمایشی لازم است. درگاه محلی برای تحویل در شبکه محلی و جفت‌شدن با عبارت رمز است. رله اینترنتی اختیاری است: بدون آن هم از راه اینترنت به مخاطبان می‌رسید. مسیرهای بیشتر را بعداً در «تنظیمات ← اتصال» روشن کنید.';

  @override
  String get onbDisplayName => 'نام نمایشی';

  @override
  String get onbLocalPort => 'درگاه رله محلی / LAN';

  @override
  String get onbRelayHost => 'نشانی رله اینترنتی (اختیاری)';

  @override
  String get onbRelayPort => 'درگاه رله اینترنتی';

  @override
  String get onbCreateButton => 'ساخت دستگاه رمزگذاری‌شده';

  @override
  String get onbMatrixInstead => 'استفاده به‌عنوان کلاینت Matrix';

  @override
  String get onbMatrixHelp =>
      'فقط گفتگوهای Matrix، بدون هویت Conest. بعداً می‌توانید در «تنظیمات ← اتصال ← حالت برنامه» به «هر دو» (Conest و Matrix کنار هم) بروید.';

  @override
  String get groupCreate => 'ساخت گروه';

  @override
  String get groupTitle => 'نام گروه';

  @override
  String get roleMember => 'عضو';

  @override
  String get roleModerator => 'ناظر';

  @override
  String get roleAdmin => 'مدیر';

  @override
  String get actionCancel => 'لغو';

  @override
  String get actionCreate => 'ساختن';

  @override
  String get actionCreating => 'در حال ساخت…';

  @override
  String get contactAdd => 'افزودن مخاطب';

  @override
  String get contactAlias => 'نام مستعار';

  @override
  String get contactInvitePayload => 'متن دعوت یا QR اسکن‌شده';

  @override
  String get contactScanQr => 'اسکن QR';

  @override
  String get contactCodephrase => 'فقط عبارت رمز';

  @override
  String get contactTrustPayload => 'اعتماد به QR / دعوت';

  @override
  String get contactFindCodephrase => 'یافتن با عبارت رمز';

  @override
  String get contactExchangeFailed => 'تبادل خودکار ناموفق بود';

  @override
  String contactExchangeFailedBody(String alias) {
    return '$alias را افزودید، اما دعوت شما به‌طور خودکار برگشت داده نشد. از طرف مقابل بخواهید دعوت شما را اسکن یا وارد کند، یا همین حالا این مخاطب یک‌طرفه را لغو و حذف کنید.';
  }

  @override
  String get actionAbort => 'لغو کردن';

  @override
  String get contactKeep => 'نگه‌داشتن مخاطب';

  @override
  String get uiPassphrase89950C => 'Passphrase';

  @override
  String get uiConfirmPassphraseEBAAC0 => 'Confirm passphrase';

  @override
  String get uiUnlock1526A1 => 'Unlock';

  @override
  String get uiUpdateAvailable67FD3A => 'Update Available';

  @override
  String get uiLater56E2F5 => 'Later';

  @override
  String get uiHostAutoDetectsTCPUDP663D30 =>
      'host auto-detects TCP/UDP; udp://host:port forces UDP';

  @override
  String get uiVerificationRequestDA06F9 => 'Verification request';

  @override
  String get uiIgnore98F55D => 'Ignore';

  @override
  String get uiVerifyDDA6AC => 'Verify';

  @override
  String uiCouldNotReadValueValue695755(String value, String value2) {
    return 'Could not read $value: $value2';
  }

  @override
  String uiCouldNotShareValueValue7BA3A3(String value, String value2) {
    return 'Could not share $value: $value2';
  }

  @override
  String uiCouldNotSaveSidebarWidthB4DACB(String value) {
    return 'Could not save sidebar width: $value';
  }

  @override
  String get uiNoAudioOutputDevicesWere17E473 =>
      'No audio output devices were found.';

  @override
  String get uiCallAudioOutput0C276F => 'Call audio output';

  @override
  String uiCallAudioRoutedToValueFFFBE8(String value) {
    return 'Call audio routed to $value.';
  }

  @override
  String uiCouldNotChangeCallAudio6CE7B1(String value) {
    return 'Could not change call audio output: $value';
  }

  @override
  String uiCouldNotOpenInviteValue6C4D06(String value) {
    return 'Could not open invite: $value';
  }

  @override
  String uiCouldNotSendAttachmentValueEFF771(String value) {
    return 'Could not send attachment: $value';
  }

  @override
  String uiCouldNotSendMessageValue042C4F(String value) {
    return 'Could not send message: $value';
  }

  @override
  String get uiSendFromOriginalFFF29A => 'Send from original';

  @override
  String uiCouldNotSendGroupMessageB6C7D1(String value) {
    return 'Could not send group message: $value';
  }

  @override
  String uiCouldNotSendLANLobby8E7487(String value) {
    return 'Could not send LAN lobby message: $value';
  }

  @override
  String uiCouldNotStageValuePathless514094(String value) {
    return 'Could not stage $value: pathless drops are limited to 8 MB to protect memory.';
  }

  @override
  String get uiSelectAGroupBeforeDropping9DAB4C =>
      'Select a group before dropping files.';

  @override
  String uiValueLocalFilePathUnavailable217177(String value) {
    return '$value: local file path unavailable.';
  }

  @override
  String uiValueSentWithoutIt7E0635(String value) {
    return '$value Sent without it.';
  }

  @override
  String get uiGroupFileScheduledB1DC66 => 'Group file scheduled.';

  @override
  String uiCouldNotScheduleValueValue25CED3(String value, String value2) {
    return 'Could not schedule $value: $value2';
  }

  @override
  String uiCouldNotOpenFilePicker8FF0C0(String value) {
    return 'Could not open file picker: $value';
  }

  @override
  String uiValuePickerReturnedNoData4670CA(String value) {
    return '$value: picker returned no data.';
  }

  @override
  String uiOnlyTheFirstValueFiles45FC47(String value, String value2) {
    return 'Only the first $value files will be staged (got $value2).';
  }

  @override
  String uiValueSkippedValueMBExceeds487B2A(String value, String value2) {
    return '$value skipped: $value2 MB exceeds the $value MB cap.';
  }

  @override
  String get uiTransfers812412 => 'Transfers';

  @override
  String uiValue75CED7(String value) {
    return '$value';
  }

  @override
  String get uiPreparingCallE86D6C => 'Preparing call…';

  @override
  String get uiCallingACD4A6 => 'Calling…';

  @override
  String get uiIncomingVoiceCallF68FD3 => 'Incoming voice call';

  @override
  String get uiConnectingFD3E79 => 'Connecting…';

  @override
  String get uiReconnecting8A8B95 => 'Reconnecting…';

  @override
  String get uiCallEnded9933A4 => 'Call ended';

  @override
  String uiVoiceCallValue06FE1F(String value) {
    return 'Voice call: $value';
  }

  @override
  String get uiMinimizeCall6CB0F0 => 'Minimize call';

  @override
  String get uiAcceptBB54DB => 'Accept';

  @override
  String get uiReject2B03B5 => 'Reject';

  @override
  String get uiNoiseSuppression71DE3C => 'Noise suppression';

  @override
  String get uiAudioOutput2B89CC => 'Audio output';

  @override
  String get uiDoneE9B450 => 'Done';

  @override
  String get uiHangUp66BE99 => 'Hang up';

  @override
  String get uiCloseDetails433DA6 => 'Close details';

  @override
  String get uiOpenFullProfile35063C => 'Open full profile';

  @override
  String get uiOpenGroupSettings0B568E => 'Open group settings';

  @override
  String get uiNewFolderA71199 => 'New folder';

  @override
  String get uiFolderNameB2CE02 => 'Folder name';

  @override
  String get uiMoveEarlier07DD6F => 'Move earlier';

  @override
  String get uiMoveLaterBB4C84 => 'Move later';

  @override
  String get uiSaveEFC007 => 'Save';

  @override
  String get uiAddToFolderBFAD96 => 'Add to folder';

  @override
  String get uiNewMessage1ED2E7 => 'New message';

  @override
  String get uiBackToChats8DE6F6 => 'Back to chats';

  @override
  String get uiNavigationMenu6609F1 => 'Navigation menu';

  @override
  String get uiAllChats398E5B => 'All chats';

  @override
  String get uiSearchAllChatsC825C8 => 'Search all chats';

  @override
  String get uiClearSearch67300D => 'Clear search';

  @override
  String get uiContactRequests082691 => 'Contact requests';

  @override
  String get uiReviewPeopleWhoWantTo24A8CB =>
      'Review people who want to connect';

  @override
  String get uiNoChatsFoundC6BD82 => 'No chats found';

  @override
  String get uiNoArchivedChatsEAE7F0 => 'No archived chats';

  @override
  String get uiNoMatrixChatsYet23B023 => 'No Matrix chats yet';

  @override
  String get uiNewGroupF9850C => 'New group';

  @override
  String get uiAddWithConestBeam19D1E2 => 'Add with Conest Beam';

  @override
  String get uiDirectMessagesE7596A => 'Direct messages';

  @override
  String get uiConestBeamE98B77 => 'Conest Beam';

  @override
  String get uiMyInviteF80A7A => 'My invite';

  @override
  String get uiGroupDetailsDF844A => 'Group details';

  @override
  String get uiDebugBD604D => 'Debug';

  @override
  String get uiAdd61CC55 => 'Add';

  @override
  String get uiPollRoutesNow22318F => 'Poll routes now';

  @override
  String get uiContactProfile1B3A0E => 'Contact profile';

  @override
  String get uiHistoryForNewMembersF419F2 => 'History for new members';

  @override
  String get uiChooseHowToWindDownF7399D =>
      'Choose how to wind down this group. Transferring ownership keeps the group alive under a new owner and demotes you to admin. Deleting for everyone removes the group from every member\'s list and cannot be undone.';

  @override
  String get uiTransferOwnershipA563C9 => 'Transfer ownership…';

  @override
  String get uiDeleteForEveryoneE055A8 => 'Delete for everyone';

  @override
  String get uiNoOtherActiveMembersToF9DE12 =>
      'No other active members to transfer ownership to.';

  @override
  String get uiTransferOwnershipA6819E => 'Transfer ownership';

  @override
  String get uiTransferCBB4CC => 'Transfer';

  @override
  String uiOwnershipTransferredToValue14A10D(String value) {
    return 'Ownership transferred to $value.';
  }

  @override
  String get uiEveryMemberWillBeRemoved75A3FC =>
      'Every member will be removed from the group and the group will be marked left in each member\'s list. Local message history is not deleted automatically — each member can clear it via Remove from list. This cannot be undone.';

  @override
  String get uiRemoveThisGroup38C4E8 => 'Remove this group?';

  @override
  String get uiRemoveThisGroupFromYourDA7898 =>
      'Remove this group from your list? This deletes the local message history. Other members will not be notified — they already see you as having left.';

  @override
  String get uiRemoveE96390 => 'Remove';

  @override
  String get uiChangeRole2B9BFD => 'Change role';

  @override
  String get uiRemoveMember1C31D1 => 'Remove member';

  @override
  String get uiChooseWhatFutureMembersCanC38992 =>
      'Choose what future members can catch up on';

  @override
  String get uiAddMember170AD0 => 'Add member';

  @override
  String get uiDeleteGroup043336 => 'Delete group…';

  @override
  String get uiLeave7E3520 => 'Leave';

  @override
  String get uiRemoveFromList23A976 => 'Remove from list';

  @override
  String get uiForwardMessage482959 => 'Forward message';

  @override
  String get uiSavedMessagesC0FA7E => 'Saved messages';

  @override
  String get uiThisAttachmentIsNotAvailableFE641A =>
      'This attachment is not available locally yet.';

  @override
  String get uiDownloadThisFileBeforeForwarding60D7B5 =>
      'Download this file before forwarding it.';

  @override
  String get uiSearchMessagesABEA65 => 'Search messages';

  @override
  String get uiStartVoiceCallExperimental6DE320 =>
      'Start voice call (experimental)';

  @override
  String get uiChatOptionsA40D0F => 'Chat options';

  @override
  String get uiPausePreview805180 => 'Pause preview';

  @override
  String get uiPlayPreview47BB44 => 'Play preview';

  @override
  String get uiUnmutePreview12A31A => 'Unmute preview';

  @override
  String get uiMutePreviewCE44BD => 'Mute preview';

  @override
  String get uiPauseVoiceMessageECD12D => 'Pause voice message';

  @override
  String get uiPlayVoiceMessageB16684 => 'Play voice message';

  @override
  String get uiPlaybackSpeed6FF42B => 'Playback speed';

  @override
  String get uiStopRecordingEE0D9D => 'Stop recording';

  @override
  String get uiDeleteRecording8B58CE => 'Delete recording';

  @override
  String uiCouldNotLoadOlderGroup1A192E(String value) {
    return 'Could not load older group history: $value';
  }

  @override
  String uiMessageScheduledForValueD2D788(String value) {
    return 'Message scheduled for $value.';
  }

  @override
  String get uiNewPoll6D62BD => 'New poll';

  @override
  String get uiQuestion002FF5 => 'Question';

  @override
  String get uiOptionsOnePerLine62FF3D => 'Options (one per line)';

  @override
  String get uiDeleteMessageD536CF => 'Delete message?';

  @override
  String get uiDeleteSelectedMessages190A5F => 'Delete selected messages?';

  @override
  String uiDeleteFailedForOneMessage26C302(String value) {
    return 'Delete failed for one message: $value';
  }

  @override
  String get uiNothingToCopyFromTheEC27E3 =>
      'Nothing to copy from the selected messages.';

  @override
  String uiCopiedValueMessageSC97E6E(String value) {
    return 'Copied $value message(s).';
  }

  @override
  String get uiNoSelectedAttachmentIsReady536B54 =>
      'No selected attachment is ready yet — still transferring.';

  @override
  String get uiCopiedMessageText9DC18F => 'Copied message text.';

  @override
  String get uiTheGroupFileIsNotF8A236 =>
      'The group file is not available locally.';

  @override
  String uiSavedValue0463E5(String value) {
    return 'Saved $value.';
  }

  @override
  String uiCouldNotSaveValueValue178005(String value, String value2) {
    return 'Could not save $value: $value2';
  }

  @override
  String get uiTheAndroidFileSaverIsDF910B =>
      'The Android file saver is unavailable.';

  @override
  String get uiOpeningFilesIsUnavailableOnC6ADA2 =>
      'Opening files is unavailable on this platform.';

  @override
  String uiCouldNotOpenValueValue283326(String value, String value2) {
    return 'Could not open $value: $value2';
  }

  @override
  String get uiYou905CB3 => 'You';

  @override
  String get uiMessage68F414 => 'Message';

  @override
  String get uiMessageActions949184 => 'Message actions';

  @override
  String get uiTheAttachmentIsStillDownloadingF77317 =>
      'The attachment is still downloading.';

  @override
  String get uiShareOrScheduleAGroup2989F0 => 'Share or schedule a group file';

  @override
  String get uiRecordingBelongsToAnotherConversation87E802 =>
      'Recording belongs to another conversation';

  @override
  String get uiFinishTheVoicePreviewIn142571 =>
      'Finish the voice preview in its original chat';

  @override
  String get uiReviewUnsentVoiceMessage24931C => 'Review unsent voice message';

  @override
  String get uiCancelMicrophoneStartup9E9F8A => 'Cancel microphone startup';

  @override
  String get uiReleaseToDiscardRecording4C5C71 =>
      'Release to discard recording';

  @override
  String get uiRecordingLockedTapToFinish40CD88 =>
      'Recording locked · tap to finish';

  @override
  String get uiReleaseToStopSlideLeft4686F1 =>
      'Release to stop · slide left to cancel · slide up to lock';

  @override
  String get uiHoldToRecordAGroupC11B32 =>
      'Hold to record a group voice message';

  @override
  String get uiCreatePoll8F5663 => 'Create poll';

  @override
  String get uiWriteToGroup5878DB => 'Write to group';

  @override
  String get uiWriteAReply0A58E1 => 'Write a reply';

  @override
  String get uiYouAreNoLongerIn571DA7 => 'You are no longer in this group';

  @override
  String get uiVote64F872 => 'Vote';

  @override
  String get uiChooseOptionsEA120E => 'Choose options';

  @override
  String get uiRetractVoteA5DA11 => 'Retract vote';

  @override
  String get uiClosePollA6A189 => 'Close poll';

  @override
  String get uiScheduleOneAttachmentAtAC580C3 =>
      'Schedule one attachment at a time.';

  @override
  String get uiNotDeliveredYetSendViaF056E1 =>
      'Not delivered yet. Send via Matrix…';

  @override
  String get uiVoiceCallsAreTurnedOff692843 =>
      'Voice calls are turned off. Enable them in Settings to call.';

  @override
  String get uiVoiceCallAudioIsUnavailable0B6C43 =>
      'Voice-call audio is unavailable in this build.';

  @override
  String get uiRouteInspector0E65DE => 'Route inspector';

  @override
  String get uiThisContactRequestIsBlocked944F7D =>
      'This contact request is blocked.';

  @override
  String get uiMessageSavedHereUntilTheA49A2C =>
      'Message saved here until the contact accepts.';

  @override
  String get uiWriteAnEncryptedMessage9F7705 => 'Write an encrypted message';

  @override
  String get uiWriteAReplyOrAddFC0A42 => 'Write a reply or add a caption';

  @override
  String get uiHoldToRecordAVoice06B1B5 => 'Hold to record a voice message';

  @override
  String get uiWriteToNearbyLANUsers291142 => 'Write to nearby LAN users';

  @override
  String get uiBroadcast77CA3F => 'Broadcast';

  @override
  String get uiThisRemovesTheLocalContact0D6D1E =>
      'This removes the local contact and message history. The app will also try to send a removal notice so this contact disappears on the other side.';

  @override
  String get uiDescriptionBio505243 => 'Description / bio';

  @override
  String get uiCheckPaths917FF3 => 'Check Paths';

  @override
  String get uiCopyState9BFD16 => 'Copy State';

  @override
  String get uiRemoveContact7F9A8A => 'Remove Contact';

  @override
  String get uiSaveProfile909BF3 => 'Save Profile';

  @override
  String get uiShowAsBeam74375F => 'Show as Beam';

  @override
  String get uiShowTheQRAnyway0B0CDF => 'Show the QR anyway';

  @override
  String get uiOpenFullscreenQRC5418D => 'Open Fullscreen QR';

  @override
  String get uiShowQRCFBAC6 => 'Show QR';

  @override
  String get uiLegacyInviteC61C5D => 'Legacy invite';

  @override
  String get uiForContactsOnConestOr486754 =>
      'For contacts on Conest 0.3.11 or older. It leaves out your routes for blocked networks; they arrive once you are connected.';

  @override
  String get uiRotateCodephraseNow89B2D5 => 'Rotate Codephrase Now';

  @override
  String get uiEncryptForContactE07450 => 'Encrypt for contact';

  @override
  String get uiPublicOpticalTransfer58E3F4 => 'Public optical transfer';

  @override
  String get uiAnyoneWhoCanSeeTheFAB2D0 =>
      'Anyone who can see the display may reconstruct this file. It is signed for integrity but it is not confidential.';

  @override
  String get uiChoosePublicFile6E2739 => 'Choose public file';

  @override
  String get uiKeepThisScreenVisibleUntil2261B8 =>
      'Keep this screen visible until the receiver reports 100%.';

  @override
  String get uiReceiveConestBeamB05BCB => 'Receive Conest Beam';

  @override
  String get uiDesktopCameraActiveDA0F15 => 'Desktop camera active';

  @override
  String get uiPasteOneCbFrame66EA2B => 'Paste one cb1 frame';

  @override
  String get uiAddFrame2BBA30 => 'Add frame';

  @override
  String get uiContactAliasE07C25 => 'Contact alias';

  @override
  String get uiWeComparedThisFingerprintIn952BEB =>
      'We compared this fingerprint in person';

  @override
  String get uiTrustAndAddContact0962A2 => 'Trust and add contact';

  @override
  String get uiSavedInPrivateConestStorage4C1334 =>
      'Saved in private Conest storage:';

  @override
  String get uiResetIdentity8B0224 => 'Reset identity';

  @override
  String get uiThisClearsTheEncryptedVault864B3D =>
      'This clears the encrypted vault, removes contacts and messages, and returns the app to the first-launch state.';

  @override
  String get uiReset44C57A => 'Reset';

  @override
  String get uiNoIdentityIsActive6B2EE3 => 'No identity is active.';

  @override
  String get uiSaveNameE73831 => 'Save Name';

  @override
  String get uiSaveBioBE2711 => 'Save Bio';

  @override
  String get uiMessageNotifications595635 => 'Message notifications';

  @override
  String get uiShowASystemNotificationWhen90113B =>
      'Show a system notification when a direct message arrives.';

  @override
  String get uiExperimentalVoiceCalls51098B => 'Experimental voice calls';

  @override
  String get uiExperimentalAndroidBackgroundReceive60828A =>
      'Experimental Android background receive';

  @override
  String get uiDisabledInReleaseBuildsThe45B7DF =>
      'Disabled in release builds: the foreground service does not yet host a headless Flutter receiver.';

  @override
  String get uiAllowVoiceCallsInBackground73C5C5 =>
      'Allow voice calls in background';

  @override
  String get uiKeepsCallSignalingActiveAndC0A342 =>
      'Keeps call signaling active and shows an ongoing call notification while the Conest service runs. Requires Experimental voice calls; Android battery policy or force-stop can still end availability.';

  @override
  String get uiDonTSendReadConfirmations230076 =>
      'Don\'t send read confirmations';

  @override
  String get uiDebugOnlyDeliveryAcknowledgementsStill7D6A9C =>
      'Debug-only. Delivery acknowledgements still send; incoming read confirmations are still processed.';

  @override
  String get uiRemoveMetadataFromFilesA4860E => 'Remove metadata from files';

  @override
  String get uiBeforeSendingRemovesLocationCamera4E390D =>
      'Before sending, removes location, camera, author and date details from photos, videos, PDFs and office documents. Pictures are not re-compressed. Other files are sent as they are.';

  @override
  String get uiSendFilesUnderRandomNames5F79D4 =>
      'Send files under random names';

  @override
  String get uiReplacesFileNamesWithRandom16F099 =>
      'Replaces file names with random letters (the type, such as .jpg, stays), for you and the recipient.';

  @override
  String get uiKeepOfStorageFreeF00434 => 'Keep 10% of storage free';

  @override
  String get uiReserveFreeSpaceForOther1AC9CF =>
      'Reserve free space for other apps. When off, transfers can use this space but must still fit on disk.';

  @override
  String get uiLAN2ECD17 => 'LAN';

  @override
  String get uiSameNetworkListenerPairingBeacons5CF0A2 =>
      'Same-network listener, pairing beacons, LAN delivery.';

  @override
  String get uiOnlineC3E839 => 'Online';

  @override
  String get uiIrohMessagingAndFileTransfersC4D635 =>
      'Iroh messaging and file transfers over the internet. Custom Conest relays are optional.';

  @override
  String get uiIrohRelayFallbackE954F7 => 'Iroh relay fallback';

  @override
  String get uiUseIrohSBuiltIn631E03 =>
      'Use Iroh’s built-in relays for messages and files when direct connections cannot get through. Both peers must be online.';

  @override
  String get uiLimitIrohFilesToMiBB58353 =>
      'Limit Iroh files to 100 MiB (recommended)';

  @override
  String get uiAppliesToDirectOnlineAnd28F6F1 =>
      'Applies to direct online and Iroh relay transfers. Disable for larger files; they may take a long time. LAN transfers keep their larger limit.';

  @override
  String get uiShareEmailAndMatrixAddressesD762EE =>
      'Share email and Matrix addresses with group members';

  @override
  String get uiLetsMembersOfYourGroups9912A5 =>
      'Lets members of your groups who are not your contacts reach you by email or Matrix. Off: they only learn your Nostr, Tor and radio addresses, which do not name you. Turning it off stops sharing from now on; members who already saw an address may keep it.';

  @override
  String get uiAutomaticDownloads5E777B => 'Automatic downloads';

  @override
  String get uiVerifiedContactsOnlyLimitsAdapt8A1876 =>
      'Verified contacts only. Limits adapt to Wi-Fi/Ethernet, cellular, and roaming.';

  @override
  String get uiCustomIrohRelayURLsDBF979 => 'Custom Iroh relay URLs';

  @override
  String get uiOneHTTPSURLPerLineDA8E70 =>
      'One HTTPS URL per line; blank uses the standard N0 relay set.';

  @override
  String get uiSaveIrohRelaysC144AD => 'Save Iroh relays';

  @override
  String get uiCheckAvailabilityFCC1A6 => 'Check Availability';

  @override
  String get uiRunThisDeviceAsA9DEA14 => 'Run this device as a relay';

  @override
  String get uiAllowTrustedContactsToUse001771 =>
      'Allow trusted contacts to use this device as a relay.';

  @override
  String get uiAutoUseContactsAsRelaysC62C06 => 'Auto-use contacts as relays';

  @override
  String get uiLocalRelayPort28A73C => 'Local relay port';

  @override
  String get uiSavePort1876F6 => 'Save Port';

  @override
  String get uiRelayHostURLF11441 => 'Relay host / URL';

  @override
  String get uiRelayPortEA05DA => 'Relay port';

  @override
  String get uiDetectAddRelayE825AD => 'Detect & Add Relay';

  @override
  String get uiErrorHistory25AFF8 => 'Error history';

  @override
  String get uiWhatWentWrongKeptAcross27FC1F =>
      'What went wrong, kept across restarts on this build, to copy for a bug report.';

  @override
  String get uiReceiveUnstableUpdatesBF7122 => 'Receive unstable updates';

  @override
  String get uiAlsoOfferNightlyBuildsNewerA7FAB0 =>
      'Also offer nightly builds: newer features, less tested. A newer stable release is always offered.';

  @override
  String get uiResetAppIdentity2E0F86 => 'Reset App Identity';

  @override
  String get uiTrustNewKeyA181BE => 'Trust new key';

  @override
  String get uiVerifyThePersonAndCompare738F28 =>
      'Verify the person and compare this safety number through another channel before accepting.';

  @override
  String get uiReviewE29A79 => 'Review';

  @override
  String get uiDiscardChat319267 => 'Discard chat';

  @override
  String get uiConfirmIdentityReplacement0219C5 =>
      'Confirm identity replacement?';

  @override
  String get uiItSThem394960 => 'It\'s them';

  @override
  String get uiRejectThisIdentityCB604F => 'Reject this identity?';

  @override
  String get uiThisDeletesTheNewContactBB4444 =>
      'This deletes the new contact and any held inbound messages. Use this if you believe this is impersonation.';

  @override
  String get uiNotThem685593 => 'Not them';

  @override
  String get uiRemoveImportedList36FC81 => 'Remove imported list?';

  @override
  String get uiNoBundledConestRelaysOnline46529B =>
      'No bundled Conest relays. Online connections use Iroh; you can also configure your own relay.';

  @override
  String get uiImportFromURL3F7B77 => 'Import from URL…';

  @override
  String get uiImportRelayListFromURL86E363 => 'Import relay list from URL';

  @override
  String get uiJSONURL6918BA => 'JSON URL';

  @override
  String get uiOperatorSPublicKeyOptionalA80E7A =>
      'Operator\'s public key (optional, base64)';

  @override
  String get uiImportD6FBC9 => 'Import';

  @override
  String get uiCLEAN2F3D27 => 'CLEAN';

  @override
  String get uiSUBTLEBB048B => 'SUBTLE';

  @override
  String get uiDEFAULTC18920 => 'DEFAULT';

  @override
  String get uiFULLCC0A74 => 'FULL';

  @override
  String get uiLANFirstB360D1 => 'LAN first';

  @override
  String get uiLANOnly94945D => 'LAN only';

  @override
  String get uiOnlineFirst346B6D => 'Online first';

  @override
  String get uiOnlineOnlyF79CB9 => 'Online only';

  @override
  String get uiOfflineE01FA7 => 'Offline';

  @override
  String get uiUsesLANWhenAvailableFallsA810EF =>
      'Uses LAN when available, falls back to Online.';

  @override
  String get uiUsesLANOnlyNoRelay589D55 =>
      'Uses LAN only. No relay traffic for this contact.';

  @override
  String get uiUsesOnlineWhenAvailableFallsCE2CAF =>
      'Uses Online when available, falls back to LAN.';

  @override
  String get uiUsesOnlineOnlyNoLAN193810 =>
      'Uses Online only. No LAN traffic for this contact.';

  @override
  String get uiNoTransportSelectedThisContact7969EB =>
      'No transport selected — this contact is unreachable.';

  @override
  String get uiGlobalConnectivityIsOffAdjustA7C644 =>
      'Global connectivity is off — adjust Settings to send.';

  @override
  String get uiSameNetworkDelivery94E793 => 'Same-network delivery';

  @override
  String get uiDisabledByGlobalSetting2CB06C => 'Disabled by global setting';

  @override
  String get uiAllowIrohRelayFallback35227B => 'Allow Iroh relay fallback';

  @override
  String get uiVisibleAndOnlineOnlyDirectEA8902 =>
      'Visible and online-only; direct Iroh is preferred.';

  @override
  String get uiRelayInternetDeliveryD64AB6 => 'Relay / internet delivery';

  @override
  String get uiPrefer13F662 => 'Prefer';

  @override
  String get uiCarryTheirMessages22FD33 => 'Carry their messages';

  @override
  String get uiWhenThisContactCannotReach5C3FF8 =>
      'When this contact cannot reach someone but this device can, pass their messages on. You see only who they are for and when; the content stays encrypted.';

  @override
  String uiSaveValueFileSToB46C57(String value) {
    return 'Save $value file(s) to…';
  }

  @override
  String get uiSaveCanceled1939D0 => 'Save canceled.';

  @override
  String get uiAlbumActions7B6D70 => 'Album actions';

  @override
  String get uiCancelSelectionF7F56C => 'Cancel selection';

  @override
  String get uiCopyAF74F7 => 'Copy';

  @override
  String get uiSaveAttachments5A74EA => 'Save attachments';

  @override
  String get uiCancelAndClearAllTransfers01B81D =>
      'Cancel and clear all transfers?';

  @override
  String get uiKeepTransfersDB8CC7 => 'Keep transfers';

  @override
  String get uiCancelAndClearCCF59C => 'Cancel and clear';

  @override
  String get uiPauseAll6F6099 => 'Pause all';

  @override
  String get uiResumeAll039916 => 'Resume all';

  @override
  String get uiCancelAndClearAllTransfersACEBB3 =>
      'Cancel and clear all transfers';

  @override
  String get uiClearCompletedE63FC1 => 'Clear completed';

  @override
  String get uiMoveToTop44AFA6 => 'Move to top';

  @override
  String get uiPreparingDownloadF9B13B => 'Preparing download';

  @override
  String get uiDownloadA479C9 => 'Download';

  @override
  String get uiResumeB3BD0B => 'Resume';

  @override
  String get uiPause781961 => 'Pause';

  @override
  String get uiRetry9F5CD8 => 'Retry';

  @override
  String get uiContinueOverIrohRelay949702 => 'Continue over Iroh relay';

  @override
  String get uiDownloadAnyway42859F => 'Download anyway';

  @override
  String get uiPreparing96A9B7 => 'Preparing';

  @override
  String get uiQueued6A5998 => 'Queued';

  @override
  String get uiWaiting33D306 => 'Waiting';

  @override
  String get uiTransferring73F753 => 'Transferring';

  @override
  String get uiReconnecting9D80F9 => 'Reconnecting';

  @override
  String get uiPausedC7DFB6 => 'Paused';

  @override
  String get uiVerifying536244 => 'Verifying';

  @override
  String get uiComplete1F5A1A => 'Complete';

  @override
  String get uiCanceledF840AC => 'Canceled';

  @override
  String get uiUnavailable2C9C1F => 'Unavailable';

  @override
  String uiSavedValueToValue08F152(String value, String value2) {
    return 'Saved $value to $value2.';
  }

  @override
  String uiGallerySaveFailedValueFalling0B82BB(String value) {
    return 'Gallery save failed ($value); falling back to file dialog.';
  }

  @override
  String uiSaveValue5769AA(String value) {
    return 'Save $value';
  }

  @override
  String uiSaveFailedValue534182(String value) {
    return 'Save failed: $value';
  }

  @override
  String get uiTheAttachmentFileIsNotA67009 =>
      'The attachment file is not available locally.';

  @override
  String uiCopiedValueToClipboard669D0B(String value) {
    return 'Copied $value to clipboard.';
  }

  @override
  String uiCopiedValueTextOnlySystemB51B8D(String value) {
    return 'Copied \"$value\" (text only — system clipboard binary surface unavailable).';
  }

  @override
  String uiCopyFailedValueFilenameCopiedF71C87(String value) {
    return 'Copy failed: $value. Filename copied as text fallback.';
  }

  @override
  String get uiCachePathIsNotReady0404B5 =>
      'Cache path is not ready yet — still transferring.';

  @override
  String uiCachePathCopiedValue4CC1C4(String value) {
    return 'Cache path copied: $value';
  }

  @override
  String get uiVideoIsnTCachedLocally8920DD =>
      'Video isn\'t cached locally yet — wait for the transfer to finish.';

  @override
  String uiCouldNotOpenVideoIn054087(String value) {
    return 'Could not open video in the system player: $value';
  }

  @override
  String get uiImageIsNotAvailableLocally12017F =>
      'Image is not available locally.';

  @override
  String uiVideoStillTransferringValue3F4049(String value) {
    return 'Video still transferring ($value%).';
  }

  @override
  String get uiVoiceMessageBytesAreNotF8339B =>
      'Voice message bytes are not ready.';

  @override
  String get uiSendMode265A2D => 'Send mode';

  @override
  String get uiLANRelayA05D48 => 'LAN relay';

  @override
  String get uiLobbyFDB6D9 => 'Lobby';

  @override
  String get uiDirectBC8152 => 'Direct';

  @override
  String get uiIroh84642D => 'Iroh';

  @override
  String get uiIrohRelayB128EA => 'Iroh relay';

  @override
  String get uiRelay9F537F => 'Relay';

  @override
  String get uiMatrix58947E => 'Matrix';

  @override
  String get uiPlainMatrixBA9DE1 => 'Plain Matrix';

  @override
  String get uiNostr4D3AD8 => 'Nostr';

  @override
  String get uiEmail84ADD5 => 'Email';

  @override
  String get uiReticulumC27E52 => 'Reticulum';

  @override
  String get uiMeshtastic29C887 => 'Meshtastic';

  @override
  String get uiMeshCoreBA58A2 => 'MeshCore';

  @override
  String get uiBluetoothC3B414 => 'Bluetooth';

  @override
  String get uiTorED7088 => 'Tor';

  @override
  String get uiViaContactCF1F8E => 'Via contact';

  @override
  String get uiSendViaMatrix062A08 => 'Send via Matrix?';

  @override
  String get uiKeepWaiting9BE1AB => 'Keep waiting';

  @override
  String get uiSendViaMatrix638038 => 'Send via Matrix';

  @override
  String uiNotSentViaMatrixValue99F62C(String value) {
    return 'Not sent via Matrix: $value';
  }

  @override
  String get uiMessageRoutesFBF32C => 'Message routes';

  @override
  String get uiWhatTheColouredMarksOnA10C8E =>
      'What the coloured marks on messages mean';

  @override
  String get uiOpenInDefaultPlayerE64C20 => 'Open in default player';

  @override
  String get uiCancelReplyBD62D2 => 'Cancel reply';

  @override
  String get uiScheduledMessages98CEF4 => 'Scheduled messages';

  @override
  String get uiEditScheduledMessage62AF88 => 'Edit scheduled message';

  @override
  String get uiCaption3428D9 => 'Caption';

  @override
  String get uiNoChatsToShareIntoB50F2F => 'No chats to share into yet.';

  @override
  String get uiLetDevicesOnThisNetwork42E2F0 =>
      'Let devices on this network reach this PC';

  @override
  String get uiAllow3AD0E3 => 'Allow';

  @override
  String get uiKeepSignedIn611A13 => 'Keep signed in';

  @override
  String get uiSignOutHereA6F129 => 'Sign out here';

  @override
  String get uiMatrixPassword34E218 => 'Matrix password';

  @override
  String get uiPassword8BE3C9 => 'Password';

  @override
  String get uiYourServerAsksForIt1594FA =>
      'Your server asks for it to create signing keys.';

  @override
  String get uiRecoveryIsAlreadySetUp371F7F => 'Recovery is already set up';

  @override
  String get uiOK9CE3BD => 'OK';

  @override
  String get uiSaveYourRecoveryKey7851B3 => 'Save your recovery key';

  @override
  String get uiKeepThisKeySomewhereSafe0C0DFE =>
      'Keep this key somewhere safe. You need it to read encrypted Matrix history on a new device. It is shown only once.';

  @override
  String get uiISavedIt3E2255 => 'I saved it';

  @override
  String get uiEnterRecoveryKey4521B6 => 'Enter recovery key';

  @override
  String get uiEsTFromAnotherMatrixAppFCA0C9 =>
      'EsT… (from another Matrix app or this one)';

  @override
  String get uiSignOutDC1649 => 'Sign out';

  @override
  String get uiSetUpRecoveryFD3804 => 'Set up recovery';

  @override
  String get uiVerifyWithAnotherSession9ED031 => 'Verify with another session';

  @override
  String get uiShowJoinsLeavesAndProfile9FA764 =>
      'Show joins, leaves and profile changes';

  @override
  String get uiInMatrixRoomsCollapsedIntoD20CAB =>
      'In Matrix rooms, collapsed into one line';

  @override
  String get uiMatrixUser70A560 => 'Matrix user';

  @override
  String get uiForExampleNameMatrixOrg63C60A => 'For example @name:matrix.org';

  @override
  String get uiHomeserverOptional70DF85 => 'Homeserver (optional)';

  @override
  String get uiFoundFromTheUserId69A3AB => 'Found from the user id when blank';

  @override
  String get uiSignInToMatrix652C8F => 'Sign in to Matrix';

  @override
  String get uiSignInWithBrowserC995DF => 'Sign in with browser';

  @override
  String get uiFinishSigningInInYour9F41A4 =>
      'Finish signing in in your browser.';

  @override
  String get uiCopyLink2F84EE => 'Copy link';

  @override
  String get uiThisDeviceFA5A6D => 'This device';

  @override
  String uiOutOfTouchSinceValueA037FD(String value) {
    return 'Out of touch since $value: nothing syncs with it until you confirm it is still yours.';
  }

  @override
  String uiLinkedValueDCADF7(String value) {
    return 'Linked $value';
  }

  @override
  String get uiYourContactsWillStopAccepting5B0F03 =>
      'Your contacts will stop accepting anything from that device. It cannot be added back; link it again as a new device instead.';

  @override
  String get uiStillMine38C8AE => 'Still mine';

  @override
  String get uiRemoveDeviceA9C39D => 'Remove device';

  @override
  String get uiLinkADeviceE71635 => 'Link a device';

  @override
  String get uiLinkThisDeviceToMy888A1A => 'Link this device to my account';

  @override
  String get uiCheckThatBothDevicesShow031E51 =>
      'Check that both devices show this code:';

  @override
  String get uiTheCodesMatch32C407 => 'The codes match';

  @override
  String get uiLinkedTheNewDeviceNow9900E5 =>
      'Linked. The new device now has your account and contacts; your contacts will see it as you.';

  @override
  String get uiConfirmTheCodeOnThe17BB1F =>
      'Confirm the code on the new device too.';

  @override
  String get uiWaitingForTheNewDevice75283F =>
      'Waiting for the new device to answer. If no code appears, make sure the new device still shows its code, and that both are on the same network or online.';

  @override
  String get uiOnTheNewDeviceOpen29AF5E =>
      'On the new device, open Settings → Devices → Link this device to my account, then scan the code it shows.';

  @override
  String get uiScanCode4596C2 => 'Scan code';

  @override
  String get uiOrPasteTheCodeE72792 => 'Or paste the code';

  @override
  String get uiLinkThisDeviceBF5E5C => 'Link this device';

  @override
  String get uiThisDeviceIsNowLinked7EA826 =>
      'This device is now linked to your account.';

  @override
  String get uiWaitingForTheOtherDeviceB39C3F =>
      'Waiting for the other device…';

  @override
  String get uiOnTheDeviceYouAlready92C421 =>
      'On the device you already use, open Settings → Devices → Link a device and scan this code. Both devices should be on the same network or online.';

  @override
  String get uiDeltaChat8BDA67 => 'Delta Chat';

  @override
  String get uiBitchatA99B50 => 'bitchat';

  @override
  String get uiWithAFilterOfTheir4FD18E =>
      'With a filter of their own. Off: open them from the network\'s settings only.';

  @override
  String get uiYourDeltaChatInviteEE073F => 'Your Delta Chat invite';

  @override
  String get uiShowTheQRCodeTo0769AD =>
      'Show the QR code to a Delta Chat user, or send the link. Whoever has it can start a verified chat with you.';

  @override
  String get uiShowQRCode2DF2DD => 'Show QR code';

  @override
  String get uiDeltaChatChats8EBCBC => 'Delta Chat chats';

  @override
  String get uiGroup171A06 => 'Group';

  @override
  String get uiJoinWithAnInviteC76024 => 'Join with an invite';

  @override
  String get uiJoinE0D731 => 'Join';

  @override
  String get uiNewDeltaChatGroup7D5142 => 'New Delta Chat group';

  @override
  String get uiGroupNameEBB7E1 => 'Group name';

  @override
  String get uiMembers1CB449 => 'Members';

  @override
  String get uiGroupInviteD64669 => 'Group invite';

  @override
  String get uiYouAreNotInThisCF5BD5 => 'You are not in this group';

  @override
  String get uiStartGroupCallC2A083 => 'Start group call';

  @override
  String get uiJoinGroupCallC9ECF8 => 'Join group call';

  @override
  String get uiPushToTalk032E78 => 'Push-to-talk';

  @override
  String get uiCarryMessagesOverAReticulum1CE915 =>
      'Carry messages over a Reticulum network, for example LoRa radios (RNode) without the internet, through a node running rnsd with a TCP server interface. Conest keeps a Reticulum identity of its own; your contacts learn it automatically.';

  @override
  String get uiNodeAddressRnsdCD61E2 => 'Node address (rnsd)';

  @override
  String get uiUSBDeviceB47FF0 => 'USB device';

  @override
  String get uiRNodeAddress691283 => 'RNode address';

  @override
  String get uiBluetoothAddress0E2BED => 'Bluetooth address';

  @override
  String get uiTCPPortDE05BE => 'TCP port';

  @override
  String get uiEU233558 => 'EU 869.525';

  @override
  String get uiUS5ED166 => 'US 914.875';

  @override
  String get uiUseConestAsAMatrix6A44C5 =>
      'Use Conest as a Matrix client only?';

  @override
  String get uiYourConestChatsAreHiddenCFD853 =>
      'Your Conest chats are hidden and Conest stops connecting on this device until you switch back. Nothing is deleted. Contacts cannot reach you over Conest meanwhile; their apps keep retrying and deliver when you switch back.';

  @override
  String get uiSwitch3E44C9 => 'Switch';

  @override
  String get uiSealAnimatedRings29BE2D => 'Seal (animated rings)';

  @override
  String get uiSigilRuneA0B8A7 => 'Sigil (rune)';

  @override
  String get uiBlockiePixelHashA265BA => 'Blockie (pixel hash)';

  @override
  String get uiMonogramInitials8C6019 => 'Monogram (initials)';

  @override
  String get uiNewMatrixChatC065C8 => 'New Matrix chat';

  @override
  String get uiNameMatrixOrgD0BB06 => '@name:matrix.org';

  @override
  String get uiStartChat18BB58 => 'Start chat';

  @override
  String get uiCopyText06A76C => 'Copy text';

  @override
  String uiVerifyValue1B6B79(String value) {
    return 'Verify $value';
  }

  @override
  String get uiAttachAFileAE85E4 => 'Attach a file';

  @override
  String get uiMessageDeleted3271A7 => 'Message deleted';

  @override
  String get uiUnableToDecryptFDF88B => 'Unable to decrypt';

  @override
  String uiValueCF9C0A(String value) {
    return '📷 $value';
  }

  @override
  String uiValue134796(String value) {
    return '📎 $value';
  }

  @override
  String uiValueValue6EF45D(String value, String value2) {
    return '$value: $value2';
  }

  @override
  String get uiDeclineB59CF9 => 'Decline';

  @override
  String get uiCarryMessagesAsEncryptedEmail0D19EA =>
      'Carry messages as encrypted email when other routes fail, like Delta Chat. The mail servers see both addresses and when, not what. Your contacts learn the address automatically.';

  @override
  String get uiUseMyOwnEmailAccountE78C1D => 'Use my own email account instead';

  @override
  String get uiNostrRelaysBD8BAD => 'Nostr relays';

  @override
  String get uiCarryMessagesThroughPublicNostr729B94 =>
      'Carry messages through public Nostr relays when other routes fail. Relays see that someone writes to you and when, not who or what. Uses a separate key; your contacts learn it automatically.';

  @override
  String get uiRelaysYouReadFromOne020C0A =>
      'Relays you read from (one per line, up to 4)';

  @override
  String get uiSaveRelays91CBA8 => 'Save relays';

  @override
  String get uiDefaultRelays5C909F => 'Default relays';

  @override
  String get uiNewChat009BF6 => 'New chat';

  @override
  String get uiNodeAddress896F20 => 'Node address';

  @override
  String get uiDeleteChatDB9121 => 'Delete chat';

  @override
  String get uiTurnOnAppMessagesTo7DCA13 => 'Turn on app messages to write';

  @override
  String get uiBitchatNearbyD0C416 => 'bitchat nearby';

  @override
  String get uiMeshChat7BF668 => 'Mesh chat';

  @override
  String get uiHiddenTurnOnReachableBy0103C9 =>
      'Hidden: turn on \"Reachable by bitchat users\"';

  @override
  String get uiTheyDonTMatch27EF0C => 'They don\'t match';

  @override
  String get uiTheyMatch6FB8EB => 'They match';

  @override
  String get uiNameBitchatUsersSee1CE7E3 => 'Name bitchat users see';

  @override
  String get uiANameYouChooseStays17E677 =>
      'A name you choose stays when your identity changes, so people nearby can tell it is still you. Leave it empty for a new \"anon\" name with each identity.';

  @override
  String get uiBluetoothMeshC8B7F1 => 'Bluetooth mesh';

  @override
  String get uiReachContactsNearbyWithoutAny9E9649 =>
      'Reach contacts nearby without any network: messages hop from phone to phone over Bluetooth, through Conest and bitchat users alike, and this phone relays for others. This phone does not show up in bitchat, and what it sends looks like any bitchat private message, with ids that change every hour.';

  @override
  String get uiReachableByBitchatUsers568021 => 'Reachable by bitchat users';

  @override
  String get uiShareInternetWithBitchatUsers572F90 =>
      'Share internet with bitchat users';

  @override
  String get uiChangeNameE46692 => 'Change name';

  @override
  String get uiNewIdentityA119CF => 'New identity';

  @override
  String get uiBitchatChatsC74EC3 => 'bitchat chats';

  @override
  String get uiTheMatrixClientIsNot01A5B4 =>
      'The Matrix client is not available on this device, so Conest cannot run in Matrix-only mode here.';

  @override
  String get uiUseConest12EEF3 => 'Use Conest';

  @override
  String get uiSearchRoomsCCE4F9 => 'Search rooms';

  @override
  String get uiReachContactsThroughTorOnion8B8A98 =>
      'Reach contacts through Tor onion services: neither side nor the network learns where the other is. Slower than other routes; add bridges where Tor is blocked.';

  @override
  String get uiBridgesOptionalOnePerLine110291 =>
      'Bridges (optional, one per line)';

  @override
  String get uiEEFEBFE80B7A =>
      '192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413';

  @override
  String get uiObfsEEFEAD0EDF =>
      'obfs4 192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413 cert=… iat-mode=0';

  @override
  String get uiLinesFromBridgesTorprojectOrgF08389 =>
      'Lines from bridges.torproject.org, starting with the type: obfs4, webtunnel, snowflake or meek_lite (or plain bridges: address and fingerprint).';

  @override
  String get uiPlainBridgesOnlyAddressAnd7F0B60 =>
      'Plain bridges only (address and fingerprint) in this build.';

  @override
  String get uiUseTheseBridgesC1FA11 => 'Use these bridges';

  @override
  String get uiNostrPrivateMessagesDF74A3 => 'Nostr private messages';

  @override
  String get uiChatWithAnyoneOnNostrA867BC =>
      'Chat with anyone on Nostr (0xchat, Amethyst, Damus and other apps that use NIP-17), one to one or in small groups. A Nostr account of its own, never linked to your Conest contacts. End-to-end encrypted, but without forward secrecy.';

  @override
  String get uiYourNostrAddress5CF7C6 => 'Your Nostr address';

  @override
  String get uiCopyWithYourRelaysD49669 => 'Copy (with your relays)';

  @override
  String get uiNostrChats3D786C => 'Nostr chats';

  @override
  String get uiNewNostrChat68199C => 'New Nostr chat';

  @override
  String get uiNpubSeveralForAGroupE6ED77 => 'npub1… (several for a group)';

  @override
  String get uiCarryShortMessagesOverAFA94B6 =>
      'Carry short messages over a MeshCore LoRa mesh through your companion radio, without the internet. Conest adds your contacts to the radio so it accepts their messages.';

  @override
  String get uiMessagesWithMeshCoreAppUsersDE77BA =>
      'Messages with MeshCore app users';

  @override
  String get uiReadAndWriteTheMeshCore98E60E =>
      'Read and write the MeshCore apps\' own messages through this radio: with its contacts, and on its channels as group chats. They are protected only as MeshCore protects them.';

  @override
  String get uiMeshCoreChats82C29C => 'MeshCore chats';

  @override
  String get uiSendWithItsDetailsF287FB => 'Send with its details?';

  @override
  String get uiSendAnyway911263 => 'Send anyway';

  @override
  String get uiSaveTheErrorHistory0B3413 => 'Save the error history';

  @override
  String uiSavedTheErrorHistoryTo5271C5(String value) {
    return 'Saved the error history to $value.';
  }

  @override
  String uiSavingTheErrorHistoryFailed72A33A(String value) {
    return 'Saving the error history failed: $value';
  }

  @override
  String get uiSaveToAFile5BB648 => 'Save to a file';

  @override
  String get uiClear719EA3 => 'Clear';

  @override
  String get uiFilterD7DECF => 'Filter';

  @override
  String get uiErrorsOnlyHideTheDebugECA1DD =>
      'Errors only (hide the debug log)';

  @override
  String uiValueH171B92(String value) {
    return '$value h';
  }

  @override
  String uiValueMin439C52(String value) {
    return '$value min';
  }

  @override
  String uiTheirClockIsAboutValueF406F1(String value) {
    return 'Their clock is about $value $value; times here are by this device.';
  }

  @override
  String uiValueB7CFB44(String value) {
    return '$value B';
  }

  @override
  String uiValueKB554C06(String value) {
    return '$value KB';
  }

  @override
  String uiValueMBDB5A1C(String value) {
    return '$value MB';
  }

  @override
  String uiValueGB0A98F3(String value) {
    return '$value GB';
  }

  @override
  String get uiSent27E770 => 'sent';

  @override
  String get uiWaitingOnTheRelayED66FF => 'waiting on the relay';

  @override
  String get uiReachedTheirDevice0FE289 => 'reached their device';

  @override
  String get uiDeliveredF81891 => 'delivered';

  @override
  String get uiReceived38428A => 'received';

  @override
  String get uiCarryShortMessagesOverADD8570 =>
      'Carry short messages over a Meshtastic LoRa mesh, without the internet, through your Meshtastic radio. Contacts need Conest with a radio in the same mesh.';

  @override
  String get uiFindDevices98771A => 'Find devices';

  @override
  String get uiRadioAddressD288E6 => 'Radio address';

  @override
  String get uiMessagesWithMeshtasticAppUsers812B3A =>
      'Messages with Meshtastic app users';

  @override
  String get uiReadAndWriteTheMeshtastic995E5D =>
      'Read and write the Meshtastic apps\' own messages through this radio: direct ones, and its channels as group chats. They are protected only as Meshtastic protects them.';

  @override
  String get uiMeshtasticChats46BEF8 => 'Meshtastic chats';

  @override
  String get uiClearSelection247FD6 => 'Clear selection';

  @override
  String get uiBrowseFilesAF7C13 => 'Browse files…';

  @override
  String get uiSelectMoreE38EF3 => 'Select more';

  @override
  String get uiAllowAllA16326 => 'Allow all';

  @override
  String get uiCaptionDA5C59 => 'Caption…';

  @override
  String get uiOpenSettingsFD7108 => 'Open settings';

  @override
  String get uiDiscardChangesD3F0B4 => 'Discard changes?';

  @override
  String get uiYourEditsWillBeLostB34663 =>
      'Your edits will be lost. The original image stays in your gallery.';

  @override
  String get uiKeepEditingD4D9E3 => 'Keep editing';

  @override
  String get uiDiscard36FFF6 => 'Discard';

  @override
  String get uiRotateLeft6F72F3 => 'Rotate left';

  @override
  String get uiRotateRightB75F23 => 'Rotate right';

  @override
  String get uiApplyCropA43CCF => 'Apply crop';

  @override
  String get uiCropC5DB3D => 'Crop';

  @override
  String get uiVerifiedDownloadProgressBED7C2 => 'Verified download progress';

  @override
  String get uiSharingWithGroup2AED71 => 'Sharing with group';

  @override
  String get uiOpenCF9B77 => 'Open';

  @override
  String get uiStopSharing0E45AE => 'Stop sharing';

  @override
  String get uiRemoveLocalCopy80FA01 => 'Remove local copy';

  @override
  String get uiScanInviteEFC78A => 'Scan Invite';

  @override
  String uiValueValue176D15(String value, String value2) {
    return '$value:$value2';
  }

  @override
  String uiDefaultRelayValueBD3FD1(String value) {
    return 'default relay $value';
  }

  @override
  String uiSamplesValueSlowOverMsValueAE2EBF(String value, String value2) {
    return 'samples=$value slowOver100ms=$value2 maxTotalMs=$value maxBuildMs=$value maxRasterMs=$value';
  }

  @override
  String get uiConversation2A20C7 => 'Conversation';

  @override
  String uiSharedValueWithTheGroup163418(String value) {
    return 'Shared $value with the group as a regular attachment; some members need an update for voice playback.';
  }

  @override
  String uiSharedValueWithTheGroupAE4134(String value) {
    return 'Shared $value with the group.';
  }

  @override
  String uiValueBackoffValueSStreak25FF09(
    String value,
    String value2,
    String value3,
  ) {
    return '$value backoff ${value2}s streak $value3';
  }

  @override
  String get uiNone3C6B18 => '(none)';

  @override
  String uiLANNodeValueOn5D539E(String value) {
    return 'LAN node :$value on';
  }

  @override
  String get uiLANNodeUnavailable9CFA32 => 'LAN node unavailable';

  @override
  String uiLANValueA8EEF3(String value) {
    return 'LAN $value';
  }

  @override
  String uiRelayValueDownD6B267(String value) {
    return 'relay $value down';
  }

  @override
  String uiRelayValueA6D70A(String value) {
    return 'relay $value';
  }

  @override
  String get uiNoInternetRelay55D2CE => 'no internet relay';

  @override
  String uiValueValue42DC94(String value, String value2) {
    return '$value=$value2';
  }

  @override
  String uiValueHasBeenOutOf039D48(String value) {
    return '$value has been out of touch for a while: nothing syncs with it until you confirm it in Settings → Devices.';
  }

  @override
  String uiValueIsOneOfYourE4FD9C(String value) {
    return '$value is one of your own devices now; its old chat is no longer listed.';
  }

  @override
  String uiYourDevicesDisagreeOnWhich2E7001(String value) {
    return 'Your devices disagree on which devices are in the account, and together there would be more than $value. Remove one in Settings → Devices.';
  }

  @override
  String uiValueAddedADeviceValue710908(String value, String value2) {
    return '$value added a device: $value2.';
  }

  @override
  String uiUnknownValue9B520C(String value) {
    return 'Unknown $value';
  }

  @override
  String uiReadByAllValue43BA5A(String value) {
    return 'Read by all $value';
  }

  @override
  String uiDeliveredToAllValue71E077(String value) {
    return 'Delivered to all $value';
  }

  @override
  String uiAcceptedByValueOfValue826A0E(String value, String value2) {
    return 'Accepted by $value of $value2';
  }

  @override
  String uiWaitingForValueMemberS5A8BA6(String value) {
    return 'Waiting for $value member(s)';
  }

  @override
  String get uiConest26885B => 'Conest';

  @override
  String uiValueValueValueE9AA4A(String value, String value2, String value3) {
    return '$value$value2$value3';
  }

  @override
  String uiValueSkippedValueMBExceedsD0800C(
    String value,
    String value2,
    String value3,
  ) {
    return '$value skipped: $value2 MB exceeds the $value3 MB cap.';
  }

  @override
  String get uiRoute499952 => 'Route';

  @override
  String get uiSafetyNumber5ED2D3 => 'Safety number';

  @override
  String get uiIrohEndpoint72F674 => 'Iroh endpoint';

  @override
  String get uiDeviceA5A74A => 'Device';

  @override
  String get uiLANLobbyC16DC8 => 'LAN lobby';

  @override
  String uiMembersValue541E72(String value) {
    return 'Members · $value';
  }

  @override
  String get uiNodeOnlineFAC64A => 'Node · online';

  @override
  String uiSafetyValueC542B8(String value) {
    return 'safety $value';
  }

  @override
  String uiValue3072D4(String value) {
    return '$value%';
  }

  @override
  String uiValueMembersCEF563(String value) {
    return '$value members';
  }

  @override
  String get uiPairwise64A0EF => 'pairwise';

  @override
  String get uiPasteMedia4831DE => 'Paste media';

  @override
  String get uiRELAYA1C0CF => 'RELAY';

  @override
  String get uiSentAsAPlainMatrixAAE694 => 'Sent as a plain Matrix message';

  @override
  String get uiOnlyOnThisDevice7D64C4 => 'Only on this device';

  @override
  String get uiConnectivityIsOffTurnOnE42D4A =>
      'Connectivity is off. Turn on LAN or Online to exchange this invite.';

  @override
  String get uiConnectivityIsOffTurnOnFA573F =>
      'Connectivity is off. Turn on LAN or Online before sharing this invite.';

  @override
  String get uiReceiveBeam2CB58B => 'Receive Beam';

  @override
  String get uiSendEncryptedFile99D424 => 'Send encrypted file';

  @override
  String get uiSendPublicFileF81389 => 'Send public file';

  @override
  String get uiBeamContactInvite2BAB4C => 'Beam contact invite';

  @override
  String get uiDevicesDF485C => 'Devices';

  @override
  String get uiWARNC2FD77 => 'WARN';

  @override
  String get uiDOWN30E504 => 'DOWN';

  @override
  String get uiAVGRTTE96B26 => 'AVG RTT';

  @override
  String uiRoutingValueFC4557(String value) {
    return 'Routing — $value';
  }

  @override
  String uiActiveValueC78B63(String value) {
    return 'Active ($value)';
  }

  @override
  String uiRecentValueB82237(String value) {
    return 'Recent ($value)';
  }

  @override
  String get uiDirect24A173 => 'direct';

  @override
  String get uiRelayBD28B2 => 'relay';

  @override
  String get uiRoutingECF60A => 'routing';

  @override
  String uiInvitationValue6F0633(String value) {
    return 'Invitation: $value';
  }

  @override
  String get uiMeshChatNearbyA35A63 => 'Mesh chat (nearby)';

  @override
  String get uiVerifiedWithAnInviteBD826F => 'Verified with an invite';

  @override
  String get uiHoldToTalkOrHold74FC22 => 'Hold to talk, or hold Space';

  @override
  String get uiEndToEndEncryptedMatrix9E4418 => 'End-to-end encrypted (Matrix)';

  @override
  String get uiVerifiedAED3B8 => 'Verified';

  @override
  String uiValueValue64684F(String value, String value2) {
    return '$value · $value2';
  }

  @override
  String get uiPrimaryChannel53B8E1 => 'Primary channel';

  @override
  String uiChannelValue76ED1D(String value) {
    return 'Channel $value';
  }

  @override
  String get uiPublicChannelA9795B => 'Public channel';

  @override
  String get uiDescriptionCB3291 => 'description';

  @override
  String uiTheirClockIsAboutValue7DB956(String value, String value2) {
    return 'Their clock is about $value $value2; times here are by this device.';
  }

  @override
  String uiSamplesValueSlowOverMsValue45CEDE(
    String value,
    String value2,
    String value3,
    String value4,
    String value5,
  ) {
    return 'samples=$value slowOver100ms=$value2 maxTotalMs=$value3 maxBuildMs=$value4 maxRasterMs=$value5';
  }

  @override
  String uiValueF36340(String value) {
    return '$value…';
  }

  @override
  String get uiConestTransfer406028 => 'Conest transfer';

  @override
  String uiValueConestTransfersF846F8(String value) {
    return '$value Conest transfers';
  }

  @override
  String uiViaValueValue37232D(String value, String value2) {
    return 'via $value ($value2)';
  }

  @override
  String get uiBackThroughTheContactWhoD09BD0 =>
      'back through the contact who passed their message on';

  @override
  String uiConestRelayValue4FB2DB(String value) {
    return 'Conest relay $value';
  }

  @override
  String get uiConestIsAlreadyRunningEE8037 => 'Conest is already running';

  @override
  String get uiCloseTheExistingConestWindow83B30B =>
      'Close the existing Conest window first. A second instance would race the local relay port and encrypted vault.';

  @override
  String get uiChooseWhereConestStoresData0CF613 =>
      'Choose where Conest stores data';

  @override
  String get uiGhostModeIsBestEffort694912 =>
      'Ghost mode is best-effort privacy: OS launch history, crash logs, network metadata, shell history, recent files, and platform caches are outside app control.';

  @override
  String get uiDefaultOnThisDevice10343F => 'Default on this device';

  @override
  String get uiUseTheNormalAppDataF44F79 =>
      'Use the normal app data folder and this device keychain when auto-unlock is selected.';

  @override
  String get uiGhostPortableBesideTheApp31A40D =>
      'Ghost/portable beside the app';

  @override
  String get uiStoreConestControlledFilesIn7DA307 =>
      'Store Conest-controlled files in a conest_data folder next to the app.';

  @override
  String get uiVaultUnlock602BF6 => 'Vault unlock';

  @override
  String get uiKeyFileAutoUnlock66AC4A => 'Key file auto-unlock';

  @override
  String get uiKeepsTheKeyBesideTheB045D9 =>
      'Keeps the key beside the vault. Anyone with the folder can open it.';

  @override
  String get uiAutoUnlockWithThisDeviceE7F781 => 'Auto-unlock with this device';

  @override
  String get uiStoresTheVaultKeyInC7B1CD =>
      'Stores the vault key in the platform secure store.';

  @override
  String get uiPassphraseUnlock13B14C => 'Passphrase unlock';

  @override
  String get uiAskForAPassphraseOn4BA25C =>
      'Ask for a passphrase on each launch. Forgotten passphrases cannot be recovered.';

  @override
  String get uiUnlockConest033EB6 => 'Unlock Conest';

  @override
  String get uiEnterThePassphraseForThis891200 =>
      'Enter the passphrase for this vault.';

  @override
  String get uiNoUpdateIsAvailableRightA5EB48 =>
      'No update is available right now.';

  @override
  String uiValueIsAvailableOnTheD338C4(String value, String value2) {
    return '$value is available on the $value2 channel.';
  }

  @override
  String uiCurrentBuildValue2FD415(String value) {
    return 'Current build: $value';
  }

  @override
  String get uiWhatSNew4D8DC5 => 'What\'s new';

  @override
  String get uiSERVERLESSSECUREMESSENGER1E1891 =>
      '◢ SERVERLESS SECURE MESSENGER';

  @override
  String uiYourMatrixSessionValueWants580E45(String value) {
    return 'Your Matrix session $value wants to verify this one. Accept only if you started it.';
  }

  @override
  String uiValueWantsToVerifyYou61FD9D(String value) {
    return '$value wants to verify you, comparing emojis. Check the whole address: look-alike ones exist. Accept only if you can compare with them in person or on a call; verifying marks their keys as trusted.';
  }

  @override
  String uiCouldNotVerifyValue3AE1C4(String value) {
    return 'Could not verify: $value';
  }

  @override
  String get uiSendWithoutResumableCopy0475F4 => 'Send without resumable copy?';

  @override
  String uiValueCouldNotBeCopied06F61A(
    String value,
    String value2,
    String value3,
  ) {
    return '$value could not be copied into private transfer storage.\n\n$value2\n\nThe app can read the original file directly, but the transfer cannot resume after restart if that file moves or its permission expires.$value3';
  }

  @override
  String get uiUnmute7044C3 => 'Unmute';

  @override
  String get uiMute0F0973 => 'Mute';

  @override
  String get uiSpeakerOn93982E => 'Speaker on';

  @override
  String get uiSpeakerOff97823A => 'Speaker off';

  @override
  String get uiCancelCallCE6C16 => 'Cancel call';

  @override
  String uiValueValueReturnToCall49F82C(String value, String value2) {
    return '$value$value2 · Return to call';
  }

  @override
  String get uiContactDetailsD4EC65 => 'Contact details';

  @override
  String uiValueActiveMemberValue6700F2(String value, String value2) {
    return '$value active member$value2';
  }

  @override
  String get uiOwner89FF31 => 'Owner';

  @override
  String uiEditValue75BE00(String value) {
    return 'Edit $value';
  }

  @override
  String uiCouldNotSaveChatSettings2372B2(String value) {
    return 'Could not save chat settings: $value';
  }

  @override
  String get uiAddAContactToStart165431 =>
      'Add a contact to start a conversation';

  @override
  String get uiNoContactsFound816015 => 'No contacts found';

  @override
  String uiOpenValue8DF02B(String value) {
    return 'Open #$value';
  }

  @override
  String get uiNoMessagesYetC04921 => 'No messages yet';

  @override
  String get uiNoActivityYetPairA7F5366 =>
      'No activity yet — pair a contact to start the log.';

  @override
  String get uiSENT5AD0CD => 'SENT';

  @override
  String get uiRECVBFC296 => 'RECV';

  @override
  String uiDeviceValue11AEA9(String value) {
    return 'device $value';
  }

  @override
  String get uiFreeForAllLocalChat5485CC =>
      'Free-for-all local chat • untrusted';

  @override
  String get uiGroupsAE9629 => 'Groups';

  @override
  String get uiAddTrustedContactsBeforeCreating1084CC =>
      'Add trusted contacts before creating a group.';

  @override
  String get uiNoGroupsYet5009C6 => 'No groups yet.';

  @override
  String uiValueMemberSE75249(String value) {
    return '$value member(s)';
  }

  @override
  String get uiContactsB0DD61 => 'Contacts';

  @override
  String get uiAppliesToFutureAdmissionsHistory78E3A0 =>
      'Applies to future admissions. History already received cannot be withdrawn.';

  @override
  String uiValueAllRetainedHistory5E25F4(String value) {
    return '${value}All retained history';
  }

  @override
  String uiValueSinceAdmissionB2617B(String value) {
    return '${value}Since admission';
  }

  @override
  String uiDeleteValueF0396B(String value) {
    return 'Delete \"$value\"';
  }

  @override
  String uiDeleteValueForEveryone12E724(String value) {
    return 'Delete \"$value\" for everyone?';
  }

  @override
  String uiValueMemberSOwnerValueE42E13(String value, String value2) {
    return '$value member(s) • owner $value2';
  }

  @override
  String get uiGROUPTRUSTFANOUTMintPaired5DDF6E =>
      '// GROUP TRUST FANOUT · mint = paired';

  @override
  String get uiAddTrustedContact126717 => 'Add trusted contact';

  @override
  String get uiNoAvailableChats1FAA40 => 'No available chats';

  @override
  String get uiForwardedMessageQueuedC82DA4 => 'Forwarded message queued';

  @override
  String uiCouldNotForwardValue80193D(String value) {
    return 'Could not forward: $value';
  }

  @override
  String get uiForwardedAttachmentQueued57C88B => 'Forwarded attachment queued';

  @override
  String uiCouldNotForwardAttachmentValue5165FD(String value) {
    return 'Could not forward attachment: $value';
  }

  @override
  String get uiChatDetails15DAEC => 'Chat details';

  @override
  String get uiConnectionDetailsAB30A5 => 'Connection details';

  @override
  String uiValueValue270519(String value, String value2) {
    return '$value / $value2';
  }

  @override
  String uiVoiceMessageValue2F0300(String value) {
    return 'Voice message · $value';
  }

  @override
  String uiPlaybackFailedValue1C0E1A(String value) {
    return 'Playback failed: $value';
  }

  @override
  String get uiPreparingMicrophone0BBF4A => 'Preparing microphone…';

  @override
  String get uiPreparingPreview312E7B => 'Preparing preview…';

  @override
  String uiVoiceMessagePreviewValue8235CB(String value) {
    return 'Voice message preview · $value';
  }

  @override
  String uiRecordingValueValue111FF1(String value, String value2) {
    return 'Recording$value · $value2';
  }

  @override
  String get uiSendingCF7655 => 'Sending…';

  @override
  String uiValue72F816(String value) {
    return '$value×';
  }

  @override
  String get uiSingleChoice68E3E0 => 'Single choice';

  @override
  String get uiMultipleChoiceB88936 => 'Multiple choice';

  @override
  String uiThisRemovesTheMessageFor2247A2(String value) {
    return 'This removes the message for group members when they synchronize.$value';
  }

  @override
  String get uiCouldNotLocateThisMessage220E83 =>
      'Could not locate this message in the current chat';

  @override
  String uiDeleteValueMessageValueForABA7AC(String value, String value2) {
    return 'Delete $value message$value2 for the group?';
  }

  @override
  String uiValueValue29C8B9(String value, String value2) {
    return '$value $value2';
  }

  @override
  String get uiNewC2A6B0 => 'new';

  @override
  String get uiEditedA22FCA => 'edited';

  @override
  String get uiCopyCachePathC23134 => 'Copy cache path';

  @override
  String get uiStopKeepingOfflineAABFC7 => 'Stop keeping offline';

  @override
  String get uiKeepOffline123286 => 'Keep offline';

  @override
  String get uiForwardFileC4B5CB => 'Forward file';

  @override
  String get uiLoadingHistory02CB12 => 'Loading history…';

  @override
  String get uiLoadOlderMessages07471F => 'Load older messages';

  @override
  String get uiShareFileNow96E2A2 => 'Share file now';

  @override
  String get uiScheduleFile690A92 => 'Schedule file';

  @override
  String get uiDropToShareThisFile0B73E8 =>
      'Drop to share this file with the group';

  @override
  String get uiClosed88D86B => 'Closed';

  @override
  String get uiVisibleVotes460E7A => 'Visible votes';

  @override
  String uiValueVoteSWereNot02CC9A(String value) {
    return '$value vote(s) were not in the creator’s close checkpoint.';
  }

  @override
  String get uiVotingIsUnavailableWithThis9B92E7 =>
      'Voting is unavailable with this Conest version.';

  @override
  String get uiThisRemovesTheMessageHere61D27C =>
      'This removes the message here and asks the contact to remove their copy if reachable.';

  @override
  String get uiThisRemovesTheMessageFrom6A47E2 =>
      'This removes the message from this device.';

  @override
  String get uiSendViaMatrix3868FE => 'Send via Matrix…';

  @override
  String get uiNotesFilesAndForwardsOnlyB0145F =>
      'Notes, files and forwards, only on this device';

  @override
  String uiValueSafetyValue82C755(String value, String value2) {
    return '$value • safety $value2';
  }

  @override
  String uiDropFilesToSendMax106011(String value) {
    return 'Drop files to send (max $value)';
  }

  @override
  String get uiFreeForAllLocalChatBC90D2 =>
      'Free-for-all local chat. Messages are session-signed but people here are not trusted contacts.';

  @override
  String get uiNoLANLobbyMessagesYetBCDC4B =>
      'No LAN lobby messages yet. Nearby Conest peers will receive messages while they are on this LAN.';

  @override
  String uiValueUntrusted519A32(String value) {
    return '$value • untrusted';
  }

  @override
  String uiRemoveValueF4FE4B(String value) {
    return 'Remove $value?';
  }

  @override
  String get uiAvailablePaths6EE503 => 'Available paths';

  @override
  String get uiRunACheckToMeasure5D76A5 =>
      'Run a check to measure latency, availability, and reachability freshness. Paths are sorted by best direct/LAN route first, then relay fallback.';

  @override
  String get uiNoRouteHintsAreAdvertisedB25540 =>
      'No route hints are advertised for this contact.';

  @override
  String get uiEitherInputIsEnoughOn020B90 =>
      'Either input is enough on its own. Scan or paste a QR invite to trust it directly, or enter only the current codephrase to discover the sender over nearby LAN routes or the configured relay. If automatic exchange fails, the app will suggest asking the other side to add you back or aborting.';

  @override
  String get uiInvitePreview6433A0 => 'Invite preview';

  @override
  String uiValueValueValue98AECE(String value, String value2, String value3) {
    return '$value$value2 • $value3';
  }

  @override
  String get uiShareInviteDBCC1E => 'Share invite';

  @override
  String get uiThisInviteWorksOnlyOnB106B0 =>
      'This invite works only on the same network: no internet route is on. Turn on Iroh relays, a Conest relay or a carrier (Nostr, email) in Settings → Connectivity so contacts can add you from anywhere.';

  @override
  String get uiThisInviteAlsoListsYourEF3A4F =>
      'This invite also lists your routes for blocked networks, which makes it too large for one QR code. Show it as Beam, an animated QR the other camera reads in a few seconds.';

  @override
  String get uiQRRenderingIsDeferredOn8A6997 =>
      'QR rendering is deferred on Windows.';

  @override
  String get uiUseTheCodephraseBelowOrB6A588 =>
      'Use the codephrase below, or render the QR after this page is open.';

  @override
  String get uiScanningTheCompactQRIs9459D9 =>
      'Scanning the compact QR is enough on its own. If the camera still struggles, open it full screen or use only the current codephrase.';

  @override
  String uiQRPayloadValueCharactersBABEDF(String value) {
    return 'QR payload: $value characters';
  }

  @override
  String uiAlsoListsYourAddressesOnC5D815(String value) {
    return 'Also lists your addresses on: $value.';
  }

  @override
  String uiPinnedValue834309(String value) {
    return 'Pinned · $value';
  }

  @override
  String get uiNoVerifiedCiContactsAre3FD190 =>
      'No verified ci6 contacts are available yet.';

  @override
  String get uiCloseUpTransferE6BA46 => 'Close-up transfer';

  @override
  String get uiALoopingLTFountainStream840218 =>
      'A looping LT fountain stream survives missed, duplicate, and out-of-order QR frames. The final file is hash-checked before you can accept it.';

  @override
  String get uiPUBLICVisibleToAnyoneNearbyA775C2 =>
      'PUBLIC · visible to anyone nearby';

  @override
  String get uiCONTACTENCRYPTED879896 => 'CONTACT ENCRYPTED';

  @override
  String get uiSIGNEDCONTACTINVITE752317 => 'SIGNED CONTACT INVITE';

  @override
  String uiFrameValueValueSourceBlocks9C37CB(
    String value,
    String value2,
    String value3,
  ) {
    return 'Frame $value · $value2 source blocks · $value3';
  }

  @override
  String get uiPointThisCameraAtThe2EA3F7 =>
      'Point this camera at the animated Beam QR. Only decoded cb1 frames leave the native scanner.';

  @override
  String get uiNativeDesktopCameraCaptureIs4619C8 =>
      'Native desktop camera capture is unavailable. Paste cb1 frames below; the protocol decoder and verification path are identical.';

  @override
  String uiValueValueBlocksValueFrames66F819(
    String value,
    String value2,
    String value3,
    String value4,
  ) {
    return '$value/$value2 blocks · $value3 frames · $value4 invalid';
  }

  @override
  String get uiSignedContactInviteA7CC8B => 'Signed contact invite';

  @override
  String get uiPUBLICUNTRUSTEDTheSignatureProves96FA7F =>
      'PUBLIC / UNTRUSTED. The signature proves that all frames came from one key; it does not prove who owns that key.';

  @override
  String get uiEncryptedAndAuthenticatedAsA68B7E4 =>
      'Encrypted and authenticated as a pinned Conest contact.';

  @override
  String get uiSignatureValidCompareTheFingerprintA8A1FE =>
      'Signature valid. Compare the fingerprint in person.';

  @override
  String get uiAcceptAndSavePublicFile852517 => 'Accept and save public file';

  @override
  String get uiSaveFileBEDC84 => 'Save file';

  @override
  String get uiFullscreenCompactInviteQRCF6B8B =>
      'Fullscreen compact invite QR';

  @override
  String uiValueCharactersIncreaseScreenBrightnessA5AF7D(String value) {
    return '$value characters. Increase screen brightness if scanning is unreliable.';
  }

  @override
  String get uiPersonalPreferencesBD0D61 => 'Personal / Preferences';

  @override
  String get uiNetworkRelay4F9A27 => 'Network / Relay';

  @override
  String get uiDanger58D175 => 'Danger';

  @override
  String get uiAllowsOneToOneIroh45EEF1 =>
      'Allows one-to-one Iroh voice calls on this device. Turn off to stop placing and receiving calls.';

  @override
  String get uiPrivacyOfFilesYouSend4E4A5B => 'Privacy of files you send';

  @override
  String get uiLowA12494 => 'Low';

  @override
  String get uiMediumD40496 => 'Medium';

  @override
  String get uiHighB1A595 => 'High';

  @override
  String get uiTransportPolicy088D79 => 'Transport policy';

  @override
  String get uiPerContactRoutingIsIntersected88E292 =>
      'Per-contact routing is intersected with these flags. Turning off either restricts traffic; turning off both makes the app idle.';

  @override
  String get uiConnectivityIsFullyOffTheB12483 =>
      'Connectivity is fully off — the app will not send or receive.';

  @override
  String uiValueCandidateRouteSAre175673(String value) {
    return '$value candidate route(s) are available right now.';
  }

  @override
  String get uiConfiguredRelays3CA0DE => 'Configured relays';

  @override
  String get uiNoRelaysAddedYetF791E7 => 'No relays added yet.';

  @override
  String uiCurrentBuildValueValue9A675D(String value, String value2) {
    return 'Current build: $value • $value2';
  }

  @override
  String uiCommitValue2E080C(String value) {
    return 'commit $value';
  }

  @override
  String uiAvailableValue4B15F7(String value) {
    return 'Available: $value';
  }

  @override
  String get uiChecking494D0F => 'Checking...';

  @override
  String get uiCheckForUpdates8604FF => 'Check for Updates';

  @override
  String uiTrustNewIdentityForValue8B0612(String value) {
    return 'Trust new identity for $value?';
  }

  @override
  String uiTheRelayIsNowSigningFF71FD(String value) {
    return 'The relay is now signing with a different Ed25519 public key ($value). Only continue if the operator has confirmed they rotated the key — otherwise this could be a man-in-the-middle.';
  }

  @override
  String get uiRelayIdentityChanged097638 => 'Relay identity changed';

  @override
  String get uiAConfiguredRelayIsSigning60EED0 =>
      'A configured relay is signing with a new key. Verify with the operator before trusting it.';

  @override
  String uiValueValue66746D(String value, String value2) {
    return '$value → $value2';
  }

  @override
  String get uiNoPendingContactRequests697615 => 'No pending contact requests';

  @override
  String uiCouldNotReviewRequestValue82B3D5(String value) {
    return 'Could not review request: $value';
  }

  @override
  String uiAddValueF034EE(String value) {
    return 'Add $value?';
  }

  @override
  String uiCouldNotAddContactValue7F6C38(String value) {
    return 'Could not add contact: $value';
  }

  @override
  String uiCouldNotRejectRequestValue2EFD58(String value) {
    return 'Could not reject request: $value';
  }

  @override
  String get uiContactRequestRejected447EE8 => 'Contact request rejected.';

  @override
  String uiContactRequestFromValue50B6AC(String value) {
    return 'Contact request from $value';
  }

  @override
  String uiUnverifiedValueC1937C(String value) {
    return 'Unverified · $value';
  }

  @override
  String uiContactRequestFailedValue28DD81(String value) {
    return 'Contact request failed: $value';
  }

  @override
  String get uiRequestAgain7B0434 => 'Request again';

  @override
  String uiTrustValueAsAFresh7BF87F(String value, String value2) {
    return 'Trust $value as a fresh contact? Verify the safety number out of band first — accepting now archives any previous \"$value2\" entries as read-only.';
  }

  @override
  String uiTrustThisAsAReinstallCBA4CC(String value) {
    return 'Trust this as a reinstall of \"$value\"? The previous contact will be archived (history kept read-only); the new contact takes over. This cannot be undone.';
  }

  @override
  String uiConfirmFailedValueBDE200(String value) {
    return 'Confirm failed: $value';
  }

  @override
  String uiRejectFailedValue5F5917(String value) {
    return 'Reject failed: $value';
  }

  @override
  String uiThisContactMayBeAD1405D(String value) {
    return 'This contact may be a reset of \"$value\". Verify their safety number out of band before exchanging messages.';
  }

  @override
  String uiImportedRelaysFromValue37C175(String value) {
    return 'Imported relays from $value.';
  }

  @override
  String uiImportFailedValueBAFB4A(String value) {
    return 'Import failed: $value';
  }

  @override
  String uiThisWillRemoveValueRelay330EEB(String value, String value2) {
    return 'This will remove $value relay route(s) imported from $value2.';
  }

  @override
  String uiRemoveFailedValue58F348(String value) {
    return 'Remove failed: $value';
  }

  @override
  String get uiImportedRelayListsB0BD8B => 'Imported relay lists';

  @override
  String get uiNoImportedLists6CBC34 => 'No imported lists.';

  @override
  String uiValueValueValueRouteS40FB98(
    String value,
    String value2,
    String value3,
  ) {
    return '$value · $value2 · $value3 route(s)';
  }

  @override
  String get uiLeaveBlankToImportUnsigned0D354E =>
      'Leave blank to import unsigned (untrusted; pre-flight probes still gate use). Provide the operator\'s key for cryptographically trusted imports — the signature is fetched from <URL>.ed25519.sig.';

  @override
  String uiValueF7CD86(String value) {
    return '// $value';
  }

  @override
  String get uiThemeA797E3 => 'Theme';

  @override
  String get uiAdaptiveIsUsingSystemDynamicBAA149 =>
      'Adaptive is using system dynamic colors.';

  @override
  String get uiMintAndPinkRemainTheC846F3 =>
      'Mint and pink remain the Conest fallback accents.';

  @override
  String get uiDecoration2DB87A => 'Decoration';

  @override
  String get uiAmbientGridScanlinesCornerReticles45D5C5 =>
      'Ambient grid, scanlines, corner reticles and the status readout. Clean ↔ full atmosphere.';

  @override
  String get uiShellBDC1FD => 'Shell';

  @override
  String get uiHomeLayoutE19685 => 'Home layout';

  @override
  String uiCONESTCiValue7964DC(String value) {
    return 'CONEST · ci5 · $value';
  }

  @override
  String get uiQRUnavailable12869A => 'QR unavailable';

  @override
  String get uiUseTheCodephraseOrPayload187111 =>
      'Use the codephrase or payload below.';

  @override
  String uiTwoWayConfirmedValueE5A1A1(String value) {
    return 'two-way confirmed$value';
  }

  @override
  String uiPathAcceptsSendWaitingFor10B4B0(String value) {
    return 'path accepts send; waiting for peer reply$value';
  }

  @override
  String get uiUnavailable1D5EE3 => 'unavailable';

  @override
  String get uiUsable829A7C => 'usable';

  @override
  String get uiOneWay5EF4D0 => 'one-way';

  @override
  String get uiSkipC7E168 => 'skip';

  @override
  String get uiShareYourInviteThenEither5FEF78 =>
      'Share your invite, then either scan the QR code or enter only the current codephrase on the other device to add the contact.';

  @override
  String get uiStartWithOneTrustedContact650B80 =>
      'Start with one trusted contact';

  @override
  String get uiThisReleasePairsThroughA883AA2 =>
      'This release pairs through a QR invite alone or through a codephrase alone, prefers nearby LAN routes, and falls back to internet relay routes after that.';

  @override
  String get uiConnectivityIsOffEnableLAN39990E =>
      'Connectivity is off. Enable LAN or Online in Settings.';

  @override
  String get uiAutomaticAC9041 => 'Automatic';

  @override
  String get uiPreferred0A3E0D => 'Preferred';

  @override
  String get uiDisabledF4F447 => 'Disabled';

  @override
  String get uiAskFirst1AEB84 => 'Ask first';

  @override
  String get uiRetryFailed7B6CA4 => 'Retry failed';

  @override
  String get uiCancelAlbumDB0A07 => 'Cancel album';

  @override
  String get uiDeleteAlbum52E30F => 'Delete album';

  @override
  String uiValueSelectedB1DFAF(String value) {
    return '$value selected';
  }

  @override
  String uiThisWillCancelValueActiveB3425E(String value, String value2) {
    return 'This will cancel $value active transfer$value2 and clear the transfer list. Chat messages and completed downloaded files will stay.';
  }

  @override
  String get uiNoTransfersYetB8E5C1 => 'No transfers yet.';

  @override
  String get uiAttachmentMetadataUnavailableE2C31D =>
      'Attachment metadata unavailable';

  @override
  String uiValueMBPreparingDownload799D4A(String value) {
    return '$value MB · preparing download…';
  }

  @override
  String uiValueMBDirectRouteRequired6379F0(String value) {
    return '$value MB · direct route required';
  }

  @override
  String uiValueMBTapToDownload432280(String value) {
    return '$value MB · tap to download';
  }

  @override
  String get uiPreparingDownload8CB769 => 'Preparing download…';

  @override
  String uiTransferringValueValue10EEBE(String value, String value2) {
    return 'Transferring · $value% · $value2';
  }

  @override
  String uiTransferringValue9D7F13(String value) {
    return 'Transferring · $value';
  }

  @override
  String get uiVoiceMessage999DEB => 'Voice message';

  @override
  String get uiSendAsMedia061D87 => 'Send as media';

  @override
  String get uiSendAsFileB50EAF => 'Send as file';

  @override
  String get uiMEDIAB85FA2 => 'MEDIA';

  @override
  String get uiFILEB4915D => 'FILE';

  @override
  String get uiPausedByPeer63BD05 => 'Paused by peer';

  @override
  String get uiCouldNotDecodeThisImage3EAA16 => 'Could not decode this image.';

  @override
  String uiValueValueValueDAEE95(String value, String value2, String value3) {
    return '$value  ·  $value2/$value3';
  }

  @override
  String uiValueCannotBeReachedOver14E8C2(String value, String value2) {
    return '$value cannot be reached over Conest right now. Send this message to $value2 as an ordinary Matrix message instead?\n\nIt goes to your Matrix direct chat with them, not through Conest encryption: the homeserver can read it unless that chat is encrypted. Conest stops trying to deliver it.';
  }

  @override
  String uiValueF69855(String value) {
    return '+$value';
  }

  @override
  String uiCouldNotPlayThisVideoF7D318(String value) {
    return 'Could not play this video: $value';
  }

  @override
  String get uiYouLeft9F2CDB => 'You left';

  @override
  String uiReplyingToValue645786(String value) {
    return 'Replying to $value';
  }

  @override
  String get uiNoScheduledMessages1DDB60 => 'No scheduled messages';

  @override
  String get uiScheduledAttachment08DB0E => 'Scheduled attachment';

  @override
  String uiValueValueValue209DD2(String value, String value2, String value3) {
    return '$value • $value2\n$value3';
  }

  @override
  String get uiSendNowDAE330 => 'Send now';

  @override
  String get uiReschedule34B2DC => 'Reschedule';

  @override
  String get uiShareTextTo7B5086 => 'Share text to…';

  @override
  String uiShareValueTo6E3BDD(String value) {
    return 'Share $value to…';
  }

  @override
  String uiShareValueFilesToA46E17(String value) {
    return 'Share $value files to…';
  }

  @override
  String get uiIfMessagesAndFilesFrom3DED27 =>
      'If messages and files from a phone on the same network never arrive (but yours reach it), Windows Firewall is blocking them. This lets other devices on any network reach Conest on this PC; Windows asks to confirm.';

  @override
  String get uiServerRefusedSignOut66337B => 'Server refused sign-out';

  @override
  String get uiServerNotReached62FED2 => 'Server not reached';

  @override
  String uiThisServerDoesNotLet9EEC1F(String value) {
    return 'This server does not let Conest end its session ($value). It may manage sessions on its own account page.\n\nSign out on this device anyway? Then remove the Conest session from your account page or another Matrix app.';
  }

  @override
  String uiConestCouldNotSignThis3C1074(String value) {
    return 'Conest could not sign this device out on the server ($value).\n\nSign out on this device anyway? The session stays valid on the server until you remove it from another Matrix app.';
  }

  @override
  String get uiEnabledDF174A => 'Enabled';

  @override
  String get uiYourEncryptedMatrixHistoryIsC16CD2 =>
      'Your encrypted Matrix history is already backed up. Use \"Enter recovery key\" on a new device.';

  @override
  String get uiThisAccountAlreadyHasA0CF3D8 =>
      'This account already has a recovery key. Use \"Enter recovery key\" or \"Verify with another session\" to unlock your encrypted history on this device.';

  @override
  String uiMatrixValueED6C29(String value) {
    return 'Matrix: $value';
  }

  @override
  String uiValueValueB5F18A(String value, String value2) {
    return '$value$value2';
  }

  @override
  String get uiMatrixFallbackAA082C => 'Matrix fallback';

  @override
  String get uiMatrixAccountD69140 => 'Matrix account';

  @override
  String get uiAccountsThatSignInThrough64868A =>
      'Accounts that sign in through Google, GitHub or another provider, or through matrix.org, use the browser.';

  @override
  String uiThisAccountIsOnValueB78C80(String value) {
    return 'This account is on $value devices.';
  }

  @override
  String get uiUseConestOnMoreThanD2AA6A =>
      'Use Conest on more than one device: link a phone, tablet or computer to this account. Your contacts see one person.';

  @override
  String get uiThisDeviceWasLinkedLess2E5122 =>
      'This device was linked less than a day ago, so it cannot add or remove devices yet.';

  @override
  String get uiPauseSyncingWithADevice89642E =>
      'Pause syncing with a device out of touch for';

  @override
  String uiValueDaysEE919A(String value) {
    return '$value days';
  }

  @override
  String get uiChatsFromOtherNetworks13CDCD => 'Chats from other networks';

  @override
  String uiShowValueChatsInTheBC0E41(String value) {
    return 'Show $value chats in the chat list';
  }

  @override
  String get uiChatWithDeltaChatUsers3B8607 =>
      'Chat with Delta Chat users through your email account. Set up Email above first.';

  @override
  String uiChatWithDeltaChatUsersABD3F5(String value) {
    return 'Chat with Delta Chat users as $value, one to one and in groups. End-to-end encrypted (OpenPGP, without forward secrecy); the mail servers see who writes to whom and when.';
  }

  @override
  String get uiNoDeltaChatChatsYetF4C538 =>
      'No Delta Chat chats yet. Share your invite, or join with someone\'s.';

  @override
  String uiRequestValueE6C033(String value) {
    return 'Request: $value';
  }

  @override
  String get uiNobodyToAddYetStart0983BB =>
      'Nobody to add yet: start a chat first. You can share the group\'s invite once it exists.';

  @override
  String get uiVerifiedEC734B => 'verified';

  @override
  String uiAddValueF546E5(String value) {
    return 'Add $value';
  }

  @override
  String get uiChatDeleted73DC61 => 'Chat deleted';

  @override
  String get uiLeaveGroup925789 => 'Leave group';

  @override
  String get uiWaitingForTheInviteTo1C712D =>
      'Waiting for the invite to be answered; this can take a minute.';

  @override
  String get uiEncryptedWithOpenPGPDeltaChat9C6326 =>
      'Encrypted with OpenPGP (Delta Chat), without forward secrecy. The mail servers see who writes to whom and when.';

  @override
  String get uiARequestFromSomeoneYouAE0967 =>
      'A request from someone you have not chatted with. Replying accepts it.';

  @override
  String get uiReadA7AFDD => 'read';

  @override
  String get uiNotSentBE2B9D => 'not sent';

  @override
  String get uiCouldNotJoinTheCall252D45 =>
      'Could not join the call. Check your route or leave the current call.';

  @override
  String uiCallInValue16F998(String value) {
    return 'Call in $value';
  }

  @override
  String uiValueStartedACallIn278E96(String value, String value2) {
    return '$value started a call in $value2';
  }

  @override
  String get uiReturn24F096 => 'Return';

  @override
  String get uiCouldNotUpdateTheCall33517D => 'Could not update the call.';

  @override
  String get uiVoiceCallB8499D => 'Voice call';

  @override
  String uiCallViaValue0A68E8(String value) {
    return 'Call via $value';
  }

  @override
  String uiValueYouEFED9A(String value) {
    return '$value (you)';
  }

  @override
  String get uiTalkingC34D84 => 'Talking…';

  @override
  String get uiHoldToTalkSpace869505 => 'Hold to talk · Space';

  @override
  String uiVoiceCallValueBD3141(String value) {
    return 'Voice call · $value';
  }

  @override
  String uiStartedByValueValueParticipants99F03D(String value, String value2) {
    return 'Started by $value · $value2 participants';
  }

  @override
  String get uiNodeRnsd0D8EEC => 'Node (rnsd)';

  @override
  String get uiRNodeOnUSBF00220 => 'RNode on USB';

  @override
  String get uiRNodeOnBluetooth13657D => 'RNode on Bluetooth';

  @override
  String get uiRNodeOnWiFiC18593 => 'RNode on Wi-Fi';

  @override
  String get uiScanForRadios2B185E => 'Scan for radios';

  @override
  String get uiUseTheSameFrequencyBandwidthFC1A9F =>
      'Use the same frequency, bandwidth and spreading factor as the Reticulum network the radio joins.';

  @override
  String get uiAppMode2965FD => 'App mode';

  @override
  String get uiBoth1F4698 => 'Both';

  @override
  String uiCouldNotStartTheChatAE2F54(String value) {
    return 'Could not start the chat: $value';
  }

  @override
  String uiMessagesAreEndToEndE786B5(String value) {
    return 'Messages are end-to-end encrypted, but your homeserver and theirs see who talks to whom and when. Verify $value to be sure it is them.';
  }

  @override
  String get uiThisChatIsNotEncrypted799D99 =>
      'This chat is not encrypted: your homeserver and theirs can read it.';

  @override
  String get uiLoading33CE41 => 'Loading…';

  @override
  String get uiLoadEarlierMessages4AC08D => 'Load earlier messages';

  @override
  String get uiEditing3B9BA1 => 'Editing';

  @override
  String uiReplyToValueValue666B4E(String value, String value2) {
    return 'Reply to $value: $value2';
  }

  @override
  String get uiYouWereInvitedToThisE30D1E =>
      'You were invited to this Matrix chat.';

  @override
  String get uiEdited0E3C32 => 'edited · ';

  @override
  String get uiUnableToDecryptThisMessage8A31CC =>
      'Unable to decrypt this message yet';

  @override
  String get uiUnsupportedMessage9E48EB => 'Unsupported message';

  @override
  String uiImageUnavailableValueB024FC(String value) {
    return 'Image unavailable: $value';
  }

  @override
  String uiDownloadFailedValueB18BB6(String value) {
    return 'Download failed: $value';
  }

  @override
  String get uiFile2C3CAF => 'File';

  @override
  String uiValueKiBEC48AF(String value) {
    return '$value KiB';
  }

  @override
  String get uiCODEPHRASEE2C724 => 'CODEPHRASE';

  @override
  String uiROTATESINValueS5745B8(String value) {
    return 'ROTATES IN ${value}s';
  }

  @override
  String get uiROUTEINSPECTOR321AA4 => 'ROUTE INSPECTOR';

  @override
  String get uiLIVE67B40B => '● LIVE';

  @override
  String uiValueChatsAD9A3B(String value) {
    return '$value chats';
  }

  @override
  String uiValueValue167E51(String value, String value2) {
    return '$value ($value2)';
  }

  @override
  String get uiNotDeliveredTheirRadioCould75D581 =>
      'not delivered (their radio could not read it)';

  @override
  String get uiSenderNotVerified2BB0FA => 'sender not verified';

  @override
  String get uiYouAreHidden56DCC1 => 'You are hidden';

  @override
  String get uiYouReadTheMeshChatAEACC5 =>
      'You read the mesh chat, but bitchat users cannot see you or write to you. Turn on \"Reachable by bitchat users\" in Settings → Connectivity to write.';

  @override
  String get uiEveryoneNearbyOverBluetooth7B8D63 =>
      'Everyone nearby, over Bluetooth';

  @override
  String get uiNoBitchatUsersNearbyYetD30471 => 'No bitchat users nearby yet';

  @override
  String get uiPhonesInBluetoothRangeThatDCCC0D =>
      'Phones in Bluetooth range that announce themselves show up here.';

  @override
  String get uiNearbyF1536C => 'Nearby';

  @override
  String get uiEveryoneInBluetoothRangeReadsA7628A =>
      'Everyone in Bluetooth range reads this chat, and anyone can relay it. Messages are signed, not encrypted.';

  @override
  String get uiEncryptedBetweenTheTwoPhones3871C4 =>
      'Encrypted between the two phones (bitchat\'s Noise), with forward secrecy only while you are both nearby.';

  @override
  String get uiThisChatWasWithAn0507F9 =>
      'This chat was with an earlier bitchat identity of yours. Writing now tells them your new one is the same person.';

  @override
  String uiValueValue64C067(String value, String value2) {
    return '$value#$value2';
  }

  @override
  String get uiVerifyThisSessionB5065C => 'Verify this session';

  @override
  String get uiBluetoothMeshOn5A96FE => 'Bluetooth mesh on';

  @override
  String get uiStartingBluetoothE6928A => 'Starting Bluetooth';

  @override
  String get uiBluetoothUnavailableF4B751 => 'Bluetooth unavailable';

  @override
  String uiBitchatUsersNearbySeeYou1B54FC(String value) {
    return 'bitchat users nearby see you as \"$value\" while you are in range, and can write to you. The identity they see is new every week and has nothing to do with your Conest identity.';
  }

  @override
  String get uiOffBitchatUsersDoNot054F9A =>
      'Off: bitchat users do not see this phone. You can still read the mesh chat.';

  @override
  String uiPhonesNearbyWithoutInternetCan27CC7F(String value) {
    return 'Phones nearby without internet can use bitchat\'s location channels through this phone. Only those public, signed messages pass. This phone connects to the relays of the areas they use$value: those relays see your internet address and the area, so they can tell roughly where you are.';
  }

  @override
  String get uiOffBitchatUsersNearbyWithout030CFB =>
      'Off: bitchat users nearby without internet cannot reach location channels through you.';

  @override
  String uiValueNearbyTheMeshChat31C0CA(String value) {
    return '$value nearby · the mesh chat and private chats';
  }

  @override
  String get uiSignInToYourMatrix8D0037 => 'Sign in to your Matrix account';

  @override
  String get uiNoRoomsFoundAD2C3E => 'No rooms found';

  @override
  String get uiMatrixInvitation525106 => 'Matrix invitation';

  @override
  String get uiEncryptedChat0D7563 => 'Encrypted chat';

  @override
  String get uiChat2CED57 => 'Chat';

  @override
  String get uiNoNostrChatsYet0A95D0 => 'No Nostr chats yet';

  @override
  String get uiEncryptedOnNostrNIPRelaysA51F70 =>
      'Encrypted on Nostr (NIP-17); relays see neither who wrote nor when. No forward secrecy.';

  @override
  String get uiTestingRoutes19C586 => 'Testing routes…';

  @override
  String get uiTestRoutes52770A => 'Test Routes';

  @override
  String get uiCheckingWhetherTheirAppCan51E401 =>
      'Checking whether their app can take route tests…';

  @override
  String get uiTheirAppDidNotSay758036 =>
      'Their app did not say it can take route tests. If they run this version too, they may not be reachable right now.';

  @override
  String get uiNoRouteTookTheTestF2F6CB => 'No route took the test.';

  @override
  String uiTestedValueRoutesThatAnswer70B842(String value) {
    return 'Tested $value. Routes that answer go first for messages.';
  }

  @override
  String get uiUSB09716C => 'USB';

  @override
  String get uiCopiedTheErrorHistoryCE02E2 => 'Copied the error history.';

  @override
  String get uiNothingRecordedA27006 => 'Nothing recorded.';

  @override
  String uiValueValue1C180E(String value, String value2) {
    return '$value  ·  $value2';
  }

  @override
  String uiValueValueValueValue56C1C1(
    String value,
    String value2,
    String value3,
    String value4,
  ) {
    return '$value: $value2 $value3$value4';
  }

  @override
  String uiRouteValue9D8426(String value) {
    return 'Route: $value';
  }

  @override
  String uiValueValue7B4608(String value, String value2) {
    return '$value · !$value2';
  }

  @override
  String get uiNetwork53EBC5 => 'Network';

  @override
  String uiImageIsLargerThanTheEE56C5(String value) {
    return 'Image is larger than the $value MB cap.';
  }

  @override
  String uiFileIsLargerThanTheAF488F(String value) {
    return 'File is larger than the $value MB cap.';
  }

  @override
  String uiSendValueBF4C3C(String value) {
    return 'Send $value';
  }

  @override
  String get uiRecent76EEC7 => 'Recent';

  @override
  String get uiConestSeesOnlyThePhotosEE1926 =>
      'Conest sees only the photos you picked.';

  @override
  String get uiPhotosPermissionDeniedUseBrowseD672EE =>
      'Photos permission denied. Use \"Browse files…\" to send any file, or grant access in system settings.';

  @override
  String get uiNoPhotosOrVideosHereC729D1 => 'No photos or videos here.';

  @override
  String get uiCouldNotDecodeTheImage69AC9D =>
      'Could not decode the image to rotate it.';

  @override
  String uiRotationFailedValue176CC6(String value) {
    return 'Rotation failed: $value';
  }

  @override
  String uiValueOfValueVerified63B11D(String value, String value2) {
    return '$value of $value2 verified';
  }

  @override
  String get uiPointTheCameraAtA9BAFAF =>
      'Point the camera at a Conest invite QR code.';
}

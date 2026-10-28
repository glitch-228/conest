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
  String get uiPassphrase89950C => 'گذرواژه';

  @override
  String get uiConfirmPassphraseEBAAC0 => 'تأیید گذرواژه';

  @override
  String get uiUnlock1526A1 => 'باز کردن قفل';

  @override
  String get uiUpdateAvailable67FD3A => 'به‌روزرسانی موجود است';

  @override
  String get uiLater56E2F5 => 'بعداً';

  @override
  String get uiHostAutoDetectsTCPUDP663D30 =>
      'میزبان TCP/UDP را خودکار تشخیص می‌دهد؛ udp://host:port استفاده از UDP را اجباری می‌کند';

  @override
  String get uiVerificationRequestDA06F9 => 'درخواست تأیید';

  @override
  String get uiIgnore98F55D => 'نادیده گرفتن';

  @override
  String get uiVerifyDDA6AC => 'تأیید';

  @override
  String uiCouldNotReadValueValue695755(String value, String value2) {
    return 'خواندن $value ممکن نشد: $value2';
  }

  @override
  String uiCouldNotShareValueValue7BA3A3(String value, String value2) {
    return 'اشتراک‌گذاری $value ممکن نشد: $value2';
  }

  @override
  String uiCouldNotSaveSidebarWidthB4DACB(String value) {
    return 'ذخیرهٔ پهنای نوار کناری ممکن نشد: $value';
  }

  @override
  String get uiNoAudioOutputDevicesWere17E473 =>
      'هیچ دستگاه خروجی صدا پیدا نشد.';

  @override
  String get uiCallAudioOutput0C276F => 'خروجی صدای تماس';

  @override
  String uiCallAudioRoutedToValueFFFBE8(String value) {
    return 'صدای تماس به $value هدایت شد.';
  }

  @override
  String uiCouldNotChangeCallAudio6CE7B1(String value) {
    return 'تغییر خروجی صدای تماس ممکن نشد: $value';
  }

  @override
  String uiCouldNotOpenInviteValue6C4D06(String value) {
    return 'باز کردن دعوت ممکن نشد: $value';
  }

  @override
  String uiCouldNotSendAttachmentValueEFF771(String value) {
    return 'ارسال پیوست ممکن نشد: $value';
  }

  @override
  String uiCouldNotSendMessageValue042C4F(String value) {
    return 'ارسال پیام ممکن نشد: $value';
  }

  @override
  String get uiSendFromOriginalFFF29A => 'ارسال از فایل اصلی';

  @override
  String uiCouldNotSendGroupMessageB6C7D1(String value) {
    return 'ارسال پیام گروه ممکن نشد: $value';
  }

  @override
  String uiCouldNotSendLANLobby8E7487(String value) {
    return 'ارسال پیام گفت‌وگوی محلی ممکن نشد: $value';
  }

  @override
  String uiCouldNotStageValuePathless514094(String value) {
    return 'آماده‌سازی $value ممکن نشد: برای محافظت از حافظه، فایل‌های رهاشدهٔ بدون مسیر به ۸ MB محدودند.';
  }

  @override
  String get uiSelectAGroupBeforeDropping9DAB4C =>
      'پیش از رها کردن فایل‌ها، گروهی را انتخاب کنید.';

  @override
  String uiValueLocalFilePathUnavailable217177(String value) {
    return '$value: مسیر فایل محلی در دسترس نیست.';
  }

  @override
  String uiValueSentWithoutIt7E0635(String value) {
    return '$value بدون آن ارسال شد.';
  }

  @override
  String get uiGroupFileScheduledB1DC66 => 'فایل گروه زمان‌بندی شد.';

  @override
  String uiCouldNotScheduleValueValue25CED3(String value, String value2) {
    return 'زمان‌بندی $value ممکن نشد: $value2';
  }

  @override
  String uiCouldNotOpenFilePicker8FF0C0(String value) {
    return 'باز کردن انتخابگر فایل ممکن نشد: $value';
  }

  @override
  String uiValuePickerReturnedNoData4670CA(String value) {
    return '$value: انتخابگر داده‌ای برنگرداند.';
  }

  @override
  String uiOnlyTheFirstValueFiles45FC47(String value, String value2) {
    return 'فقط $value فایل نخست آماده می‌شوند ($value2 فایل دریافت شد).';
  }

  @override
  String uiValueSkippedValueMBExceeds487B2A(String value, String value2) {
    return 'از $value گذشتیم: حجم $value2 MB از سقف $value MB بیشتر است.';
  }

  @override
  String get uiTransfers812412 => 'انتقال‌ها';

  @override
  String uiValue75CED7(String value) {
    return '$value';
  }

  @override
  String get uiPreparingCallE86D6C => 'در حال آماده‌سازی تماس…';

  @override
  String get uiCallingACD4A6 => 'در حال تماس…';

  @override
  String get uiIncomingVoiceCallF68FD3 => 'تماس صوتی ورودی';

  @override
  String get uiConnectingFD3E79 => 'در حال اتصال…';

  @override
  String get uiReconnecting8A8B95 => 'در حال اتصال دوباره…';

  @override
  String get uiCallEnded9933A4 => 'تماس پایان یافت';

  @override
  String uiVoiceCallValue06FE1F(String value) {
    return 'تماس صوتی: $value';
  }

  @override
  String get uiMinimizeCall6CB0F0 => 'کوچک کردن تماس';

  @override
  String get uiAcceptBB54DB => 'پذیرش';

  @override
  String get uiReject2B03B5 => 'رد کردن';

  @override
  String get uiNoiseSuppression71DE3C => 'کاهش نویز';

  @override
  String get uiAudioOutput2B89CC => 'خروجی صدا';

  @override
  String get uiDoneE9B450 => 'تمام';

  @override
  String get uiHangUp66BE99 => 'پایان تماس';

  @override
  String get uiCloseDetails433DA6 => 'بستن جزئیات';

  @override
  String get uiOpenFullProfile35063C => 'باز کردن نمایهٔ کامل';

  @override
  String get uiOpenGroupSettings0B568E => 'باز کردن تنظیمات گروه';

  @override
  String get uiNewFolderA71199 => 'پوشهٔ تازه';

  @override
  String get uiFolderNameB2CE02 => 'نام پوشه';

  @override
  String get uiMoveEarlier07DD6F => 'انتقال به قبل';

  @override
  String get uiMoveLaterBB4C84 => 'انتقال به بعد';

  @override
  String get uiSaveEFC007 => 'ذخیره';

  @override
  String get uiAddToFolderBFAD96 => 'افزودن به پوشه';

  @override
  String get uiNewMessage1ED2E7 => 'پیام تازه';

  @override
  String get uiBackToChats8DE6F6 => 'بازگشت به گفت‌وگوها';

  @override
  String get uiNavigationMenu6609F1 => 'منوی پیمایش';

  @override
  String get uiAllChats398E5B => 'همهٔ گفت‌وگوها';

  @override
  String get uiSearchAllChatsC825C8 => 'جست‌وجو در همهٔ گفت‌وگوها';

  @override
  String get uiClearSearch67300D => 'پاک کردن جست‌وجو';

  @override
  String get uiContactRequests082691 => 'درخواست‌های ارتباط';

  @override
  String get uiReviewPeopleWhoWantTo24A8CB =>
      'بررسی افرادی که می‌خواهند ارتباط بگیرند';

  @override
  String get uiNoChatsFoundC6BD82 => 'گفت‌وگویی پیدا نشد';

  @override
  String get uiNoArchivedChatsEAE7F0 => 'گفت‌وگوی بایگانی‌شده‌ای نیست';

  @override
  String get uiNoMatrixChatsYet23B023 => 'هنوز گفت‌وگوی Matrix ندارید';

  @override
  String get uiNewGroupF9850C => 'گروه تازه';

  @override
  String get uiAddWithConestBeam19D1E2 => 'افزودن با Conest Beam';

  @override
  String get uiDirectMessagesE7596A => 'پیام‌های مستقیم';

  @override
  String get uiConestBeamE98B77 => 'Conest Beam';

  @override
  String get uiMyInviteF80A7A => 'دعوت من';

  @override
  String get uiGroupDetailsDF844A => 'جزئیات گروه';

  @override
  String get uiDebugBD604D => 'اشکال‌زدایی';

  @override
  String get uiAdd61CC55 => 'افزودن';

  @override
  String get uiPollRoutesNow22318F => 'بررسی مسیرها اکنون';

  @override
  String get uiContactProfile1B3A0E => 'نمایهٔ مخاطب';

  @override
  String get uiHistoryForNewMembersF419F2 => 'تاریخچه برای اعضای تازه';

  @override
  String get uiChooseHowToWindDownF7399D =>
      'روش پایان دادن به این گروه را انتخاب کنید. انتقال مالکیت، گروه را با مالک تازه نگه می‌دارد و شما مدیر می‌شوید. حذف برای همه، گروه را از فهرست همهٔ اعضا پاک می‌کند و برگشت‌پذیر نیست.';

  @override
  String get uiTransferOwnershipA563C9 => 'انتقال مالکیت…';

  @override
  String get uiDeleteForEveryoneE055A8 => 'حذف برای همه';

  @override
  String get uiNoOtherActiveMembersToF9DE12 =>
      'عضو فعال دیگری برای انتقال مالکیت وجود ندارد.';

  @override
  String get uiTransferOwnershipA6819E => 'انتقال مالکیت';

  @override
  String get uiTransferCBB4CC => 'انتقال';

  @override
  String uiOwnershipTransferredToValue14A10D(String value) {
    return 'مالکیت به $value منتقل شد.';
  }

  @override
  String get uiEveryMemberWillBeRemoved75A3FC =>
      'همهٔ اعضا حذف می‌شوند و گروه در فهرست هر عضو ترک‌شده نشان داده می‌شود. تاریخچهٔ محلی پیام‌ها خودکار پاک نمی‌شود؛ هر عضو می‌تواند آن را با «حذف از فهرست» پاک کند. این کار برگشت‌پذیر نیست.';

  @override
  String get uiRemoveThisGroup38C4E8 => 'این گروه حذف شود؟';

  @override
  String get uiRemoveThisGroupFromYourDA7898 =>
      'این گروه از فهرست شما حذف شود؟ تاریخچهٔ محلی پیام‌ها پاک می‌شود. دیگر اعضا مطلع نمی‌شوند؛ آن‌ها پیش‌تر خروج شما را دیده‌اند.';

  @override
  String get uiRemoveE96390 => 'حذف';

  @override
  String get uiChangeRole2B9BFD => 'تغییر نقش';

  @override
  String get uiRemoveMember1C31D1 => 'حذف عضو';

  @override
  String get uiChooseWhatFutureMembersCanC38992 =>
      'انتخاب کنید اعضای آینده چه تاریخچه‌ای را دریافت کنند';

  @override
  String get uiAddMember170AD0 => 'افزودن عضو';

  @override
  String get uiDeleteGroup043336 => 'حذف گروه…';

  @override
  String get uiLeave7E3520 => 'خروج';

  @override
  String get uiRemoveFromList23A976 => 'حذف از فهرست';

  @override
  String get uiForwardMessage482959 => 'بازفرست پیام';

  @override
  String get uiSavedMessagesC0FA7E => 'پیام‌های ذخیره‌شده';

  @override
  String get uiThisAttachmentIsNotAvailableFE641A =>
      'این پیوست هنوز به‌صورت محلی در دسترس نیست.';

  @override
  String get uiDownloadThisFileBeforeForwarding60D7B5 =>
      'پیش از بازفرستادن، این فایل را بارگیری کنید.';

  @override
  String get uiSearchMessagesABEA65 => 'جست‌وجوی پیام‌ها';

  @override
  String get uiStartVoiceCallExperimental6DE320 => 'شروع تماس صوتی (آزمایشی)';

  @override
  String get uiChatOptionsA40D0F => 'گزینه‌های گفت‌وگو';

  @override
  String get uiPausePreview805180 => 'مکث پیش‌نمایش';

  @override
  String get uiPlayPreview47BB44 => 'پخش پیش‌نمایش';

  @override
  String get uiUnmutePreview12A31A => 'وصل صدای پیش‌نمایش';

  @override
  String get uiMutePreviewCE44BD => 'قطع صدای پیش‌نمایش';

  @override
  String get uiPauseVoiceMessageECD12D => 'مکث پیام صوتی';

  @override
  String get uiPlayVoiceMessageB16684 => 'پخش پیام صوتی';

  @override
  String get uiPlaybackSpeed6FF42B => 'سرعت پخش';

  @override
  String get uiStopRecordingEE0D9D => 'توقف ضبط';

  @override
  String get uiDeleteRecording8B58CE => 'حذف ضبط';

  @override
  String uiCouldNotLoadOlderGroup1A192E(String value) {
    return 'بارگذاری تاریخچهٔ قدیمی‌تر گروه ممکن نشد: $value';
  }

  @override
  String uiMessageScheduledForValueD2D788(String value) {
    return 'پیام برای $value زمان‌بندی شد.';
  }

  @override
  String get uiNewPoll6D62BD => 'نظرسنجی تازه';

  @override
  String get uiQuestion002FF5 => 'پرسش';

  @override
  String get uiOptionsOnePerLine62FF3D => 'گزینه‌ها (هرکدام در یک خط)';

  @override
  String get uiDeleteMessageD536CF => 'پیام حذف شود؟';

  @override
  String get uiDeleteSelectedMessages190A5F => 'پیام‌های انتخاب‌شده حذف شوند؟';

  @override
  String uiDeleteFailedForOneMessage26C302(String value) {
    return 'حذف یک پیام ناموفق بود: $value';
  }

  @override
  String get uiNothingToCopyFromTheEC27E3 =>
      'چیزی برای کپی از پیام‌های انتخاب‌شده نیست.';

  @override
  String uiCopiedValueMessageSC97E6E(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value پیام کپی شد.',
      one: '$value پیام کپی شد.',
    );
    return '$_temp0';
  }

  @override
  String get uiNoSelectedAttachmentIsReady536B54 =>
      'هیچ پیوست انتخاب‌شده‌ای آماده نیست؛ انتقال ادامه دارد.';

  @override
  String get uiCopiedMessageText9DC18F => 'متن پیام کپی شد.';

  @override
  String get uiTheGroupFileIsNotF8A236 =>
      'فایل گروه به‌صورت محلی در دسترس نیست.';

  @override
  String uiSavedValue0463E5(String value) {
    return '$value ذخیره شد.';
  }

  @override
  String uiCouldNotSaveValueValue178005(String value, String value2) {
    return 'ذخیرهٔ $value ممکن نشد: $value2';
  }

  @override
  String get uiTheAndroidFileSaverIsDF910B =>
      'ذخیره‌کنندهٔ فایل Android در دسترس نیست.';

  @override
  String get uiOpeningFilesIsUnavailableOnC6ADA2 =>
      'باز کردن فایل در این سکو ممکن نیست.';

  @override
  String uiCouldNotOpenValueValue283326(String value, String value2) {
    return 'باز کردن $value ممکن نشد: $value2';
  }

  @override
  String get uiYou905CB3 => 'شما';

  @override
  String get uiMessage68F414 => 'پیام';

  @override
  String get uiMessageActions949184 => 'عملیات پیام';

  @override
  String get uiTheAttachmentIsStillDownloadingF77317 =>
      'بارگیری پیوست هنوز ادامه دارد.';

  @override
  String get uiShareOrScheduleAGroup2989F0 =>
      'اشتراک‌گذاری یا زمان‌بندی فایل گروه';

  @override
  String get uiRecordingBelongsToAnotherConversation87E802 =>
      'ضبط متعلق به گفت‌وگوی دیگری است';

  @override
  String get uiFinishTheVoicePreviewIn142571 =>
      'پیش‌نمایش صوت را در گفت‌وگوی اصلی آن تمام کنید';

  @override
  String get uiReviewUnsentVoiceMessage24931C => 'بررسی پیام صوتی ارسال‌نشده';

  @override
  String get uiCancelMicrophoneStartup9E9F8A => 'لغو راه‌اندازی میکروفن';

  @override
  String get uiReleaseToDiscardRecording4C5C71 =>
      'برای دور انداختن ضبط رها کنید';

  @override
  String get uiRecordingLockedTapToFinish40CD88 =>
      'ضبط قفل شده · برای پایان بزنید';

  @override
  String get uiReleaseToStopSlideLeft4686F1 =>
      'برای توقف رها کنید · برای لغو به چپ بکشید · برای قفل به بالا بکشید';

  @override
  String get uiHoldToRecordAGroupC11B32 => 'برای ضبط پیام صوتی گروه نگه دارید';

  @override
  String get uiCreatePoll8F5663 => 'ساخت نظرسنجی';

  @override
  String get uiWriteToGroup5878DB => 'نوشتن در گروه';

  @override
  String get uiWriteAReply0A58E1 => 'نوشتن پاسخ';

  @override
  String get uiYouAreNoLongerIn571DA7 => 'دیگر عضو این گروه نیستید';

  @override
  String get uiVote64F872 => 'رأی دادن';

  @override
  String get uiChooseOptionsEA120E => 'انتخاب گزینه‌ها';

  @override
  String get uiRetractVoteA5DA11 => 'پس گرفتن رأی';

  @override
  String get uiClosePollA6A189 => 'بستن نظرسنجی';

  @override
  String get uiScheduleOneAttachmentAtAC580C3 =>
      'هر بار یک پیوست را زمان‌بندی کنید.';

  @override
  String get uiNotDeliveredYetSendViaF056E1 =>
      'هنوز تحویل نشده. ارسال از Matrix…';

  @override
  String get uiVoiceCallsAreTurnedOff692843 =>
      'تماس صوتی خاموش است. برای تماس آن را در تنظیمات روشن کنید.';

  @override
  String get uiVoiceCallAudioIsUnavailable0B6C43 =>
      'صدای تماس در این نسخه در دسترس نیست.';

  @override
  String get uiRouteInspector0E65DE => 'بازرس مسیر';

  @override
  String get uiThisContactRequestIsBlocked944F7D =>
      'این درخواست ارتباط مسدود شده است.';

  @override
  String get uiMessageSavedHereUntilTheA49A2C =>
      'پیام تا پذیرش مخاطب اینجا ذخیره می‌شود.';

  @override
  String get uiWriteAnEncryptedMessage9F7705 => 'نوشتن پیام رمزگذاری‌شده';

  @override
  String get uiWriteAReplyOrAddFC0A42 => 'نوشتن پاسخ یا افزودن شرح';

  @override
  String get uiHoldToRecordAVoice06B1B5 => 'برای ضبط پیام صوتی نگه دارید';

  @override
  String get uiWriteToNearbyLANUsers291142 =>
      'نوشتن به کاربران نزدیک شبکهٔ محلی';

  @override
  String get uiBroadcast77CA3F => 'پخش همگانی';

  @override
  String get uiThisRemovesTheLocalContact0D6D1E =>
      'مخاطب و تاریخچهٔ پیام محلی حذف می‌شود. برنامه تلاش می‌کند اعلان حذف هم بفرستد تا این ارتباط در دستگاه طرف مقابل نیز حذف شود.';

  @override
  String get uiDescriptionBio505243 => 'توضیح / دربارهٔ من';

  @override
  String get uiCheckPaths917FF3 => 'بررسی مسیرها';

  @override
  String get uiCopyState9BFD16 => 'کپی وضعیت';

  @override
  String get uiRemoveContact7F9A8A => 'حذف مخاطب';

  @override
  String get uiSaveProfile909BF3 => 'ذخیرهٔ نمایه';

  @override
  String get uiShowAsBeam74375F => 'نمایش با Beam';

  @override
  String get uiShowTheQRAnyway0B0CDF => 'با این حال نمایش QR';

  @override
  String get uiOpenFullscreenQRC5418D => 'نمایش QR تمام‌صفحه';

  @override
  String get uiShowQRCFBAC6 => 'نمایش QR';

  @override
  String get uiLegacyInviteC61C5D => 'دعوت قدیمی';

  @override
  String get uiForContactsOnConestOr486754 =>
      'برای مخاطبان دارای Conest 0.3.11 یا قدیمی‌تر. مسیرهای شبکه‌های مسدود شما در آن نیست؛ پس از اتصال می‌رسند.';

  @override
  String get uiRotateCodephraseNow89B2D5 => 'تغییر عبارت اتصال اکنون';

  @override
  String get uiEncryptForContactE07450 => 'رمزگذاری برای مخاطب';

  @override
  String get uiPublicOpticalTransfer58E3F4 => 'انتقال نوری عمومی';

  @override
  String get uiAnyoneWhoCanSeeTheFAB2D0 =>
      'هر کس نمایشگر را ببیند می‌تواند این فایل را بازسازی کند. برای بررسی یکپارچگی امضا شده، اما محرمانه نیست.';

  @override
  String get uiChoosePublicFile6E2739 => 'انتخاب فایل عمومی';

  @override
  String get uiKeepThisScreenVisibleUntil2261B8 =>
      'این صفحه را تا اعلام دریافت ۱۰۰٪ باز نگه دارید.';

  @override
  String get uiReceiveConestBeamB05BCB => 'دریافت Conest Beam';

  @override
  String get uiDesktopCameraActiveDA0F15 => 'دوربین رایانه فعال است';

  @override
  String get uiPasteOneCbFrame66EA2B => 'چسباندن یک فریم cb1';

  @override
  String get uiAddFrame2BBA30 => 'افزودن فریم';

  @override
  String get uiContactAliasE07C25 => 'نام مستعار مخاطب';

  @override
  String get uiWeComparedThisFingerprintIn952BEB =>
      'این اثر انگشت را حضوری مقایسه کردیم';

  @override
  String get uiTrustAndAddContact0962A2 => 'اعتماد و افزودن مخاطب';

  @override
  String get uiSavedInPrivateConestStorage4C1334 =>
      'در فضای خصوصی Conest ذخیره شد:';

  @override
  String get uiResetIdentity8B0224 => 'بازنشانی هویت';

  @override
  String get uiThisClearsTheEncryptedVault864B3D =>
      'این کار گاوصندوق رمزگذاری‌شده، مخاطبان و پیام‌ها را پاک می‌کند و برنامه را به حالت نخستین اجرا برمی‌گرداند.';

  @override
  String get uiReset44C57A => 'بازنشانی';

  @override
  String get uiNoIdentityIsActive6B2EE3 => 'هیچ هویتی فعال نیست.';

  @override
  String get uiSaveNameE73831 => 'ذخیرهٔ نام';

  @override
  String get uiSaveBioBE2711 => 'ذخیرهٔ دربارهٔ من';

  @override
  String get uiMessageNotifications595635 => 'اعلان‌های پیام';

  @override
  String get uiShowASystemNotificationWhen90113B =>
      'هنگام دریافت پیام مستقیم، اعلان سیستم نشان داده شود.';

  @override
  String get uiExperimentalVoiceCalls51098B => 'تماس صوتی آزمایشی';

  @override
  String get uiExperimentalAndroidBackgroundReceive60828A =>
      'دریافت پس‌زمینهٔ آزمایشی در Android';

  @override
  String get uiDisabledInReleaseBuildsThe45B7DF =>
      'در نسخه‌های انتشار غیرفعال است: سرویس پیش‌زمینه هنوز دریافت‌کنندهٔ بی‌واسط Flutter را اجرا نمی‌کند.';

  @override
  String get uiAllowVoiceCallsInBackground73C5C5 =>
      'اجازهٔ تماس صوتی در پس‌زمینه';

  @override
  String get uiKeepsCallSignalingActiveAndC0A342 =>
      'تا وقتی سرویس Conest اجراست، سیگنال‌دهی تماس را فعال نگه می‌دارد و اعلان تماس نشان می‌دهد. به تماس صوتی آزمایشی نیاز دارد؛ سیاست باتری Android یا توقف اجباری همچنان می‌تواند دسترسی را قطع کند.';

  @override
  String get uiDonTSendReadConfirmations230076 => 'تأیید خواندن فرستاده نشود';

  @override
  String get uiDebugOnlyDeliveryAcknowledgementsStill7D6A9C =>
      'فقط برای اشکال‌زدایی. تأیید تحویل همچنان ارسال و تأییدهای خواندن دریافتی پردازش می‌شوند.';

  @override
  String get uiRemoveMetadataFromFilesA4860E => 'حذف فرادادهٔ فایل‌ها';

  @override
  String get uiBeforeSendingRemovesLocationCamera4E390D =>
      'پیش از ارسال، اطلاعات مکان، دوربین، نویسنده و تاریخ را از عکس، ویدیو، PDF و اسناد اداری حذف می‌کند. تصاویر دوباره فشرده نمی‌شوند. دیگر فایل‌ها بدون تغییر ارسال می‌شوند.';

  @override
  String get uiSendFilesUnderRandomNames5F79D4 => 'ارسال فایل‌ها با نام تصادفی';

  @override
  String get uiReplacesFileNamesWithRandom16F099 =>
      'برای شما و گیرنده، نام فایل‌ها را با حروف تصادفی جایگزین می‌کند؛ پسوند مانند .jpg باقی می‌ماند.';

  @override
  String get uiKeepOfStorageFreeF00434 => '۱۰٪ فضای ذخیره‌سازی خالی بماند';

  @override
  String get uiReserveFreeSpaceForOther1AC9CF =>
      'فضای خالی برای برنامه‌های دیگر نگه می‌دارد. در حالت خاموش انتقال‌ها می‌توانند از این فضا استفاده کنند، ولی همچنان باید در دیسک جا شوند.';

  @override
  String get uiLAN2ECD17 => 'LAN';

  @override
  String get uiSameNetworkListenerPairingBeacons5CF0A2 =>
      'دریافت در شبکهٔ مشترک، اعلان جفت‌سازی و تحویل محلی.';

  @override
  String get uiOnlineC3E839 => 'آنلاین';

  @override
  String get uiIrohMessagingAndFileTransfersC4D635 =>
      'پیام‌رسانی و انتقال فایل Iroh از اینترنت. رله‌های سفارشی Conest اختیاری‌اند.';

  @override
  String get uiIrohRelayFallbackE954F7 => 'مسیر جایگزین رلهٔ Iroh';

  @override
  String get uiUseIrohSBuiltIn631E03 =>
      'وقتی اتصال مستقیم ممکن نیست، از رله‌های داخلی Iroh برای پیام و فایل استفاده شود. هر دو طرف باید آنلاین باشند.';

  @override
  String get uiLimitIrohFilesToMiBB58353 =>
      'محدود کردن فایل‌های Iroh به ۱۰۰ MiB (پیشنهادی)';

  @override
  String get uiAppliesToDirectOnlineAnd28F6F1 =>
      'برای انتقال مستقیم آنلاین و رلهٔ Iroh است. برای فایل بزرگ‌تر خاموش کنید؛ ممکن است زمان زیادی ببرد. سقف بزرگ‌تر انتقال محلی باقی می‌ماند.';

  @override
  String get uiShareEmailAndMatrixAddressesD762EE =>
      'اشتراک نشانی ایمیل و Matrix با اعضای گروه';

  @override
  String get uiLetsMembersOfYourGroups9912A5 =>
      'به اعضای گروه که مخاطب شما نیستند امکان تماس با ایمیل یا Matrix می‌دهد. در حالت خاموش فقط نشانی‌های Nostr، Tor و رادیو را می‌گیرند که نام شما را نشان نمی‌دهند. خاموش کردن، اشتراک‌های آینده را متوقف می‌کند؛ نشانی دیده‌شده ممکن است نزد اعضا بماند.';

  @override
  String get uiAutomaticDownloads5E777B => 'بارگیری خودکار';

  @override
  String get uiVerifiedContactsOnlyLimitsAdapt8A1876 =>
      'فقط مخاطبان تأییدشده. سقف‌ها با Wi-Fi/Ethernet، دادهٔ همراه و رومینگ سازگار می‌شوند.';

  @override
  String get uiCustomIrohRelayURLsDBF979 => 'نشانی‌های رلهٔ سفارشی Iroh';

  @override
  String get uiOneHTTPSURLPerLineDA8E70 =>
      'هر خط یک نشانی HTTPS؛ خالی یعنی مجموعهٔ پیش‌فرض رله‌های N0.';

  @override
  String get uiSaveIrohRelaysC144AD => 'ذخیرهٔ رله‌های Iroh';

  @override
  String get uiCheckAvailabilityFCC1A6 => 'بررسی دسترسی';

  @override
  String get uiRunThisDeviceAsA9DEA14 => 'اجرای این دستگاه به‌عنوان رله';

  @override
  String get uiAllowTrustedContactsToUse001771 =>
      'به مخاطبان مورد اعتماد اجازه دهید از این دستگاه به‌عنوان رله استفاده کنند.';

  @override
  String get uiAutoUseContactsAsRelaysC62C06 =>
      'استفادهٔ خودکار از مخاطبان به‌عنوان رله';

  @override
  String get uiLocalRelayPort28A73C => 'درگاه رلهٔ محلی';

  @override
  String get uiSavePort1876F6 => 'ذخیرهٔ درگاه';

  @override
  String get uiRelayHostURLF11441 => 'میزبان / نشانی رله';

  @override
  String get uiRelayPortEA05DA => 'درگاه رله';

  @override
  String get uiDetectAddRelayE825AD => 'یافتن و افزودن رله';

  @override
  String get uiErrorHistory25AFF8 => 'تاریخچهٔ خطا';

  @override
  String get uiWhatWentWrongKeptAcross27FC1F =>
      'خطاها در این نسخه پس از راه‌اندازی دوباره نگه داشته می‌شوند تا برای گزارش اشکال کپی کنید.';

  @override
  String get uiReceiveUnstableUpdatesBF7122 => 'دریافت به‌روزرسانی ناپایدار';

  @override
  String get uiAlsoOfferNightlyBuildsNewerA7FAB0 =>
      'نسخه‌های شبانه را هم پیشنهاد می‌دهد: قابلیت تازه‌تر با آزمون کمتر. نسخهٔ پایدار جدیدتر همیشه پیشنهاد می‌شود.';

  @override
  String get uiResetAppIdentity2E0F86 => 'بازنشانی هویت برنامه';

  @override
  String get uiTrustNewKeyA181BE => 'اعتماد به کلید تازه';

  @override
  String get uiVerifyThePersonAndCompare738F28 =>
      'پیش از پذیرش، شخص را تأیید و شمارهٔ ایمنی را از راه دیگری مقایسه کنید.';

  @override
  String get uiReviewE29A79 => 'بررسی';

  @override
  String get uiDiscardChat319267 => 'دور انداختن گفت‌وگو';

  @override
  String get uiConfirmIdentityReplacement0219C5 => 'جایگزینی هویت تأیید شود؟';

  @override
  String get uiItSThem394960 => 'خود اوست';

  @override
  String get uiRejectThisIdentityCB604F => 'این هویت رد شود؟';

  @override
  String get uiThisDeletesTheNewContactBB4444 =>
      'مخاطب تازه و پیام‌های دریافتی نگه‌داشته‌شده حذف می‌شوند. اگر به جعل هویت مشکوکید از این گزینه استفاده کنید.';

  @override
  String get uiNotThem685593 => 'او نیست';

  @override
  String get uiRemoveImportedList36FC81 => 'فهرست واردشده حذف شود؟';

  @override
  String get uiNoBundledConestRelaysOnline46529B =>
      'رلهٔ Conest همراه برنامه نیست. اتصال‌های آنلاین از Iroh استفاده می‌کنند؛ رلهٔ خودتان را هم می‌توانید تنظیم کنید.';

  @override
  String get uiImportFromURL3F7B77 => 'وارد کردن از نشانی…';

  @override
  String get uiImportRelayListFromURL86E363 => 'وارد کردن فهرست رله از نشانی';

  @override
  String get uiJSONURL6918BA => 'نشانی JSON';

  @override
  String get uiOperatorSPublicKeyOptionalA80E7A =>
      'کلید عمومی گرداننده (اختیاری، base64)';

  @override
  String get uiImportD6FBC9 => 'وارد کردن';

  @override
  String get uiCLEAN2F3D27 => 'ساده';

  @override
  String get uiSUBTLEBB048B => 'ملایم';

  @override
  String get uiDEFAULTC18920 => 'پیش‌فرض';

  @override
  String get uiFULLCC0A74 => 'کامل';

  @override
  String get uiLANFirstB360D1 => 'نخست شبکهٔ محلی';

  @override
  String get uiLANOnly94945D => 'فقط شبکهٔ محلی';

  @override
  String get uiOnlineFirst346B6D => 'نخست آنلاین';

  @override
  String get uiOnlineOnlyF79CB9 => 'فقط آنلاین';

  @override
  String get uiOfflineE01FA7 => 'آفلاین';

  @override
  String get uiUsesLANWhenAvailableFallsA810EF =>
      'اگر ممکن باشد از شبکهٔ محلی وگرنه از اینترنت استفاده می‌کند.';

  @override
  String get uiUsesLANOnlyNoRelay589D55 =>
      'فقط شبکهٔ محلی. برای این مخاطب ترافیک رله‌ای نیست.';

  @override
  String get uiUsesOnlineWhenAvailableFallsCE2CAF =>
      'اگر ممکن باشد از اینترنت وگرنه از شبکهٔ محلی استفاده می‌کند.';

  @override
  String get uiUsesOnlineOnlyNoLAN193810 =>
      'فقط آنلاین. برای این مخاطب ترافیک شبکهٔ محلی نیست.';

  @override
  String get uiNoTransportSelectedThisContact7969EB =>
      'هیچ مسیر انتقالی انتخاب نشده؛ مخاطب در دسترس نیست.';

  @override
  String get uiGlobalConnectivityIsOffAdjustA7C644 =>
      'اتصال کلی خاموش است؛ برای ارسال تنظیمات را تغییر دهید.';

  @override
  String get uiSameNetworkDelivery94E793 => 'تحویل در شبکهٔ مشترک';

  @override
  String get uiDisabledByGlobalSetting2CB06C => 'با تنظیم سراسری غیرفعال است';

  @override
  String get uiAllowIrohRelayFallback35227B => 'اجازهٔ مسیر جایگزین رلهٔ Iroh';

  @override
  String get uiVisibleAndOnlineOnlyDirectEA8902 =>
      'قابل مشاهده و فقط آنلاین؛ اتصال مستقیم Iroh ترجیح دارد.';

  @override
  String get uiRelayInternetDeliveryD64AB6 => 'تحویل با رله / اینترنت';

  @override
  String get uiPrefer13F662 => 'ترجیح';

  @override
  String get uiCarryTheirMessages22FD33 => 'انتقال پیام‌های او';

  @override
  String get uiWhenThisContactCannotReach5C3FF8 =>
      'اگر این مخاطب به کسی دسترسی ندارد ولی دستگاه شما دارد، پیام‌هایش را منتقل کنید. فقط گیرنده و زمان را می‌بینید؛ محتوا رمزگذاری‌شده می‌ماند.';

  @override
  String uiSaveValueFileSToB46C57(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'ذخیرهٔ $value فایل در…',
      one: 'ذخیرهٔ $value فایل در…',
    );
    return '$_temp0';
  }

  @override
  String get uiSaveCanceled1939D0 => 'ذخیره لغو شد.';

  @override
  String get uiAlbumActions7B6D70 => 'عملیات آلبوم';

  @override
  String get uiCancelSelectionF7F56C => 'لغو انتخاب';

  @override
  String get uiCopyAF74F7 => 'کپی';

  @override
  String get uiSaveAttachments5A74EA => 'ذخیرهٔ پیوست‌ها';

  @override
  String get uiCancelAndClearAllTransfers01B81D =>
      'همهٔ انتقال‌ها لغو و پاک شوند؟';

  @override
  String get uiKeepTransfersDB8CC7 => 'نگه داشتن انتقال‌ها';

  @override
  String get uiCancelAndClearCCF59C => 'لغو و پاک کردن';

  @override
  String get uiPauseAll6F6099 => 'مکث همه';

  @override
  String get uiResumeAll039916 => 'ادامهٔ همه';

  @override
  String get uiCancelAndClearAllTransfersACEBB3 =>
      'لغو و پاک کردن همهٔ انتقال‌ها';

  @override
  String get uiClearCompletedE63FC1 => 'پاک کردن موارد کامل';

  @override
  String get uiMoveToTop44AFA6 => 'انتقال به بالا';

  @override
  String get uiPreparingDownloadF9B13B => 'آماده‌سازی بارگیری';

  @override
  String get uiDownloadA479C9 => 'بارگیری';

  @override
  String get uiResumeB3BD0B => 'ادامه';

  @override
  String get uiPause781961 => 'مکث';

  @override
  String get uiRetry9F5CD8 => 'تلاش دوباره';

  @override
  String get uiContinueOverIrohRelay949702 => 'ادامه با رلهٔ Iroh';

  @override
  String get uiDownloadAnyway42859F => 'با این حال بارگیری شود';

  @override
  String get uiPreparing96A9B7 => 'آماده‌سازی';

  @override
  String get uiQueued6A5998 => 'در صف';

  @override
  String get uiWaiting33D306 => 'در انتظار';

  @override
  String get uiTransferring73F753 => 'در حال انتقال';

  @override
  String get uiReconnecting9D80F9 => 'اتصال دوباره';

  @override
  String get uiPausedC7DFB6 => 'متوقف‌شده';

  @override
  String get uiVerifying536244 => 'در حال بررسی';

  @override
  String get uiComplete1F5A1A => 'کامل';

  @override
  String get uiCanceledF840AC => 'لغوشده';

  @override
  String get uiUnavailable2C9C1F => 'در دسترس نیست';

  @override
  String uiSavedValueToValue08F152(String value, String value2) {
    return '$value در $value2 ذخیره شد.';
  }

  @override
  String uiGallerySaveFailedValueFalling0B82BB(String value) {
    return 'ذخیره در گالری ناموفق بود ($value)؛ از پنجرهٔ ذخیرهٔ فایل استفاده می‌شود.';
  }

  @override
  String uiSaveValue5769AA(String value) {
    return 'ذخیرهٔ $value';
  }

  @override
  String uiSaveFailedValue534182(String value) {
    return 'ذخیره ناموفق بود: $value';
  }

  @override
  String get uiTheAttachmentFileIsNotA67009 =>
      'فایل پیوست به‌صورت محلی در دسترس نیست.';

  @override
  String uiCopiedValueToClipboard669D0B(String value) {
    return '$value در بریده‌دان کپی شد.';
  }

  @override
  String uiCopiedValueTextOnlySystemB51B8D(String value) {
    return '«$value» کپی شد (فقط متن؛ بخش دودویی بریده‌دان سیستم در دسترس نیست).';
  }

  @override
  String uiCopyFailedValueFilenameCopiedF71C87(String value) {
    return 'کپی ناموفق بود: $value. نام فایل به‌جای آن به‌صورت متن کپی شد.';
  }

  @override
  String get uiCachePathIsNotReady0404B5 =>
      'مسیر حافظهٔ نهان هنوز آماده نیست؛ انتقال ادامه دارد.';

  @override
  String uiCachePathCopiedValue4CC1C4(String value) {
    return 'مسیر حافظهٔ نهان کپی شد: $value';
  }

  @override
  String get uiVideoIsnTCachedLocally8920DD =>
      'ویدیو هنوز محلی ذخیره نشده؛ تا پایان انتقال صبر کنید.';

  @override
  String uiCouldNotOpenVideoIn054087(String value) {
    return 'باز کردن ویدیو در پخش‌کنندهٔ سیستم ممکن نشد: $value';
  }

  @override
  String get uiImageIsNotAvailableLocally12017F => 'تصویر محلی در دسترس نیست.';

  @override
  String uiVideoStillTransferringValue3F4049(String value) {
    return 'انتقال ویدیو ادامه دارد ($value٪).';
  }

  @override
  String get uiVoiceMessageBytesAreNotF8339B =>
      'داده‌های پیام صوتی آماده نیست.';

  @override
  String get uiSendMode265A2D => 'حالت ارسال';

  @override
  String get uiLANRelayA05D48 => 'رلهٔ شبکهٔ محلی';

  @override
  String get uiLobbyFDB6D9 => 'لابی';

  @override
  String get uiDirectBC8152 => 'مستقیم';

  @override
  String get uiIroh84642D => 'Iroh';

  @override
  String get uiIrohRelayB128EA => 'رلهٔ Iroh';

  @override
  String get uiRelay9F537F => 'رله';

  @override
  String get uiMatrix58947E => 'Matrix';

  @override
  String get uiPlainMatrixBA9DE1 => 'Matrix عادی';

  @override
  String get uiNostr4D3AD8 => 'Nostr';

  @override
  String get uiEmail84ADD5 => 'ایمیل';

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
  String get uiViaContactCF1F8E => 'از طریق مخاطب';

  @override
  String get uiSendViaMatrix062A08 => 'از Matrix ارسال شود؟';

  @override
  String get uiKeepWaiting9BE1AB => 'ادامهٔ انتظار';

  @override
  String get uiSendViaMatrix638038 => 'ارسال از Matrix';

  @override
  String uiNotSentViaMatrixValue99F62C(String value) {
    return 'از Matrix ارسال نشد: $value';
  }

  @override
  String get uiMessageRoutesFBF32C => 'مسیرهای پیام';

  @override
  String get uiWhatTheColouredMarksOnA10C8E => 'معنای نشانه‌های رنگی پیام‌ها';

  @override
  String get uiOpenInDefaultPlayerE64C20 => 'باز کردن در پخش‌کنندهٔ پیش‌فرض';

  @override
  String get uiCancelReplyBD62D2 => 'لغو پاسخ';

  @override
  String get uiScheduledMessages98CEF4 => 'پیام‌های زمان‌بندی‌شده';

  @override
  String get uiEditScheduledMessage62AF88 => 'ویرایش پیام زمان‌بندی‌شده';

  @override
  String get uiCaption3428D9 => 'شرح';

  @override
  String get uiNoChatsToShareIntoB50F2F =>
      'هنوز گفت‌وگویی برای اشتراک‌گذاری نیست.';

  @override
  String get uiLetDevicesOnThisNetwork42E2F0 =>
      'اجازهٔ دسترسی دستگاه‌های این شبکه به رایانه';

  @override
  String get uiAllow3AD0E3 => 'اجازه';

  @override
  String get uiKeepSignedIn611A13 => 'واردشده بماند';

  @override
  String get uiSignOutHereA6F129 => 'خروج از این دستگاه';

  @override
  String get uiMatrixPassword34E218 => 'گذرواژهٔ Matrix';

  @override
  String get uiPassword8BE3C9 => 'رمز عبور';

  @override
  String get uiYourServerAsksForIt1594FA =>
      'سرور برای ساخت کلیدهای امضا آن را می‌خواهد.';

  @override
  String get uiRecoveryIsAlreadySetUp371F7F => 'بازیابی از پیش تنظیم شده';

  @override
  String get uiOK9CE3BD => 'باشه';

  @override
  String get uiSaveYourRecoveryKey7851B3 => 'کلید بازیابی را ذخیره کنید';

  @override
  String get uiKeepThisKeySomewhereSafe0C0DFE =>
      'این کلید را جای امن نگه دارید. برای خواندن تاریخچهٔ رمزگذاری‌شدهٔ Matrix در دستگاه تازه لازم است. فقط یک‌بار نشان داده می‌شود.';

  @override
  String get uiISavedIt3E2255 => 'ذخیره کردم';

  @override
  String get uiEnterRecoveryKey4521B6 => 'وارد کردن کلید بازیابی';

  @override
  String get uiEsTFromAnotherMatrixAppFCA0C9 =>
      'EsT… (از برنامهٔ Matrix دیگر یا همین برنامه)';

  @override
  String get uiSignOutDC1649 => 'خروج';

  @override
  String get uiSetUpRecoveryFD3804 => 'تنظیم بازیابی';

  @override
  String get uiVerifyWithAnotherSession9ED031 => 'تأیید با نشست دیگر';

  @override
  String get uiShowJoinsLeavesAndProfile9FA764 =>
      'نمایش ورود، خروج و تغییرات نمایه';

  @override
  String get uiInMatrixRoomsCollapsedIntoD20CAB =>
      'در اتاق‌های Matrix در یک خط جمع می‌شوند';

  @override
  String get uiMatrixUser70A560 => 'کاربر Matrix';

  @override
  String get uiForExampleNameMatrixOrg63C60A => 'مثلاً @name:matrix.org';

  @override
  String get uiHomeserverOptional70DF85 => 'سرور خانگی (اختیاری)';

  @override
  String get uiFoundFromTheUserId69A3AB =>
      'اگر خالی باشد از شناسهٔ کاربر پیدا می‌شود';

  @override
  String get uiSignInToMatrix652C8F => 'ورود به Matrix';

  @override
  String get uiSignInWithBrowserC995DF => 'ورود با مرورگر';

  @override
  String get uiFinishSigningInInYour9F41A4 => 'ورود را در مرورگر تمام کنید.';

  @override
  String get uiCopyLink2F84EE => 'کپی پیوند';

  @override
  String get uiThisDeviceFA5A6D => 'این دستگاه';

  @override
  String uiOutOfTouchSinceValueA037FD(String value) {
    return 'از $value بی‌خبر است: تا تأیید نکنید هنوز مال شماست، چیزی همگام نمی‌شود.';
  }

  @override
  String uiLinkedValueDCADF7(String value) {
    return 'پیوندشده $value';
  }

  @override
  String get uiYourContactsWillStopAccepting5B0F03 =>
      'مخاطبان دیگر چیزی از این دستگاه نمی‌پذیرند. نمی‌توان آن را برگرداند؛ دوباره به‌عنوان دستگاه تازه پیوند دهید.';

  @override
  String get uiStillMine38C8AE => 'هنوز مال من است';

  @override
  String get uiRemoveDeviceA9C39D => 'حذف دستگاه';

  @override
  String get uiLinkADeviceE71635 => 'پیوند دستگاه';

  @override
  String get uiLinkThisDeviceToMy888A1A => 'پیوند این دستگاه به حساب من';

  @override
  String get uiCheckThatBothDevicesShow031E51 =>
      'بررسی کنید هر دو دستگاه این کد را نشان دهند:';

  @override
  String get uiTheCodesMatch32C407 => 'کدها یکسان‌اند';

  @override
  String get uiLinkedTheNewDeviceNow9900E5 =>
      'پیوند انجام شد. دستگاه تازه اکنون حساب و مخاطبان شما را دارد؛ مخاطبان آن را به‌عنوان شما می‌بینند.';

  @override
  String get uiConfirmTheCodeOnThe17BB1F =>
      'کد را در دستگاه تازه هم تأیید کنید.';

  @override
  String get uiWaitingForTheNewDevice75283F =>
      'منتظر پاسخ دستگاه تازه هستیم. اگر کدی ظاهر نشد، مطمئن شوید دستگاه تازه همچنان کدش را نشان می‌دهد و هر دو در یک شبکه یا آنلاین‌اند.';

  @override
  String get uiOnTheNewDeviceOpen29AF5E =>
      'در دستگاه تازه، تنظیمات ← دستگاه‌ها ← پیوند این دستگاه به حساب من را باز کنید، سپس کد نمایش‌داده‌شده را اسکن کنید.';

  @override
  String get uiScanCode4596C2 => 'اسکن کد';

  @override
  String get uiOrPasteTheCodeE72792 => 'یا کد را بچسبانید';

  @override
  String get uiLinkThisDeviceBF5E5C => 'پیوند این دستگاه';

  @override
  String get uiThisDeviceIsNowLinked7EA826 =>
      'این دستگاه اکنون به حساب شما پیوند دارد.';

  @override
  String get uiWaitingForTheOtherDeviceB39C3F => 'در انتظار دستگاه دیگر…';

  @override
  String get uiOnTheDeviceYouAlready92C421 =>
      'در دستگاهی که از قبل استفاده می‌کنید، تنظیمات ← دستگاه‌ها ← پیوند دستگاه را باز و این کد را اسکن کنید. هر دو دستگاه باید در یک شبکه یا آنلاین باشند.';

  @override
  String get uiDeltaChat8BDA67 => 'Delta Chat';

  @override
  String get uiBitchatA99B50 => 'bitchat';

  @override
  String get uiWithAFilterOfTheir4FD18E =>
      'با فیلتر جداگانه. در حالت خاموش، فقط از تنظیمات همان شبکه باز می‌شوند.';

  @override
  String get uiYourDeltaChatInviteEE073F => 'دعوت Delta Chat شما';

  @override
  String get uiShowTheQRCodeTo0769AD =>
      'کد QR را به کاربر Delta Chat نشان دهید یا پیوند را بفرستید. هر کس آن را داشته باشد می‌تواند گفت‌وگویی تأییدشده با شما شروع کند.';

  @override
  String get uiShowQRCode2DF2DD => 'نمایش کد QR';

  @override
  String get uiDeltaChatChats8EBCBC => 'گفت‌وگوهای Delta Chat';

  @override
  String get uiGroup171A06 => 'گروه';

  @override
  String get uiJoinWithAnInviteC76024 => 'پیوستن با دعوت';

  @override
  String get uiJoinE0D731 => 'پیوستن';

  @override
  String get uiNewDeltaChatGroup7D5142 => 'گروه تازهٔ Delta Chat';

  @override
  String get uiGroupNameEBB7E1 => 'نام گروه';

  @override
  String get uiMembers1CB449 => 'اعضا';

  @override
  String get uiGroupInviteD64669 => 'دعوت گروه';

  @override
  String get uiYouAreNotInThisCF5BD5 => 'شما عضو این گروه نیستید';

  @override
  String get uiStartGroupCallC2A083 => 'شروع تماس گروهی';

  @override
  String get uiJoinGroupCallC9ECF8 => 'پیوستن به تماس گروهی';

  @override
  String get uiPushToTalk032E78 => 'فشار برای صحبت';

  @override
  String get uiCarryMessagesOverAReticulum1CE915 =>
      'انتقال پیام از شبکهٔ Reticulum، مانند رادیوهای LoRa ‏(RNode) بدون اینترنت، از طریق گرهی که rnsd را با رابط سرور TCP اجرا می‌کند. Conest هویت Reticulum جداگانه دارد؛ مخاطبان آن را خودکار دریافت می‌کنند.';

  @override
  String get uiNodeAddressRnsdCD61E2 => 'نشانی گره (rnsd)';

  @override
  String get uiUSBDeviceB47FF0 => 'دستگاه USB';

  @override
  String get uiRNodeAddress691283 => 'نشانی RNode';

  @override
  String get uiBluetoothAddress0E2BED => 'نشانی Bluetooth';

  @override
  String get uiTCPPortDE05BE => 'درگاه TCP';

  @override
  String get uiEU233558 => 'اروپا 869.525';

  @override
  String get uiUS5ED166 => 'آمریکا 914.875';

  @override
  String get uiUseConestAsAMatrix6A44C5 =>
      'Conest فقط به‌عنوان کارخواه Matrix استفاده شود؟';

  @override
  String get uiYourConestChatsAreHiddenCFD853 =>
      'گفت‌وگوهای Conest پنهان و اتصال آن در این دستگاه تا بازگشت شما متوقف می‌شود. چیزی حذف نمی‌شود. مخاطبان در این مدت با Conest به شما دسترسی ندارند؛ برنامه‌هایشان تلاش می‌کنند و پس از بازگشت شما تحویل می‌دهند.';

  @override
  String get uiSwitch3E44C9 => 'تغییر';

  @override
  String get uiSealAnimatedRings29BE2D => 'مهر (حلقه‌های متحرک)';

  @override
  String get uiSigilRuneA0B8A7 => 'نشان (رون)';

  @override
  String get uiBlockiePixelHashA265BA => 'بلوک پیکسلی (هش)';

  @override
  String get uiMonogramInitials8C6019 => 'حروف آغازین';

  @override
  String get uiNewMatrixChatC065C8 => 'گفت‌وگوی تازهٔ Matrix';

  @override
  String get uiNameMatrixOrgD0BB06 => '@name:matrix.org';

  @override
  String get uiStartChat18BB58 => 'شروع گفت‌وگو';

  @override
  String get uiCopyText06A76C => 'کپی متن';

  @override
  String uiVerifyValue1B6B79(String value) {
    return 'تأیید $value';
  }

  @override
  String get uiAttachAFileAE85E4 => 'پیوست فایل';

  @override
  String get uiMessageDeleted3271A7 => 'پیام حذف شد';

  @override
  String get uiUnableToDecryptFDF88B => 'رمزگشایی ممکن نشد';

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
  String get uiDeclineB59CF9 => 'رد کردن';

  @override
  String get uiCarryMessagesAsEncryptedEmail0D19EA =>
      'وقتی مسیرهای دیگر کار نکنند، پیام‌ها مانند Delta Chat با ایمیل رمزگذاری‌شده منتقل می‌شوند. سرورهای ایمیل هر دو نشانی و زمان را می‌بینند، نه محتوا را. مخاطبان نشانی را خودکار می‌گیرند.';

  @override
  String get uiUseMyOwnEmailAccountE78C1D =>
      'به‌جای آن از حساب ایمیل خودم استفاده کنم';

  @override
  String get uiNostrRelaysBD8BAD => 'رله‌های Nostr';

  @override
  String get uiCarryMessagesThroughPublicNostr729B94 =>
      'وقتی مسیرهای دیگر کار نکنند، پیام از رله‌های عمومی Nostr می‌گذرد. رله‌ها می‌بینند کسی چه وقت به شما می‌نویسد، نه هویت او یا محتوا را. کلید جداگانه‌ای دارد؛ مخاطبان خودکار آن را می‌گیرند.';

  @override
  String get uiRelaysYouReadFromOne020C0A =>
      'رله‌های دریافت (هر خط یکی، حداکثر ۴)';

  @override
  String get uiSaveRelays91CBA8 => 'ذخیرهٔ رله‌ها';

  @override
  String get uiDefaultRelays5C909F => 'رله‌های پیش‌فرض';

  @override
  String get uiNewChat009BF6 => 'گفت‌وگوی تازه';

  @override
  String get uiNodeAddress896F20 => 'نشانی گره';

  @override
  String get uiDeleteChatDB9121 => 'حذف گفت‌وگو';

  @override
  String get uiTurnOnAppMessagesTo7DCA13 =>
      'برای نوشتن پیام‌های برنامه را روشن کنید';

  @override
  String get uiBitchatNearbyD0C416 => 'bitchat نزدیک';

  @override
  String get uiMeshChat7BF668 => 'گفت‌وگوی مش';

  @override
  String get uiHiddenTurnOnReachableBy0103C9 =>
      'پنهان: «دسترسی کاربران bitchat به شما» را روشن کنید';

  @override
  String get uiTheyDonTMatch27EF0C => 'یکسان نیستند';

  @override
  String get uiTheyMatch6FB8EB => 'یکسان‌اند';

  @override
  String get uiNameBitchatUsersSee1CE7E3 => 'نامی که کاربران bitchat می‌بینند';

  @override
  String get uiANameYouChooseStays17E677 =>
      'نام انتخابی شما با تغییر هویت باقی می‌ماند، پس افراد نزدیک می‌فهمند که هنوز خود شما هستید. برای نام تازهٔ \"anon\" با هر هویت، آن را خالی بگذارید.';

  @override
  String get uiBluetoothMeshC8B7F1 => 'شبکهٔ مش Bluetooth';

  @override
  String get uiReachContactsNearbyWithoutAny9E9649 =>
      'بدون هیچ شبکه‌ای با مخاطبان نزدیک ارتباط بگیرید: پیام‌ها با Bluetooth از دستگاهی به دستگاه دیگر، میان کاربران Conest وbitchat می‌روند و این دستگاه هم پیام دیگران را منتقل می‌کند. این دستگاه در bitchat دیده نمی‌شود و پیام‌هایش مانند هر پیام خصوصی bitchat هستند، با شناسه‌هایی که هر ساعت تغییر می‌کنند.';

  @override
  String get uiReachableByBitchatUsers568021 => 'دسترسی کاربران bitchat به شما';

  @override
  String get uiShareInternetWithBitchatUsers572F90 =>
      'اشتراک اینترنت با کاربران bitchat';

  @override
  String get uiChangeNameE46692 => 'تغییر نام';

  @override
  String get uiNewIdentityA119CF => 'هویت جدید';

  @override
  String get uiBitchatChatsC74EC3 => 'گفت‌وگوهای bitchat';

  @override
  String get uiTheMatrixClientIsNot01A5B4 =>
      'کارخواه Matrix در این دستگاه در دسترس نیست؛ Conest نمی‌تواند اینجا در حالت فقط Matrix اجرا شود.';

  @override
  String get uiUseConest12EEF3 => 'استفاده از Conest';

  @override
  String get uiSearchRoomsCCE4F9 => 'جست‌وجوی اتاق‌ها';

  @override
  String get uiReachContactsThroughTorOnion8B8A98 =>
      'با سرویس‌های onion در Tor به مخاطبان برسید: هیچ طرف و نیز شبکه، مکان طرف دیگر را نمی‌فهمد. از مسیرهای دیگر کندتر است؛ اگر Tor مسدود است پل اضافه کنید.';

  @override
  String get uiBridgesOptionalOnePerLine110291 => 'پل‌ها (اختیاری، هر خط یکی)';

  @override
  String get uiEEFEBFE80B7A =>
      '192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413';

  @override
  String get uiObfsEEFEAD0EDF =>
      'obfs4 192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413 cert=… iat-mode=0';

  @override
  String get uiLinesFromBridgesTorprojectOrgF08389 =>
      'خط‌هایی از bridges.torproject.org با نوع آغازین: obfs4، webtunnel، snowflake یا meek_lite (یا پل عادی: نشانی و اثر انگشت).';

  @override
  String get uiPlainBridgesOnlyAddressAnd7F0B60 =>
      'این نسخه فقط پل عادی (نشانی و اثر انگشت) دارد.';

  @override
  String get uiUseTheseBridgesC1FA11 => 'استفاده از این پل‌ها';

  @override
  String get uiNostrPrivateMessagesDF74A3 => 'پیام‌های خصوصی Nostr';

  @override
  String get uiChatWithAnyoneOnNostrA867BC =>
      'با هر کاربر Nostr ‏(0xchat، Amethyst، Damus و دیگر برنامه‌های NIP-17)، دونفره یا در گروه کوچک گفت‌وگو کنید. حساب Nostr جداگانه‌ای دارد که به مخاطبان Conest پیوند ندارد. سرتاسر رمزگذاری شده، اما بدون محرمانگی پیشرو.';

  @override
  String get uiYourNostrAddress5CF7C6 => 'نشانی Nostr شما';

  @override
  String get uiCopyWithYourRelaysD49669 => 'کپی (همراه رله‌های شما)';

  @override
  String get uiNostrChats3D786C => 'گفت‌وگوهای Nostr';

  @override
  String get uiNewNostrChat68199C => 'گفت‌وگوی تازهٔ Nostr';

  @override
  String get uiNpubSeveralForAGroupE6ED77 => 'npub1… (چند نشانی برای گروه)';

  @override
  String get uiCarryShortMessagesOverAFA94B6 =>
      'پیام کوتاه را بدون اینترنت از مش LoRa در MeshCore و رادیوی همراه بفرستید. Conest مخاطبان را به رادیو می‌افزاید تا پیامشان پذیرفته شود.';

  @override
  String get uiMessagesWithMeshCoreAppUsersDE77BA =>
      'پیام با کاربران برنامهٔ MeshCore';

  @override
  String get uiReadAndWriteTheMeshCore98E60E =>
      'پیام‌های برنامه‌های MeshCore را از این رادیو بخوانید و بنویسید: با مخاطبانش و در کانال‌ها به‌صورت گروهی. محافظت آن‌ها فقط به‌اندازهٔ MeshCore است.';

  @override
  String get uiMeshCoreChats82C29C => 'گفت‌وگوهای MeshCore';

  @override
  String get uiSendWithItsDetailsF287FB => 'با جزئیاتش ارسال شود؟';

  @override
  String get uiSendAnyway911263 => 'با این حال ارسال شود';

  @override
  String get uiSaveTheErrorHistory0B3413 => 'ذخیرهٔ تاریخچهٔ خطا';

  @override
  String uiSavedTheErrorHistoryTo5271C5(String value) {
    return 'تاریخچهٔ خطا در $value ذخیره شد.';
  }

  @override
  String uiSavingTheErrorHistoryFailed72A33A(String value) {
    return 'ذخیرهٔ تاریخچهٔ خطا ناموفق بود: $value';
  }

  @override
  String get uiSaveToAFile5BB648 => 'ذخیره در فایل';

  @override
  String get uiClear719EA3 => 'پاک کردن';

  @override
  String get uiFilterD7DECF => 'فیلتر';

  @override
  String get uiErrorsOnlyHideTheDebugECA1DD =>
      'فقط خطاها (پنهان کردن گزارش اشکال‌زدایی)';

  @override
  String uiValueH171B92(String value) {
    return '$value ساعت';
  }

  @override
  String uiValueMin439C52(String value) {
    return '$value دقیقه';
  }

  @override
  String uiTheirClockIsAboutValueF406F1(String value) {
    return 'ساعت او حدود $value $value اختلاف دارد؛ زمان‌های اینجا بر اساس این دستگاه‌اند.';
  }

  @override
  String uiValueB7CFB44(String value) {
    return '$value بایت';
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
  String get uiSent27E770 => 'ارسال شد';

  @override
  String get uiWaitingOnTheRelayED66FF => 'در انتظار رله';

  @override
  String get uiReachedTheirDevice0FE289 => 'به دستگاه او رسید';

  @override
  String get uiDeliveredF81891 => 'تحویل شد';

  @override
  String get uiReceived38428A => 'دریافت شد';

  @override
  String get uiCarryShortMessagesOverADD8570 =>
      'پیام کوتاه را بدون اینترنت از مش LoRa در Meshtastic و رادیوی Meshtastic بفرستید. مخاطبان باید Conest و رادیویی در همان مش داشته باشند.';

  @override
  String get uiFindDevices98771A => 'یافتن دستگاه‌ها';

  @override
  String get uiRadioAddressD288E6 => 'نشانی رادیو';

  @override
  String get uiMessagesWithMeshtasticAppUsers812B3A =>
      'پیام با کاربران برنامهٔ Meshtastic';

  @override
  String get uiReadAndWriteTheMeshtastic995E5D =>
      'پیام‌های برنامه‌های Meshtastic را از این رادیو بخوانید و بنویسید: پیام مستقیم و کانال‌ها به‌صورت گروهی. محافظت آن‌ها فقط به‌اندازهٔ Meshtastic است.';

  @override
  String get uiMeshtasticChats46BEF8 => 'گفت‌وگوهای Meshtastic';

  @override
  String get uiClearSelection247FD6 => 'پاک کردن انتخاب';

  @override
  String get uiBrowseFilesAF7C13 => 'مرور فایل‌ها…';

  @override
  String get uiSelectMoreE38EF3 => 'انتخاب بیشتر';

  @override
  String get uiAllowAllA16326 => 'اجازه به همه';

  @override
  String get uiCaptionDA5C59 => 'شرح…';

  @override
  String get uiOpenSettingsFD7108 => 'باز کردن تنظیمات';

  @override
  String get uiDiscardChangesD3F0B4 => 'تغییرات دور انداخته شوند؟';

  @override
  String get uiYourEditsWillBeLostB34663 =>
      'ویرایش‌ها از دست می‌روند. تصویر اصلی در گالری می‌ماند.';

  @override
  String get uiKeepEditingD4D9E3 => 'ادامهٔ ویرایش';

  @override
  String get uiDiscard36FFF6 => 'دور انداختن';

  @override
  String get uiRotateLeft6F72F3 => 'چرخش به چپ';

  @override
  String get uiRotateRightB75F23 => 'چرخش به راست';

  @override
  String get uiApplyCropA43CCF => 'اعمال برش';

  @override
  String get uiCropC5DB3D => 'برش';

  @override
  String get uiVerifiedDownloadProgressBED7C2 => 'پیشرفت بارگیری تأییدشده';

  @override
  String get uiSharingWithGroup2AED71 => 'در حال اشتراک با گروه';

  @override
  String get uiOpenCF9B77 => 'باز کردن';

  @override
  String get uiStopSharing0E45AE => 'توقف اشتراک';

  @override
  String get uiRemoveLocalCopy80FA01 => 'حذف نسخهٔ محلی';

  @override
  String get uiScanInviteEFC78A => 'اسکن دعوت';

  @override
  String uiValueValue176D15(String value, String value2) {
    return '$value:$value2';
  }

  @override
  String uiDefaultRelayValueBD3FD1(String value) {
    return 'رلهٔ پیش‌فرض $value';
  }

  @override
  String uiSamplesValueSlowOverMsValueAE2EBF(String value, String value2) {
    return 'samples=$value slowOver100ms=$value2 maxTotalMs=$value maxBuildMs=$value maxRasterMs=$value';
  }

  @override
  String get uiConversation2A20C7 => 'گفت‌وگو';

  @override
  String uiSharedValueWithTheGroup163418(String value) {
    return '$value به‌صورت پیوست معمولی با گروه به اشتراک گذاشته شد؛ برخی اعضا برای پخش صدا باید به‌روزرسانی کنند.';
  }

  @override
  String uiSharedValueWithTheGroupAE4134(String value) {
    return '$value با گروه به اشتراک گذاشته شد.';
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
  String get uiNone3C6B18 => '(هیچ)';

  @override
  String uiLANNodeValueOn5D539E(String value) {
    return 'گره شبکهٔ محلی در درگاه $value روشن است';
  }

  @override
  String get uiLANNodeUnavailable9CFA32 => 'گره شبکهٔ محلی در دسترس نیست';

  @override
  String uiLANValueA8EEF3(String value) {
    return 'LAN $value';
  }

  @override
  String uiRelayValueDownD6B267(String value) {
    return 'رلهٔ $value از دسترس خارج است';
  }

  @override
  String uiRelayValueA6D70A(String value) {
    return 'رلهٔ $value';
  }

  @override
  String get uiNoInternetRelay55D2CE => 'رلهٔ اینترنت نیست';

  @override
  String uiValueValue42DC94(String value, String value2) {
    return '$value=$value2';
  }

  @override
  String uiValueHasBeenOutOf039D48(String value) {
    return 'مدتی است از $value بی‌خبریم: تا آن را در تنظیمات ← دستگاه‌ها تأیید نکنید چیزی همگام نمی‌شود.';
  }

  @override
  String uiValueIsOneOfYourE4FD9C(String value) {
    return '$value اکنون یکی از دستگاه‌های شماست؛ گفت‌وگوی قدیمی آن دیگر در فهرست نیست.';
  }

  @override
  String uiYourDevicesDisagreeOnWhich2E7001(String value) {
    return 'دستگاه‌هایتان دربارهٔ اعضای حساب اختلاف دارند و مجموعشان بیش از $value می‌شود. یکی را در تنظیمات ← دستگاه‌ها حذف کنید.';
  }

  @override
  String uiValueAddedADeviceValue710908(String value, String value2) {
    return '$value دستگاهی افزود: $value2.';
  }

  @override
  String uiUnknownValue9B520C(String value) {
    return '$value نامشخص';
  }

  @override
  String uiReadByAllValue43BA5A(String value) {
    return 'همهٔ $value نفر خواندند';
  }

  @override
  String uiDeliveredToAllValue71E077(String value) {
    return 'به همهٔ $value نفر تحویل شد';
  }

  @override
  String uiAcceptedByValueOfValue826A0E(String value, String value2) {
    return '$value از $value2 نفر پذیرفتند';
  }

  @override
  String uiWaitingForValueMemberS5A8BA6(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'در انتظار $value عضو',
      one: 'در انتظار $value عضو',
    );
    return '$_temp0';
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
    return 'از $value گذشتیم: حجم $value2 MB از سقف $value3 MB بیشتر است.';
  }

  @override
  String get uiRoute499952 => 'مسیر';

  @override
  String get uiSafetyNumber5ED2D3 => 'شمارهٔ ایمنی';

  @override
  String get uiIrohEndpoint72F674 => 'نقطهٔ پایانی Iroh';

  @override
  String get uiDeviceA5A74A => 'دستگاه';

  @override
  String get uiLANLobbyC16DC8 => 'لابی شبکهٔ محلی';

  @override
  String uiMembersValue541E72(String value) {
    return 'اعضا · $value';
  }

  @override
  String get uiNodeOnlineFAC64A => 'گره · آنلاین';

  @override
  String uiSafetyValueC542B8(String value) {
    return 'ایمنی $value';
  }

  @override
  String uiValue3072D4(String value) {
    return '$value%';
  }

  @override
  String uiValueMembersCEF563(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value عضو',
      one: '$value عضو',
    );
    return '$_temp0';
  }

  @override
  String get uiPairwise64A0EF => 'جفت‌به‌جفت';

  @override
  String get uiPasteMedia4831DE => 'چسباندن رسانه';

  @override
  String get uiRELAYA1C0CF => 'رله';

  @override
  String get uiSentAsAPlainMatrixAAE694 => 'به‌صورت پیام عادی Matrix ارسال شد';

  @override
  String get uiOnlyOnThisDevice7D64C4 => 'فقط در این دستگاه';

  @override
  String get uiConnectivityIsOffTurnOnE42D4A =>
      'اتصال خاموش است. برای تبادل دعوت، شبکهٔ محلی یا آنلاین را روشن کنید.';

  @override
  String get uiConnectivityIsOffTurnOnFA573F =>
      'اتصال خاموش است. پیش از اشتراک دعوت، شبکهٔ محلی یا آنلاین را روشن کنید.';

  @override
  String get uiReceiveBeam2CB58B => 'دریافت Beam';

  @override
  String get uiSendEncryptedFile99D424 => 'ارسال فایل رمزگذاری‌شده';

  @override
  String get uiSendPublicFileF81389 => 'ارسال فایل عمومی';

  @override
  String get uiBeamContactInvite2BAB4C => 'دعوت مخاطب با Beam';

  @override
  String get uiDevicesDF485C => 'دستگاه‌ها';

  @override
  String get uiWARNC2FD77 => 'WARN';

  @override
  String get uiDOWN30E504 => 'DOWN';

  @override
  String get uiAVGRTTE96B26 => 'AVG RTT';

  @override
  String uiRoutingValueFC4557(String value) {
    return 'مسیریابی — $value';
  }

  @override
  String uiActiveValueC78B63(String value) {
    return 'فعال ($value)';
  }

  @override
  String uiRecentValueB82237(String value) {
    return 'اخیر ($value)';
  }

  @override
  String get uiDirect24A173 => 'مستقیم';

  @override
  String get uiRelayBD28B2 => 'رله';

  @override
  String get uiRoutingECF60A => 'مسیریابی';

  @override
  String uiInvitationValue6F0633(String value) {
    return 'دعوت: $value';
  }

  @override
  String get uiMeshChatNearbyA35A63 => 'گفت‌وگوی مش (نزدیک)';

  @override
  String get uiVerifiedWithAnInviteBD826F => 'با دعوت تأیید شده';

  @override
  String get uiHoldToTalkOrHold74FC22 =>
      'برای صحبت نگه دارید یا Space را نگه دارید';

  @override
  String get uiEndToEndEncryptedMatrix9E4418 => 'رمزگذاری سرتاسری (Matrix)';

  @override
  String get uiVerifiedAED3B8 => 'تأییدشده';

  @override
  String uiValueValue64684F(String value, String value2) {
    return '$value · $value2';
  }

  @override
  String get uiPrimaryChannel53B8E1 => 'کانال اصلی';

  @override
  String uiChannelValue76ED1D(String value) {
    return 'کانال $value';
  }

  @override
  String get uiPublicChannelA9795B => 'کانال عمومی';

  @override
  String get uiDescriptionCB3291 => 'توضیح';

  @override
  String uiTheirClockIsAboutValue7DB956(String value, String value2) {
    return 'ساعت او حدود $value $value2 اختلاف دارد؛ زمان‌های اینجا بر اساس این دستگاه‌اند.';
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
  String get uiConestTransfer406028 => 'انتقال Conest';

  @override
  String uiValueConestTransfersF846F8(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value انتقال Conest',
      one: '$value انتقال Conest',
    );
    return '$_temp0';
  }

  @override
  String uiViaValueValue37232D(String value, String value2) {
    return 'از $value ($value2)';
  }

  @override
  String get uiBackThroughTheContactWhoD09BD0 =>
      'بازگشت از مخاطبی که پیام او را منتقل کرد';

  @override
  String uiConestRelayValue4FB2DB(String value) {
    return 'رلهٔ Conest ‏$value';
  }

  @override
  String get uiConestIsAlreadyRunningEE8037 => 'Conest از قبل اجراست';

  @override
  String get uiCloseTheExistingConestWindow83B30B =>
      'ابتدا پنجرهٔ باز Conest را ببندید. اجرای دوم بر سر درگاه رلهٔ محلی و گاوصندوق رمزگذاری‌شده رقابت می‌کند.';

  @override
  String get uiChooseWhereConestStoresData0CF613 =>
      'محل ذخیرهٔ داده‌های Conest را انتخاب کنید';

  @override
  String get uiGhostModeIsBestEffort694912 =>
      'حالت شبح حریم خصوصی را تا حد امکان حفظ می‌کند: سابقهٔ اجرای سیستم، گزارش خرابی، فرادادهٔ شبکه، تاریخچهٔ پوسته، فایل‌های اخیر و حافظهٔ نهان سیستم در کنترل برنامه نیستند.';

  @override
  String get uiDefaultOnThisDevice10343F => 'پیش‌فرض این دستگاه';

  @override
  String get uiUseTheNormalAppDataF44F79 =>
      'در صورت انتخاب بازگشایی خودکار، از پوشهٔ معمول دادهٔ برنامه و کلیددان این دستگاه استفاده کنید.';

  @override
  String get uiGhostPortableBesideTheApp31A40D => 'شبح / قابل‌حمل کنار برنامه';

  @override
  String get uiStoreConestControlledFilesIn7DA307 =>
      'فایل‌های تحت کنترل Conest در پوشهٔ conest_data کنار برنامه ذخیره شوند.';

  @override
  String get uiVaultUnlock602BF6 => 'بازگشایی گاوصندوق';

  @override
  String get uiKeyFileAutoUnlock66AC4A => 'بازگشایی خودکار با فایل کلید';

  @override
  String get uiKeepsTheKeyBesideTheB045D9 =>
      'کلید کنار گاوصندوق می‌ماند. هر کس پوشه را داشته باشد می‌تواند آن را باز کند.';

  @override
  String get uiAutoUnlockWithThisDeviceE7F781 =>
      'بازگشایی خودکار با این دستگاه';

  @override
  String get uiStoresTheVaultKeyInC7B1CD =>
      'کلید گاوصندوق در ذخیره‌ساز امن سیستم نگه داشته می‌شود.';

  @override
  String get uiPassphraseUnlock13B14C => 'بازگشایی با گذرواژه';

  @override
  String get uiAskForAPassphraseOn4BA25C =>
      'در هر اجرا گذرواژه می‌خواهد. گذرواژهٔ فراموش‌شده قابل بازیابی نیست.';

  @override
  String get uiUnlockConest033EB6 => 'بازگشایی Conest';

  @override
  String get uiEnterThePassphraseForThis891200 =>
      'گذرواژهٔ این گاوصندوق را وارد کنید.';

  @override
  String get uiNoUpdateIsAvailableRightA5EB48 =>
      'اکنون به‌روزرسانی‌ای موجود نیست.';

  @override
  String uiValueIsAvailableOnTheD338C4(String value, String value2) {
    return '$value در کانال $value2 موجود است.';
  }

  @override
  String uiCurrentBuildValue2FD415(String value) {
    return 'نسخهٔ فعلی: $value';
  }

  @override
  String get uiWhatSNew4D8DC5 => 'تازه‌ها';

  @override
  String get uiSERVERLESSSECUREMESSENGER1E1891 => '◢ پیام‌رسان امن بدون سرور';

  @override
  String uiYourMatrixSessionValueWants580E45(String value) {
    return 'نشست Matrix شما $value می‌خواهد این نشست را تأیید کند. فقط اگر خودتان شروع کرده‌اید بپذیرید.';
  }

  @override
  String uiValueWantsToVerifyYou61FD9D(String value) {
    return '$value می‌خواهد با مقایسهٔ شکلک‌ها شما را تأیید کند. نشانی کامل را بررسی کنید؛ نشانی‌های شبیه وجود دارند. فقط اگر حضوری یا در تماس می‌توانید مقایسه کنید بپذیرید؛ تأیید، کلیدهای او را مورد اعتماد می‌کند.';
  }

  @override
  String uiCouldNotVerifyValue3AE1C4(String value) {
    return 'تأیید ممکن نشد: $value';
  }

  @override
  String get uiSendWithoutResumableCopy0475F4 =>
      'بدون نسخهٔ قابل‌ادامه ارسال شود؟';

  @override
  String uiValueCouldNotBeCopied06F61A(
    String value,
    String value2,
    String value3,
  ) {
    return 'کپی $value به فضای خصوصی انتقال ممکن نشد.\n\n$value2\n\nبرنامه می‌تواند فایل اصلی را مستقیم بخواند، ولی اگر فایل جابه‌جا یا مجوزش منقضی شود، انتقال پس از راه‌اندازی دوباره ادامه نمی‌یابد.$value3';
  }

  @override
  String get uiUnmute7044C3 => 'وصل صدا';

  @override
  String get uiMute0F0973 => 'قطع صدا';

  @override
  String get uiSpeakerOn93982E => 'بلندگو روشن';

  @override
  String get uiSpeakerOff97823A => 'بلندگو خاموش';

  @override
  String get uiCancelCallCE6C16 => 'لغو تماس';

  @override
  String uiValueValueReturnToCall49F82C(String value, String value2) {
    return '$value$value2 · بازگشت به تماس';
  }

  @override
  String get uiContactDetailsD4EC65 => 'جزئیات مخاطب';

  @override
  String uiValueActiveMemberValue6700F2(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value عضو فعال',
      one: '$value عضو فعال',
    );
    return '$_temp0';
  }

  @override
  String get uiOwner89FF31 => 'مالک';

  @override
  String uiEditValue75BE00(String value) {
    return 'ویرایش $value';
  }

  @override
  String uiCouldNotSaveChatSettings2372B2(String value) {
    return 'ذخیرهٔ تنظیمات گفت‌وگو ممکن نشد: $value';
  }

  @override
  String get uiAddAContactToStart165431 =>
      'برای شروع گفت‌وگو مخاطبی اضافه کنید';

  @override
  String get uiNoContactsFound816015 => 'مخاطبی پیدا نشد';

  @override
  String uiOpenValue8DF02B(String value) {
    return 'باز کردن #$value';
  }

  @override
  String get uiNoMessagesYetC04921 => 'هنوز پیامی نیست';

  @override
  String get uiNoActivityYetPairA7F5366 =>
      'هنوز فعالیتی نیست؛ برای شروع گزارش مخاطبی جفت کنید.';

  @override
  String get uiSENT5AD0CD => 'ارسال';

  @override
  String get uiRECVBFC296 => 'دریافت';

  @override
  String uiDeviceValue11AEA9(String value) {
    return 'دستگاه $value';
  }

  @override
  String get uiFreeForAllLocalChat5485CC => 'گفت‌وگوی محلی آزاد • نامطمئن';

  @override
  String get uiGroupsAE9629 => 'گروه‌ها';

  @override
  String get uiAddTrustedContactsBeforeCreating1084CC =>
      'پیش از ساخت گروه مخاطبان مورد اعتماد را اضافه کنید.';

  @override
  String get uiNoGroupsYet5009C6 => 'هنوز گروهی نیست.';

  @override
  String uiValueMemberSE75249(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value عضو',
      one: '$value عضو',
    );
    return '$_temp0';
  }

  @override
  String get uiContactsB0DD61 => 'مخاطبان';

  @override
  String get uiAppliesToFutureAdmissionsHistory78E3A0 =>
      'برای پذیرش‌های آینده است. تاریخچه‌ای که دریافت شده پس گرفته نمی‌شود.';

  @override
  String uiValueAllRetainedHistory5E25F4(String value) {
    return '$valueتمام تاریخچهٔ نگه‌داشته‌شده';
  }

  @override
  String uiValueSinceAdmissionB2617B(String value) {
    return '$valueاز زمان پذیرش';
  }

  @override
  String uiDeleteValueF0396B(String value) {
    return 'حذف «$value»';
  }

  @override
  String uiDeleteValueForEveryone12E724(String value) {
    return '«$value» برای همه حذف شود؟';
  }

  @override
  String uiValueMemberSOwnerValueE42E13(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value عضو • مالک $value2',
      one: '$value عضو • مالک $value2',
    );
    return '$_temp0';
  }

  @override
  String get uiGROUPTRUSTFANOUTMintPaired5DDF6E =>
      '// GROUP TRUST FANOUT · mint = paired';

  @override
  String get uiAddTrustedContact126717 => 'افزودن مخاطب مورد اعتماد';

  @override
  String get uiNoAvailableChats1FAA40 => 'گفت‌وگوی در دسترسی نیست';

  @override
  String get uiForwardedMessageQueuedC82DA4 =>
      'پیام بازفرست‌شده در صف قرار گرفت';

  @override
  String uiCouldNotForwardValue80193D(String value) {
    return 'بازفرستادن ممکن نشد: $value';
  }

  @override
  String get uiForwardedAttachmentQueued57C88B =>
      'پیوست بازفرست‌شده در صف قرار گرفت';

  @override
  String uiCouldNotForwardAttachmentValue5165FD(String value) {
    return 'بازفرستادن پیوست ممکن نشد: $value';
  }

  @override
  String get uiChatDetails15DAEC => 'جزئیات گفت‌وگو';

  @override
  String get uiConnectionDetailsAB30A5 => 'جزئیات اتصال';

  @override
  String uiValueValue270519(String value, String value2) {
    return '$value / $value2';
  }

  @override
  String uiVoiceMessageValue2F0300(String value) {
    return 'پیام صوتی · $value';
  }

  @override
  String uiPlaybackFailedValue1C0E1A(String value) {
    return 'پخش ناموفق بود: $value';
  }

  @override
  String get uiPreparingMicrophone0BBF4A => 'آماده‌سازی میکروفن…';

  @override
  String get uiPreparingPreview312E7B => 'آماده‌سازی پیش‌نمایش…';

  @override
  String uiVoiceMessagePreviewValue8235CB(String value) {
    return 'پیش‌نمایش پیام صوتی · $value';
  }

  @override
  String uiRecordingValueValue111FF1(String value, String value2) {
    return 'در حال ضبط$value · $value2';
  }

  @override
  String get uiSendingCF7655 => 'در حال ارسال…';

  @override
  String uiValue72F816(String value) {
    return '$value×';
  }

  @override
  String get uiSingleChoice68E3E0 => 'تک‌گزینه‌ای';

  @override
  String get uiMultipleChoiceB88936 => 'چندگزینه‌ای';

  @override
  String uiThisRemovesTheMessageFor2247A2(String value) {
    return 'این پیام برای اعضای گروه هنگام همگام‌سازی حذف می‌شود.$value';
  }

  @override
  String get uiCouldNotLocateThisMessage220E83 =>
      'این پیام در گفت‌وگوی فعلی پیدا نشد';

  @override
  String uiDeleteValueMessageValueForABA7AC(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value پیام برای گروه حذف شود؟',
      one: '$value پیام برای گروه حذف شود؟',
    );
    return '$_temp0';
  }

  @override
  String uiValueValue29C8B9(String value, String value2) {
    return '$value $value2';
  }

  @override
  String get uiNewC2A6B0 => 'جدید';

  @override
  String get uiEditedA22FCA => 'ویرایش‌شده';

  @override
  String get uiCopyCachePathC23134 => 'کپی مسیر حافظهٔ نهان';

  @override
  String get uiStopKeepingOfflineAABFC7 => 'توقف نگهداری آفلاین';

  @override
  String get uiKeepOffline123286 => 'نگهداری آفلاین';

  @override
  String get uiForwardFileC4B5CB => 'بازفرست فایل';

  @override
  String get uiLoadingHistory02CB12 => 'بارگذاری تاریخچه…';

  @override
  String get uiLoadOlderMessages07471F => 'بارگذاری پیام‌های قدیمی‌تر';

  @override
  String get uiShareFileNow96E2A2 => 'اشتراک فایل اکنون';

  @override
  String get uiScheduleFile690A92 => 'زمان‌بندی فایل';

  @override
  String get uiDropToShareThisFile0B73E8 =>
      'برای اشتراک این فایل با گروه رها کنید';

  @override
  String get uiClosed88D86B => 'بسته';

  @override
  String get uiVisibleVotes460E7A => 'رأی‌های آشکار';

  @override
  String uiValueVoteSWereNot02CC9A(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value رأی در ثبت نهایی سازنده نبود.',
      one: '$value رأی در ثبت نهایی سازنده نبود.',
    );
    return '$_temp0';
  }

  @override
  String get uiVotingIsUnavailableWithThis9B92E7 =>
      'رأی دادن در این نسخهٔ Conest ممکن نیست.';

  @override
  String get uiThisRemovesTheMessageHere61D27C =>
      'این پیام اینجا حذف می‌شود و اگر مخاطب در دسترس باشد درخواست حذف نسخهٔ او فرستاده می‌شود.';

  @override
  String get uiThisRemovesTheMessageFrom6A47E2 =>
      'این پیام از این دستگاه حذف می‌شود.';

  @override
  String get uiSendViaMatrix3868FE => 'ارسال از Matrix…';

  @override
  String get uiNotesFilesAndForwardsOnlyB0145F =>
      'یادداشت، فایل و بازفرست‌ها، فقط در این دستگاه';

  @override
  String uiValueSafetyValue82C755(String value, String value2) {
    return '$value • ایمنی $value2';
  }

  @override
  String uiDropFilesToSendMax106011(String value) {
    return 'فایل‌ها را برای ارسال رها کنید (حداکثر $value)';
  }

  @override
  String get uiFreeForAllLocalChatBC90D2 =>
      'گفت‌وگوی محلی آزاد. پیام‌ها با نشست امضا می‌شوند، اما افراد اینجا مخاطبان مورد اعتماد نیستند.';

  @override
  String get uiNoLANLobbyMessagesYetBCDC4B =>
      'هنوز پیامی در لابی شبکهٔ محلی نیست. همتایان نزدیک Conest تا وقتی در این شبکهٔ محلی باشند پیام را می‌گیرند.';

  @override
  String uiValueUntrusted519A32(String value) {
    return '$value • نامطمئن';
  }

  @override
  String uiRemoveValueF4FE4B(String value) {
    return '$value حذف شود؟';
  }

  @override
  String get uiAvailablePaths6EE503 => 'مسیرهای موجود';

  @override
  String get uiRunACheckToMeasure5D76A5 =>
      'برای سنجش تأخیر، دسترسی و تازگی وضعیت دسترسی بررسی اجرا کنید. مسیرها ابتدا بر اساس بهترین مسیر مستقیم یا محلی و سپس رلهٔ جایگزین مرتب می‌شوند.';

  @override
  String get uiNoRouteHintsAreAdvertisedB25540 =>
      'هیچ مسیر پیشنهادی برای این مخاطب اعلام نشده است.';

  @override
  String get uiEitherInputIsEnoughOn020B90 =>
      'هر ورودی به‌تنهایی کافی است. دعوت QR را اسکن یا بچسبانید تا مستقیم اعتماد کنید، یا فقط عبارت اتصال فعلی را وارد کنید تا فرستنده از شبکهٔ محلی یا رلهٔ تنظیم‌شده پیدا شود. اگر تبادل خودکار ناموفق باشد، برنامه پیشنهاد می‌کند از طرف مقابل بخواهید شما را اضافه کند یا لغو کنید.';

  @override
  String get uiInvitePreview6433A0 => 'پیش‌نمایش دعوت';

  @override
  String uiValueValueValue98AECE(String value, String value2, String value3) {
    return '$value$value2 • $value3';
  }

  @override
  String get uiShareInviteDBCC1E => 'اشتراک دعوت';

  @override
  String get uiThisInviteWorksOnlyOnB106B0 =>
      'این دعوت فقط در شبکهٔ مشترک کار می‌کند: مسیر اینترنت روشن نیست. در تنظیمات ← اتصال، رلهٔ Iroh، رلهٔ Conest یا حامل (Nostr، ایمیل) را روشن کنید تا مخاطبان از هر جا اضافه‌تان کنند.';

  @override
  String get uiThisInviteAlsoListsYourEF3A4F =>
      'این دعوت مسیرهای شبکه‌های مسدود را هم دارد و برای یک کد QR بزرگ است. آن را با Beam نشان دهید؛ QR متحرکی که دوربین دیگر در چند ثانیه می‌خواند.';

  @override
  String get uiQRRenderingIsDeferredOn8A6997 =>
      'نمایش QR در Windows به تعویق می‌افتد.';

  @override
  String get uiUseTheCodephraseBelowOrB6A588 =>
      'از عبارت اتصال زیر استفاده کنید یا پس از باز شدن صفحه QR را نمایش دهید.';

  @override
  String get uiScanningTheCompactQRIs9459D9 =>
      'اسکن QR فشرده به‌تنهایی کافی است. اگر دوربین هنوز مشکل دارد، آن را تمام‌صفحه کنید یا فقط از عبارت اتصال فعلی استفاده کنید.';

  @override
  String uiQRPayloadValueCharactersBABEDF(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'محتوای QR: ‏$value نویسه',
      one: 'محتوای QR: ‏$value نویسه',
    );
    return '$_temp0';
  }

  @override
  String uiAlsoListsYourAddressesOnC5D815(String value) {
    return 'نشانی‌های شما در این شبکه‌ها را هم دارد: $value.';
  }

  @override
  String uiPinnedValue834309(String value) {
    return 'سنجاق‌شده · $value';
  }

  @override
  String get uiNoVerifiedCiContactsAre3FD190 =>
      'هنوز مخاطب ci6 تأییدشده‌ای نیست.';

  @override
  String get uiCloseUpTransferE6BA46 => 'انتقال نزدیک';

  @override
  String get uiALoopingLTFountainStream840218 =>
      'جریان چرخشی کد فواره‌ای LT از فریم‌های QR گم‌شده، تکراری و نامرتب عبور می‌کند. پیش از پذیرش فایل نهایی، هش آن بررسی می‌شود.';

  @override
  String get uiPUBLICVisibleToAnyoneNearbyA775C2 =>
      'عمومی · قابل‌دیدن برای همهٔ اطرافیان';

  @override
  String get uiCONTACTENCRYPTED879896 => 'رمزگذاری برای مخاطب';

  @override
  String get uiSIGNEDCONTACTINVITE752317 => 'دعوت مخاطب امضاشده';

  @override
  String uiFrameValueValueSourceBlocks9C37CB(
    String value,
    int value2,
    String value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value2,
      locale: localeName,
      other: 'فریم $value · $value2 بلوک منبع · $value3',
      one: 'فریم $value · $value2 بلوک منبع · $value3',
    );
    return '$_temp0';
  }

  @override
  String get uiPointThisCameraAtThe2EA3F7 =>
      'این دوربین را به QR متحرک Beam بگیرید. فقط فریم‌های cb1 رمزگشایی‌شده از اسکنر بومی خارج می‌شوند.';

  @override
  String get uiNativeDesktopCameraCaptureIs4619C8 =>
      'تصویربرداری بومی دوربین رایانه در دسترس نیست. فریم‌های cb1 را پایین بچسبانید؛ رمزگشایی پروتکل و مسیر تأیید یکسان‌اند.';

  @override
  String uiValueValueBlocksValueFrames66F819(
    String value,
    String value2,
    String value3,
    String value4,
  ) {
    return '$value/$value2 بلوک · $value3 فریم · $value4 نامعتبر';
  }

  @override
  String get uiSignedContactInviteA7CC8B => 'دعوت مخاطب امضاشده';

  @override
  String get uiPUBLICUNTRUSTEDTheSignatureProves96FA7F =>
      'عمومی / نامطمئن. امضا ثابت می‌کند همهٔ فریم‌ها از یک کلید آمده‌اند؛ نه اینکه مالک کلید کیست.';

  @override
  String get uiEncryptedAndAuthenticatedAsA68B7E4 =>
      'رمزگذاری و احراز هویت به‌عنوان مخاطب سنجاق‌شدهٔ Conest.';

  @override
  String get uiSignatureValidCompareTheFingerprintA8A1FE =>
      'امضا معتبر است. اثر انگشت را حضوری مقایسه کنید.';

  @override
  String get uiAcceptAndSavePublicFile852517 => 'پذیرش و ذخیرهٔ فایل عمومی';

  @override
  String get uiSaveFileBEDC84 => 'ذخیرهٔ فایل';

  @override
  String get uiFullscreenCompactInviteQRCF6B8B => 'QR دعوت فشردهٔ تمام‌صفحه';

  @override
  String uiValueCharactersIncreaseScreenBrightnessA5AF7D(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value نویسه. اگر اسکن مشکل دارد روشنایی نمایشگر را بالا ببرید.',
      one: '$value نویسه. اگر اسکن مشکل دارد روشنایی نمایشگر را بالا ببرید.',
    );
    return '$_temp0';
  }

  @override
  String get uiPersonalPreferencesBD0D61 => 'شخصی / ترجیحات';

  @override
  String get uiNetworkRelay4F9A27 => 'شبکه / رله';

  @override
  String get uiDanger58D175 => 'خطر';

  @override
  String get uiAllowsOneToOneIroh45EEF1 =>
      'تماس دونفرهٔ Iroh را در این دستگاه فعال می‌کند. برای توقف برقراری و دریافت تماس خاموش کنید.';

  @override
  String get uiPrivacyOfFilesYouSend4E4A5B => 'حریم خصوصی فایل‌های ارسالی';

  @override
  String get uiLowA12494 => 'کم';

  @override
  String get uiMediumD40496 => 'متوسط';

  @override
  String get uiHighB1A595 => 'زیاد';

  @override
  String get uiTransportPolicy088D79 => 'سیاست انتقال';

  @override
  String get uiPerContactRoutingIsIntersected88E292 =>
      'مسیریابی هر مخاطب با این گزینه‌ها محدود می‌شود. خاموش کردن هرکدام ترافیک را محدود و خاموش کردن هر دو برنامه را بی‌فعالیت می‌کند.';

  @override
  String get uiConnectivityIsFullyOffTheB12483 =>
      'اتصال کاملاً خاموش است؛ برنامه ارسال یا دریافت نمی‌کند.';

  @override
  String uiValueCandidateRouteSAre175673(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'اکنون $value مسیر پیشنهادی موجود است.',
      one: 'اکنون $value مسیر پیشنهادی موجود است.',
    );
    return '$_temp0';
  }

  @override
  String get uiConfiguredRelays3CA0DE => 'رله‌های تنظیم‌شده';

  @override
  String get uiNoRelaysAddedYetF791E7 => 'هنوز رله‌ای اضافه نشده.';

  @override
  String uiCurrentBuildValueValue9A675D(String value, String value2) {
    return 'نسخهٔ فعلی: $value • $value2';
  }

  @override
  String uiCommitValue2E080C(String value) {
    return 'کامیت $value';
  }

  @override
  String uiAvailableValue4B15F7(String value) {
    return 'موجود: $value';
  }

  @override
  String get uiChecking494D0F => 'در حال بررسی…';

  @override
  String get uiCheckForUpdates8604FF => 'بررسی به‌روزرسانی';

  @override
  String uiTrustNewIdentityForValue8B0612(String value) {
    return 'به هویت تازهٔ $value اعتماد می‌کنید؟';
  }

  @override
  String uiTheRelayIsNowSigningFF71FD(String value) {
    return 'رله اکنون با کلید عمومی Ed25519 دیگری امضا می‌کند ($value). فقط اگر گرداننده تغییر کلید را تأیید کرده ادامه دهید؛ وگرنه ممکن است حملهٔ واسطه باشد.';
  }

  @override
  String get uiRelayIdentityChanged097638 => 'هویت رله تغییر کرد';

  @override
  String get uiAConfiguredRelayIsSigning60EED0 =>
      'رلهٔ تنظیم‌شده با کلید تازه امضا می‌کند. پیش از اعتماد از گرداننده تأیید بگیرید.';

  @override
  String uiValueValue66746D(String value, String value2) {
    return '$value → $value2';
  }

  @override
  String get uiNoPendingContactRequests697615 =>
      'درخواست ارتباط در انتظاری نیست';

  @override
  String uiCouldNotReviewRequestValue82B3D5(String value) {
    return 'بررسی درخواست ممکن نشد: $value';
  }

  @override
  String uiAddValueF034EE(String value) {
    return '$value اضافه شود؟';
  }

  @override
  String uiCouldNotAddContactValue7F6C38(String value) {
    return 'افزودن مخاطب ممکن نشد: $value';
  }

  @override
  String uiCouldNotRejectRequestValue2EFD58(String value) {
    return 'رد درخواست ممکن نشد: $value';
  }

  @override
  String get uiContactRequestRejected447EE8 => 'درخواست ارتباط رد شد.';

  @override
  String uiContactRequestFromValue50B6AC(String value) {
    return 'درخواست ارتباط از $value';
  }

  @override
  String uiUnverifiedValueC1937C(String value) {
    return 'تأییدنشده · $value';
  }

  @override
  String uiContactRequestFailedValue28DD81(String value) {
    return 'درخواست ارتباط ناموفق بود: $value';
  }

  @override
  String get uiRequestAgain7B0434 => 'درخواست دوباره';

  @override
  String uiTrustValueAsAFresh7BF87F(String value, String value2) {
    return 'به $value به‌عنوان مخاطب تازه اعتماد می‌کنید؟ ابتدا شمارهٔ ایمنی را از راه دیگری بررسی کنید؛ پذیرش، مدخل‌های قبلی «$value2» را فقط‌خواندنی بایگانی می‌کند.';
  }

  @override
  String uiTrustThisAsAReinstallCBA4CC(String value) {
    return 'این هویت را نصب دوبارهٔ «$value» می‌دانید؟ مخاطب قبلی با تاریخچهٔ فقط‌خواندنی بایگانی و مخاطب تازه جایگزین می‌شود. برگشت‌پذیر نیست.';
  }

  @override
  String uiConfirmFailedValueBDE200(String value) {
    return 'تأیید ناموفق بود: $value';
  }

  @override
  String uiRejectFailedValue5F5917(String value) {
    return 'رد کردن ناموفق بود: $value';
  }

  @override
  String uiThisContactMayBeAD1405D(String value) {
    return 'ممکن است این مخاطب بازنشانی «$value» باشد. پیش از تبادل پیام، شمارهٔ ایمنی را از راه دیگری تأیید کنید.';
  }

  @override
  String uiImportedRelaysFromValue37C175(String value) {
    return 'رله‌ها از $value وارد شدند.';
  }

  @override
  String uiImportFailedValueBAFB4A(String value) {
    return 'وارد کردن ناموفق بود: $value';
  }

  @override
  String uiThisWillRemoveValueRelay330EEB(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'این کار $value مسیر رلهٔ واردشده از $value2 را حذف می‌کند.',
      one: 'این کار $value مسیر رلهٔ واردشده از $value2 را حذف می‌کند.',
    );
    return '$_temp0';
  }

  @override
  String uiRemoveFailedValue58F348(String value) {
    return 'حذف ناموفق بود: $value';
  }

  @override
  String get uiImportedRelayListsB0BD8B => 'فهرست‌های واردشدهٔ رله';

  @override
  String get uiNoImportedLists6CBC34 => 'فهرست واردشده‌ای نیست.';

  @override
  String uiValueValueValueRouteS40FB98(
    String value,
    String value2,
    int value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value3,
      locale: localeName,
      other: '$value · $value2 · $value3 مسیر',
      one: '$value · $value2 · $value3 مسیر',
    );
    return '$_temp0';
  }

  @override
  String get uiLeaveBlankToImportUnsigned0D354E =>
      'برای وارد کردن بی‌امضا خالی بگذارید (نامطمئن؛ بررسی پیش از استفاده همچنان لازم است). برای اعتماد رمزنگاری‌شده کلید گرداننده را بدهید؛ امضا از <URL>.ed25519.sig دریافت می‌شود.';

  @override
  String uiValueF7CD86(String value) {
    return '// $value';
  }

  @override
  String get uiThemeA797E3 => 'پوسته';

  @override
  String get uiAdaptiveIsUsingSystemDynamicBAA149 =>
      'پوستهٔ تطبیقی از رنگ‌های پویای سیستم استفاده می‌کند.';

  @override
  String get uiMintAndPinkRemainTheC846F3 =>
      'نعنایی و صورتی رنگ‌های جایگزین Conest می‌مانند.';

  @override
  String get uiDecoration2DB87A => 'تزئینات';

  @override
  String get uiAmbientGridScanlinesCornerReticles45D5C5 =>
      'شبکهٔ پس‌زمینه، خطوط اسکن، نشانه‌های گوشه و نمایش وضعیت. از ساده تا فضای کامل.';

  @override
  String get uiShellBDC1FD => 'چارچوب';

  @override
  String get uiHomeLayoutE19685 => 'چیدمان خانه';

  @override
  String uiCONESTCiValue7964DC(String value) {
    return 'CONEST · ci5 · $value';
  }

  @override
  String get uiQRUnavailable12869A => 'QR در دسترس نیست';

  @override
  String get uiUseTheCodephraseOrPayload187111 =>
      'از عبارت اتصال یا محتوای دعوت زیر استفاده کنید.';

  @override
  String uiTwoWayConfirmedValueE5A1A1(String value) {
    return 'دوسویه تأیید شد$value';
  }

  @override
  String uiPathAcceptsSendWaitingFor10B4B0(String value) {
    return 'مسیر ارسال را می‌پذیرد؛ در انتظار پاسخ همتا$value';
  }

  @override
  String get uiUnavailable1D5EE3 => 'در دسترس نیست';

  @override
  String get uiUsable829A7C => 'قابل استفاده';

  @override
  String get uiOneWay5EF4D0 => 'یک‌طرفه';

  @override
  String get uiSkipC7E168 => 'رد شدن';

  @override
  String get uiShareYourInviteThenEither5FEF78 =>
      'دعوت خود را به اشتراک بگذارید، سپس در دستگاه دیگر QR را اسکن یا فقط عبارت اتصال فعلی را وارد کنید تا مخاطب اضافه شود.';

  @override
  String get uiStartWithOneTrustedContact650B80 =>
      'با یک مخاطب مورد اعتماد شروع کنید';

  @override
  String get uiThisReleasePairsThroughA883AA2 =>
      'این نسخه با دعوت QR تنها یا عبارت اتصال تنها جفت می‌شود، مسیر شبکهٔ محلی نزدیک را ترجیح می‌دهد و سپس از رلهٔ اینترنت استفاده می‌کند.';

  @override
  String get uiConnectivityIsOffEnableLAN39990E =>
      'اتصال خاموش است. شبکهٔ محلی یا آنلاین را در تنظیمات روشن کنید.';

  @override
  String get uiAutomaticAC9041 => 'خودکار';

  @override
  String get uiPreferred0A3E0D => 'ترجیحی';

  @override
  String get uiDisabledF4F447 => 'غیرفعال';

  @override
  String get uiAskFirst1AEB84 => 'اول پرسیده شود';

  @override
  String get uiRetryFailed7B6CA4 => 'تلاش دوبارهٔ ناموفق‌ها';

  @override
  String get uiCancelAlbumDB0A07 => 'لغو آلبوم';

  @override
  String get uiDeleteAlbum52E30F => 'حذف آلبوم';

  @override
  String get menuForwardAlbum => 'بازارسال آلبوم';

  @override
  String get menuSelect => 'انتخاب';

  @override
  String get menuSelectAlbum => 'انتخاب آلبوم';

  @override
  String uiValueSelectedB1DFAF(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value انتخاب‌شده',
      one: '$value انتخاب‌شده',
    );
    return '$_temp0';
  }

  @override
  String uiThisWillCancelValueActiveB3425E(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other:
          'این کار $value انتقال فعال را لغو و فهرست انتقال را پاک می‌کند. پیام‌های گفت‌وگو و فایل‌های کامل‌شده می‌مانند.',
      one:
          'این کار $value انتقال فعال را لغو و فهرست انتقال را پاک می‌کند. پیام‌های گفت‌وگو و فایل‌های کامل‌شده می‌مانند.',
    );
    return '$_temp0';
  }

  @override
  String get uiNoTransfersYetB8E5C1 => 'هنوز انتقالی نیست.';

  @override
  String get uiAttachmentMetadataUnavailableE2C31D =>
      'فرادادهٔ پیوست در دسترس نیست';

  @override
  String uiValueMBPreparingDownload799D4A(String value) {
    return '$value MB · آماده‌سازی بارگیری…';
  }

  @override
  String uiValueMBDirectRouteRequired6379F0(String value) {
    return '$value MB · مسیر مستقیم لازم است';
  }

  @override
  String uiValueMBTapToDownload432280(String value) {
    return '$value MB · برای بارگیری بزنید';
  }

  @override
  String get uiPreparingDownload8CB769 => 'آماده‌سازی بارگیری…';

  @override
  String uiTransferringValueValue10EEBE(String value, String value2) {
    return 'در حال انتقال · $value٪ · $value2';
  }

  @override
  String uiTransferringValue9D7F13(String value) {
    return 'در حال انتقال · $value';
  }

  @override
  String get uiVoiceMessage999DEB => 'پیام صوتی';

  @override
  String get uiSendAsMedia061D87 => 'ارسال به‌صورت رسانه';

  @override
  String get uiSendAsFileB50EAF => 'ارسال به‌صورت فایل';

  @override
  String get uiMEDIAB85FA2 => 'رسانه';

  @override
  String get uiFILEB4915D => 'فایل';

  @override
  String get uiPausedByPeer63BD05 => 'همتا مکث کرده است';

  @override
  String get uiCouldNotDecodeThisImage3EAA16 => 'رمزگشایی این تصویر ممکن نشد.';

  @override
  String uiValueValueValueDAEE95(String value, String value2, String value3) {
    return '$value  ·  $value2/$value3';
  }

  @override
  String uiValueCannotBeReachedOver14E8C2(String value, String value2) {
    return 'اکنون از Conest به $value دسترسی نیست. این پیام را به‌جای آن به $value2 به‌صورت پیام معمولی Matrix بفرستیم؟\n\nپیام به گفت‌وگوی مستقیم Matrix شما می‌رود، بدون رمزگذاری Conest: اگر آن گفت‌وگو رمزگذاری نشده باشد سرور خانگی می‌تواند آن را بخواند. Conest تلاش برای تحویل را متوقف می‌کند.';
  }

  @override
  String uiValueF69855(String value) {
    return '+$value';
  }

  @override
  String uiCouldNotPlayThisVideoF7D318(String value) {
    return 'پخش این ویدیو ممکن نشد: $value';
  }

  @override
  String get uiYouLeft9F2CDB => 'شما خارج شدید';

  @override
  String uiReplyingToValue645786(String value) {
    return 'پاسخ به $value';
  }

  @override
  String get uiNoScheduledMessages1DDB60 => 'پیام زمان‌بندی‌شده‌ای نیست';

  @override
  String get uiScheduledAttachment08DB0E => 'پیوست زمان‌بندی‌شده';

  @override
  String uiValueValueValue209DD2(String value, String value2, String value3) {
    return '$value • $value2\n$value3';
  }

  @override
  String get uiSendNowDAE330 => 'ارسال اکنون';

  @override
  String get uiReschedule34B2DC => 'زمان‌بندی دوباره';

  @override
  String get uiShareTextTo7B5086 => 'اشتراک متن با…';

  @override
  String uiShareValueTo6E3BDD(String value) {
    return 'اشتراک $value با…';
  }

  @override
  String uiShareValueFilesToA46E17(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'اشتراک $value فایل با…',
      one: 'اشتراک $value فایل با…',
    );
    return '$_temp0';
  }

  @override
  String get uiIfMessagesAndFilesFrom3DED27 =>
      'اگر پیام و فایل گوشی در همین شبکه نمی‌رسد ولی پیام شما به آن می‌رسد، دیوار آتش Windows آن‌ها را مسدود می‌کند. این گزینه به دستگاه‌های دیگر در هر شبکه اجازهٔ دسترسی به Conest این رایانه می‌دهد؛ Windows تأیید می‌خواهد.';

  @override
  String get uiServerRefusedSignOut66337B => 'سرور خروج را نپذیرفت';

  @override
  String get uiServerNotReached62FED2 => 'سرور در دسترس نبود';

  @override
  String uiThisServerDoesNotLet9EEC1F(String value) {
    return 'این سرور اجازهٔ پایان نشست Conest را نمی‌دهد ($value). شاید نشست‌ها در صفحهٔ حساب سرور مدیریت شوند.\n\nبا این حال از این دستگاه خارج شوید؟ سپس نشست Conest را از صفحهٔ حساب یا برنامهٔ دیگر Matrix حذف کنید.';
  }

  @override
  String uiConestCouldNotSignThis3C1074(String value) {
    return 'Conest نتوانست این دستگاه را از سرور خارج کند ($value).\n\nبا این حال از این دستگاه خارج شوید؟ نشست تا زمانی که از برنامهٔ دیگر Matrix حذفش کنید در سرور معتبر می‌ماند.';
  }

  @override
  String get uiEnabledDF174A => 'فعال';

  @override
  String get uiYourEncryptedMatrixHistoryIsC16CD2 =>
      'از تاریخچهٔ رمزگذاری‌شدهٔ Matrix پشتیبان تهیه شده است. در دستگاه تازه از «وارد کردن کلید بازیابی» استفاده کنید.';

  @override
  String get uiThisAccountAlreadyHasA0CF3D8 =>
      'این حساب کلید بازیابی دارد. برای باز کردن تاریخچهٔ رمزگذاری‌شده در این دستگاه از «وارد کردن کلید بازیابی» یا «تأیید با نشست دیگر» استفاده کنید.';

  @override
  String uiMatrixValueED6C29(String value) {
    return 'Matrix: ‏$value';
  }

  @override
  String uiValueValueB5F18A(String value, String value2) {
    return '$value$value2';
  }

  @override
  String get uiMatrixFallbackAA082C => 'مسیر جایگزین Matrix';

  @override
  String get uiMatrixAccountD69140 => 'حساب Matrix';

  @override
  String get uiAccountsThatSignInThrough64868A =>
      'حساب‌هایی که با Google، GitHub، ارائه‌دهندهٔ دیگر یا matrix.org وارد می‌شوند از مرورگر استفاده می‌کنند.';

  @override
  String uiThisAccountIsOnValueB78C80(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'این حساب در $value دستگاه است.',
      one: 'این حساب در $value دستگاه است.',
    );
    return '$_temp0';
  }

  @override
  String get uiUseConestOnMoreThanD2AA6A =>
      'از Conest در چند دستگاه استفاده کنید: گوشی، تبلت یا رایانه را به این حساب پیوند دهید. مخاطبان یک نفر می‌بینند.';

  @override
  String get uiThisDeviceWasLinkedLess2E5122 =>
      'این دستگاه کمتر از یک روز پیش پیوند شده و هنوز نمی‌تواند دستگاه اضافه یا حذف کند.';

  @override
  String get uiPauseSyncingWithADevice89642E =>
      'توقف همگام‌سازی با دستگاه بی‌خبر پس از';

  @override
  String uiValueDaysEE919A(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value روز',
      one: '$value روز',
    );
    return '$_temp0';
  }

  @override
  String get uiChatsFromOtherNetworks13CDCD => 'گفت‌وگوهای شبکه‌های دیگر';

  @override
  String uiShowValueChatsInTheBC0E41(String value) {
    return 'نمایش گفت‌وگوهای $value در فهرست';
  }

  @override
  String get uiChatWithDeltaChatUsers3B8607 =>
      'با کاربران Delta Chat از حساب ایمیل خود گفت‌وگو کنید. ابتدا ایمیل را در بالا تنظیم کنید.';

  @override
  String uiChatWithDeltaChatUsersABD3F5(String value) {
    return 'با کاربران Delta Chat با نام $value، دونفره و گروهی گفت‌وگو کنید. رمزگذاری سرتاسری (OpenPGP، بدون محرمانگی پیشرو)؛ سرور ایمیل می‌بیند چه کسی چه وقت به چه کسی می‌نویسد.';
  }

  @override
  String get uiNoDeltaChatChatsYetF4C538 =>
      'هنوز گفت‌وگوی Delta Chat ندارید. دعوت خود را به اشتراک بگذارید یا با دعوت دیگری بپیوندید.';

  @override
  String uiRequestValueE6C033(String value) {
    return 'درخواست: $value';
  }

  @override
  String get uiNobodyToAddYetStart0983BB =>
      'هنوز کسی برای افزودن نیست: ابتدا گفت‌وگو را شروع کنید. پس از ساخت گروه می‌توانید دعوتش را به اشتراک بگذارید.';

  @override
  String get uiVerifiedEC734B => 'تأییدشده';

  @override
  String uiAddValueF546E5(String value) {
    return 'افزودن $value';
  }

  @override
  String get uiChatDeleted73DC61 => 'گفت‌وگو حذف شد';

  @override
  String get uiLeaveGroup925789 => 'خروج از گروه';

  @override
  String get uiWaitingForTheInviteTo1C712D =>
      'منتظر پاسخ دعوت هستیم؛ ممکن است یک دقیقه طول بکشد.';

  @override
  String get uiEncryptedWithOpenPGPDeltaChat9C6326 =>
      'رمزگذاری با OpenPGP ‏(Delta Chat)، بدون محرمانگی پیشرو. سرور ایمیل می‌بیند چه کسی چه وقت به چه کسی می‌نویسد.';

  @override
  String get uiARequestFromSomeoneYouAE0967 =>
      'درخواست کسی که با او گفت‌وگو نکرده‌اید. پاسخ دادن آن را می‌پذیرد.';

  @override
  String get uiReadA7AFDD => 'خوانده شد';

  @override
  String get uiNotSentBE2B9D => 'ارسال نشد';

  @override
  String get uiCouldNotJoinTheCall252D45 =>
      'پیوستن به تماس ممکن نشد. مسیر را بررسی کنید یا از تماس فعلی خارج شوید.';

  @override
  String uiCallInValue16F998(String value) {
    return 'تماس در $value';
  }

  @override
  String uiValueStartedACallIn278E96(String value, String value2) {
    return '$value در $value2 تماس شروع کرد';
  }

  @override
  String get uiReturn24F096 => 'بازگشت';

  @override
  String get uiCouldNotUpdateTheCall33517D => 'به‌روزرسانی تماس ممکن نشد.';

  @override
  String get uiVoiceCallB8499D => 'تماس صوتی';

  @override
  String uiCallViaValue0A68E8(String value) {
    return 'تماس از $value';
  }

  @override
  String uiValueYouEFED9A(String value) {
    return '$value (شما)';
  }

  @override
  String get uiTalkingC34D84 => 'در حال صحبت…';

  @override
  String get uiHoldToTalkSpace869505 => 'برای صحبت نگه دارید · Space';

  @override
  String uiVoiceCallValueBD3141(String value) {
    return 'تماس صوتی · $value';
  }

  @override
  String uiStartedByValueValueParticipants99F03D(String value, int value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value2,
      locale: localeName,
      other: 'آغازگر $value · $value2 شرکت‌کننده',
      one: 'آغازگر $value · $value2 شرکت‌کننده',
    );
    return '$_temp0';
  }

  @override
  String get uiNodeRnsd0D8EEC => 'گره (rnsd)';

  @override
  String get uiRNodeOnUSBF00220 => 'RNode با USB';

  @override
  String get uiRNodeOnBluetooth13657D => 'RNode با Bluetooth';

  @override
  String get uiRNodeOnWiFiC18593 => 'RNode با Wi-Fi';

  @override
  String get uiScanForRadios2B185E => 'جست‌وجوی رادیوها';

  @override
  String get uiUseTheSameFrequencyBandwidthFC1A9F =>
      'از همان فرکانس، پهنای باند و ضریب گسترش شبکهٔ Reticulum که رادیو به آن می‌پیوندد استفاده کنید.';

  @override
  String get uiAppMode2965FD => 'حالت برنامه';

  @override
  String get uiBoth1F4698 => 'هر دو';

  @override
  String uiCouldNotStartTheChatAE2F54(String value) {
    return 'شروع گفت‌وگو ممکن نشد: $value';
  }

  @override
  String uiMessagesAreEndToEndE786B5(String value) {
    return 'پیام‌ها سرتاسر رمزگذاری شده‌اند، اما سرور شما و طرف مقابل می‌بینند چه کسی چه وقت با چه کسی صحبت می‌کند. برای اطمینان، $value را تأیید کنید.';
  }

  @override
  String get uiThisChatIsNotEncrypted799D99 =>
      'این گفت‌وگو رمزگذاری نشده است: سرور شما و طرف مقابل می‌توانند آن را بخوانند.';

  @override
  String get uiLoading33CE41 => 'در حال بارگذاری…';

  @override
  String get uiLoadEarlierMessages4AC08D => 'بارگذاری پیام‌های پیشین';

  @override
  String get uiEditing3B9BA1 => 'در حال ویرایش';

  @override
  String uiReplyToValueValue666B4E(String value, String value2) {
    return 'پاسخ به $value: ‏$value2';
  }

  @override
  String get uiYouWereInvitedToThisE30D1E =>
      'به این گفت‌وگوی Matrix دعوت شده‌اید.';

  @override
  String get uiEdited0E3C32 => 'ویرایش‌شده · ';

  @override
  String get uiUnableToDecryptThisMessage8A31CC =>
      'هنوز رمزگشایی این پیام ممکن نیست';

  @override
  String get uiUnsupportedMessage9E48EB => 'پیام پشتیبانی‌نشده';

  @override
  String uiImageUnavailableValueB024FC(String value) {
    return 'تصویر در دسترس نیست: $value';
  }

  @override
  String uiDownloadFailedValueB18BB6(String value) {
    return 'بارگیری ناموفق بود: $value';
  }

  @override
  String get uiFile2C3CAF => 'فایل';

  @override
  String uiValueKiBEC48AF(String value) {
    return '$value KiB';
  }

  @override
  String get uiCODEPHRASEE2C724 => 'عبارت اتصال';

  @override
  String uiROTATESINValueS5745B8(String value) {
    return 'تغییر تا $value ثانیه';
  }

  @override
  String get uiROUTEINSPECTOR321AA4 => 'بازرس مسیر';

  @override
  String get uiLIVE67B40B => '● زنده';

  @override
  String uiValueChatsAD9A3B(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value گفت‌وگو',
      one: '$value گفت‌وگو',
    );
    return '$_temp0';
  }

  @override
  String uiValueValue167E51(String value, String value2) {
    return '$value ($value2)';
  }

  @override
  String get uiNotDeliveredTheirRadioCould75D581 =>
      'تحویل نشد (رادیوی او نتوانست بخواند)';

  @override
  String get uiSenderNotVerified2BB0FA => 'فرستنده تأیید نشده';

  @override
  String get uiYouAreHidden56DCC1 => 'شما پنهان هستید';

  @override
  String get uiYouReadTheMeshChatAEACC5 =>
      'گفت‌وگوی مش را می‌خوانید، اما کاربران bitchat شما را نمی‌بینند و نمی‌توانند بنویسند. برای نوشتن، «دسترسی کاربران bitchat به شما» را در تنظیمات ← اتصال روشن کنید.';

  @override
  String get uiEveryoneNearbyOverBluetooth7B8D63 => 'همهٔ نزدیکان از Bluetooth';

  @override
  String get uiNoBitchatUsersNearbyYetD30471 =>
      'هنوز کاربر bitchat نزدیکی نیست';

  @override
  String get uiPhonesInBluetoothRangeThatDCCC0D =>
      'دستگاه‌هایی که در برد Bluetooth اعلام حضور کنند اینجا دیده می‌شوند.';

  @override
  String get uiNearbyF1536C => 'نزدیک';

  @override
  String get uiEveryoneInBluetoothRangeReadsA7628A =>
      'همهٔ افراد در برد Bluetooth این گفت‌وگو را می‌خوانند و هر کس می‌تواند منتقلش کند. پیام‌ها امضا شده‌اند، نه رمزگذاری.';

  @override
  String get uiEncryptedBetweenTheTwoPhones3871C4 =>
      'بین دو دستگاه رمزگذاری می‌شود (Noise در bitchat)، با محرمانگی پیشرو فقط تا وقتی هر دو نزدیک هستید.';

  @override
  String get uiThisChatWasWithAn0507F9 =>
      'این گفت‌وگو با هویت قبلی bitchat شما بود. نوشتن اکنون به آن‌ها نشان می‌دهد هویت تازه متعلق به همان شخص است.';

  @override
  String uiValueValue64C067(String value, String value2) {
    return '$value#$value2';
  }

  @override
  String get uiVerifyThisSessionB5065C => 'تأیید این نشست';

  @override
  String get uiBluetoothMeshOn5A96FE => 'شبکهٔ مش Bluetooth روشن است';

  @override
  String get uiStartingBluetoothE6928A => 'در حال راه‌اندازی Bluetooth';

  @override
  String get uiBluetoothUnavailableF4B751 => 'Bluetooth در دسترس نیست';

  @override
  String uiBitchatUsersNearbySeeYou1B54FC(String value) {
    return 'کاربران نزدیک bitchat تا وقتی در محدوده هستید شما را با نام «$value» می‌بینند و می‌توانند پیام بدهند. هویتی که می‌بینند هر هفته تازه می‌شود و هیچ ارتباطی با هویت Conest شما ندارد.';
  }

  @override
  String get uiOffBitchatUsersDoNot054F9A =>
      'خاموش: کاربران bitchat این دستگاه را نمی‌بینند. همچنان می‌توانید گفت‌وگوی مش را بخوانید.';

  @override
  String uiPhonesNearbyWithoutInternetCan27CC7F(String value) {
    return 'گوشی‌های نزدیکِ بدون اینترنت می‌توانند از کانال‌های مکانی bitchat از طریق این دستگاه استفاده کنند. فقط همان پیام‌های عمومی و امضاشده عبور می‌کنند. این دستگاه به رله‌های مناطق مورد استفادهٔ آن‌ها وصل می‌شود$value: این رله‌ها نشانی اینترنت و منطقهٔ شما را می‌بینند و می‌توانند موقعیت تقریبی شما را بفهمند.';
  }

  @override
  String get uiOffBitchatUsersNearbyWithout030CFB =>
      'خاموش: کاربران نزدیک bitchat که اینترنت ندارند نمی‌توانند از طریق شما به کانال‌های مکانی دسترسی پیدا کنند.';

  @override
  String uiValueNearbyTheMeshChat31C0CA(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value نفر نزدیک · گفت‌وگوی مش و خصوصی',
      one: '$value نفر نزدیک · گفت‌وگوی مش و خصوصی',
    );
    return '$_temp0';
  }

  @override
  String get uiSignInToYourMatrix8D0037 => 'ورود به حساب Matrix شما';

  @override
  String get uiNoRoomsFoundAD2C3E => 'اتاقی پیدا نشد';

  @override
  String get uiMatrixInvitation525106 => 'دعوت Matrix';

  @override
  String get uiEncryptedChat0D7563 => 'گفت‌وگوی رمزگذاری‌شده';

  @override
  String get uiChat2CED57 => 'گفت‌وگو';

  @override
  String get uiNoNostrChatsYet0A95D0 => 'هنوز گفت‌وگوی Nostr نیست';

  @override
  String get uiEncryptedOnNostrNIPRelaysA51F70 =>
      'رمزگذاری در Nostr ‏(NIP-17)؛ رله‌ها نه نویسنده را می‌بینند نه زمان نوشتن را. بدون محرمانگی پیشرو.';

  @override
  String get uiTestingRoutes19C586 => 'در حال آزمون مسیرها…';

  @override
  String get uiTestRoutes52770A => 'آزمون مسیرها';

  @override
  String get uiCheckingWhetherTheirAppCan51E401 =>
      'بررسی پشتیبانی برنامهٔ او از آزمون مسیر…';

  @override
  String get uiTheirAppDidNotSay758036 =>
      'برنامهٔ او پشتیبانی آزمون مسیر را اعلام نکرد. اگر همین نسخه را دارد، شاید اکنون در دسترس نیست.';

  @override
  String get uiNoRouteTookTheTestF2F6CB => 'هیچ مسیری آزمون را نپذیرفت.';

  @override
  String uiTestedValueRoutesThatAnswer70B842(String value) {
    return '$value آزموده شد. مسیرهای پاسخ‌گو برای پیام اولویت دارند.';
  }

  @override
  String get uiUSB09716C => 'USB';

  @override
  String get uiCopiedTheErrorHistoryCE02E2 => 'تاریخچهٔ خطا کپی شد.';

  @override
  String get uiNothingRecordedA27006 => 'چیزی ثبت نشده.';

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
    return 'مسیر: $value';
  }

  @override
  String uiValueValue7B4608(String value, String value2) {
    return '$value · !$value2';
  }

  @override
  String get uiNetwork53EBC5 => 'شبکه';

  @override
  String uiImageIsLargerThanTheEE56C5(String value) {
    return 'تصویر از سقف $value MB بزرگ‌تر است.';
  }

  @override
  String uiFileIsLargerThanTheAF488F(String value) {
    return 'فایل از سقف $value MB بزرگ‌تر است.';
  }

  @override
  String uiSendValueBF4C3C(String value) {
    return 'ارسال $value';
  }

  @override
  String get uiRecent76EEC7 => 'اخیر';

  @override
  String get uiConestSeesOnlyThePhotosEE1926 =>
      'Conest فقط عکس‌های انتخابی شما را می‌بیند.';

  @override
  String get uiPhotosPermissionDeniedUseBrowseD672EE =>
      'مجوز عکس رد شد. برای ارسال هر فایل از «مرور فایل‌ها…» استفاده کنید یا در تنظیمات سیستم دسترسی بدهید.';

  @override
  String get uiNoPhotosOrVideosHereC729D1 => 'اینجا عکس یا ویدیویی نیست.';

  @override
  String get uiCouldNotDecodeTheImage69AC9D =>
      'رمزگشایی تصویر برای چرخش ممکن نشد.';

  @override
  String uiRotationFailedValue176CC6(String value) {
    return 'چرخش ناموفق بود: $value';
  }

  @override
  String uiValueOfValueVerified63B11D(String value, String value2) {
    return '$value از $value2 تأیید شد';
  }

  @override
  String get uiPointTheCameraAtA9BAFAF => 'دوربین را به QR دعوت Conest بگیرید.';

  @override
  String get statusMatrixRoomsShowJoinsAndE8AC9E =>
      'ورود و خروج در اتاق‌های Matrix نمایش داده می‌شود.';

  @override
  String get statusMatrixRoomsHideJoinsAndE00610 =>
      'ورود و خروج در اتاق‌های Matrix پنهان می‌شود.';

  @override
  String statusAppMode95B48F(String value) {
    return 'حالت برنامه: $value.';
  }

  @override
  String statusCalling7A8C67(String value) {
    return 'در حال تماس با $value…';
  }

  @override
  String get statusUpdatedHistoryVisibilityForFutureDA1A23 =>
      'نمایانی تاریخچه برای اعضای آیندهٔ گروه به‌روز شد.';

  @override
  String statusVaultUnlockFailedAE7813(String value) {
    return 'بازگشایی گاوصندوق ناموفق بود: $value';
  }

  @override
  String get statusDirectOnlineTransportIsUnavailableB1EFAE =>
      'انتقال مستقیم آنلاین در دسترس نیست؛ مسیر جایگزین رله فعال است.';

  @override
  String get statusNostrCarrierSetUpE82998 => 'حامل Nostr تنظیم شد.';

  @override
  String get statusNostrCarrierRemovedCB968A => 'حامل Nostr حذف شد.';

  @override
  String get statusNostrRelaysUpdatedARelay03F8F3 =>
      'رله‌های Nostr به‌روز شدند: یک رله بسته شد.';

  @override
  String get statusTorCarrierSetUp3D2304 => 'حامل Tor تنظیم شد.';

  @override
  String get statusTorCarrierRemovedAAC23E => 'حامل Tor حذف شد.';

  @override
  String get statusBluetoothMeshOn11FD21 => 'شبکهٔ مش Bluetooth روشن شد.';

  @override
  String get statusBluetoothMeshOff2CE954 => 'شبکهٔ مش Bluetooth خاموش شد.';

  @override
  String get statusNostrMessagesOn35ABF5 => 'پیام‌های Nostr روشن شد.';

  @override
  String get statusNostrMessagesOff16BCA7 => 'پیام‌های Nostr خاموش شد.';

  @override
  String get statusDeltaChatOn1F38AA => 'Delta Chat روشن شد.';

  @override
  String get statusDeltaChatOff8BDBD4 => 'Delta Chat خاموش شد.';

  @override
  String statusBitchatUsersNearbyCanNow5536CD(String value) {
    return 'کاربران نزدیک bitchat اکنون شما را با نام $value می‌بینند.';
  }

  @override
  String get statusBitchatUsersNoLongerSee68B46D =>
      'کاربران bitchat دیگر شما را نمی‌بینند.';

  @override
  String statusMeshcoreCarrierSetUpThroughE51369(String value) {
    return 'حامل MeshCore از $value تنظیم شد.';
  }

  @override
  String get statusMeshcoreCarrierRemoved38FC35 => 'حامل MeshCore حذف شد.';

  @override
  String statusMeshtasticCarrierSetUpThroughAFA24A(String value) {
    return 'حامل Meshtastic از $value تنظیم شد.';
  }

  @override
  String get statusMeshtasticCarrierRemoved66387E => 'حامل Meshtastic حذف شد.';

  @override
  String get statusMeshtasticAppMessagesOn2C1888 =>
      'پیام‌های برنامهٔ Meshtastic روشن شد.';

  @override
  String get statusMeshtasticAppMessagesOffAFB9E8 =>
      'پیام‌های برنامهٔ Meshtastic خاموش شد.';

  @override
  String get statusMeshcoreAppMessagesOn2BF1E3 =>
      'پیام‌های برنامهٔ MeshCore روشن شد.';

  @override
  String get statusMeshcoreAppMessagesOffE59C90 =>
      'پیام‌های برنامهٔ MeshCore خاموش شد.';

  @override
  String statusReticulumCarrierSetUpThrough7EB41E(String value) {
    return 'حامل Reticulum از $value تنظیم شد.';
  }

  @override
  String get statusReticulumCarrierRemoved301C05 => 'حامل Reticulum حذف شد.';

  @override
  String statusEmailCarrierSetUpAs8427FD(String value) {
    return 'حامل ایمیل با نشانی $value تنظیم شد.';
  }

  @override
  String get statusEmailCarrierRemoved036E51 => 'حامل ایمیل حذف شد.';

  @override
  String statusImportedRelaySFromB1DB2D(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value رله از $value2 وارد شد.',
      one: '$value رله از $value2 وارد شد.',
    );
    return '$_temp0';
  }

  @override
  String statusRemovedImportedRelaySource3F4540(String value) {
    return 'منبع واردشدهٔ رلهٔ $value حذف شد.';
  }

  @override
  String get statusPairingCodeRotatedAndAdvertised722FB9 =>
      'کد جفت‌سازی تغییر و اعلام شد.';

  @override
  String statusCheckedRouteSAvailableE9B9D6(
    int value,
    int value2,
    String value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value مسیر بررسی شد؛ $value2 موجود است. $value3',
      one: '$value مسیر بررسی شد؛ $value2 موجود است. $value3',
    );
    return '$_temp0';
  }

  @override
  String statusCheckedIrohPathSFor038B43(
    String value,
    String value2,
    String value3,
  ) {
    return 'مسیرهای Iroh برای $value بررسی شد؛ وضعیت دسترسی $value2 است. $value3';
  }

  @override
  String statusNoPathsAreAdvertisedForA37EA3(String value) {
    return 'هیچ مسیری برای $value اعلام نشده.';
  }

  @override
  String statusCheckedPathSForAvailable0970F6(
    int value,
    String value2,
    int value3,
    String value4,
    String value5,
    String value6,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other:
          '$value مسیر برای $value2 بررسی شد؛ $value3 موجود است$value4. وضعیت دسترسی $value5 است. $value6',
      one:
          '$value مسیر برای $value2 بررسی شد؛ $value3 موجود است$value4. وضعیت دسترسی $value5 است. $value6',
    );
    return '$_temp0';
  }

  @override
  String get statusDisplayNameUpdated3BD31A => 'نام نمایشی به‌روز شد.';

  @override
  String get statusBioCleared543896 => 'دربارهٔ من پاک شد.';

  @override
  String get statusBioUpdated440110 => 'دربارهٔ من به‌روز شد.';

  @override
  String get statusContactProfileUpdated47ECF6 => 'نمایهٔ مخاطب به‌روز شد.';

  @override
  String get statusRelayModeEnabledB9ACB8 => 'حالت رله روشن شد.';

  @override
  String get statusRelayModeDisabled723F4D => 'حالت رله خاموش شد.';

  @override
  String get statusContactsCanNowContributeRelay147ECE =>
      'مخاطبان اکنون می‌توانند مسیر رله را خودکار ارائه کنند.';

  @override
  String get statusAutomaticContactRelayUsageDisabledE762A7 =>
      'استفادهٔ خودکار از رلهٔ مخاطبان خاموش شد.';

  @override
  String get statusNotificationsEnabledF70668 => 'اعلان‌ها روشن شد.';

  @override
  String get statusNotificationsDisabledForThisDeviceE10A46 =>
      'اعلان‌ها در این دستگاه خاموش شد.';

  @override
  String get statusExperimentalVoiceCallsEnabledOn4081DE =>
      'تماس صوتی آزمایشی در این دستگاه روشن شد.';

  @override
  String get statusExperimentalVoiceCallsDisabledOn19A5AE =>
      'تماس صوتی آزمایشی در این دستگاه خاموش شد.';

  @override
  String get statusAndroidBackgroundRuntimeEnabledIfAA5168 =>
      'اجرای پس‌زمینهٔ Android روشن شد. اگر سیستم دسترسی باتری یا پس‌زمینه را مسدود کند، اعلان‌ها ممکن است دیر برسند یا نرسند.';

  @override
  String get statusAndroidBackgroundRuntimeDisabled5FC9A0 =>
      'اجرای پس‌زمینهٔ Android خاموش شد.';

  @override
  String get statusBackgroundVoiceCallAvailabilityEnabledA87223 =>
      'دسترسی تماس صوتی پس‌زمینه روشن شد. تماس فقط وقتی می‌رسد که سرویس Conest اجازهٔ اجرا داشته باشد.';

  @override
  String get statusBackgroundVoiceCallAvailabilityDisabledA71AD1 =>
      'دسترسی تماس صوتی پس‌زمینه خاموش شد.';

  @override
  String get statusFreeSpaceReserveEnabledD7CE0E =>
      'نگهداری ۱۰٪ فضای خالی روشن شد.';

  @override
  String get statusFreeSpaceReserveDisabledD3E635 =>
      'نگهداری ۱۰٪ فضای خالی خاموش شد.';

  @override
  String statusRoutingPreferencesUpdatedFor05867B(String value) {
    return 'ترجیحات مسیریابی $value به‌روز شد.';
  }

  @override
  String statusLocalRelayPortUpdatedTo7F815D(String value) {
    return 'درگاه رلهٔ محلی به $value تغییر کرد.';
  }

  @override
  String statusRelayAdded800692(String value) {
    return 'رلهٔ $value افزوده شد.';
  }

  @override
  String statusRelayAddedFor087398(String value, String value2, String value3) {
    return 'رلهٔ $value:$value2 برای $value3 افزوده شد.';
  }

  @override
  String statusRelayRemoved546A15(String value) {
    return 'رلهٔ $value حذف شد.';
  }

  @override
  String statusTrustedNewIdentityForRelay4CDBFE(String value) {
    return 'به هویت تازهٔ رلهٔ $value اعتماد شد.';
  }

  @override
  String get statusContactRemovedE31CE0 => 'مخاطب حذف شد.';

  @override
  String get statusContactRemovedLocallySendingA40D607 =>
      'مخاطب محلی حذف شد. اعلان حذف در پس‌زمینه فرستاده می‌شود.';

  @override
  String get statusDeviceCreatedShareAQr06E7B6 =>
      'دستگاه ساخته شد. برای افزودن مخاطب، دعوت QR یا عبارت اتصال فعلی را به اشتراک بگذارید.';

  @override
  String statusContactAcceptedSendingApprovalOverDAD10C(String value) {
    return 'مخاطب $value پذیرفته شد. تأیید از مسیرهای موجود ارسال می‌شود.';
  }

  @override
  String statusContactSavedWaitingForThe41F77D(String value) {
    return 'مخاطب $value ذخیره شد. در انتظار تأیید درخواست از طرف مقابل.';
  }

  @override
  String statusReconnectedWithBC62EC(String value) {
    return 'با $value دوباره متصل شدیم.';
  }

  @override
  String statusAskingToReconnectE93389(String value) {
    return 'از $value درخواست اتصال دوباره می‌شود.';
  }

  @override
  String statusConfirmedIdentityReplacementForC93359(String value) {
    return 'جایگزینی هویت $value تأیید شد.';
  }

  @override
  String statusRejectedIdentityReplacementForDEC894(String value) {
    return 'جایگزینی هویت $value رد شد.';
  }

  @override
  String get statusContactRequestCancelledQueuedItemsEC2567 =>
      'درخواست ارتباط لغو شد. موارد در صف مسدود می‌مانند.';

  @override
  String get statusSaved9D4AF6 => 'ذخیره شد.';

  @override
  String statusMessageSavedLocallyItWill0DBD03(String value) {
    return 'پیام محلی ذخیره شد. پس از پذیرش درخواست توسط $value ارسال می‌شود.';
  }

  @override
  String statusTryingLanFirstThenRelay1F5BEC(String value) {
    return 'نخست شبکهٔ محلی و سپس رله برای $value امتحان می‌شود.';
  }

  @override
  String get statusMessageQueuedTheAppWillA89BCC =>
      'پیام در صف است. برنامه هنگام بررسی، مسیرهای مستقیم و رله را دوباره امتحان می‌کند.';

  @override
  String statusAttachmentIsWaitingForA3F032B(String value) {
    return 'پیوست منتظر مسیر است: $value';
  }

  @override
  String statusCouldNotPrepareForDownloadE8FB18(String value) {
    return 'آماده‌سازی $value برای بارگیری ممکن نشد.';
  }

  @override
  String statusCreatedGroupF5D335(String value) {
    return 'گروه $value ساخته شد.';
  }

  @override
  String statusUpdatedGroup2140B7(String value) {
    return 'گروه $value به‌روز شد.';
  }

  @override
  String statusRemovedAMemberFrom68CF04(String value) {
    return 'عضوی از $value حذف شد.';
  }

  @override
  String statusLeftGroup9E3412(String value) {
    return 'از گروه $value خارج شدید.';
  }

  @override
  String statusRemovedGroupFromYourList047F4B(String value) {
    return 'گروه $value از فهرست شما حذف شد.';
  }

  @override
  String statusTransferredOwnershipOfToA126A1(String value, String value2) {
    return 'مالکیت $value به $value2 منتقل شد.';
  }

  @override
  String statusDeletedGroupForEveryoneDB26F8(String value) {
    return 'گروه $value برای همه حذف شد.';
  }

  @override
  String statusUpdatedIn642C0A(String value, String value2) {
    return '$value در $value2 به‌روز شد.';
  }

  @override
  String statusSendingGroupMessageToD77236(String value) {
    return 'در حال ارسال پیام گروه به $value.';
  }

  @override
  String statusSentToAsAPlainAF2DE6(String value) {
    return 'به $value به‌صورت پیام عادی Matrix ارسال شد.';
  }

  @override
  String statusCanceledAndDeletedPendingMessageCDCA88(String value) {
    return 'پیام منتظر به $value لغو و حذف شد.';
  }

  @override
  String get statusMessageDeletedLocallyCE90EE => 'پیام محلی حذف شد.';

  @override
  String statusMessageDeletedHereAndDeletion7C4E80(String value) {
    return 'پیام اینجا حذف شد و درخواست حذف به $value رفت.';
  }

  @override
  String get statusMessageDeletedHereRemoteDeletionB6AE62 =>
      'پیام اینجا حذف شد. درخواست حذف از راه دور هنوز ارسال نشده.';

  @override
  String get statusMessageEditedLocally187334 => 'پیام محلی ویرایش شد.';

  @override
  String statusMessageEditQueuedTo695B15(String value) {
    return 'ویرایش پیام برای $value در صف است.';
  }

  @override
  String get statusReactionUpdatedLocally97D795 => 'واکنش محلی به‌روز شد.';

  @override
  String statusReactionQueuedToD43BED(String value) {
    return 'واکنش برای $value در صف است.';
  }

  @override
  String get statusLanLobbyMessageSavedLocallyFDE86E =>
      'پیام لابی محلی ذخیره شد؛ هیچ شرکت‌کنندهٔ محلی نزدیک در دسترس نبود.';

  @override
  String statusLanLobbyMessageSentTo82F0B0(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'پیام لابی محلی از $value مسیر نزدیک ارسال شد.',
      one: 'پیام لابی محلی از $value مسیر نزدیک ارسال شد.',
    );
    return '$_temp0';
  }

  @override
  String statusGroupMembershipAckFrom43FCF1(String value, String value2) {
    return 'تأیید عضویت گروه $value از $value2.';
  }

  @override
  String statusReceivedItemSVia58B082(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value مورد از $value2 دریافت شد.',
      one: '$value مورد از $value2 دریافت شد.',
    );
    return '$_temp0';
  }

  @override
  String statusRoutePollFailedA1FD0C(String value) {
    return 'بررسی مسیرها ناموفق بود: $value';
  }

  @override
  String statusLanReceivingIsOffPort5F04CB(String value) {
    return 'دریافت محلی خاموش است: درگاه $value اشغال است. در تنظیمات درگاه رلهٔ محلی دیگری انتخاب کنید.';
  }

  @override
  String statusRediscoveredLanRouteFor587829(String value, String value2) {
    return 'مسیر محلی $value برای $value2 دوباره پیدا شد.';
  }

  @override
  String statusLanDiscoveryUnavailable0E99AE(String value) {
    return 'کشف شبکهٔ محلی در دسترس نیست: $value';
  }

  @override
  String get statusUpdatedNearbyLanRoutesF8CAFC =>
      'مسیرهای محلی نزدیک به‌روز شدند.';

  @override
  String statusRejectedMalformedAttachmentOfferFrom9FC96A(String value) {
    return 'پیشنهاد پیوست نادرست از $value رد شد.';
  }

  @override
  String get statusRejectedInvalidAttachmentMetadata849465 =>
      'فرادادهٔ نامعتبر پیوست رد شد.';

  @override
  String statusDeclinedTheRequestQueuedMessagesABFFCB(String value) {
    return '$value درخواست را رد کرد. پیام و فایل‌های در صف مسدود می‌مانند.';
  }

  @override
  String statusNewContactRequestFromCF70B9(String value) {
    return 'درخواست ارتباط تازه از $value.';
  }

  @override
  String statusLeftF4FE32(String value, String value2) {
    return '$value از $value2 خارج شد.';
  }

  @override
  String statusRemovedYouTheConversationRemains3BB516(String value) {
    return '$value شما را حذف کرد. گفت‌وگو محلی بایگانی می‌ماند.';
  }

  @override
  String statusUpdatedEditedMessageFrom1AB90D(String value) {
    return 'پیام ویرایش‌شدهٔ $value به‌روز شد.';
  }

  @override
  String statusDeletedMessageRemovedBy5A9E79(String value) {
    return 'پیامی که $value حذف کرد برداشته شد.';
  }

  @override
  String statusAppliedAReactionFrom41011B(String value) {
    return 'واکنش $value اعمال شد.';
  }

  @override
  String get statusAppliedDeferredDirectReactions1414C8 =>
      'واکنش‌های مستقیم معوق اعمال شد.';

  @override
  String statusEncryptedMessageStoredForVia029324(String value, String value2) {
    return 'پیام رمزگذاری‌شده برای $value از $value2 ذخیره شد.';
  }

  @override
  String statusSentToViaWaitingForEA766D(String value, String value2) {
    return 'به $value از $value2 ارسال شد؛ در انتظار تأیید تحویل.';
  }

  @override
  String statusDeliveryRetryPending93EAA3(String value) {
    return 'تلاش دوبارهٔ تحویل در انتظار است: $value';
  }

  @override
  String statusGroupDeliveryRetryPending691CA4(String value) {
    return 'تلاش دوبارهٔ تحویل گروه در انتظار است: $value';
  }

  @override
  String statusRelayIdentityChangedVerifyWith6F3689(String value) {
    return 'هویت رلهٔ $value تغییر کرد؛ از گرداننده تأیید بگیرید.';
  }

  @override
  String statusRelayIdentityMismatchVerifyWith2D3B10(
    String value,
    String value2,
  ) {
    return 'هویت رلهٔ $value:$value2 مطابقت ندارد؛ از گرداننده تأیید بگیرید.';
  }

  @override
  String get statusTheMatrixSignInExpired76ABA4 =>
      'ورود Matrix منقضی شد. برای استفاده دوباره وارد شوید.';

  @override
  String statusSignedInToMatrixAs5103D2(String value) {
    return 'با نام $value به Matrix وارد شدید.';
  }

  @override
  String get statusSignedOutOfMatrix1D1860 => 'از Matrix خارج شدید.';

  @override
  String statusSOtherDevicesHaveNot07F30F(String value, String value2) {
    return 'دستگاه‌های دیگر $value مدتی است از $value2 بی‌خبرند: ممکن است پیام‌های آن از صاحب حساب نباشد.';
  }

  @override
  String statusReceivedItemSInstantlyViaA7773B(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value مورد فوری از رلهٔ محلی دریافت شد.',
      one: '$value مورد فوری از رلهٔ محلی دریافت شد.',
    );
    return '$_temp0';
  }

  @override
  String statusReceivedItemSViaLocal71A104(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value مورد از صندوق محلی دریافت شد.',
      one: '$value مورد از صندوق محلی دریافت شد.',
    );
    return '$_temp0';
  }

  @override
  String get statusNoNewProtocols => 'پروتکل رلهٔ تازه‌ای پیدا نشد.';

  @override
  String get statusRouteExchangeRequested => 'تبادل اطلاعات مسیر درخواست شد.';

  @override
  String get statusRouteExchangePending =>
      'درخواست تبادل مسیر هنوز ارسال نشده.';

  @override
  String get statusKnownRoutes => 'مسیرهای شناخته‌شده';

  @override
  String get statusReachable => 'در دسترس';

  @override
  String get statusUnreachable => 'دور از دسترس';

  @override
  String get statusUnknown => 'نامشخص';

  @override
  String get statusExpired => 'قدیمی';

  @override
  String get connectionsTitle => 'اتصال‌ها';

  @override
  String get connectionsDescription =>
      'کدام دستگاه به کدام می‌رسد، دوطرفه یا یک‌طرفه.';

  @override
  String get relayUdpHint => 'udp://host:port استفاده از UDP را اجباری می‌کند';

  @override
  String get deltaFileActions => 'عملیات فایل';

  @override
  String get deltaForward => 'بازفرست';

  @override
  String get deltaAttach => 'پیوست';

  @override
  String get deltaSendVoice => 'ارسال پیام صوتی';

  @override
  String get deltaDiscardVoice => 'دور انداختن پیام صوتی';

  @override
  String get deltaRecordVoice => 'ضبط پیام صوتی';

  @override
  String get deltaReact => 'واکنش';

  @override
  String get savedMessagesPreview => 'یادداشت، فایل و بازفرست برای خودتان';

  @override
  String networkChatsTitle(String network) {
    return 'گفت‌وگوهای $network';
  }

  @override
  String get networkEncryptedMatrixChat => 'گفت‌وگوی رمزگذاری‌شدهٔ Matrix';

  @override
  String get networkMatrixChat => 'گفت‌وگوی Matrix';

  @override
  String get networkEveryoneBluetooth => 'همهٔ افراد در برد Bluetooth';

  @override
  String get inviteNoRoutes => 'مسیری اعلام نشده';

  @override
  String get deliveryPending => 'در انتظار مسیر در دسترس';

  @override
  String get deliveryLocal => 'از شبکهٔ محلی ارسال شد؛ در انتظار تأیید تحویل';

  @override
  String get deliveryRelayed => 'در صف رله؛ در انتظار تأیید تحویل';

  @override
  String get deliveryDelivered => 'تحویل شد';

  @override
  String get deliveryRead => 'خوانده شد';

  @override
  String get reachabilityOnline => 'آنلاین';

  @override
  String get reachabilityRecent => 'به‌تازگی دیده شده';

  @override
  String get reachabilityKnown => 'شناخته‌شده';

  @override
  String get transferApproval => 'در انتظار تأیید';

  @override
  String get transferPeer => 'در انتظار همتا';

  @override
  String get routeLanDirect => 'مستقیم شبکهٔ محلی';

  @override
  String get routeInternetDirect => 'مستقیم اینترنت';

  @override
  String get routeIrohDirect => 'Iroh مستقیم';

  @override
  String get routeConestRelay => 'رلهٔ Conest';

  @override
  String get routeOptical => 'نوری';

  @override
  String get routeViaContact => 'از طریق مخاطب';

  @override
  String get themeSystem => 'سیستم';

  @override
  String get themeLight => 'Signature · روشن';

  @override
  String get themeDark => 'Signature · تیره';

  @override
  String get themeBlack => 'Signature · سیاه (OLED)';

  @override
  String get themeAdaptive => 'تطبیقی (پس‌زمینه)';

  @override
  String get layoutSignalCards => 'کارت‌های سیگنال';

  @override
  String get layoutStationFeed => 'خوراک ایستگاه';

  @override
  String get layoutClassic => 'ردیف‌های کلاسیک';

  @override
  String get layoutSignalDescription =>
      'همتایان به‌صورت کارت اتصال در داشبورد.';

  @override
  String get layoutFeedDescription => 'گزارش زمانی بسته‌ها و فعالیت.';

  @override
  String get layoutClassicDescription => 'فهرست فشردهٔ تک‌خطی.';

  @override
  String get shellSignatureDescription => 'نوار کناری داشبورد اصلی Conest.';

  @override
  String get shellGarrisonDescription =>
      'مانند Discord: نوار خانه‌ها و گفت‌وگوها.';

  @override
  String get shellCourierDescription =>
      'مانند Telegram: یک فهرست سادهٔ گفت‌وگو.';

  @override
  String get connectionsBothWays => 'دوطرفه';

  @override
  String get connectionsInbound => 'فقط از آن‌ها';

  @override
  String get connectionsFailing => 'ناموفق';

  @override
  String get connectionsUnknown => 'خبر تازه‌ای نیست';

  @override
  String voiceConnected(String time) {
    return 'متصل · $time';
  }

  @override
  String messageClockAhead(String amount) {
    return 'ساعت او حدود $amount جلو است؛ زمان‌های اینجا بر اساس این دستگاه‌اند.';
  }

  @override
  String messageClockBehind(String amount) {
    return 'ساعت او حدود $amount عقب است؛ زمان‌های اینجا بر اساس این دستگاه‌اند.';
  }

  @override
  String messageNotRecentlyConfirmed(String date) {
    return 'به‌تازگی تأیید نشده: دیگر دستگاه‌های او آخرین بار در $date این دستگاه را متعلق به او دانستند.';
  }

  @override
  String get routeLanDirectDescription =>
      'مستقیم به دستگاه دیگر در شبکهٔ محلی شما.';

  @override
  String get routeLanRelayDescription =>
      'از طریق گره رلهٔ دستگاهی دیگر در شبکهٔ محلی شما.';

  @override
  String get routeLanLobbyDescription =>
      'صندوق پیام مشترک لابی شبکهٔ محلی؛ هر کسی در شبکه می‌تواند آن را بخواند.';

  @override
  String get routeInternetDirectDescription =>
      'مستقیم به گره رلهٔ دستگاه دیگر از طریق اینترنت.';

  @override
  String get routeIrohDirectDescription =>
      'همتا‌به‌همتا از طریق Iroh، با رمزگذاری سرتاسری.';

  @override
  String get routeIrohRelayDescription =>
      'از طریق سرور رلهٔ Iroh که فقط ترافیک رمزگذاری‌شده را می‌بیند.';

  @override
  String get routeConestRelayDescription =>
      'سرور رلهٔ Conest آن را ذخیره و ارسال می‌کند و فقط پاکت‌های رمزگذاری‌شده را می‌بیند.';

  @override
  String get routeMatrixDescription =>
      'از طریق Matrix منتقل می‌شود و همچنان با Conest رمزگذاری سرتاسری دارد؛ سرور خانگی طرف‌های ارتباط و زمان آن را می‌بیند.';

  @override
  String get routePlainMatrixDescription =>
      'به‌صورت پیام عادی Matrix ارسال می‌شود؛ اگر اتاق رمزگذاری نشده باشد سرور خانگی می‌تواند آن را بخواند.';

  @override
  String get routeNostrDescription =>
      'از طریق رله‌های Nostr منتقل می‌شود و همچنان با Conest رمزگذاری سرتاسری دارد؛ رله‌ها گیرنده و زمان را می‌بینند، نه فرستنده را.';

  @override
  String get routeEmailDescription =>
      'از طریق ایمیل منتقل می‌شود و همچنان با Conest رمزگذاری سرتاسری دارد؛ سرورهای ایمیل هر دو نشانی و زمان را می‌بینند.';

  @override
  String get routeReticulumDescription =>
      'از طریق Reticulum، با رادیو یا شبکهٔ Reticulum، با رمزگذاری سرتاسری.';

  @override
  String get routeMeshtasticDescription =>
      'از طریق مش رادیویی Meshtastic، با رمزگذاری سرتاسری.';

  @override
  String get routeMeshCoreDescription =>
      'از طریق مش رادیویی MeshCore، با رمزگذاری سرتاسری.';

  @override
  String get routeBluetoothDescription =>
      'از طریق مش Bluetooth و دستگاه‌های نزدیک، با رمزگذاری سرتاسری.';

  @override
  String get routeTorDescription =>
      'میان سرویس‌های onion از طریق Tor؛ هیچ واسطه‌ای طرف‌های ارتباط را نمی‌بیند.';

  @override
  String get routeContactDescription =>
      'مخاطبی که به دستگاه دیگر دسترسی دارد آن را منتقل می‌کند؛ همچنان رمزگذاری سرتاسری دارد و مخاطب فقط گیرنده و زمان را می‌بیند.';

  @override
  String routeTestRoundTrip(String route, String ms) {
    return '$route: رفت‌وبرگشت $ms میلی‌ثانیه';
  }

  @override
  String routeTestStored(String route) {
    return '$route: در رله مانده (پس از دریافت پاسخ می‌دهد)';
  }

  @override
  String routeTestNoAnswer(String route) {
    return '$route: پاسخی نیست';
  }

  @override
  String transferTimeLeft(String time) {
    return '$time باقی مانده';
  }

  @override
  String transferQueuePosition(String position) {
    return 'صف #$position';
  }

  @override
  String get transferTapRetry => 'برای تلاش دوباره بزنید';

  @override
  String get transferRerouting => 'تغییر مسیر';

  @override
  String get routeShortLobby => 'لابی';

  @override
  String get routeShortDirect => 'مستقیم';

  @override
  String get routeShortRelay => 'رله';

  @override
  String get routeShortContact => 'از طریق مخاطب';

  @override
  String chatDraftPreview(String text) {
    return 'پیش‌نویس: $text';
  }

  @override
  String get routeAutomaticFallback => 'جایگزینی خودکار ✓';

  @override
  String get releaseNightly => 'شبانه';

  @override
  String get releaseStable => 'پایدار';

  @override
  String get callActive => 'تماس فعال';

  @override
  String get callGeneric => 'تماس';

  @override
  String get contactNotPinned => 'پین نشده';

  @override
  String get groupUnknownMember => 'یک عضو';

  @override
  String get relaySourceSigned => 'امضاشده';

  @override
  String get relaySourceUnsigned => 'بدون امضا';

  @override
  String get beamFingerprintUnavailable => 'اثر انگشت در دسترس نیست';

  @override
  String get fileOriginalMetadataWarning =>
      'جزئیات مکان، دوربین، نویسنده و تاریخ همراه آن ارسال می‌شود.';

  @override
  String get routeMarkSent => 'ارسال شد';

  @override
  String get routeMarkStored => 'در انتظار رله';

  @override
  String get routeMarkReached => 'به دستگاه او رسید';

  @override
  String get routeMarkDelivered => 'تحویل شد';

  @override
  String get routeMarkReceived => 'دریافت شد';

  @override
  String get relayHostOrLinkLabel => 'میزبان، نشانی یا پیوند رله';

  @override
  String get relayLinkHint => 'conest-relay://… از نصب‌کننده آن';

  @override
  String get brokenPartNotice => 'اینجا مشکلی پیش آمد.';

  @override
  String get crashNoticeBody =>
      'Conest دفعهٔ پیش به‌طور غیرمنتظره بسته شد. جزئیات روی همین دستگاه می‌ماند؛ می‌توانید آن را در گزارش خطا کپی کنید.';

  @override
  String get crashNoticeDetails => 'جزئیات';

  @override
  String get crashNoticeDismiss => 'بستن پیام';

  @override
  String get crashReportTitle => 'چه اتفاقی افتاد';

  @override
  String get crashReportCopy => 'کپی';

  @override
  String get crashReportClose => 'بستن';

  @override
  String get connectionsNetworks => 'شبکه‌هایی که این دستگاه به آن‌ها وصل بوده';

  @override
  String get connectionsNetworkNow => 'اکنون در حال استفاده';

  @override
  String connectionsNetworkLastSeen(String date) {
    return 'آخرین بار $date';
  }

  @override
  String get connectionsRouteWorks => 'کار می‌کند';

  @override
  String get connectionsRouteBlocked => 'در این شبکه مسدود است';

  @override
  String get connectionsRouteFailing => 'خطا دارد';

  @override
  String connectionsAsOf(String when) {
    return 'تا $when';
  }

  @override
  String get bluetoothMeshNeedsAttention => 'شبکهٔ بلوتوث نیاز به بررسی دارد';

  @override
  String forwardSelectedTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'بازارسال $count پیام',
      one: 'بازارسال $count پیام',
    );
    return '$_temp0';
  }

  @override
  String forwardedSummary(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count پیام بازارسال شد',
      one: '$count پیام بازارسال شد',
    );
    return '$_temp0';
  }

  @override
  String forwardSkipped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count فایل هنوز روی این دستگاه نیست و کنار گذاشته شد',
      one: '$count فایل هنوز روی این دستگاه نیست و کنار گذاشته شد',
    );
    return '$_temp0';
  }

  @override
  String get torBlockedHint =>
      'به نظر می‌رسد Tor در این شبکه مسدود است. پل‌ها این مسدودسازی را دور می‌زنند، اما پل‌های عمومی هم اغلب مسدودند: پل‌های خودتان را بگیرید (پایین).';

  @override
  String get torGetBridgesTitle => 'چگونه پل‌های خودتان را بگیرید';

  @override
  String get torGetBridgesIntro =>
      'Tor Project پل‌ها را از این راه‌ها می‌دهد. پل‌های obfs4 یا webtunnel بخواهید، سپس خط‌ها را در بالا بچسبانید.';

  @override
  String get torGetBridgesWeb => 'وب‌سایت: bridges.torproject.org';

  @override
  String get torGetBridgesTelegram => 'تلگرام: به ‎@GetBridgesBot پیام دهید';

  @override
  String get torGetBridgesEmail =>
      'ایمیل: از یک نشانی Gmail یا Riseup به bridges@torproject.org بنویسید';

  @override
  String get torGetBridgesFriend =>
      'یا از کسی که به او اعتماد دارید و از Tor استفاده می‌کند بخواهید یک خط پل با شما به اشتراک بگذارد.';

  @override
  String get transportsTitle => 'دسترسی به افراد بیرون از این شبکه';

  @override
  String get transportsIntro =>
      'دستگاه‌های این شبکه مستقیماً به شما می‌رسند. برای دیگران، Conest دست‌کم به یک راه از طریق اینترنت نیاز دارد و سه راه بهتر است، چون شبکه‌ها برخی از آن‌ها را مسدود می‌کنند. این‌ها اکنون در این شبکه کار می‌کنند.';

  @override
  String get transportsChecking => 'در حال بررسی آنچه در این شبکه کار می‌کند…';

  @override
  String transportsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count راه آماده: ۳ توصیه می‌شود',
      one: '$count راه آماده: ۳ توصیه می‌شود',
      zero: 'هنوز هیچ‌کدام: ۱ لازم است، ۳ توصیه می‌شود',
    );
    return '$_temp0';
  }

  @override
  String get transportStateOn => 'کار می‌کند';

  @override
  String get transportStateWorks => 'اینجا کار می‌کند';

  @override
  String get transportStateBlocked => 'اینجا مسدود است';

  @override
  String get transportStateNeedsSetup => 'بعداً در تنظیمات راه‌اندازی کنید';

  @override
  String get transportsEmailCost =>
      'صندوق نامه را بررسی می‌کند: کمی داده و باتری بیشتر.';

  @override
  String get transportsSkipTitle =>
      'فقط دستگاه‌های نزدیک می‌توانند به شما برسند';

  @override
  String get transportsSkipBody =>
      'بدون راهی از طریق اینترنت، فقط دستگاه‌های این شبکه می‌توانند به شما برسند و شما هم فقط به آن‌ها. بعداً می‌توانید در تنظیمات، بخش اتصال، راهی راه‌اندازی کنید.';

  @override
  String get transportsSkipConfirm => 'به هر حال ادامه دهید';

  @override
  String get transportsBanner =>
      'اکنون فقط دستگاه‌های این شبکه می‌توانند به شما برسند. راهی از طریق اینترنت راه‌اندازی کنید.';

  @override
  String get transportsBannerAction => 'راه‌اندازی';

  @override
  String get transportsBannerDismiss => 'اکنون نه';

  @override
  String transportsTurnOnFailed(String name, String error) {
    return '$name روشن نشد: $error';
  }

  @override
  String get transportsHowToChoose => 'چطور انتخاب کنیم';

  @override
  String get settingsUserGuide => 'راهنمای کاربر';

  @override
  String get settingsEnterSends => 'Enter پیام را می‌فرستد';

  @override
  String get settingsEnterSendsHelp =>
      'Shift+Enter خط تازه می‌سازد. خاموش: Enter خط تازه می‌سازد و Ctrl+Enter می‌فرستد.';

  @override
  String get menuCopySelection => 'کپی متن انتخاب‌شده';

  @override
  String get linkLookalikeTitle => 'این پیوند باز شود؟';

  @override
  String linkLookalikeBody(String host) {
    return 'نشانی $host حروفی از الفباهای دیگر دارد. ممکن است از سایتی که می‌شناسید تقلید کند.';
  }

  @override
  String get linkOpen => 'باز کردن';

  @override
  String get carrierRemove => 'حذف';

  @override
  String carrierRemoveTitle(String name) {
    return '$name حذف شود؟';
  }

  @override
  String carrierRemoveBody(String name) {
    return 'مخاطبان دیگر از طریق $name به شما نمی‌رسند و آنچه این دستگاه برایش نگه داشته فراموش می‌شود. راه‌اندازی دوباره نشانی تازه‌ای می‌دهد. برای توقف موقت، به‌جای آن کلیدش را خاموش کنید.';
  }

  @override
  String get carrierPaused =>
      'موقتاً متوقف: نگه داشته شده، استفاده نمی‌شود. برای استفادهٔ دوباره روشنش کنید.';

  @override
  String get emailChangeAccount => 'تغییر حساب';

  @override
  String get emailOtherServer => 'استفاده از سرور دیگر';

  @override
  String get actionSave => 'ذخیره';

  @override
  String get settingsLinksTitle => 'پیوندهایی که می‌فرستید و باز می‌کنید';

  @override
  String get settingsCleanLinks => 'حذف ردیابی از پیوندها';

  @override
  String get settingsCleanLinksHelp =>
      'بخش‌هایی از پیوند را که به سایت می‌گویند چه کسی آن را هم‌رسانی کرده (مانند ?si= یا utm_) هنگام فرستادن و باز کردن حذف می‌کند. از قواعد ClearURLs استفاده می‌کند.';

  @override
  String get settingsEmbedLinks => 'پیوندهای دارای پیش‌نمایش';

  @override
  String get settingsEmbedLinksHelp =>
      'پیوندهای پست‌های X، اینستاگرام، ردیت، تیک‌تاک و سایت‌های مشابه از سرویسی می‌گذرند که به برنامه‌های دیگر امکان نمایش پیش‌نمایش می‌دهد و مرورگر را به پست می‌برد. سرویس‌ها از فهرست embed-fixer آمده‌اند؛ سرویسی که کار نکند کنار گذاشته می‌شود.';

  @override
  String get linkCleaned => 'پیوند پاک‌سازی شد';

  @override
  String get linkCleanedUndo => 'واگرد';

  @override
  String get menuOpenOriginalLink => 'باز کردن پیوند اصلی';

  @override
  String get editorSendOriginalAsFile =>
      'فرستادن نسخهٔ اصلی به‌صورت فایل (بدون فشرده‌سازی)';

  @override
  String get linkPreviewShow => 'نمایش پیش‌نمایش پیوند';

  @override
  String get settingsLinkPreviews => 'پیش‌نمایش پیوندها';

  @override
  String get settingsLinkPreviewsHelp =>
      'عنوان و تصویر پیوند را زیر پیام نشان می‌دهد. این دستگاه آن‌ها را از سایت می‌گیرد و سایت نشانی IP شما را می‌بیند: در گفتگو با مخاطبان و گروه‌هایتان به‌طور خودکار (نه در حالت صرفه‌جویی باتری یا رومینگ) و در گفتگوهای دیگر فقط با ضربهٔ شما.';

  @override
  String get linkPreviewModeReceiver => 'هر گیرنده خودش می‌گیرد';

  @override
  String get linkPreviewModeSender =>
      'همراه پیام فرستاده می‌شود (گیرندگان با سایت تماس نمی‌گیرند)';

  @override
  String get linkPreviewModeBoth => 'هر دو';

  @override
  String get linkPreviewModeOff => 'خاموش';

  @override
  String get linkPreviewRemove => 'فرستادن بدون پیش‌نمایش';

  @override
  String get settingsLinkPreviewsTor => 'گرفتن پیش‌نمایش از راه Tor';

  @override
  String get settingsLinkPreviewsTorHelp =>
      'وقتی Tor راه‌اندازی شده باشد، سایت‌ها خروجی Tor را می‌بینند نه نشانی شما را، و دربارهٔ پیوند چیزی در شبکهٔ شما جست‌وجو نمی‌شود. تا Tor وصل نشده، پیش‌نمایشی گرفته نمی‌شود.';

  @override
  String linkPreviewFromSender(String host) {
    return '$host · پیش‌نمایش از فرستنده';
  }

  @override
  String get contentRoutingTitle => 'چه چیزهایی از طریق اینترنت ارسال شود';

  @override
  String get contentRoutingHelp =>
      'شبکه محلی شما همیشه همه چیز را منتقل می‌کند. مخاطبان شما از این انتخاب باخبر می‌شوند: آنچه کنار گذاشته شود منتظر راهی می‌ماند که اجازه انتقال آن را دارد.';

  @override
  String get contentRoutingEverything => 'همه چیز';

  @override
  String get contentRoutingMessagesAndSmallFiles =>
      'پیام‌ها و فایل‌های تا ۱ مگابایت';

  @override
  String get contentRoutingMessagesOnly =>
      'فقط پیام‌ها (فایل‌ها از طریق شبکه محلی)';

  @override
  String get contentRoutingCustom => 'سفارشی';

  @override
  String get contentRoutingByTransport => 'بر اساس روش انتقال';

  @override
  String get contentClassText => 'پیام‌ها';

  @override
  String get contentClassOwnSync => 'دستگاه‌های شما';

  @override
  String get contentClassHistory => 'تاریخچه';

  @override
  String get contentClassFileSmall => 'فایل تا ۱ مگابایت';

  @override
  String get contentClassFileMedium => 'فایل تا ۳۰ مگابایت';

  @override
  String get contentClassFileLarge => 'فایل‌های بزرگ‌تر';

  @override
  String get contentClassCallSignal => 'تماس‌ها';

  @override
  String get contentRoutingCannotCarry =>
      'این روش انتقال نمی‌تواند آن را منتقل کند';

  @override
  String get routeViaOwnDevice => 'از طریق دستگاه دیگر شما';

  @override
  String get routeOwnDeviceDescription =>
      'دستگاه دیگری از شما آن را دریافت کرد و به این دستگاه فرستاد، با رمزگذاری سرتاسری.';

  @override
  String get routeShortOwnDevice => 'دستگاه شما';

  @override
  String get backgroundReceiveTitle => 'دریافت پیام‌ها در پس‌زمینه';

  @override
  String get backgroundReceiveHelp =>
      'پیام‌ها و تماس‌ها وقتی Conest بسته است هم می‌رسند. تا وقتی اجرا می‌شود، Android یک اعلان بی‌صدا نشان می‌دهد.';

  @override
  String get batteryExemptionTitle => 'بهینه‌سازی باتری';

  @override
  String get batteryExemptionAllowed =>
      'بدون محدودیت: Android برنامهٔ Conest را در پس‌زمینه متوقف نمی‌کند.';

  @override
  String get batteryExemptionLimited =>
      'ممکن است Android برنامهٔ Conest را در پس‌زمینه متوقف کند و پیام‌ها تا باز کردن آن منتظر بمانند.';

  @override
  String get batteryExemptionAllow => 'اجازه بده';

  @override
  String get batteryExemptionPromptTitle => 'دریافت پیام‌ها ادامه پیدا کند';

  @override
  String get batteryExemptionPromptBody =>
      'برای دریافت پیام‌ها وقتی Conest بسته است، Android باید اجازه دهد در پس‌زمینه اجرا شود. در صفحهٔ بعد، اجازه دهید Conest بدون محدودیت باتری اجرا شود.';

  @override
  String batteryExemptionVendorHint(String maker) {
    return 'در گوشی‌های $maker، «شروع خودکار» را هم برای Conest روشن کنید و صرفه‌جویی باتری آن را روی «بدون محدودیت» بگذارید (تنظیمات ← برنامه‌ها ← Conest).';
  }

  @override
  String get closeToTrayTitle => 'پس از بستن، در سینی سیستم بماند';

  @override
  String get closeToTrayHelp =>
      'پیام‌ها همچنان می‌رسند. Conest را دوباره از نماد سینی باز کنید یا از همان‌جا خارج شوید.';

  @override
  String get trayShow => 'نمایش Conest';

  @override
  String get trayQuit => 'خروج';

  @override
  String get notificationReply => 'پاسخ';

  @override
  String get notificationMarkRead => 'علامت‌گذاری به‌عنوان خوانده‌شده';

  @override
  String notificationReplyNotSent(String text) {
    return 'ارسال نشد: $text';
  }

  @override
  String get startAtLoginTitle => 'اجرای Conest هنگام ورود به سیستم';

  @override
  String get startAtLoginHelp =>
      'در سینی سیستم باز می‌شود و بدون پنجره آمادهٔ دریافت است.';

  @override
  String get notificationNewMessage => 'پیام جدید';

  @override
  String notificationNewMessageFrom(String name) {
    return 'پیام جدید از $name';
  }

  @override
  String get notificationReplyNotSentPlain => 'یک پاسخ ارسال نشد';

  @override
  String get notificationPreviewTitle => 'نمایش در اعلان‌ها';

  @override
  String get notificationPreviewFull => 'نام و پیام';

  @override
  String get notificationPreviewSender => 'فقط نام';

  @override
  String get notificationPreviewHidden => 'هیچ';

  @override
  String get voiceSettingsTitle => 'صدا';

  @override
  String get voiceInputDevice => 'میکروفون';

  @override
  String get voiceOutputDevice => 'بلندگو یا هدفون';

  @override
  String get voiceSystemDefault => 'پیش‌فرض سیستم';

  @override
  String get voiceInputVolume => 'بلندی میکروفون';

  @override
  String get voiceOutputVolume => 'بلندی صدا';

  @override
  String get voiceMicTest => 'بررسی میکروفون';

  @override
  String get voiceMicTestStart => 'بررسی کن';

  @override
  String get voiceMicTestStop => 'توقف';

  @override
  String get voiceMicTestLoopback => 'شنیدن صدای خود';

  @override
  String get voiceMicTestUnavailable =>
      'بررسی میکروفون الان در دسترس نیست (هنگام تماس، یا این نسخه تماس صوتی ندارد).';

  @override
  String get voiceInputMode => 'ارسال صدای من';

  @override
  String get voiceInputModeAlways => 'همیشه';

  @override
  String get voiceInputModeActivity => 'وقتی حرف می‌زنم';

  @override
  String get voiceInputModePushToTalk => 'فشار برای صحبت';

  @override
  String get voiceSensitivityAutomatic => 'تنظیم خودکار حساسیت';

  @override
  String get voiceSensitivity => 'حساسیت';

  @override
  String get voicePushToTalkKey => 'کلید فشار برای صحبت';

  @override
  String get voicePushToTalkKeyNone => 'فقط دکمهٔ تماس';

  @override
  String get voicePushToTalkKeyPress => 'یک کلید را فشار دهید…';

  @override
  String get voicePushToTalkKeyHint => 'وقتی Conest جلو است کار می‌کند';

  @override
  String get voiceClear => 'پاک کردن';

  @override
  String get voiceProcessing => 'پردازش';

  @override
  String get voiceNoiseSuppression => 'حذف نویز';

  @override
  String get voiceEchoCancellation => 'حذف پژواک';

  @override
  String get voiceAutoGain => 'تنظیم خودکار بلندی';

  @override
  String get voiceCallSounds => 'صداهای تماس';

  @override
  String get voiceCallSoundsHint => 'تماس ورودی همچنان زنگ می‌زند.';

  @override
  String get voiceDevicesOnPhone =>
      'در اندروید، گوشی میکروفون و بلندگوی تماس را انتخاب می‌کند.';

  @override
  String get voiceSettingsButton => 'تنظیمات صدا';

  @override
  String voiceParticipantVolume(String name) {
    return 'بلندی صدای $name';
  }

  @override
  String get voiceHoldToTalk => 'برای صحبت نگه دارید';

  @override
  String get quietHoursTitle => 'ساعات سکوت';

  @override
  String get quietHoursHint => 'اعلان‌ها بدون صدا و لرزش نمایش داده می‌شوند.';

  @override
  String quietHoursFrom(String time) {
    return 'از $time';
  }

  @override
  String quietHoursUntil(String time) {
    return 'تا $time';
  }

  @override
  String get quietHoursCallsRing => 'تماس‌ها همچنان زنگ می‌زنند';

  @override
  String get muteForHour => 'برای ۱ ساعت';

  @override
  String get muteForEightHours => 'برای ۸ ساعت';

  @override
  String get muteForDay => 'برای ۱ روز';

  @override
  String get muteUntilUnmuted => 'تا وقتی که خودم روشن کنم';

  @override
  String get notifyMentionsOnly => 'فقط هنگام اشاره به من اعلان بده';

  @override
  String get notifyAllMessages => 'برای همهٔ پیام‌ها اعلان بده';

  @override
  String get xmppEncOmemo2Unverified => 'رمزنگاری‌شده، تأییدنشده (OMEMO)';

  @override
  String get xmppTrustPending => 'دستگاه جدید، تأییدنشده';

  @override
  String get xmppUnconfirmedMsg => 'از دستگاه جدیدی که تأیید نکرده‌اید.';

  @override
  String get xmppEncOmemo2 => 'رمزگذاری‌شده (OMEMO)';

  @override
  String get xmppEncLegacy => 'OMEMO قدیمی (هنوز بررسی نشده)';

  @override
  String get xmppEncAuto => 'در صورت پشتیبانی مخاطب رمزگذاری می‌شود';

  @override
  String get xmppEncRequired => 'همیشه رمزگذاری‌شده';

  @override
  String get xmppEncryptionMenu => 'رمزگذاری و کلیدها';

  @override
  String get xmppEncryptionTitle => 'رمزگذاری';

  @override
  String get xmppEncryptionAuto => 'وقتی مخاطب پشتیبانی می‌کند';

  @override
  String get xmppEncryptionOn => 'همیشه (در غیر این صورت چیزی ارسال نشود)';

  @override
  String get xmppEncryptionOff => 'هرگز';

  @override
  String get xmppKeysTitle => 'کلیدهای رمزگذاری';

  @override
  String get xmppKeysYours => 'کلید شما';

  @override
  String get xmppKeysYoursHint =>
      'این اثرانگشت را حضوری یا در تماسی مطمئن با مخاطب مقایسه کنید، یا بگذارید کد را اسکن کند.';

  @override
  String xmppKeysTheirs(String name) {
    return 'دستگاه‌های $name';
  }

  @override
  String get xmppKeysNone => 'هیچ دستگاه OMEMO برای این مخاطب پیدا نشد.';

  @override
  String get xmppTrustBlind => 'تأیید نشده';

  @override
  String get xmppTrustVerified => 'تأیید شده';

  @override
  String get xmppTrustRefused => 'رد شده';

  @override
  String get xmppTrustVerify => 'علامت‌گذاری به‌عنوان تأییدشده';

  @override
  String get xmppTrustRefuse => 'رد این دستگاه';

  @override
  String get xmppTrustAllow => 'دوباره مجاز کن';

  @override
  String get xmppKeysScan => 'اسکن کد آن‌ها';

  @override
  String get xmppKeysRefresh => 'بررسی دستگاه‌ها';

  @override
  String get xmppKeysForget => 'فراموش‌کردن کلید این دستگاه';

  @override
  String get xmppKeysChanged =>
      'کلید آن تغییر کرده است: تا وقتی کلید قدیمی را فراموش نکنید چیزی به آن ارسال نمی‌شود.';

  @override
  String xmppKeysScanMatch(String count) {
    return '$count دستگاه تأیید شد.';
  }

  @override
  String get xmppKeysScanMismatch =>
      'کد با کلیدهای این مخاطب مطابقت ندارد. به آن‌ها اعتماد نکنید.';

  @override
  String get xmppUnreadable => 'رمزگشایی این پیام ممکن نبود.';

  @override
  String get xmppUntrustedMsg => 'از دستگاهی که رد کرده‌اید.';

  @override
  String get xmppLegacySwitch => 'OMEMO قدیمی (آزمایشی)';

  @override
  String get xmppLegacyHint =>
      'گفتگوی رمزگذاری‌شده با برنامه‌های قدیمی‌تر مانند Conversations، Dino و Gajim. هنوز بررسی نشده، پس این پیام‌ها رمزگذاری‌شده علامت نمی‌خورند.';

  @override
  String get routeXmppDescription =>
      'خادم‌های XMPP آن را می‌برند و همچنان با Conest سرتاسری رمزگذاری شده است؛ خادم‌ها هر دو حساب و زمان را می‌بینند.';

  @override
  String get xmppCarrierSubtitle =>
      'انتقال پیام‌ها از طریق یک حساب XMPP (Jabber)';

  @override
  String get xmppCreatedAccount => 'حسابی که Conest ساخته است';

  @override
  String get xmppOwnAccount => 'حساب خودتان';

  @override
  String get xmppChangeAccount => 'تغییر حساب';

  @override
  String get xmppServerField =>
      'خادم XMPP (خالی: نخستین خادمی که اینجا پاسخ می‌دهد)';

  @override
  String get xmppUseOwnAccount => 'استفاده از حساب XMPP خودم';

  @override
  String get xmppOwnAccountNote =>
      'Conest به‌عنوان یک دستگاه اضافه وارد می‌شود؛ برنامه‌های دیگر XMPP شما پیام‌های آن را نمی‌بینند.';

  @override
  String get xmppAddressField => 'نشانی XMPP (نام@خادم)';

  @override
  String get xmppPasswordField => 'گذرواژه';

  @override
  String get xmppRetracted => 'پیام پس گرفته شد';

  @override
  String get xmppFile => 'فایل';

  @override
  String get xmppNewChat => 'گفتگوی XMPP تازه';

  @override
  String get xmppNewChatAddress => 'نشانی یا پیوند xmpp:';

  @override
  String get xmppGroupChat => 'گفتگوی گروهی';

  @override
  String get xmppNickname => 'نام مستعار شما';

  @override
  String get xmppOpenChat => 'باز کردن';

  @override
  String get xmppMetadataTitle => 'برخی جزئیات در این فایل می‌ماند';

  @override
  String get xmppMetadataBody =>
      'Conest نتوانست همه جزئیات پنهان (مانند مکان یا دستگاه) را از این فایل پاک کند. با این حال بفرستید؟';

  @override
  String get xmppSendAnyway => 'به هر حال بفرست';

  @override
  String get xmppReply => 'پاسخ';

  @override
  String get xmppCopy => 'رونوشت';

  @override
  String get xmppEdit => 'ویرایش';

  @override
  String get xmppRetract => 'پس گرفتن';

  @override
  String get xmppChatGone => 'این گفتگو دیگر وجود ندارد.';

  @override
  String get xmppNotEncrypted => 'رمزگذاری نشده';

  @override
  String get xmppLeaveRoom => 'ترک گفتگوی گروهی';

  @override
  String get xmppDeleteChat => 'حذف گفتگو';

  @override
  String get xmppBlock => 'مسدود کردن';

  @override
  String get xmppAccept => 'پذیرفتن';

  @override
  String get xmppRequest =>
      'کسی که در مخاطبان شما نیست پیام داده است. پاسخ و نشانگر خوانده‌شدن فقط پس از پذیرش فرستاده می‌شود.';

  @override
  String get xmppRoomInvitation =>
      'به این گفتگوی گروهی دعوت شده‌اید. می‌پیوندید؟';

  @override
  String get xmppAttach => 'پیوست فایل';

  @override
  String get xmppMessageHint => 'پیام';

  @override
  String get xmppEdited => 'ویرایش‌شده';

  @override
  String get xmppChats => 'گفتگوهای XMPP';

  @override
  String get xmppChatsSubtitle =>
      'با هر کسی در XMPP (Jabber) گفتگو کنید، کنار گفتگوهای Conest';

  @override
  String get xmppChatsOtherAccount =>
      'استفاده از حسابی جز حسابی که Conest پیام‌ها را با آن می‌برد';

  @override
  String get xmppConnected => 'متصل';

  @override
  String get xmppConnecting => 'در حال اتصال';

  @override
  String appModeClientOnlyTitle(String network) {
    return 'از Conest به‌عنوان کارخواه $network استفاده شود؟';
  }

  @override
  String get onbXmppInstead => 'به‌جای آن به‌عنوان کارخواه XMPP استفاده کن';

  @override
  String get xmppSignIn => 'به حساب XMPP خود وارد شوید';

  @override
  String get xmppNoChats => 'هنوز گفتگوی XMPP نیست';

  @override
  String get xmppRequestShort => 'درخواست گفتگو';

  @override
  String get routeTelegramDescription =>
      'از طریق ربات‌های تلگرام منتقل می‌شود و همچنان با رمزنگاری سرتاسری Conest است؛ تلگرام هر دو ربات و زمان را می‌بیند.';

  @override
  String get telegramCarrierSubtitle =>
      'انتقال پیام‌ها از طریق رباتی در تلگرام که ساخته‌اید';

  @override
  String get telegramChangeBot => 'تغییر ربات';

  @override
  String get telegramBotHelp =>
      'با @BotFather یک ربات بسازید، پیام‌رسانی بین رباتی را برایش روشن کنید و توکن آن را اینجا بچسبانید. رباتی را به کار ببرید که فقط Conest می‌خواند. مخاطب شما هم همین کار را می‌کند.';

  @override
  String get telegramBotTokenField => 'توکن ربات';

  @override
  String get telegramClientTitle => 'کلاینت تلگرام';

  @override
  String get telegramClientSubtitle =>
      'استفاده از حساب تلگرام خود در Conest (کلاینت غیررسمی)';

  @override
  String get telegramUnofficial =>
      'Conest یک کلاینت غیررسمی تلگرام است. قوانین تلگرام برای حساب شما اعمال می‌شود.';

  @override
  String get telegramPhoneField => 'شماره تلفن (+…)';

  @override
  String get telegramCodeField => 'کد ورود';

  @override
  String get telegramPasswordField => 'گذرواژه تأیید دومرحله‌ای';

  @override
  String get telegramQrLogin => 'ورود با کد QR';

  @override
  String get telegramQrHint =>
      'در تلفن خود تلگرام را باز کنید، تنظیمات، دستگاه‌ها، اتصال دستگاه دسکتاپ و این کد را اسکن کنید.';

  @override
  String get telegramNoAccount =>
      'این شماره حساب تلگرام ندارد. Conest فقط وارد می‌شود؛ ابتدا حساب را در برنامه رسمی تلگرام بسازید.';

  @override
  String get telegramLogOut => 'خروج و حذف';

  @override
  String telegramSignedInAs(String name) {
    return 'وارد شده با نام $name';
  }

  @override
  String get telegramConnecting => 'در حال اتصال…';

  @override
  String get telegramMods => 'تنظیمات افزونه‌ها';

  @override
  String get telegramNoChats => 'هنوز گفتگوی تلگرامی نیست';

  @override
  String get telegramSaved => 'پیام‌های ذخیره‌شده';

  @override
  String get telegramSponsored => 'حمایت‌شده';

  @override
  String get telegramDeletedBySender => 'توسط فرستنده حذف شد';

  @override
  String get telegramAllChats => 'همه گفتگوها';

  @override
  String get telegramArchive => 'بایگانی';

  @override
  String get telegramChannelReadOnly =>
      'فقط مدیران می‌توانند اینجا پست بگذارند';

  @override
  String get telegramSendSilently => 'ارسال بی‌صدا';

  @override
  String get telegramSchedule => 'ارسال در زمان بعد…';

  @override
  String get telegramTranslate => 'ترجمه';

  @override
  String get telegramExport => 'صادر کردن پیام‌های بارگذاری‌شده';

  @override
  String get telegramDeleteForAll => 'حذف برای همه';

  @override
  String get telegramDeleteForMe => 'حذف برای من';

  @override
  String get telegramDownload => 'دانلود';

  @override
  String get telegramOpenSponsored => 'باز کردن پیوند';

  @override
  String get telegramHiddenWords =>
      'پنهان کردن پیام‌های دارای این واژه‌ها (هر خط یکی)';

  @override
  String get telegramDeletedNoticeSwitch =>
      'نمایش اعلان وقتی کسی پیامی را حذف می‌کند';

  @override
  String get telegramDeletedNoticeNote =>
      'فقط اعلان می‌ماند. محتوای حذف‌شده نگه داشته نمی‌شود.';

  @override
  String get telegramTranslateTo => 'ترجمه به (کد زبان، خالی برای زبان برنامه)';

  @override
  String get telegramPlugins => 'افزونه‌ها';

  @override
  String get telegramPluginHelp =>
      'افزونه‌ها فایل‌های قانون کوچکی هستند. فقط می‌توانند پیام‌ها را پنهان کنند، متن ارسالی را تغییر دهند و دستور اضافه کنند، آن هم فقط در حد مجوزهایشان.';

  @override
  String get telegramPluginInstall => 'نصب افزونه (متن آن را بچسبانید)';

  @override
  String get telegramPluginBad =>
      'این افزونه معتبر نیست یا تعداد افزونه‌ها زیاد است.';

  @override
  String telegramPluginPermissions(String permissions) {
    return 'مجاز: $permissions';
  }

  @override
  String get telegramPermReadMessages => 'پنهان کردن پیام‌ها';

  @override
  String get telegramPermEditOutgoing => 'تغییر آنچه می‌فرستید';

  @override
  String get telegramPermCommands => 'افزودن دستورها';

  @override
  String get telegramDownloads => 'دانلودها';

  @override
  String get telegramLoadOlder => 'بارگذاری پیام‌های قدیمی‌تر';

  @override
  String get onbTelegramInstead => 'استفاده به‌عنوان کلاینت تلگرام';

  @override
  String get routeDiscordDescription =>
      'از طریق ربات‌های دیسکورد منتقل می‌شود و همچنان با رمزنگاری سرتاسری Conest است؛ دیسکورد هر دو ربات و زمان را می‌بیند.';

  @override
  String get discordCarrierSubtitle =>
      'انتقال پیام‌ها از طریق رباتی در دیسکورد که ساخته‌اید';

  @override
  String get discordBotHelp =>
      'در پورتال توسعه‌دهندگان دیسکورد یک ربات بسازید، آن را به سروری خصوصی که با ربات مخاطبانتان مشترک است اضافه کنید و توکن و شناسه کانال را بچسبانید. رباتی را به کار ببرید که فقط Conest می‌خواند.';

  @override
  String get discordBotTokenField => 'توکن ربات';

  @override
  String get discordChannelField => 'شناسه کانال';

  @override
  String get discordChangeBot => 'تغییر ربات';

  @override
  String get discordClientTitle => 'کلاینت دیسکورد (برخلاف قوانین دیسکورد)';

  @override
  String get discordClientSubtitle =>
      'استفاده از حساب دیسکورد خود در Conest مانند Vencord و Vesktop';

  @override
  String get discordWarningTitle => 'ممکن است حساب شما مسدود شود';

  @override
  String get discordWarningBody =>
      'استفاده از توکن حساب در برنامه‌ای دیگر برخلاف قوانین دیسکورد است و ممکن است حساب مسدود شود. Conest فقط وقتی شما کاری می‌کنید عمل می‌کند: آنچه را باز می‌کنید می‌خواند و فقط آنچه می‌فرستید ارسال می‌کند. این توکن برای کار دیگری استفاده نمی‌شود و حامل Conest هرگز از آن استفاده نمی‌کند.';

  @override
  String get discordWarningAccept => 'متوجه هستم، ادامه';

  @override
  String get discordAccountTokenField => 'توکن حساب';

  @override
  String get discordTokenHelp =>
      'آن را در ابزار توسعه‌دهنده دیسکورد در مرورگر پیدا کنید (زبانه Network، سرآیند Authorization). هرگز به اشتراک نگذارید.';

  @override
  String discordSignedInAs(String name) {
    return 'وارد شده با نام $name';
  }

  @override
  String get discordDirectMessages => 'پیام‌های خصوصی';

  @override
  String get discordNoChats => 'هنوز گفتگوی دیسکوردی نیست';

  @override
  String get discordServers => 'سرورها';

  @override
  String get discordLoadOlder => 'بارگذاری پیام‌های قدیمی‌تر';

  @override
  String get discordOnbInstead => 'استفاده به‌عنوان کلاینت دیسکورد';

  @override
  String get telegramRelaySaved =>
      'انتقال پیام‌های ذخیره‌شده به دستگاه‌های دیگرم';

  @override
  String get telegramRelayChat => 'انتقال این گفتگو به دستگاه‌های دیگرم';

  @override
  String get telegramRelayNote =>
      'فقط متن پیام‌ها منتقل می‌شود، با رمزنگاری سرتاسری بین دستگاه‌هایتان. ورود تلگرام شما از این دستگاه خارج نمی‌شود.';

  @override
  String get telegramViaDevice => 'تلگرام، از طریق دستگاه دیگرتان';

  @override
  String get telegramBridgeReadOnly =>
      'اینجا فقط‌خواندنی است. در تلگرام روی دستگاهی که دارد پاسخ دهید.';
}

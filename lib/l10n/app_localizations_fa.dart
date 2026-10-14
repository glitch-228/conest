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
}

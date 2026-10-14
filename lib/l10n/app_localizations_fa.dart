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
}

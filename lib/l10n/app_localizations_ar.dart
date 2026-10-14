// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

  @override
  String get modeChooseTitle => 'كيف تريد أن يبدو Conest؟';

  @override
  String get modeChangeLater => 'يمكنك تغيير ذلك في أي وقت من الإعدادات.';

  @override
  String get modeSimple => 'بسيط';

  @override
  String get modeStandard => 'قياسي';

  @override
  String get modeAdvanced => 'متقدم';

  @override
  String get modeSimpleDescription =>
      'قائمة محادثات واحدة ونص كبير والإعدادات التي تحتاجها فقط. تُظهر الرسائل حالة الإرسال والتسليم والقراءة.';

  @override
  String get modeStandardDescription =>
      'مثل تطبيقات المراسلة التي تعرفها: محادثات ومجموعات ومكالمات وملفات، مع علامات التسليم والقراءة.';

  @override
  String get modeAdvancedDescription =>
      'كل شيء، بما في ذلك المسارات التي سلكتها كل رسالة وكل وسائل النقل وأدوات التشخيص.';

  @override
  String get actionContinue => 'متابعة';

  @override
  String get actionStart => 'ابدأ';

  @override
  String get actionBack => 'رجوع';

  @override
  String get actionClose => 'إغلاق';

  @override
  String get routesTitle => 'كيف يصل Conest إلى الآخرين';

  @override
  String get routesDirect =>
      'يرسل Conest الرسائل مباشرة إلى جهات اتصالك عبر شبكتك والإنترنت، دون أي خادم في المنتصف. هذا مفعّل الآن.';

  @override
  String get routesOthers =>
      'عندما تكون هذه الطرق محجوبة أو غير متاحة، يمكن لـ Conest أيضًا استخدام المرحّلات وTor وNostr والبريد الإلكتروني وMatrix وشبكة بلوتوث من الهواتف القريبة أو أجهزة راديو LoRa. كل منها متوقف حتى تشغّله من «الإعدادات ← الاتصال».';

  @override
  String get routesAdvanced =>
      'في الوضع المتقدم تُظهر كل رسالة المسارات التي سلكتها، ويمكن من ملف جهة الاتصال اختبار كل مسار.';

  @override
  String get tabChats => 'المحادثات';

  @override
  String get tabCalls => 'المكالمات';

  @override
  String get tabSettings => 'الإعدادات';

  @override
  String get callsEmpty => 'لا توجد مكالمات بعد. افتح محادثة واضغط زر الاتصال.';

  @override
  String get callOutgoing => 'صادرة';

  @override
  String get callIncoming => 'واردة';

  @override
  String get callMissed => 'فائتة';

  @override
  String get callDeclined => 'مرفوضة';

  @override
  String get callCancelled => 'ملغاة';

  @override
  String get callFailed => 'فشلت';

  @override
  String callDuration(int minutes, int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes د $seconds ث',
      zero: '$seconds ث',
    );
    return '$_temp0';
  }

  @override
  String get unknownContact => 'جهة اتصال غير معروفة';

  @override
  String get messageDetails => 'تفاصيل الرسالة';

  @override
  String messageSentAt(String time) {
    return 'أُرسلت $time';
  }

  @override
  String messageReceivedAt(String time) {
    return 'استُلمت $time';
  }

  @override
  String messageDeliveredAt(String time) {
    return 'سُلّمت $time';
  }

  @override
  String messageReadAt(String time) {
    return 'قُرئت $time';
  }

  @override
  String memberDeliveredAt(String time) {
    return 'سُلّمت $time';
  }

  @override
  String memberReadAt(String time) {
    return 'قُرئت $time';
  }

  @override
  String get messageRoutes => 'المسارات';

  @override
  String get messageArrivedBy => 'وصلت عبر';

  @override
  String get settingsShowAll => 'إظهار كل الإعدادات';

  @override
  String get settingsLanguage => 'اللغة';

  @override
  String get settingsLanguageSystem => 'مثل الجهاز';

  @override
  String get settingsAiTranslated =>
      'أُنجزت هذه الترجمة بالذكاء الاصطناعي وقد تحتوي على أخطاء. يمكنك المساعدة في تحسينها على Weblate.';
}

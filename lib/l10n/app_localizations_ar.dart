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

  @override
  String get menuReply => 'رد';

  @override
  String get menuReact => 'تفاعل 👍';

  @override
  String get menuForward => 'إعادة توجيه';

  @override
  String get menuCopyMessage => 'نسخ الرسالة';

  @override
  String get menuDownloadAttachment => 'تنزيل المرفق';

  @override
  String get menuSaveAttachment => 'حفظ المرفق';

  @override
  String get menuCopyImage => 'نسخ الصورة';

  @override
  String get menuFreeUpSpace => 'تحرير المساحة المحلية';

  @override
  String get menuCancelTransfer => 'إلغاء النقل';

  @override
  String get menuRetryTransfer => 'إعادة محاولة النقل';

  @override
  String get menuForwardAttachment => 'إعادة توجيه المرفق';

  @override
  String get menuCancelSending => 'إلغاء الإرسال';

  @override
  String get menuEditMessage => 'تعديل الرسالة';

  @override
  String get menuDeleteMessage => 'حذف الرسالة';

  @override
  String get menuEdit => 'تعديل';

  @override
  String get menuDelete => 'حذف';

  @override
  String get composerAttach => 'إرفاق ملف أو صورة';

  @override
  String get composerSchedule => 'جدولة الرسالة';

  @override
  String get composerSend => 'إرسال';

  @override
  String get searchChatsAndMessages => 'البحث في المحادثات والرسائل';

  @override
  String get searchChats => 'البحث في المحادثات';

  @override
  String get searchContacts => 'البحث في جهات الاتصال';

  @override
  String get archivedChats => 'المحادثات المؤرشفة';

  @override
  String get actionSearch => 'بحث';

  @override
  String get settingsPersonal => 'شخصي';

  @override
  String get settingsStorage => 'التخزين';

  @override
  String get settingsConnectivity => 'الاتصال';

  @override
  String get settingsRelays => 'المرحّلات';

  @override
  String get settingsUpdates => 'التحديثات';

  @override
  String get settingsAccount => 'الحساب';

  @override
  String get onbNameRequired => 'أدخل اسمًا للعرض ومنفذًا محليًا صالحًا.';

  @override
  String get onbRelayPortInvalid =>
      'إذا حددت عنوان مرحّل على الإنترنت، فيجب أن يكون منفذه صالحًا أيضًا.';

  @override
  String get onbRelayDesktop =>
      'تعمل أجهزة الكمبيوتر كمرحّلات افتراضيًا وتعلن مسارات الشبكة المحلية القريبة تلقائيًا.';

  @override
  String get onbRelayAndroid =>
      'يبدأ أندرويد ووضع الترحيل متوقف. شغّله من الإعدادات فقط إذا أردت أن يعمل هذا الجهاز كمرحّل.';

  @override
  String get onbRelayOther =>
      'يمكن تشغيل وضع الترحيل من الإعدادات إذا أردت أن يساعد هذا الجهاز في نقل الرسائل.';

  @override
  String get onbTagline =>
      'تواصل مع جهات اتصالك مباشرة عبر شبكتك أو الإنترنت، بتشفير تام بين الطرفين مع السرية الأمامية. وعندما تُحجب الطرق المعتادة، يلجأ Conest إلى المرحّلات وMatrix وNostr والبريد الإلكتروني وTor وأجهزة راديو LoRa أو شبكة بلوتوث من الهواتف القريبة.';

  @override
  String get onbFeatureForwardSecret => 'محادثات بسرية أمامية';

  @override
  String get onbFeatureDirect => 'مباشرة عبر الشبكة المحلية والإنترنت';

  @override
  String get onbFeatureFallbacks => 'بدائل عبر Tor والشبكة المتداخلة والراديو';

  @override
  String get onbFeatureMatrix => 'وأيضًا عميل Matrix';

  @override
  String get onbCreateTitle => 'أنشئ جهازك الأول';

  @override
  String get onbCreateHelp =>
      'لا تحتاج إلا إلى اسم للعرض. المنفذ المحلي للتسليم عبر الشبكة المحلية والاقتران بعبارة الرمز. المرحّل على الإنترنت اختياري: يمكن الوصول إلى جهات الاتصال عبر الإنترنت بدونه. شغّل مسارات أخرى لاحقًا من «الإعدادات ← الاتصال».';

  @override
  String get onbDisplayName => 'اسم العرض';

  @override
  String get onbLocalPort => 'منفذ المرحّل المحلي / الشبكة المحلية';

  @override
  String get onbRelayHost => 'عنوان المرحّل على الإنترنت (اختياري)';

  @override
  String get onbRelayPort => 'منفذ المرحّل على الإنترنت';

  @override
  String get onbCreateButton => 'إنشاء جهاز مشفّر';

  @override
  String get onbMatrixInstead => 'استخدامه كعميل Matrix بدلًا من ذلك';

  @override
  String get onbMatrixHelp =>
      'محادثات Matrix فقط، دون هوية Conest. يمكنك لاحقًا التبديل إلى «كلاهما» (Conest وMatrix جنبًا إلى جنب) من «الإعدادات ← الاتصال ← وضع التطبيق».';

  @override
  String get groupCreate => 'إنشاء مجموعة';

  @override
  String get groupTitle => 'اسم المجموعة';

  @override
  String get roleMember => 'عضو';

  @override
  String get roleModerator => 'مشرف';

  @override
  String get roleAdmin => 'مسؤول';

  @override
  String get actionCancel => 'إلغاء';

  @override
  String get actionCreate => 'إنشاء';

  @override
  String get actionCreating => 'جارٍ الإنشاء…';

  @override
  String get contactAdd => 'إضافة جهة اتصال';

  @override
  String get contactAlias => 'الاسم المستعار';

  @override
  String get contactInvitePayload => 'نص الدعوة أو رمز QR الممسوح';

  @override
  String get contactScanQr => 'مسح QR';

  @override
  String get contactCodephrase => 'عبارة الرمز فقط';

  @override
  String get contactTrustPayload => 'الوثوق برمز QR / الدعوة';

  @override
  String get contactFindCodephrase => 'البحث بعبارة الرمز';

  @override
  String get contactExchangeFailed => 'فشل التبادل التلقائي';

  @override
  String contactExchangeFailedBody(String alias) {
    return 'أضفت $alias، لكن تعذّر إرسال دعوتك إليه تلقائيًا. اطلب من الطرف الآخر مسح دعوتك أو إدخالها من جهته، أو ألغِ واحذف جهة الاتصال أحادية الجانب هذه الآن.';
  }

  @override
  String get actionAbort => 'إلغاء العملية';

  @override
  String get contactKeep => 'الإبقاء على جهة الاتصال';
}

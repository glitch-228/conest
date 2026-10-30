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

  @override
  String get uiPassphrase89950C => 'عبارة المرور';

  @override
  String get uiConfirmPassphraseEBAAC0 => 'تأكيد عبارة المرور';

  @override
  String get uiUnlock1526A1 => 'فتح القفل';

  @override
  String get uiUpdateAvailable67FD3A => 'تحديث متاح';

  @override
  String get uiLater56E2F5 => 'لاحقًا';

  @override
  String get uiHostAutoDetectsTCPUDP663D30 =>
      'يكتشف المضيف TCP/UDP تلقائيًا؛ يفرض udp://host:port استخدام UDP';

  @override
  String get uiVerificationRequestDA06F9 => 'طلب تحقق';

  @override
  String get uiIgnore98F55D => 'تجاهل';

  @override
  String get uiVerifyDDA6AC => 'تحقق';

  @override
  String uiCouldNotReadValueValue695755(String value, String value2) {
    return 'تعذّرت قراءة $value: $value2';
  }

  @override
  String uiCouldNotShareValueValue7BA3A3(String value, String value2) {
    return 'تعذّرت مشاركة $value: $value2';
  }

  @override
  String uiCouldNotSaveSidebarWidthB4DACB(String value) {
    return 'تعذّر حفظ عرض الشريط الجانبي: $value';
  }

  @override
  String get uiNoAudioOutputDevicesWere17E473 =>
      'لم يُعثر على أجهزة لإخراج الصوت.';

  @override
  String get uiCallAudioOutput0C276F => 'إخراج صوت المكالمة';

  @override
  String uiCallAudioRoutedToValueFFFBE8(String value) {
    return 'تم توجيه صوت المكالمة إلى $value.';
  }

  @override
  String uiCouldNotChangeCallAudio6CE7B1(String value) {
    return 'تعذّر تغيير إخراج صوت المكالمة: $value';
  }

  @override
  String uiCouldNotOpenInviteValue6C4D06(String value) {
    return 'تعذّر فتح الدعوة: $value';
  }

  @override
  String uiCouldNotSendAttachmentValueEFF771(String value) {
    return 'تعذّر إرسال المرفق: $value';
  }

  @override
  String uiCouldNotSendMessageValue042C4F(String value) {
    return 'تعذّر إرسال الرسالة: $value';
  }

  @override
  String get uiSendFromOriginalFFF29A => 'إرسال من الأصل';

  @override
  String uiCouldNotSendGroupMessageB6C7D1(String value) {
    return 'تعذّر إرسال رسالة المجموعة: $value';
  }

  @override
  String uiCouldNotSendLANLobby8E7487(String value) {
    return 'تعذّر إرسال رسالة الدردشة المحلية: $value';
  }

  @override
  String uiCouldNotStageValuePathless514094(String value) {
    return 'تعذّر تجهيز $value: لحماية الذاكرة، يقتصر حجم الملفات المسحوبة دون مسار على 8 MB.';
  }

  @override
  String get uiSelectAGroupBeforeDropping9DAB4C =>
      'اختر مجموعة قبل سحب الملفات.';

  @override
  String uiValueLocalFilePathUnavailable217177(String value) {
    return '$value: مسار الملف المحلي غير متاح.';
  }

  @override
  String uiValueSentWithoutIt7E0635(String value) {
    return '$value أُرسل بدونه.';
  }

  @override
  String get uiGroupFileScheduledB1DC66 => 'تمت جدولة ملف المجموعة.';

  @override
  String uiCouldNotScheduleValueValue25CED3(String value, String value2) {
    return 'تعذّرت جدولة $value: $value2';
  }

  @override
  String uiCouldNotOpenFilePicker8FF0C0(String value) {
    return 'تعذّر فتح منتقي الملفات: $value';
  }

  @override
  String uiValuePickerReturnedNoData4670CA(String value) {
    return '$value: لم يُرجع المنتقي أي بيانات.';
  }

  @override
  String uiOnlyTheFirstValueFiles45FC47(String value, String value2) {
    return 'سيتم تجهيز أول $value ملف فقط (تم استلام $value2).';
  }

  @override
  String uiValueSkippedValueMBExceeds487B2A(String value, String value2) {
    return 'تم تخطي $value: الحجم $value2 MB يتجاوز الحد $value MB.';
  }

  @override
  String get uiTransfers812412 => 'عمليات النقل';

  @override
  String uiValue75CED7(String value) {
    return '$value';
  }

  @override
  String get uiPreparingCallE86D6C => 'جارٍ تجهيز المكالمة…';

  @override
  String get uiCallingACD4A6 => 'جارٍ الاتصال…';

  @override
  String get uiIncomingVoiceCallF68FD3 => 'مكالمة صوتية واردة';

  @override
  String get uiConnectingFD3E79 => 'جارٍ الاتصال…';

  @override
  String get uiReconnecting8A8B95 => 'جارٍ إعادة الاتصال…';

  @override
  String get uiCallEnded9933A4 => 'انتهت المكالمة';

  @override
  String uiVoiceCallValue06FE1F(String value) {
    return 'مكالمة صوتية: $value';
  }

  @override
  String get uiMinimizeCall6CB0F0 => 'تصغير المكالمة';

  @override
  String get uiAcceptBB54DB => 'قبول';

  @override
  String get uiReject2B03B5 => 'رفض';

  @override
  String get uiNoiseSuppression71DE3C => 'تقليل الضوضاء';

  @override
  String get uiAudioOutput2B89CC => 'إخراج الصوت';

  @override
  String get uiDoneE9B450 => 'تم';

  @override
  String get uiHangUp66BE99 => 'إنهاء المكالمة';

  @override
  String get uiCloseDetails433DA6 => 'إغلاق التفاصيل';

  @override
  String get uiOpenFullProfile35063C => 'فتح الملف الشخصي الكامل';

  @override
  String get uiOpenGroupSettings0B568E => 'فتح إعدادات المجموعة';

  @override
  String get uiNewFolderA71199 => 'مجلد جديد';

  @override
  String get uiFolderNameB2CE02 => 'اسم المجلد';

  @override
  String get uiMoveEarlier07DD6F => 'نقل للأعلى';

  @override
  String get uiMoveLaterBB4C84 => 'نقل للأسفل';

  @override
  String get uiSaveEFC007 => 'حفظ';

  @override
  String get uiAddToFolderBFAD96 => 'إضافة إلى مجلد';

  @override
  String get uiNewMessage1ED2E7 => 'رسالة جديدة';

  @override
  String get uiBackToChats8DE6F6 => 'العودة إلى المحادثات';

  @override
  String get uiNavigationMenu6609F1 => 'قائمة التنقل';

  @override
  String get uiAllChats398E5B => 'كل المحادثات';

  @override
  String get uiSearchAllChatsC825C8 => 'البحث في كل المحادثات';

  @override
  String get uiClearSearch67300D => 'مسح البحث';

  @override
  String get uiContactRequests082691 => 'طلبات التواصل';

  @override
  String get uiReviewPeopleWhoWantTo24A8CB => 'مراجعة من يريد التواصل معك';

  @override
  String get uiNoChatsFoundC6BD82 => 'لم يُعثر على محادثات';

  @override
  String get uiNoArchivedChatsEAE7F0 => 'لا توجد محادثات مؤرشفة';

  @override
  String get uiNoMatrixChatsYet23B023 => 'لا توجد محادثات Matrix بعد';

  @override
  String get uiNewGroupF9850C => 'مجموعة جديدة';

  @override
  String get uiAddWithConestBeam19D1E2 => 'إضافة باستخدام Conest Beam';

  @override
  String get uiDirectMessagesE7596A => 'الرسائل الخاصة';

  @override
  String get uiConestBeamE98B77 => 'Conest Beam';

  @override
  String get uiMyInviteF80A7A => 'دعوتي';

  @override
  String get uiGroupDetailsDF844A => 'تفاصيل المجموعة';

  @override
  String get uiDebugBD604D => 'تصحيح الأخطاء';

  @override
  String get uiAdd61CC55 => 'إضافة';

  @override
  String get uiPollRoutesNow22318F => 'فحص المسارات الآن';

  @override
  String get uiContactProfile1B3A0E => 'ملف جهة الاتصال';

  @override
  String get uiHistoryForNewMembersF419F2 => 'سجل المحادثة للأعضاء الجدد';

  @override
  String get uiChooseHowToWindDownF7399D =>
      'اختر كيفية إنهاء هذه المجموعة. يحافظ نقل الملكية على المجموعة مع مالك جديد وتصبح أنت مشرفًا. يؤدي حذفها للجميع إلى إزالتها من قائمة كل عضو ولا يمكن التراجع عنه.';

  @override
  String get uiTransferOwnershipA563C9 => 'نقل الملكية…';

  @override
  String get uiDeleteForEveryoneE055A8 => 'حذف للجميع';

  @override
  String get uiNoOtherActiveMembersToF9DE12 =>
      'لا يوجد أعضاء نشطون آخرون لنقل الملكية إليهم.';

  @override
  String get uiTransferOwnershipA6819E => 'نقل الملكية';

  @override
  String get uiTransferCBB4CC => 'نقل';

  @override
  String uiOwnershipTransferredToValue14A10D(String value) {
    return 'تم نقل الملكية إلى $value.';
  }

  @override
  String get uiEveryMemberWillBeRemoved75A3FC =>
      'ستُزال المجموعة من قائمة كل عضو بعد إخراج الجميع منها. لن يُحذف سجل الرسائل المحلي تلقائيًا؛ يمكن لكل عضو مسحه عبر «إزالة من القائمة». لا يمكن التراجع عن هذا.';

  @override
  String get uiRemoveThisGroup38C4E8 => 'إزالة هذه المجموعة؟';

  @override
  String get uiRemoveThisGroupFromYourDA7898 =>
      'إزالة هذه المجموعة من قائمتك؟ سيُحذف سجل الرسائل المحلي. لن يُخطر الأعضاء الآخرون؛ فهم يرون أنك غادرت بالفعل.';

  @override
  String get uiRemoveE96390 => 'إزالة';

  @override
  String get uiChangeRole2B9BFD => 'تغيير الدور';

  @override
  String get uiRemoveMember1C31D1 => 'إزالة العضو';

  @override
  String get uiChooseWhatFutureMembersCanC38992 =>
      'اختر ما يمكن للأعضاء الجدد الاطلاع عليه لاحقًا';

  @override
  String get uiAddMember170AD0 => 'إضافة عضو';

  @override
  String get uiDeleteGroup043336 => 'حذف المجموعة…';

  @override
  String get uiLeave7E3520 => 'مغادرة';

  @override
  String get uiRemoveFromList23A976 => 'إزالة من القائمة';

  @override
  String get uiForwardMessage482959 => 'إعادة توجيه الرسالة';

  @override
  String get uiSavedMessagesC0FA7E => 'الرسائل المحفوظة';

  @override
  String get uiThisAttachmentIsNotAvailableFE641A =>
      'هذا المرفق غير متاح محليًا بعد.';

  @override
  String get uiDownloadThisFileBeforeForwarding60D7B5 =>
      'نزّل هذا الملف قبل إعادة توجيهه.';

  @override
  String get uiSearchMessagesABEA65 => 'البحث في الرسائل';

  @override
  String get uiStartVoiceCallExperimental6DE320 => 'بدء مكالمة صوتية (تجريبي)';

  @override
  String get uiChatOptionsA40D0F => 'خيارات المحادثة';

  @override
  String get uiPausePreview805180 => 'إيقاف المعاينة مؤقتًا';

  @override
  String get uiPlayPreview47BB44 => 'تشغيل المعاينة';

  @override
  String get uiUnmutePreview12A31A => 'تشغيل صوت المعاينة';

  @override
  String get uiMutePreviewCE44BD => 'كتم صوت المعاينة';

  @override
  String get uiPauseVoiceMessageECD12D => 'إيقاف الرسالة الصوتية مؤقتًا';

  @override
  String get uiPlayVoiceMessageB16684 => 'تشغيل الرسالة الصوتية';

  @override
  String get uiPlaybackSpeed6FF42B => 'سرعة التشغيل';

  @override
  String get uiStopRecordingEE0D9D => 'إيقاف التسجيل';

  @override
  String get uiDeleteRecording8B58CE => 'حذف التسجيل';

  @override
  String uiCouldNotLoadOlderGroup1A192E(String value) {
    return 'تعذّر تحميل سجل المجموعة الأقدم: $value';
  }

  @override
  String uiMessageScheduledForValueD2D788(String value) {
    return 'تمت جدولة الرسالة لـ $value.';
  }

  @override
  String get uiNewPoll6D62BD => 'استطلاع جديد';

  @override
  String get uiQuestion002FF5 => 'السؤال';

  @override
  String get uiOptionsOnePerLine62FF3D => 'الخيارات (واحد في كل سطر)';

  @override
  String get uiDeleteMessageD536CF => 'حذف الرسالة؟';

  @override
  String get uiDeleteSelectedMessages190A5F => 'حذف الرسائل المحددة؟';

  @override
  String uiDeleteFailedForOneMessage26C302(String value) {
    return 'تعذّر حذف رسالة واحدة: $value';
  }

  @override
  String get uiNothingToCopyFromTheEC27E3 =>
      'لا يوجد ما يمكن نسخه من الرسائل المحددة.';

  @override
  String uiCopiedValueMessageSC97E6E(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'تم نسخ $value رسالة.',
      many: 'تم نسخ $value رسالة.',
      few: 'تم نسخ $value رسالة.',
      two: 'تم نسخ $value رسالة.',
      one: 'تم نسخ $value رسالة.',
      zero: 'تم نسخ $value رسالة.',
    );
    return '$_temp0';
  }

  @override
  String get uiNoSelectedAttachmentIsReady536B54 =>
      'لم يجهز أي مرفق محدد بعد؛ ما زال النقل جاريًا.';

  @override
  String get uiCopiedMessageText9DC18F => 'تم نسخ نص الرسالة.';

  @override
  String get uiTheGroupFileIsNotF8A236 => 'ملف المجموعة غير متاح محليًا.';

  @override
  String uiSavedValue0463E5(String value) {
    return 'تم حفظ $value.';
  }

  @override
  String uiCouldNotSaveValueValue178005(String value, String value2) {
    return 'تعذّر حفظ $value: $value2';
  }

  @override
  String get uiTheAndroidFileSaverIsDF910B =>
      'أداة حفظ الملفات في Android غير متاحة.';

  @override
  String get uiOpeningFilesIsUnavailableOnC6ADA2 =>
      'فتح الملفات غير متاح على هذه المنصة.';

  @override
  String uiCouldNotOpenValueValue283326(String value, String value2) {
    return 'تعذّر فتح $value: $value2';
  }

  @override
  String get uiYou905CB3 => 'أنت';

  @override
  String get uiMessage68F414 => 'رسالة';

  @override
  String get uiMessageActions949184 => 'إجراءات الرسالة';

  @override
  String get uiTheAttachmentIsStillDownloadingF77317 =>
      'لا يزال تنزيل المرفق جاريًا.';

  @override
  String get uiShareOrScheduleAGroup2989F0 => 'مشاركة ملف للمجموعة أو جدولته';

  @override
  String get uiRecordingBelongsToAnotherConversation87E802 =>
      'التسجيل يخص محادثة أخرى';

  @override
  String get uiFinishTheVoicePreviewIn142571 =>
      'أكمل معاينة الصوت في محادثته الأصلية';

  @override
  String get uiReviewUnsentVoiceMessage24931C => 'مراجعة رسالة صوتية غير مرسلة';

  @override
  String get uiCancelMicrophoneStartup9E9F8A => 'إلغاء تشغيل الميكروفون';

  @override
  String get uiReleaseToDiscardRecording4C5C71 => 'ارفع إصبعك لحذف التسجيل';

  @override
  String get uiRecordingLockedTapToFinish40CD88 =>
      'التسجيل مُثبّت · انقر للإنهاء';

  @override
  String get uiReleaseToStopSlideLeft4686F1 =>
      'ارفع إصبعك للإيقاف · اسحب لليسار للإلغاء · وللأعلى للتثبيت';

  @override
  String get uiHoldToRecordAGroupC11B32 =>
      'اضغط مطولًا لتسجيل رسالة صوتية للمجموعة';

  @override
  String get uiCreatePoll8F5663 => 'إنشاء استطلاع';

  @override
  String get uiWriteToGroup5878DB => 'الكتابة للمجموعة';

  @override
  String get uiWriteAReply0A58E1 => 'كتابة رد';

  @override
  String get uiYouAreNoLongerIn571DA7 => 'لم تعد عضوًا في هذه المجموعة';

  @override
  String get uiVote64F872 => 'تصويت';

  @override
  String get uiChooseOptionsEA120E => 'اختيار الخيارات';

  @override
  String get uiRetractVoteA5DA11 => 'سحب التصويت';

  @override
  String get uiClosePollA6A189 => 'إغلاق الاستطلاع';

  @override
  String get uiScheduleOneAttachmentAtAC580C3 =>
      'جدول مرفقًا واحدًا في كل مرة.';

  @override
  String get uiNotDeliveredYetSendViaF056E1 =>
      'لم تُسلّم بعد. إرسال عبر Matrix…';

  @override
  String get uiVoiceCallsAreTurnedOff692843 =>
      'المكالمات الصوتية متوقفة. فعّلها في الإعدادات للاتصال.';

  @override
  String get uiVoiceCallAudioIsUnavailable0B6C43 =>
      'صوت المكالمات غير متاح في هذا الإصدار.';

  @override
  String get uiRouteInspector0E65DE => 'فاحص المسارات';

  @override
  String get uiThisContactRequestIsBlocked944F7D => 'طلب التواصل هذا محظور.';

  @override
  String get uiMessageSavedHereUntilTheA49A2C =>
      'حُفظت الرسالة هنا حتى تقبل جهة الاتصال.';

  @override
  String get uiWriteAnEncryptedMessage9F7705 => 'كتابة رسالة مشفّرة';

  @override
  String get uiWriteAReplyOrAddFC0A42 => 'كتابة رد أو إضافة وصف';

  @override
  String get uiHoldToRecordAVoice06B1B5 => 'اضغط مطولًا لتسجيل رسالة صوتية';

  @override
  String get uiWriteToNearbyLANUsers291142 =>
      'الكتابة لمستخدمي الشبكة المحلية القريبين';

  @override
  String get uiBroadcast77CA3F => 'بث';

  @override
  String get uiThisRemovesTheLocalContact0D6D1E =>
      'سيُحذف سجل الرسائل وجهة الاتصال محليًا. سيحاول التطبيق أيضًا إرسال إشعار بالإزالة ليختفي هذا الاتصال لدى الطرف الآخر.';

  @override
  String get uiDescriptionBio505243 => 'الوصف / نبذة';

  @override
  String get uiCheckPaths917FF3 => 'فحص المسارات';

  @override
  String get uiCopyState9BFD16 => 'نسخ الحالة';

  @override
  String get uiRemoveContact7F9A8A => 'إزالة جهة الاتصال';

  @override
  String get uiSaveProfile909BF3 => 'حفظ الملف الشخصي';

  @override
  String get uiShowAsBeam74375F => 'عرض باستخدام Beam';

  @override
  String get uiShowTheQRAnyway0B0CDF => 'عرض رمز QR رغم ذلك';

  @override
  String get uiOpenFullscreenQRC5418D => 'فتح QR بملء الشاشة';

  @override
  String get uiShowQRCFBAC6 => 'عرض QR';

  @override
  String get uiLegacyInviteC61C5D => 'دعوة قديمة';

  @override
  String get uiForContactsOnConestOr486754 =>
      'لجهات الاتصال التي تستخدم Conest 0.3.11 أو أقدم. لا يتضمن مساراتك للشبكات المحجوبة؛ تصل بعد الاتصال.';

  @override
  String get uiRotateCodephraseNow89B2D5 => 'تغيير عبارة الرمز الآن';

  @override
  String get uiEncryptForContactE07450 => 'تشفير لجهة اتصال';

  @override
  String get uiPublicOpticalTransfer58E3F4 => 'نقل بصري عام';

  @override
  String get uiAnyoneWhoCanSeeTheFAB2D0 =>
      'يمكن لأي شخص يرى الشاشة إعادة تكوين هذا الملف. هو موقّع للتحقق من سلامته، لكنه غير سري.';

  @override
  String get uiChoosePublicFile6E2739 => 'اختيار ملف عام';

  @override
  String get uiKeepThisScreenVisibleUntil2261B8 =>
      'أبقِ هذه الشاشة ظاهرة حتى يُبلغ المستقبِل عن اكتمال 100%.';

  @override
  String get uiReceiveConestBeamB05BCB => 'استقبال Conest Beam';

  @override
  String get uiDesktopCameraActiveDA0F15 => 'كاميرا سطح المكتب نشطة';

  @override
  String get uiPasteOneCbFrame66EA2B => 'لصق إطار cb1 واحد';

  @override
  String get uiAddFrame2BBA30 => 'إضافة إطار';

  @override
  String get uiContactAliasE07C25 => 'اسم مستعار لجهة الاتصال';

  @override
  String get uiWeComparedThisFingerprintIn952BEB => 'قارنّا هذه البصمة شخصيًا';

  @override
  String get uiTrustAndAddContact0962A2 => 'الوثوق بجهة الاتصال وإضافتها';

  @override
  String get uiSavedInPrivateConestStorage4C1334 =>
      'حُفظ في مساحة Conest الخاصة:';

  @override
  String get uiResetIdentity8B0224 => 'إعادة تعيين الهوية';

  @override
  String get uiThisClearsTheEncryptedVault864B3D =>
      'سيؤدي هذا إلى مسح الخزنة المشفّرة وإزالة جهات الاتصال والرسائل وإعادة التطبيق إلى حالة التشغيل الأول.';

  @override
  String get uiReset44C57A => 'إعادة تعيين';

  @override
  String get uiNoIdentityIsActive6B2EE3 => 'لا توجد هوية نشطة.';

  @override
  String get uiSaveNameE73831 => 'حفظ الاسم';

  @override
  String get uiSaveBioBE2711 => 'حفظ النبذة';

  @override
  String get uiMessageNotifications595635 => 'إشعارات الرسائل';

  @override
  String get uiShowASystemNotificationWhen90113B =>
      'عرض إشعار نظام عند وصول رسالة خاصة.';

  @override
  String get uiExperimentalVoiceCalls51098B => 'مكالمات صوتية تجريبية';

  @override
  String get uiExperimentalAndroidBackgroundReceive60828A =>
      'استقبال تجريبي في خلفية Android';

  @override
  String get uiDisabledInReleaseBuildsThe45B7DF =>
      'معطّل في إصدارات النشر: خدمة المقدمة لا تشغّل مستقبِل Flutter دون واجهة بعد.';

  @override
  String get uiAllowVoiceCallsInBackground73C5C5 =>
      'السماح بالمكالمات الصوتية في الخلفية';

  @override
  String get uiKeepsCallSignalingActiveAndC0A342 =>
      'يبقي إشارات المكالمات نشطة ويعرض إشعارًا أثناء تشغيل خدمة Conest. يتطلب المكالمات الصوتية التجريبية؛ قد توقف سياسة بطارية Android أو الإيقاف القسري إتاحتها.';

  @override
  String get uiDonTSendReadConfirmations230076 => 'عدم إرسال تأكيدات القراءة';

  @override
  String get uiDebugOnlyDeliveryAcknowledgementsStill7D6A9C =>
      'للتصحيح فقط. يستمر إرسال تأكيدات التسليم ومعالجة تأكيدات القراءة الواردة.';

  @override
  String get uiRemoveMetadataFromFilesA4860E =>
      'إزالة البيانات الوصفية من الملفات';

  @override
  String get uiBeforeSendingRemovesLocationCamera4E390D =>
      'يزيل الموقع والكاميرا والمؤلف والتاريخ من الصور والفيديو وملفات PDF والمستندات المكتبية قبل الإرسال. لا يُعاد ضغط الصور. تُرسل الملفات الأخرى كما هي.';

  @override
  String get uiSendFilesUnderRandomNames5F79D4 =>
      'إرسال الملفات بأسماء عشوائية';

  @override
  String get uiReplacesFileNamesWithRandom16F099 =>
      'يستبدل أسماء الملفات بأحرف عشوائية لك وللمستقبِل، مع إبقاء النوع مثل .jpg.';

  @override
  String get uiKeepOfStorageFreeF00434 => 'إبقاء 10% من التخزين فارغًا';

  @override
  String get uiReserveFreeSpaceForOther1AC9CF =>
      'حجز مساحة فارغة للتطبيقات الأخرى. عند إيقافه يمكن للنقل استخدام هذه المساحة، لكن يجب أن تتّسع الملفات على القرص.';

  @override
  String get uiLAN2ECD17 => 'LAN';

  @override
  String get uiSameNetworkListenerPairingBeacons5CF0A2 =>
      'مستمع الشبكة المحلية وإشارات الاقتران والتسليم المحلي.';

  @override
  String get uiOnlineC3E839 => 'عبر الإنترنت';

  @override
  String get uiIrohMessagingAndFileTransfersC4D635 =>
      'رسائل Iroh ونقل الملفات عبر الإنترنت. مرحّلات Conest المخصصة اختيارية.';

  @override
  String get uiIrohRelayFallbackE954F7 => 'استخدام مرحّلات Iroh عند التعذّر';

  @override
  String get uiUseIrohSBuiltIn631E03 =>
      'استخدام مرحّلات Iroh المدمجة للرسائل والملفات عند تعذّر الاتصال المباشر. يجب أن يكون الطرفان متصلين بالإنترنت.';

  @override
  String get uiLimitIrohFilesToMiBB58353 =>
      'حد ملفات Iroh عند 100 MiB (موصى به)';

  @override
  String get uiAppliesToDirectOnlineAnd28F6F1 =>
      'ينطبق على النقل المباشر عبر الإنترنت وعبر مرحّلات Iroh. أوقفه للملفات الأكبر التي قد تستغرق وقتًا طويلًا. يحتفظ النقل المحلي بحدّه الأكبر.';

  @override
  String get uiShareEmailAndMatrixAddressesD762EE =>
      'مشاركة عناوين البريد وMatrix مع أعضاء المجموعات';

  @override
  String get uiLetsMembersOfYourGroups9912A5 =>
      'يتيح لأعضاء مجموعاتك غير الموجودين بجهات اتصالك الوصول إليك عبر البريد أو Matrix. عند إيقافه يعرفون فقط عناوين Nostr وTor والراديو التي لا تُسمّيك. يتوقف النشر من الآن؛ قد يحتفظ من رأى عنوانًا به.';

  @override
  String get uiAutomaticDownloads5E777B => 'تنزيلات تلقائية';

  @override
  String get uiVerifiedContactsOnlyLimitsAdapt8A1876 =>
      'جهات الاتصال المتحقق منها فقط. تتكيّف الحدود مع Wi-Fi/Ethernet وشبكة الهاتف والتجوال.';

  @override
  String get uiCustomIrohRelayURLsDBF979 => 'روابط مرحّلات Iroh المخصصة';

  @override
  String get uiOneHTTPSURLPerLineDA8E70 =>
      'رابط HTTPS واحد في كل سطر؛ اتركه فارغًا لاستخدام مرحّلات N0 القياسية.';

  @override
  String get uiSaveIrohRelaysC144AD => 'حفظ مرحّلات Iroh';

  @override
  String get uiCheckAvailabilityFCC1A6 => 'فحص الإتاحة';

  @override
  String get uiRunThisDeviceAsA9DEA14 => 'تشغيل هذا الجهاز كمرحّل';

  @override
  String get uiAllowTrustedContactsToUse001771 =>
      'السماح لجهات الاتصال الموثوقة باستخدام هذا الجهاز كمرحّل.';

  @override
  String get uiAutoUseContactsAsRelaysC62C06 =>
      'استخدام جهات الاتصال كمرحّلات تلقائيًا';

  @override
  String get uiLocalRelayPort28A73C => 'منفذ المرحّل المحلي';

  @override
  String get uiSavePort1876F6 => 'حفظ المنفذ';

  @override
  String get uiRelayHostURLF11441 => 'مضيف المرحّل / رابطه';

  @override
  String get uiRelayPortEA05DA => 'منفذ المرحّل';

  @override
  String get uiDetectAddRelayE825AD => 'اكتشاف المرحّل وإضافته';

  @override
  String get uiErrorHistory25AFF8 => 'سجل الأخطاء';

  @override
  String get uiWhatWentWrongKeptAcross27FC1F =>
      'المشكلات المحفوظة عبر إعادة التشغيل في هذا الإصدار لنسخها في تقرير خطأ.';

  @override
  String get uiReceiveUnstableUpdatesBF7122 => 'تلقي تحديثات غير مستقرة';

  @override
  String get uiAlsoOfferNightlyBuildsNewerA7FAB0 =>
      'عرض الإصدارات الليلية أيضًا: ميزات أحدث واختبارات أقل. يُعرض الإصدار المستقر الأحدث دائمًا.';

  @override
  String get uiResetAppIdentity2E0F86 => 'إعادة تعيين هوية التطبيق';

  @override
  String get uiTrustNewKeyA181BE => 'الوثوق بالمفتاح الجديد';

  @override
  String get uiVerifyThePersonAndCompare738F28 =>
      'تحقّق من الشخص وقارن رقم الأمان عبر قناة أخرى قبل القبول.';

  @override
  String get uiReviewE29A79 => 'مراجعة';

  @override
  String get uiDiscardChat319267 => 'حذف المحادثة';

  @override
  String get uiConfirmIdentityReplacement0219C5 => 'تأكيد استبدال الهوية؟';

  @override
  String get uiItSThem394960 => 'هذا هو الشخص';

  @override
  String get uiRejectThisIdentityCB604F => 'رفض هذه الهوية؟';

  @override
  String get uiThisDeletesTheNewContactBB4444 =>
      'سيُحذف الاتصال الجديد والرسائل الواردة المحتجزة. استخدمه إذا اشتبهت بانتحال الهوية.';

  @override
  String get uiNotThem685593 => 'ليس هو';

  @override
  String get uiRemoveImportedList36FC81 => 'إزالة القائمة المستوردة؟';

  @override
  String get uiNoBundledConestRelaysOnline46529B =>
      'لا توجد مرحّلات Conest مضمّنة. تستخدم اتصالات الإنترنت Iroh؛ ويمكنك إعداد مرحّلك الخاص.';

  @override
  String get uiImportFromURL3F7B77 => 'استيراد من رابط…';

  @override
  String get uiImportRelayListFromURL86E363 => 'استيراد قائمة مرحّلات من رابط';

  @override
  String get uiJSONURL6918BA => 'رابط JSON';

  @override
  String get uiOperatorSPublicKeyOptionalA80E7A =>
      'المفتاح العام للمشغّل (اختياري، base64)';

  @override
  String get uiImportD6FBC9 => 'استيراد';

  @override
  String get uiCLEAN2F3D27 => 'بسيط';

  @override
  String get uiSUBTLEBB048B => 'خفيف';

  @override
  String get uiDEFAULTC18920 => 'افتراضي';

  @override
  String get uiFULLCC0A74 => 'كامل';

  @override
  String get uiLANFirstB360D1 => 'الشبكة المحلية أولًا';

  @override
  String get uiLANOnly94945D => 'الشبكة المحلية فقط';

  @override
  String get uiOnlineFirst346B6D => 'الإنترنت أولًا';

  @override
  String get uiOnlineOnlyF79CB9 => 'الإنترنت فقط';

  @override
  String get uiOfflineE01FA7 => 'دون اتصال';

  @override
  String get uiUsesLANWhenAvailableFallsA810EF =>
      'يستخدم الشبكة المحلية إن توفرت، وإلا فالإنترنت.';

  @override
  String get uiUsesLANOnlyNoRelay589D55 =>
      'يستخدم الشبكة المحلية فقط. لا تمر حركة هذا الاتصال عبر المرحّلات.';

  @override
  String get uiUsesOnlineWhenAvailableFallsCE2CAF =>
      'يستخدم الإنترنت إن توفر، وإلا فالشبكة المحلية.';

  @override
  String get uiUsesOnlineOnlyNoLAN193810 =>
      'يستخدم الإنترنت فقط. لا تمر حركة هذا الاتصال عبر الشبكة المحلية.';

  @override
  String get uiNoTransportSelectedThisContact7969EB =>
      'لم يُحدّد ناقل؛ لا يمكن الوصول إلى جهة الاتصال.';

  @override
  String get uiGlobalConnectivityIsOffAdjustA7C644 =>
      'الاتصال العام متوقف؛ عدّل الإعدادات للإرسال.';

  @override
  String get uiSameNetworkDelivery94E793 => 'التسليم عبر الشبكة نفسها';

  @override
  String get uiDisabledByGlobalSetting2CB06C => 'معطّل بإعداد عام';

  @override
  String get uiAllowIrohRelayFallback35227B =>
      'السماح باستخدام مرحّلات Iroh عند التعذّر';

  @override
  String get uiVisibleAndOnlineOnlyDirectEA8902 =>
      'ظاهر وعبر الإنترنت فقط؛ تُفضّل اتصالات Iroh المباشرة.';

  @override
  String get uiRelayInternetDeliveryD64AB6 => 'التسليم عبر المرحّل / الإنترنت';

  @override
  String get uiPrefer13F662 => 'تفضيل';

  @override
  String get uiCarryTheirMessages22FD33 => 'نقل رسائله';

  @override
  String get uiWhenThisContactCannotReach5C3FF8 =>
      'عندما يعجز هذا الاتصال عن الوصول لشخص يستطيع جهازك الوصول إليه، انقل رسائله. ترى فقط لمن هي ومتى؛ ويبقى محتواها مشفّرًا.';

  @override
  String uiSaveValueFileSToB46C57(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'حفظ $value ملف في…',
      many: 'حفظ $value ملف في…',
      few: 'حفظ $value ملف في…',
      two: 'حفظ $value ملف في…',
      one: 'حفظ $value ملف في…',
      zero: 'حفظ $value ملف في…',
    );
    return '$_temp0';
  }

  @override
  String get uiSaveCanceled1939D0 => 'أُلغي الحفظ.';

  @override
  String get uiAlbumActions7B6D70 => 'إجراءات الألبوم';

  @override
  String get uiCancelSelectionF7F56C => 'إلغاء التحديد';

  @override
  String get uiCopyAF74F7 => 'نسخ';

  @override
  String get uiSaveAttachments5A74EA => 'حفظ المرفقات';

  @override
  String get uiCancelAndClearAllTransfers01B81D =>
      'إلغاء كل عمليات النقل ومسحها؟';

  @override
  String get uiKeepTransfersDB8CC7 => 'إبقاء عمليات النقل';

  @override
  String get uiCancelAndClearCCF59C => 'إلغاء ومسح';

  @override
  String get uiPauseAll6F6099 => 'إيقاف الكل مؤقتًا';

  @override
  String get uiResumeAll039916 => 'استئناف الكل';

  @override
  String get uiCancelAndClearAllTransfersACEBB3 =>
      'إلغاء كل عمليات النقل ومسحها';

  @override
  String get uiClearCompletedE63FC1 => 'مسح المكتمل';

  @override
  String get uiMoveToTop44AFA6 => 'نقل إلى الأعلى';

  @override
  String get uiPreparingDownloadF9B13B => 'جارٍ تجهيز التنزيل';

  @override
  String get uiDownloadA479C9 => 'تنزيل';

  @override
  String get uiResumeB3BD0B => 'استئناف';

  @override
  String get uiPause781961 => 'إيقاف مؤقت';

  @override
  String get uiRetry9F5CD8 => 'إعادة المحاولة';

  @override
  String get uiContinueOverIrohRelay949702 => 'متابعة عبر مرحّل Iroh';

  @override
  String get uiDownloadAnyway42859F => 'تنزيل رغم ذلك';

  @override
  String get uiPreparing96A9B7 => 'جارٍ التجهيز';

  @override
  String get uiQueued6A5998 => 'في قائمة الانتظار';

  @override
  String get uiWaiting33D306 => 'جارٍ الانتظار';

  @override
  String get uiTransferring73F753 => 'جارٍ النقل';

  @override
  String get uiReconnecting9D80F9 => 'جارٍ إعادة الاتصال';

  @override
  String get uiPausedC7DFB6 => 'متوقف مؤقتًا';

  @override
  String get uiVerifying536244 => 'جارٍ التحقق';

  @override
  String get uiComplete1F5A1A => 'مكتمل';

  @override
  String get uiCanceledF840AC => 'ملغى';

  @override
  String get uiUnavailable2C9C1F => 'غير متاح';

  @override
  String uiSavedValueToValue08F152(String value, String value2) {
    return 'تم حفظ $value في $value2.';
  }

  @override
  String uiGallerySaveFailedValueFalling0B82BB(String value) {
    return 'فشل الحفظ في المعرض ($value)؛ سيتم فتح مربع حفظ الملفات.';
  }

  @override
  String uiSaveValue5769AA(String value) {
    return 'حفظ $value';
  }

  @override
  String uiSaveFailedValue534182(String value) {
    return 'فشل الحفظ: $value';
  }

  @override
  String get uiTheAttachmentFileIsNotA67009 => 'ملف المرفق غير متاح محليًا.';

  @override
  String uiCopiedValueToClipboard669D0B(String value) {
    return 'تم نسخ $value إلى الحافظة.';
  }

  @override
  String uiCopiedValueTextOnlySystemB51B8D(String value) {
    return 'تم نسخ «$value» كنص فقط؛ حافظة النظام لا تدعم البيانات الثنائية هنا.';
  }

  @override
  String uiCopyFailedValueFilenameCopiedF71C87(String value) {
    return 'فشل النسخ: $value. نُسخ اسم الملف كنص بدلًا منه.';
  }

  @override
  String get uiCachePathIsNotReady0404B5 =>
      'مسار التخزين المؤقت غير جاهز؛ ما زال النقل جاريًا.';

  @override
  String uiCachePathCopiedValue4CC1C4(String value) {
    return 'تم نسخ مسار التخزين المؤقت: $value';
  }

  @override
  String get uiVideoIsnTCachedLocally8920DD =>
      'الفيديو غير مخزّن محليًا بعد؛ انتظر انتهاء النقل.';

  @override
  String uiCouldNotOpenVideoIn054087(String value) {
    return 'تعذّر فتح الفيديو في مشغّل النظام: $value';
  }

  @override
  String get uiImageIsNotAvailableLocally12017F => 'الصورة غير متاحة محليًا.';

  @override
  String uiVideoStillTransferringValue3F4049(String value) {
    return 'ما زال نقل الفيديو جاريًا ($value%).';
  }

  @override
  String get uiVoiceMessageBytesAreNotF8339B =>
      'بيانات الرسالة الصوتية غير جاهزة.';

  @override
  String get uiSendMode265A2D => 'وضع الإرسال';

  @override
  String get uiLANRelayA05D48 => 'مرحّل الشبكة المحلية';

  @override
  String get uiLobbyFDB6D9 => 'الردهة';

  @override
  String get uiDirectBC8152 => 'مباشر';

  @override
  String get uiIroh84642D => 'Iroh';

  @override
  String get uiIrohRelayB128EA => 'مرحّل Iroh';

  @override
  String get uiRelay9F537F => 'مرحّل';

  @override
  String get uiMatrix58947E => 'Matrix';

  @override
  String get uiPlainMatrixBA9DE1 => 'Matrix عادي';

  @override
  String get uiNostr4D3AD8 => 'Nostr';

  @override
  String get uiEmail84ADD5 => 'البريد الإلكتروني';

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
  String get uiViaContactCF1F8E => 'عبر جهة اتصال';

  @override
  String get uiSendViaMatrix062A08 => 'إرسال عبر Matrix؟';

  @override
  String get uiKeepWaiting9BE1AB => 'متابعة الانتظار';

  @override
  String get uiSendViaMatrix638038 => 'إرسال عبر Matrix';

  @override
  String uiNotSentViaMatrixValue99F62C(String value) {
    return 'لم يُرسل عبر Matrix: $value';
  }

  @override
  String get uiMessageRoutesFBF32C => 'مسارات الرسائل';

  @override
  String get uiWhatTheColouredMarksOnA10C8E =>
      'معنى العلامات الملونة على الرسائل';

  @override
  String get uiOpenInDefaultPlayerE64C20 => 'فتح في المشغّل الافتراضي';

  @override
  String get uiCancelReplyBD62D2 => 'إلغاء الرد';

  @override
  String get uiScheduledMessages98CEF4 => 'رسائل مجدولة';

  @override
  String get uiEditScheduledMessage62AF88 => 'تعديل رسالة مجدولة';

  @override
  String get uiCaption3428D9 => 'الوصف';

  @override
  String get uiNoChatsToShareIntoB50F2F => 'لا توجد محادثات للمشاركة فيها بعد.';

  @override
  String get uiLetDevicesOnThisNetwork42E2F0 =>
      'السماح لأجهزة هذه الشبكة بالوصول لهذا الحاسوب';

  @override
  String get uiAllow3AD0E3 => 'سماح';

  @override
  String get uiKeepSignedIn611A13 => 'إبقاء تسجيل الدخول';

  @override
  String get uiSignOutHereA6F129 => 'تسجيل الخروج هنا';

  @override
  String get uiMatrixPassword34E218 => 'كلمة مرور Matrix';

  @override
  String get uiPassword8BE3C9 => 'كلمة المرور';

  @override
  String get uiYourServerAsksForIt1594FA =>
      'يطلبها الخادم لإنشاء مفاتيح التوقيع.';

  @override
  String get uiRecoveryIsAlreadySetUp371F7F => 'الاسترداد معدّ بالفعل';

  @override
  String get uiOK9CE3BD => 'حسنًا';

  @override
  String get uiSaveYourRecoveryKey7851B3 => 'احفظ مفتاح الاسترداد';

  @override
  String get uiKeepThisKeySomewhereSafe0C0DFE =>
      'احتفظ بالمفتاح في مكان آمن. تحتاجه لقراءة سجل Matrix المشفّر على جهاز جديد. يُعرض مرة واحدة فقط.';

  @override
  String get uiISavedIt3E2255 => 'حفظته';

  @override
  String get uiEnterRecoveryKey4521B6 => 'إدخال مفتاح الاسترداد';

  @override
  String get uiEsTFromAnotherMatrixAppFCA0C9 =>
      'EsT… (من تطبيق Matrix آخر أو من هذا التطبيق)';

  @override
  String get uiSignOutDC1649 => 'تسجيل الخروج';

  @override
  String get uiSetUpRecoveryFD3804 => 'إعداد الاسترداد';

  @override
  String get uiVerifyWithAnotherSession9ED031 => 'التحقق بجلسة أخرى';

  @override
  String get uiShowJoinsLeavesAndProfile9FA764 =>
      'عرض الانضمام والمغادرة وتغييرات الملفات الشخصية';

  @override
  String get uiInMatrixRoomsCollapsedIntoD20CAB =>
      'في غرف Matrix، تُطوى في سطر واحد';

  @override
  String get uiMatrixUser70A560 => 'مستخدم Matrix';

  @override
  String get uiForExampleNameMatrixOrg63C60A => 'مثل @name:matrix.org';

  @override
  String get uiHomeserverOptional70DF85 => 'الخادم المنزلي (اختياري)';

  @override
  String get uiFoundFromTheUserId69A3AB =>
      'يُستخرج من معرّف المستخدم عند تركه فارغًا';

  @override
  String get uiSignInToMatrix652C8F => 'تسجيل الدخول إلى Matrix';

  @override
  String get uiSignInWithBrowserC995DF => 'تسجيل الدخول بالمتصفح';

  @override
  String get uiFinishSigningInInYour9F41A4 => 'أكمل تسجيل الدخول في المتصفح.';

  @override
  String get uiCopyLink2F84EE => 'نسخ الرابط';

  @override
  String get uiThisDeviceFA5A6D => 'هذا الجهاز';

  @override
  String uiOutOfTouchSinceValueA037FD(String value) {
    return 'غير متصل منذ $value: لن تتم مزامنة شيء معه حتى تؤكد أنه ما زال لك.';
  }

  @override
  String uiLinkedValueDCADF7(String value) {
    return 'تم الربط $value';
  }

  @override
  String get uiYourContactsWillStopAccepting5B0F03 =>
      'ستتوقف جهات اتصالك عن قبول أي شيء من هذا الجهاز. لا يمكن إعادته؛ اربطه مجددًا كجهاز جديد.';

  @override
  String get uiStillMine38C8AE => 'ما زال لي';

  @override
  String get uiRemoveDeviceA9C39D => 'إزالة الجهاز';

  @override
  String get uiLinkADeviceE71635 => 'ربط جهاز';

  @override
  String get uiLinkThisDeviceToMy888A1A => 'ربط هذا الجهاز بحسابي';

  @override
  String get uiCheckThatBothDevicesShow031E51 =>
      'تأكد من ظهور هذا الرمز على الجهازين:';

  @override
  String get uiTheCodesMatch32C407 => 'الرمزان متطابقان';

  @override
  String get uiLinkedTheNewDeviceNow9900E5 =>
      'تم الربط. أصبح للحهاز الجديد حسابك وجهات اتصالك؛ وستراه جهات اتصالك بصفتك أنت.';

  @override
  String get uiConfirmTheCodeOnThe17BB1F =>
      'أكّد الرمز على الجهاز الجديد أيضًا.';

  @override
  String get uiWaitingForTheNewDevice75283F =>
      'في انتظار رد الجهاز الجديد. إن لم يظهر رمز، تأكد أن الجهاز الجديد لا يزال يعرض رمزه وأن الجهازين على الشبكة نفسها أو متصلان بالإنترنت.';

  @override
  String get uiOnTheNewDeviceOpen29AF5E =>
      'على الجهاز الجديد افتح الإعدادات ← الأجهزة ← ربط هذا الجهاز بحسابي، ثم امسح الرمز الظاهر.';

  @override
  String get uiScanCode4596C2 => 'مسح الرمز';

  @override
  String get uiOrPasteTheCodeE72792 => 'أو الصق الرمز';

  @override
  String get uiLinkThisDeviceBF5E5C => 'ربط هذا الجهاز';

  @override
  String get uiThisDeviceIsNowLinked7EA826 => 'هذا الجهاز مرتبط بحسابك الآن.';

  @override
  String get uiWaitingForTheOtherDeviceB39C3F => 'في انتظار الجهاز الآخر…';

  @override
  String get uiOnTheDeviceYouAlready92C421 =>
      'على جهازك الحالي افتح الإعدادات ← الأجهزة ← ربط جهاز وامسح هذا الرمز. يجب أن يكون الجهازان على الشبكة نفسها أو متصلين بالإنترنت.';

  @override
  String get uiDeltaChat8BDA67 => 'Delta Chat';

  @override
  String get uiBitchatA99B50 => 'bitchat';

  @override
  String get uiWithAFilterOfTheir4FD18E =>
      'بمرشّح خاص لكل شبكة. عند إيقافه تُفتح محادثاتها من إعدادات الشبكة فقط.';

  @override
  String get uiYourDeltaChatInviteEE073F => 'دعوتك في Delta Chat';

  @override
  String get uiShowTheQRCodeTo0769AD =>
      'اعرض رمز QR لمستخدم Delta Chat أو أرسل الرابط. يمكن لأي شخص يملكه بدء محادثة متحقق منها معك.';

  @override
  String get uiShowQRCode2DF2DD => 'عرض رمز QR';

  @override
  String get uiDeltaChatChats8EBCBC => 'محادثات Delta Chat';

  @override
  String get uiGroup171A06 => 'مجموعة';

  @override
  String get uiJoinWithAnInviteC76024 => 'الانضمام بدعوة';

  @override
  String get uiJoinE0D731 => 'انضمام';

  @override
  String get uiNewDeltaChatGroup7D5142 => 'مجموعة Delta Chat جديدة';

  @override
  String get uiGroupNameEBB7E1 => 'اسم المجموعة';

  @override
  String get uiMembers1CB449 => 'الأعضاء';

  @override
  String get uiGroupInviteD64669 => 'دعوة المجموعة';

  @override
  String get uiYouAreNotInThisCF5BD5 => 'لست عضوًا في هذه المجموعة';

  @override
  String get uiStartGroupCallC2A083 => 'بدء مكالمة جماعية';

  @override
  String get uiJoinGroupCallC9ECF8 => 'الانضمام للمكالمة الجماعية';

  @override
  String get uiPushToTalk032E78 => 'اضغط للتحدث';

  @override
  String get uiCarryMessagesOverAReticulum1CE915 =>
      'نقل الرسائل عبر شبكة Reticulum، مثل أجهزة LoRa ‏(RNode) دون إنترنت، باستخدام عقدة تشغّل rnsd بواجهة خادم TCP. يحتفظ Conest بهوية Reticulum مستقلة؛ تتعرف عليها جهات اتصالك تلقائيًا.';

  @override
  String get uiNodeAddressRnsdCD61E2 => 'عنوان العقدة (rnsd)';

  @override
  String get uiUSBDeviceB47FF0 => 'جهاز USB';

  @override
  String get uiRNodeAddress691283 => 'عنوان RNode';

  @override
  String get uiBluetoothAddress0E2BED => 'عنوان Bluetooth';

  @override
  String get uiTCPPortDE05BE => 'منفذ TCP';

  @override
  String get uiEU233558 => 'الاتحاد الأوروبي 869.525';

  @override
  String get uiUS5ED166 => 'الولايات المتحدة 914.875';

  @override
  String get uiUseConestAsAMatrix6A44C5 => 'استخدام Conest كعميل Matrix فقط؟';

  @override
  String get uiYourConestChatsAreHiddenCFD853 =>
      'تُخفى محادثات Conest ويتوقف الاتصال على هذا الجهاز حتى تعود. لا يُحذف شيء. لن تتمكن جهات الاتصال من الوصول إليك عبر Conest مؤقتًا؛ تستمر تطبيقاتها بالمحاولة وتُسلّم الرسائل عند عودتك.';

  @override
  String get uiSwitch3E44C9 => 'تبديل';

  @override
  String get uiSealAnimatedRings29BE2D => 'ختم (حلقات متحركة)';

  @override
  String get uiSigilRuneA0B8A7 => 'رمز (نقش)';

  @override
  String get uiBlockiePixelHashA265BA => 'صورة بكسلية (تجزئة)';

  @override
  String get uiMonogramInitials8C6019 => 'حروف أولى';

  @override
  String get uiNewMatrixChatC065C8 => 'محادثة Matrix جديدة';

  @override
  String get uiNameMatrixOrgD0BB06 => '@name:matrix.org';

  @override
  String get uiStartChat18BB58 => 'بدء محادثة';

  @override
  String get uiCopyText06A76C => 'نسخ النص';

  @override
  String uiVerifyValue1B6B79(String value) {
    return 'التحقق من $value';
  }

  @override
  String get uiAttachAFileAE85E4 => 'إرفاق ملف';

  @override
  String get uiMessageDeleted3271A7 => 'حُذفت الرسالة';

  @override
  String get uiUnableToDecryptFDF88B => 'تعذّر فك التشفير';

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
  String get uiDeclineB59CF9 => 'رفض';

  @override
  String get uiCarryMessagesAsEncryptedEmail0D19EA =>
      'نقل الرسائل كبريد مشفّر عند تعذّر المسارات الأخرى، مثل Delta Chat. ترى خوادم البريد عنواني الطرفين والوقت، لا المحتوى. تتعرف جهات اتصالك على العنوان تلقائيًا.';

  @override
  String get uiUseMyOwnEmailAccountE78C1D =>
      'استخدام حساب بريدي الخاص بدلًا من ذلك';

  @override
  String get uiNostrRelaysBD8BAD => 'مرحّلات Nostr';

  @override
  String get uiCarryMessagesThroughPublicNostr729B94 =>
      'نقل الرسائل عبر مرحّلات Nostr العامة عند تعذّر المسارات الأخرى. تعرف المرحّلات أن أحدًا يكتب إليك ومتى، لا من هو أو ماذا يكتب. يستخدم مفتاحًا مستقلًا؛ تتعرف عليه جهات اتصالك تلقائيًا.';

  @override
  String get uiRelaysYouReadFromOne020C0A =>
      'مرحّلات تقرأ منها (واحد في كل سطر، حتى 4)';

  @override
  String get uiSaveRelays91CBA8 => 'حفظ المرحّلات';

  @override
  String get uiDefaultRelays5C909F => 'المرحّلات الافتراضية';

  @override
  String get uiNewChat009BF6 => 'محادثة جديدة';

  @override
  String get uiNodeAddress896F20 => 'عنوان العقدة';

  @override
  String get uiDeleteChatDB9121 => 'حذف المحادثة';

  @override
  String get uiTurnOnAppMessagesTo7DCA13 => 'فعّل رسائل التطبيق للكتابة';

  @override
  String get uiBitchatNearbyD0C416 => 'bitchat قريب';

  @override
  String get uiMeshChat7BF668 => 'محادثة الشبكة';

  @override
  String get uiHiddenTurnOnReachableBy0103C9 =>
      'مخفي: فعّل «إمكانية التواصل عبر bitchat»';

  @override
  String get uiTheyDonTMatch27EF0C => 'غير متطابقة';

  @override
  String get uiTheyMatch6FB8EB => 'متطابقة';

  @override
  String get uiNameBitchatUsersSee1CE7E3 => 'الاسم الذي يراه مستخدمو bitchat';

  @override
  String get uiANameYouChooseStays17E677 =>
      'يبقى الاسم الذي تختاره عند تغيّر هويتك، فيستطيع من حولك معرفة أنك الشخص نفسه. اتركه فارغًا للحصول على اسم \"anon\" جديد مع كل هوية.';

  @override
  String get uiBluetoothMeshC8B7F1 => 'شبكة Bluetooth';

  @override
  String get uiReachContactsNearbyWithoutAny9E9649 =>
      'تواصل مع جهات الاتصال القريبة دون شبكة: تنتقل الرسائل عبر Bluetooth من جهاز لآخر، عبر مستخدمي Conest وbitchat، وينقل هذا الجهاز رسائل الآخرين. لا يظهر هذا الجهاز في bitchat، وتبدو رسائله كأي رسالة خاصة في bitchat، بمعرّفات تتغيّر كل ساعة.';

  @override
  String get uiReachableByBitchatUsers568021 => 'إمكانية التواصل عبر bitchat';

  @override
  String get uiShareInternetWithBitchatUsers572F90 =>
      'مشاركة الإنترنت مع مستخدمي bitchat';

  @override
  String get uiChangeNameE46692 => 'تغيير الاسم';

  @override
  String get uiNewIdentityA119CF => 'هوية جديدة';

  @override
  String get uiBitchatChatsC74EC3 => 'محادثات bitchat';

  @override
  String get uiTheMatrixClientIsNot01A5B4 =>
      'عميل Matrix غير متاح على هذا الجهاز، لذا لا يمكن تشغيل Conest بوضع Matrix فقط هنا.';

  @override
  String get uiUseConest12EEF3 => 'استخدام Conest';

  @override
  String get uiSearchRoomsCCE4F9 => 'البحث في الغرف';

  @override
  String get uiReachContactsThroughTorOnion8B8A98 =>
      'الوصول لجهات الاتصال عبر خدمات Tor المخفية: لا يعرف أي طرف ولا الشبكة موقع الآخر. أبطأ من المسارات الأخرى؛ أضف جسورًا حيث يُحجب Tor.';

  @override
  String get uiBridgesOptionalOnePerLine110291 =>
      'جسور (اختيارية، واحد في كل سطر)';

  @override
  String get uiEEFEBFE80B7A =>
      '192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413';

  @override
  String get uiObfsEEFEAD0EDF =>
      'obfs4 192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413 cert=… iat-mode=0';

  @override
  String get uiLinesFromBridgesTorprojectOrgF08389 =>
      'أسطر من bridges.torproject.org تبدأ بالنوع: obfs4 أو webtunnel أو snowflake أو meek_lite (أو جسور عادية: عنوان وبصمة).';

  @override
  String get uiPlainBridgesOnlyAddressAnd7F0B60 =>
      'هذا الإصدار يدعم الجسور العادية فقط (العنوان والبصمة).';

  @override
  String get uiUseTheseBridgesC1FA11 => 'استخدام هذه الجسور';

  @override
  String get uiNostrPrivateMessagesDF74A3 => 'رسائل Nostr الخاصة';

  @override
  String get uiChatWithAnyoneOnNostrA867BC =>
      'تحدّث مع أي مستخدم Nostr ‏(0xchat وAmethyst وDamus وغيرها من تطبيقات NIP-17)، فرديًا أو في مجموعات صغيرة. بحساب Nostr مستقل لا يرتبط بجهات اتصال Conest. مشفّر بين الطرفين، لكن دون سرية مستقبلية.';

  @override
  String get uiYourNostrAddress5CF7C6 => 'عنوانك في Nostr';

  @override
  String get uiCopyWithYourRelaysD49669 => 'نسخ (مع مرحّلاتك)';

  @override
  String get uiNostrChats3D786C => 'محادثات Nostr';

  @override
  String get uiNewNostrChat68199C => 'محادثة Nostr جديدة';

  @override
  String get uiNpubSeveralForAGroupE6ED77 => 'npub1… (عدة عناوين للمجموعة)';

  @override
  String get uiCarryShortMessagesOverAFA94B6 =>
      'نقل رسائل قصيرة عبر شبكة MeshCore LoRa باستخدام جهاز الراديو المرافق، دون إنترنت. يضيف Conest جهات اتصالك إلى الراديو ليقبل رسائلهم.';

  @override
  String get uiMessagesWithMeshCoreAppUsersDE77BA =>
      'رسائل مع مستخدمي تطبيق MeshCore';

  @override
  String get uiReadAndWriteTheMeshCore98E60E =>
      'قراءة رسائل تطبيقات MeshCore وإرسالها عبر هذا الراديو: مع جهات اتصاله وعلى قنواته كمحادثات جماعية. حمايتها تقتصر على ما يوفّره MeshCore.';

  @override
  String get uiMeshCoreChats82C29C => 'محادثات MeshCore';

  @override
  String get uiSendWithItsDetailsF287FB => 'إرسال مع بياناته؟';

  @override
  String get uiSendAnyway911263 => 'إرسال رغم ذلك';

  @override
  String get uiSaveTheErrorHistory0B3413 => 'حفظ سجل الأخطاء';

  @override
  String uiSavedTheErrorHistoryTo5271C5(String value) {
    return 'حُفظ سجل الأخطاء في $value.';
  }

  @override
  String uiSavingTheErrorHistoryFailed72A33A(String value) {
    return 'فشل حفظ سجل الأخطاء: $value';
  }

  @override
  String get uiSaveToAFile5BB648 => 'حفظ في ملف';

  @override
  String get uiClear719EA3 => 'مسح';

  @override
  String get uiFilterD7DECF => 'تصفية';

  @override
  String get uiErrorsOnlyHideTheDebugECA1DD =>
      'الأخطاء فقط (إخفاء سجل التصحيح)';

  @override
  String uiValueH171B92(String value) {
    return '$value ساعة';
  }

  @override
  String uiValueMin439C52(String value) {
    return '$value دقيقة';
  }

  @override
  String uiTheirClockIsAboutValueF406F1(String value) {
    return 'ساعته تختلف بنحو $value $value؛ الأوقات هنا حسب هذا الجهاز.';
  }

  @override
  String uiValueB7CFB44(String value) {
    return '$value بايت';
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
  String get uiSent27E770 => 'أُرسلت';

  @override
  String get uiWaitingOnTheRelayED66FF => 'في انتظار المرحّل';

  @override
  String get uiReachedTheirDevice0FE289 => 'وصلت إلى جهازه';

  @override
  String get uiDeliveredF81891 => 'سُلّمت';

  @override
  String get uiReceived38428A => 'استُلمت';

  @override
  String get uiCarryShortMessagesOverADD8570 =>
      'نقل رسائل قصيرة عبر شبكة Meshtastic LoRa، دون إنترنت، باستخدام راديو Meshtastic. يحتاج الطرفان Conest وراديو في الشبكة نفسها.';

  @override
  String get uiFindDevices98771A => 'العثور على الأجهزة';

  @override
  String get uiRadioAddressD288E6 => 'عنوان الراديو';

  @override
  String get uiMessagesWithMeshtasticAppUsers812B3A =>
      'رسائل مع مستخدمي تطبيق Meshtastic';

  @override
  String get uiReadAndWriteTheMeshtastic995E5D =>
      'قراءة رسائل تطبيقات Meshtastic وإرسالها عبر هذا الراديو: الرسائل الخاصة وقنواته كمحادثات جماعية. حمايتها تقتصر على ما يوفّره Meshtastic.';

  @override
  String get uiMeshtasticChats46BEF8 => 'محادثات Meshtastic';

  @override
  String get uiClearSelection247FD6 => 'مسح التحديد';

  @override
  String get uiBrowseFilesAF7C13 => 'تصفح الملفات…';

  @override
  String get uiSelectMoreE38EF3 => 'تحديد المزيد';

  @override
  String get uiAllowAllA16326 => 'السماح بالكل';

  @override
  String get uiCaptionDA5C59 => 'وصف…';

  @override
  String get uiOpenSettingsFD7108 => 'فتح الإعدادات';

  @override
  String get uiDiscardChangesD3F0B4 => 'تجاهل التغييرات؟';

  @override
  String get uiYourEditsWillBeLostB34663 =>
      'ستُفقد تعديلاتك. تبقى الصورة الأصلية في المعرض.';

  @override
  String get uiKeepEditingD4D9E3 => 'متابعة التعديل';

  @override
  String get uiDiscard36FFF6 => 'تجاهل';

  @override
  String get uiRotateLeft6F72F3 => 'تدوير لليسار';

  @override
  String get uiRotateRightB75F23 => 'تدوير لليمين';

  @override
  String get uiApplyCropA43CCF => 'تطبيق القص';

  @override
  String get uiCropC5DB3D => 'قص';

  @override
  String get uiVerifiedDownloadProgressBED7C2 => 'تقدم التنزيل المتحقق منه';

  @override
  String get uiSharingWithGroup2AED71 => 'جارٍ المشاركة مع المجموعة';

  @override
  String get uiOpenCF9B77 => 'فتح';

  @override
  String get uiStopSharing0E45AE => 'إيقاف المشاركة';

  @override
  String get uiRemoveLocalCopy80FA01 => 'إزالة النسخة المحلية';

  @override
  String get uiScanInviteEFC78A => 'مسح دعوة';

  @override
  String uiValueValue176D15(String value, String value2) {
    return '$value:$value2';
  }

  @override
  String uiDefaultRelayValueBD3FD1(String value) {
    return 'المرحّل الافتراضي $value';
  }

  @override
  String uiSamplesValueSlowOverMsValueAE2EBF(String value, String value2) {
    return 'samples=$value slowOver100ms=$value2 maxTotalMs=$value maxBuildMs=$value maxRasterMs=$value';
  }

  @override
  String get uiConversation2A20C7 => 'المحادثة';

  @override
  String uiSharedValueWithTheGroup163418(String value) {
    return 'تمت مشاركة $value مع المجموعة كمرفق عادي؛ يحتاج بعض الأعضاء إلى تحديث لتشغيل الصوت.';
  }

  @override
  String uiSharedValueWithTheGroupAE4134(String value) {
    return 'تمت مشاركة $value مع المجموعة.';
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
  String get uiNone3C6B18 => '(لا شيء)';

  @override
  String uiLANNodeValueOn5D539E(String value) {
    return 'عقدة الشبكة المحلية على المنفذ $value تعمل';
  }

  @override
  String get uiLANNodeUnavailable9CFA32 => 'عقدة الشبكة المحلية غير متاحة';

  @override
  String uiLANValueA8EEF3(String value) {
    return 'LAN $value';
  }

  @override
  String uiRelayValueDownD6B267(String value) {
    return 'المرحّل $value متوقف';
  }

  @override
  String uiRelayValueA6D70A(String value) {
    return 'المرحّل $value';
  }

  @override
  String get uiNoInternetRelay55D2CE => 'لا يوجد مرحّل إنترنت';

  @override
  String uiValueValue42DC94(String value, String value2) {
    return '$value=$value2';
  }

  @override
  String uiValueHasBeenOutOf039D48(String value) {
    return 'انقطع الاتصال بـ $value منذ فترة: لن تتم مزامنة شيء معه حتى تؤكده في الإعدادات ← الأجهزة.';
  }

  @override
  String uiValueIsOneOfYourE4FD9C(String value) {
    return 'أصبح $value من أجهزتك الآن؛ لم تعد محادثته القديمة مدرجة.';
  }

  @override
  String uiYourDevicesDisagreeOnWhich2E7001(String value) {
    return 'تختلف أجهزتك حول الأجهزة الموجودة بالحساب، وسيزيد عددها معًا عن $value. أزل جهازًا في الإعدادات ← الأجهزة.';
  }

  @override
  String uiValueAddedADeviceValue710908(String value, String value2) {
    return 'أضاف $value جهازًا: $value2.';
  }

  @override
  String uiUnknownValue9B520C(String value) {
    return '$value غير معروف';
  }

  @override
  String uiReadByAllValue43BA5A(String value) {
    return 'قرأها الجميع ($value)';
  }

  @override
  String uiDeliveredToAllValue71E077(String value) {
    return 'سُلّمت للجميع ($value)';
  }

  @override
  String uiAcceptedByValueOfValue826A0E(String value, String value2) {
    return 'قبلها $value من $value2';
  }

  @override
  String uiWaitingForValueMemberS5A8BA6(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'في انتظار $value عضو',
      many: 'في انتظار $value عضو',
      few: 'في انتظار $value عضو',
      two: 'في انتظار $value عضو',
      one: 'في انتظار $value عضو',
      zero: 'في انتظار $value عضو',
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
    return 'تم تخطي $value: الحجم $value2 MB يتجاوز الحد $value3 MB.';
  }

  @override
  String get uiRoute499952 => 'المسار';

  @override
  String get uiSafetyNumber5ED2D3 => 'رقم الأمان';

  @override
  String get uiIrohEndpoint72F674 => 'نقطة اتصال Iroh';

  @override
  String get uiDeviceA5A74A => 'الجهاز';

  @override
  String get uiLANLobbyC16DC8 => 'دردشة الشبكة المحلية';

  @override
  String uiMembersValue541E72(String value) {
    return 'الأعضاء · $value';
  }

  @override
  String get uiNodeOnlineFAC64A => 'العقدة · متصلة';

  @override
  String uiSafetyValueC542B8(String value) {
    return 'الأمان $value';
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
      many: '$value عضوًا',
      few: '$value أعضاء',
      two: 'عضوان',
      one: 'عضو واحد',
      zero: 'لا أعضاء',
    );
    return '$_temp0';
  }

  @override
  String get uiPairwise64A0EF => 'بين كل طرفين';

  @override
  String get uiPasteMedia4831DE => 'لصق وسائط';

  @override
  String get uiRELAYA1C0CF => 'مرحّل';

  @override
  String get uiSentAsAPlainMatrixAAE694 => 'أُرسلت كرسالة Matrix عادية';

  @override
  String get uiOnlyOnThisDevice7D64C4 => 'على هذا الجهاز فقط';

  @override
  String get uiConnectivityIsOffTurnOnE42D4A =>
      'الاتصال متوقف. شغّل الشبكة المحلية أو الإنترنت لتبادل هذه الدعوة.';

  @override
  String get uiConnectivityIsOffTurnOnFA573F =>
      'الاتصال متوقف. شغّل الشبكة المحلية أو الإنترنت قبل مشاركة الدعوة.';

  @override
  String get uiReceiveBeam2CB58B => 'استقبال Beam';

  @override
  String get uiSendEncryptedFile99D424 => 'إرسال ملف مشفّر';

  @override
  String get uiSendPublicFileF81389 => 'إرسال ملف عام';

  @override
  String get uiBeamContactInvite2BAB4C => 'إرسال دعوة جهة اتصال عبر Beam';

  @override
  String get uiDevicesDF485C => 'الأجهزة';

  @override
  String get uiWARNC2FD77 => 'WARN';

  @override
  String get uiDOWN30E504 => 'DOWN';

  @override
  String get uiAVGRTTE96B26 => 'AVG RTT';

  @override
  String uiRoutingValueFC4557(String value) {
    return 'التوجيه — $value';
  }

  @override
  String uiActiveValueC78B63(String value) {
    return 'نشط ($value)';
  }

  @override
  String uiRecentValueB82237(String value) {
    return 'حديث ($value)';
  }

  @override
  String get uiDirect24A173 => 'مباشر';

  @override
  String get uiRelayBD28B2 => 'مرحّل';

  @override
  String get uiRoutingECF60A => 'جارٍ التوجيه';

  @override
  String uiInvitationValue6F0633(String value) {
    return 'دعوة: $value';
  }

  @override
  String get uiMeshChatNearbyA35A63 => 'محادثة الشبكة (بالقرب)';

  @override
  String get uiVerifiedWithAnInviteBD826F => 'تم التحقق بدعوة';

  @override
  String get uiHoldToTalkOrHold74FC22 =>
      'اضغط مطولًا للتحدث، أو اضغط على المسافة';

  @override
  String get uiEndToEndEncryptedMatrix9E4418 => 'مشفّر بين الطرفين (Matrix)';

  @override
  String get uiVerifiedAED3B8 => 'تم التحقق';

  @override
  String uiValueValue64684F(String value, String value2) {
    return '$value · $value2';
  }

  @override
  String get uiPrimaryChannel53B8E1 => 'القناة الرئيسية';

  @override
  String uiChannelValue76ED1D(String value) {
    return 'القناة $value';
  }

  @override
  String get uiPublicChannelA9795B => 'القناة العامة';

  @override
  String get uiDescriptionCB3291 => 'الوصف';

  @override
  String uiTheirClockIsAboutValue7DB956(String value, String value2) {
    return 'ساعته تختلف بنحو $value $value2؛ الأوقات هنا حسب هذا الجهاز.';
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
  String get uiConestTransfer406028 => 'نقل Conest';

  @override
  String uiValueConestTransfersF846F8(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value عملية نقل Conest',
      many: '$value عملية نقل Conest',
      few: '$value عملية نقل Conest',
      two: '$value عملية نقل Conest',
      one: '$value عملية نقل Conest',
      zero: '$value عملية نقل Conest',
    );
    return '$_temp0';
  }

  @override
  String uiViaValueValue37232D(String value, String value2) {
    return 'عبر $value ($value2)';
  }

  @override
  String get uiBackThroughTheContactWhoD09BD0 =>
      'عودةً عبر جهة الاتصال التي نقلت رسالته';

  @override
  String uiConestRelayValue4FB2DB(String value) {
    return 'مرحّل Conest ‏$value';
  }

  @override
  String get uiConestIsAlreadyRunningEE8037 => 'Conest يعمل بالفعل';

  @override
  String get uiCloseTheExistingConestWindow83B30B =>
      'أغلق نافذة Conest الحالية أولًا. تشغيل نسخة ثانية قد يتعارض على منفذ المرحّل المحلي والخزنة المشفّرة.';

  @override
  String get uiChooseWhereConestStoresData0CF613 =>
      'اختر مكان تخزين بيانات Conest';

  @override
  String get uiGhostModeIsBestEffort694912 =>
      'وضع التخفي يوفر خصوصية قدر الإمكان: سجل تشغيل النظام وتقارير الأعطال وبيانات الشبكة وسجل الطرفية والملفات الأخيرة وذاكرة المنصة خارج تحكم التطبيق.';

  @override
  String get uiDefaultOnThisDevice10343F => 'الافتراضي على هذا الجهاز';

  @override
  String get uiUseTheNormalAppDataF44F79 =>
      'استخدام مجلد بيانات التطبيق المعتاد وسلسلة مفاتيح الجهاز عند اختيار الفتح التلقائي.';

  @override
  String get uiGhostPortableBesideTheApp31A40D => 'تخفي / محمول بجانب التطبيق';

  @override
  String get uiStoreConestControlledFilesIn7DA307 =>
      'تخزين الملفات التي يديرها Conest في مجلد conest_data بجانب التطبيق.';

  @override
  String get uiVaultUnlock602BF6 => 'فتح الخزنة';

  @override
  String get uiKeyFileAutoUnlock66AC4A => 'فتح تلقائي بملف مفتاح';

  @override
  String get uiKeepsTheKeyBesideTheB045D9 =>
      'يُحفظ المفتاح بجانب الخزنة. يمكن لأي شخص يملك المجلد فتحها.';

  @override
  String get uiAutoUnlockWithThisDeviceE7F781 => 'فتح تلقائي بهذا الجهاز';

  @override
  String get uiStoresTheVaultKeyInC7B1CD =>
      'يُحفظ مفتاح الخزنة في مخزن النظام الآمن.';

  @override
  String get uiPassphraseUnlock13B14C => 'فتح بعبارة مرور';

  @override
  String get uiAskForAPassphraseOn4BA25C =>
      'طلب عبارة مرور عند كل تشغيل. لا يمكن استرداد عبارة المرور المنسية.';

  @override
  String get uiUnlockConest033EB6 => 'فتح Conest';

  @override
  String get uiEnterThePassphraseForThis891200 => 'أدخل عبارة مرور هذه الخزنة.';

  @override
  String get uiNoUpdateIsAvailableRightA5EB48 => 'لا يوجد تحديث متاح الآن.';

  @override
  String uiValueIsAvailableOnTheD338C4(String value, String value2) {
    return '$value متاح على قناة $value2.';
  }

  @override
  String uiCurrentBuildValue2FD415(String value) {
    return 'الإصدار الحالي: $value';
  }

  @override
  String get uiWhatSNew4D8DC5 => 'ما الجديد';

  @override
  String get uiSERVERLESSSECUREMESSENGER1E1891 => '◢ مراسلة آمنة دون خوادم';

  @override
  String uiYourMatrixSessionValueWants580E45(String value) {
    return 'تريد جلسة Matrix الخاصة بك $value التحقق من هذه الجلسة. اقبل فقط إن كنت أنت من بدأ الطلب.';
  }

  @override
  String uiValueWantsToVerifyYou61FD9D(String value) {
    return 'يريد $value التحقق منك بمقارنة الرموز التعبيرية. افحص العنوان كاملًا؛ توجد عناوين متشابهة. اقبل فقط إذا أمكن المقارنة شخصيًا أو بمكالمة؛ فالتحقق يضع مفاتيحه ضمن الموثوقة.';
  }

  @override
  String uiCouldNotVerifyValue3AE1C4(String value) {
    return 'تعذّر التحقق: $value';
  }

  @override
  String get uiSendWithoutResumableCopy0475F4 =>
      'إرسال دون نسخة قابلة للاستئناف؟';

  @override
  String uiValueCouldNotBeCopied06F61A(
    String value,
    String value2,
    String value3,
  ) {
    return 'تعذّر نسخ $value إلى تخزين النقل الخاص.\n\n$value2\n\nيمكن للتطبيق قراءة الملف الأصلي مباشرة، لكن لن يُستأنف النقل بعد إعادة التشغيل إذا نُقل الملف أو انتهى إذن الوصول إليه.$value3';
  }

  @override
  String get uiUnmute7044C3 => 'إلغاء الكتم';

  @override
  String get uiMute0F0973 => 'كتم';

  @override
  String get uiSpeakerOn93982E => 'مكبر الصوت مشغّل';

  @override
  String get uiSpeakerOff97823A => 'مكبر الصوت متوقف';

  @override
  String get uiCancelCallCE6C16 => 'إلغاء المكالمة';

  @override
  String uiValueValueReturnToCall49F82C(String value, String value2) {
    return '$value$value2 · العودة للمكالمة';
  }

  @override
  String get uiContactDetailsD4EC65 => 'تفاصيل جهة الاتصال';

  @override
  String uiValueActiveMemberValue6700F2(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value عضو نشط',
      many: '$value عضو نشط',
      few: '$value عضو نشط',
      two: '$value عضو نشط',
      one: '$value عضو نشط',
      zero: '$value عضو نشط',
    );
    return '$_temp0';
  }

  @override
  String get uiOwner89FF31 => 'المالك';

  @override
  String uiEditValue75BE00(String value) {
    return 'تعديل $value';
  }

  @override
  String uiCouldNotSaveChatSettings2372B2(String value) {
    return 'تعذّر حفظ إعدادات المحادثة: $value';
  }

  @override
  String get uiAddAContactToStart165431 => 'أضف جهة اتصال لبدء محادثة';

  @override
  String get uiNoContactsFound816015 => 'لم يُعثر على جهات اتصال';

  @override
  String uiOpenValue8DF02B(String value) {
    return 'فتح #$value';
  }

  @override
  String get uiNoMessagesYetC04921 => 'لا توجد رسائل بعد';

  @override
  String get uiNoActivityYetPairA7F5366 =>
      'لا يوجد نشاط بعد؛ اقترن بجهة اتصال لبدء السجل.';

  @override
  String get uiSENT5AD0CD => 'أُرسلت';

  @override
  String get uiRECVBFC296 => 'استُلمت';

  @override
  String uiDeviceValue11AEA9(String value) {
    return 'الجهاز $value';
  }

  @override
  String get uiFreeForAllLocalChat5485CC =>
      'دردشة محلية مفتوحة للجميع • غير موثوقة';

  @override
  String get uiGroupsAE9629 => 'المجموعات';

  @override
  String get uiAddTrustedContactsBeforeCreating1084CC =>
      'أضف جهات اتصال موثوقة قبل إنشاء مجموعة.';

  @override
  String get uiNoGroupsYet5009C6 => 'لا توجد مجموعات بعد.';

  @override
  String uiValueMemberSE75249(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value عضو',
      many: '$value عضوًا',
      few: '$value أعضاء',
      two: 'عضوان',
      one: 'عضو واحد',
      zero: 'لا أعضاء',
    );
    return '$_temp0';
  }

  @override
  String get uiContactsB0DD61 => 'جهات الاتصال';

  @override
  String get uiAppliesToFutureAdmissionsHistory78E3A0 =>
      'ينطبق على الانضمامات المستقبلية. لا يمكن سحب سجل سبق استلامه.';

  @override
  String uiValueAllRetainedHistory5E25F4(String value) {
    return '$valueكل السجل المحتفظ به';
  }

  @override
  String uiValueSinceAdmissionB2617B(String value) {
    return '$valueمنذ الانضمام';
  }

  @override
  String uiDeleteValueF0396B(String value) {
    return 'حذف «$value»';
  }

  @override
  String uiDeleteValueForEveryone12E724(String value) {
    return 'حذف «$value» للجميع؟';
  }

  @override
  String uiValueMemberSOwnerValueE42E13(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value عضو • المالك $value2',
      many: '$value عضو • المالك $value2',
      few: '$value عضو • المالك $value2',
      two: '$value عضو • المالك $value2',
      one: '$value عضو • المالك $value2',
      zero: '$value عضو • المالك $value2',
    );
    return '$_temp0';
  }

  @override
  String get uiGROUPTRUSTFANOUTMintPaired5DDF6E =>
      '// GROUP TRUST FANOUT · mint = paired';

  @override
  String get uiAddTrustedContact126717 => 'إضافة جهة اتصال موثوقة';

  @override
  String get uiNoAvailableChats1FAA40 => 'لا توجد محادثات متاحة';

  @override
  String get uiForwardedMessageQueuedC82DA4 =>
      'وُضعت الرسالة المعاد توجيهها في الانتظار';

  @override
  String uiCouldNotForwardValue80193D(String value) {
    return 'تعذّرت إعادة التوجيه: $value';
  }

  @override
  String get uiForwardedAttachmentQueued57C88B =>
      'وُضع المرفق المعاد توجيهه في الانتظار';

  @override
  String uiCouldNotForwardAttachmentValue5165FD(String value) {
    return 'تعذّرت إعادة توجيه المرفق: $value';
  }

  @override
  String get uiChatDetails15DAEC => 'تفاصيل المحادثة';

  @override
  String get uiConnectionDetailsAB30A5 => 'تفاصيل الاتصال';

  @override
  String uiValueValue270519(String value, String value2) {
    return '$value / $value2';
  }

  @override
  String uiVoiceMessageValue2F0300(String value) {
    return 'رسالة صوتية · $value';
  }

  @override
  String uiPlaybackFailedValue1C0E1A(String value) {
    return 'فشل التشغيل: $value';
  }

  @override
  String get uiPreparingMicrophone0BBF4A => 'جارٍ تجهيز الميكروفون…';

  @override
  String get uiPreparingPreview312E7B => 'جارٍ تجهيز المعاينة…';

  @override
  String uiVoiceMessagePreviewValue8235CB(String value) {
    return 'معاينة الرسالة الصوتية · $value';
  }

  @override
  String uiRecordingValueValue111FF1(String value, String value2) {
    return 'جارٍ التسجيل$value · $value2';
  }

  @override
  String get uiSendingCF7655 => 'جارٍ الإرسال…';

  @override
  String uiValue72F816(String value) {
    return '$value×';
  }

  @override
  String get uiSingleChoice68E3E0 => 'اختيار واحد';

  @override
  String get uiMultipleChoiceB88936 => 'اختيارات متعددة';

  @override
  String uiThisRemovesTheMessageFor2247A2(String value) {
    return 'سيُحذف هذا من رسائل أعضاء المجموعة عند المزامنة.$value';
  }

  @override
  String get uiCouldNotLocateThisMessage220E83 =>
      'تعذّر العثور على هذه الرسالة في المحادثة الحالية';

  @override
  String uiDeleteValueMessageValueForABA7AC(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'حذف $value رسالة للمجموعة؟',
      many: 'حذف $value رسالة للمجموعة؟',
      few: 'حذف $value رسالة للمجموعة؟',
      two: 'حذف $value رسالة للمجموعة؟',
      one: 'حذف $value رسالة للمجموعة؟',
      zero: 'حذف $value رسالة للمجموعة؟',
    );
    return '$_temp0';
  }

  @override
  String uiValueValue29C8B9(String value, String value2) {
    return '$value $value2';
  }

  @override
  String get uiNewC2A6B0 => 'جديد';

  @override
  String get uiEditedA22FCA => 'معدّل';

  @override
  String get uiCopyCachePathC23134 => 'نسخ مسار التخزين المؤقت';

  @override
  String get uiStopKeepingOfflineAABFC7 => 'إيقاف الاحتفاظ دون اتصال';

  @override
  String get uiKeepOffline123286 => 'الاحتفاظ دون اتصال';

  @override
  String get uiForwardFileC4B5CB => 'إعادة توجيه الملف';

  @override
  String get uiLoadingHistory02CB12 => 'جارٍ تحميل السجل…';

  @override
  String get uiLoadOlderMessages07471F => 'تحميل رسائل أقدم';

  @override
  String get uiShareFileNow96E2A2 => 'مشاركة الملف الآن';

  @override
  String get uiScheduleFile690A92 => 'جدولة الملف';

  @override
  String get uiDropToShareThisFile0B73E8 =>
      'أفلِت لمشاركة هذا الملف مع المجموعة';

  @override
  String get uiClosed88D86B => 'مغلق';

  @override
  String get uiVisibleVotes460E7A => 'أصوات ظاهرة';

  @override
  String uiValueVoteSWereNot02CC9A(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'لم يتضمن سجل الإغلاق عند المنشئ $value صوتًا.',
      many: 'لم يتضمن سجل الإغلاق عند المنشئ $value صوتًا.',
      few: 'لم يتضمن سجل الإغلاق عند المنشئ $value صوتًا.',
      two: 'لم يتضمن سجل الإغلاق عند المنشئ $value صوتًا.',
      one: 'لم يتضمن سجل الإغلاق عند المنشئ $value صوتًا.',
      zero: 'لم يتضمن سجل الإغلاق عند المنشئ $value صوتًا.',
    );
    return '$_temp0';
  }

  @override
  String get uiVotingIsUnavailableWithThis9B92E7 =>
      'التصويت غير متاح بهذا الإصدار من Conest.';

  @override
  String get uiThisRemovesTheMessageHere61D27C =>
      'يُحذف هذا من هنا ويُطلب من جهة الاتصال حذف نسختها إن أمكن الوصول إليها.';

  @override
  String get uiThisRemovesTheMessageFrom6A47E2 => 'يُحذف هذا من هذا الجهاز.';

  @override
  String get uiSendViaMatrix3868FE => 'إرسال عبر Matrix…';

  @override
  String get uiNotesFilesAndForwardsOnlyB0145F =>
      'ملاحظات وملفات ورسائل معاد توجيهها، على هذا الجهاز فقط';

  @override
  String uiValueSafetyValue82C755(String value, String value2) {
    return '$value • الأمان $value2';
  }

  @override
  String uiDropFilesToSendMax106011(String value) {
    return 'أفلِت الملفات للإرسال (الحد $value)';
  }

  @override
  String get uiFreeForAllLocalChatBC90D2 =>
      'دردشة محلية مفتوحة للجميع. الرسائل موقّعة لكل جلسة، لكن الموجودين هنا ليسوا جهات اتصال موثوقة.';

  @override
  String get uiNoLANLobbyMessagesYetBCDC4B =>
      'لا توجد رسائل في دردشة الشبكة المحلية بعد. ستستقبلها أجهزة Conest القريبة ما دامت على الشبكة نفسها.';

  @override
  String uiValueUntrusted519A32(String value) {
    return '$value • غير موثوق';
  }

  @override
  String uiRemoveValueF4FE4B(String value) {
    return 'إزالة $value؟';
  }

  @override
  String get uiAvailablePaths6EE503 => 'المسارات المتاحة';

  @override
  String get uiRunACheckToMeasure5D76A5 =>
      'شغّل فحصًا لقياس التأخير والإتاحة وحداثة الوصول. تُرتّب المسارات بأفضل اتصال مباشر أو محلي أولًا، ثم المرحّلات البديلة.';

  @override
  String get uiNoRouteHintsAreAdvertisedB25540 =>
      'لا تُعلن جهة الاتصال عن مسارات.';

  @override
  String get uiEitherInputIsEnoughOn020B90 =>
      'يكفي أي خيار وحده. امسح دعوة QR أو الصقها للوثوق المباشر، أو أدخل عبارة الرمز الحالية فقط لاكتشاف المرسِل عبر الشبكة المحلية أو المرحّل المعدّ. إن فشل التبادل التلقائي، سيقترح التطبيق طلب إضافتك من الطرف الآخر أو الإلغاء.';

  @override
  String get uiInvitePreview6433A0 => 'معاينة الدعوة';

  @override
  String uiValueValueValue98AECE(String value, String value2, String value3) {
    return '$value$value2 • $value3';
  }

  @override
  String get uiShareInviteDBCC1E => 'مشاركة الدعوة';

  @override
  String get uiThisInviteWorksOnlyOnB106B0 =>
      'تعمل الدعوة على الشبكة نفسها فقط: لا يوجد مسار إنترنت مفعّل. فعّل مرحّلات Iroh أو مرحّل Conest أو ناقلًا (Nostr أو البريد) في الإعدادات ← الاتصال ليتمكن الآخرون من إضافتك من أي مكان.';

  @override
  String get uiThisInviteAlsoListsYourEF3A4F =>
      'تتضمن الدعوة أيضًا مساراتك للشبكات المحجوبة، لذا هي أكبر من رمز QR واحد. اعرضها عبر Beam: رمز QR متحرك تقرؤه الكاميرا الأخرى خلال ثوانٍ.';

  @override
  String get uiQRRenderingIsDeferredOn8A6997 => 'يتأخر رسم QR على Windows.';

  @override
  String get uiUseTheCodephraseBelowOrB6A588 =>
      'استخدم عبارة الرمز أدناه أو اعرض QR بعد فتح هذه الصفحة.';

  @override
  String get uiScanningTheCompactQRIs9459D9 =>
      'يكفي مسح QR المختصر وحده. إن تعثّرت الكاميرا فافتحه بملء الشاشة أو استخدم عبارة الرمز الحالية فقط.';

  @override
  String uiQRPayloadValueCharactersBABEDF(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'حجم دعوة QR: ‏$value حرف',
      many: 'حجم دعوة QR: ‏$value حرف',
      few: 'حجم دعوة QR: ‏$value حرف',
      two: 'حجم دعوة QR: ‏$value حرف',
      one: 'حجم دعوة QR: ‏$value حرف',
      zero: 'حجم دعوة QR: ‏$value حرف',
    );
    return '$_temp0';
  }

  @override
  String uiAlsoListsYourAddressesOnC5D815(String value) {
    return 'تتضمن أيضًا عناوينك على: $value.';
  }

  @override
  String uiPinnedValue834309(String value) {
    return 'مثبّت · $value';
  }

  @override
  String get uiNoVerifiedCiContactsAre3FD190 =>
      'لا توجد جهات اتصال ci6 متحقق منها بعد.';

  @override
  String get uiCloseUpTransferE6BA46 => 'نقل عن قرب';

  @override
  String get uiALoopingLTFountainStream840218 =>
      'يستمر تدفق LT المتكرر رغم إطارات QR المفقودة أو المكررة أو غير المرتّبة. يُتحقّق من تجزئة الملف النهائي قبل قبوله.';

  @override
  String get uiPUBLICVisibleToAnyoneNearbyA775C2 => 'عام · ظاهر لكل من بالقرب';

  @override
  String get uiCONTACTENCRYPTED879896 => 'مشفّر لجهة اتصال';

  @override
  String get uiSIGNEDCONTACTINVITE752317 => 'دعوة جهة اتصال موقّعة';

  @override
  String uiFrameValueValueSourceBlocks9C37CB(
    String value,
    int value2,
    String value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value2,
      locale: localeName,
      other: 'الإطار $value · $value2 كتلة مصدر · $value3',
      many: 'الإطار $value · $value2 كتلة مصدر · $value3',
      few: 'الإطار $value · $value2 كتلة مصدر · $value3',
      two: 'الإطار $value · $value2 كتلة مصدر · $value3',
      one: 'الإطار $value · $value2 كتلة مصدر · $value3',
      zero: 'الإطار $value · $value2 كتلة مصدر · $value3',
    );
    return '$_temp0';
  }

  @override
  String get uiPointThisCameraAtThe2EA3F7 =>
      'وجّه هذه الكاميرا إلى رمز Beam المتحرك. لا يغادر الماسح الأصلي سوى إطارات cb1 المفككة.';

  @override
  String get uiNativeDesktopCameraCaptureIs4619C8 =>
      'التقاط الكاميرا الأصلي لسطح المكتب غير متاح. الصق إطارات cb1 أدناه؛ فك البروتوكول والتحقق متطابقان.';

  @override
  String uiValueValueBlocksValueFrames66F819(
    String value,
    String value2,
    String value3,
    String value4,
  ) {
    return '$value/$value2 كتلة · $value3 إطار · $value4 غير صالح';
  }

  @override
  String get uiSignedContactInviteA7CC8B => 'دعوة جهة اتصال موقّعة';

  @override
  String get uiPUBLICUNTRUSTEDTheSignatureProves96FA7F =>
      'عام / غير موثوق. يثبت التوقيع أن الإطارات كلها من مفتاح واحد؛ لا يثبت مالك هذا المفتاح.';

  @override
  String get uiEncryptedAndAuthenticatedAsA68B7E4 =>
      'مشفّر ومصادق عليه بصفته جهة اتصال Conest مثبّتة.';

  @override
  String get uiSignatureValidCompareTheFingerprintA8A1FE =>
      'التوقيع صحيح. قارن البصمة شخصيًا.';

  @override
  String get uiAcceptAndSavePublicFile852517 => 'قبول الملف العام وحفظه';

  @override
  String get uiSaveFileBEDC84 => 'حفظ الملف';

  @override
  String get uiFullscreenCompactInviteQRCF6B8B => 'QR دعوة مختصر بملء الشاشة';

  @override
  String uiValueCharactersIncreaseScreenBrightnessA5AF7D(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value حرفًا. ارفع سطوع الشاشة إن تعذّر المسح.',
      many: '$value حرفًا. ارفع سطوع الشاشة إن تعذّر المسح.',
      few: '$value حرفًا. ارفع سطوع الشاشة إن تعذّر المسح.',
      two: '$value حرفًا. ارفع سطوع الشاشة إن تعذّر المسح.',
      one: '$value حرفًا. ارفع سطوع الشاشة إن تعذّر المسح.',
      zero: '$value حرفًا. ارفع سطوع الشاشة إن تعذّر المسح.',
    );
    return '$_temp0';
  }

  @override
  String get uiPersonalPreferencesBD0D61 => 'الشخصية / التفضيلات';

  @override
  String get uiNetworkRelay4F9A27 => 'الشبكة / المرحّل';

  @override
  String get uiDanger58D175 => 'خطر';

  @override
  String get uiAllowsOneToOneIroh45EEF1 =>
      'يسمح بمكالمات Iroh فردية على هذا الجهاز. أوقفه لمنع إجراء المكالمات واستقبالها.';

  @override
  String get uiPrivacyOfFilesYouSend4E4A5B => 'خصوصية الملفات التي ترسلها';

  @override
  String get uiLowA12494 => 'منخفض';

  @override
  String get uiMediumD40496 => 'متوسط';

  @override
  String get uiHighB1A595 => 'مرتفع';

  @override
  String get uiTransportPolicy088D79 => 'سياسة النقل';

  @override
  String get uiPerContactRoutingIsIntersected88E292 =>
      'يتقيّد توجيه كل جهة اتصال بهذه الخيارات. إيقاف أي منهما يقيّد الحركة؛ وإيقاف الاثنين يجعل التطبيق خاملًا.';

  @override
  String get uiConnectivityIsFullyOffTheB12483 =>
      'الاتصال متوقف تمامًا؛ لن يرسل التطبيق أو يستقبل.';

  @override
  String uiValueCandidateRouteSAre175673(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'يوجد $value مسار محتمل متاح الآن.',
      many: 'يوجد $value مسار محتمل متاح الآن.',
      few: 'يوجد $value مسار محتمل متاح الآن.',
      two: 'يوجد $value مسار محتمل متاح الآن.',
      one: 'يوجد $value مسار محتمل متاح الآن.',
      zero: 'يوجد $value مسار محتمل متاح الآن.',
    );
    return '$_temp0';
  }

  @override
  String get uiConfiguredRelays3CA0DE => 'المرحّلات المعدّة';

  @override
  String get uiNoRelaysAddedYetF791E7 => 'لم تُضف مرحّلات بعد.';

  @override
  String uiCurrentBuildValueValue9A675D(String value, String value2) {
    return 'الإصدار الحالي: $value • $value2';
  }

  @override
  String uiCommitValue2E080C(String value) {
    return 'التثبيت $value';
  }

  @override
  String uiAvailableValue4B15F7(String value) {
    return 'متاح: $value';
  }

  @override
  String get uiChecking494D0F => 'جارٍ الفحص…';

  @override
  String get uiCheckForUpdates8604FF => 'التحقق من التحديثات';

  @override
  String uiTrustNewIdentityForValue8B0612(String value) {
    return 'الوثوق بالهوية الجديدة لـ $value؟';
  }

  @override
  String uiTheRelayIsNowSigningFF71FD(String value) {
    return 'يوقّع المرحّل الآن بمفتاح Ed25519 عام مختلف ($value). تابع فقط إذا أكد المشغّل أنه بدّل المفتاح؛ وإلا فقد يكون هجوم وسيط.';
  }

  @override
  String get uiRelayIdentityChanged097638 => 'تغيّرت هوية المرحّل';

  @override
  String get uiAConfiguredRelayIsSigning60EED0 =>
      'يوقّع مرحّل معدّ بمفتاح جديد. تحقّق مع المشغّل قبل الوثوق به.';

  @override
  String uiValueValue66746D(String value, String value2) {
    return '$value → $value2';
  }

  @override
  String get uiNoPendingContactRequests697615 => 'لا توجد طلبات تواصل معلّقة';

  @override
  String uiCouldNotReviewRequestValue82B3D5(String value) {
    return 'تعذّرت مراجعة الطلب: $value';
  }

  @override
  String uiAddValueF034EE(String value) {
    return 'إضافة $value؟';
  }

  @override
  String uiCouldNotAddContactValue7F6C38(String value) {
    return 'تعذّرت إضافة جهة الاتصال: $value';
  }

  @override
  String uiCouldNotRejectRequestValue2EFD58(String value) {
    return 'تعذّر رفض الطلب: $value';
  }

  @override
  String get uiContactRequestRejected447EE8 => 'رُفض طلب التواصل.';

  @override
  String uiContactRequestFromValue50B6AC(String value) {
    return 'طلب تواصل من $value';
  }

  @override
  String uiUnverifiedValueC1937C(String value) {
    return 'غير متحقق منه · $value';
  }

  @override
  String uiContactRequestFailedValue28DD81(String value) {
    return 'فشل طلب التواصل: $value';
  }

  @override
  String get uiRequestAgain7B0434 => 'طلب مجددًا';

  @override
  String uiTrustValueAsAFresh7BF87F(String value, String value2) {
    return 'الوثوق بـ $value كاتصال جديد؟ تحقّق من رقم الأمان عبر قناة أخرى أولًا؛ القبول يؤرشف أي إدخالات سابقة باسم «$value2» للقراءة فقط.';
  }

  @override
  String uiTrustThisAsAReinstallCBA4CC(String value) {
    return 'الوثوق بهذه الهوية كتثبيت جديد لـ «$value»؟ ستُؤرشف جهة الاتصال السابقة مع إبقاء السجل للقراءة فقط، وتحل الجديدة مكانها. لا يمكن التراجع.';
  }

  @override
  String uiConfirmFailedValueBDE200(String value) {
    return 'فشل التأكيد: $value';
  }

  @override
  String uiRejectFailedValue5F5917(String value) {
    return 'فشل الرفض: $value';
  }

  @override
  String uiThisContactMayBeAD1405D(String value) {
    return 'قد تكون جهة الاتصال هذه نسخة أعيد تعيينها من «$value». تحقّق من رقم الأمان عبر قناة أخرى قبل تبادل الرسائل.';
  }

  @override
  String uiImportedRelaysFromValue37C175(String value) {
    return 'تم استيراد مرحّلات من $value.';
  }

  @override
  String uiImportFailedValueBAFB4A(String value) {
    return 'فشل الاستيراد: $value';
  }

  @override
  String uiThisWillRemoveValueRelay330EEB(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'سيؤدي هذا إلى إزالة $value مسار مرحّل مستورد من $value2.',
      many: 'سيؤدي هذا إلى إزالة $value مسار مرحّل مستورد من $value2.',
      few: 'سيؤدي هذا إلى إزالة $value مسار مرحّل مستورد من $value2.',
      two: 'سيؤدي هذا إلى إزالة $value مسار مرحّل مستورد من $value2.',
      one: 'سيؤدي هذا إلى إزالة $value مسار مرحّل مستورد من $value2.',
      zero: 'سيؤدي هذا إلى إزالة $value مسار مرحّل مستورد من $value2.',
    );
    return '$_temp0';
  }

  @override
  String uiRemoveFailedValue58F348(String value) {
    return 'فشلت الإزالة: $value';
  }

  @override
  String get uiImportedRelayListsB0BD8B => 'قوائم المرحّلات المستوردة';

  @override
  String get uiNoImportedLists6CBC34 => 'لا توجد قوائم مستوردة.';

  @override
  String uiValueValueValueRouteS40FB98(
    String value,
    String value2,
    int value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value3,
      locale: localeName,
      other: '$value · $value2 · $value3 مسار',
      many: '$value · $value2 · $value3 مسار',
      few: '$value · $value2 · $value3 مسار',
      two: '$value · $value2 · $value3 مسار',
      one: '$value · $value2 · $value3 مسار',
      zero: '$value · $value2 · $value3 مسار',
    );
    return '$_temp0';
  }

  @override
  String get uiLeaveBlankToImportUnsigned0D354E =>
      'اتركه فارغًا للاستيراد دون توقيع (غير موثوق؛ تظل فحوص ما قبل الاستخدام مطلوبة). أدخل مفتاح المشغّل لاستيراد موثوق تشفيريًا؛ يُجلب التوقيع من <URL>.ed25519.sig.';

  @override
  String uiValueF7CD86(String value) {
    return '// $value';
  }

  @override
  String get uiThemeA797E3 => 'السمة';

  @override
  String get uiAdaptiveIsUsingSystemDynamicBAA149 =>
      'تستخدم السمة المتكيّفة ألوان النظام الديناميكية.';

  @override
  String get uiMintAndPinkRemainTheC846F3 =>
      'يبقى النعناعي والوردي لوني Conest البديلين.';

  @override
  String get uiDecoration2DB87A => 'الزخرفة';

  @override
  String get uiAmbientGridScanlinesCornerReticles45D5C5 =>
      'شبكة خلفية وخطوط مسح وعلامات زوايا وقراءة الحالة. من البسيط إلى الجو الكامل.';

  @override
  String get uiShellBDC1FD => 'واجهة';

  @override
  String get uiHomeLayoutE19685 => 'تخطيط الرئيسية';

  @override
  String uiCONESTCiValue7964DC(String value) {
    return 'CONEST · ci5 · $value';
  }

  @override
  String get uiQRUnavailable12869A => 'QR غير متاح';

  @override
  String get uiUseTheCodephraseOrPayload187111 =>
      'استخدم عبارة الرمز أو نص الدعوة أدناه.';

  @override
  String uiTwoWayConfirmedValueE5A1A1(String value) {
    return 'تم التأكيد بالاتجاهين$value';
  }

  @override
  String uiPathAcceptsSendWaitingFor10B4B0(String value) {
    return 'المسار يقبل الإرسال؛ في انتظار رد الطرف الآخر$value';
  }

  @override
  String get uiUnavailable1D5EE3 => 'غير متاح';

  @override
  String get uiUsable829A7C => 'قابل للاستخدام';

  @override
  String get uiOneWay5EF4D0 => 'اتجاه واحد';

  @override
  String get uiSkipC7E168 => 'تخطي';

  @override
  String get uiShareYourInviteThenEither5FEF78 =>
      'شارك دعوتك ثم امسح رمز QR أو أدخل عبارة الرمز الحالية فقط على الجهاز الآخر لإضافة جهة الاتصال.';

  @override
  String get uiStartWithOneTrustedContact650B80 =>
      'ابدأ بجهة اتصال موثوقة واحدة';

  @override
  String get uiThisReleasePairsThroughA883AA2 =>
      'يقترن هذا الإصدار بدعوة QR وحدها أو بعبارة رمز وحدها، ويفضّل المسارات المحلية القريبة ثم يعود إلى مرحّلات الإنترنت.';

  @override
  String get uiConnectivityIsOffEnableLAN39990E =>
      'الاتصال متوقف. فعّل الشبكة المحلية أو الإنترنت في الإعدادات.';

  @override
  String get uiAutomaticAC9041 => 'تلقائي';

  @override
  String get uiPreferred0A3E0D => 'مفضّل';

  @override
  String get uiDisabledF4F447 => 'معطّل';

  @override
  String get uiAskFirst1AEB84 => 'السؤال أولًا';

  @override
  String get uiRetryFailed7B6CA4 => 'إعادة محاولة الفاشل';

  @override
  String get uiCancelAlbumDB0A07 => 'إلغاء الألبوم';

  @override
  String get uiDeleteAlbum52E30F => 'حذف الألبوم';

  @override
  String get menuForwardAlbum => 'إعادة توجيه الألبوم';

  @override
  String get menuSelect => 'تحديد';

  @override
  String get menuSelectAlbum => 'تحديد الألبوم';

  @override
  String uiValueSelectedB1DFAF(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'تم تحديد $value',
      many: 'تم تحديد $value',
      few: 'تم تحديد $value',
      two: 'تم تحديد $value',
      one: 'تم تحديد $value',
      zero: 'تم تحديد $value',
    );
    return '$_temp0';
  }

  @override
  String uiThisWillCancelValueActiveB3425E(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other:
          'سيؤدي هذا لإلغاء $value عملية نقل نشطة ومسح القائمة. ستبقى رسائل المحادثات والملفات المكتملة.',
      many:
          'سيؤدي هذا لإلغاء $value عملية نقل نشطة ومسح القائمة. ستبقى رسائل المحادثات والملفات المكتملة.',
      few:
          'سيؤدي هذا لإلغاء $value عملية نقل نشطة ومسح القائمة. ستبقى رسائل المحادثات والملفات المكتملة.',
      two:
          'سيؤدي هذا لإلغاء $value عملية نقل نشطة ومسح القائمة. ستبقى رسائل المحادثات والملفات المكتملة.',
      one:
          'سيؤدي هذا لإلغاء $value عملية نقل نشطة ومسح القائمة. ستبقى رسائل المحادثات والملفات المكتملة.',
      zero:
          'سيؤدي هذا لإلغاء $value عملية نقل نشطة ومسح القائمة. ستبقى رسائل المحادثات والملفات المكتملة.',
    );
    return '$_temp0';
  }

  @override
  String get uiNoTransfersYetB8E5C1 => 'لا توجد عمليات نقل بعد.';

  @override
  String get uiAttachmentMetadataUnavailableE2C31D =>
      'بيانات المرفق الوصفية غير متاحة';

  @override
  String uiValueMBPreparingDownload799D4A(String value) {
    return '$value MB · جارٍ تجهيز التنزيل…';
  }

  @override
  String uiValueMBDirectRouteRequired6379F0(String value) {
    return '$value MB · يلزم مسار مباشر';
  }

  @override
  String uiValueMBTapToDownload432280(String value) {
    return '$value MB · انقر للتنزيل';
  }

  @override
  String get uiPreparingDownload8CB769 => 'جارٍ تجهيز التنزيل…';

  @override
  String uiTransferringValueValue10EEBE(String value, String value2) {
    return 'جارٍ النقل · $value% · $value2';
  }

  @override
  String uiTransferringValue9D7F13(String value) {
    return 'جارٍ النقل · $value';
  }

  @override
  String get uiVoiceMessage999DEB => 'رسالة صوتية';

  @override
  String get uiSendAsMedia061D87 => 'إرسال كوسائط';

  @override
  String get uiSendAsFileB50EAF => 'إرسال كملف';

  @override
  String get uiMEDIAB85FA2 => 'وسائط';

  @override
  String get uiFILEB4915D => 'ملف';

  @override
  String get uiPausedByPeer63BD05 => 'أوقفه الطرف الآخر مؤقتًا';

  @override
  String get uiCouldNotDecodeThisImage3EAA16 => 'تعذّر فك ترميز هذه الصورة.';

  @override
  String uiValueValueValueDAEE95(String value, String value2, String value3) {
    return '$value  ·  $value2/$value3';
  }

  @override
  String uiValueCannotBeReachedOver14E8C2(String value, String value2) {
    return 'لا يمكن الوصول إلى $value عبر Conest الآن. هل تريد إرسال هذه الرسالة إلى $value2 كرسالة Matrix عادية بدلًا من ذلك؟\n\nستصل إلى محادثتكما الخاصة في Matrix، دون تشفير Conest: يمكن للخادم المنزلي قراءتها ما لم تكن المحادثة مشفّرة. سيتوقف Conest عن محاولة تسليمها.';
  }

  @override
  String uiValueF69855(String value) {
    return '+$value';
  }

  @override
  String uiCouldNotPlayThisVideoF7D318(String value) {
    return 'تعذّر تشغيل هذا الفيديو: $value';
  }

  @override
  String get uiYouLeft9F2CDB => 'لقد غادرت';

  @override
  String uiReplyingToValue645786(String value) {
    return 'رد على $value';
  }

  @override
  String get uiNoScheduledMessages1DDB60 => 'لا توجد رسائل مجدولة';

  @override
  String get uiScheduledAttachment08DB0E => 'مرفق مجدول';

  @override
  String uiValueValueValue209DD2(String value, String value2, String value3) {
    return '$value • $value2\n$value3';
  }

  @override
  String get uiSendNowDAE330 => 'إرسال الآن';

  @override
  String get uiReschedule34B2DC => 'إعادة الجدولة';

  @override
  String get uiShareTextTo7B5086 => 'مشاركة النص مع…';

  @override
  String uiShareValueTo6E3BDD(String value) {
    return 'مشاركة $value مع…';
  }

  @override
  String uiShareValueFilesToA46E17(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'مشاركة $value ملف مع…',
      many: 'مشاركة $value ملف مع…',
      few: 'مشاركة $value ملف مع…',
      two: 'مشاركة $value ملف مع…',
      one: 'مشاركة $value ملف مع…',
      zero: 'مشاركة $value ملف مع…',
    );
    return '$_temp0';
  }

  @override
  String get uiIfMessagesAndFilesFrom3DED27 =>
      'إذا لم تصلك رسائل وملفات هاتف على الشبكة نفسها بينما تصله رسائلك، فإن جدار حماية Windows يحجبها. يتيح هذا للأجهزة الأخرى على أي شبكة الوصول إلى Conest على هذا الحاسوب؛ سيطلب Windows التأكيد.';

  @override
  String get uiServerRefusedSignOut66337B => 'رفض الخادم تسجيل الخروج';

  @override
  String get uiServerNotReached62FED2 => 'تعذّر الوصول للخادم';

  @override
  String uiThisServerDoesNotLet9EEC1F(String value) {
    return 'لا يسمح هذا الخادم لـ Conest بإنهاء جلسته ($value). قد تُدار الجلسات من صفحة الحساب لديه.\n\nهل تسجل الخروج على هذا الجهاز رغم ذلك؟ احذف جلسة Conest لاحقًا من صفحة الحساب أو تطبيق Matrix آخر.';
  }

  @override
  String uiConestCouldNotSignThis3C1074(String value) {
    return 'تعذّر على Conest تسجيل خروج هذا الجهاز من الخادم ($value).\n\nهل تسجل الخروج على هذا الجهاز رغم ذلك؟ تبقى الجلسة صالحة على الخادم حتى تحذفها من تطبيق Matrix آخر.';
  }

  @override
  String get uiEnabledDF174A => 'مفعّل';

  @override
  String get uiYourEncryptedMatrixHistoryIsC16CD2 =>
      'سجل Matrix المشفّر منسوخ احتياطيًا بالفعل. استخدم «إدخال مفتاح الاسترداد» على جهاز جديد.';

  @override
  String get uiThisAccountAlreadyHasA0CF3D8 =>
      'للحساب مفتاح استرداد بالفعل. استخدم «إدخال مفتاح الاسترداد» أو «التحقق بجلسة أخرى» لفتح سجلك المشفّر هنا.';

  @override
  String uiMatrixValueED6C29(String value) {
    return 'Matrix: ‏$value';
  }

  @override
  String uiValueValueB5F18A(String value, String value2) {
    return '$value$value2';
  }

  @override
  String get uiMatrixFallbackAA082C => 'استخدام Matrix عند التعذّر';

  @override
  String get uiMatrixAccountD69140 => 'حساب Matrix';

  @override
  String get uiAccountsThatSignInThrough64868A =>
      'الحسابات التي تدخل عبر Google أو GitHub أو مزوّد آخر أو matrix.org تستخدم المتصفح.';

  @override
  String uiThisAccountIsOnValueB78C80(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'هذا الحساب على $value جهاز.',
      many: 'هذا الحساب على $value جهاز.',
      few: 'هذا الحساب على $value جهاز.',
      two: 'هذا الحساب على $value جهاز.',
      one: 'هذا الحساب على $value جهاز.',
      zero: 'هذا الحساب على $value جهاز.',
    );
    return '$_temp0';
  }

  @override
  String get uiUseConestOnMoreThanD2AA6A =>
      'استخدم Conest على أكثر من جهاز: اربط هاتفًا أو جهازًا لوحيًا أو حاسوبًا بهذا الحساب. تراك جهات الاتصال كشخص واحد.';

  @override
  String get uiThisDeviceWasLinkedLess2E5122 =>
      'رُبط هذا الجهاز منذ أقل من يوم، لذا لا يمكنه إضافة أجهزة أو إزالتها بعد.';

  @override
  String get uiPauseSyncingWithADevice89642E =>
      'إيقاف المزامنة مع جهاز انقطع الاتصال به لمدة';

  @override
  String uiValueDaysEE919A(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value يوم',
      many: '$value يوم',
      few: '$value يوم',
      two: '$value يوم',
      one: '$value يوم',
      zero: '$value يوم',
    );
    return '$_temp0';
  }

  @override
  String get uiChatsFromOtherNetworks13CDCD => 'محادثات من شبكات أخرى';

  @override
  String uiShowValueChatsInTheBC0E41(String value) {
    return 'عرض محادثات $value في قائمة المحادثات';
  }

  @override
  String get uiChatWithDeltaChatUsers3B8607 =>
      'تحدّث مع مستخدمي Delta Chat عبر حساب بريدك. أعِدّ البريد الإلكتروني أعلاه أولًا.';

  @override
  String uiChatWithDeltaChatUsersABD3F5(String value) {
    return 'تحدّث مع مستخدمي Delta Chat باسم $value، فرديًا وفي مجموعات. تشفير بين الطرفين (OpenPGP، دون سرية مستقبلية)؛ ترى خوادم البريد من يكاتب من ومتى.';
  }

  @override
  String get uiNoDeltaChatChatsYetF4C538 =>
      'لا توجد محادثات Delta Chat بعد. شارك دعوتك أو انضم بدعوة شخص آخر.';

  @override
  String uiRequestValueE6C033(String value) {
    return 'طلب: $value';
  }

  @override
  String get uiNobodyToAddYetStart0983BB =>
      'لا يوجد أحد لإضافته بعد: ابدأ محادثة أولًا. يمكنك مشاركة دعوة المجموعة بعد إنشائها.';

  @override
  String get uiVerifiedEC734B => 'تم التحقق';

  @override
  String uiAddValueF546E5(String value) {
    return 'إضافة $value';
  }

  @override
  String get uiChatDeleted73DC61 => 'حُذفت المحادثة';

  @override
  String get uiLeaveGroup925789 => 'مغادرة المجموعة';

  @override
  String get uiWaitingForTheInviteTo1C712D =>
      'في انتظار الرد على الدعوة؛ قد يستغرق ذلك دقيقة.';

  @override
  String get uiEncryptedWithOpenPGPDeltaChat9C6326 =>
      'مشفّر باستخدام OpenPGP ‏(Delta Chat)، دون سرية مستقبلية. ترى خوادم البريد من يكاتب من ومتى.';

  @override
  String get uiARequestFromSomeoneYouAE0967 =>
      'طلب من شخص لم تتحدث معه. الرد يقبل الطلب.';

  @override
  String get uiReadA7AFDD => 'قُرئت';

  @override
  String get uiNotSentBE2B9D => 'لم تُرسل';

  @override
  String get uiCouldNotJoinTheCall252D45 =>
      'تعذّر الانضمام للمكالمة. افحص المسار أو غادر المكالمة الحالية.';

  @override
  String uiCallInValue16F998(String value) {
    return 'مكالمة في $value';
  }

  @override
  String uiValueStartedACallIn278E96(String value, String value2) {
    return 'بدأ $value مكالمة في $value2';
  }

  @override
  String get uiReturn24F096 => 'عودة';

  @override
  String get uiCouldNotUpdateTheCall33517D => 'تعذّر تحديث المكالمة.';

  @override
  String get uiVoiceCallB8499D => 'مكالمة صوتية';

  @override
  String uiCallViaValue0A68E8(String value) {
    return 'مكالمة عبر $value';
  }

  @override
  String uiValueYouEFED9A(String value) {
    return '$value (أنت)';
  }

  @override
  String get uiTalkingC34D84 => 'جارٍ التحدث…';

  @override
  String get uiHoldToTalkSpace869505 => 'اضغط مطولًا للتحدث · المسافة';

  @override
  String uiVoiceCallValueBD3141(String value) {
    return 'مكالمة صوتية · $value';
  }

  @override
  String uiStartedByValueValueParticipants99F03D(String value, int value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value2,
      locale: localeName,
      other: 'بدأها $value · $value2 مشارك',
      many: 'بدأها $value · $value2 مشارك',
      few: 'بدأها $value · $value2 مشارك',
      two: 'بدأها $value · $value2 مشارك',
      one: 'بدأها $value · $value2 مشارك',
      zero: 'بدأها $value · $value2 مشارك',
    );
    return '$_temp0';
  }

  @override
  String get uiNodeRnsd0D8EEC => 'عقدة (rnsd)';

  @override
  String get uiRNodeOnUSBF00220 => 'RNode عبر USB';

  @override
  String get uiRNodeOnBluetooth13657D => 'RNode عبر Bluetooth';

  @override
  String get uiRNodeOnWiFiC18593 => 'RNode عبر Wi-Fi';

  @override
  String get uiScanForRadios2B185E => 'البحث عن أجهزة الراديو';

  @override
  String get uiUseTheSameFrequencyBandwidthFC1A9F =>
      'استخدم التردد وعرض النطاق ومعامل الانتشار نفسها لشبكة Reticulum التي ينضم إليها الراديو.';

  @override
  String get uiAppMode2965FD => 'وضع التطبيق';

  @override
  String get uiBoth1F4698 => 'كلاهما';

  @override
  String uiCouldNotStartTheChatAE2F54(String value) {
    return 'تعذّر بدء المحادثة: $value';
  }

  @override
  String uiMessagesAreEndToEndE786B5(String value) {
    return 'الرسائل مشفّرة بين الطرفين، لكن خادمك وخادم الطرف الآخر يريان من يتحدث مع من ومتى. تحقّق من $value للتأكد من هويته.';
  }

  @override
  String get uiThisChatIsNotEncrypted799D99 =>
      'هذه المحادثة غير مشفّرة: يمكن لخادمك وخادم الطرف الآخر قراءتها.';

  @override
  String get uiLoading33CE41 => 'جارٍ التحميل…';

  @override
  String get uiLoadEarlierMessages4AC08D => 'تحميل رسائل سابقة';

  @override
  String get uiEditing3B9BA1 => 'جارٍ التعديل';

  @override
  String uiReplyToValueValue666B4E(String value, String value2) {
    return 'رد على $value: ‏$value2';
  }

  @override
  String get uiYouWereInvitedToThisE30D1E => 'دُعيت إلى محادثة Matrix هذه.';

  @override
  String get uiEdited0E3C32 => 'معدّل · ';

  @override
  String get uiUnableToDecryptThisMessage8A31CC =>
      'تعذّر فك تشفير هذه الرسالة بعد';

  @override
  String get uiUnsupportedMessage9E48EB => 'رسالة غير مدعومة';

  @override
  String uiImageUnavailableValueB024FC(String value) {
    return 'الصورة غير متاحة: $value';
  }

  @override
  String uiDownloadFailedValueB18BB6(String value) {
    return 'فشل التنزيل: $value';
  }

  @override
  String get uiFile2C3CAF => 'ملف';

  @override
  String uiValueKiBEC48AF(String value) {
    return '$value KiB';
  }

  @override
  String get uiCODEPHRASEE2C724 => 'عبارة الرمز';

  @override
  String uiROTATESINValueS5745B8(String value) {
    return 'تتغيّر خلال $value ث';
  }

  @override
  String get uiROUTEINSPECTOR321AA4 => 'فاحص المسارات';

  @override
  String get uiLIVE67B40B => '● مباشر';

  @override
  String uiValueChatsAD9A3B(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value محادثة',
      many: '$value محادثة',
      few: '$value محادثة',
      two: '$value محادثة',
      one: '$value محادثة',
      zero: '$value محادثة',
    );
    return '$_temp0';
  }

  @override
  String uiValueValue167E51(String value, String value2) {
    return '$value ($value2)';
  }

  @override
  String get uiNotDeliveredTheirRadioCould75D581 =>
      'لم تُسلّم (تعذّرت قراءتها على راديو الطرف الآخر)';

  @override
  String get uiSenderNotVerified2BB0FA => 'المرسِل غير متحقق منه';

  @override
  String get uiYouAreHidden56DCC1 => 'أنت مخفي';

  @override
  String get uiYouReadTheMeshChatAEACC5 =>
      'يمكنك قراءة محادثة الشبكة، لكن مستخدمي bitchat لا يرونك ولا يكتبون إليك. فعّل «إمكانية التواصل عبر bitchat» في الإعدادات ← الاتصال للكتابة.';

  @override
  String get uiEveryoneNearbyOverBluetooth7B8D63 =>
      'كل من بالقرب عبر Bluetooth';

  @override
  String get uiNoBitchatUsersNearbyYetD30471 =>
      'لا يوجد مستخدمو bitchat قريبون بعد';

  @override
  String get uiPhonesInBluetoothRangeThatDCCC0D =>
      'تظهر هنا الأجهزة التي تعلن عن نفسها ضمن نطاق Bluetooth.';

  @override
  String get uiNearbyF1536C => 'بالقرب';

  @override
  String get uiEveryoneInBluetoothRangeReadsA7628A =>
      'يقرأ هذه المحادثة كل من ضمن نطاق Bluetooth ويمكن لأي شخص نقلها. الرسائل موقّعة، لا مشفّرة.';

  @override
  String get uiEncryptedBetweenTheTwoPhones3871C4 =>
      'مشفّر بين الجهازين (Noise في bitchat)، بسرية مستقبلية فقط ما دمتما قريبين.';

  @override
  String get uiThisChatWasWithAn0507F9 =>
      'هذه المحادثة كانت بهوية bitchat سابقة لك. الكتابة الآن تُعلمهم أن هويتك الجديدة للشخص نفسه.';

  @override
  String uiValueValue64C067(String value, String value2) {
    return '$value#$value2';
  }

  @override
  String get uiVerifyThisSessionB5065C => 'التحقق من هذه الجلسة';

  @override
  String get uiBluetoothMeshOn5A96FE => 'شبكة Bluetooth مفعّلة';

  @override
  String get uiStartingBluetoothE6928A => 'جارٍ تشغيل Bluetooth';

  @override
  String get uiBluetoothUnavailableF4B751 => 'Bluetooth غير متاح';

  @override
  String uiBitchatUsersNearbySeeYou1B54FC(String value) {
    return 'يراك مستخدمو bitchat القريبون باسم \"$value\" ما دمت ضمن النطاق، ويمكنهم مراسلتك. تتجدّد الهوية التي يرونها كل أسبوع ولا ترتبط بهويتك في Conest.';
  }

  @override
  String get uiOffBitchatUsersDoNot054F9A =>
      'متوقف: لا يرى مستخدمو bitchat هذا الجهاز. لا يزال بإمكانك قراءة محادثة الشبكة.';

  @override
  String uiPhonesNearbyWithoutInternetCan27CC7F(String value) {
    return 'يمكن للهواتف القريبة دون إنترنت استخدام قنوات الموقع في bitchat عبر هذا الجهاز. تمرّ فقط تلك الرسائل العامة الموقّعة. يتصل هذا الجهاز بمرحّلات المناطق المستخدمة$value: ترى تلك المرحّلات عنوان الإنترنت والمنطقة، ويمكنها معرفة موقعك التقريبي.';
  }

  @override
  String get uiOffBitchatUsersNearbyWithout030CFB =>
      'متوقف: لا يمكن لمستخدمي bitchat القريبين دون إنترنت الوصول إلى قنوات الموقع عبرك.';

  @override
  String uiValueNearbyTheMeshChat31C0CA(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value قريب · محادثة الشبكة والمحادثات الخاصة',
      many: '$value قريب · محادثة الشبكة والمحادثات الخاصة',
      few: '$value قريب · محادثة الشبكة والمحادثات الخاصة',
      two: '$value قريب · محادثة الشبكة والمحادثات الخاصة',
      one: '$value قريب · محادثة الشبكة والمحادثات الخاصة',
      zero: '$value قريب · محادثة الشبكة والمحادثات الخاصة',
    );
    return '$_temp0';
  }

  @override
  String get uiSignInToYourMatrix8D0037 => 'تسجيل الدخول إلى حساب Matrix';

  @override
  String get uiNoRoomsFoundAD2C3E => 'لم يُعثر على غرف';

  @override
  String get uiMatrixInvitation525106 => 'دعوة Matrix';

  @override
  String get uiEncryptedChat0D7563 => 'محادثة مشفّرة';

  @override
  String get uiChat2CED57 => 'محادثة';

  @override
  String get uiNoNostrChatsYet0A95D0 => 'لا توجد محادثات Nostr بعد';

  @override
  String get uiEncryptedOnNostrNIPRelaysA51F70 =>
      'مشفّر في Nostr ‏(NIP-17)؛ لا ترى المرحّلات من كتب أو متى. دون سرية مستقبلية.';

  @override
  String get uiTestingRoutes19C586 => 'جارٍ اختبار المسارات…';

  @override
  String get uiTestRoutes52770A => 'اختبار المسارات';

  @override
  String get uiCheckingWhetherTheirAppCan51E401 =>
      'جارٍ التحقق من دعم تطبيقه لاختبارات المسارات…';

  @override
  String get uiTheirAppDidNotSay758036 =>
      'لم يعلن تطبيقه عن دعم اختبارات المسارات. إن كان يستخدم هذا الإصدار أيضًا فقد يكون غير متاح الآن.';

  @override
  String get uiNoRouteTookTheTestF2F6CB => 'لم يقبل أي مسار الاختبار.';

  @override
  String uiTestedValueRoutesThatAnswer70B842(String value) {
    return 'تم اختبار $value. تُفضّل المسارات التي تجيب للرسائل.';
  }

  @override
  String get uiUSB09716C => 'USB';

  @override
  String get uiCopiedTheErrorHistoryCE02E2 => 'تم نسخ سجل الأخطاء.';

  @override
  String get uiNothingRecordedA27006 => 'لا يوجد سجل.';

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
    return 'المسار: $value';
  }

  @override
  String uiValueValue7B4608(String value, String value2) {
    return '$value · !$value2';
  }

  @override
  String get uiNetwork53EBC5 => 'الشبكة';

  @override
  String uiImageIsLargerThanTheEE56C5(String value) {
    return 'الصورة أكبر من الحد $value MB.';
  }

  @override
  String uiFileIsLargerThanTheAF488F(String value) {
    return 'الملف أكبر من الحد $value MB.';
  }

  @override
  String uiSendValueBF4C3C(String value) {
    return 'إرسال $value';
  }

  @override
  String get uiRecent76EEC7 => 'حديث';

  @override
  String get uiConestSeesOnlyThePhotosEE1926 =>
      'يرى Conest الصور التي اخترتها فقط.';

  @override
  String get uiPhotosPermissionDeniedUseBrowseD672EE =>
      'رُفض إذن الصور. استخدم «تصفح الملفات…» لإرسال أي ملف، أو امنح الوصول من إعدادات النظام.';

  @override
  String get uiNoPhotosOrVideosHereC729D1 => 'لا توجد صور أو فيديوهات هنا.';

  @override
  String get uiCouldNotDecodeTheImage69AC9D =>
      'تعذّر فك ترميز الصورة لتدويرها.';

  @override
  String uiRotationFailedValue176CC6(String value) {
    return 'فشل التدوير: $value';
  }

  @override
  String uiValueOfValueVerified63B11D(String value, String value2) {
    return 'تم التحقق من $value من أصل $value2';
  }

  @override
  String get uiPointTheCameraAtA9BAFAF =>
      'وجّه الكاميرا إلى رمز QR لدعوة Conest.';

  @override
  String get statusMatrixRoomsShowJoinsAndE8AC9E =>
      'تعرض غرف Matrix الانضمام والمغادرة.';

  @override
  String get statusMatrixRoomsHideJoinsAndE00610 =>
      'تخفي غرف Matrix الانضمام والمغادرة.';

  @override
  String statusAppMode95B48F(String value) {
    return 'وضع التطبيق: $value.';
  }

  @override
  String statusCalling7A8C67(String value) {
    return 'جارٍ الاتصال بـ $value…';
  }

  @override
  String get statusUpdatedHistoryVisibilityForFutureDA1A23 =>
      'تم تحديث ظهور السجل لأعضاء المجموعة المستقبليين.';

  @override
  String statusVaultUnlockFailedAE7813(String value) {
    return 'فشل فتح الخزنة: $value';
  }

  @override
  String get statusDirectOnlineTransportIsUnavailableB1EFAE =>
      'النقل المباشر عبر الإنترنت غير متاح؛ يبقى مسار المرحّل البديل نشطًا.';

  @override
  String get statusNostrCarrierSetUpE82998 => 'تم إعداد ناقل Nostr.';

  @override
  String get statusNostrCarrierRemovedCB968A => 'تمت إزالة ناقل Nostr.';

  @override
  String get statusNostrRelaysUpdatedARelay03F8F3 =>
      'تم تحديث مرحّلات Nostr: توقف مرحّل.';

  @override
  String get statusTorCarrierSetUp3D2304 => 'تم إعداد ناقل Tor.';

  @override
  String get statusTorCarrierRemovedAAC23E => 'تمت إزالة ناقل Tor.';

  @override
  String get statusBluetoothMeshOn11FD21 => 'شبكة Bluetooth مفعّلة.';

  @override
  String get statusBluetoothMeshOff2CE954 => 'شبكة Bluetooth متوقفة.';

  @override
  String get statusNostrMessagesOn35ABF5 => 'رسائل Nostr مفعّلة.';

  @override
  String get statusNostrMessagesOff16BCA7 => 'رسائل Nostr متوقفة.';

  @override
  String get statusDeltaChatOn1F38AA => 'Delta Chat مفعّل.';

  @override
  String get statusDeltaChatOff8BDBD4 => 'Delta Chat متوقف.';

  @override
  String statusBitchatUsersNearbyCanNow5536CD(String value) {
    return 'يراك مستخدمو bitchat القريبون الآن باسم $value.';
  }

  @override
  String get statusBitchatUsersNoLongerSee68B46D =>
      'لم يعد مستخدمو bitchat يرونك.';

  @override
  String statusMeshcoreCarrierSetUpThroughE51369(String value) {
    return 'تم إعداد ناقل MeshCore عبر $value.';
  }

  @override
  String get statusMeshcoreCarrierRemoved38FC35 => 'تمت إزالة ناقل MeshCore.';

  @override
  String statusMeshtasticCarrierSetUpThroughAFA24A(String value) {
    return 'تم إعداد ناقل Meshtastic عبر $value.';
  }

  @override
  String get statusMeshtasticCarrierRemoved66387E =>
      'تمت إزالة ناقل Meshtastic.';

  @override
  String get statusMeshtasticAppMessagesOn2C1888 =>
      'رسائل تطبيق Meshtastic مفعّلة.';

  @override
  String get statusMeshtasticAppMessagesOffAFB9E8 =>
      'رسائل تطبيق Meshtastic متوقفة.';

  @override
  String get statusMeshcoreAppMessagesOn2BF1E3 =>
      'رسائل تطبيق MeshCore مفعّلة.';

  @override
  String get statusMeshcoreAppMessagesOffE59C90 =>
      'رسائل تطبيق MeshCore متوقفة.';

  @override
  String statusReticulumCarrierSetUpThrough7EB41E(String value) {
    return 'تم إعداد ناقل Reticulum عبر $value.';
  }

  @override
  String get statusReticulumCarrierRemoved301C05 => 'تمت إزالة ناقل Reticulum.';

  @override
  String statusEmailCarrierSetUpAs8427FD(String value) {
    return 'تم إعداد ناقل البريد باسم $value.';
  }

  @override
  String get statusEmailCarrierRemoved036E51 => 'تمت إزالة ناقل البريد.';

  @override
  String statusImportedRelaySFromB1DB2D(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'تم استيراد $value مرحّل من $value2.',
      many: 'تم استيراد $value مرحّل من $value2.',
      few: 'تم استيراد $value مرحّل من $value2.',
      two: 'تم استيراد $value مرحّل من $value2.',
      one: 'تم استيراد $value مرحّل من $value2.',
      zero: 'تم استيراد $value مرحّل من $value2.',
    );
    return '$_temp0';
  }

  @override
  String statusRemovedImportedRelaySource3F4540(String value) {
    return 'تمت إزالة مصدر المرحّلات المستورد $value.';
  }

  @override
  String get statusPairingCodeRotatedAndAdvertised722FB9 =>
      'تم تغيير رمز الاقتران والإعلان عنه.';

  @override
  String statusCheckedRouteSAvailableE9B9D6(
    int value,
    int value2,
    String value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'تم فحص $value مسار؛ $value2 متاح. $value3',
      many: 'تم فحص $value مسار؛ $value2 متاح. $value3',
      few: 'تم فحص $value مسار؛ $value2 متاح. $value3',
      two: 'تم فحص $value مسار؛ $value2 متاح. $value3',
      one: 'تم فحص $value مسار؛ $value2 متاح. $value3',
      zero: 'تم فحص $value مسار؛ $value2 متاح. $value3',
    );
    return '$_temp0';
  }

  @override
  String statusCheckedIrohPathSFor038B43(
    String value,
    String value2,
    String value3,
  ) {
    return 'تم فحص مسارات Iroh لـ $value؛ حالة الوصول $value2. $value3';
  }

  @override
  String statusNoPathsAreAdvertisedForA37EA3(String value) {
    return 'لا توجد مسارات معلنة لـ $value.';
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
          'تم فحص $value مسار لـ $value2؛ $value3 متاح$value4. حالة الوصول $value5. $value6',
      many:
          'تم فحص $value مسار لـ $value2؛ $value3 متاح$value4. حالة الوصول $value5. $value6',
      few:
          'تم فحص $value مسار لـ $value2؛ $value3 متاح$value4. حالة الوصول $value5. $value6',
      two:
          'تم فحص $value مسار لـ $value2؛ $value3 متاح$value4. حالة الوصول $value5. $value6',
      one:
          'تم فحص $value مسار لـ $value2؛ $value3 متاح$value4. حالة الوصول $value5. $value6',
      zero:
          'تم فحص $value مسار لـ $value2؛ $value3 متاح$value4. حالة الوصول $value5. $value6',
    );
    return '$_temp0';
  }

  @override
  String get statusDisplayNameUpdated3BD31A => 'تم تحديث اسم العرض.';

  @override
  String get statusBioCleared543896 => 'تم مسح النبذة.';

  @override
  String get statusBioUpdated440110 => 'تم تحديث النبذة.';

  @override
  String get statusContactProfileUpdated47ECF6 => 'تم تحديث ملف جهة الاتصال.';

  @override
  String get statusRelayModeEnabledB9ACB8 => 'وضع المرحّل مفعّل.';

  @override
  String get statusRelayModeDisabled723F4D => 'وضع المرحّل متوقف.';

  @override
  String get statusContactsCanNowContributeRelay147ECE =>
      'يمكن لجهات الاتصال الآن توفير مسارات مرحّلات تلقائيًا.';

  @override
  String get statusAutomaticContactRelayUsageDisabledE762A7 =>
      'أُلغي الاستخدام التلقائي لمرحّلات جهات الاتصال.';

  @override
  String get statusNotificationsEnabledF70668 => 'الإشعارات مفعّلة.';

  @override
  String get statusNotificationsDisabledForThisDeviceE10A46 =>
      'الإشعارات متوقفة على هذا الجهاز.';

  @override
  String get statusExperimentalVoiceCallsEnabledOn4081DE =>
      'المكالمات الصوتية التجريبية مفعّلة على هذا الجهاز.';

  @override
  String get statusExperimentalVoiceCallsDisabledOn19A5AE =>
      'المكالمات الصوتية التجريبية متوقفة على هذا الجهاز.';

  @override
  String get statusAndroidBackgroundRuntimeEnabledIfAA5168 =>
      'تشغيل Android في الخلفية مفعّل. إذا حظر النظام وصول البطارية أو الخلفية، فقد تتأخر الإشعارات أو لا تصل.';

  @override
  String get statusAndroidBackgroundRuntimeDisabled5FC9A0 =>
      'تشغيل Android في الخلفية متوقف.';

  @override
  String get statusBackgroundVoiceCallAvailabilityEnabledA87223 =>
      'إتاحة المكالمات الصوتية بالخلفية مفعّلة لهذا الجهاز. تصل المكالمات فقط ما دامت خدمة Conest مسموحة بالعمل.';

  @override
  String get statusBackgroundVoiceCallAvailabilityDisabledA71AD1 =>
      'إتاحة المكالمات الصوتية بالخلفية متوقفة.';

  @override
  String get statusFreeSpaceReserveEnabledD7CE0E =>
      'حجز 10% من المساحة الفارغة مفعّل.';

  @override
  String get statusFreeSpaceReserveDisabledD3E635 =>
      'حجز 10% من المساحة الفارغة متوقف.';

  @override
  String statusRoutingPreferencesUpdatedFor05867B(String value) {
    return 'تم تحديث تفضيلات التوجيه لـ $value.';
  }

  @override
  String statusLocalRelayPortUpdatedTo7F815D(String value) {
    return 'تم تحديث منفذ المرحّل المحلي إلى $value.';
  }

  @override
  String statusRelayAdded800692(String value) {
    return 'أُضيف المرحّل $value.';
  }

  @override
  String statusRelayAddedFor087398(String value, String value2, String value3) {
    return 'أُضيف المرحّل $value:$value2 لـ $value3.';
  }

  @override
  String statusRelayRemoved546A15(String value) {
    return 'أُزيل المرحّل $value.';
  }

  @override
  String statusTrustedNewIdentityForRelay4CDBFE(String value) {
    return 'تم الوثوق بالهوية الجديدة للمرحّل $value.';
  }

  @override
  String get statusContactRemovedE31CE0 => 'أُزيلت جهة الاتصال.';

  @override
  String get statusContactRemovedLocallySendingA40D607 =>
      'أُزيلت جهة الاتصال محليًا. يُرسل إشعار الإزالة في الخلفية.';

  @override
  String get statusDeviceCreatedShareAQr06E7B6 =>
      'أُنشئ الجهاز. شارك دعوة QR أو عبارة الرمز الحالية لإضافة جهة الاتصال.';

  @override
  String statusContactAcceptedSendingApprovalOverDAD10C(String value) {
    return 'قُبلت جهة الاتصال $value. تُرسل الموافقة عبر المسارات المتاحة.';
  }

  @override
  String statusContactSavedWaitingForThe41F77D(String value) {
    return 'حُفظت جهة الاتصال $value. في انتظار موافقة الطرف الآخر.';
  }

  @override
  String statusReconnectedWithBC62EC(String value) {
    return 'أُعيد الاتصال بـ $value.';
  }

  @override
  String statusAskingToReconnectE93389(String value) {
    return 'نطلب من $value إعادة الاتصال.';
  }

  @override
  String statusConfirmedIdentityReplacementForC93359(String value) {
    return 'تم تأكيد استبدال هوية $value.';
  }

  @override
  String statusRejectedIdentityReplacementForDEC894(String value) {
    return 'رُفض استبدال هوية $value.';
  }

  @override
  String get statusContactRequestCancelledQueuedItemsEC2567 =>
      'أُلغي طلب التواصل. تبقى العناصر المنتظرة محظورة.';

  @override
  String get statusSaved9D4AF6 => 'تم الحفظ.';

  @override
  String statusMessageSavedLocallyItWill0DBD03(String value) {
    return 'حُفظت الرسالة محليًا. ستُرسل بعد قبول $value لطلب التواصل.';
  }

  @override
  String statusTryingLanFirstThenRelay1F5BEC(String value) {
    return 'تجربة الشبكة المحلية أولًا ثم المرحّل لـ $value.';
  }

  @override
  String get statusMessageQueuedTheAppWillA89BCC =>
      'الرسالة في الانتظار. سيعيد التطبيق تجربة المسارات المباشرة والمرحّلات أثناء الاستطلاع.';

  @override
  String statusAttachmentIsWaitingForA3F032B(String value) {
    return 'المرفق ينتظر مسارًا: $value';
  }

  @override
  String statusCouldNotPrepareForDownloadE8FB18(String value) {
    return 'تعذّر تجهيز $value للتنزيل.';
  }

  @override
  String statusCreatedGroupF5D335(String value) {
    return 'أُنشئت المجموعة $value.';
  }

  @override
  String statusUpdatedGroup2140B7(String value) {
    return 'حُدّثت المجموعة $value.';
  }

  @override
  String statusRemovedAMemberFrom68CF04(String value) {
    return 'أُزيل عضو من $value.';
  }

  @override
  String statusLeftGroup9E3412(String value) {
    return 'غادرت المجموعة $value.';
  }

  @override
  String statusRemovedGroupFromYourList047F4B(String value) {
    return 'أُزيلت المجموعة $value من قائمتك.';
  }

  @override
  String statusTransferredOwnershipOfToA126A1(String value, String value2) {
    return 'نُقلت ملكية $value إلى $value2.';
  }

  @override
  String statusDeletedGroupForEveryoneDB26F8(String value) {
    return 'حُذفت المجموعة $value للجميع.';
  }

  @override
  String statusUpdatedIn642C0A(String value, String value2) {
    return 'حُدّث $value في $value2.';
  }

  @override
  String statusSendingGroupMessageToD77236(String value) {
    return 'جارٍ إرسال رسالة المجموعة إلى $value.';
  }

  @override
  String statusSentToAsAPlainAF2DE6(String value) {
    return 'أُرسلت إلى $value كرسالة Matrix عادية.';
  }

  @override
  String statusCanceledAndDeletedPendingMessageCDCA88(String value) {
    return 'أُلغيت وحُذفت الرسالة المعلّقة إلى $value.';
  }

  @override
  String get statusMessageDeletedLocallyCE90EE => 'حُذفت الرسالة محليًا.';

  @override
  String statusMessageDeletedHereAndDeletion7C4E80(String value) {
    return 'حُذفت الرسالة هنا وأُرسل طلب حذفها إلى $value.';
  }

  @override
  String get statusMessageDeletedHereRemoteDeletionB6AE62 =>
      'حُذفت الرسالة هنا. لم يُرسل طلب الحذف البعيد بعد.';

  @override
  String get statusMessageEditedLocally187334 => 'عُدّلت الرسالة محليًا.';

  @override
  String statusMessageEditQueuedTo695B15(String value) {
    return 'تعديل الرسالة في انتظار الإرسال إلى $value.';
  }

  @override
  String get statusReactionUpdatedLocally97D795 => 'حُدّث التفاعل محليًا.';

  @override
  String statusReactionQueuedToD43BED(String value) {
    return 'التفاعل في انتظار الإرسال إلى $value.';
  }

  @override
  String get statusLanLobbyMessageSavedLocallyFDE86E =>
      'حُفظت رسالة دردشة الشبكة محليًا؛ لم يمكن الوصول لمشاركين قريبين.';

  @override
  String statusLanLobbyMessageSentTo82F0B0(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'أُرسلت رسالة الدردشة المحلية عبر $value مسار قريب.',
      many: 'أُرسلت رسالة الدردشة المحلية عبر $value مسار قريب.',
      few: 'أُرسلت رسالة الدردشة المحلية عبر $value مسار قريب.',
      two: 'أُرسلت رسالة الدردشة المحلية عبر $value مسار قريب.',
      one: 'أُرسلت رسالة الدردشة المحلية عبر $value مسار قريب.',
      zero: 'أُرسلت رسالة الدردشة المحلية عبر $value مسار قريب.',
    );
    return '$_temp0';
  }

  @override
  String statusGroupMembershipAckFrom43FCF1(String value, String value2) {
    return 'تأكيد عضوية المجموعة $value من $value2.';
  }

  @override
  String statusReceivedItemSVia58B082(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'استُلم $value عنصر عبر $value2.',
      many: 'استُلم $value عنصر عبر $value2.',
      few: 'استُلم $value عنصر عبر $value2.',
      two: 'استُلم $value عنصر عبر $value2.',
      one: 'استُلم $value عنصر عبر $value2.',
      zero: 'استُلم $value عنصر عبر $value2.',
    );
    return '$_temp0';
  }

  @override
  String statusRoutePollFailedA1FD0C(String value) {
    return 'فشل استطلاع المسارات: $value';
  }

  @override
  String statusLanReceivingIsOffPort5F04CB(String value) {
    return 'الاستقبال المحلي متوقف: المنفذ $value مستخدم. اختر منفذ مرحّل محلي آخر في الإعدادات.';
  }

  @override
  String statusRediscoveredLanRouteFor587829(String value, String value2) {
    return 'أُعيد اكتشاف المسار المحلي $value لـ $value2.';
  }

  @override
  String statusLanDiscoveryUnavailable0E99AE(String value) {
    return 'اكتشاف الشبكة المحلية غير متاح: $value';
  }

  @override
  String get statusUpdatedNearbyLanRoutesF8CAFC =>
      'حُدّثت المسارات المحلية القريبة.';

  @override
  String statusRejectedMalformedAttachmentOfferFrom9FC96A(String value) {
    return 'رُفض عرض مرفق غير صالح من $value.';
  }

  @override
  String get statusRejectedInvalidAttachmentMetadata849465 =>
      'رُفضت بيانات وصفية غير صالحة للمرفق.';

  @override
  String statusDeclinedTheRequestQueuedMessagesABFFCB(String value) {
    return 'رفض $value الطلب. تبقى الرسائل والملفات المنتظرة محظورة.';
  }

  @override
  String statusNewContactRequestFromCF70B9(String value) {
    return 'طلب تواصل جديد من $value.';
  }

  @override
  String statusLeftF4FE32(String value, String value2) {
    return 'غادر $value المجموعة $value2.';
  }

  @override
  String statusRemovedYouTheConversationRemains3BB516(String value) {
    return 'أزالك $value. تبقى المحادثة مؤرشفة محليًا.';
  }

  @override
  String statusUpdatedEditedMessageFrom1AB90D(String value) {
    return 'حُدّثت رسالة معدّلة من $value.';
  }

  @override
  String statusDeletedMessageRemovedBy5A9E79(String value) {
    return 'أُزيلت رسالة حذفها $value.';
  }

  @override
  String statusAppliedAReactionFrom41011B(String value) {
    return 'طُبّق تفاعل من $value.';
  }

  @override
  String get statusAppliedDeferredDirectReactions1414C8 =>
      'طُبّقت التفاعلات الخاصة المؤجّلة.';

  @override
  String statusEncryptedMessageStoredForVia029324(String value, String value2) {
    return 'حُفظت رسالة مشفّرة لـ $value عبر $value2.';
  }

  @override
  String statusSentToViaWaitingForEA766D(String value, String value2) {
    return 'أُرسلت إلى $value عبر $value2؛ في انتظار تأكيد التسليم.';
  }

  @override
  String statusDeliveryRetryPending93EAA3(String value) {
    return 'إعادة محاولة التسليم معلّقة: $value';
  }

  @override
  String statusGroupDeliveryRetryPending691CA4(String value) {
    return 'إعادة محاولة تسليم المجموعة معلّقة: $value';
  }

  @override
  String statusRelayIdentityChangedVerifyWith6F3689(String value) {
    return 'تغيّرت هوية المرحّل $value؛ تحقّق مع المشغّل.';
  }

  @override
  String statusRelayIdentityMismatchVerifyWith2D3B10(
    String value,
    String value2,
  ) {
    return 'هوية المرحّل $value:$value2 غير مطابقة؛ تحقّق مع المشغّل.';
  }

  @override
  String get statusTheMatrixSignInExpired76ABA4 =>
      'انتهت جلسة Matrix. سجّل الدخول مجددًا لاستخدامه.';

  @override
  String statusSignedInToMatrixAs5103D2(String value) {
    return 'تم تسجيل الدخول إلى Matrix باسم $value.';
  }

  @override
  String get statusSignedOutOfMatrix1D1860 => 'تم تسجيل الخروج من Matrix.';

  @override
  String statusSOtherDevicesHaveNot07F30F(String value, String value2) {
    return 'لم تسمع أجهزة $value الأخرى من $value2 منذ فترة: قد لا تكون رسائله من صاحب الحساب.';
  }

  @override
  String statusReceivedItemSInstantlyViaA7773B(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'استُلم $value عنصر فورًا عبر المرحّل المحلي.',
      many: 'استُلم $value عنصر فورًا عبر المرحّل المحلي.',
      few: 'استُلم $value عنصر فورًا عبر المرحّل المحلي.',
      two: 'استُلم $value عنصر فورًا عبر المرحّل المحلي.',
      one: 'استُلم $value عنصر فورًا عبر المرحّل المحلي.',
      zero: 'استُلم $value عنصر فورًا عبر المرحّل المحلي.',
    );
    return '$_temp0';
  }

  @override
  String statusReceivedItemSViaLocal71A104(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'استُلم $value عنصر عبر الوارد المحلي.',
      many: 'استُلم $value عنصر عبر الوارد المحلي.',
      few: 'استُلم $value عنصر عبر الوارد المحلي.',
      two: 'استُلم $value عنصر عبر الوارد المحلي.',
      one: 'استُلم $value عنصر عبر الوارد المحلي.',
      zero: 'استُلم $value عنصر عبر الوارد المحلي.',
    );
    return '$_temp0';
  }

  @override
  String get statusNoNewProtocols => 'لم تُكتشف بروتوكولات مرحّلات جديدة.';

  @override
  String get statusRouteExchangeRequested => 'طُلب تبادل معلومات المسارات.';

  @override
  String get statusRouteExchangePending =>
      'لم يُرسل تبادل معلومات المسارات بعد.';

  @override
  String get statusKnownRoutes => 'مسارات معروفة';

  @override
  String get statusReachable => 'يمكن الوصول';

  @override
  String get statusUnreachable => 'غير قابل للوصول';

  @override
  String get statusUnknown => 'غير معروف';

  @override
  String get statusExpired => 'قديم';

  @override
  String get connectionsTitle => 'الاتصالات';

  @override
  String get connectionsDescription =>
      'الأجهزة التي تصل إلى غيرها، بالاتجاهين أو باتجاه واحد.';

  @override
  String get relayUdpHint => 'يفرض udp://host:port استخدام UDP';

  @override
  String get deltaFileActions => 'إجراءات الملف';

  @override
  String get deltaForward => 'إعادة توجيه';

  @override
  String get deltaAttach => 'إرفاق';

  @override
  String get deltaSendVoice => 'إرسال رسالة صوتية';

  @override
  String get deltaDiscardVoice => 'تجاهل الرسالة الصوتية';

  @override
  String get deltaRecordVoice => 'تسجيل رسالة صوتية';

  @override
  String get deltaReact => 'تفاعل';

  @override
  String get savedMessagesPreview => 'ملاحظات وملفات ورسائل معاد توجيهها لنفسك';

  @override
  String networkChatsTitle(String network) {
    return 'محادثات $network';
  }

  @override
  String get networkEncryptedMatrixChat => 'محادثة Matrix مشفّرة';

  @override
  String get networkMatrixChat => 'محادثة Matrix';

  @override
  String get networkEveryoneBluetooth => 'كل من ضمن نطاق Bluetooth';

  @override
  String get inviteNoRoutes => 'لا توجد مسارات معلنة';

  @override
  String get deliveryPending => 'في انتظار مسار متاح';

  @override
  String get deliveryLocal => 'أُرسلت محليًا؛ في انتظار تأكيد التسليم';

  @override
  String get deliveryRelayed => 'في انتظار المرحّل؛ في انتظار تأكيد التسليم';

  @override
  String get deliveryDelivered => 'سُلّمت';

  @override
  String get deliveryRead => 'قُرئت';

  @override
  String get reachabilityOnline => 'متصل';

  @override
  String get reachabilityRecent => 'ظهر مؤخرًا';

  @override
  String get reachabilityKnown => 'معروف';

  @override
  String get transferApproval => 'في انتظار الموافقة';

  @override
  String get transferPeer => 'في انتظار الطرف الآخر';

  @override
  String get routeLanDirect => 'مباشر عبر الشبكة المحلية';

  @override
  String get routeInternetDirect => 'مباشر عبر الإنترنت';

  @override
  String get routeIrohDirect => 'Iroh مباشر';

  @override
  String get routeConestRelay => 'مرحّل Conest';

  @override
  String get routeOptical => 'بصري';

  @override
  String get routeViaContact => 'عبر جهة اتصال';

  @override
  String get themeSystem => 'النظام';

  @override
  String get themeLight => 'Signature · فاتح';

  @override
  String get themeDark => 'Signature · داكن';

  @override
  String get themeBlack => 'Signature · أسود (OLED)';

  @override
  String get themeAdaptive => 'متكيّف (الخلفية)';

  @override
  String get layoutSignalCards => 'بطاقات الإشارة';

  @override
  String get layoutStationFeed => 'سجل المحطة';

  @override
  String get layoutClassic => 'صفوف تقليدية';

  @override
  String get layoutSignalDescription => 'الأجهزة كبطاقات اتصال في لوحة.';

  @override
  String get layoutFeedDescription => 'سجل زمني للحزم والنشاط.';

  @override
  String get layoutClassicDescription => 'قائمة مضغوطة بسطر واحد.';

  @override
  String get shellSignatureDescription => 'الشريط الجانبي الأصلي للوحة Conest.';

  @override
  String get shellGarrisonDescription =>
      'على نمط Discord: شريط خلايا ومحادثات.';

  @override
  String get shellCourierDescription =>
      'على نمط Telegram: قائمة محادثات بسيطة.';

  @override
  String get connectionsBothWays => 'بالاتجاهين';

  @override
  String get connectionsInbound => 'من جهتهم فقط';

  @override
  String get connectionsFailing => 'يتعذّر';

  @override
  String get connectionsUnknown => 'لا أخبار حديثة';

  @override
  String voiceConnected(String time) {
    return 'متصل · $time';
  }

  @override
  String messageClockAhead(String amount) {
    return 'ساعتهم متقدمة بنحو $amount؛ الأوقات هنا حسب هذا الجهاز.';
  }

  @override
  String messageClockBehind(String amount) {
    return 'ساعتهم متأخرة بنحو $amount؛ الأوقات هنا حسب هذا الجهاز.';
  }

  @override
  String messageNotRecentlyConfirmed(String date) {
    return 'لم يُؤكد مؤخرًا: آخر مرة اعتبرته أجهزتهم الأخرى ملكًا لهم كانت في $date.';
  }

  @override
  String get routeLanDirectDescription =>
      'مباشرة إلى الجهاز الآخر على شبكتك المحلية.';

  @override
  String get routeLanRelayDescription =>
      'عبر عقدة ترحيل لجهاز آخر على شبكتك المحلية.';

  @override
  String get routeLanLobbyDescription =>
      'صندوق البريد المشترك لردهة الشبكة المحلية؛ يستطيع أي شخص على الشبكة قراءته.';

  @override
  String get routeInternetDirectDescription =>
      'مباشرة إلى عقدة الترحيل للجهاز الآخر عبر الإنترنت.';

  @override
  String get routeIrohDirectDescription =>
      'اتصال مباشر بين الطرفين عبر Iroh، مع تشفير من طرف إلى طرف.';

  @override
  String get routeIrohRelayDescription =>
      'عبر خادم ترحيل Iroh، الذي لا يرى إلا حركة بيانات مشفرة.';

  @override
  String get routeConestRelayDescription =>
      'يخزنها خادم ترحيل Conest ويمررها، ولا يرى إلا مظاريف مشفرة.';

  @override
  String get routeMatrixDescription =>
      'تُنقل عبر Matrix وتبقى مشفرة من طرف إلى طرف بواسطة Conest؛ يرى الخادم المنزلي من يتواصل ومتى.';

  @override
  String get routePlainMatrixDescription =>
      'تُرسل كرسالة Matrix عادية؛ يستطيع الخادم المنزلي قراءتها ما لم تكن الغرفة مشفرة.';

  @override
  String get routeNostrDescription =>
      'تُنقل عبر مرحّلات Nostr وتبقى مشفرة من طرف إلى طرف بواسطة Conest؛ ترى المرحّلات المستلم والتوقيت ولا ترى المرسل.';

  @override
  String get routeEmailDescription =>
      'تُنقل بالبريد الإلكتروني وتبقى مشفرة من طرف إلى طرف بواسطة Conest؛ ترى خوادم البريد العنوانين والتوقيت.';

  @override
  String get routeReticulumDescription =>
      'عبر Reticulum باستخدام الراديو أو شبكة Reticulum، مع تشفير من طرف إلى طرف.';

  @override
  String get routeMeshtasticDescription =>
      'عبر شبكة راديوية متداخلة من Meshtastic، مع تشفير من طرف إلى طرف.';

  @override
  String get routeMeshCoreDescription =>
      'عبر شبكة راديوية متداخلة من MeshCore، مع تشفير من طرف إلى طرف.';

  @override
  String get routeBluetoothDescription =>
      'عبر شبكة Bluetooth المتداخلة مرورًا بالأجهزة القريبة، مع تشفير من طرف إلى طرف.';

  @override
  String get routeTorDescription =>
      'بين خدمات onion عبر Tor؛ لا يرى أحد على المسار من يتواصل مع من.';

  @override
  String get routeContactDescription =>
      'تمررها جهة اتصال تستطيع الوصول إلى الجهاز الآخر؛ تبقى مشفرة من طرف إلى طرف، ولا ترى جهة الاتصال إلا المستلم والتوقيت.';

  @override
  String routeTestRoundTrip(String route, String ms) {
    return '$route: $ms مللي ثانية ذهابًا وإيابًا';
  }

  @override
  String routeTestStored(String route) {
    return '$route: تُركت على المرحّل (يأتي الرد عند جلبها)';
  }

  @override
  String routeTestNoAnswer(String route) {
    return '$route: لا رد';
  }

  @override
  String transferTimeLeft(String time) {
    return 'متبقي $time';
  }

  @override
  String transferQueuePosition(String position) {
    return 'الطابور #$position';
  }

  @override
  String get transferTapRetry => 'اضغط لإعادة المحاولة';

  @override
  String get transferRerouting => 'تغيير المسار';

  @override
  String get routeShortLobby => 'الردهة';

  @override
  String get routeShortDirect => 'مباشر';

  @override
  String get routeShortRelay => 'مرحّل';

  @override
  String get routeShortContact => 'عبر جهة اتصال';

  @override
  String chatDraftPreview(String text) {
    return 'مسودة: $text';
  }

  @override
  String get routeAutomaticFallback => 'تبديل تلقائي ✓';

  @override
  String get releaseNightly => 'ليلي';

  @override
  String get releaseStable => 'مستقر';

  @override
  String get callActive => 'مكالمة جارية';

  @override
  String get callGeneric => 'مكالمة';

  @override
  String get contactNotPinned => 'غير مثبت';

  @override
  String get groupUnknownMember => 'أحد الأعضاء';

  @override
  String get relaySourceSigned => 'موقّع';

  @override
  String get relaySourceUnsigned => 'غير موقّع';

  @override
  String get beamFingerprintUnavailable => 'البصمة غير متاحة';

  @override
  String get fileOriginalMetadataWarning =>
      'ستُرسل معه معلومات الموقع والكاميرا والمؤلف والتاريخ.';

  @override
  String get routeMarkSent => 'أُرسلت';

  @override
  String get routeMarkStored => 'في انتظار المرحّل';

  @override
  String get routeMarkReached => 'وصلت إلى جهازه';

  @override
  String get routeMarkDelivered => 'سُلّمت';

  @override
  String get routeMarkReceived => 'استُلمت';

  @override
  String get relayHostOrLinkLabel => 'مضيف المرحّل أو عنوانه أو رابطه';

  @override
  String get relayLinkHint => 'conest-relay://… من مثبّته';

  @override
  String get brokenPartNotice => 'حدث خطأ هنا.';

  @override
  String get crashNoticeBody =>
      'أُغلق Conest بشكل غير متوقع في المرة السابقة. تبقى التفاصيل على هذا الجهاز؛ يمكنك نسخها إلى تقرير خطأ.';

  @override
  String get crashNoticeDetails => 'التفاصيل';

  @override
  String get crashNoticeDismiss => 'تجاهل';

  @override
  String get crashReportTitle => 'ما الذي حدث';

  @override
  String get crashReportCopy => 'نسخ';

  @override
  String get crashReportClose => 'إغلاق';

  @override
  String get connectionsNetworks => 'الشبكات التي اتصل بها هذا الجهاز';

  @override
  String get connectionsNetworkNow => 'قيد الاستخدام الآن';

  @override
  String connectionsNetworkLastSeen(String date) {
    return 'آخر ظهور $date';
  }

  @override
  String get connectionsRouteWorks => 'يعمل';

  @override
  String get connectionsRouteBlocked => 'محجوب على هذه الشبكة';

  @override
  String get connectionsRouteFailing => 'يفشل';

  @override
  String connectionsAsOf(String when) {
    return 'حتى $when';
  }

  @override
  String get bluetoothMeshNeedsAttention => 'شبكة البلوتوث تحتاج إلى انتباه';

  @override
  String forwardSelectedTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'إعادة توجيه $count رسالة',
      many: 'إعادة توجيه $count رسالة',
      few: 'إعادة توجيه $count رسائل',
      two: 'إعادة توجيه رسالتين',
      one: 'إعادة توجيه رسالة واحدة',
      zero: 'إعادة توجيه $count رسالة',
    );
    return '$_temp0';
  }

  @override
  String forwardedSummary(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'وُجِّهت $count رسالة',
      many: 'وُجِّهت $count رسالة',
      few: 'وُجِّهت $count رسائل',
      two: 'وُجِّهت رسالتان',
      one: 'وُجِّهت رسالة واحدة',
      zero: 'لم تُوجَّه أي رسالة',
    );
    return '$_temp0';
  }

  @override
  String forwardSkipped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ملف ليست على هذا الجهاز بعد فتُركت',
      many: '$count ملفًا ليست على هذا الجهاز بعد فتُركت',
      few: '$count ملفات ليست على هذا الجهاز بعد فتُركت',
      two: 'ملفان ليسا على هذا الجهاز بعد فتُركا',
      one: 'ملف واحد ليس على هذا الجهاز بعد فتُرك',
      zero: 'لم يُترك أي ملف',
    );
    return '$_temp0';
  }

  @override
  String get torBlockedHint =>
      'يبدو أن Tor محجوب على هذه الشبكة. الجسور تتجاوز ذلك، لكن الجسور العامة غالبًا ما تكون محجوبة أيضًا: احصل على جسورك الخاصة (أدناه).';

  @override
  String get torGetBridgesTitle => 'كيف تحصل على جسورك الخاصة';

  @override
  String get torGetBridgesIntro =>
      'يوزّع Tor Project الجسور بهذه الطرق. اطلب جسور obfs4 أو webtunnel، ثم الصق الأسطر أعلاه.';

  @override
  String get torGetBridgesWeb => 'الموقع: bridges.torproject.org';

  @override
  String get torGetBridgesTelegram => 'تيليغرام: راسل ‎@GetBridgesBot';

  @override
  String get torGetBridgesEmail =>
      'البريد: اكتب إلى bridges@torproject.org من عنوان Gmail أو Riseup';

  @override
  String get torGetBridgesFriend =>
      'أو اطلب من شخص تثق به ويستخدم Tor أن يشاركك سطر جسر.';

  @override
  String get transportsTitle => 'الوصول إلى أشخاص خارج هذه الشبكة';

  @override
  String get transportsIntro =>
      'الأجهزة على هذه الشبكة تصل إليك مباشرة. أما لغيرها، فيحتاج Conest إلى طريق واحد على الأقل عبر الإنترنت، وثلاثة أفضل، لأن الشبكات تحجب بعضها. هذا ما يعمل على هذه الشبكة الآن.';

  @override
  String get transportsChecking => 'جارٍ التحقق مما يعمل على هذه الشبكة…';

  @override
  String transportsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count طريق جاهز: يُنصح بـ 3',
      many: '$count طريقًا جاهزًا: يُنصح بـ 3',
      few: '$count طرق جاهزة: يُنصح بـ 3',
      two: 'طريقان جاهزان: يُنصح بـ 3',
      one: 'طريق واحد جاهز: يُنصح بـ 3',
      zero: 'لا شيء بعد: يلزم 1، ويُنصح بـ 3',
    );
    return '$_temp0';
  }

  @override
  String get transportStateOn => 'يعمل';

  @override
  String get transportStateWorks => 'يعمل هنا';

  @override
  String get transportStateBlocked => 'محجوب هنا';

  @override
  String get transportStateNeedsSetup => 'يُعدّ لاحقًا في الإعدادات';

  @override
  String get transportsEmailCost =>
      'يفحص صندوق بريد: بيانات وبطارية أكثر قليلًا.';

  @override
  String get transportsSkipTitle => 'لن تصل إليك إلا الأجهزة القريبة';

  @override
  String get transportsSkipBody =>
      'بدون طريق عبر الإنترنت، لن تصل إليك إلا الأجهزة على هذه الشبكة، ولن تصل أنت إلا إليها. يمكنك إعداد طريق لاحقًا في الإعدادات، ضمن الاتصال.';

  @override
  String get transportsSkipConfirm => 'المتابعة على أي حال';

  @override
  String get transportsBanner =>
      'الآن لا تصل إليك إلا الأجهزة على هذه الشبكة. أعدّ طريقًا عبر الإنترنت.';

  @override
  String get transportsBannerAction => 'إعداد';

  @override
  String get transportsBannerDismiss => 'ليس الآن';

  @override
  String transportsTurnOnFailed(String name, String error) {
    return 'تعذّر تشغيل $name: $error';
  }

  @override
  String get transportsHowToChoose => 'كيف تختار';

  @override
  String get settingsUserGuide => 'دليل المستخدم';

  @override
  String get settingsEnterSends => 'زر Enter يرسل الرسالة';

  @override
  String get settingsEnterSendsHelp =>
      'Shift+Enter يبدأ سطرًا جديدًا. عند الإيقاف: Enter يبدأ سطرًا جديدًا وCtrl+Enter يرسل.';

  @override
  String get menuCopySelection => 'نسخ النص المحدد';

  @override
  String get linkLookalikeTitle => 'هل تفتح هذا الرابط؟';

  @override
  String linkLookalikeBody(String host) {
    return 'العنوان $host يستخدم حروفًا من أبجديات أخرى. قد يقلّد موقعًا تعرفه.';
  }

  @override
  String get linkOpen => 'فتح';

  @override
  String get carrierRemove => 'إزالة';

  @override
  String carrierRemoveTitle(String name) {
    return 'إزالة $name؟';
  }

  @override
  String carrierRemoveBody(String name) {
    return 'لن تصل إليك جهات الاتصال عبر $name، وسيُنسى ما يحفظه هذا الجهاز له. إعداده من جديد يمنحك عنوانًا جديدًا. لإيقافه مؤقتًا، أطفئ مفتاحه بدلًا من ذلك.';
  }

  @override
  String get carrierPaused =>
      'متوقف مؤقتًا: محفوظ وغير مستخدم. شغّله لاستخدامه مجددًا.';

  @override
  String get emailChangeAccount => 'تغيير الحساب';

  @override
  String get emailOtherServer => 'استخدام خادم آخر';

  @override
  String get actionSave => 'حفظ';

  @override
  String get settingsLinksTitle => 'الروابط التي ترسلها وتفتحها';

  @override
  String get settingsCleanLinks => 'إزالة التتبع من الروابط';

  @override
  String get settingsCleanLinksHelp =>
      'يزيل أجزاء الرابط التي تخبر الموقع بمن شاركه (مثل ?si= أو utm_) عند إرساله وعند فتحه. يستخدم قواعد ClearURLs.';

  @override
  String get settingsEmbedLinks => 'روابط تعرض معاينة';

  @override
  String get settingsEmbedLinksHelp =>
      'تمر روابط المنشورات على X وInstagram وReddit وTikTok والمواقع المشابهة عبر خدمة تتيح للتطبيقات الأخرى عرض معاينة، وتوجّه المتصفح إلى المنشور. الخدمات مأخوذة من قائمة embed-fixer؛ ويُتخطّى ما يتعطل منها.';

  @override
  String get linkCleaned => 'نُظِّف الرابط';

  @override
  String get linkCleanedUndo => 'تراجع';

  @override
  String get menuOpenOriginalLink => 'فتح الرابط الأصلي';

  @override
  String get editorSendOriginalAsFile => 'إرسال الأصل كملف (دون ضغط)';

  @override
  String get linkPreviewShow => 'عرض معاينة الرابط';

  @override
  String get settingsLinkPreviews => 'معاينات الروابط';

  @override
  String get settingsLinkPreviewsHelp =>
      'يعرض عنوان الرابط وصورته تحت الرسالة. يجلبها هذا الجهاز من الموقع، فيرى الموقع عنوان IP الخاص بك: تلقائيًا في المحادثات مع جهات اتصالك ومجموعاتك (ليس في وضع توفير البطارية أو أثناء التجوال)، وفي المحادثات الأخرى عند النقر فقط.';

  @override
  String get linkPreviewModeReceiver => 'يجلبها كل مستلم';

  @override
  String get linkPreviewModeSender =>
      'تُرسل مع الرسالة (لا يتصل المستلمون بالموقع)';

  @override
  String get linkPreviewModeBoth => 'كلاهما';

  @override
  String get linkPreviewModeOff => 'إيقاف';

  @override
  String get linkPreviewRemove => 'إرسال بلا معاينة';

  @override
  String get settingsLinkPreviewsTor => 'جلب المعاينات عبر Tor';

  @override
  String get settingsLinkPreviewsTorHelp =>
      'عند إعداد Tor ترى المواقع مخرج Tor لا عنوانك، ولا يُستعلم عن شيء من الرابط على شبكتك. ما دام Tor غير متصل لا تُجلب معاينات.';

  @override
  String linkPreviewFromSender(String host) {
    return '$host · معاينة من المرسل';
  }

  @override
  String get contentRoutingTitle => 'ما الذي يُرسل عبر الإنترنت';

  @override
  String get contentRoutingHelp =>
      'شبكتك المحلية تنقل كل شيء دائمًا. يعرف جهات اتصالك هذا الاختيار: ما يُستثنى ينتظر وسيلة نقل مسموحًا لها بحمله.';

  @override
  String get contentRoutingEverything => 'كل شيء';

  @override
  String get contentRoutingMessagesAndSmallFiles =>
      'الرسائل والملفات حتى 1 ميغابايت';

  @override
  String get contentRoutingMessagesOnly =>
      'الرسائل فقط (الملفات عبر الشبكة المحلية)';

  @override
  String get contentRoutingCustom => 'مخصص';

  @override
  String get contentRoutingByTransport => 'حسب وسيلة النقل';

  @override
  String get contentClassText => 'الرسائل';

  @override
  String get contentClassOwnSync => 'أجهزتك';

  @override
  String get contentClassHistory => 'السجل';

  @override
  String get contentClassFileSmall => 'ملفات حتى 1 ميغابايت';

  @override
  String get contentClassFileMedium => 'ملفات حتى 30 ميغابايت';

  @override
  String get contentClassFileLarge => 'ملفات أكبر';

  @override
  String get contentClassCallSignal => 'المكالمات';

  @override
  String get contentRoutingCannotCarry => 'لا يمكن لوسيلة النقل هذه حمله';

  @override
  String get routeViaOwnDevice => 'عبر جهازك الآخر';

  @override
  String get routeOwnDeviceDescription =>
      'استلمه جهاز آخر من أجهزتك ومرّره إلى هذا الجهاز، بتشفير تام بين الطرفين.';

  @override
  String get routeShortOwnDevice => 'جهازك';

  @override
  String get backgroundReceiveTitle => 'استقبال الرسائل في الخلفية';

  @override
  String get backgroundReceiveHelp =>
      'تصل الرسائل والمكالمات وConest مغلق. يعرض Android إشعارًا صامتًا أثناء تشغيله.';

  @override
  String get batteryExemptionTitle => 'تحسين البطارية';

  @override
  String get batteryExemptionAllowed =>
      'بلا قيود: لا يوقف Android تطبيق Conest في الخلفية.';

  @override
  String get batteryExemptionLimited =>
      'قد يوقف Android تطبيق Conest في الخلفية، فتنتظر الرسائل حتى تفتحه.';

  @override
  String get batteryExemptionAllow => 'السماح';

  @override
  String get batteryExemptionPromptTitle => 'استمر في استقبال الرسائل';

  @override
  String get batteryExemptionPromptBody =>
      'لكي تصلك الرسائل وConest مغلق، يجب أن يسمح له Android بالعمل في الخلفية. في الشاشة التالية، اسمح لـ Conest بالعمل دون قيود البطارية.';

  @override
  String batteryExemptionVendorHint(String maker) {
    return 'على هواتف $maker، فعّل أيضًا التشغيل التلقائي لـ Conest واضبط موفر البطارية له على «بلا قيود» (الإعدادات ← التطبيقات ← Conest).';
  }

  @override
  String get closeToTrayTitle => 'البقاء في شريط النظام عند الإغلاق';

  @override
  String get closeToTrayHelp =>
      'تستمر الرسائل في الوصول. افتح Conest مجددًا من أيقونته في شريط النظام أو أنهِه من هناك.';

  @override
  String get trayShow => 'إظهار Conest';

  @override
  String get trayQuit => 'إنهاء';

  @override
  String get notificationReply => 'رد';

  @override
  String get notificationMarkRead => 'تعليم كمقروء';

  @override
  String notificationReplyNotSent(String text) {
    return 'لم تُرسل: $text';
  }

  @override
  String get startAtLoginTitle => 'تشغيل Conest عند تسجيل الدخول';

  @override
  String get startAtLoginHelp =>
      'يفتح في شريط النظام جاهزًا للاستقبال، دون نافذة.';

  @override
  String get notificationNewMessage => 'رسالة جديدة';

  @override
  String notificationNewMessageFrom(String name) {
    return 'رسالة جديدة من $name';
  }

  @override
  String get notificationReplyNotSentPlain => 'لم يُرسل رد';

  @override
  String get notificationPreviewTitle => 'المعروض في الإشعارات';

  @override
  String get notificationPreviewFull => 'الاسم والرسالة';

  @override
  String get notificationPreviewSender => 'الاسم فقط';

  @override
  String get notificationPreviewHidden => 'لا شيء';

  @override
  String get voiceSettingsTitle => 'الصوت';

  @override
  String get voiceInputDevice => 'الميكروفون';

  @override
  String get voiceOutputDevice => 'السماعة أو سماعات الرأس';

  @override
  String get voiceSystemDefault => 'افتراضي النظام';

  @override
  String get voiceInputVolume => 'مستوى الميكروفون';

  @override
  String get voiceOutputVolume => 'مستوى الصوت';

  @override
  String get voiceMicTest => 'اختبار الميكروفون';

  @override
  String get voiceMicTestStart => 'لنختبر';

  @override
  String get voiceMicTestStop => 'إيقاف';

  @override
  String get voiceMicTestLoopback => 'اسمع صوتك';

  @override
  String get voiceMicTestUnavailable =>
      'اختبار الميكروفون غير متاح الآن (أثناء مكالمة، أو لا يدعم هذا الإصدار المكالمات).';

  @override
  String get voiceInputMode => 'إرسال صوتي';

  @override
  String get voiceInputModeAlways => 'دائمًا';

  @override
  String get voiceInputModeActivity => 'عندما أتكلم';

  @override
  String get voiceInputModePushToTalk => 'اضغط للتحدث';

  @override
  String get voiceSensitivityAutomatic => 'ضبط الحساسية تلقائيًا';

  @override
  String get voiceSensitivity => 'الحساسية';

  @override
  String get voicePushToTalkKey => 'مفتاح الضغط للتحدث';

  @override
  String get voicePushToTalkKeyNone => 'زر المكالمة فقط';

  @override
  String get voicePushToTalkKeyPress => 'اضغط مفتاحًا…';

  @override
  String get voicePushToTalkKeyHint => 'يعمل عندما يكون Conest في المقدمة';

  @override
  String get voiceClear => 'مسح';

  @override
  String get voiceProcessing => 'المعالجة';

  @override
  String get voiceNoiseSuppression => 'كتم الضوضاء';

  @override
  String get voiceEchoCancellation => 'إلغاء الصدى';

  @override
  String get voiceAutoGain => 'مستوى صوت تلقائي';

  @override
  String get voiceCallSounds => 'أصوات المكالمة';

  @override
  String get voiceCallSoundsHint => 'تظل المكالمة الواردة ترن.';

  @override
  String get voiceDevicesOnPhone =>
      'على أندرويد يختار الهاتف الميكروفون والسماعة للمكالمات.';

  @override
  String get voiceSettingsButton => 'إعدادات الصوت';

  @override
  String voiceParticipantVolume(String name) {
    return 'مستوى صوت $name';
  }

  @override
  String get voiceHoldToTalk => 'اضغط مطولًا للتحدث';

  @override
  String get quietHoursTitle => 'ساعات الهدوء';

  @override
  String get quietHoursHint => 'تظهر الإشعارات دون صوت أو اهتزاز.';

  @override
  String quietHoursFrom(String time) {
    return 'من $time';
  }

  @override
  String quietHoursUntil(String time) {
    return 'حتى $time';
  }

  @override
  String get quietHoursCallsRing => 'تظل المكالمات ترن';

  @override
  String get muteForHour => 'لمدة ساعة';

  @override
  String get muteForEightHours => 'لمدة 8 ساعات';

  @override
  String get muteForDay => 'لمدة يوم';

  @override
  String get muteUntilUnmuted => 'حتى ألغي الكتم';

  @override
  String get notifyMentionsOnly => 'الإشعار عند الإشارة إليّ فقط';

  @override
  String get notifyAllMessages => 'الإشعار لكل الرسائل';

  @override
  String get xmppEncOmemo2Unverified => 'مشفّر، غير موثّق (OMEMO)';

  @override
  String get xmppTrustPending => 'جهاز جديد، غير مؤكَّد';

  @override
  String get xmppUnconfirmedMsg => 'من جهاز جديد لم تؤكده.';

  @override
  String get xmppEncOmemo2 => 'مشفّرة (OMEMO)';

  @override
  String get xmppEncLegacy => 'OMEMO القديم (لم يُراجَع بعد)';

  @override
  String get xmppEncAuto => 'تُشفَّر إذا دعمتها جهة الاتصال';

  @override
  String get xmppEncRequired => 'مشفّرة دائمًا';

  @override
  String get xmppEncryptionMenu => 'التشفير والمفاتيح';

  @override
  String get xmppEncryptionTitle => 'التشفير';

  @override
  String get xmppEncryptionAuto => 'عندما تدعمه جهة الاتصال';

  @override
  String get xmppEncryptionOn => 'دائمًا (لا يُرسَل شيء بخلاف ذلك)';

  @override
  String get xmppEncryptionOff => 'أبدًا';

  @override
  String get xmppKeysTitle => 'مفاتيح التشفير';

  @override
  String get xmppKeysYours => 'مفتاحك';

  @override
  String get xmppKeysYoursHint =>
      'قارن هذه البصمة مع جهة الاتصال وجهًا لوجه أو عبر مكالمة تثق بها، أو دعها تمسح الرمز.';

  @override
  String xmppKeysTheirs(String name) {
    return 'أجهزة $name';
  }

  @override
  String get xmppKeysNone => 'لم يُعثر على أجهزة OMEMO لجهة الاتصال هذه.';

  @override
  String get xmppTrustBlind => 'غير مُتحقَّق منه';

  @override
  String get xmppTrustVerified => 'تم التحقق';

  @override
  String get xmppTrustRefused => 'مرفوض';

  @override
  String get xmppTrustVerify => 'وضع علامة تم التحقق';

  @override
  String get xmppTrustRefuse => 'رفض هذا الجهاز';

  @override
  String get xmppTrustAllow => 'السماح مجددًا';

  @override
  String get xmppKeysScan => 'امسح رمزهم';

  @override
  String get xmppKeysRefresh => 'تحقق من الأجهزة';

  @override
  String get xmppKeysForget => 'نسيان مفتاح هذا الجهاز';

  @override
  String get xmppKeysChanged =>
      'تغيّر مفتاحه: لن يُرسَل إليه شيء حتى تنسى المفتاح القديم.';

  @override
  String xmppKeysScanMatch(String count) {
    return 'تم التحقق من $count جهاز.';
  }

  @override
  String get xmppKeysScanMismatch =>
      'الرمز لا يطابق مفاتيح جهة الاتصال. لا تثق بها.';

  @override
  String get xmppUnreadable => 'تعذّر فك تشفير هذه الرسالة.';

  @override
  String get xmppUntrustedMsg => 'من جهاز رفضتَه.';

  @override
  String get xmppLegacySwitch => 'OMEMO القديم (تجريبي)';

  @override
  String get xmppLegacyHint =>
      'محادثات مشفّرة مع تطبيقات أقدم مثل Conversations وDino وGajim. لم تُراجَع بعد، لذا لا تُوسَم هذه الرسائل بأنها مشفّرة.';

  @override
  String get routeXmppDescription =>
      'تحمله خوادم XMPP، مع بقائه مشفّرًا من طرف إلى طرف بواسطة Conest؛ ترى الخوادم الحسابين والتوقيت.';

  @override
  String get xmppCarrierSubtitle => 'نقل الرسائل عبر حساب XMPP (Jabber)';

  @override
  String get xmppCreatedAccount => 'حساب أنشأه Conest';

  @override
  String get xmppOwnAccount => 'حسابك الخاص';

  @override
  String get xmppChangeAccount => 'تغيير الحساب';

  @override
  String get xmppServerField => 'خادم XMPP (فارغ: أول خادم يستجيب هنا)';

  @override
  String get xmppUseOwnAccount => 'استخدام حساب XMPP الخاص بي';

  @override
  String get xmppOwnAccountNote =>
      'يسجّل Conest الدخول كجهاز إضافي؛ لا ترى تطبيقات XMPP الأخرى رسائله.';

  @override
  String get xmppAddressField => 'عنوان XMPP (الاسم@الخادم)';

  @override
  String get xmppPasswordField => 'كلمة المرور';

  @override
  String get xmppRetracted => 'سُحبت الرسالة';

  @override
  String get xmppFile => 'ملف';

  @override
  String get xmppNewChat => 'محادثة XMPP جديدة';

  @override
  String get xmppNewChatAddress => 'العنوان أو رابط xmpp:';

  @override
  String get xmppGroupChat => 'محادثة جماعية';

  @override
  String get xmppNickname => 'اسمك المستعار';

  @override
  String get xmppOpenChat => 'فتح';

  @override
  String get xmppMetadataTitle => 'تبقى بعض التفاصيل في هذا الملف';

  @override
  String get xmppMetadataBody =>
      'تعذّر على Conest إزالة كل التفاصيل المخفية (مثل الموقع أو الجهاز) من هذا الملف. أترسله رغم ذلك؟';

  @override
  String get xmppSendAnyway => 'أرسل على أي حال';

  @override
  String get xmppReply => 'رد';

  @override
  String get xmppCopy => 'نسخ';

  @override
  String get xmppEdit => 'تعديل';

  @override
  String get xmppRetract => 'سحب';

  @override
  String get xmppChatGone => 'لم تعد هذه المحادثة موجودة.';

  @override
  String get xmppNotEncrypted => 'غير مشفّرة';

  @override
  String get xmppLeaveRoom => 'مغادرة المحادثة الجماعية';

  @override
  String get xmppDeleteChat => 'حذف المحادثة';

  @override
  String get xmppBlock => 'حظر';

  @override
  String get xmppAccept => 'قبول';

  @override
  String get xmppRequest =>
      'راسلك شخص ليس من جهات اتصالك. لا تُرسل الردود وعلامات القراءة إلا بعد قبولك.';

  @override
  String get xmppRoomInvitation =>
      'تمت دعوتك إلى هذه المحادثة الجماعية. هل تنضم؟';

  @override
  String get xmppAttach => 'إرفاق ملف';

  @override
  String get xmppMessageHint => 'رسالة';

  @override
  String get xmppEdited => 'معدّلة';

  @override
  String get xmppChats => 'محادثات XMPP';

  @override
  String get xmppChatsSubtitle =>
      'تحدث مع أي شخص على XMPP (Jabber) بجانب محادثات Conest';

  @override
  String get xmppChatsOtherAccount =>
      'استخدام حساب غير الذي ينقل به Conest الرسائل';

  @override
  String get xmppConnected => 'متصل';

  @override
  String get xmppConnecting => 'جارٍ الاتصال';

  @override
  String appModeClientOnlyTitle(String network) {
    return 'هل تستخدم Conest كعميل $network؟';
  }

  @override
  String get onbXmppInstead => 'استخدمه كعميل XMPP بدلًا من ذلك';

  @override
  String get xmppSignIn => 'سجّل الدخول إلى حساب XMPP';

  @override
  String get xmppNoChats => 'لا توجد محادثات XMPP بعد';

  @override
  String get xmppRequestShort => 'طلب محادثة';

  @override
  String get routeTelegramDescription =>
      'يُنقل عبر بوتات تيليجرام، ومشفّر من طرف إلى طرف بواسطة Conest؛ يرى تيليجرام البوتين والوقت.';

  @override
  String get telegramCarrierSubtitle => 'نقل الرسائل عبر بوت تيليجرام أنشأته';

  @override
  String get telegramChangeBot => 'تغيير البوت';

  @override
  String get telegramBotHelp =>
      'أنشئ بوتًا عبر @BotFather وفعّل المراسلة بين البوتات له والصق الرمز هنا. استخدم بوتًا يقرؤه Conest فقط. ويفعل جهة اتصالك الشيء نفسه.';

  @override
  String get telegramBotTokenField => 'رمز البوت';

  @override
  String get telegramClientTitle => 'عميل تيليجرام';

  @override
  String get telegramClientSubtitle =>
      'استخدم حسابك في تيليجرام داخل Conest (عميل غير رسمي)';

  @override
  String get telegramUnofficial =>
      'Conest عميل غير رسمي لتيليجرام. تنطبق قواعد تيليجرام على حسابك.';

  @override
  String get telegramPhoneField => 'رقم الهاتف (+…)';

  @override
  String get telegramCodeField => 'رمز الدخول';

  @override
  String get telegramPasswordField => 'كلمة مرور التحقق بخطوتين';

  @override
  String get telegramQrLogin => 'تسجيل الدخول برمز QR بدلًا من ذلك';

  @override
  String get telegramQrHint =>
      'على هاتفك افتح تيليجرام ثم الإعدادات ثم الأجهزة ثم ربط جهاز سطح المكتب وامسح هذا الرمز.';

  @override
  String get telegramNoAccount =>
      'لا يوجد حساب تيليجرام لهذا الرقم. Conest يسجّل الدخول فقط؛ أنشئ الحساب أولًا في تطبيق تيليجرام الرسمي.';

  @override
  String get telegramLogOut => 'تسجيل الخروج والإزالة';

  @override
  String telegramSignedInAs(String name) {
    return 'تم تسجيل الدخول باسم $name';
  }

  @override
  String get telegramConnecting => 'جارٍ الاتصال…';

  @override
  String get telegramMods => 'إعدادات التعديلات';

  @override
  String get telegramNoChats => 'لا توجد محادثات تيليجرام بعد';

  @override
  String get telegramSaved => 'الرسائل المحفوظة';

  @override
  String get telegramSponsored => 'مُموَّل';

  @override
  String get telegramDeletedBySender => 'حذفها المرسل';

  @override
  String get telegramAllChats => 'كل المحادثات';

  @override
  String get telegramArchive => 'الأرشيف';

  @override
  String get telegramChannelReadOnly => 'يمكن للمشرفين فقط النشر هنا';

  @override
  String get telegramSendSilently => 'إرسال بصمت';

  @override
  String get telegramSchedule => 'إرسال لاحقًا…';

  @override
  String get telegramTranslate => 'ترجمة';

  @override
  String get telegramExport => 'تصدير الرسائل المحمّلة';

  @override
  String get telegramDeleteForAll => 'حذف للجميع';

  @override
  String get telegramDeleteForMe => 'حذف لدي فقط';

  @override
  String get telegramDownload => 'تنزيل';

  @override
  String get telegramOpenSponsored => 'فتح الرابط';

  @override
  String get telegramHiddenWords =>
      'إخفاء الرسائل التي تحتوي هذه الكلمات (كلمة في كل سطر)';

  @override
  String get telegramDeletedNoticeSwitch =>
      'إظهار إشعار عندما يحذف أحدهم رسالة';

  @override
  String get telegramDeletedNoticeNote =>
      'يبقى الإشعار فقط. لا يُحتفظ بالمحتوى المحذوف.';

  @override
  String get telegramTranslateTo =>
      'الترجمة إلى (رمز اللغة، فارغ للغة التطبيق)';

  @override
  String get telegramPlugins => 'الإضافات';

  @override
  String get telegramPluginHelp =>
      'الإضافات ملفات قواعد صغيرة. تستطيع فقط إخفاء الرسائل وتغيير النص المرسل وإضافة أوامر، وبحسب ما تعلنه فقط.';

  @override
  String get telegramPluginInstall => 'تثبيت إضافة (الصق نصها)';

  @override
  String get telegramPluginBad =>
      'هذه ليست إضافة صالحة أو أن عدد المثبتة كبير.';

  @override
  String telegramPluginPermissions(String permissions) {
    return 'يمكنها: $permissions';
  }

  @override
  String get telegramPermReadMessages => 'إخفاء الرسائل';

  @override
  String get telegramPermEditOutgoing => 'تغيير ما ترسله';

  @override
  String get telegramPermCommands => 'إضافة أوامر';

  @override
  String get telegramDownloads => 'التنزيلات';

  @override
  String get telegramLoadOlder => 'تحميل رسائل أقدم';

  @override
  String get onbTelegramInstead => 'استخدمه كعميل تيليجرام بدلًا من ذلك';

  @override
  String get routeDiscordDescription =>
      'يُنقل عبر بوتات ديسكورد، ومشفّر من طرف إلى طرف بواسطة Conest؛ يرى ديسكورد البوتين والوقت.';

  @override
  String get discordCarrierSubtitle => 'نقل الرسائل عبر بوت ديسكورد أنشأته';

  @override
  String get discordBotHelp =>
      'أنشئ بوتًا في بوابة مطوري ديسكورد وأضفه إلى خادم خاص تشاركه مع بوتات جهات اتصالك والصق الرمز ومعرّف القناة. استخدم بوتًا يقرؤه Conest فقط.';

  @override
  String get discordBotTokenField => 'رمز البوت';

  @override
  String get discordChannelField => 'معرّف القناة';

  @override
  String get discordChangeBot => 'تغيير البوت';

  @override
  String get discordClientTitle => 'عميل ديسكورد (مخالف لشروط ديسكورد)';

  @override
  String get discordClientSubtitle =>
      'استخدم حسابك في ديسكورد داخل Conest كما يفعل Vencord وVesktop';

  @override
  String get discordWarningTitle => 'قد يؤدي هذا إلى حظر حسابك';

  @override
  String get discordWarningBody =>
      'استخدام رمز حسابك في تطبيق آخر مخالف لشروط ديسكورد وقد يحظر ديسكورد الحساب. لا يتصرف Conest إلا عندما تفعل أنت: يقرأ ما تفتحه ويرسل ما ترسله فقط. لا يستخدم هذا الرمز لأي شيء آخر ولا تستخدمه ناقلة Conest أبدًا.';

  @override
  String get discordWarningAccept => 'أفهم، تابع';

  @override
  String get discordAccountTokenField => 'رمز الحساب';

  @override
  String get discordTokenHelp =>
      'ستجده في أدوات المطور لديسكورد في المتصفح (تبويب Network، ترويسة Authorization). لا تشاركه أبدًا.';

  @override
  String discordSignedInAs(String name) {
    return 'تم تسجيل الدخول باسم $name';
  }

  @override
  String get discordDirectMessages => 'الرسائل الخاصة';

  @override
  String get discordNoChats => 'لا توجد محادثات ديسكورد بعد';

  @override
  String get discordServers => 'الخوادم';

  @override
  String get discordLoadOlder => 'تحميل رسائل أقدم';

  @override
  String get discordOnbInstead => 'استخدمه كعميل ديسكورد بدلًا من ذلك';

  @override
  String get telegramRelaySaved => 'نقل الرسائل المحفوظة إلى أجهزتي الأخرى';

  @override
  String get telegramRelayChat => 'نقل هذه المحادثة إلى أجهزتي الأخرى';

  @override
  String get telegramRelayNote =>
      'يُنقل نص الرسائل فقط، ومشفّر من طرف إلى طرف بين أجهزتك. لا يغادر تسجيل دخولك إلى تيليجرام هذا الجهاز.';

  @override
  String get telegramViaDevice => 'تيليجرام عبر جهازك الآخر';

  @override
  String get telegramBridgeReadOnly =>
      'للقراءة فقط هنا. أجب في تيليجرام على الجهاز الذي يملكه.';

  @override
  String telegramPluginConfirmTitle(String name) {
    return 'تثبيت $name؟';
  }

  @override
  String get telegramPluginNoPermissions => 'لا شيء (لا يستطيع فعل أي شيء)';

  @override
  String get telegramPluginInstallButton => 'تثبيت';

  @override
  String get xmppEditNotApplied =>
      'لم يُطبَّق تعديل هذه الرسالة: تعذّر التحقق منه.';

  @override
  String get relayAccessTitle => 'الوصول إلى المرحِّل';

  @override
  String get relayAccessUnknown =>
      'لم يذكر هذا المرحِّل من يمكنه استخدامه (مرحِّل أقدم، أو لم يُفحص بعد).';

  @override
  String get relayAccessSessions =>
      'اتصال خاص: من تجلب رسائله يبقى مخفيًا عن الشبكة.';

  @override
  String get relayAccessMessagesOpen => 'يمكن لأي شخص ترك الرسائل هنا.';

  @override
  String get relayAccessMessagesRegistered =>
      'يمكن للحسابات المسجلة فقط ترك الرسائل هنا.';

  @override
  String get relayAccessMessagesOff => 'لا يقبل هذا المرحِّل رسائل جديدة.';

  @override
  String get relayAccessRegistrationOpen => 'يمكن لأي شخص التسجيل.';

  @override
  String get relayAccessRegistrationInvite => 'يتطلب التسجيل رمز دعوة.';

  @override
  String get relayAccessRegistrationPassword =>
      'يتطلب التسجيل كلمة مرور المرحِّل.';

  @override
  String get relayAccessRegistrationClosed => 'التسجيل مغلق.';

  @override
  String relayAccessRegistered(String date) {
    return 'مسجَّل على هذا المرحِّل حتى $date.';
  }

  @override
  String get relayAccessInviteLabel => 'رمز الدعوة';

  @override
  String get relayAccessPasswordLabel => 'كلمة المرور';

  @override
  String get relayAccessRegister => 'تسجيل';

  @override
  String get relayAccessRegisteredNow => 'تم التسجيل.';

  @override
  String relayAccessFailed(String error) {
    return 'تعذّر التسجيل: $error';
  }

  @override
  String get circumventionTitle => 'تجاوز الرقابة';

  @override
  String get circumventionIntro =>
      'للشبكات التي تحجب Conest أو ترشّحه. «تلقائي» يشغّلها فقط على الشبكات التي يبدو أن الطرق فيها محجوبة.';

  @override
  String get circumventionPrivateDns => 'بحث خاص عن الأسماء (DNS عبر HTTPS)';

  @override
  String get circumventionSplitGreeting => 'تقسيم تحية الاتصال الآمن';

  @override
  String get circumventionSplitGreetingHint =>
      'يخفي عن المرشِّحات البسيطة الخادم الذي تتصل به.';

  @override
  String get circumventionQuietLan => 'اكتشاف هادئ للأجهزة القريبة';

  @override
  String get circumventionQuietLanHint =>
      'تكتشف الأجهزة القريبة بعضها بإشارة مُشفَّرة بدل إشارة يسهل التعرف عليها.';

  @override
  String get circumventionAutomatic => 'تلقائي';

  @override
  String get circumventionAlways => 'دائمًا';

  @override
  String get circumventionNever => 'متوقف';

  @override
  String get circumventionActiveHere => 'قيد الاستخدام على هذه الشبكة.';

  @override
  String get circumventionIdleHere => 'غير مستخدم على هذه الشبكة.';

  @override
  String linkKeepsThisDevice(int chats, int contacts, int groups) {
    return 'يحتفظ هذا الجهاز بمحادثاته ($chats) وجهات اتصاله ($contacts) ومجموعاته ($groups) وإعداداته. جهات الاتصال المشتركة تحتفظ بالأسماء والمسارات التي اخترتها هنا. تُضاف جهات اتصال الحساب ومجموعاته وسجل محادثاته.';
  }

  @override
  String linkLeavesAccount(int devices) {
    return 'هذا الجهاز جزء من حساب آخر فيه $devices أجهزة أخرى. الربط ينقله خارج ذلك الحساب. تبقى تلك الأجهزة تعرضه حتى تزيله من هناك.';
  }

  @override
  String get linkLeaveAndContinue => 'مغادرة ذلك الحساب والمتابعة';

  @override
  String get devicesSyncSpeed => 'المزامنة مع أجهزتي';

  @override
  String get devicesSyncSteady => 'ثابتة';

  @override
  String get devicesSyncFast => 'سريعة';

  @override
  String get devicesSyncPaused => 'متوقفة';

  @override
  String get devicesSyncFastWarning =>
      'المزامنة السريعة تستهلك الكثير من البيانات والبطارية. تعمل فقط على الشبكات غير المحدودة بحجم، ويُطلب تأكيدك في كل مرة تشغّلها.';

  @override
  String get devicesSyncFastTurnOn => 'تشغيل المزامنة السريعة';

  @override
  String get devicesShareSettings => 'مشاركة الإعدادات مع أجهزتي الأخرى';

  @override
  String get devicesShareSettingsHint =>
      'تتبع قواعد التنزيل وحدود التخزين أحدث تغيير. يعمل فقط بين أجهزة فعّلت هذا الخيار جميعها.';

  @override
  String get xmppCaptchaTitle => 'يطلب الخادم رمز CAPTCHA';

  @override
  String get xmppCaptchaAnswerField => 'ما هو مكتوب في الصورة';

  @override
  String get xmppSignUpOnWebsite =>
      'تسجّل هذه الخوادم الحسابات على موقعها. سجّل هناك ثم اختر «استخدام حساب XMPP الخاص بي».';

  @override
  String get xmppOpenWebsite => 'فتح الموقع';

  @override
  String linkSummaryLine(
    String side,
    int contacts,
    int chats,
    int groups,
    int files,
  ) {
    return '$side: $contacts جهة اتصال، $chats محادثة، $groups مجموعة، $files ملف';
  }

  @override
  String get linkSideThisDevice => 'هذا الجهاز';

  @override
  String get linkSideAccount => 'الحساب';

  @override
  String linkConflictContact(String thisName, String accountName) {
    return '$thisName هنا، و$accountName في الحساب';
  }

  @override
  String linkConflictGroup(String name) {
    return 'المجموعة $name موجودة في الجانبين';
  }

  @override
  String get linkModeMerge => 'دمج (موصى به)';

  @override
  String get linkModeMergeHint =>
      'يصبح الطرفان بيانات الحساب. تحتفظ جهات الاتصال المشتركة بالأسماء التي منحتها لها هنا. وتبقى جهات الاتصال والمحادثات والمجموعات الأخرى في هذا الجهاز.';

  @override
  String get linkModeReplace => 'الاستبدال ببيانات الحساب';

  @override
  String get linkModeReplaceHint =>
      'يأخذ هذا الجهاز محادثات الحساب وسجلات جهات الاتصال المشتركة. تُحفظ المحادثات التي يتخلى عنها مشفرة في الإعدادات > الأجهزة > المحادثات القديمة.';

  @override
  String get linkModeReplaceConfirm =>
      'ستُستبدل محادثات هذا الجهاز مع جهات الاتصال الموجودة في الحساب أيضًا بمحادثات الحساب. تبقى القديمة قابلة للقراءة في المحادثات القديمة ويمكنك تصديرها إلى ملف. متابعة؟';

  @override
  String get linkModeSeparate => 'ملف منفصل (غير متاح بعد)';

  @override
  String get linkSettingsKeep => 'الاحتفاظ بإعدادات هذا الجهاز';

  @override
  String get linkSettingsTake => 'أخذ إعدادات الحساب';

  @override
  String get linkSettingsTakeList =>
      'أخذ إعدادات الحساب يغيّر فقط: التنزيل التلقائي، واحتياطي التخزين، وحد النقل عبر Iroh.';

  @override
  String linkConflictKeys(
    String name,
    String thisFingerprint,
    String accountFingerprint,
  ) {
    return '$name: مفاتيح مختلفة هنا عن الحساب ($thisFingerprint هنا، $accountFingerprint في الحساب). يحتفظ هذا الجهاز بسجله؛ تحقق من جهة الاتصال.';
  }

  @override
  String get devicesOldChats => 'المحادثات القديمة لهذا الجهاز';

  @override
  String get devicesOldChatsHint =>
      'محادثات تخلى عنها هذا الجهاز عند انضمامه إلى الحساب. للقراءة فقط.';

  @override
  String get linkArchiveEmpty => 'لا شيء هنا.';

  @override
  String linkArchiveSummary(int chats, int messages) {
    return '$chats محادثات، $messages رسائل';
  }

  @override
  String get linkArchiveExport => 'تصدير إلى ملف';

  @override
  String get linkArchiveExportWarning =>
      'الملف غير مشفر. يحتوي على محادثاتك القديمة وأسماء جهات الاتصال وعناوينهم. يستطيع أي شخص يحصل عليه قراءتها. احفظه فقط حيث تثق.';

  @override
  String linkArchiveSaved(String path) {
    return 'تم الحفظ في $path.';
  }

  @override
  String get linkArchiveDelete => 'حذف هذا الأرشيف';

  @override
  String get linkArchiveDeleteConfirm => 'حذف هذه المحادثات القديمة نهائيًا؟';

  @override
  String get linkArchiveExportWithFiles => 'تصدير مع الملفات';

  @override
  String linkArchiveFileMissing(String name) {
    return 'الملف $name لم يعد على هذا الجهاز.';
  }

  @override
  String linkArchiveSavedWithFiles(String path, int count) {
    return 'تم الحفظ في $path مع $count ملفات.';
  }

  @override
  String get contactKeysDifferTitle => 'المفاتيح مختلفة: تحقق';

  @override
  String get contactKeysDifferBody =>
      'عرف هذا الجهاز جهة الاتصال هذه بمفاتيح غير التي في حسابك. قارن رقم الأمان معها عبر قناة أخرى.';

  @override
  String get contactKeysDifferConfirm => 'قارنتها';

  @override
  String get energyBudgetTitle => 'استهلاك الطاقة';

  @override
  String get energyBudgetSubtitle =>
      'مقدار البطارية التي قد تستهلكها الاتصالات. وضع التوفير يبقي الحد الأدنى عند فصل الشاحن.';

  @override
  String get energyBudgetBalanced => 'متوازن';

  @override
  String get energyBudgetEco => 'توفير: المزيد أثناء الشحن فقط';

  @override
  String get energyBudgetFast => 'سريع';
}

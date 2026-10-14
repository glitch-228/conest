// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get modeChooseTitle => '你希望 Conest 如何显示？';

  @override
  String get modeChangeLater => '你可以随时在设置中更改。';

  @override
  String get modeSimple => '简洁';

  @override
  String get modeStandard => '标准';

  @override
  String get modeAdvanced => '高级';

  @override
  String get modeSimpleDescription => '一个聊天列表、大号文字，只保留你需要的设置。消息显示已发送、已送达和已读。';

  @override
  String get modeStandardDescription => '和你熟悉的聊天软件一样：聊天、群组、通话和文件，带有送达和已读标记。';

  @override
  String get modeAdvancedDescription => '全部内容，包括每条消息经过的路线、所有传输方式和诊断信息。';

  @override
  String get actionContinue => '继续';

  @override
  String get actionStart => '开始';

  @override
  String get actionBack => '返回';

  @override
  String get actionClose => '关闭';

  @override
  String get routesTitle => 'Conest 如何联系他人';

  @override
  String get routesDirect => 'Conest 通过你的网络和互联网把消息直接发给联系人，中间没有服务器。这已经开启。';

  @override
  String get routesOthers =>
      '当这些途径被封锁或不可用时，Conest 还可以使用中继、Tor、Nostr、电子邮件、Matrix、附近手机组成的蓝牙网络或 LoRa 电台。每一种在你于“设置 → 连接”中开启之前都是关闭的。';

  @override
  String get routesAdvanced => '在高级模式下，每条消息会显示它经过的路线，并且可以在联系人资料中测试每条路线。';

  @override
  String get tabChats => '聊天';

  @override
  String get tabCalls => '通话';

  @override
  String get tabSettings => '设置';

  @override
  String get callsEmpty => '还没有通话。打开一个聊天并点按通话按钮。';

  @override
  String get callOutgoing => '呼出';

  @override
  String get callIncoming => '呼入';

  @override
  String get callMissed => '未接';

  @override
  String get callDeclined => '已拒绝';

  @override
  String get callCancelled => '已取消';

  @override
  String get callFailed => '失败';

  @override
  String callDuration(int minutes, int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes 分 $seconds 秒',
      zero: '$seconds 秒',
    );
    return '$_temp0';
  }

  @override
  String get unknownContact => '未知联系人';

  @override
  String get messageDetails => '消息详情';

  @override
  String messageSentAt(String time) {
    return '发送于 $time';
  }

  @override
  String messageReceivedAt(String time) {
    return '接收于 $time';
  }

  @override
  String messageDeliveredAt(String time) {
    return '送达于 $time';
  }

  @override
  String messageReadAt(String time) {
    return '已读于 $time';
  }

  @override
  String memberDeliveredAt(String time) {
    return '送达 $time';
  }

  @override
  String memberReadAt(String time) {
    return '已读 $time';
  }

  @override
  String get messageRoutes => '路线';

  @override
  String get messageArrivedBy => '到达途径';

  @override
  String get settingsShowAll => '显示所有设置';

  @override
  String get settingsLanguage => '语言';

  @override
  String get settingsLanguageSystem => '跟随设备';

  @override
  String get settingsAiTranslated => '此翻译由 AI 完成，可能有错误。你可以在 Weblate 上帮助改进。';
}

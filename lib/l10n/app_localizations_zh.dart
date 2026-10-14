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

  @override
  String get menuReply => '回复';

  @override
  String get menuReact => '回应 👍';

  @override
  String get menuForward => '转发';

  @override
  String get menuCopyMessage => '复制消息';

  @override
  String get menuDownloadAttachment => '下载附件';

  @override
  String get menuSaveAttachment => '保存附件';

  @override
  String get menuCopyImage => '复制图片';

  @override
  String get menuFreeUpSpace => '释放本地空间';

  @override
  String get menuCancelTransfer => '取消传输';

  @override
  String get menuRetryTransfer => '重试传输';

  @override
  String get menuForwardAttachment => '转发附件';

  @override
  String get menuCancelSending => '取消发送';

  @override
  String get menuEditMessage => '编辑消息';

  @override
  String get menuDeleteMessage => '删除消息';

  @override
  String get menuEdit => '编辑';

  @override
  String get menuDelete => '删除';

  @override
  String get composerAttach => '附加文件或图片';

  @override
  String get composerSchedule => '定时发送';

  @override
  String get composerSend => '发送';

  @override
  String get searchChatsAndMessages => '搜索聊天和消息';

  @override
  String get searchChats => '搜索聊天';

  @override
  String get searchContacts => '搜索联系人';

  @override
  String get archivedChats => '已归档的聊天';

  @override
  String get actionSearch => '搜索';

  @override
  String get settingsPersonal => '个人';

  @override
  String get settingsStorage => '存储';

  @override
  String get settingsConnectivity => '连接';

  @override
  String get settingsRelays => '中继';

  @override
  String get settingsUpdates => '更新';

  @override
  String get settingsAccount => '账户';

  @override
  String get onbNameRequired => '请输入显示名称和有效的本地端口。';

  @override
  String get onbRelayPortInvalid => '如果填写了互联网中继地址，中继端口也必须有效。';

  @override
  String get onbRelayDesktop => '电脑默认充当中继，并自动公布附近的局域网路线。';

  @override
  String get onbRelayAndroid => '安卓默认关闭中继模式。只有希望这台设备帮忙转发时，才在设置中开启。';

  @override
  String get onbRelayOther => '如果希望这台设备帮忙转发流量，可以在设置中开启中继模式。';

  @override
  String get onbTagline =>
      '通过你的网络或互联网直接联系联系人，端到端加密并具备前向保密。当常用途径被封锁时，Conest 会改用中继、Matrix、Nostr、电子邮件、Tor、LoRa 电台或附近手机组成的蓝牙网络。';

  @override
  String get onbFeatureForwardSecret => '前向保密聊天';

  @override
  String get onbFeatureDirect => '通过局域网和互联网直连';

  @override
  String get onbFeatureFallbacks => 'Tor、网状网络和电台备用';

  @override
  String get onbFeatureMatrix => '同时也是 Matrix 客户端';

  @override
  String get onbCreateTitle => '创建你的第一台设备';

  @override
  String get onbCreateHelp =>
      '只需要一个显示名称。本地端口用于局域网投递和口令配对。互联网中继是可选的：没有它也能通过互联网联系到联系人。之后可在“设置 → 连接”中开启更多路线。';

  @override
  String get onbDisplayName => '显示名称';

  @override
  String get onbLocalPort => '本地中继 / 局域网端口';

  @override
  String get onbRelayHost => '互联网中继地址（可选）';

  @override
  String get onbRelayPort => '互联网中继端口';

  @override
  String get onbCreateButton => '创建加密设备';

  @override
  String get onbMatrixInstead => '改为仅用作 Matrix 客户端';

  @override
  String get onbMatrixHelp =>
      '仅 Matrix 聊天，没有 Conest 身份。之后可在“设置 → 连接 → 应用模式”中切换为“两者”（Conest 与 Matrix 并排）。';

  @override
  String get groupCreate => '创建群组';

  @override
  String get groupTitle => '群组名称';

  @override
  String get roleMember => '成员';

  @override
  String get roleModerator => '版主';

  @override
  String get roleAdmin => '管理员';

  @override
  String get actionCancel => '取消';

  @override
  String get actionCreate => '创建';

  @override
  String get actionCreating => '正在创建…';

  @override
  String get contactAdd => '添加联系人';

  @override
  String get contactAlias => '备注名';

  @override
  String get contactInvitePayload => '邀请内容或扫描的二维码';

  @override
  String get contactScanQr => '扫描二维码';

  @override
  String get contactCodephrase => '仅口令';

  @override
  String get contactTrustPayload => '信任二维码 / 邀请';

  @override
  String get contactFindCodephrase => '通过口令查找';

  @override
  String get contactExchangeFailed => '自动交换失败';

  @override
  String contactExchangeFailedBody(String alias) {
    return '你添加了 $alias，但你的邀请无法自动发回。请让对方在他们那边扫描或输入你的邀请，或者现在放弃并删除这个单向联系人。';
  }

  @override
  String get actionAbort => '放弃';

  @override
  String get contactKeep => '保留联系人';
}

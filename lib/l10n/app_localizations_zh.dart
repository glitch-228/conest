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

  @override
  String get uiPassphrase89950C => '口令';

  @override
  String get uiConfirmPassphraseEBAAC0 => '确认口令';

  @override
  String get uiUnlock1526A1 => '解锁';

  @override
  String get uiUpdateAvailable67FD3A => '有可用更新';

  @override
  String get uiLater56E2F5 => '稍后';

  @override
  String get uiHostAutoDetectsTCPUDP663D30 =>
      '主机会自动检测 TCP/UDP；udp://host:port 强制使用 UDP';

  @override
  String get uiVerificationRequestDA06F9 => '验证请求';

  @override
  String get uiIgnore98F55D => '忽略';

  @override
  String get uiVerifyDDA6AC => '验证';

  @override
  String uiCouldNotReadValueValue695755(String value, String value2) {
    return '无法读取 $value：$value2';
  }

  @override
  String uiCouldNotShareValueValue7BA3A3(String value, String value2) {
    return '无法分享 $value：$value2';
  }

  @override
  String uiCouldNotSaveSidebarWidthB4DACB(String value) {
    return '无法保存侧栏宽度：$value';
  }

  @override
  String get uiNoAudioOutputDevicesWere17E473 => '未找到音频输出设备。';

  @override
  String get uiCallAudioOutput0C276F => '通话音频输出';

  @override
  String uiCallAudioRoutedToValueFFFBE8(String value) {
    return '通话音频已切换到 $value。';
  }

  @override
  String uiCouldNotChangeCallAudio6CE7B1(String value) {
    return '无法更改通话音频输出：$value';
  }

  @override
  String uiCouldNotOpenInviteValue6C4D06(String value) {
    return '无法打开邀请：$value';
  }

  @override
  String uiCouldNotSendAttachmentValueEFF771(String value) {
    return '无法发送附件：$value';
  }

  @override
  String uiCouldNotSendMessageValue042C4F(String value) {
    return '无法发送消息：$value';
  }

  @override
  String get uiSendFromOriginalFFF29A => '从原文件发送';

  @override
  String uiCouldNotSendGroupMessageB6C7D1(String value) {
    return '无法发送群消息：$value';
  }

  @override
  String uiCouldNotSendLANLobby8E7487(String value) {
    return '无法发送局域网大厅消息：$value';
  }

  @override
  String uiCouldNotStageValuePathless514094(String value) {
    return '无法准备 $value：为保护内存，无路径拖入文件的大小上限为 8 MB。';
  }

  @override
  String get uiSelectAGroupBeforeDropping9DAB4C => '拖入文件前请先选择群组。';

  @override
  String uiValueLocalFilePathUnavailable217177(String value) {
    return '$value：本地文件路径不可用。';
  }

  @override
  String uiValueSentWithoutIt7E0635(String value) {
    return '$value 已在缺少该项的情况下发送。';
  }

  @override
  String get uiGroupFileScheduledB1DC66 => '群文件已定时发送。';

  @override
  String uiCouldNotScheduleValueValue25CED3(String value, String value2) {
    return '无法定时发送 $value：$value2';
  }

  @override
  String uiCouldNotOpenFilePicker8FF0C0(String value) {
    return '无法打开文件选择器：$value';
  }

  @override
  String uiValuePickerReturnedNoData4670CA(String value) {
    return '$value：选择器未返回数据。';
  }

  @override
  String uiOnlyTheFirstValueFiles45FC47(String value, String value2) {
    return '仅准备前 $value 个文件（共收到 $value2 个）。';
  }

  @override
  String uiValueSkippedValueMBExceeds487B2A(String value, String value2) {
    return '已跳过 $value：$value2 MB 超出 $value MB 上限。';
  }

  @override
  String get uiTransfers812412 => '传输';

  @override
  String uiValue75CED7(String value) {
    return '$value';
  }

  @override
  String get uiPreparingCallE86D6C => '正在准备通话…';

  @override
  String get uiCallingACD4A6 => '正在呼叫…';

  @override
  String get uiIncomingVoiceCallF68FD3 => '语音来电';

  @override
  String get uiConnectingFD3E79 => '正在连接…';

  @override
  String get uiReconnecting8A8B95 => '正在重新连接…';

  @override
  String get uiCallEnded9933A4 => '通话已结束';

  @override
  String uiVoiceCallValue06FE1F(String value) {
    return '语音通话：$value';
  }

  @override
  String get uiMinimizeCall6CB0F0 => '最小化通话';

  @override
  String get uiAcceptBB54DB => '接受';

  @override
  String get uiReject2B03B5 => '拒绝';

  @override
  String get uiNoiseSuppression71DE3C => '降噪';

  @override
  String get uiAudioOutput2B89CC => '音频输出';

  @override
  String get uiDoneE9B450 => '完成';

  @override
  String get uiHangUp66BE99 => '挂断';

  @override
  String get uiCloseDetails433DA6 => '关闭详情';

  @override
  String get uiOpenFullProfile35063C => '打开完整资料';

  @override
  String get uiOpenGroupSettings0B568E => '打开群设置';

  @override
  String get uiNewFolderA71199 => '新建文件夹';

  @override
  String get uiFolderNameB2CE02 => '文件夹名称';

  @override
  String get uiMoveEarlier07DD6F => '前移';

  @override
  String get uiMoveLaterBB4C84 => '后移';

  @override
  String get uiSaveEFC007 => '保存';

  @override
  String get uiAddToFolderBFAD96 => '添加到文件夹';

  @override
  String get uiNewMessage1ED2E7 => '新消息';

  @override
  String get uiBackToChats8DE6F6 => '返回聊天';

  @override
  String get uiNavigationMenu6609F1 => '导航菜单';

  @override
  String get uiAllChats398E5B => '所有聊天';

  @override
  String get uiSearchAllChatsC825C8 => '搜索所有聊天';

  @override
  String get uiClearSearch67300D => '清除搜索';

  @override
  String get uiContactRequests082691 => '联系人请求';

  @override
  String get uiReviewPeopleWhoWantTo24A8CB => '查看想与您联系的人';

  @override
  String get uiNoChatsFoundC6BD82 => '未找到聊天';

  @override
  String get uiNoArchivedChatsEAE7F0 => '没有已归档聊天';

  @override
  String get uiNoMatrixChatsYet23B023 => '暂无 Matrix 聊天';

  @override
  String get uiNewGroupF9850C => '新建群组';

  @override
  String get uiAddWithConestBeam19D1E2 => '通过 Conest Beam 添加';

  @override
  String get uiDirectMessagesE7596A => '私信';

  @override
  String get uiConestBeamE98B77 => 'Conest Beam';

  @override
  String get uiMyInviteF80A7A => '我的邀请';

  @override
  String get uiGroupDetailsDF844A => '群组详情';

  @override
  String get uiDebugBD604D => '调试';

  @override
  String get uiAdd61CC55 => '添加';

  @override
  String get uiPollRoutesNow22318F => '立即检查路由';

  @override
  String get uiContactProfile1B3A0E => '联系人资料';

  @override
  String get uiHistoryForNewMembersF419F2 => '新成员可见历史';

  @override
  String get uiChooseHowToWindDownF7399D =>
      '请选择如何结束此群组。转让群主后，群组将由新群主管理，您会成为管理员。为所有人删除会从每位成员的列表中移除此群组，且无法撤销。';

  @override
  String get uiTransferOwnershipA563C9 => '转让群主…';

  @override
  String get uiDeleteForEveryoneE055A8 => '为所有人删除';

  @override
  String get uiNoOtherActiveMembersToF9DE12 => '没有可接任群主的其他活跃成员。';

  @override
  String get uiTransferOwnershipA6819E => '转让群主';

  @override
  String get uiTransferCBB4CC => '转让';

  @override
  String uiOwnershipTransferredToValue14A10D(String value) {
    return '群主已转让给 $value。';
  }

  @override
  String get uiEveryMemberWillBeRemoved75A3FC =>
      '所有成员都会被移出，群组在各成员列表中将标记为已退出。本地消息历史不会自动删除；每位成员都可通过“从列表移除”来清除。此操作无法撤销。';

  @override
  String get uiRemoveThisGroup38C4E8 => '移除此群组？';

  @override
  String get uiRemoveThisGroupFromYourDA7898 =>
      '从您的列表中移除此群组？这将删除本地消息历史。其他成员不会收到通知，他们已看到您退出。';

  @override
  String get uiRemoveE96390 => '移除';

  @override
  String get uiChangeRole2B9BFD => '更改角色';

  @override
  String get uiRemoveMember1C31D1 => '移除成员';

  @override
  String get uiChooseWhatFutureMembersCanC38992 => '选择新成员可补阅的历史';

  @override
  String get uiAddMember170AD0 => '添加成员';

  @override
  String get uiDeleteGroup043336 => '删除群组…';

  @override
  String get uiLeave7E3520 => '退出';

  @override
  String get uiRemoveFromList23A976 => '从列表移除';

  @override
  String get uiForwardMessage482959 => '转发消息';

  @override
  String get uiSavedMessagesC0FA7E => '已保存消息';

  @override
  String get uiThisAttachmentIsNotAvailableFE641A => '此附件尚未在本地可用。';

  @override
  String get uiDownloadThisFileBeforeForwarding60D7B5 => '请先下载此文件再转发。';

  @override
  String get uiSearchMessagesABEA65 => '搜索消息';

  @override
  String get uiStartVoiceCallExperimental6DE320 => '发起语音通话（实验性）';

  @override
  String get uiChatOptionsA40D0F => '聊天选项';

  @override
  String get uiPausePreview805180 => '暂停预览';

  @override
  String get uiPlayPreview47BB44 => '播放预览';

  @override
  String get uiUnmutePreview12A31A => '开启预览声音';

  @override
  String get uiMutePreviewCE44BD => '静音预览';

  @override
  String get uiPauseVoiceMessageECD12D => '暂停语音消息';

  @override
  String get uiPlayVoiceMessageB16684 => '播放语音消息';

  @override
  String get uiPlaybackSpeed6FF42B => '播放速度';

  @override
  String get uiStopRecordingEE0D9D => '停止录音';

  @override
  String get uiDeleteRecording8B58CE => '删除录音';

  @override
  String uiCouldNotLoadOlderGroup1A192E(String value) {
    return '无法加载较早的群组历史：$value';
  }

  @override
  String uiMessageScheduledForValueD2D788(String value) {
    return '消息已定时至 $value。';
  }

  @override
  String get uiNewPoll6D62BD => '新建投票';

  @override
  String get uiQuestion002FF5 => '问题';

  @override
  String get uiOptionsOnePerLine62FF3D => '选项（每行一个）';

  @override
  String get uiDeleteMessageD536CF => '删除消息？';

  @override
  String get uiDeleteSelectedMessages190A5F => '删除所选消息？';

  @override
  String uiDeleteFailedForOneMessage26C302(String value) {
    return '一条消息删除失败：$value';
  }

  @override
  String get uiNothingToCopyFromTheEC27E3 => '所选消息中没有可复制的内容。';

  @override
  String uiCopiedValueMessageSC97E6E(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '已复制 $value 条消息。',
    );
    return '$_temp0';
  }

  @override
  String get uiNoSelectedAttachmentIsReady536B54 => '所选附件均尚未准备好，仍在传输。';

  @override
  String get uiCopiedMessageText9DC18F => '已复制消息文本。';

  @override
  String get uiTheGroupFileIsNotF8A236 => '群文件在本地不可用。';

  @override
  String uiSavedValue0463E5(String value) {
    return '已保存 $value。';
  }

  @override
  String uiCouldNotSaveValueValue178005(String value, String value2) {
    return '无法保存 $value：$value2';
  }

  @override
  String get uiTheAndroidFileSaverIsDF910B => 'Android 文件保存工具不可用。';

  @override
  String get uiOpeningFilesIsUnavailableOnC6ADA2 => '此平台无法打开文件。';

  @override
  String uiCouldNotOpenValueValue283326(String value, String value2) {
    return '无法打开 $value：$value2';
  }

  @override
  String get uiYou905CB3 => '您';

  @override
  String get uiMessage68F414 => '消息';

  @override
  String get uiMessageActions949184 => '消息操作';

  @override
  String get uiTheAttachmentIsStillDownloadingF77317 => '附件仍在下载。';

  @override
  String get uiShareOrScheduleAGroup2989F0 => '分享或定时发送群文件';

  @override
  String get uiRecordingBelongsToAnotherConversation87E802 => '录音属于另一个聊天';

  @override
  String get uiFinishTheVoicePreviewIn142571 => '请在原聊天中完成语音预览';

  @override
  String get uiReviewUnsentVoiceMessage24931C => '检查未发送的语音消息';

  @override
  String get uiCancelMicrophoneStartup9E9F8A => '取消启动麦克风';

  @override
  String get uiReleaseToDiscardRecording4C5C71 => '松开以丢弃录音';

  @override
  String get uiRecordingLockedTapToFinish40CD88 => '录音已锁定 · 点击结束';

  @override
  String get uiReleaseToStopSlideLeft4686F1 => '松开停止 · 左滑取消 · 上滑锁定';

  @override
  String get uiHoldToRecordAGroupC11B32 => '按住录制群语音消息';

  @override
  String get uiCreatePoll8F5663 => '创建投票';

  @override
  String get uiWriteToGroup5878DB => '向群组发送';

  @override
  String get uiWriteAReply0A58E1 => '撰写回复';

  @override
  String get uiYouAreNoLongerIn571DA7 => '您已不在此群组中';

  @override
  String get uiVote64F872 => '投票';

  @override
  String get uiChooseOptionsEA120E => '选择选项';

  @override
  String get uiRetractVoteA5DA11 => '撤回投票';

  @override
  String get uiClosePollA6A189 => '结束投票';

  @override
  String get uiScheduleOneAttachmentAtAC580C3 => '每次仅可定时发送一个附件。';

  @override
  String get uiNotDeliveredYetSendViaF056E1 => '尚未送达。通过 Matrix 发送…';

  @override
  String get uiVoiceCallsAreTurnedOff692843 => '语音通话已关闭。请在设置中开启后拨打。';

  @override
  String get uiVoiceCallAudioIsUnavailable0B6C43 => '此版本不支持通话音频。';

  @override
  String get uiRouteInspector0E65DE => '路由检查器';

  @override
  String get uiThisContactRequestIsBlocked944F7D => '此联系人请求已被屏蔽。';

  @override
  String get uiMessageSavedHereUntilTheA49A2C => '消息保存在此处，等待联系人接受。';

  @override
  String get uiWriteAnEncryptedMessage9F7705 => '撰写加密消息';

  @override
  String get uiWriteAReplyOrAddFC0A42 => '撰写回复或添加说明';

  @override
  String get uiHoldToRecordAVoice06B1B5 => '按住录制语音消息';

  @override
  String get uiWriteToNearbyLANUsers291142 => '向附近局域网用户发送';

  @override
  String get uiBroadcast77CA3F => '广播';

  @override
  String get uiThisRemovesTheLocalContact0D6D1E =>
      '这将删除本地联系人和消息历史。应用也会尝试发送移除通知，让对方的联系人列表中也移除此联系。';

  @override
  String get uiDescriptionBio505243 => '描述／简介';

  @override
  String get uiCheckPaths917FF3 => '检查路径';

  @override
  String get uiCopyState9BFD16 => '复制状态';

  @override
  String get uiRemoveContact7F9A8A => '移除联系人';

  @override
  String get uiSaveProfile909BF3 => '保存资料';

  @override
  String get uiShowAsBeam74375F => '以 Beam 显示';

  @override
  String get uiShowTheQRAnyway0B0CDF => '仍然显示二维码';

  @override
  String get uiOpenFullscreenQRC5418D => '全屏打开二维码';

  @override
  String get uiShowQRCFBAC6 => '显示二维码';

  @override
  String get uiLegacyInviteC61C5D => '旧版邀请';

  @override
  String get uiForContactsOnConestOr486754 =>
      '适用于使用 Conest 0.3.11 或更早版本的联系人。不含受阻网络的路由，这些路由将在连接后送达。';

  @override
  String get uiRotateCodephraseNow89B2D5 => '立即更换口令短语';

  @override
  String get uiEncryptForContactE07450 => '为联系人加密';

  @override
  String get uiPublicOpticalTransfer58E3F4 => '公开光学传输';

  @override
  String get uiAnyoneWhoCanSeeTheFAB2D0 => '任何看到屏幕的人都可重建此文件。文件已签名以验证完整性，但并不保密。';

  @override
  String get uiChoosePublicFile6E2739 => '选择公开文件';

  @override
  String get uiKeepThisScreenVisibleUntil2261B8 => '请保持此屏幕可见，直到接收方显示 100%。';

  @override
  String get uiReceiveConestBeamB05BCB => '接收 Conest Beam';

  @override
  String get uiDesktopCameraActiveDA0F15 => '桌面摄像头已启用';

  @override
  String get uiPasteOneCbFrame66EA2B => '粘贴一帧 cb1';

  @override
  String get uiAddFrame2BBA30 => '添加帧';

  @override
  String get uiContactAliasE07C25 => '联系人别名';

  @override
  String get uiWeComparedThisFingerprintIn952BEB => '我们已当面比对此指纹';

  @override
  String get uiTrustAndAddContact0962A2 => '信任并添加联系人';

  @override
  String get uiSavedInPrivateConestStorage4C1334 => '已保存到 Conest 私有存储：';

  @override
  String get uiResetIdentity8B0224 => '重置身份';

  @override
  String get uiThisClearsTheEncryptedVault864B3D =>
      '这将清空加密保险库，移除联系人和消息，并将应用恢复到首次启动状态。';

  @override
  String get uiReset44C57A => '重置';

  @override
  String get uiNoIdentityIsActive6B2EE3 => '没有已启用的身份。';

  @override
  String get uiSaveNameE73831 => '保存名称';

  @override
  String get uiSaveBioBE2711 => '保存简介';

  @override
  String get uiMessageNotifications595635 => '消息通知';

  @override
  String get uiShowASystemNotificationWhen90113B => '收到私信时显示系统通知。';

  @override
  String get uiExperimentalVoiceCalls51098B => '实验性语音通话';

  @override
  String get uiExperimentalAndroidBackgroundReceive60828A => '实验性 Android 后台接收';

  @override
  String get uiDisabledInReleaseBuildsThe45B7DF =>
      '正式版本中已禁用：前台服务尚未运行无界面的 Flutter 接收器。';

  @override
  String get uiAllowVoiceCallsInBackground73C5C5 => '允许后台语音通话';

  @override
  String get uiKeepsCallSignalingActiveAndC0A342 =>
      '在 Conest 服务运行时保持通话信令并显示通话通知。需要启用实验性语音通话；Android 电池策略或强行停止仍可能使其不可用。';

  @override
  String get uiDonTSendReadConfirmations230076 => '不发送已读回执';

  @override
  String get uiDebugOnlyDeliveryAcknowledgementsStill7D6A9C =>
      '仅用于调试。仍会发送送达回执，并处理收到的已读回执。';

  @override
  String get uiRemoveMetadataFromFilesA4860E => '移除文件元数据';

  @override
  String get uiBeforeSendingRemovesLocationCamera4E390D =>
      '发送前从照片、视频、PDF 和办公文档中移除位置、相机、作者和日期信息。图片不会重新压缩。其他文件按原样发送。';

  @override
  String get uiSendFilesUnderRandomNames5F79D4 => '使用随机文件名发送';

  @override
  String get uiReplacesFileNamesWithRandom16F099 =>
      '为您和接收方将文件名替换成随机字母，保留 .jpg 等扩展名。';

  @override
  String get uiKeepOfStorageFreeF00434 => '保留 10% 存储空间';

  @override
  String get uiReserveFreeSpaceForOther1AC9CF =>
      '为其他应用预留可用空间。关闭后传输可使用这部分空间，但文件仍必须能放入磁盘。';

  @override
  String get uiLAN2ECD17 => 'LAN';

  @override
  String get uiSameNetworkListenerPairingBeacons5CF0A2 => '同网络监听、配对信标和局域网送达。';

  @override
  String get uiOnlineC3E839 => '在线';

  @override
  String get uiIrohMessagingAndFileTransfersC4D635 =>
      '通过互联网使用 Iroh 消息和文件传输。自定义 Conest 中继为可选项。';

  @override
  String get uiIrohRelayFallbackE954F7 => 'Iroh 中继备用路径';

  @override
  String get uiUseIrohSBuiltIn631E03 => '直连不通时使用 Iroh 内置中继传输消息和文件。双方都需在线。';

  @override
  String get uiLimitIrohFilesToMiBB58353 => '将 Iroh 文件限制为 100 MiB（推荐）';

  @override
  String get uiAppliesToDirectOnlineAnd28F6F1 =>
      '适用于在线直连和 Iroh 中继传输。关闭后可传更大文件，但可能耗时较长。局域网传输仍保留较高上限。';

  @override
  String get uiShareEmailAndMatrixAddressesD762EE => '与群成员分享邮箱和 Matrix 地址';

  @override
  String get uiLetsMembersOfYourGroups9912A5 =>
      '允许非联系人的群成员通过邮箱或 Matrix 联系您。关闭后仅分享不透露姓名的 Nostr、Tor 和无线电地址。关闭只停止之后的分享，已看到地址的成员可能会保留它。';

  @override
  String get uiAutomaticDownloads5E777B => '自动下载';

  @override
  String get uiVerifiedContactsOnlyLimitsAdapt8A1876 =>
      '仅限已验证联系人。上限随 Wi-Fi／以太网、移动网络和漫游调整。';

  @override
  String get uiCustomIrohRelayURLsDBF979 => '自定义 Iroh 中继 URL';

  @override
  String get uiOneHTTPSURLPerLineDA8E70 => '每行一个 HTTPS URL；留空则使用标准 N0 中继。';

  @override
  String get uiSaveIrohRelaysC144AD => '保存 Iroh 中继';

  @override
  String get uiCheckAvailabilityFCC1A6 => '检查可用性';

  @override
  String get uiRunThisDeviceAsA9DEA14 => '将此设备用作中继';

  @override
  String get uiAllowTrustedContactsToUse001771 => '允许受信任联系人将此设备用作中继。';

  @override
  String get uiAutoUseContactsAsRelaysC62C06 => '自动将联系人用作中继';

  @override
  String get uiLocalRelayPort28A73C => '本地中继端口';

  @override
  String get uiSavePort1876F6 => '保存端口';

  @override
  String get uiRelayHostURLF11441 => '中继主机／URL';

  @override
  String get uiRelayPortEA05DA => '中继端口';

  @override
  String get uiDetectAddRelayE825AD => '检测并添加中继';

  @override
  String get uiErrorHistory25AFF8 => '错误历史';

  @override
  String get uiWhatWentWrongKeptAcross27FC1F => '此版本在重启后仍保留错误记录，可复制用于问题报告。';

  @override
  String get uiReceiveUnstableUpdatesBF7122 => '接收不稳定更新';

  @override
  String get uiAlsoOfferNightlyBuildsNewerA7FAB0 =>
      '同时提供每日构建：功能更新，测试较少。始终会提供更新的稳定版本。';

  @override
  String get uiResetAppIdentity2E0F86 => '重置应用身份';

  @override
  String get uiTrustNewKeyA181BE => '信任新密钥';

  @override
  String get uiVerifyThePersonAndCompare738F28 => '接受前请核实对方身份，并通过其他渠道比对安全号码。';

  @override
  String get uiReviewE29A79 => '查看';

  @override
  String get uiDiscardChat319267 => '丢弃聊天';

  @override
  String get uiConfirmIdentityReplacement0219C5 => '确认替换身份？';

  @override
  String get uiItSThem394960 => '是本人';

  @override
  String get uiRejectThisIdentityCB604F => '拒绝此身份？';

  @override
  String get uiThisDeletesTheNewContactBB4444 =>
      '这将删除新联系人及暂存的收到消息。若怀疑冒充身份，请使用此选项。';

  @override
  String get uiNotThem685593 => '不是本人';

  @override
  String get uiRemoveImportedList36FC81 => '移除导入列表？';

  @override
  String get uiNoBundledConestRelaysOnline46529B =>
      '未内置 Conest 中继。在线连接使用 Iroh；您也可配置自己的中继。';

  @override
  String get uiImportFromURL3F7B77 => '从 URL 导入…';

  @override
  String get uiImportRelayListFromURL86E363 => '从 URL 导入中继列表';

  @override
  String get uiJSONURL6918BA => 'JSON URL';

  @override
  String get uiOperatorSPublicKeyOptionalA80E7A => '运营者公钥（可选，base64）';

  @override
  String get uiImportD6FBC9 => '导入';

  @override
  String get uiCLEAN2F3D27 => '简洁';

  @override
  String get uiSUBTLEBB048B => '淡雅';

  @override
  String get uiDEFAULTC18920 => '默认';

  @override
  String get uiFULLCC0A74 => '完整';

  @override
  String get uiLANFirstB360D1 => '优先局域网';

  @override
  String get uiLANOnly94945D => '仅局域网';

  @override
  String get uiOnlineFirst346B6D => '优先在线';

  @override
  String get uiOnlineOnlyF79CB9 => '仅在线';

  @override
  String get uiOfflineE01FA7 => '离线';

  @override
  String get uiUsesLANWhenAvailableFallsA810EF => '局域网可用时使用局域网，否则使用在线连接。';

  @override
  String get uiUsesLANOnlyNoRelay589D55 => '仅使用局域网。此联系人的流量不经中继。';

  @override
  String get uiUsesOnlineWhenAvailableFallsCE2CAF => '在线连接可用时使用在线连接，否则使用局域网。';

  @override
  String get uiUsesOnlineOnlyNoLAN193810 => '仅使用在线连接。此联系人的流量不走局域网。';

  @override
  String get uiNoTransportSelectedThisContact7969EB => '未选择传输方式，无法联系此人。';

  @override
  String get uiGlobalConnectivityIsOffAdjustA7C644 => '全局连接已关闭，请在设置中调整后发送。';

  @override
  String get uiSameNetworkDelivery94E793 => '同网络送达';

  @override
  String get uiDisabledByGlobalSetting2CB06C => '已被全局设置禁用';

  @override
  String get uiAllowIrohRelayFallback35227B => '允许 Iroh 中继备用路径';

  @override
  String get uiVisibleAndOnlineOnlyDirectEA8902 => '可见且仅在线；优先使用 Iroh 直连。';

  @override
  String get uiRelayInternetDeliveryD64AB6 => '中继／互联网送达';

  @override
  String get uiPrefer13F662 => '优先';

  @override
  String get uiCarryTheirMessages22FD33 => '代转其消息';

  @override
  String get uiWhenThisContactCannotReach5C3FF8 =>
      '此联系人无法联系某人而您的设备可以时，代为转发消息。您仅能看到收件人和时间，内容仍然加密。';

  @override
  String uiSaveValueFileSToB46C57(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '将 $value 个文件保存到…',
    );
    return '$_temp0';
  }

  @override
  String get uiSaveCanceled1939D0 => '保存已取消。';

  @override
  String get uiAlbumActions7B6D70 => '相册操作';

  @override
  String get uiCancelSelectionF7F56C => '取消选择';

  @override
  String get uiCopyAF74F7 => '复制';

  @override
  String get uiSaveAttachments5A74EA => '保存附件';

  @override
  String get uiCancelAndClearAllTransfers01B81D => '取消并清除所有传输？';

  @override
  String get uiKeepTransfersDB8CC7 => '保留传输';

  @override
  String get uiCancelAndClearCCF59C => '取消并清除';

  @override
  String get uiPauseAll6F6099 => '全部暂停';

  @override
  String get uiResumeAll039916 => '全部继续';

  @override
  String get uiCancelAndClearAllTransfersACEBB3 => '取消并清除所有传输';

  @override
  String get uiClearCompletedE63FC1 => '清除已完成';

  @override
  String get uiMoveToTop44AFA6 => '移至顶部';

  @override
  String get uiPreparingDownloadF9B13B => '正在准备下载';

  @override
  String get uiDownloadA479C9 => '下载';

  @override
  String get uiResumeB3BD0B => '继续';

  @override
  String get uiPause781961 => '暂停';

  @override
  String get uiRetry9F5CD8 => '重试';

  @override
  String get uiContinueOverIrohRelay949702 => '通过 Iroh 中继继续';

  @override
  String get uiDownloadAnyway42859F => '仍然下载';

  @override
  String get uiPreparing96A9B7 => '正在准备';

  @override
  String get uiQueued6A5998 => '排队中';

  @override
  String get uiWaiting33D306 => '等待中';

  @override
  String get uiTransferring73F753 => '传输中';

  @override
  String get uiReconnecting9D80F9 => '重新连接中';

  @override
  String get uiPausedC7DFB6 => '已暂停';

  @override
  String get uiVerifying536244 => '正在校验';

  @override
  String get uiComplete1F5A1A => '已完成';

  @override
  String get uiCanceledF840AC => '已取消';

  @override
  String get uiUnavailable2C9C1F => '不可用';

  @override
  String uiSavedValueToValue08F152(String value, String value2) {
    return '已将 $value 保存到 $value2。';
  }

  @override
  String uiGallerySaveFailedValueFalling0B82BB(String value) {
    return '保存到图库失败（$value），改用文件对话框。';
  }

  @override
  String uiSaveValue5769AA(String value) {
    return '保存 $value';
  }

  @override
  String uiSaveFailedValue534182(String value) {
    return '保存失败：$value';
  }

  @override
  String get uiTheAttachmentFileIsNotA67009 => '附件文件在本地不可用。';

  @override
  String uiCopiedValueToClipboard669D0B(String value) {
    return '已将 $value 复制到剪贴板。';
  }

  @override
  String uiCopiedValueTextOnlySystemB51B8D(String value) {
    return '已复制“$value”（仅文本，系统二进制剪贴板不可用）。';
  }

  @override
  String uiCopyFailedValueFilenameCopiedF71C87(String value) {
    return '复制失败：$value。已改为复制文件名文本。';
  }

  @override
  String get uiCachePathIsNotReady0404B5 => '缓存路径尚未准备好，仍在传输。';

  @override
  String uiCachePathCopiedValue4CC1C4(String value) {
    return '已复制缓存路径：$value';
  }

  @override
  String get uiVideoIsnTCachedLocally8920DD => '视频尚未缓存到本地，请等待传输完成。';

  @override
  String uiCouldNotOpenVideoIn054087(String value) {
    return '无法在系统播放器中打开视频：$value';
  }

  @override
  String get uiImageIsNotAvailableLocally12017F => '图片在本地不可用。';

  @override
  String uiVideoStillTransferringValue3F4049(String value) {
    return '视频仍在传输（$value%）。';
  }

  @override
  String get uiVoiceMessageBytesAreNotF8339B => '语音消息数据尚未准备好。';

  @override
  String get uiSendMode265A2D => '发送模式';

  @override
  String get uiLANRelayA05D48 => '局域网中继';

  @override
  String get uiLobbyFDB6D9 => '大厅';

  @override
  String get uiDirectBC8152 => '直连';

  @override
  String get uiIroh84642D => 'Iroh';

  @override
  String get uiIrohRelayB128EA => 'Iroh 中继';

  @override
  String get uiRelay9F537F => '中继';

  @override
  String get uiMatrix58947E => 'Matrix';

  @override
  String get uiPlainMatrixBA9DE1 => '普通 Matrix';

  @override
  String get uiNostr4D3AD8 => 'Nostr';

  @override
  String get uiEmail84ADD5 => '电子邮件';

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
  String get uiViaContactCF1F8E => '经联系人';

  @override
  String get uiSendViaMatrix062A08 => '通过 Matrix 发送？';

  @override
  String get uiKeepWaiting9BE1AB => '继续等待';

  @override
  String get uiSendViaMatrix638038 => '通过 Matrix 发送';

  @override
  String uiNotSentViaMatrixValue99F62C(String value) {
    return '未通过 Matrix 发送：$value';
  }

  @override
  String get uiMessageRoutesFBF32C => '消息路由';

  @override
  String get uiWhatTheColouredMarksOnA10C8E => '消息上彩色标记的含义';

  @override
  String get uiOpenInDefaultPlayerE64C20 => '在默认播放器中打开';

  @override
  String get uiCancelReplyBD62D2 => '取消回复';

  @override
  String get uiScheduledMessages98CEF4 => '定时消息';

  @override
  String get uiEditScheduledMessage62AF88 => '编辑定时消息';

  @override
  String get uiCaption3428D9 => '说明';

  @override
  String get uiNoChatsToShareIntoB50F2F => '暂无可分享的聊天。';

  @override
  String get uiLetDevicesOnThisNetwork42E2F0 => '允许此网络中的设备访问此电脑';

  @override
  String get uiAllow3AD0E3 => '允许';

  @override
  String get uiKeepSignedIn611A13 => '保持登录';

  @override
  String get uiSignOutHereA6F129 => '在此设备退出';

  @override
  String get uiMatrixPassword34E218 => 'Matrix 密码';

  @override
  String get uiPassword8BE3C9 => '密码';

  @override
  String get uiYourServerAsksForIt1594FA => '服务器需要此密码以创建签名密钥。';

  @override
  String get uiRecoveryIsAlreadySetUp371F7F => '恢复功能已设置';

  @override
  String get uiOK9CE3BD => '确定';

  @override
  String get uiSaveYourRecoveryKey7851B3 => '保存恢复密钥';

  @override
  String get uiKeepThisKeySomewhereSafe0C0DFE =>
      '请将此密钥保存在安全的地方。在新设备上读取 Matrix 加密历史需要此密钥。密钥仅显示一次。';

  @override
  String get uiISavedIt3E2255 => '已保存';

  @override
  String get uiEnterRecoveryKey4521B6 => '输入恢复密钥';

  @override
  String get uiEsTFromAnotherMatrixAppFCA0C9 => 'EsT…（来自其他 Matrix 应用或本应用）';

  @override
  String get uiSignOutDC1649 => '退出登录';

  @override
  String get uiSetUpRecoveryFD3804 => '设置恢复';

  @override
  String get uiVerifyWithAnotherSession9ED031 => '通过其他会话验证';

  @override
  String get uiShowJoinsLeavesAndProfile9FA764 => '显示加入、退出及资料变更';

  @override
  String get uiInMatrixRoomsCollapsedIntoD20CAB => '在 Matrix 房间中折叠为一行';

  @override
  String get uiMatrixUser70A560 => 'Matrix 用户';

  @override
  String get uiForExampleNameMatrixOrg63C60A => '例如 @name:matrix.org';

  @override
  String get uiHomeserverOptional70DF85 => '主服务器（可选）';

  @override
  String get uiFoundFromTheUserId69A3AB => '留空时从用户 ID 查找';

  @override
  String get uiSignInToMatrix652C8F => '登录 Matrix';

  @override
  String get uiSignInWithBrowserC995DF => '通过浏览器登录';

  @override
  String get uiFinishSigningInInYour9F41A4 => '请在浏览器中完成登录。';

  @override
  String get uiCopyLink2F84EE => '复制链接';

  @override
  String get uiThisDeviceFA5A6D => '此设备';

  @override
  String uiOutOfTouchSinceValueA037FD(String value) {
    return '自 $value 起失联：确认此设备仍属于您之前，不会与之同步任何内容。';
  }

  @override
  String uiLinkedValueDCADF7(String value) {
    return '已关联 $value';
  }

  @override
  String get uiYourContactsWillStopAccepting5B0F03 =>
      '您的联系人将停止接受来自该设备的任何内容。它无法恢复，需作为新设备重新关联。';

  @override
  String get uiStillMine38C8AE => '仍属于我';

  @override
  String get uiRemoveDeviceA9C39D => '移除设备';

  @override
  String get uiLinkADeviceE71635 => '关联设备';

  @override
  String get uiLinkThisDeviceToMy888A1A => '将此设备关联到我的账号';

  @override
  String get uiCheckThatBothDevicesShow031E51 => '确认两台设备显示此验证码：';

  @override
  String get uiTheCodesMatch32C407 => '验证码相同';

  @override
  String get uiLinkedTheNewDeviceNow9900E5 => '已关联。新设备现在拥有您的账号和联系人，联系人会将其视为您。';

  @override
  String get uiConfirmTheCodeOnThe17BB1F => '也请在新设备上确认验证码。';

  @override
  String get uiWaitingForTheNewDevice75283F =>
      '正在等待新设备回应。若未出现验证码，请确认新设备仍在显示其验证码，且两台设备在同一网络中或均已联网。';

  @override
  String get uiOnTheNewDeviceOpen29AF5E =>
      '在新设备上打开“设置 → 设备 → 将此设备关联到我的账号”，然后扫描显示的验证码。';

  @override
  String get uiScanCode4596C2 => '扫描验证码';

  @override
  String get uiOrPasteTheCodeE72792 => '或粘贴验证码';

  @override
  String get uiLinkThisDeviceBF5E5C => '关联此设备';

  @override
  String get uiThisDeviceIsNowLinked7EA826 => '此设备现已关联到您的账号。';

  @override
  String get uiWaitingForTheOtherDeviceB39C3F => '正在等待另一台设备…';

  @override
  String get uiOnTheDeviceYouAlready92C421 =>
      '在您已使用的设备上打开“设置 → 设备 → 关联设备”并扫描此验证码。两台设备需在同一网络中或均已联网。';

  @override
  String get uiDeltaChat8BDA67 => 'Delta Chat';

  @override
  String get uiBitchatA99B50 => 'bitchat';

  @override
  String get uiWithAFilterOfTheir4FD18E => '带有各自的筛选器。关闭后仅可从对应网络的设置中打开。';

  @override
  String get uiYourDeltaChatInviteEE073F => '您的 Delta Chat 邀请';

  @override
  String get uiShowTheQRCodeTo0769AD =>
      '向 Delta Chat 用户展示二维码，或发送链接。任何持有邀请的人都可与您建立已验证聊天。';

  @override
  String get uiShowQRCode2DF2DD => '显示二维码';

  @override
  String get uiDeltaChatChats8EBCBC => 'Delta Chat 聊天';

  @override
  String get uiGroup171A06 => '群组';

  @override
  String get uiJoinWithAnInviteC76024 => '通过邀请加入';

  @override
  String get uiJoinE0D731 => '加入';

  @override
  String get uiNewDeltaChatGroup7D5142 => '新建 Delta Chat 群组';

  @override
  String get uiGroupNameEBB7E1 => '群名称';

  @override
  String get uiMembers1CB449 => '成员';

  @override
  String get uiGroupInviteD64669 => '群邀请';

  @override
  String get uiYouAreNotInThisCF5BD5 => '您不在此群组中';

  @override
  String get uiStartGroupCallC2A083 => '发起群通话';

  @override
  String get uiJoinGroupCallC9ECF8 => '加入群通话';

  @override
  String get uiPushToTalk032E78 => '按键说话';

  @override
  String get uiCarryMessagesOverAReticulum1CE915 =>
      '通过运行带 TCP 服务端接口的 rnsd 节点，经 Reticulum 网络传递消息，例如在无互联网时使用 LoRa 无线电（RNode）。Conest 使用独立的 Reticulum 身份，联系人会自动获知。';

  @override
  String get uiNodeAddressRnsdCD61E2 => '节点地址（rnsd）';

  @override
  String get uiUSBDeviceB47FF0 => 'USB 设备';

  @override
  String get uiRNodeAddress691283 => 'RNode 地址';

  @override
  String get uiBluetoothAddress0E2BED => '蓝牙地址';

  @override
  String get uiTCPPortDE05BE => 'TCP 端口';

  @override
  String get uiEU233558 => '欧盟 869.525';

  @override
  String get uiUS5ED166 => '美国 914.875';

  @override
  String get uiUseConestAsAMatrix6A44C5 => '仅将 Conest 用作 Matrix 客户端？';

  @override
  String get uiYourConestChatsAreHiddenCFD853 =>
      'Conest 聊天将隐藏，此设备上的 Conest 连接将暂停，直到您切换回来。不会删除任何内容。期间联系人无法通过 Conest 联系您；他们的应用会继续重试，并在您切换回来后送达。';

  @override
  String get uiSwitch3E44C9 => '切换';

  @override
  String get uiSealAnimatedRings29BE2D => '印章（动态圆环）';

  @override
  String get uiSigilRuneA0B8A7 => '符印（符文）';

  @override
  String get uiBlockiePixelHashA265BA => '像素图（像素哈希）';

  @override
  String get uiMonogramInitials8C6019 => '字母组合（首字母）';

  @override
  String get uiNewMatrixChatC065C8 => '新建 Matrix 聊天';

  @override
  String get uiNameMatrixOrgD0BB06 => '@name:matrix.org';

  @override
  String get uiStartChat18BB58 => '开始聊天';

  @override
  String get uiCopyText06A76C => '复制文本';

  @override
  String uiVerifyValue1B6B79(String value) {
    return '验证 $value';
  }

  @override
  String get uiAttachAFileAE85E4 => '添加文件';

  @override
  String get uiMessageDeleted3271A7 => '消息已删除';

  @override
  String get uiUnableToDecryptFDF88B => '无法解密';

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
  String get uiDeclineB59CF9 => '拒绝';

  @override
  String get uiCarryMessagesAsEncryptedEmail0D19EA =>
      '其他路由失败时，以加密邮件传递消息，类似 Delta Chat。邮件服务器可看到双方地址和时间，但看不到内容。联系人会自动获知您的地址。';

  @override
  String get uiUseMyOwnEmailAccountE78C1D => '改用自己的邮箱账号';

  @override
  String get uiNostrRelaysBD8BAD => 'Nostr 中继';

  @override
  String get uiCarryMessagesThroughPublicNostr729B94 =>
      '其他路由失败时，通过公开 Nostr 中继传递消息。中继可看到有人何时给您写信，但看不到是谁或写了什么。使用独立密钥，联系人会自动获知。';

  @override
  String get uiRelaysYouReadFromOne020C0A => '读取消息的中继（每行一个，最多 4 个）';

  @override
  String get uiSaveRelays91CBA8 => '保存中继';

  @override
  String get uiDefaultRelays5C909F => '默认中继';

  @override
  String get uiNewChat009BF6 => '新建聊天';

  @override
  String get uiNodeAddress896F20 => '节点地址';

  @override
  String get uiDeleteChatDB9121 => '删除聊天';

  @override
  String get uiTurnOnAppMessagesTo7DCA13 => '启用应用消息后可发送';

  @override
  String get uiBitchatNearbyD0C416 => '附近的 bitchat';

  @override
  String get uiMeshChat7BF668 => '网状网络聊天';

  @override
  String get uiHiddenTurnOnReachableBy0103C9 => '已隐藏：请开启“允许 bitchat 用户联系”';

  @override
  String get uiTheyDonTMatch27EF0C => '不相同';

  @override
  String get uiTheyMatch6FB8EB => '相同';

  @override
  String get uiNameBitchatUsersSee1CE7E3 => 'bitchat 用户看到的名称';

  @override
  String get uiANameYouChooseStays17E677 =>
      '您选择的名称在身份更改后仍会保留，附近的人可以据此认出您。留空则每次更换身份时都会生成新的“anon”名称。';

  @override
  String get uiBluetoothMeshC8B7F1 => '蓝牙网状网络';

  @override
  String get uiReachContactsNearbyWithoutAny9E9649 =>
      '无需网络即可联系附近的联系人：消息通过蓝牙在 Conest 和 bitchat 用户的设备间逐跳传递，此设备也会为他人转发。此设备不会显示在 bitchat 中，发出的消息与其他 bitchat 私信相同，标识符每小时更换。';

  @override
  String get uiReachableByBitchatUsers568021 => '允许 bitchat 用户联系';

  @override
  String get uiShareInternetWithBitchatUsers572F90 => '与 bitchat 用户共享网络';

  @override
  String get uiChangeNameE46692 => '更改名称';

  @override
  String get uiNewIdentityA119CF => '新身份';

  @override
  String get uiBitchatChatsC74EC3 => 'bitchat 聊天';

  @override
  String get uiTheMatrixClientIsNot01A5B4 =>
      '此设备不支持 Matrix 客户端，因此 Conest 无法在此处以仅 Matrix 模式运行。';

  @override
  String get uiUseConest12EEF3 => '使用 Conest';

  @override
  String get uiSearchRoomsCCE4F9 => '搜索房间';

  @override
  String get uiReachContactsThroughTorOnion8B8A98 =>
      '通过 Tor 洋葱服务联系联系人：双方和网络都无法获知对方的位置。速度比其他路由慢；Tor 被封锁时请添加网桥。';

  @override
  String get uiBridgesOptionalOnePerLine110291 => '网桥（可选，每行一个）';

  @override
  String get uiEEFEBFE80B7A =>
      '192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413';

  @override
  String get uiObfsEEFEAD0EDF =>
      'obfs4 192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413 cert=… iat-mode=0';

  @override
  String get uiLinesFromBridgesTorprojectOrgF08389 =>
      '来自 bridges.torproject.org 的网桥行，以类型开头：obfs4、webtunnel、snowflake 或 meek_lite（或普通网桥：地址和指纹）。';

  @override
  String get uiPlainBridgesOnlyAddressAnd7F0B60 => '此版本仅支持普通网桥（地址和指纹）。';

  @override
  String get uiUseTheseBridgesC1FA11 => '使用这些网桥';

  @override
  String get uiNostrPrivateMessagesDF74A3 => 'Nostr 私信';

  @override
  String get uiChatWithAnyoneOnNostrA867BC =>
      '与任何 Nostr 用户（0xchat、Amethyst、Damus 及其他使用 NIP-17 的应用）私聊或小群聊天。使用独立的 Nostr 账号，与 Conest 联系人无关。端到端加密，但不具备前向保密。';

  @override
  String get uiYourNostrAddress5CF7C6 => '您的 Nostr 地址';

  @override
  String get uiCopyWithYourRelaysD49669 => '复制（含您的中继）';

  @override
  String get uiNostrChats3D786C => 'Nostr 聊天';

  @override
  String get uiNewNostrChat68199C => '新建 Nostr 聊天';

  @override
  String get uiNpubSeveralForAGroupE6ED77 => 'npub1…（多个地址可建群）';

  @override
  String get uiCarryShortMessagesOverAFA94B6 =>
      '无需互联网，通过配套无线电经 MeshCore LoRa 网状网络传递短消息。Conest 会将联系人添加到无线电中，使其接受他们的消息。';

  @override
  String get uiMessagesWithMeshCoreAppUsersDE77BA => '与 MeshCore 应用用户收发消息';

  @override
  String get uiReadAndWriteTheMeshCore98E60E =>
      '通过此无线电收发 MeshCore 应用的消息：与其联系人私聊，或在频道中群聊。仅采用 MeshCore 提供的保护。';

  @override
  String get uiMeshCoreChats82C29C => 'MeshCore 聊天';

  @override
  String get uiSendWithItsDetailsF287FB => '连同其信息发送？';

  @override
  String get uiSendAnyway911263 => '仍然发送';

  @override
  String get uiSaveTheErrorHistory0B3413 => '保存错误历史';

  @override
  String uiSavedTheErrorHistoryTo5271C5(String value) {
    return '错误历史已保存到 $value。';
  }

  @override
  String uiSavingTheErrorHistoryFailed72A33A(String value) {
    return '保存错误历史失败：$value';
  }

  @override
  String get uiSaveToAFile5BB648 => '保存到文件';

  @override
  String get uiClear719EA3 => '清除';

  @override
  String get uiFilterD7DECF => '筛选';

  @override
  String get uiErrorsOnlyHideTheDebugECA1DD => '仅错误（隐藏调试日志）';

  @override
  String uiValueH171B92(String value) {
    return '$value 小时';
  }

  @override
  String uiValueMin439C52(String value) {
    return '$value 分钟';
  }

  @override
  String uiTheirClockIsAboutValueF406F1(String value) {
    return '对方时钟相差约 $value $value；此处时间以本设备为准。';
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
  String get uiSent27E770 => '已发送';

  @override
  String get uiWaitingOnTheRelayED66FF => '在中继等待';

  @override
  String get uiReachedTheirDevice0FE289 => '已到达对方设备';

  @override
  String get uiDeliveredF81891 => '已送达';

  @override
  String get uiReceived38428A => '已接收';

  @override
  String get uiCarryShortMessagesOverADD8570 =>
      '无需互联网，通过 Meshtastic 无线电经 LoRa 网状网络传递短消息。联系人需使用 Conest，并有处于同一网状网络中的无线电。';

  @override
  String get uiFindDevices98771A => '查找设备';

  @override
  String get uiRadioAddressD288E6 => '无线电地址';

  @override
  String get uiMessagesWithMeshtasticAppUsers812B3A => '与 Meshtastic 应用用户收发消息';

  @override
  String get uiReadAndWriteTheMeshtastic995E5D =>
      '通过此无线电收发 Meshtastic 应用的消息：包括私信和作为群聊的频道。仅采用 Meshtastic 提供的保护。';

  @override
  String get uiMeshtasticChats46BEF8 => 'Meshtastic 聊天';

  @override
  String get uiClearSelection247FD6 => '清除选择';

  @override
  String get uiBrowseFilesAF7C13 => '浏览文件…';

  @override
  String get uiSelectMoreE38EF3 => '选择更多';

  @override
  String get uiAllowAllA16326 => '全部允许';

  @override
  String get uiCaptionDA5C59 => '说明…';

  @override
  String get uiOpenSettingsFD7108 => '打开设置';

  @override
  String get uiDiscardChangesD3F0B4 => '放弃更改？';

  @override
  String get uiYourEditsWillBeLostB34663 => '您的编辑将丢失，原图仍保留在图库中。';

  @override
  String get uiKeepEditingD4D9E3 => '继续编辑';

  @override
  String get uiDiscard36FFF6 => '放弃';

  @override
  String get uiRotateLeft6F72F3 => '向左旋转';

  @override
  String get uiRotateRightB75F23 => '向右旋转';

  @override
  String get uiApplyCropA43CCF => '应用裁剪';

  @override
  String get uiCropC5DB3D => '裁剪';

  @override
  String get uiVerifiedDownloadProgressBED7C2 => '已校验下载进度';

  @override
  String get uiSharingWithGroup2AED71 => '正在与群组共享';

  @override
  String get uiOpenCF9B77 => '打开';

  @override
  String get uiStopSharing0E45AE => '停止共享';

  @override
  String get uiRemoveLocalCopy80FA01 => '移除本地副本';

  @override
  String get uiScanInviteEFC78A => '扫描邀请';

  @override
  String uiValueValue176D15(String value, String value2) {
    return '$value:$value2';
  }

  @override
  String uiDefaultRelayValueBD3FD1(String value) {
    return '默认中继 $value';
  }

  @override
  String uiSamplesValueSlowOverMsValueAE2EBF(String value, String value2) {
    return 'samples=$value slowOver100ms=$value2 maxTotalMs=$value maxBuildMs=$value maxRasterMs=$value';
  }

  @override
  String get uiConversation2A20C7 => '会话';

  @override
  String uiSharedValueWithTheGroup163418(String value) {
    return '已将 $value 作为普通附件分享给群组；部分成员需更新应用才能播放语音。';
  }

  @override
  String uiSharedValueWithTheGroupAE4134(String value) {
    return '已将 $value 分享给群组。';
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
  String get uiNone3C6B18 => '（无）';

  @override
  String uiLANNodeValueOn5D539E(String value) {
    return '局域网节点 :$value 已启用';
  }

  @override
  String get uiLANNodeUnavailable9CFA32 => '局域网节点不可用';

  @override
  String uiLANValueA8EEF3(String value) {
    return 'LAN $value';
  }

  @override
  String uiRelayValueDownD6B267(String value) {
    return '中继 $value 不可用';
  }

  @override
  String uiRelayValueA6D70A(String value) {
    return '中继 $value';
  }

  @override
  String get uiNoInternetRelay55D2CE => '无互联网中继';

  @override
  String uiValueValue42DC94(String value, String value2) {
    return '$value=$value2';
  }

  @override
  String uiValueHasBeenOutOf039D48(String value) {
    return '$value 已失联一段时间：在“设置 → 设备”中确认之前，不会与之同步任何内容。';
  }

  @override
  String uiValueIsOneOfYourE4FD9C(String value) {
    return '$value 现已是您自己的设备，其旧聊天不再列出。';
  }

  @override
  String uiYourDevicesDisagreeOnWhich2E7001(String value) {
    return '您的设备对账号中的设备名单存在分歧，合并后将超过 $value 台。请在“设置 → 设备”中移除一台。';
  }

  @override
  String uiValueAddedADeviceValue710908(String value, String value2) {
    return '$value 添加了设备：$value2。';
  }

  @override
  String uiUnknownValue9B520C(String value) {
    return '未知 $value';
  }

  @override
  String uiReadByAllValue43BA5A(String value) {
    return '全部 $value 人已读';
  }

  @override
  String uiDeliveredToAllValue71E077(String value) {
    return '已送达全部 $value 人';
  }

  @override
  String uiAcceptedByValueOfValue826A0E(String value, String value2) {
    return '$value/$value2 人已接受';
  }

  @override
  String uiWaitingForValueMemberS5A8BA6(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '正在等待 $value 位成员',
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
    return '已跳过 $value：$value2 MB 超出 $value3 MB 上限。';
  }

  @override
  String get uiRoute499952 => '路由';

  @override
  String get uiSafetyNumber5ED2D3 => '安全号码';

  @override
  String get uiIrohEndpoint72F674 => 'Iroh 端点';

  @override
  String get uiDeviceA5A74A => '设备';

  @override
  String get uiLANLobbyC16DC8 => '局域网大厅';

  @override
  String uiMembersValue541E72(String value) {
    return '成员 · $value';
  }

  @override
  String get uiNodeOnlineFAC64A => '节点 · 在线';

  @override
  String uiSafetyValueC542B8(String value) {
    return '安全 $value';
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
      other: '$value 位成员',
    );
    return '$_temp0';
  }

  @override
  String get uiPairwise64A0EF => '两两加密';

  @override
  String get uiPasteMedia4831DE => '粘贴媒体';

  @override
  String get uiRELAYA1C0CF => '中继';

  @override
  String get uiSentAsAPlainMatrixAAE694 => '已作为普通 Matrix 消息发送';

  @override
  String get uiOnlyOnThisDevice7D64C4 => '仅在此设备';

  @override
  String get uiConnectivityIsOffTurnOnE42D4A => '连接已关闭。请启用局域网或在线连接以交换此邀请。';

  @override
  String get uiConnectivityIsOffTurnOnFA573F => '连接已关闭。分享邀请前请先启用局域网或在线连接。';

  @override
  String get uiReceiveBeam2CB58B => '接收 Beam';

  @override
  String get uiSendEncryptedFile99D424 => '发送加密文件';

  @override
  String get uiSendPublicFileF81389 => '发送公开文件';

  @override
  String get uiBeamContactInvite2BAB4C => 'Beam 联系人邀请';

  @override
  String get uiDevicesDF485C => '设备';

  @override
  String get uiWARNC2FD77 => 'WARN';

  @override
  String get uiDOWN30E504 => 'DOWN';

  @override
  String get uiAVGRTTE96B26 => 'AVG RTT';

  @override
  String uiRoutingValueFC4557(String value) {
    return '路由 — $value';
  }

  @override
  String uiActiveValueC78B63(String value) {
    return '活跃（$value）';
  }

  @override
  String uiRecentValueB82237(String value) {
    return '最近（$value）';
  }

  @override
  String get uiDirect24A173 => '直连';

  @override
  String get uiRelayBD28B2 => '中继';

  @override
  String get uiRoutingECF60A => '路由中';

  @override
  String uiInvitationValue6F0633(String value) {
    return '邀请：$value';
  }

  @override
  String get uiMeshChatNearbyA35A63 => '网状网络聊天（附近）';

  @override
  String get uiVerifiedWithAnInviteBD826F => '通过邀请验证';

  @override
  String get uiHoldToTalkOrHold74FC22 => '按住说话，或按住空格键';

  @override
  String get uiEndToEndEncryptedMatrix9E4418 => '端到端加密（Matrix）';

  @override
  String get uiVerifiedAED3B8 => '已验证';

  @override
  String uiValueValue64684F(String value, String value2) {
    return '$value · $value2';
  }

  @override
  String get uiPrimaryChannel53B8E1 => '主频道';

  @override
  String uiChannelValue76ED1D(String value) {
    return '频道 $value';
  }

  @override
  String get uiPublicChannelA9795B => '公开频道';

  @override
  String get uiDescriptionCB3291 => '描述';

  @override
  String uiTheirClockIsAboutValue7DB956(String value, String value2) {
    return '对方时钟相差约 $value $value2；此处时间以本设备为准。';
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
  String get uiConestTransfer406028 => 'Conest 传输';

  @override
  String uiValueConestTransfersF846F8(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value 项 Conest 传输',
    );
    return '$_temp0';
  }

  @override
  String uiViaValueValue37232D(String value, String value2) {
    return '经 $value（$value2）';
  }

  @override
  String get uiBackThroughTheContactWhoD09BD0 => '通过代转其消息的联系人返回';

  @override
  String uiConestRelayValue4FB2DB(String value) {
    return 'Conest 中继 $value';
  }

  @override
  String get uiConestIsAlreadyRunningEE8037 => 'Conest 已在运行';

  @override
  String get uiCloseTheExistingConestWindow83B30B =>
      '请先关闭已有的 Conest 窗口。第二个实例会争用本地中继端口和加密保险库。';

  @override
  String get uiChooseWhereConestStoresData0CF613 => '选择 Conest 的数据存储位置';

  @override
  String get uiGhostModeIsBestEffort694912 =>
      '幽灵模式尽力保护隐私：系统启动历史、崩溃日志、网络元数据、命令行历史、最近文件和平台缓存不受应用控制。';

  @override
  String get uiDefaultOnThisDevice10343F => '此设备的默认位置';

  @override
  String get uiUseTheNormalAppDataF44F79 => '使用常规应用数据文件夹，选择自动解锁时使用此设备的钥匙串。';

  @override
  String get uiGhostPortableBesideTheApp31A40D => '幽灵／便携模式，位于应用旁';

  @override
  String get uiStoreConestControlledFilesIn7DA307 =>
      '将 Conest 管理的文件存储在应用旁的 conest_data 文件夹中。';

  @override
  String get uiVaultUnlock602BF6 => '保险库解锁方式';

  @override
  String get uiKeyFileAutoUnlock66AC4A => '通过密钥文件自动解锁';

  @override
  String get uiKeepsTheKeyBesideTheB045D9 => '将密钥保存在保险库旁。任何获得该文件夹的人都可打开。';

  @override
  String get uiAutoUnlockWithThisDeviceE7F781 => '使用此设备自动解锁';

  @override
  String get uiStoresTheVaultKeyInC7B1CD => '将保险库密钥保存在平台安全存储中。';

  @override
  String get uiPassphraseUnlock13B14C => '通过口令解锁';

  @override
  String get uiAskForAPassphraseOn4BA25C => '每次启动时要求输入口令。忘记口令将无法恢复。';

  @override
  String get uiUnlockConest033EB6 => '解锁 Conest';

  @override
  String get uiEnterThePassphraseForThis891200 => '请输入此保险库的口令。';

  @override
  String get uiNoUpdateIsAvailableRightA5EB48 => '当前没有可用更新。';

  @override
  String uiValueIsAvailableOnTheD338C4(String value, String value2) {
    return '$value 已在 $value2 渠道可用。';
  }

  @override
  String uiCurrentBuildValue2FD415(String value) {
    return '当前版本：$value';
  }

  @override
  String get uiWhatSNew4D8DC5 => '更新内容';

  @override
  String get uiSERVERLESSSECUREMESSENGER1E1891 => '◢ 无服务器安全通信';

  @override
  String uiYourMatrixSessionValueWants580E45(String value) {
    return '您的 Matrix 会话 $value 希望验证此会话。仅在您主动发起时接受。';
  }

  @override
  String uiValueWantsToVerifyYou61FD9D(String value) {
    return '$value 希望通过比对表情符号验证您。请检查完整地址，谨防相似地址。仅在能当面或通话比对时接受；验证会将对方密钥标记为可信。';
  }

  @override
  String uiCouldNotVerifyValue3AE1C4(String value) {
    return '无法验证：$value';
  }

  @override
  String get uiSendWithoutResumableCopy0475F4 => '不保留可续传副本而发送？';

  @override
  String uiValueCouldNotBeCopied06F61A(
    String value,
    String value2,
    String value3,
  ) {
    return '无法将 $value 复制到私有传输存储。\n\n$value2\n\n应用可直接读取原文件，但如果文件被移动或访问权限过期，重启后将无法继续传输。$value3';
  }

  @override
  String get uiUnmute7044C3 => '取消静音';

  @override
  String get uiMute0F0973 => '静音';

  @override
  String get uiSpeakerOn93982E => '扬声器已开启';

  @override
  String get uiSpeakerOff97823A => '扬声器已关闭';

  @override
  String get uiCancelCallCE6C16 => '取消通话';

  @override
  String uiValueValueReturnToCall49F82C(String value, String value2) {
    return '$value$value2 · 返回通话';
  }

  @override
  String get uiContactDetailsD4EC65 => '联系人详情';

  @override
  String uiValueActiveMemberValue6700F2(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value 位活跃成员',
    );
    return '$_temp0';
  }

  @override
  String get uiOwner89FF31 => '群主';

  @override
  String uiEditValue75BE00(String value) {
    return '编辑 $value';
  }

  @override
  String uiCouldNotSaveChatSettings2372B2(String value) {
    return '无法保存聊天设置：$value';
  }

  @override
  String get uiAddAContactToStart165431 => '添加联系人以开始聊天';

  @override
  String get uiNoContactsFound816015 => '未找到联系人';

  @override
  String uiOpenValue8DF02B(String value) {
    return '打开 #$value';
  }

  @override
  String get uiNoMessagesYetC04921 => '暂无消息';

  @override
  String get uiNoActivityYetPairA7F5366 => '暂无活动；配对联系人后开始记录。';

  @override
  String get uiSENT5AD0CD => '已发';

  @override
  String get uiRECVBFC296 => '已收';

  @override
  String uiDeviceValue11AEA9(String value) {
    return '设备 $value';
  }

  @override
  String get uiFreeForAllLocalChat5485CC => '开放本地聊天 • 不可信';

  @override
  String get uiGroupsAE9629 => '群组';

  @override
  String get uiAddTrustedContactsBeforeCreating1084CC => '创建群组前请先添加受信任联系人。';

  @override
  String get uiNoGroupsYet5009C6 => '暂无群组。';

  @override
  String uiValueMemberSE75249(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value 位成员',
    );
    return '$_temp0';
  }

  @override
  String get uiContactsB0DD61 => '联系人';

  @override
  String get uiAppliesToFutureAdmissionsHistory78E3A0 =>
      '适用于以后加入的成员。已接收的历史无法撤回。';

  @override
  String uiValueAllRetainedHistory5E25F4(String value) {
    return '$value全部保留历史';
  }

  @override
  String uiValueSinceAdmissionB2617B(String value) {
    return '$value自加入起';
  }

  @override
  String uiDeleteValueF0396B(String value) {
    return '删除“$value”';
  }

  @override
  String uiDeleteValueForEveryone12E724(String value) {
    return '为所有人删除“$value”？';
  }

  @override
  String uiValueMemberSOwnerValueE42E13(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value 位成员 • 群主 $value2',
    );
    return '$_temp0';
  }

  @override
  String get uiGROUPTRUSTFANOUTMintPaired5DDF6E =>
      '// GROUP TRUST FANOUT · mint = paired';

  @override
  String get uiAddTrustedContact126717 => '添加受信任联系人';

  @override
  String get uiNoAvailableChats1FAA40 => '没有可用聊天';

  @override
  String get uiForwardedMessageQueuedC82DA4 => '转发消息已排队';

  @override
  String uiCouldNotForwardValue80193D(String value) {
    return '无法转发：$value';
  }

  @override
  String get uiForwardedAttachmentQueued57C88B => '转发附件已排队';

  @override
  String uiCouldNotForwardAttachmentValue5165FD(String value) {
    return '无法转发附件：$value';
  }

  @override
  String get uiChatDetails15DAEC => '聊天详情';

  @override
  String get uiConnectionDetailsAB30A5 => '连接详情';

  @override
  String uiValueValue270519(String value, String value2) {
    return '$value / $value2';
  }

  @override
  String uiVoiceMessageValue2F0300(String value) {
    return '语音消息 · $value';
  }

  @override
  String uiPlaybackFailedValue1C0E1A(String value) {
    return '播放失败：$value';
  }

  @override
  String get uiPreparingMicrophone0BBF4A => '正在准备麦克风…';

  @override
  String get uiPreparingPreview312E7B => '正在准备预览…';

  @override
  String uiVoiceMessagePreviewValue8235CB(String value) {
    return '语音消息预览 · $value';
  }

  @override
  String uiRecordingValueValue111FF1(String value, String value2) {
    return '录音中$value · $value2';
  }

  @override
  String get uiSendingCF7655 => '正在发送…';

  @override
  String uiValue72F816(String value) {
    return '$value×';
  }

  @override
  String get uiSingleChoice68E3E0 => '单选';

  @override
  String get uiMultipleChoiceB88936 => '多选';

  @override
  String uiThisRemovesTheMessageFor2247A2(String value) {
    return '群成员同步时将删除此消息。$value';
  }

  @override
  String get uiCouldNotLocateThisMessage220E83 => '无法在当前聊天中找到此消息';

  @override
  String uiDeleteValueMessageValueForABA7AC(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '为群组删除 $value 条消息？',
    );
    return '$_temp0';
  }

  @override
  String uiValueValue29C8B9(String value, String value2) {
    return '$value $value2';
  }

  @override
  String get uiNewC2A6B0 => '新';

  @override
  String get uiEditedA22FCA => '已编辑';

  @override
  String get uiCopyCachePathC23134 => '复制缓存路径';

  @override
  String get uiStopKeepingOfflineAABFC7 => '停止离线保留';

  @override
  String get uiKeepOffline123286 => '离线保留';

  @override
  String get uiForwardFileC4B5CB => '转发文件';

  @override
  String get uiLoadingHistory02CB12 => '正在加载历史…';

  @override
  String get uiLoadOlderMessages07471F => '加载更早消息';

  @override
  String get uiShareFileNow96E2A2 => '立即分享文件';

  @override
  String get uiScheduleFile690A92 => '定时发送文件';

  @override
  String get uiDropToShareThisFile0B73E8 => '松开以将文件分享给群组';

  @override
  String get uiClosed88D86B => '已结束';

  @override
  String get uiVisibleVotes460E7A => '公开投票';

  @override
  String uiValueVoteSWereNot02CC9A(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '发起者的结束记录未包含 $value 票。',
    );
    return '$_temp0';
  }

  @override
  String get uiVotingIsUnavailableWithThis9B92E7 => '此 Conest 版本不支持投票。';

  @override
  String get uiThisRemovesTheMessageHere61D27C => '这会在此处删除消息，并在可联系到对方时请求其删除副本。';

  @override
  String get uiThisRemovesTheMessageFrom6A47E2 => '这会从此设备删除消息。';

  @override
  String get uiSendViaMatrix3868FE => '通过 Matrix 发送…';

  @override
  String get uiNotesFilesAndForwardsOnlyB0145F => '笔记、文件和转发，仅保存在此设备';

  @override
  String uiValueSafetyValue82C755(String value, String value2) {
    return '$value • 安全 $value2';
  }

  @override
  String uiDropFilesToSendMax106011(String value) {
    return '拖入文件以发送（上限 $value）';
  }

  @override
  String get uiFreeForAllLocalChatBC90D2 => '开放本地聊天。消息带有会话签名，但此处参与者并非受信任联系人。';

  @override
  String get uiNoLANLobbyMessagesYetBCDC4B =>
      '局域网大厅暂无消息。附近的 Conest 设备处于此局域网时会收到消息。';

  @override
  String uiValueUntrusted519A32(String value) {
    return '$value • 不可信';
  }

  @override
  String uiRemoveValueF4FE4B(String value) {
    return '移除 $value？';
  }

  @override
  String get uiAvailablePaths6EE503 => '可用路径';

  @override
  String get uiRunACheckToMeasure5D76A5 =>
      '运行检查以测量延迟、可用性和可达状态的新鲜度。路径优先按最佳直连／局域网排序，再列备用中继。';

  @override
  String get uiNoRouteHintsAreAdvertisedB25540 => '此联系人未公布路由信息。';

  @override
  String get uiEitherInputIsEnoughOn020B90 =>
      '任选一种方式即可。扫描或粘贴二维码邀请以直接信任，或仅输入当前口令短语，通过附近局域网或已配置中继发现发送者。若自动交换失败，应用会建议请对方反向添加您，或中止。';

  @override
  String get uiInvitePreview6433A0 => '邀请预览';

  @override
  String uiValueValueValue98AECE(String value, String value2, String value3) {
    return '$value$value2 • $value3';
  }

  @override
  String get uiShareInviteDBCC1E => '分享邀请';

  @override
  String get uiThisInviteWorksOnlyOnB106B0 =>
      '此邀请仅适用于同一网络：未启用互联网路由。请在“设置 → 连接”启用 Iroh 中继、Conest 中继或其他传输方式（Nostr、邮件），联系人即可从任何地方添加您。';

  @override
  String get uiThisInviteAlsoListsYourEF3A4F =>
      '此邀请还包含受阻网络的路由，单个二维码无法容纳。请以 Beam 显示，另一台相机可在几秒内读取其动态二维码。';

  @override
  String get uiQRRenderingIsDeferredOn8A6997 => 'Windows 上暂缓渲染二维码。';

  @override
  String get uiUseTheCodephraseBelowOrB6A588 => '请使用下方口令短语，或在此页面打开后再渲染二维码。';

  @override
  String get uiScanningTheCompactQRIs9459D9 =>
      '单独扫描紧凑二维码即可。若相机仍难以识别，请全屏打开或仅使用当前口令短语。';

  @override
  String uiQRPayloadValueCharactersBABEDF(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '二维码内容：$value 个字符',
    );
    return '$_temp0';
  }

  @override
  String uiAlsoListsYourAddressesOnC5D815(String value) {
    return '也包含您在以下网络的地址：$value。';
  }

  @override
  String uiPinnedValue834309(String value) {
    return '已固定 · $value';
  }

  @override
  String get uiNoVerifiedCiContactsAre3FD190 => '暂无已验证的 ci6 联系人。';

  @override
  String get uiCloseUpTransferE6BA46 => '近距离传输';

  @override
  String get uiALoopingLTFountainStream840218 =>
      '循环 LT 喷泉码流可容忍二维码帧丢失、重复或乱序。接受文件前会校验最终文件的哈希。';

  @override
  String get uiPUBLICVisibleToAnyoneNearbyA775C2 => '公开 · 附近任何人均可查看';

  @override
  String get uiCONTACTENCRYPTED879896 => '为联系人加密';

  @override
  String get uiSIGNEDCONTACTINVITE752317 => '已签名联系人邀请';

  @override
  String uiFrameValueValueSourceBlocks9C37CB(
    String value,
    int value2,
    String value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value2,
      locale: localeName,
      other: '帧 $value · $value2 个源数据块 · $value3',
    );
    return '$_temp0';
  }

  @override
  String get uiPointThisCameraAtThe2EA3F7 =>
      '将此相机对准动态 Beam 二维码。原生扫描器仅输出已解码的 cb1 帧。';

  @override
  String get uiNativeDesktopCameraCaptureIs4619C8 =>
      '桌面原生相机采集不可用。请在下方粘贴 cb1 帧，协议解码和验证流程相同。';

  @override
  String uiValueValueBlocksValueFrames66F819(
    String value,
    String value2,
    String value3,
    String value4,
  ) {
    return '$value/$value2 个数据块 · $value3 帧 · $value4 个无效';
  }

  @override
  String get uiSignedContactInviteA7CC8B => '已签名联系人邀请';

  @override
  String get uiPUBLICUNTRUSTEDTheSignatureProves96FA7F =>
      '公开／不可信。签名仅证明所有帧来自同一个密钥，并不能证明密钥的所有者身份。';

  @override
  String get uiEncryptedAndAuthenticatedAsA68B7E4 => '已加密并验证为固定的 Conest 联系人。';

  @override
  String get uiSignatureValidCompareTheFingerprintA8A1FE => '签名有效。请当面比对指纹。';

  @override
  String get uiAcceptAndSavePublicFile852517 => '接受并保存公开文件';

  @override
  String get uiSaveFileBEDC84 => '保存文件';

  @override
  String get uiFullscreenCompactInviteQRCF6B8B => '全屏紧凑邀请二维码';

  @override
  String uiValueCharactersIncreaseScreenBrightnessA5AF7D(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value 个字符。若扫描不稳定，请提高屏幕亮度。',
    );
    return '$_temp0';
  }

  @override
  String get uiPersonalPreferencesBD0D61 => '个人／偏好';

  @override
  String get uiNetworkRelay4F9A27 => '网络／中继';

  @override
  String get uiDanger58D175 => '危险操作';

  @override
  String get uiAllowsOneToOneIroh45EEF1 =>
      '允许在此设备上进行一对一 Iroh 语音通话。关闭后将停止拨打和接听。';

  @override
  String get uiPrivacyOfFilesYouSend4E4A5B => '所发文件的隐私';

  @override
  String get uiLowA12494 => '低';

  @override
  String get uiMediumD40496 => '中';

  @override
  String get uiHighB1A595 => '高';

  @override
  String get uiTransportPolicy088D79 => '传输策略';

  @override
  String get uiPerContactRoutingIsIntersected88E292 =>
      '每个联系人的路由都会受这些选项约束。关闭任一项会限制流量，全部关闭则使应用停止收发。';

  @override
  String get uiConnectivityIsFullyOffTheB12483 => '所有连接已关闭，应用将不再收发。';

  @override
  String uiValueCandidateRouteSAre175673(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '当前有 $value 条候选路由可用。',
    );
    return '$_temp0';
  }

  @override
  String get uiConfiguredRelays3CA0DE => '已配置中继';

  @override
  String get uiNoRelaysAddedYetF791E7 => '尚未添加中继。';

  @override
  String uiCurrentBuildValueValue9A675D(String value, String value2) {
    return '当前版本：$value • $value2';
  }

  @override
  String uiCommitValue2E080C(String value) {
    return '提交 $value';
  }

  @override
  String uiAvailableValue4B15F7(String value) {
    return '可用：$value';
  }

  @override
  String get uiChecking494D0F => '正在检查…';

  @override
  String get uiCheckForUpdates8604FF => '检查更新';

  @override
  String uiTrustNewIdentityForValue8B0612(String value) {
    return '信任 $value 的新身份？';
  }

  @override
  String uiTheRelayIsNowSigningFF71FD(String value) {
    return '中继正在使用不同的 Ed25519 公钥签名（$value）。仅在运营者确认轮换密钥后继续，否则可能遭遇中间人攻击。';
  }

  @override
  String get uiRelayIdentityChanged097638 => '中继身份已更改';

  @override
  String get uiAConfiguredRelayIsSigning60EED0 => '已配置的中继正在使用新密钥签名。信任前请向运营者核实。';

  @override
  String uiValueValue66746D(String value, String value2) {
    return '$value → $value2';
  }

  @override
  String get uiNoPendingContactRequests697615 => '没有待处理联系人请求';

  @override
  String uiCouldNotReviewRequestValue82B3D5(String value) {
    return '无法查看请求：$value';
  }

  @override
  String uiAddValueF034EE(String value) {
    return '添加 $value？';
  }

  @override
  String uiCouldNotAddContactValue7F6C38(String value) {
    return '无法添加联系人：$value';
  }

  @override
  String uiCouldNotRejectRequestValue2EFD58(String value) {
    return '无法拒绝请求：$value';
  }

  @override
  String get uiContactRequestRejected447EE8 => '已拒绝联系人请求。';

  @override
  String uiContactRequestFromValue50B6AC(String value) {
    return '来自 $value 的联系人请求';
  }

  @override
  String uiUnverifiedValueC1937C(String value) {
    return '未验证 · $value';
  }

  @override
  String uiContactRequestFailedValue28DD81(String value) {
    return '联系人请求失败：$value';
  }

  @override
  String get uiRequestAgain7B0434 => '重新请求';

  @override
  String uiTrustValueAsAFresh7BF87F(String value, String value2) {
    return '将 $value 信任为新联系人？请先通过其他渠道验证安全号码；接受后，以前的“$value2”条目将归档为只读。';
  }

  @override
  String uiTrustThisAsAReinstallCBA4CC(String value) {
    return '将此身份信任为“$value”重新安装后的身份？原联系人将归档，历史保留为只读，由新联系人接替。此操作无法撤销。';
  }

  @override
  String uiConfirmFailedValueBDE200(String value) {
    return '确认失败：$value';
  }

  @override
  String uiRejectFailedValue5F5917(String value) {
    return '拒绝失败：$value';
  }

  @override
  String uiThisContactMayBeAD1405D(String value) {
    return '此联系人可能是“$value”重置后的身份。交换消息前，请通过其他渠道验证其安全号码。';
  }

  @override
  String uiImportedRelaysFromValue37C175(String value) {
    return '已从 $value 导入中继。';
  }

  @override
  String uiImportFailedValueBAFB4A(String value) {
    return '导入失败：$value';
  }

  @override
  String uiThisWillRemoveValueRelay330EEB(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '这将移除从 $value2 导入的 $value 条中继路由。',
    );
    return '$_temp0';
  }

  @override
  String uiRemoveFailedValue58F348(String value) {
    return '移除失败：$value';
  }

  @override
  String get uiImportedRelayListsB0BD8B => '已导入的中继列表';

  @override
  String get uiNoImportedLists6CBC34 => '没有导入列表。';

  @override
  String uiValueValueValueRouteS40FB98(
    String value,
    String value2,
    int value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value3,
      locale: localeName,
      other: '$value · $value2 · $value3 条路由',
    );
    return '$_temp0';
  }

  @override
  String get uiLeaveBlankToImportUnsigned0D354E =>
      '留空则导入未签名列表（不可信，使用前仍会探测）。提供运营者密钥可进行密码学可信导入；签名从 <URL>.ed25519.sig 获取。';

  @override
  String uiValueF7CD86(String value) {
    return '// $value';
  }

  @override
  String get uiThemeA797E3 => '主题';

  @override
  String get uiAdaptiveIsUsingSystemDynamicBAA149 => '自适应主题正在使用系统动态颜色。';

  @override
  String get uiMintAndPinkRemainTheC846F3 => '薄荷绿和粉色仍作为 Conest 的备用强调色。';

  @override
  String get uiDecoration2DB87A => '装饰';

  @override
  String get uiAmbientGridScanlinesCornerReticles45D5C5 =>
      '背景网格、扫描线、角标和状态显示。从简洁到完整氛围。';

  @override
  String get uiShellBDC1FD => '外观';

  @override
  String get uiHomeLayoutE19685 => '主页布局';

  @override
  String uiCONESTCiValue7964DC(String value) {
    return 'CONEST · ci5 · $value';
  }

  @override
  String get uiQRUnavailable12869A => '二维码不可用';

  @override
  String get uiUseTheCodephraseOrPayload187111 => '请使用下方口令短语或邀请内容。';

  @override
  String uiTwoWayConfirmedValueE5A1A1(String value) {
    return '已确认双向连通$value';
  }

  @override
  String uiPathAcceptsSendWaitingFor10B4B0(String value) {
    return '路径接受发送，等待对方回复$value';
  }

  @override
  String get uiUnavailable1D5EE3 => '不可用';

  @override
  String get uiUsable829A7C => '可用';

  @override
  String get uiOneWay5EF4D0 => '单向';

  @override
  String get uiSkipC7E168 => '跳过';

  @override
  String get uiShareYourInviteThenEither5FEF78 =>
      '分享邀请，然后在另一台设备上扫描二维码或仅输入当前口令短语，即可添加联系人。';

  @override
  String get uiStartWithOneTrustedContact650B80 => '从一位受信任联系人开始';

  @override
  String get uiThisReleasePairsThroughA883AA2 =>
      '此版本可仅通过二维码邀请或口令短语配对，优先使用附近局域网路由，随后回退至互联网中继。';

  @override
  String get uiConnectivityIsOffEnableLAN39990E => '连接已关闭。请在设置中启用局域网或在线连接。';

  @override
  String get uiAutomaticAC9041 => '自动';

  @override
  String get uiPreferred0A3E0D => '首选';

  @override
  String get uiDisabledF4F447 => '已禁用';

  @override
  String get uiAskFirst1AEB84 => '先询问';

  @override
  String get uiRetryFailed7B6CA4 => '重试失败项';

  @override
  String get uiCancelAlbumDB0A07 => '取消相册';

  @override
  String get uiDeleteAlbum52E30F => '删除相册';

  @override
  String get menuForwardAlbum => '转发相册';

  @override
  String get menuSelect => '选择';

  @override
  String get menuSelectAlbum => '选择相册';

  @override
  String uiValueSelectedB1DFAF(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '已选 $value 项',
    );
    return '$_temp0';
  }

  @override
  String uiThisWillCancelValueActiveB3425E(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '这将取消 $value 项正在进行的传输并清空传输列表。聊天消息和已下载完成的文件将保留。',
    );
    return '$_temp0';
  }

  @override
  String get uiNoTransfersYetB8E5C1 => '暂无传输。';

  @override
  String get uiAttachmentMetadataUnavailableE2C31D => '附件元数据不可用';

  @override
  String uiValueMBPreparingDownload799D4A(String value) {
    return '$value MB · 正在准备下载…';
  }

  @override
  String uiValueMBDirectRouteRequired6379F0(String value) {
    return '$value MB · 需要直连路径';
  }

  @override
  String uiValueMBTapToDownload432280(String value) {
    return '$value MB · 点击下载';
  }

  @override
  String get uiPreparingDownload8CB769 => '正在准备下载…';

  @override
  String uiTransferringValueValue10EEBE(String value, String value2) {
    return '传输中 · $value% · $value2';
  }

  @override
  String uiTransferringValue9D7F13(String value) {
    return '传输中 · $value';
  }

  @override
  String get uiVoiceMessage999DEB => '语音消息';

  @override
  String get uiSendAsMedia061D87 => '作为媒体发送';

  @override
  String get uiSendAsFileB50EAF => '作为文件发送';

  @override
  String get uiMEDIAB85FA2 => '媒体';

  @override
  String get uiFILEB4915D => '文件';

  @override
  String get uiPausedByPeer63BD05 => '对方已暂停';

  @override
  String get uiCouldNotDecodeThisImage3EAA16 => '无法解码此图片。';

  @override
  String uiValueValueValueDAEE95(String value, String value2, String value3) {
    return '$value  ·  $value2/$value3';
  }

  @override
  String uiValueCannotBeReachedOver14E8C2(String value, String value2) {
    return '目前无法通过 Conest 联系 $value。是否改为向 $value2 发送普通 Matrix 消息？\n\n消息将发送到您与对方的 Matrix 私聊中，不经过 Conest 加密：除非该聊天已加密，否则主服务器可以读取。Conest 将停止尝试投递。';
  }

  @override
  String uiValueF69855(String value) {
    return '+$value';
  }

  @override
  String uiCouldNotPlayThisVideoF7D318(String value) {
    return '无法播放此视频：$value';
  }

  @override
  String get uiYouLeft9F2CDB => '您已退出';

  @override
  String uiReplyingToValue645786(String value) {
    return '回复 $value';
  }

  @override
  String get uiNoScheduledMessages1DDB60 => '没有定时消息';

  @override
  String get uiScheduledAttachment08DB0E => '定时附件';

  @override
  String uiValueValueValue209DD2(String value, String value2, String value3) {
    return '$value • $value2\n$value3';
  }

  @override
  String get uiSendNowDAE330 => '立即发送';

  @override
  String get uiReschedule34B2DC => '重新定时';

  @override
  String get uiShareTextTo7B5086 => '分享文本到…';

  @override
  String uiShareValueTo6E3BDD(String value) {
    return '分享 $value 到…';
  }

  @override
  String uiShareValueFilesToA46E17(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '分享 $value 个文件到…',
    );
    return '$_temp0';
  }

  @override
  String get uiIfMessagesAndFilesFrom3DED27 =>
      '若同一网络中手机的消息和文件始终无法到达，但您发送的可以到达，则 Windows 防火墙正在阻止接收。此操作允许任意网络上的其他设备访问此电脑的 Conest；Windows 会要求确认。';

  @override
  String get uiServerRefusedSignOut66337B => '服务器拒绝退出';

  @override
  String get uiServerNotReached62FED2 => '无法连接服务器';

  @override
  String uiThisServerDoesNotLet9EEC1F(String value) {
    return '此服务器不允许 Conest 结束其会话（$value）。可能需要在服务器账号页面管理会话。\n\n仍在此设备退出？之后请从账号页面或其他 Matrix 应用移除 Conest 会话。';
  }

  @override
  String uiConestCouldNotSignThis3C1074(String value) {
    return 'Conest 无法在服务器上注销此设备（$value）。\n\n仍在此设备退出？服务器上的会话将继续有效，直到您从其他 Matrix 应用将其移除。';
  }

  @override
  String get uiEnabledDF174A => '已启用';

  @override
  String get uiYourEncryptedMatrixHistoryIsC16CD2 =>
      '您的 Matrix 加密历史已备份。请在新设备上使用“输入恢复密钥”。';

  @override
  String get uiThisAccountAlreadyHasA0CF3D8 =>
      '此账号已有恢复密钥。请使用“输入恢复密钥”或“通过其他会话验证”来解锁此设备上的加密历史。';

  @override
  String uiMatrixValueED6C29(String value) {
    return 'Matrix：$value';
  }

  @override
  String uiValueValueB5F18A(String value, String value2) {
    return '$value$value2';
  }

  @override
  String get uiMatrixFallbackAA082C => 'Matrix 备用路径';

  @override
  String get uiMatrixAccountD69140 => 'Matrix 账号';

  @override
  String get uiAccountsThatSignInThrough64868A =>
      '通过 Google、GitHub、其他提供商或 matrix.org 登录的账号使用浏览器。';

  @override
  String uiThisAccountIsOnValueB78C80(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '此账号已在 $value 台设备上使用。',
    );
    return '$_temp0';
  }

  @override
  String get uiUseConestOnMoreThanD2AA6A =>
      '在多台设备上使用 Conest：将手机、平板或电脑关联到此账号。联系人始终看到同一个人。';

  @override
  String get uiThisDeviceWasLinkedLess2E5122 => '此设备关联尚未满一天，暂时无法添加或移除设备。';

  @override
  String get uiPauseSyncingWithADevice89642E => '设备失联多久后暂停同步';

  @override
  String uiValueDaysEE919A(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value 天',
    );
    return '$_temp0';
  }

  @override
  String get uiChatsFromOtherNetworks13CDCD => '其他网络的聊天';

  @override
  String uiShowValueChatsInTheBC0E41(String value) {
    return '在聊天列表中显示 $value 聊天';
  }

  @override
  String get uiChatWithDeltaChatUsers3B8607 =>
      '通过邮箱账号与 Delta Chat 用户聊天。请先在上方设置邮箱。';

  @override
  String uiChatWithDeltaChatUsersABD3F5(String value) {
    return '以 $value 的身份与 Delta Chat 用户私聊或群聊。端到端加密（OpenPGP，无前向保密）；邮件服务器可看到谁何时给谁写信。';
  }

  @override
  String get uiNoDeltaChatChatsYetF4C538 =>
      '暂无 Delta Chat 聊天。分享您的邀请，或使用他人邀请加入。';

  @override
  String uiRequestValueE6C033(String value) {
    return '请求：$value';
  }

  @override
  String get uiNobodyToAddYetStart0983BB => '暂无可添加成员，请先开始聊天。群组创建后即可分享其邀请。';

  @override
  String get uiVerifiedEC734B => '已验证';

  @override
  String uiAddValueF546E5(String value) {
    return '添加 $value';
  }

  @override
  String get uiChatDeleted73DC61 => '聊天已删除';

  @override
  String get uiLeaveGroup925789 => '退出群组';

  @override
  String get uiWaitingForTheInviteTo1C712D => '正在等待邀请回复，可能需要一分钟。';

  @override
  String get uiEncryptedWithOpenPGPDeltaChat9C6326 =>
      '使用 OpenPGP（Delta Chat）加密，无前向保密。邮件服务器可看到谁何时给谁写信。';

  @override
  String get uiARequestFromSomeoneYouAE0967 => '来自尚未聊过的人的请求。回复即表示接受。';

  @override
  String get uiReadA7AFDD => '已读';

  @override
  String get uiNotSentBE2B9D => '未发送';

  @override
  String get uiCouldNotJoinTheCall252D45 => '无法加入通话。请检查路由或退出当前通话。';

  @override
  String uiCallInValue16F998(String value) {
    return '$value 中的通话';
  }

  @override
  String uiValueStartedACallIn278E96(String value, String value2) {
    return '$value 在 $value2 发起了通话';
  }

  @override
  String get uiReturn24F096 => '返回';

  @override
  String get uiCouldNotUpdateTheCall33517D => '无法更新通话。';

  @override
  String get uiVoiceCallB8499D => '语音通话';

  @override
  String uiCallViaValue0A68E8(String value) {
    return '经 $value 通话';
  }

  @override
  String uiValueYouEFED9A(String value) {
    return '$value（您）';
  }

  @override
  String get uiTalkingC34D84 => '正在说话…';

  @override
  String get uiHoldToTalkSpace869505 => '按住说话 · 空格';

  @override
  String uiVoiceCallValueBD3141(String value) {
    return '语音通话 · $value';
  }

  @override
  String uiStartedByValueValueParticipants99F03D(String value, int value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value2,
      locale: localeName,
      other: '由 $value 发起 · $value2 位参与者',
    );
    return '$_temp0';
  }

  @override
  String get uiNodeRnsd0D8EEC => '节点（rnsd）';

  @override
  String get uiRNodeOnUSBF00220 => '通过 USB 使用 RNode';

  @override
  String get uiRNodeOnBluetooth13657D => '通过蓝牙使用 RNode';

  @override
  String get uiRNodeOnWiFiC18593 => '通过 Wi-Fi 使用 RNode';

  @override
  String get uiScanForRadios2B185E => '扫描无线电';

  @override
  String get uiUseTheSameFrequencyBandwidthFC1A9F =>
      '请使用与无线电所加入 Reticulum 网络相同的频率、带宽和扩频因子。';

  @override
  String get uiAppMode2965FD => '应用模式';

  @override
  String get uiBoth1F4698 => '两者';

  @override
  String uiCouldNotStartTheChatAE2F54(String value) {
    return '无法开始聊天：$value';
  }

  @override
  String uiMessagesAreEndToEndE786B5(String value) {
    return '消息已端到端加密，但双方主服务器可看到谁何时与谁聊天。请验证 $value 以确认身份。';
  }

  @override
  String get uiThisChatIsNotEncrypted799D99 => '此聊天未加密，双方主服务器均可读取。';

  @override
  String get uiLoading33CE41 => '正在加载…';

  @override
  String get uiLoadEarlierMessages4AC08D => '加载先前消息';

  @override
  String get uiEditing3B9BA1 => '编辑中';

  @override
  String uiReplyToValueValue666B4E(String value, String value2) {
    return '回复 $value：$value2';
  }

  @override
  String get uiYouWereInvitedToThisE30D1E => '您受邀加入此 Matrix 聊天。';

  @override
  String get uiEdited0E3C32 => '已编辑 · ';

  @override
  String get uiUnableToDecryptThisMessage8A31CC => '暂时无法解密此消息';

  @override
  String get uiUnsupportedMessage9E48EB => '不支持的消息';

  @override
  String uiImageUnavailableValueB024FC(String value) {
    return '图片不可用：$value';
  }

  @override
  String uiDownloadFailedValueB18BB6(String value) {
    return '下载失败：$value';
  }

  @override
  String get uiFile2C3CAF => '文件';

  @override
  String uiValueKiBEC48AF(String value) {
    return '$value KiB';
  }

  @override
  String get uiCODEPHRASEE2C724 => '口令短语';

  @override
  String uiROTATESINValueS5745B8(String value) {
    return '$value 秒后更换';
  }

  @override
  String get uiROUTEINSPECTOR321AA4 => '路由检查器';

  @override
  String get uiLIVE67B40B => '● 实时';

  @override
  String uiValueChatsAD9A3B(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value 个聊天',
    );
    return '$_temp0';
  }

  @override
  String uiValueValue167E51(String value, String value2) {
    return '$value ($value2)';
  }

  @override
  String get uiNotDeliveredTheirRadioCould75D581 => '未送达（对方无线电无法读取）';

  @override
  String get uiSenderNotVerified2BB0FA => '发件人未验证';

  @override
  String get uiYouAreHidden56DCC1 => '您已隐藏';

  @override
  String get uiYouReadTheMeshChatAEACC5 =>
      '您可阅读网状网络聊天，但 bitchat 用户看不到您，也无法联系您。请在“设置 → 连接”开启“允许 bitchat 用户联系”以发送消息。';

  @override
  String get uiEveryoneNearbyOverBluetooth7B8D63 => '通过蓝牙连接的附近所有人';

  @override
  String get uiNoBitchatUsersNearbyYetD30471 => '附近暂无 bitchat 用户';

  @override
  String get uiPhonesInBluetoothRangeThatDCCC0D => '蓝牙范围内广播自身的设备会显示在此处。';

  @override
  String get uiNearbyF1536C => '附近';

  @override
  String get uiEveryoneInBluetoothRangeReadsA7628A =>
      '蓝牙范围内的所有人都可阅读此聊天，任何人都可转发。消息已签名，但未加密。';

  @override
  String get uiEncryptedBetweenTheTwoPhones3871C4 =>
      '在两台设备间加密（bitchat 的 Noise），仅在双方均在附近时具备前向保密。';

  @override
  String get uiThisChatWasWithAn0507F9 =>
      '此聊天使用的是您先前的 bitchat 身份。现在发送消息会让对方知道新身份仍是同一个人。';

  @override
  String uiValueValue64C067(String value, String value2) {
    return '$value#$value2';
  }

  @override
  String get uiVerifyThisSessionB5065C => '验证此会话';

  @override
  String get uiBluetoothMeshOn5A96FE => '蓝牙网状网络已开启';

  @override
  String get uiStartingBluetoothE6928A => '正在启动蓝牙';

  @override
  String get uiBluetoothUnavailableF4B751 => '蓝牙不可用';

  @override
  String uiBitchatUsersNearbySeeYou1B54FC(String value) {
    return '在范围内时，附近的 bitchat 用户会看到您名为“$value”，并可向您发送消息。他们看到的身份每周更换，与您的 Conest 身份无关。';
  }

  @override
  String get uiOffBitchatUsersDoNot054F9A => '关闭：bitchat 用户看不到此设备。您仍可阅读网状网络聊天。';

  @override
  String uiPhonesNearbyWithoutInternetCan27CC7F(String value) {
    return '附近没有网络的手机可以通过此设备使用 bitchat 的地理位置频道。仅转发这些公开且已签名的消息。此设备会连接到他们使用区域的中继$value：这些中继可看到您的网络地址和区域，因此能推断您的大致位置。';
  }

  @override
  String get uiOffBitchatUsersNearbyWithout030CFB =>
      '关闭：附近没有网络的 bitchat 用户无法通过您访问地理位置频道。';

  @override
  String uiValueNearbyTheMeshChat31C0CA(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '附近 $value 人 · 网状网络聊天和私聊',
    );
    return '$_temp0';
  }

  @override
  String get uiSignInToYourMatrix8D0037 => '登录您的 Matrix 账号';

  @override
  String get uiNoRoomsFoundAD2C3E => '未找到房间';

  @override
  String get uiMatrixInvitation525106 => 'Matrix 邀请';

  @override
  String get uiEncryptedChat0D7563 => '加密聊天';

  @override
  String get uiChat2CED57 => '聊天';

  @override
  String get uiNoNostrChatsYet0A95D0 => '暂无 Nostr 聊天';

  @override
  String get uiEncryptedOnNostrNIPRelaysA51F70 =>
      '在 Nostr（NIP-17）上加密；中继看不到作者或撰写时间。无前向保密。';

  @override
  String get uiTestingRoutes19C586 => '正在测试路由…';

  @override
  String get uiTestRoutes52770A => '测试路由';

  @override
  String get uiCheckingWhetherTheirAppCan51E401 => '正在检查对方应用是否支持路由测试…';

  @override
  String get uiTheirAppDidNotSay758036 => '对方应用未声明支持路由测试。如果也使用此版本，对方可能暂时无法联系。';

  @override
  String get uiNoRouteTookTheTestF2F6CB => '没有路由接受测试。';

  @override
  String uiTestedValueRoutesThatAnswer70B842(String value) {
    return '已测试 $value。有回应的路由将优先用于消息。';
  }

  @override
  String get uiUSB09716C => 'USB';

  @override
  String get uiCopiedTheErrorHistoryCE02E2 => '已复制错误历史。';

  @override
  String get uiNothingRecordedA27006 => '暂无记录。';

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
    return '路由：$value';
  }

  @override
  String uiValueValue7B4608(String value, String value2) {
    return '$value · !$value2';
  }

  @override
  String get uiNetwork53EBC5 => '网络';

  @override
  String uiImageIsLargerThanTheEE56C5(String value) {
    return '图片超过 $value MB 上限。';
  }

  @override
  String uiFileIsLargerThanTheAF488F(String value) {
    return '文件超过 $value MB 上限。';
  }

  @override
  String uiSendValueBF4C3C(String value) {
    return '发送 $value';
  }

  @override
  String get uiRecent76EEC7 => '最近';

  @override
  String get uiConestSeesOnlyThePhotosEE1926 => 'Conest 只能看到您选择的照片。';

  @override
  String get uiPhotosPermissionDeniedUseBrowseD672EE =>
      '照片权限被拒绝。可使用“浏览文件…”发送任意文件，或在系统设置中授予访问权限。';

  @override
  String get uiNoPhotosOrVideosHereC729D1 => '此处没有照片或视频。';

  @override
  String get uiCouldNotDecodeTheImage69AC9D => '无法解码图片以进行旋转。';

  @override
  String uiRotationFailedValue176CC6(String value) {
    return '旋转失败：$value';
  }

  @override
  String uiValueOfValueVerified63B11D(String value, String value2) {
    return '已校验 $value／$value2';
  }

  @override
  String get uiPointTheCameraAtA9BAFAF => '将相机对准 Conest 邀请二维码。';

  @override
  String get statusMatrixRoomsShowJoinsAndE8AC9E => 'Matrix 房间显示加入和退出。';

  @override
  String get statusMatrixRoomsHideJoinsAndE00610 => 'Matrix 房间隐藏加入和退出。';

  @override
  String statusAppMode95B48F(String value) {
    return '应用模式：$value。';
  }

  @override
  String statusCalling7A8C67(String value) {
    return '正在呼叫 $value…';
  }

  @override
  String get statusUpdatedHistoryVisibilityForFutureDA1A23 => '已更新未来群成员的历史可见性。';

  @override
  String statusVaultUnlockFailedAE7813(String value) {
    return '保险库解锁失败：$value';
  }

  @override
  String get statusDirectOnlineTransportIsUnavailableB1EFAE =>
      '在线直连传输不可用，中继备用路径仍有效。';

  @override
  String get statusNostrCarrierSetUpE82998 => '已设置 Nostr 传输。';

  @override
  String get statusNostrCarrierRemovedCB968A => '已移除 Nostr 传输。';

  @override
  String get statusNostrRelaysUpdatedARelay03F8F3 => 'Nostr 中继已更新：一个中继已关闭。';

  @override
  String get statusTorCarrierSetUp3D2304 => '已设置 Tor 传输。';

  @override
  String get statusTorCarrierRemovedAAC23E => '已移除 Tor 传输。';

  @override
  String get statusBluetoothMeshOn11FD21 => '蓝牙网状网络已开启。';

  @override
  String get statusBluetoothMeshOff2CE954 => '蓝牙网状网络已关闭。';

  @override
  String get statusNostrMessagesOn35ABF5 => 'Nostr 消息已启用。';

  @override
  String get statusNostrMessagesOff16BCA7 => 'Nostr 消息已关闭。';

  @override
  String get statusDeltaChatOn1F38AA => 'Delta Chat 已启用。';

  @override
  String get statusDeltaChatOff8BDBD4 => 'Delta Chat 已关闭。';

  @override
  String statusBitchatUsersNearbyCanNow5536CD(String value) {
    return '附近的 bitchat 用户现在看到您名为 $value。';
  }

  @override
  String get statusBitchatUsersNoLongerSee68B46D => 'bitchat 用户已无法看到您。';

  @override
  String statusMeshcoreCarrierSetUpThroughE51369(String value) {
    return '已通过 $value 设置 MeshCore 传输。';
  }

  @override
  String get statusMeshcoreCarrierRemoved38FC35 => '已移除 MeshCore 传输。';

  @override
  String statusMeshtasticCarrierSetUpThroughAFA24A(String value) {
    return '已通过 $value 设置 Meshtastic 传输。';
  }

  @override
  String get statusMeshtasticCarrierRemoved66387E => '已移除 Meshtastic 传输。';

  @override
  String get statusMeshtasticAppMessagesOn2C1888 => 'Meshtastic 应用消息已启用。';

  @override
  String get statusMeshtasticAppMessagesOffAFB9E8 => 'Meshtastic 应用消息已关闭。';

  @override
  String get statusMeshcoreAppMessagesOn2BF1E3 => 'MeshCore 应用消息已启用。';

  @override
  String get statusMeshcoreAppMessagesOffE59C90 => 'MeshCore 应用消息已关闭。';

  @override
  String statusReticulumCarrierSetUpThrough7EB41E(String value) {
    return '已通过 $value 设置 Reticulum 传输。';
  }

  @override
  String get statusReticulumCarrierRemoved301C05 => '已移除 Reticulum 传输。';

  @override
  String statusEmailCarrierSetUpAs8427FD(String value) {
    return '已以 $value 设置邮件传输。';
  }

  @override
  String get statusEmailCarrierRemoved036E51 => '已移除邮件传输。';

  @override
  String statusImportedRelaySFromB1DB2D(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '已从导入源接收中继，数量 $value，来源 $value2。',
    );
    return '$_temp0';
  }

  @override
  String statusRemovedImportedRelaySource3F4540(String value) {
    return '已移除导入的中继源 $value。';
  }

  @override
  String get statusPairingCodeRotatedAndAdvertised722FB9 => '配对码已更换并公布。';

  @override
  String statusCheckedRouteSAvailableE9B9D6(
    int value,
    int value2,
    String value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '已检查 $value 条路由，$value2 条可用。$value3',
    );
    return '$_temp0';
  }

  @override
  String statusCheckedIrohPathSFor038B43(
    String value,
    String value2,
    String value3,
  ) {
    return '已检查 $value 的 Iroh 路径，可达状态为 $value2。$value3';
  }

  @override
  String statusNoPathsAreAdvertisedForA37EA3(String value) {
    return '$value 未公布任何路径。';
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
          '已检查 $value 条路径，联系人 $value2；$value3 条可用$value4。可达状态为 $value5。$value6',
    );
    return '$_temp0';
  }

  @override
  String get statusDisplayNameUpdated3BD31A => '显示名称已更新。';

  @override
  String get statusBioCleared543896 => '简介已清除。';

  @override
  String get statusBioUpdated440110 => '简介已更新。';

  @override
  String get statusContactProfileUpdated47ECF6 => '联系人资料已更新。';

  @override
  String get statusRelayModeEnabledB9ACB8 => '中继模式已启用。';

  @override
  String get statusRelayModeDisabled723F4D => '中继模式已关闭。';

  @override
  String get statusContactsCanNowContributeRelay147ECE => '联系人现在可自动提供中继路由。';

  @override
  String get statusAutomaticContactRelayUsageDisabledE762A7 => '自动使用联系人中继已关闭。';

  @override
  String get statusNotificationsEnabledF70668 => '通知已启用。';

  @override
  String get statusNotificationsDisabledForThisDeviceE10A46 => '此设备通知已关闭。';

  @override
  String get statusExperimentalVoiceCallsEnabledOn4081DE => '此设备的实验性语音通话已启用。';

  @override
  String get statusExperimentalVoiceCallsDisabledOn19A5AE => '此设备的实验性语音通话已关闭。';

  @override
  String get statusAndroidBackgroundRuntimeEnabledIfAA5168 =>
      'Android 后台运行已启用。如果系统限制电池或后台权限，通知仍可能延迟或无法送达。';

  @override
  String get statusAndroidBackgroundRuntimeDisabled5FC9A0 => 'Android 后台运行已关闭。';

  @override
  String get statusBackgroundVoiceCallAvailabilityEnabledA87223 =>
      '此设备后台语音通话已启用。只有 Conest 服务获准运行时才可接收来电。';

  @override
  String get statusBackgroundVoiceCallAvailabilityDisabledA71AD1 =>
      '后台语音通话已关闭。';

  @override
  String get statusFreeSpaceReserveEnabledD7CE0E => '10% 可用空间预留已启用。';

  @override
  String get statusFreeSpaceReserveDisabledD3E635 => '10% 可用空间预留已关闭。';

  @override
  String statusRoutingPreferencesUpdatedFor05867B(String value) {
    return '已更新 $value 的路由偏好。';
  }

  @override
  String statusLocalRelayPortUpdatedTo7F815D(String value) {
    return '本地中继端口已更新为 $value。';
  }

  @override
  String statusRelayAdded800692(String value) {
    return '已添加中继 $value。';
  }

  @override
  String statusRelayAddedFor087398(String value, String value2, String value3) {
    return '已添加中继 $value:$value2，用于 $value3。';
  }

  @override
  String statusRelayRemoved546A15(String value) {
    return '已移除中继 $value。';
  }

  @override
  String statusTrustedNewIdentityForRelay4CDBFE(String value) {
    return '已信任中继 $value 的新身份。';
  }

  @override
  String get statusContactRemovedE31CE0 => '联系人已移除。';

  @override
  String get statusContactRemovedLocallySendingA40D607 =>
      '已在本地移除联系人。正在后台发送移除通知。';

  @override
  String get statusDeviceCreatedShareAQr06E7B6 => '设备已创建。分享二维码邀请或当前口令短语以添加联系人。';

  @override
  String statusContactAcceptedSendingApprovalOverDAD10C(String value) {
    return '已接受联系人 $value。正在通过可用路由发送批准。';
  }

  @override
  String statusContactSavedWaitingForThe41F77D(String value) {
    return '已保存联系人 $value。正在等待对方批准请求。';
  }

  @override
  String statusReconnectedWithBC62EC(String value) {
    return '已重新连接 $value。';
  }

  @override
  String statusAskingToReconnectE93389(String value) {
    return '正在请求 $value 重新连接。';
  }

  @override
  String statusConfirmedIdentityReplacementForC93359(String value) {
    return '已确认替换 $value 的身份。';
  }

  @override
  String statusRejectedIdentityReplacementForDEC894(String value) {
    return '已拒绝替换 $value 的身份。';
  }

  @override
  String get statusContactRequestCancelledQueuedItemsEC2567 =>
      '联系人请求已取消。排队项仍被阻止。';

  @override
  String get statusSaved9D4AF6 => '已保存。';

  @override
  String statusMessageSavedLocallyItWill0DBD03(String value) {
    return '消息已保存在本地。$value 接受联系人请求后将发送。';
  }

  @override
  String statusTryingLanFirstThenRelay1F5BEC(String value) {
    return '先尝试局域网，再尝试 $value 的中继。';
  }

  @override
  String get statusMessageQueuedTheAppWillA89BCC => '消息已排队。应用会在轮询时重试直连路径和中继。';

  @override
  String statusAttachmentIsWaitingForA3F032B(String value) {
    return '附件正在等待路由：$value';
  }

  @override
  String statusCouldNotPrepareForDownloadE8FB18(String value) {
    return '无法准备下载 $value。';
  }

  @override
  String statusCreatedGroupF5D335(String value) {
    return '已创建群组 $value。';
  }

  @override
  String statusUpdatedGroup2140B7(String value) {
    return '已更新群组 $value。';
  }

  @override
  String statusRemovedAMemberFrom68CF04(String value) {
    return '已从 $value 移除一位成员。';
  }

  @override
  String statusLeftGroup9E3412(String value) {
    return '已退出群组 $value。';
  }

  @override
  String statusRemovedGroupFromYourList047F4B(String value) {
    return '已从您的列表移除群组 $value。';
  }

  @override
  String statusTransferredOwnershipOfToA126A1(String value, String value2) {
    return '已将 $value 的群主转让给 $value2。';
  }

  @override
  String statusDeletedGroupForEveryoneDB26F8(String value) {
    return '已为所有人删除群组 $value。';
  }

  @override
  String statusUpdatedIn642C0A(String value, String value2) {
    return '已更新 $value，位于 $value2。';
  }

  @override
  String statusSendingGroupMessageToD77236(String value) {
    return '正在向 $value 发送群消息。';
  }

  @override
  String statusSentToAsAPlainAF2DE6(String value) {
    return '已作为普通 Matrix 消息发送给 $value。';
  }

  @override
  String statusCanceledAndDeletedPendingMessageCDCA88(String value) {
    return '已取消并删除发给 $value 的待发送消息。';
  }

  @override
  String get statusMessageDeletedLocallyCE90EE => '消息已在本地删除。';

  @override
  String statusMessageDeletedHereAndDeletion7C4E80(String value) {
    return '消息已在此处删除，并已向 $value 发送删除请求。';
  }

  @override
  String get statusMessageDeletedHereRemoteDeletionB6AE62 =>
      '消息已在此处删除，暂时无法发送远端删除请求。';

  @override
  String get statusMessageEditedLocally187334 => '消息已在本地编辑。';

  @override
  String statusMessageEditQueuedTo695B15(String value) {
    return '消息编辑已排队等待发给 $value。';
  }

  @override
  String get statusReactionUpdatedLocally97D795 => '回应已在本地更新。';

  @override
  String statusReactionQueuedToD43BED(String value) {
    return '回应已排队等待发给 $value。';
  }

  @override
  String get statusLanLobbyMessageSavedLocallyFDE86E =>
      '局域网大厅消息已保存在本地，附近没有可联系的参与者。';

  @override
  String statusLanLobbyMessageSentTo82F0B0(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '局域网大厅消息已通过 $value 条附近路由发送。',
    );
    return '$_temp0';
  }

  @override
  String statusGroupMembershipAckFrom43FCF1(String value, String value2) {
    return '群组 $value 收到成员确认，来自 $value2。';
  }

  @override
  String statusReceivedItemSVia58B082(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '已接收 $value 项，途经 $value2。',
    );
    return '$_temp0';
  }

  @override
  String statusRoutePollFailedA1FD0C(String value) {
    return '路由轮询失败：$value';
  }

  @override
  String statusLanReceivingIsOffPort5F04CB(String value) {
    return '局域网接收已关闭：端口 $value 已被占用。请在设置中选择其他本地中继端口。';
  }

  @override
  String statusRediscoveredLanRouteFor587829(String value, String value2) {
    return '重新发现局域网路由 $value，用于 $value2。';
  }

  @override
  String statusLanDiscoveryUnavailable0E99AE(String value) {
    return '局域网发现不可用：$value';
  }

  @override
  String get statusUpdatedNearbyLanRoutesF8CAFC => '附近局域网路由已更新。';

  @override
  String statusRejectedMalformedAttachmentOfferFrom9FC96A(String value) {
    return '已拒绝来自 $value 的格式错误附件。';
  }

  @override
  String get statusRejectedInvalidAttachmentMetadata849465 => '已拒绝无效附件元数据。';

  @override
  String statusDeclinedTheRequestQueuedMessagesABFFCB(String value) {
    return '$value 拒绝了请求。排队的消息和文件仍被阻止。';
  }

  @override
  String statusNewContactRequestFromCF70B9(String value) {
    return '来自 $value 的新联系人请求。';
  }

  @override
  String statusLeftF4FE32(String value, String value2) {
    return '$value 退出了 $value2。';
  }

  @override
  String statusRemovedYouTheConversationRemains3BB516(String value) {
    return '$value 已将您移除。会话仍在本地归档。';
  }

  @override
  String statusUpdatedEditedMessageFrom1AB90D(String value) {
    return '已更新 $value 编辑的消息。';
  }

  @override
  String statusDeletedMessageRemovedBy5A9E79(String value) {
    return '已移除由 $value 删除的消息。';
  }

  @override
  String statusAppliedAReactionFrom41011B(String value) {
    return '已应用来自 $value 的回应。';
  }

  @override
  String get statusAppliedDeferredDirectReactions1414C8 => '已应用暂存的私聊回应。';

  @override
  String statusEncryptedMessageStoredForVia029324(String value, String value2) {
    return '已为 $value 保存加密消息，途经 $value2。';
  }

  @override
  String statusSentToViaWaitingForEA766D(String value, String value2) {
    return '已发送给 $value，途经 $value2；正在等待送达回执。';
  }

  @override
  String statusDeliveryRetryPending93EAA3(String value) {
    return '等待重试投递：$value';
  }

  @override
  String statusGroupDeliveryRetryPending691CA4(String value) {
    return '等待重试群组投递：$value';
  }

  @override
  String statusRelayIdentityChangedVerifyWith6F3689(String value) {
    return '中继 $value 身份已更改，请向运营者核实。';
  }

  @override
  String statusRelayIdentityMismatchVerifyWith2D3B10(
    String value,
    String value2,
  ) {
    return '中继 $value:$value2 身份不匹配，请向运营者核实。';
  }

  @override
  String get statusTheMatrixSignInExpired76ABA4 => 'Matrix 登录已过期。请重新登录以继续使用。';

  @override
  String statusSignedInToMatrixAs5103D2(String value) {
    return '已以 $value 登录 Matrix。';
  }

  @override
  String get statusSignedOutOfMatrix1D1860 => '已退出 Matrix。';

  @override
  String statusSOtherDevicesHaveNot07F30F(String value, String value2) {
    return '$value 的其他设备已一段时间未联系到 $value2：来自该设备的消息可能并非本人发送。';
  }

  @override
  String statusReceivedItemSInstantlyViaA7773B(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '已通过本地中继即时接收 $value 项。',
    );
    return '$_temp0';
  }

  @override
  String statusReceivedItemSViaLocal71A104(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '已通过本地收件箱接收 $value 项。',
    );
    return '$_temp0';
  }

  @override
  String get statusNoNewProtocols => '未检测到新的中继协议。';

  @override
  String get statusRouteExchangeRequested => '已请求交换路由信息。';

  @override
  String get statusRouteExchangePending => '暂时无法发送路由信息交换请求。';

  @override
  String get statusKnownRoutes => '已知路由';

  @override
  String get statusReachable => '可联系';

  @override
  String get statusUnreachable => '无法联系';

  @override
  String get statusUnknown => '未知';

  @override
  String get statusExpired => '已过期';

  @override
  String get connectionsTitle => '连接图';

  @override
  String get connectionsDescription => '查看设备间的双向或单向连接。';

  @override
  String get relayUdpHint => 'udp://host:port 强制使用 UDP';

  @override
  String get deltaFileActions => '文件操作';

  @override
  String get deltaForward => '转发';

  @override
  String get deltaAttach => '添加附件';

  @override
  String get deltaSendVoice => '发送语音消息';

  @override
  String get deltaDiscardVoice => '丢弃语音消息';

  @override
  String get deltaRecordVoice => '录制语音消息';

  @override
  String get deltaReact => '回应';

  @override
  String get savedMessagesPreview => '给自己的笔记、文件和转发';

  @override
  String networkChatsTitle(String network) {
    return '$network 聊天';
  }

  @override
  String get networkEncryptedMatrixChat => '加密 Matrix 聊天';

  @override
  String get networkMatrixChat => 'Matrix 聊天';

  @override
  String get networkEveryoneBluetooth => '蓝牙范围内的所有人';

  @override
  String get inviteNoRoutes => '未公布路由';

  @override
  String get deliveryPending => '等待可达路径';

  @override
  String get deliveryLocal => '已通过局域网发送，等待送达回执';

  @override
  String get deliveryRelayed => '已在中继排队，等待送达回执';

  @override
  String get deliveryDelivered => '已送达';

  @override
  String get deliveryRead => '已读';

  @override
  String get reachabilityOnline => '在线';

  @override
  String get reachabilityRecent => '最近在线';

  @override
  String get reachabilityKnown => '已知';

  @override
  String get transferApproval => '等待批准';

  @override
  String get transferPeer => '等待对方';

  @override
  String get routeLanDirect => '局域网直连';

  @override
  String get routeInternetDirect => '互联网直连';

  @override
  String get routeIrohDirect => 'Iroh 直连';

  @override
  String get routeConestRelay => 'Conest 中继';

  @override
  String get routeOptical => '光学';

  @override
  String get routeViaContact => '经联系人';

  @override
  String get themeSystem => '跟随系统';

  @override
  String get themeLight => 'Signature · 浅色';

  @override
  String get themeDark => 'Signature · 深色';

  @override
  String get themeBlack => 'Signature · 纯黑（OLED）';

  @override
  String get themeAdaptive => '自适应（壁纸）';

  @override
  String get layoutSignalCards => '信号卡片';

  @override
  String get layoutStationFeed => '站点动态';

  @override
  String get layoutClassic => '经典列表';

  @override
  String get layoutSignalDescription => '以仪表盘连接卡片显示设备。';

  @override
  String get layoutFeedDescription => '按时间排列的数据包／活动记录。';

  @override
  String get layoutClassicDescription => '紧凑的单行列表。';

  @override
  String get shellSignatureDescription => 'Conest 原生仪表盘侧栏。';

  @override
  String get shellGarrisonDescription => '类似 Discord：格状导航栏和会话。';

  @override
  String get shellCourierDescription => '类似 Telegram：简洁的统一会话列表。';

  @override
  String get connectionsBothWays => '双向';

  @override
  String get connectionsInbound => '仅来自对方';

  @override
  String get connectionsFailing => '失败';

  @override
  String get connectionsUnknown => '暂无近期消息';

  @override
  String voiceConnected(String time) {
    return '已连接 · $time';
  }

  @override
  String messageClockAhead(String amount) {
    return '对方时钟快约 $amount；此处时间以本设备为准。';
  }

  @override
  String messageClockBehind(String amount) {
    return '对方时钟慢约 $amount；此处时间以本设备为准。';
  }

  @override
  String messageNotRecentlyConfirmed(String date) {
    return '近期未确认：对方其他设备最后一次将此设备认作本人设备是在 $date。';
  }

  @override
  String get routeLanDirectDescription => '通过本地网络直接连接对方设备。';

  @override
  String get routeLanRelayDescription => '通过本地网络中另一设备的中继节点。';

  @override
  String get routeLanLobbyDescription => '局域网大厅的共享信箱；网络中的任何人都能读取。';

  @override
  String get routeInternetDirectDescription => '通过互联网直连对方设备的中继节点。';

  @override
  String get routeIrohDirectDescription => '通过 Iroh 点对点连接，采用端到端加密。';

  @override
  String get routeIrohRelayDescription => '通过 Iroh 中继服务器，服务器只能看到加密流量。';

  @override
  String get routeConestRelayDescription => '由 Conest 中继服务器存储并转发，服务器只能看到加密信封。';

  @override
  String get routeMatrixDescription =>
      '通过 Matrix 传输，仍由 Conest 端到端加密；主服务器可见通信双方和时间。';

  @override
  String get routePlainMatrixDescription => '作为普通 Matrix 消息发送；若房间未加密，主服务器可以读取。';

  @override
  String get routeNostrDescription =>
      '通过 Nostr 中继传输，仍由 Conest 端到端加密；中继可见接收方和时间，无法看到发送方。';

  @override
  String get routeEmailDescription =>
      '通过电子邮件传输，仍由 Conest 端到端加密；邮件服务器可见双方地址和时间。';

  @override
  String get routeReticulumDescription => '通过 Reticulum 无线电或网络传输，采用端到端加密。';

  @override
  String get routeMeshtasticDescription => '通过 Meshtastic 无线网格传输，采用端到端加密。';

  @override
  String get routeMeshCoreDescription => '通过 MeshCore 无线网格传输，采用端到端加密。';

  @override
  String get routeBluetoothDescription => '经附近设备通过 Bluetooth 网格传输，采用端到端加密。';

  @override
  String get routeTorDescription => '通过 Tor 在 onion 服务间传输；沿途无人能看到通信双方。';

  @override
  String get routeContactDescription =>
      '由可联系对方设备的联系人转发；仍采用端到端加密，该联系人仅能看到接收方和时间。';

  @override
  String routeTestRoundTrip(String route, String ms) {
    return '$route：往返 $ms 毫秒';
  }

  @override
  String routeTestStored(String route) {
    return '$route：已留在中继（对方获取后答复）';
  }

  @override
  String routeTestNoAnswer(String route) {
    return '$route：无应答';
  }

  @override
  String transferTimeLeft(String time) {
    return '剩余 $time';
  }

  @override
  String transferQueuePosition(String position) {
    return '队列第 $position 位';
  }

  @override
  String get transferTapRetry => '点击重试';

  @override
  String get transferRerouting => '切换路由';

  @override
  String get routeShortLobby => '大厅';

  @override
  String get routeShortDirect => '直连';

  @override
  String get routeShortRelay => '中继';

  @override
  String get routeShortContact => '经联系人';

  @override
  String chatDraftPreview(String text) {
    return '草稿：$text';
  }

  @override
  String get routeAutomaticFallback => '自动切换 ✓';

  @override
  String get releaseNightly => '每夜版';

  @override
  String get releaseStable => '稳定版';

  @override
  String get callActive => '通话中';

  @override
  String get callGeneric => '通话';

  @override
  String get contactNotPinned => '未固定';

  @override
  String get groupUnknownMember => '一位成员';

  @override
  String get relaySourceSigned => '已签名';

  @override
  String get relaySourceUnsigned => '未签名';

  @override
  String get beamFingerprintUnavailable => '指纹不可用';

  @override
  String get fileOriginalMetadataWarning => '将一并发送其中的位置、相机、作者和日期信息。';

  @override
  String get routeMarkSent => '已发送';

  @override
  String get routeMarkStored => '在中继等待';

  @override
  String get routeMarkReached => '已到达对方设备';

  @override
  String get routeMarkDelivered => '已送达';

  @override
  String get routeMarkReceived => '已接收';

  @override
  String get relayHostOrLinkLabel => '中继主机、网址或链接';

  @override
  String get relayLinkHint => '安装程序给出的 conest-relay://…';

  @override
  String get brokenPartNotice => '这里出了点问题。';

  @override
  String get crashNoticeBody => 'Conest 上次意外关闭。详细信息保留在此设备上；你可以将其复制到错误报告中。';

  @override
  String get crashNoticeDetails => '详细信息';

  @override
  String get crashNoticeDismiss => '忽略';

  @override
  String get crashReportTitle => '发生了什么';

  @override
  String get crashReportCopy => '复制';

  @override
  String get crashReportClose => '关闭';

  @override
  String get connectionsNetworks => '此设备用过的网络';

  @override
  String get connectionsNetworkNow => '正在使用';

  @override
  String connectionsNetworkLastSeen(String date) {
    return '上次出现 $date';
  }

  @override
  String get connectionsRouteWorks => '可用';

  @override
  String get connectionsRouteBlocked => '在此网络上被屏蔽';

  @override
  String get connectionsRouteFailing => '失败';

  @override
  String connectionsAsOf(String when) {
    return '截至 $when';
  }

  @override
  String get bluetoothMeshNeedsAttention => '蓝牙网状网络需要处理';

  @override
  String forwardSelectedTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '转发 $count 条消息',
    );
    return '$_temp0';
  }

  @override
  String forwardedSummary(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已转发 $count 条消息',
    );
    return '$_temp0';
  }

  @override
  String forwardSkipped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个文件尚未在此设备上，已跳过',
    );
    return '$_temp0';
  }

  @override
  String get torBlockedHint =>
      'Tor 在此网络上似乎被封锁。网桥可以绕过封锁，但公共网桥也常被封锁：请获取您自己的网桥（见下方）。';

  @override
  String get torGetBridgesTitle => '如何获取您自己的网桥';

  @override
  String get torGetBridgesIntro =>
      'Tor Project 通过以下方式提供网桥。请索取 obfs4 或 webtunnel 网桥，然后把这些行粘贴到上方。';

  @override
  String get torGetBridgesWeb => '网站：bridges.torproject.org';

  @override
  String get torGetBridgesTelegram => 'Telegram：向 @GetBridgesBot 发消息';

  @override
  String get torGetBridgesEmail =>
      '电子邮件：用 Gmail 或 Riseup 邮箱写信给 bridges@torproject.org';

  @override
  String get torGetBridgesFriend => '或者请您信任的、正在使用 Tor 的人与您分享一行网桥。';

  @override
  String get transportsTitle => '联系此网络之外的人';

  @override
  String get transportsIntro =>
      '此网络上的设备可以直接联系您。对于其他人，Conest 至少需要一条经由互联网的途径，最好三条，因为网络会封锁其中一些。以下是此网络上目前可用的途径。';

  @override
  String get transportsChecking => '正在检查此网络上哪些途径可用…';

  @override
  String transportsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已设置 $count 个：推荐 3 个',
      zero: '尚未设置：至少需要 1 个，推荐 3 个',
    );
    return '$_temp0';
  }

  @override
  String get transportStateOn => '可用';

  @override
  String get transportStateWorks => '此处可用';

  @override
  String get transportStateBlocked => '此处被封锁';

  @override
  String get transportStateNeedsSetup => '稍后在设置中配置';

  @override
  String get transportsEmailCost => '会检查邮箱：多用一点流量和电量。';

  @override
  String get transportsSkipTitle => '只有附近的设备能联系到您';

  @override
  String get transportsSkipBody =>
      '没有经由互联网的途径时，只有此网络上的设备能联系您，您也只能联系它们。您可以稍后在设置的“连接”中进行设置。';

  @override
  String get transportsSkipConfirm => '仍然继续';

  @override
  String get transportsBanner => '现在只有此网络上的设备能联系您。请设置一条经由互联网的途径。';

  @override
  String get transportsBannerAction => '设置';

  @override
  String get transportsBannerDismiss => '以后再说';

  @override
  String transportsTurnOnFailed(String name, String error) {
    return '无法开启 $name：$error';
  }

  @override
  String get transportsHowToChoose => '如何选择';

  @override
  String get settingsUserGuide => '用户指南';

  @override
  String get settingsEnterSends => '按 Enter 发送消息';

  @override
  String get settingsEnterSendsHelp =>
      'Shift+Enter 换行。关闭时：Enter 换行，Ctrl+Enter 发送。';

  @override
  String get menuCopySelection => '复制所选文字';

  @override
  String get linkLookalikeTitle => '打开此链接？';

  @override
  String linkLookalikeBody(String host) {
    return '地址 $host 使用了其他字母表中的字母，可能在冒充你熟悉的网站。';
  }

  @override
  String get linkOpen => '打开';

  @override
  String get carrierRemove => '移除';

  @override
  String carrierRemoveTitle(String name) {
    return '移除 $name？';
  }

  @override
  String carrierRemoveBody(String name) {
    return '联系人将无法再通过 $name 联系你，本设备为其保存的内容也会被清除。重新设置会得到一个新地址。若只想暂停，请关闭它的开关。';
  }

  @override
  String get carrierPaused => '已暂停：保留但不使用。打开即可再次使用。';

  @override
  String get emailChangeAccount => '更换账号';

  @override
  String get emailOtherServer => '使用其他服务器';

  @override
  String get actionSave => '保存';

  @override
  String get settingsLinksTitle => '你发送和打开的链接';

  @override
  String get settingsCleanLinks => '去除链接中的跟踪参数';

  @override
  String get settingsCleanLinksHelp =>
      '发送和打开链接时，去掉让网站得知是谁分享的部分（如 ?si= 或 utm_）。使用 ClearURLs 规则。';

  @override
  String get settingsEmbedLinks => '可显示预览的链接';

  @override
  String get settingsEmbedLinksHelp =>
      '指向 X、Instagram、Reddit、TikTok 等网站帖子的链接会经过一个服务，让其他应用能显示预览，并把浏览器转到原帖。服务来自 embed-fixer 列表；失效的服务会被跳过。';

  @override
  String get linkCleaned => '链接已清理';

  @override
  String get linkCleanedUndo => '撤销';

  @override
  String get menuOpenOriginalLink => '打开原始链接';

  @override
  String get editorSendOriginalAsFile => '以文件发送原图（不压缩）';
}

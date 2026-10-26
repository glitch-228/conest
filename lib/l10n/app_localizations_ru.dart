// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get modeChooseTitle => 'Как должен выглядеть Conest?';

  @override
  String get modeChangeLater =>
      'Это можно изменить в любой момент в настройках.';

  @override
  String get modeSimple => 'Простой';

  @override
  String get modeStandard => 'Обычный';

  @override
  String get modeAdvanced => 'Расширенный';

  @override
  String get modeSimpleDescription =>
      'Один список чатов, крупный текст и только нужные настройки. У сообщений видно: отправлено, доставлено, прочитано.';

  @override
  String get modeStandardDescription =>
      'Как в привычных мессенджерах: чаты, группы, звонки и файлы с отметками о доставке и прочтении.';

  @override
  String get modeAdvancedDescription =>
      'Всё, включая маршруты каждого сообщения, все транспорты и диагностику.';

  @override
  String get actionContinue => 'Далее';

  @override
  String get actionStart => 'Начать';

  @override
  String get actionBack => 'Назад';

  @override
  String get actionClose => 'Закрыть';

  @override
  String get routesTitle => 'Как Conest доставляет сообщения';

  @override
  String get routesDirect =>
      'Conest отправляет сообщения напрямую вашим контактам через вашу сеть и интернет, без сервера посередине. Это уже включено.';

  @override
  String get routesOthers =>
      'Если эти пути заблокированы или недоступны, Conest может использовать ретрансляторы, Tor, Nostr, email, Matrix, Bluetooth-сеть телефонов рядом или радио LoRa. Каждый способ выключен, пока вы не включите его в «Настройки → Подключение».';

  @override
  String get routesAdvanced =>
      'В расширенном режиме у каждого сообщения видны пройденные маршруты, а в профиле контакта можно проверить каждый маршрут.';

  @override
  String get tabChats => 'Чаты';

  @override
  String get tabCalls => 'Звонки';

  @override
  String get tabSettings => 'Настройки';

  @override
  String get callsEmpty =>
      'Звонков пока нет. Откройте чат и нажмите кнопку звонка.';

  @override
  String get callOutgoing => 'Исходящий';

  @override
  String get callIncoming => 'Входящий';

  @override
  String get callMissed => 'Пропущенный';

  @override
  String get callDeclined => 'Отклонён';

  @override
  String get callCancelled => 'Отменён';

  @override
  String get callFailed => 'Не удался';

  @override
  String callDuration(int minutes, int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes мин $seconds с',
      zero: '$seconds с',
    );
    return '$_temp0';
  }

  @override
  String get unknownContact => 'Неизвестный контакт';

  @override
  String get messageDetails => 'Сведения о сообщении';

  @override
  String messageSentAt(String time) {
    return 'Отправлено $time';
  }

  @override
  String messageReceivedAt(String time) {
    return 'Получено $time';
  }

  @override
  String messageDeliveredAt(String time) {
    return 'Доставлено $time';
  }

  @override
  String messageReadAt(String time) {
    return 'Прочитано $time';
  }

  @override
  String memberDeliveredAt(String time) {
    return 'доставлено $time';
  }

  @override
  String memberReadAt(String time) {
    return 'прочитано $time';
  }

  @override
  String get messageRoutes => 'Маршруты';

  @override
  String get messageArrivedBy => 'Пришло по';

  @override
  String get settingsShowAll => 'Показать все настройки';

  @override
  String get settingsLanguage => 'Язык';

  @override
  String get settingsLanguageSystem => 'Как на устройстве';

  @override
  String get settingsAiTranslated =>
      'Этот перевод сделан с помощью ИИ и может содержать ошибки. Помочь улучшить его можно на Weblate.';

  @override
  String get menuReply => 'Ответить';

  @override
  String get menuReact => 'Реакция 👍';

  @override
  String get menuForward => 'Переслать';

  @override
  String get menuCopyMessage => 'Копировать сообщение';

  @override
  String get menuDownloadAttachment => 'Скачать вложение';

  @override
  String get menuSaveAttachment => 'Сохранить вложение';

  @override
  String get menuCopyImage => 'Копировать изображение';

  @override
  String get menuFreeUpSpace => 'Освободить место';

  @override
  String get menuCancelTransfer => 'Отменить передачу';

  @override
  String get menuRetryTransfer => 'Повторить передачу';

  @override
  String get menuForwardAttachment => 'Переслать вложение';

  @override
  String get menuCancelSending => 'Отменить отправку';

  @override
  String get menuEditMessage => 'Изменить сообщение';

  @override
  String get menuDeleteMessage => 'Удалить сообщение';

  @override
  String get menuEdit => 'Изменить';

  @override
  String get menuDelete => 'Удалить';

  @override
  String get composerAttach => 'Прикрепить файл или изображение';

  @override
  String get composerSchedule => 'Запланировать сообщение';

  @override
  String get composerSend => 'Отправить';

  @override
  String get searchChatsAndMessages => 'Поиск по чатам и сообщениям';

  @override
  String get searchChats => 'Поиск чатов';

  @override
  String get searchContacts => 'Поиск контактов';

  @override
  String get archivedChats => 'Архив чатов';

  @override
  String get actionSearch => 'Поиск';

  @override
  String get settingsPersonal => 'Личное';

  @override
  String get settingsStorage => 'Хранилище';

  @override
  String get settingsConnectivity => 'Подключение';

  @override
  String get settingsRelays => 'Ретрансляторы';

  @override
  String get settingsUpdates => 'Обновления';

  @override
  String get settingsAccount => 'Аккаунт';

  @override
  String get onbNameRequired =>
      'Введите отображаемое имя и правильный локальный порт.';

  @override
  String get onbRelayPortInvalid =>
      'Если указан адрес ретранслятора, порт тоже должен быть правильным.';

  @override
  String get onbRelayDesktop =>
      'Компьютеры по умолчанию работают как ретрансляторы и сами сообщают о маршрутах в локальной сети.';

  @override
  String get onbRelayAndroid =>
      'На Android режим ретранслятора выключен. Включайте его в настройках, только если хотите, чтобы устройство передавало чужие сообщения.';

  @override
  String get onbRelayOther =>
      'Режим ретранслятора можно включить в настройках, если устройство должно помогать передавать сообщения.';

  @override
  String get onbTagline =>
      'Связывайтесь с контактами напрямую через свою сеть или интернет, со сквозным шифрованием и прямой секретностью. Если обычные пути заблокированы, Conest использует ретрансляторы, Matrix, Nostr, email, Tor, радио LoRa или Bluetooth-сеть телефонов рядом.';

  @override
  String get onbFeatureForwardSecret => 'Чаты с прямой секретностью';

  @override
  String get onbFeatureDirect => 'Напрямую через сеть и интернет';

  @override
  String get onbFeatureFallbacks => 'Запасные пути: Tor, mesh и радио';

  @override
  String get onbFeatureMatrix => 'Ещё и клиент Matrix';

  @override
  String get onbCreateTitle => 'Создайте своё первое устройство';

  @override
  String get onbCreateHelp =>
      'Нужно только отображаемое имя. Локальный порт нужен для доставки по локальной сети и сопряжения по кодовой фразе. Интернет-ретранслятор необязателен: контакты доступны через интернет и без него. Другие пути можно включить позже в «Настройки → Подключение».';

  @override
  String get onbDisplayName => 'Отображаемое имя';

  @override
  String get onbLocalPort => 'Локальный порт / порт LAN';

  @override
  String get onbRelayHost => 'Адрес интернет-ретранслятора (необязательно)';

  @override
  String get onbRelayPort => 'Порт интернет-ретранслятора';

  @override
  String get onbCreateButton => 'Создать зашифрованное устройство';

  @override
  String get onbMatrixInstead => 'Использовать как клиент Matrix';

  @override
  String get onbMatrixHelp =>
      'Только чаты Matrix, без личности Conest. Позже можно включить режим «Оба» (Conest и Matrix рядом) в «Настройки → Подключение → Режим приложения».';

  @override
  String get groupCreate => 'Создать группу';

  @override
  String get groupTitle => 'Название группы';

  @override
  String get roleMember => 'Участник';

  @override
  String get roleModerator => 'Модератор';

  @override
  String get roleAdmin => 'Администратор';

  @override
  String get actionCancel => 'Отмена';

  @override
  String get actionCreate => 'Создать';

  @override
  String get actionCreating => 'Создание…';

  @override
  String get contactAdd => 'Добавить контакт';

  @override
  String get contactAlias => 'Имя';

  @override
  String get contactInvitePayload => 'Приглашение или отсканированный QR-код';

  @override
  String get contactScanQr => 'Сканировать QR';

  @override
  String get contactCodephrase => 'Только кодовая фраза';

  @override
  String get contactTrustPayload => 'Доверять QR / приглашению';

  @override
  String get contactFindCodephrase => 'Найти по кодовой фразе';

  @override
  String get contactExchangeFailed => 'Автоматический обмен не удался';

  @override
  String contactExchangeFailedBody(String alias) {
    return 'Вы добавили $alias, но ваше приглашение не удалось отправить обратно автоматически. Попросите собеседника отсканировать или ввести ваше приглашение со своей стороны, или отмените и удалите этот односторонний контакт.';
  }

  @override
  String get actionAbort => 'Отменить';

  @override
  String get contactKeep => 'Оставить контакт';

  @override
  String get uiPassphrase89950C => 'Парольная фраза';

  @override
  String get uiConfirmPassphraseEBAAC0 => 'Подтвердите парольную фразу';

  @override
  String get uiUnlock1526A1 => 'Разблокировать';

  @override
  String get uiUpdateAvailable67FD3A => 'Доступно обновление';

  @override
  String get uiLater56E2F5 => 'Позже';

  @override
  String get uiHostAutoDetectsTCPUDP663D30 =>
      'хост определяет TCP/UDP автоматически; udp://host:port задаёт UDP';

  @override
  String get uiVerificationRequestDA06F9 => 'Запрос проверки';

  @override
  String get uiIgnore98F55D => 'Игнорировать';

  @override
  String get uiVerifyDDA6AC => 'Проверить';

  @override
  String uiCouldNotReadValueValue695755(String value, String value2) {
    return 'Не удалось прочитать $value: $value2';
  }

  @override
  String uiCouldNotShareValueValue7BA3A3(String value, String value2) {
    return 'Не удалось поделиться $value: $value2';
  }

  @override
  String uiCouldNotSaveSidebarWidthB4DACB(String value) {
    return 'Не удалось сохранить ширину боковой панели: $value';
  }

  @override
  String get uiNoAudioOutputDevicesWere17E473 =>
      'Устройства вывода звука не найдены.';

  @override
  String get uiCallAudioOutput0C276F => 'Вывод звука звонка';

  @override
  String uiCallAudioRoutedToValueFFFBE8(String value) {
    return 'Звук звонка направлен на $value.';
  }

  @override
  String uiCouldNotChangeCallAudio6CE7B1(String value) {
    return 'Не удалось сменить вывод звука звонка: $value';
  }

  @override
  String uiCouldNotOpenInviteValue6C4D06(String value) {
    return 'Не удалось открыть приглашение: $value';
  }

  @override
  String uiCouldNotSendAttachmentValueEFF771(String value) {
    return 'Не удалось отправить вложение: $value';
  }

  @override
  String uiCouldNotSendMessageValue042C4F(String value) {
    return 'Не удалось отправить сообщение: $value';
  }

  @override
  String get uiSendFromOriginalFFF29A => 'Отправить из оригинала';

  @override
  String uiCouldNotSendGroupMessageB6C7D1(String value) {
    return 'Не удалось отправить сообщение в группу: $value';
  }

  @override
  String uiCouldNotSendLANLobby8E7487(String value) {
    return 'Не удалось отправить сообщение в локальный чат: $value';
  }

  @override
  String uiCouldNotStageValuePathless514094(String value) {
    return 'Не удалось подготовить $value: для защиты памяти перетаскиваемые файлы без пути ограничены 8 МБ.';
  }

  @override
  String get uiSelectAGroupBeforeDropping9DAB4C =>
      'Перед перетаскиванием файлов выберите группу.';

  @override
  String uiValueLocalFilePathUnavailable217177(String value) {
    return '$value: путь к локальному файлу недоступен.';
  }

  @override
  String uiValueSentWithoutIt7E0635(String value) {
    return '$value Отправлено без этого.';
  }

  @override
  String get uiGroupFileScheduledB1DC66 =>
      'Отправка файла в группу запланирована.';

  @override
  String uiCouldNotScheduleValueValue25CED3(String value, String value2) {
    return 'Не удалось запланировать $value: $value2';
  }

  @override
  String uiCouldNotOpenFilePicker8FF0C0(String value) {
    return 'Не удалось открыть выбор файлов: $value';
  }

  @override
  String uiValuePickerReturnedNoData4670CA(String value) {
    return '$value: окно выбора не вернуло данные.';
  }

  @override
  String uiOnlyTheFirstValueFiles45FC47(String value, String value2) {
    return 'Будут подготовлены только первые $value файлов (получено $value2).';
  }

  @override
  String uiValueSkippedValueMBExceeds487B2A(String value, String value2) {
    return '$value пропущен: $value2 МБ превышает предел $value МБ.';
  }

  @override
  String get uiTransfers812412 => 'Передачи';

  @override
  String uiValue75CED7(String value) {
    return '$value';
  }

  @override
  String get uiPreparingCallE86D6C => 'Подготовка звонка…';

  @override
  String get uiCallingACD4A6 => 'Вызов…';

  @override
  String get uiIncomingVoiceCallF68FD3 => 'Входящий голосовой звонок';

  @override
  String get uiConnectingFD3E79 => 'Подключение…';

  @override
  String get uiReconnecting8A8B95 => 'Переподключение…';

  @override
  String get uiCallEnded9933A4 => 'Звонок завершён';

  @override
  String uiVoiceCallValue06FE1F(String value) {
    return 'Голосовой звонок: $value';
  }

  @override
  String get uiMinimizeCall6CB0F0 => 'Свернуть звонок';

  @override
  String get uiAcceptBB54DB => 'Принять';

  @override
  String get uiReject2B03B5 => 'Отклонить';

  @override
  String get uiNoiseSuppression71DE3C => 'Шумоподавление';

  @override
  String get uiAudioOutput2B89CC => 'Вывод звука';

  @override
  String get uiDoneE9B450 => 'Готово';

  @override
  String get uiHangUp66BE99 => 'Завершить звонок';

  @override
  String get uiCloseDetails433DA6 => 'Закрыть подробности';

  @override
  String get uiOpenFullProfile35063C => 'Открыть полный профиль';

  @override
  String get uiOpenGroupSettings0B568E => 'Открыть настройки группы';

  @override
  String get uiNewFolderA71199 => 'Новая папка';

  @override
  String get uiFolderNameB2CE02 => 'Имя папки';

  @override
  String get uiMoveEarlier07DD6F => 'Переместить выше';

  @override
  String get uiMoveLaterBB4C84 => 'Переместить ниже';

  @override
  String get uiSaveEFC007 => 'Сохранить';

  @override
  String get uiAddToFolderBFAD96 => 'Добавить в папку';

  @override
  String get uiNewMessage1ED2E7 => 'Новое сообщение';

  @override
  String get uiBackToChats8DE6F6 => 'К чатам';

  @override
  String get uiNavigationMenu6609F1 => 'Меню навигации';

  @override
  String get uiAllChats398E5B => 'Все чаты';

  @override
  String get uiSearchAllChatsC825C8 => 'Поиск по всем чатам';

  @override
  String get uiClearSearch67300D => 'Очистить поиск';

  @override
  String get uiContactRequests082691 => 'Запросы контактов';

  @override
  String get uiReviewPeopleWhoWantTo24A8CB => 'Просмотреть желающих связаться';

  @override
  String get uiNoChatsFoundC6BD82 => 'Чаты не найдены';

  @override
  String get uiNoArchivedChatsEAE7F0 => 'Нет архивных чатов';

  @override
  String get uiNoMatrixChatsYet23B023 => 'Пока нет чатов Matrix';

  @override
  String get uiNewGroupF9850C => 'Новая группа';

  @override
  String get uiAddWithConestBeam19D1E2 => 'Добавить через Conest Beam';

  @override
  String get uiDirectMessagesE7596A => 'Личные сообщения';

  @override
  String get uiConestBeamE98B77 => 'Conest Beam';

  @override
  String get uiMyInviteF80A7A => 'Моё приглашение';

  @override
  String get uiGroupDetailsDF844A => 'О группе';

  @override
  String get uiDebugBD604D => 'Отладка';

  @override
  String get uiAdd61CC55 => 'Добавить';

  @override
  String get uiPollRoutesNow22318F => 'Проверить маршруты сейчас';

  @override
  String get uiContactProfile1B3A0E => 'Профиль контакта';

  @override
  String get uiHistoryForNewMembersF419F2 => 'История для новых участников';

  @override
  String get uiChooseHowToWindDownF7399D =>
      'Выберите, как завершить работу группы. Передача владения сохранит группу с новым владельцем, а вы станете администратором. Удаление для всех уберёт группу из списка каждого участника; отменить это нельзя.';

  @override
  String get uiTransferOwnershipA563C9 => 'Передать владение…';

  @override
  String get uiDeleteForEveryoneE055A8 => 'Удалить у всех';

  @override
  String get uiNoOtherActiveMembersToF9DE12 =>
      'Нет других активных участников для передачи владения.';

  @override
  String get uiTransferOwnershipA6819E => 'Передать владение';

  @override
  String get uiTransferCBB4CC => 'Передать';

  @override
  String uiOwnershipTransferredToValue14A10D(String value) {
    return 'Владение передано: $value.';
  }

  @override
  String get uiEveryMemberWillBeRemoved75A3FC =>
      'Все участники будут удалены, а группа отмечена как покинутая в их списках. Локальная история не удалится автоматически: каждый может очистить её через «Убрать из списка». Отменить это нельзя.';

  @override
  String get uiRemoveThisGroup38C4E8 => 'Убрать эту группу?';

  @override
  String get uiRemoveThisGroupFromYourDA7898 =>
      'Убрать группу из вашего списка? Локальная история будет удалена. Другие участники не получат уведомление: они уже видят, что вы вышли.';

  @override
  String get uiRemoveE96390 => 'Удалить';

  @override
  String get uiChangeRole2B9BFD => 'Изменить роль';

  @override
  String get uiRemoveMember1C31D1 => 'Удалить участника';

  @override
  String get uiChooseWhatFutureMembersCanC38992 =>
      'Выберите историю для будущих участников';

  @override
  String get uiAddMember170AD0 => 'Добавить участника';

  @override
  String get uiDeleteGroup043336 => 'Удалить группу…';

  @override
  String get uiLeave7E3520 => 'Выйти';

  @override
  String get uiRemoveFromList23A976 => 'Убрать из списка';

  @override
  String get uiForwardMessage482959 => 'Переслать сообщение';

  @override
  String get uiSavedMessagesC0FA7E => 'Избранное';

  @override
  String get uiThisAttachmentIsNotAvailableFE641A =>
      'Это вложение пока недоступно локально.';

  @override
  String get uiDownloadThisFileBeforeForwarding60D7B5 =>
      'Скачайте файл перед пересылкой.';

  @override
  String get uiSearchMessagesABEA65 => 'Поиск сообщений';

  @override
  String get uiStartVoiceCallExperimental6DE320 =>
      'Начать голосовой звонок (экспериментально)';

  @override
  String get uiChatOptionsA40D0F => 'Параметры чата';

  @override
  String get uiPausePreview805180 => 'Приостановить предпросмотр';

  @override
  String get uiPlayPreview47BB44 => 'Воспроизвести предпросмотр';

  @override
  String get uiUnmutePreview12A31A => 'Включить звук предпросмотра';

  @override
  String get uiMutePreviewCE44BD => 'Выключить звук предпросмотра';

  @override
  String get uiPauseVoiceMessageECD12D => 'Приостановить голосовое сообщение';

  @override
  String get uiPlayVoiceMessageB16684 => 'Воспроизвести голосовое сообщение';

  @override
  String get uiPlaybackSpeed6FF42B => 'Скорость воспроизведения';

  @override
  String get uiStopRecordingEE0D9D => 'Остановить запись';

  @override
  String get uiDeleteRecording8B58CE => 'Удалить запись';

  @override
  String uiCouldNotLoadOlderGroup1A192E(String value) {
    return 'Не удалось загрузить старую историю группы: $value';
  }

  @override
  String uiMessageScheduledForValueD2D788(String value) {
    return 'Сообщение запланировано на $value.';
  }

  @override
  String get uiNewPoll6D62BD => 'Новый опрос';

  @override
  String get uiQuestion002FF5 => 'Вопрос';

  @override
  String get uiOptionsOnePerLine62FF3D => 'Варианты (по одному в строке)';

  @override
  String get uiDeleteMessageD536CF => 'Удалить сообщение?';

  @override
  String get uiDeleteSelectedMessages190A5F => 'Удалить выбранные сообщения?';

  @override
  String uiDeleteFailedForOneMessage26C302(String value) {
    return 'Не удалось удалить одно сообщение: $value';
  }

  @override
  String get uiNothingToCopyFromTheEC27E3 =>
      'В выбранных сообщениях нечего копировать.';

  @override
  String uiCopiedValueMessageSC97E6E(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Скопировано сообщений: $value.',
      many: 'Скопировано сообщений: $value.',
      few: 'Скопировано сообщений: $value.',
      one: 'Скопировано сообщений: $value.',
    );
    return '$_temp0';
  }

  @override
  String get uiNoSelectedAttachmentIsReady536B54 =>
      'Выбранные вложения ещё не готовы: передача продолжается.';

  @override
  String get uiCopiedMessageText9DC18F => 'Текст сообщения скопирован.';

  @override
  String get uiTheGroupFileIsNotF8A236 => 'Файл группы недоступен локально.';

  @override
  String uiSavedValue0463E5(String value) {
    return 'Сохранено: $value.';
  }

  @override
  String uiCouldNotSaveValueValue178005(String value, String value2) {
    return 'Не удалось сохранить $value: $value2';
  }

  @override
  String get uiTheAndroidFileSaverIsDF910B =>
      'Сохранение файлов Android недоступно.';

  @override
  String get uiOpeningFilesIsUnavailableOnC6ADA2 =>
      'Открытие файлов недоступно на этой платформе.';

  @override
  String uiCouldNotOpenValueValue283326(String value, String value2) {
    return 'Не удалось открыть $value: $value2';
  }

  @override
  String get uiYou905CB3 => 'Вы';

  @override
  String get uiMessage68F414 => 'Сообщение';

  @override
  String get uiMessageActions949184 => 'Действия с сообщением';

  @override
  String get uiTheAttachmentIsStillDownloadingF77317 =>
      'Вложение ещё скачивается.';

  @override
  String get uiShareOrScheduleAGroup2989F0 =>
      'Отправить файл в группу сейчас или позже';

  @override
  String get uiRecordingBelongsToAnotherConversation87E802 =>
      'Запись относится к другому чату';

  @override
  String get uiFinishTheVoicePreviewIn142571 =>
      'Завершите предпросмотр голоса в исходном чате';

  @override
  String get uiReviewUnsentVoiceMessage24931C =>
      'Просмотреть неотправленное голосовое сообщение';

  @override
  String get uiCancelMicrophoneStartup9E9F8A => 'Отменить запуск микрофона';

  @override
  String get uiReleaseToDiscardRecording4C5C71 =>
      'Отпустите, чтобы удалить запись';

  @override
  String get uiRecordingLockedTapToFinish40CD88 =>
      'Запись закреплена · нажмите для завершения';

  @override
  String get uiReleaseToStopSlideLeft4686F1 =>
      'Отпустите для остановки · влево для отмены · вверх для закрепления';

  @override
  String get uiHoldToRecordAGroupC11B32 =>
      'Удерживайте для записи голосового сообщения в группу';

  @override
  String get uiCreatePoll8F5663 => 'Создать опрос';

  @override
  String get uiWriteToGroup5878DB => 'Написать в группу';

  @override
  String get uiWriteAReply0A58E1 => 'Написать ответ';

  @override
  String get uiYouAreNoLongerIn571DA7 => 'Вы больше не в этой группе';

  @override
  String get uiVote64F872 => 'Проголосовать';

  @override
  String get uiChooseOptionsEA120E => 'Выбрать варианты';

  @override
  String get uiRetractVoteA5DA11 => 'Отозвать голос';

  @override
  String get uiClosePollA6A189 => 'Закрыть опрос';

  @override
  String get uiScheduleOneAttachmentAtAC580C3 =>
      'Планируйте по одному вложению за раз.';

  @override
  String get uiNotDeliveredYetSendViaF056E1 =>
      'Ещё не доставлено. Отправить через Matrix…';

  @override
  String get uiVoiceCallsAreTurnedOff692843 =>
      'Голосовые звонки выключены. Включите их в настройках.';

  @override
  String get uiVoiceCallAudioIsUnavailable0B6C43 =>
      'Звук звонков недоступен в этой сборке.';

  @override
  String get uiRouteInspector0E65DE => 'Инспектор маршрутов';

  @override
  String get uiThisContactRequestIsBlocked944F7D =>
      'Этот запрос контакта заблокирован.';

  @override
  String get uiMessageSavedHereUntilTheA49A2C =>
      'Сообщение сохранено здесь до принятия контактом.';

  @override
  String get uiWriteAnEncryptedMessage9F7705 =>
      'Написать зашифрованное сообщение';

  @override
  String get uiWriteAReplyOrAddFC0A42 => 'Написать ответ или добавить подпись';

  @override
  String get uiHoldToRecordAVoice06B1B5 =>
      'Удерживайте для записи голосового сообщения';

  @override
  String get uiWriteToNearbyLANUsers291142 =>
      'Написать пользователям локальной сети';

  @override
  String get uiBroadcast77CA3F => 'Рассылка';

  @override
  String get uiThisRemovesTheLocalContact0D6D1E =>
      'Контакт и локальная история будут удалены. Приложение также попробует отправить уведомление об удалении, чтобы контакт исчез и у собеседника.';

  @override
  String get uiDescriptionBio505243 => 'Описание / о себе';

  @override
  String get uiCheckPaths917FF3 => 'Проверить пути';

  @override
  String get uiCopyState9BFD16 => 'Скопировать состояние';

  @override
  String get uiRemoveContact7F9A8A => 'Удалить контакт';

  @override
  String get uiSaveProfile909BF3 => 'Сохранить профиль';

  @override
  String get uiShowAsBeam74375F => 'Показать как Beam';

  @override
  String get uiShowTheQRAnyway0B0CDF => 'Всё равно показать QR';

  @override
  String get uiOpenFullscreenQRC5418D => 'Открыть QR на весь экран';

  @override
  String get uiShowQRCFBAC6 => 'Показать QR';

  @override
  String get uiLegacyInviteC61C5D => 'Старое приглашение';

  @override
  String get uiForContactsOnConestOr486754 =>
      'Для контактов с Conest 0.3.11 и старее. Маршруты для заблокированных сетей не включены: они придут после соединения.';

  @override
  String get uiRotateCodephraseNow89B2D5 => 'Сменить кодовую фразу сейчас';

  @override
  String get uiEncryptForContactE07450 => 'Зашифровать для контакта';

  @override
  String get uiPublicOpticalTransfer58E3F4 =>
      'Общедоступная оптическая передача';

  @override
  String get uiAnyoneWhoCanSeeTheFAB2D0 =>
      'Любой, кто видит экран, может восстановить файл. Он подписан для проверки целостности, но не является конфиденциальным.';

  @override
  String get uiChoosePublicFile6E2739 => 'Выбрать общедоступный файл';

  @override
  String get uiKeepThisScreenVisibleUntil2261B8 =>
      'Не закрывайте этот экран, пока получатель не сообщит о 100%.';

  @override
  String get uiReceiveConestBeamB05BCB => 'Принять Conest Beam';

  @override
  String get uiDesktopCameraActiveDA0F15 => 'Камера компьютера активна';

  @override
  String get uiPasteOneCbFrame66EA2B => 'Вставить один кадр cb1';

  @override
  String get uiAddFrame2BBA30 => 'Добавить кадр';

  @override
  String get uiContactAliasE07C25 => 'Псевдоним контакта';

  @override
  String get uiWeComparedThisFingerprintIn952BEB =>
      'Мы сравнили этот отпечаток лично';

  @override
  String get uiTrustAndAddContact0962A2 => 'Доверять и добавить контакт';

  @override
  String get uiSavedInPrivateConestStorage4C1334 =>
      'Сохранено в закрытом хранилище Conest:';

  @override
  String get uiResetIdentity8B0224 => 'Сбросить личность';

  @override
  String get uiThisClearsTheEncryptedVault864B3D =>
      'Будут очищены зашифрованное хранилище, контакты и сообщения. Приложение вернётся к первому запуску.';

  @override
  String get uiReset44C57A => 'Сбросить';

  @override
  String get uiNoIdentityIsActive6B2EE3 => 'Нет активной личности.';

  @override
  String get uiSaveNameE73831 => 'Сохранить имя';

  @override
  String get uiSaveBioBE2711 => 'Сохранить описание';

  @override
  String get uiMessageNotifications595635 => 'Уведомления о сообщениях';

  @override
  String get uiShowASystemNotificationWhen90113B =>
      'Показывать системное уведомление при получении личного сообщения.';

  @override
  String get uiExperimentalVoiceCalls51098B =>
      'Экспериментальные голосовые звонки';

  @override
  String get uiExperimentalAndroidBackgroundReceive60828A =>
      'Экспериментальный фоновый приём Android';

  @override
  String get uiDisabledInReleaseBuildsThe45B7DF =>
      'Отключено в релизных сборках: служба переднего плана пока не запускает приёмник Flutter без интерфейса.';

  @override
  String get uiAllowVoiceCallsInBackground73C5C5 =>
      'Разрешить голосовые звонки в фоне';

  @override
  String get uiKeepsCallSignalingActiveAndC0A342 =>
      'Поддерживает сигнализацию звонков и уведомление о текущем звонке, пока работает служба Conest. Требуются экспериментальные голосовые звонки; ограничения батареи Android или принудительная остановка могут прервать доступность.';

  @override
  String get uiDonTSendReadConfirmations230076 =>
      'Не отправлять подтверждения прочтения';

  @override
  String get uiDebugOnlyDeliveryAcknowledgementsStill7D6A9C =>
      'Только для отладки. Подтверждения доставки отправляются, входящие подтверждения прочтения обрабатываются.';

  @override
  String get uiRemoveMetadataFromFilesA4860E => 'Удалять метаданные из файлов';

  @override
  String get uiBeforeSendingRemovesLocationCamera4E390D =>
      'Перед отправкой удаляет сведения о месте, камере, авторе и дате из фото, видео, PDF и офисных документов. Изображения не сжимаются повторно. Остальные файлы отправляются как есть.';

  @override
  String get uiSendFilesUnderRandomNames5F79D4 =>
      'Отправлять файлы под случайными именами';

  @override
  String get uiReplacesFileNamesWithRandom16F099 =>
      'Заменяет имена файлов случайными буквами для вас и получателя. Расширение, например .jpg, сохраняется.';

  @override
  String get uiKeepOfStorageFreeF00434 => 'Оставлять 10% хранилища свободными';

  @override
  String get uiReserveFreeSpaceForOther1AC9CF =>
      'Резервирует место для других приложений. Если выключено, передачи могут использовать его, но файлы должны помещаться на диске.';

  @override
  String get uiLAN2ECD17 => 'LAN';

  @override
  String get uiSameNetworkListenerPairingBeacons5CF0A2 =>
      'Приём в общей сети, маяки сопряжения и доставка по LAN.';

  @override
  String get uiOnlineC3E839 => 'Интернет';

  @override
  String get uiIrohMessagingAndFileTransfersC4D635 =>
      'Сообщения и файлы Iroh через интернет. Собственные ретрансляторы Conest необязательны.';

  @override
  String get uiIrohRelayFallbackE954F7 => 'Резерв через ретрансляторы Iroh';

  @override
  String get uiUseIrohSBuiltIn631E03 =>
      'Использовать встроенные ретрансляторы Iroh, когда прямое соединение не проходит. Оба участника должны быть в сети.';

  @override
  String get uiLimitIrohFilesToMiBB58353 =>
      'Ограничить файлы Iroh до 100 МиБ (рекомендуется)';

  @override
  String get uiAppliesToDirectOnlineAnd28F6F1 =>
      'Для прямых передач через интернет и ретрансляторы Iroh. Выключите для больших файлов: передача может занять много времени. Более высокий лимит LAN сохраняется.';

  @override
  String get uiShareEmailAndMatrixAddressesD762EE =>
      'Делиться адресами почты и Matrix с участниками групп';

  @override
  String get uiLetsMembersOfYourGroups9912A5 =>
      'Позволяет участникам групп, не входящим в ваши контакты, связаться с вами по почте или Matrix. Если выключено, им доступны только адреса Nostr, Tor и радио, не раскрывающие ваше имя. Передача прекратится, но уже увиденные адреса могут сохранить.';

  @override
  String get uiAutomaticDownloads5E777B => 'Автоматические загрузки';

  @override
  String get uiVerifiedContactsOnlyLimitsAdapt8A1876 =>
      'Только проверенные контакты. Лимиты учитывают Wi-Fi/Ethernet, мобильную сеть и роуминг.';

  @override
  String get uiCustomIrohRelayURLsDBF979 =>
      'Собственные URL ретрансляторов Iroh';

  @override
  String get uiOneHTTPSURLPerLineDA8E70 =>
      'По одному URL HTTPS в строке; пустое поле использует стандартные ретрансляторы N0.';

  @override
  String get uiSaveIrohRelaysC144AD => 'Сохранить ретрансляторы Iroh';

  @override
  String get uiCheckAvailabilityFCC1A6 => 'Проверить доступность';

  @override
  String get uiRunThisDeviceAsA9DEA14 =>
      'Использовать устройство как ретранслятор';

  @override
  String get uiAllowTrustedContactsToUse001771 =>
      'Разрешить доверенным контактам использовать устройство как ретранслятор.';

  @override
  String get uiAutoUseContactsAsRelaysC62C06 =>
      'Автоматически использовать контакты как ретрансляторы';

  @override
  String get uiLocalRelayPort28A73C => 'Порт локального ретранслятора';

  @override
  String get uiSavePort1876F6 => 'Сохранить порт';

  @override
  String get uiRelayHostURLF11441 => 'Хост / URL ретранслятора';

  @override
  String get uiRelayPortEA05DA => 'Порт ретранслятора';

  @override
  String get uiDetectAddRelayE825AD => 'Найти и добавить ретранслятор';

  @override
  String get uiErrorHistory25AFF8 => 'История ошибок';

  @override
  String get uiWhatWentWrongKeptAcross27FC1F =>
      'Ошибки сохраняются между запусками этой сборки: их можно скопировать в отчёт.';

  @override
  String get uiReceiveUnstableUpdatesBF7122 =>
      'Получать нестабильные обновления';

  @override
  String get uiAlsoOfferNightlyBuildsNewerA7FAB0 =>
      'Также предлагать ночные сборки: функции новее, проверены меньше. Новая стабильная версия предлагается всегда.';

  @override
  String get uiResetAppIdentity2E0F86 => 'Сбросить личность приложения';

  @override
  String get uiTrustNewKeyA181BE => 'Доверять новому ключу';

  @override
  String get uiVerifyThePersonAndCompare738F28 =>
      'Перед принятием проверьте человека и сравните номер безопасности по другому каналу.';

  @override
  String get uiReviewE29A79 => 'Просмотреть';

  @override
  String get uiDiscardChat319267 => 'Удалить чат';

  @override
  String get uiConfirmIdentityReplacement0219C5 =>
      'Подтвердить замену личности?';

  @override
  String get uiItSThem394960 => 'Это он(а)';

  @override
  String get uiRejectThisIdentityCB604F => 'Отклонить эту личность?';

  @override
  String get uiThisDeletesTheNewContactBB4444 =>
      'Будут удалены новый контакт и ожидающие входящие сообщения. Используйте, если подозреваете подмену личности.';

  @override
  String get uiNotThem685593 => 'Это не он(а)';

  @override
  String get uiRemoveImportedList36FC81 => 'Удалить импортированный список?';

  @override
  String get uiNoBundledConestRelaysOnline46529B =>
      'Встроенных ретрансляторов Conest нет. Интернет-соединения используют Iroh; можно настроить свой ретранслятор.';

  @override
  String get uiImportFromURL3F7B77 => 'Импорт по URL…';

  @override
  String get uiImportRelayListFromURL86E363 =>
      'Импортировать список ретрансляторов по URL';

  @override
  String get uiJSONURL6918BA => 'URL JSON';

  @override
  String get uiOperatorSPublicKeyOptionalA80E7A =>
      'Открытый ключ оператора (необязательно, base64)';

  @override
  String get uiImportD6FBC9 => 'Импортировать';

  @override
  String get uiCLEAN2F3D27 => 'МИНИМУМ';

  @override
  String get uiSUBTLEBB048B => 'СДЕРЖАННО';

  @override
  String get uiDEFAULTC18920 => 'ПО УМОЛЧАНИЮ';

  @override
  String get uiFULLCC0A74 => 'ПОЛНОСТЬЮ';

  @override
  String get uiLANFirstB360D1 => 'Сначала LAN';

  @override
  String get uiLANOnly94945D => 'Только LAN';

  @override
  String get uiOnlineFirst346B6D => 'Сначала интернет';

  @override
  String get uiOnlineOnlyF79CB9 => 'Только интернет';

  @override
  String get uiOfflineE01FA7 => 'Без сети';

  @override
  String get uiUsesLANWhenAvailableFallsA810EF =>
      'Использует LAN, если доступна, иначе интернет.';

  @override
  String get uiUsesLANOnlyNoRelay589D55 =>
      'Только LAN. Без трафика через ретрансляторы для этого контакта.';

  @override
  String get uiUsesOnlineWhenAvailableFallsCE2CAF =>
      'Использует интернет, если доступен, иначе LAN.';

  @override
  String get uiUsesOnlineOnlyNoLAN193810 =>
      'Только интернет. Без трафика LAN для этого контакта.';

  @override
  String get uiNoTransportSelectedThisContact7969EB =>
      'Транспорт не выбран: контакт недоступен.';

  @override
  String get uiGlobalConnectivityIsOffAdjustA7C644 =>
      'Общая связь выключена: измените настройки для отправки.';

  @override
  String get uiSameNetworkDelivery94E793 => 'Доставка в общей сети';

  @override
  String get uiDisabledByGlobalSetting2CB06C => 'Отключено общей настройкой';

  @override
  String get uiAllowIrohRelayFallback35227B =>
      'Разрешить резерв через ретрансляторы Iroh';

  @override
  String get uiVisibleAndOnlineOnlyDirectEA8902 =>
      'Видимый маршрут только через интернет; предпочтителен прямой Iroh.';

  @override
  String get uiRelayInternetDeliveryD64AB6 =>
      'Доставка через ретранслятор / интернет';

  @override
  String get uiPrefer13F662 => 'Предпочитать';

  @override
  String get uiCarryTheirMessages22FD33 => 'Передавать его сообщения';

  @override
  String get uiWhenThisContactCannotReach5C3FF8 =>
      'Если контакт не может связаться с кем-то, а вы можете, передавайте его сообщения. Вам видны только получатель и время; содержимое остаётся зашифрованным.';

  @override
  String uiSaveValueFileSToB46C57(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Сохранить файлов: $value в…',
      many: 'Сохранить файлов: $value в…',
      few: 'Сохранить файлов: $value в…',
      one: 'Сохранить файлов: $value в…',
    );
    return '$_temp0';
  }

  @override
  String get uiSaveCanceled1939D0 => 'Сохранение отменено.';

  @override
  String get uiAlbumActions7B6D70 => 'Действия с альбомом';

  @override
  String get uiCancelSelectionF7F56C => 'Отменить выбор';

  @override
  String get uiCopyAF74F7 => 'Копировать';

  @override
  String get uiSaveAttachments5A74EA => 'Сохранить вложения';

  @override
  String get uiCancelAndClearAllTransfers01B81D =>
      'Отменить и очистить все передачи?';

  @override
  String get uiKeepTransfersDB8CC7 => 'Оставить передачи';

  @override
  String get uiCancelAndClearCCF59C => 'Отменить и очистить';

  @override
  String get uiPauseAll6F6099 => 'Приостановить всё';

  @override
  String get uiResumeAll039916 => 'Возобновить всё';

  @override
  String get uiCancelAndClearAllTransfersACEBB3 =>
      'Отменить и очистить все передачи';

  @override
  String get uiClearCompletedE63FC1 => 'Очистить завершённые';

  @override
  String get uiMoveToTop44AFA6 => 'Переместить вверх';

  @override
  String get uiPreparingDownloadF9B13B => 'Подготовка загрузки';

  @override
  String get uiDownloadA479C9 => 'Скачать';

  @override
  String get uiResumeB3BD0B => 'Возобновить';

  @override
  String get uiPause781961 => 'Приостановить';

  @override
  String get uiRetry9F5CD8 => 'Повторить';

  @override
  String get uiContinueOverIrohRelay949702 =>
      'Продолжить через ретранслятор Iroh';

  @override
  String get uiDownloadAnyway42859F => 'Всё равно скачать';

  @override
  String get uiPreparing96A9B7 => 'Подготовка';

  @override
  String get uiQueued6A5998 => 'В очереди';

  @override
  String get uiWaiting33D306 => 'Ожидание';

  @override
  String get uiTransferring73F753 => 'Передача';

  @override
  String get uiReconnecting9D80F9 => 'Переподключение';

  @override
  String get uiPausedC7DFB6 => 'Приостановлено';

  @override
  String get uiVerifying536244 => 'Проверка';

  @override
  String get uiComplete1F5A1A => 'Завершено';

  @override
  String get uiCanceledF840AC => 'Отменено';

  @override
  String get uiUnavailable2C9C1F => 'Недоступно';

  @override
  String uiSavedValueToValue08F152(String value, String value2) {
    return '$value сохранён в $value2.';
  }

  @override
  String uiGallerySaveFailedValueFalling0B82BB(String value) {
    return 'Не удалось сохранить в галерею ($value); открывается диалог сохранения.';
  }

  @override
  String uiSaveValue5769AA(String value) {
    return 'Сохранить $value';
  }

  @override
  String uiSaveFailedValue534182(String value) {
    return 'Не удалось сохранить: $value';
  }

  @override
  String get uiTheAttachmentFileIsNotA67009 =>
      'Файл вложения недоступен локально.';

  @override
  String uiCopiedValueToClipboard669D0B(String value) {
    return '$value скопирован в буфер обмена.';
  }

  @override
  String uiCopiedValueTextOnlySystemB51B8D(String value) {
    return '«$value» скопировано как текст: двоичные данные в системном буфере недоступны.';
  }

  @override
  String uiCopyFailedValueFilenameCopiedF71C87(String value) {
    return 'Ошибка копирования: $value. Вместо файла скопировано его имя.';
  }

  @override
  String get uiCachePathIsNotReady0404B5 =>
      'Путь к кэшу ещё не готов: передача продолжается.';

  @override
  String uiCachePathCopiedValue4CC1C4(String value) {
    return 'Путь к кэшу скопирован: $value';
  }

  @override
  String get uiVideoIsnTCachedLocally8920DD =>
      'Видео ещё нет в локальном кэше: дождитесь окончания передачи.';

  @override
  String uiCouldNotOpenVideoIn054087(String value) {
    return 'Не удалось открыть видео в системном проигрывателе: $value';
  }

  @override
  String get uiImageIsNotAvailableLocally12017F =>
      'Изображение недоступно локально.';

  @override
  String uiVideoStillTransferringValue3F4049(String value) {
    return 'Видео ещё передаётся ($value%).';
  }

  @override
  String get uiVoiceMessageBytesAreNotF8339B =>
      'Данные голосового сообщения ещё не готовы.';

  @override
  String get uiSendMode265A2D => 'Режим отправки';

  @override
  String get uiLANRelayA05D48 => 'Ретранслятор LAN';

  @override
  String get uiLobbyFDB6D9 => 'Общий чат';

  @override
  String get uiDirectBC8152 => 'Напрямую';

  @override
  String get uiIroh84642D => 'Iroh';

  @override
  String get uiIrohRelayB128EA => 'Ретранслятор Iroh';

  @override
  String get uiRelay9F537F => 'Ретранслятор';

  @override
  String get uiMatrix58947E => 'Matrix';

  @override
  String get uiPlainMatrixBA9DE1 => 'Обычный Matrix';

  @override
  String get uiNostr4D3AD8 => 'Nostr';

  @override
  String get uiEmail84ADD5 => 'Электронная почта';

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
  String get uiViaContactCF1F8E => 'Через контакт';

  @override
  String get uiSendViaMatrix062A08 => 'Отправить через Matrix?';

  @override
  String get uiKeepWaiting9BE1AB => 'Продолжить ожидание';

  @override
  String get uiSendViaMatrix638038 => 'Отправить через Matrix';

  @override
  String uiNotSentViaMatrixValue99F62C(String value) {
    return 'Не отправлено через Matrix: $value';
  }

  @override
  String get uiMessageRoutesFBF32C => 'Маршруты сообщений';

  @override
  String get uiWhatTheColouredMarksOnA10C8E =>
      'Значение цветных отметок на сообщениях';

  @override
  String get uiOpenInDefaultPlayerE64C20 =>
      'Открыть в проигрывателе по умолчанию';

  @override
  String get uiCancelReplyBD62D2 => 'Отменить ответ';

  @override
  String get uiScheduledMessages98CEF4 => 'Запланированные сообщения';

  @override
  String get uiEditScheduledMessage62AF88 =>
      'Изменить запланированное сообщение';

  @override
  String get uiCaption3428D9 => 'Подпись';

  @override
  String get uiNoChatsToShareIntoB50F2F => 'Пока нет чатов для отправки.';

  @override
  String get uiLetDevicesOnThisNetwork42E2F0 =>
      'Разрешить устройствам этой сети доступ к ПК';

  @override
  String get uiAllow3AD0E3 => 'Разрешить';

  @override
  String get uiKeepSignedIn611A13 => 'Остаться в системе';

  @override
  String get uiSignOutHereA6F129 => 'Выйти на этом устройстве';

  @override
  String get uiMatrixPassword34E218 => 'Пароль Matrix';

  @override
  String get uiPassword8BE3C9 => 'Пароль';

  @override
  String get uiYourServerAsksForIt1594FA =>
      'Сервер запрашивает его для создания ключей подписи.';

  @override
  String get uiRecoveryIsAlreadySetUp371F7F => 'Восстановление уже настроено';

  @override
  String get uiOK9CE3BD => 'ОК';

  @override
  String get uiSaveYourRecoveryKey7851B3 => 'Сохраните ключ восстановления';

  @override
  String get uiKeepThisKeySomewhereSafe0C0DFE =>
      'Храните ключ в безопасном месте. Он нужен для чтения зашифрованной истории Matrix на новом устройстве. Ключ показывается только один раз.';

  @override
  String get uiISavedIt3E2255 => 'Я сохранил(а)';

  @override
  String get uiEnterRecoveryKey4521B6 => 'Ввести ключ восстановления';

  @override
  String get uiEsTFromAnotherMatrixAppFCA0C9 =>
      'EsT… (из другого приложения Matrix или этого)';

  @override
  String get uiSignOutDC1649 => 'Выйти';

  @override
  String get uiSetUpRecoveryFD3804 => 'Настроить восстановление';

  @override
  String get uiVerifyWithAnotherSession9ED031 => 'Проверить через другой сеанс';

  @override
  String get uiShowJoinsLeavesAndProfile9FA764 =>
      'Показывать входы, выходы и изменения профиля';

  @override
  String get uiInMatrixRoomsCollapsedIntoD20CAB =>
      'В комнатах Matrix свёрнуто в одну строку';

  @override
  String get uiMatrixUser70A560 => 'Пользователь Matrix';

  @override
  String get uiForExampleNameMatrixOrg63C60A => 'Например, @name:matrix.org';

  @override
  String get uiHomeserverOptional70DF85 => 'Домашний сервер (необязательно)';

  @override
  String get uiFoundFromTheUserId69A3AB =>
      'Определяется по ID пользователя, если не указан';

  @override
  String get uiSignInToMatrix652C8F => 'Войти в Matrix';

  @override
  String get uiSignInWithBrowserC995DF => 'Войти через браузер';

  @override
  String get uiFinishSigningInInYour9F41A4 => 'Завершите вход в браузере.';

  @override
  String get uiCopyLink2F84EE => 'Скопировать ссылку';

  @override
  String get uiThisDeviceFA5A6D => 'Это устройство';

  @override
  String uiOutOfTouchSinceValueA037FD(String value) {
    return 'Нет связи с $value: синхронизация остановлена, пока вы не подтвердите, что устройство ваше.';
  }

  @override
  String uiLinkedValueDCADF7(String value) {
    return 'Подключено $value';
  }

  @override
  String get uiYourContactsWillStopAccepting5B0F03 =>
      'Контакты перестанут принимать данные с этого устройства. Вернуть его нельзя: подключите заново как новое.';

  @override
  String get uiStillMine38C8AE => 'Всё ещё моё';

  @override
  String get uiRemoveDeviceA9C39D => 'Удалить устройство';

  @override
  String get uiLinkADeviceE71635 => 'Подключить устройство';

  @override
  String get uiLinkThisDeviceToMy888A1A =>
      'Подключить это устройство к моему аккаунту';

  @override
  String get uiCheckThatBothDevicesShow031E51 =>
      'Проверьте, что на обоих устройствах этот код:';

  @override
  String get uiTheCodesMatch32C407 => 'Коды совпадают';

  @override
  String get uiLinkedTheNewDeviceNow9900E5 =>
      'Подключено. На новом устройстве теперь ваш аккаунт и контакты; контакты увидят его как вас.';

  @override
  String get uiConfirmTheCodeOnThe17BB1F =>
      'Подтвердите код и на новом устройстве.';

  @override
  String get uiWaitingForTheNewDevice75283F =>
      'Ожидание ответа нового устройства. Если код не появился, убедитесь, что новое устройство всё ещё показывает свой код, а оба подключены к одной сети или интернету.';

  @override
  String get uiOnTheNewDeviceOpen29AF5E =>
      'На новом устройстве откройте Настройки → Устройства → Подключить это устройство к моему аккаунту, затем отсканируйте показанный код.';

  @override
  String get uiScanCode4596C2 => 'Сканировать код';

  @override
  String get uiOrPasteTheCodeE72792 => 'Или вставьте код';

  @override
  String get uiLinkThisDeviceBF5E5C => 'Подключить это устройство';

  @override
  String get uiThisDeviceIsNowLinked7EA826 =>
      'Это устройство теперь подключено к вашему аккаунту.';

  @override
  String get uiWaitingForTheOtherDeviceB39C3F => 'Ожидание другого устройства…';

  @override
  String get uiOnTheDeviceYouAlready92C421 =>
      'На привычном устройстве откройте Настройки → Устройства → Подключить устройство и отсканируйте код. Оба устройства должны быть в одной сети или интернете.';

  @override
  String get uiDeltaChat8BDA67 => 'Delta Chat';

  @override
  String get uiBitchatA99B50 => 'bitchat';

  @override
  String get uiWithAFilterOfTheir4FD18E =>
      'С отдельным фильтром. Если выключено, открываются только из настроек сети.';

  @override
  String get uiYourDeltaChatInviteEE073F => 'Ваше приглашение Delta Chat';

  @override
  String get uiShowTheQRCodeTo0769AD =>
      'Покажите QR-код пользователю Delta Chat или отправьте ссылку. Любой, у кого она есть, может начать с вами проверенный чат.';

  @override
  String get uiShowQRCode2DF2DD => 'Показать QR-код';

  @override
  String get uiDeltaChatChats8EBCBC => 'Чаты Delta Chat';

  @override
  String get uiGroup171A06 => 'Группа';

  @override
  String get uiJoinWithAnInviteC76024 => 'Присоединиться по приглашению';

  @override
  String get uiJoinE0D731 => 'Присоединиться';

  @override
  String get uiNewDeltaChatGroup7D5142 => 'Новая группа Delta Chat';

  @override
  String get uiGroupNameEBB7E1 => 'Имя группы';

  @override
  String get uiMembers1CB449 => 'Участники';

  @override
  String get uiGroupInviteD64669 => 'Приглашение в группу';

  @override
  String get uiYouAreNotInThisCF5BD5 => 'Вы не в этой группе';

  @override
  String get uiStartGroupCallC2A083 => 'Начать групповой звонок';

  @override
  String get uiJoinGroupCallC9ECF8 => 'Присоединиться к групповому звонку';

  @override
  String get uiPushToTalk032E78 => 'Нажать, чтобы говорить';

  @override
  String get uiCarryMessagesOverAReticulum1CE915 =>
      'Передача сообщений через Reticulum, например радиостанции LoRa (RNode) без интернета, через узел rnsd с интерфейсом сервера TCP. У Conest отдельная личность Reticulum; контакты узнают её автоматически.';

  @override
  String get uiNodeAddressRnsdCD61E2 => 'Адрес узла (rnsd)';

  @override
  String get uiUSBDeviceB47FF0 => 'Устройство USB';

  @override
  String get uiRNodeAddress691283 => 'Адрес RNode';

  @override
  String get uiBluetoothAddress0E2BED => 'Адрес Bluetooth';

  @override
  String get uiTCPPortDE05BE => 'Порт TCP';

  @override
  String get uiEU233558 => 'ЕС 869.525';

  @override
  String get uiUS5ED166 => 'США 914.875';

  @override
  String get uiUseConestAsAMatrix6A44C5 =>
      'Использовать Conest только как клиент Matrix?';

  @override
  String get uiYourConestChatsAreHiddenCFD853 =>
      'Чаты Conest будут скрыты, а соединения на этом устройстве остановятся до переключения обратно. Ничего не удаляется. Контакты временно не смогут связаться с вами через Conest; их приложения продолжат попытки и доставят сообщения после возвращения.';

  @override
  String get uiSwitch3E44C9 => 'Переключить';

  @override
  String get uiSealAnimatedRings29BE2D => 'Печать (движущиеся кольца)';

  @override
  String get uiSigilRuneA0B8A7 => 'Символ (руна)';

  @override
  String get uiBlockiePixelHashA265BA => 'Блоки (пиксельный хеш)';

  @override
  String get uiMonogramInitials8C6019 => 'Монограмма (инициалы)';

  @override
  String get uiNewMatrixChatC065C8 => 'Новый чат Matrix';

  @override
  String get uiNameMatrixOrgD0BB06 => '@name:matrix.org';

  @override
  String get uiStartChat18BB58 => 'Начать чат';

  @override
  String get uiCopyText06A76C => 'Скопировать текст';

  @override
  String uiVerifyValue1B6B79(String value) {
    return 'Проверить $value';
  }

  @override
  String get uiAttachAFileAE85E4 => 'Прикрепить файл';

  @override
  String get uiMessageDeleted3271A7 => 'Сообщение удалено';

  @override
  String get uiUnableToDecryptFDF88B => 'Не удалось расшифровать';

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
  String get uiDeclineB59CF9 => 'Отклонить';

  @override
  String get uiCarryMessagesAsEncryptedEmail0D19EA =>
      'Передача сообщений зашифрованной почтой при отказе других маршрутов, как в Delta Chat. Почтовые серверы видят оба адреса и время, но не содержимое. Контакты узнают адрес автоматически.';

  @override
  String get uiUseMyOwnEmailAccountE78C1D =>
      'Использовать свой почтовый аккаунт';

  @override
  String get uiNostrRelaysBD8BAD => 'Ретрансляторы Nostr';

  @override
  String get uiCarryMessagesThroughPublicNostr729B94 =>
      'Передача сообщений через общедоступные ретрансляторы Nostr при отказе других путей. Они видят, что вам пишут и когда, но не кто и что. Используется отдельный ключ; контакты узнают его автоматически.';

  @override
  String get uiRelaysYouReadFromOne020C0A =>
      'Ретрансляторы для чтения (по одному в строке, до 4)';

  @override
  String get uiSaveRelays91CBA8 => 'Сохранить ретрансляторы';

  @override
  String get uiDefaultRelays5C909F => 'Ретрансляторы по умолчанию';

  @override
  String get uiNewChat009BF6 => 'Новый чат';

  @override
  String get uiNodeAddress896F20 => 'Адрес узла';

  @override
  String get uiDeleteChatDB9121 => 'Удалить чат';

  @override
  String get uiTurnOnAppMessagesTo7DCA13 =>
      'Включите сообщения приложений для отправки';

  @override
  String get uiBitchatNearbyD0C416 => 'bitchat рядом';

  @override
  String get uiMeshChat7BF668 => 'Общий чат сети';

  @override
  String get uiHiddenTurnOnReachableBy0103C9 =>
      'Скрыт: включите «Доступен пользователям bitchat»';

  @override
  String get uiTheyDonTMatch27EF0C => 'Не совпадают';

  @override
  String get uiTheyMatch6FB8EB => 'Совпадают';

  @override
  String get uiNameBitchatUsersSee1CE7E3 => 'Имя для пользователей bitchat';

  @override
  String get uiANameYouChooseStays17E677 =>
      'Выбранное имя сохраняется при смене личности, поэтому люди рядом могут узнать вас. Оставьте поле пустым, чтобы с каждой личностью получать новое имя «anon».';

  @override
  String get uiBluetoothMeshC8B7F1 => 'Сеть Bluetooth';

  @override
  String get uiReachContactsNearbyWithoutAny9E9649 =>
      'Общайтесь с контактами рядом без сети: сообщения переходят по Bluetooth между устройствами пользователей Conest и bitchat. Это устройство также передаёт чужие сообщения. Оно не отображается в bitchat, а его сообщения выглядят как обычные личные сообщения bitchat с идентификаторами, меняющимися каждый час.';

  @override
  String get uiReachableByBitchatUsers568021 =>
      'Доступен пользователям bitchat';

  @override
  String get uiShareInternetWithBitchatUsers572F90 =>
      'Делиться интернетом с пользователями bitchat';

  @override
  String get uiChangeNameE46692 => 'Изменить имя';

  @override
  String get uiNewIdentityA119CF => 'Новая личность';

  @override
  String get uiBitchatChatsC74EC3 => 'Чаты bitchat';

  @override
  String get uiTheMatrixClientIsNot01A5B4 =>
      'Клиент Matrix недоступен на этом устройстве, поэтому режим только Matrix здесь невозможен.';

  @override
  String get uiUseConest12EEF3 => 'Использовать Conest';

  @override
  String get uiSearchRoomsCCE4F9 => 'Поиск комнат';

  @override
  String get uiReachContactsThroughTorOnion8B8A98 =>
      'Связь через onion-сервисы Tor: стороны и сеть не узнают местоположение собеседника. Медленнее других маршрутов; добавьте мосты, если Tor заблокирован.';

  @override
  String get uiBridgesOptionalOnePerLine110291 =>
      'Мосты (необязательно, по одному в строке)';

  @override
  String get uiEEFEBFE80B7A =>
      '192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413';

  @override
  String get uiObfsEEFEAD0EDF =>
      'obfs4 192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413 cert=… iat-mode=0';

  @override
  String get uiLinesFromBridgesTorprojectOrgF08389 =>
      'Строки с bridges.torproject.org, начинающиеся с типа: obfs4, webtunnel, snowflake или meek_lite (либо обычные мосты: адрес и отпечаток).';

  @override
  String get uiPlainBridgesOnlyAddressAnd7F0B60 =>
      'В этой сборке только обычные мосты (адрес и отпечаток).';

  @override
  String get uiUseTheseBridgesC1FA11 => 'Использовать эти мосты';

  @override
  String get uiNostrPrivateMessagesDF74A3 => 'Личные сообщения Nostr';

  @override
  String get uiChatWithAnyoneOnNostrA867BC =>
      'Общайтесь с пользователями Nostr (0xchat, Amethyst, Damus и других приложений NIP-17) лично или в небольших группах. Отдельный аккаунт Nostr, не связанный с контактами Conest. Сквозное шифрование без прямой секретности.';

  @override
  String get uiYourNostrAddress5CF7C6 => 'Ваш адрес Nostr';

  @override
  String get uiCopyWithYourRelaysD49669 =>
      'Скопировать (с вашими ретрансляторами)';

  @override
  String get uiNostrChats3D786C => 'Чаты Nostr';

  @override
  String get uiNewNostrChat68199C => 'Новый чат Nostr';

  @override
  String get uiNpubSeveralForAGroupE6ED77 => 'npub1… (несколько для группы)';

  @override
  String get uiCarryShortMessagesOverAFA94B6 =>
      'Короткие сообщения через сеть LoRa MeshCore с помощью подключённой радиостанции без интернета. Conest добавит контакты в радиостанцию для приёма их сообщений.';

  @override
  String get uiMessagesWithMeshCoreAppUsersDE77BA =>
      'Сообщения с пользователями MeshCore';

  @override
  String get uiReadAndWriteTheMeshCore98E60E =>
      'Читайте и отправляйте сообщения приложений MeshCore через эту радиостанцию: контактам и в каналах как групповых чатах. Защита только средствами MeshCore.';

  @override
  String get uiMeshCoreChats82C29C => 'Чаты MeshCore';

  @override
  String get uiSendWithItsDetailsF287FB => 'Отправить с его данными?';

  @override
  String get uiSendAnyway911263 => 'Всё равно отправить';

  @override
  String get uiSaveTheErrorHistory0B3413 => 'Сохранить историю ошибок';

  @override
  String uiSavedTheErrorHistoryTo5271C5(String value) {
    return 'История ошибок сохранена в $value.';
  }

  @override
  String uiSavingTheErrorHistoryFailed72A33A(String value) {
    return 'Не удалось сохранить историю ошибок: $value';
  }

  @override
  String get uiSaveToAFile5BB648 => 'Сохранить в файл';

  @override
  String get uiClear719EA3 => 'Очистить';

  @override
  String get uiFilterD7DECF => 'Фильтр';

  @override
  String get uiErrorsOnlyHideTheDebugECA1DD =>
      'Только ошибки (скрыть отладочный журнал)';

  @override
  String uiValueH171B92(String value) {
    return '$value ч';
  }

  @override
  String uiValueMin439C52(String value) {
    return '$value мин';
  }

  @override
  String uiTheirClockIsAboutValueF406F1(String value) {
    return 'Их часы отличаются примерно на $value $value; здесь время этого устройства.';
  }

  @override
  String uiValueB7CFB44(String value) {
    return '$value Б';
  }

  @override
  String uiValueKB554C06(String value) {
    return '$value КБ';
  }

  @override
  String uiValueMBDB5A1C(String value) {
    return '$value МБ';
  }

  @override
  String uiValueGB0A98F3(String value) {
    return '$value ГБ';
  }

  @override
  String get uiSent27E770 => 'отправлено';

  @override
  String get uiWaitingOnTheRelayED66FF => 'ожидает на ретрансляторе';

  @override
  String get uiReachedTheirDevice0FE289 => 'получено устройством';

  @override
  String get uiDeliveredF81891 => 'доставлено';

  @override
  String get uiReceived38428A => 'получено';

  @override
  String get uiCarryShortMessagesOverADD8570 =>
      'Короткие сообщения через сеть LoRa Meshtastic без интернета с помощью радиостанции Meshtastic. Контактам нужны Conest и радиостанция в той же сети.';

  @override
  String get uiFindDevices98771A => 'Найти устройства';

  @override
  String get uiRadioAddressD288E6 => 'Адрес радиостанции';

  @override
  String get uiMessagesWithMeshtasticAppUsers812B3A =>
      'Сообщения с пользователями Meshtastic';

  @override
  String get uiReadAndWriteTheMeshtastic995E5D =>
      'Читайте и отправляйте сообщения приложений Meshtastic через эту радиостанцию: личные и в каналах как групповых чатах. Защита только средствами Meshtastic.';

  @override
  String get uiMeshtasticChats46BEF8 => 'Чаты Meshtastic';

  @override
  String get uiClearSelection247FD6 => 'Снять выделение';

  @override
  String get uiBrowseFilesAF7C13 => 'Обзор файлов…';

  @override
  String get uiSelectMoreE38EF3 => 'Выбрать ещё';

  @override
  String get uiAllowAllA16326 => 'Разрешить всё';

  @override
  String get uiCaptionDA5C59 => 'Подпись…';

  @override
  String get uiOpenSettingsFD7108 => 'Открыть настройки';

  @override
  String get uiDiscardChangesD3F0B4 => 'Отменить изменения?';

  @override
  String get uiYourEditsWillBeLostB34663 =>
      'Изменения будут потеряны. Исходное изображение останется в галерее.';

  @override
  String get uiKeepEditingD4D9E3 => 'Продолжить редактирование';

  @override
  String get uiDiscard36FFF6 => 'Отменить';

  @override
  String get uiRotateLeft6F72F3 => 'Повернуть влево';

  @override
  String get uiRotateRightB75F23 => 'Повернуть вправо';

  @override
  String get uiApplyCropA43CCF => 'Применить обрезку';

  @override
  String get uiCropC5DB3D => 'Обрезать';

  @override
  String get uiVerifiedDownloadProgressBED7C2 =>
      'Проверенный прогресс загрузки';

  @override
  String get uiSharingWithGroup2AED71 => 'Раздаётся группе';

  @override
  String get uiOpenCF9B77 => 'Открыть';

  @override
  String get uiStopSharing0E45AE => 'Прекратить раздачу';

  @override
  String get uiRemoveLocalCopy80FA01 => 'Удалить локальную копию';

  @override
  String get uiScanInviteEFC78A => 'Сканировать приглашение';

  @override
  String uiValueValue176D15(String value, String value2) {
    return '$value:$value2';
  }

  @override
  String uiDefaultRelayValueBD3FD1(String value) {
    return 'ретранслятор по умолчанию $value';
  }

  @override
  String uiSamplesValueSlowOverMsValueAE2EBF(String value, String value2) {
    return 'samples=$value slowOver100ms=$value2 maxTotalMs=$value maxBuildMs=$value maxRasterMs=$value';
  }

  @override
  String get uiConversation2A20C7 => 'Беседа';

  @override
  String uiSharedValueWithTheGroup163418(String value) {
    return '$value отправлен в группу как обычное вложение; некоторым участникам нужно обновление для воспроизведения голоса.';
  }

  @override
  String uiSharedValueWithTheGroupAE4134(String value) {
    return '$value отправлен в группу.';
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
  String get uiNone3C6B18 => '(нет)';

  @override
  String uiLANNodeValueOn5D539E(String value) {
    return 'Узел LAN :$value включён';
  }

  @override
  String get uiLANNodeUnavailable9CFA32 => 'Узел LAN недоступен';

  @override
  String uiLANValueA8EEF3(String value) {
    return 'LAN $value';
  }

  @override
  String uiRelayValueDownD6B267(String value) {
    return 'ретранслятор $value недоступен';
  }

  @override
  String uiRelayValueA6D70A(String value) {
    return 'ретранслятор $value';
  }

  @override
  String get uiNoInternetRelay55D2CE => 'нет интернет-ретранслятора';

  @override
  String uiValueValue42DC94(String value, String value2) {
    return '$value=$value2';
  }

  @override
  String uiValueHasBeenOutOf039D48(String value) {
    return 'С $value давно нет связи: синхронизация остановлена до подтверждения в Настройки → Устройства.';
  }

  @override
  String uiValueIsOneOfYourE4FD9C(String value) {
    return '$value теперь ваше устройство; старый чат с ним больше не отображается.';
  }

  @override
  String uiYourDevicesDisagreeOnWhich2E7001(String value) {
    return 'Устройства расходятся в составе аккаунта: вместе их будет больше $value. Удалите одно в Настройки → Устройства.';
  }

  @override
  String uiValueAddedADeviceValue710908(String value, String value2) {
    return '$value добавил(а) устройство: $value2.';
  }

  @override
  String uiUnknownValue9B520C(String value) {
    return 'Неизвестный $value';
  }

  @override
  String uiReadByAllValue43BA5A(String value) {
    return 'Прочитано всеми: $value';
  }

  @override
  String uiDeliveredToAllValue71E077(String value) {
    return 'Доставлено всем: $value';
  }

  @override
  String uiAcceptedByValueOfValue826A0E(String value, String value2) {
    return 'Принято: $value из $value2';
  }

  @override
  String uiWaitingForValueMemberS5A8BA6(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Ожидание участников: $value',
      many: 'Ожидание участников: $value',
      few: 'Ожидание участников: $value',
      one: 'Ожидание участников: $value',
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
    return '$value пропущен: $value2 МБ превышает предел $value3 МБ.';
  }

  @override
  String get uiRoute499952 => 'Маршрут';

  @override
  String get uiSafetyNumber5ED2D3 => 'Номер безопасности';

  @override
  String get uiIrohEndpoint72F674 => 'Конечная точка Iroh';

  @override
  String get uiDeviceA5A74A => 'Устройство';

  @override
  String get uiLANLobbyC16DC8 => 'Общий чат LAN';

  @override
  String uiMembersValue541E72(String value) {
    return 'Участники · $value';
  }

  @override
  String get uiNodeOnlineFAC64A => 'Узел · в сети';

  @override
  String uiSafetyValueC542B8(String value) {
    return 'безопасность $value';
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
      other: '$value участника',
      many: '$value участников',
      few: '$value участника',
      one: '$value участник',
    );
    return '$_temp0';
  }

  @override
  String get uiPairwise64A0EF => 'попарно';

  @override
  String get uiPasteMedia4831DE => 'Вставить медиа';

  @override
  String get uiRELAYA1C0CF => 'РЕТРАНСЛЯТОР';

  @override
  String get uiSentAsAPlainMatrixAAE694 =>
      'Отправлено обычным сообщением Matrix';

  @override
  String get uiOnlyOnThisDevice7D64C4 => 'Только на этом устройстве';

  @override
  String get uiConnectivityIsOffTurnOnE42D4A =>
      'Связь выключена. Включите LAN или интернет для обмена приглашением.';

  @override
  String get uiConnectivityIsOffTurnOnFA573F =>
      'Связь выключена. Перед отправкой приглашения включите LAN или интернет.';

  @override
  String get uiReceiveBeam2CB58B => 'Принять Beam';

  @override
  String get uiSendEncryptedFile99D424 => 'Отправить зашифрованный файл';

  @override
  String get uiSendPublicFileF81389 => 'Отправить общедоступный файл';

  @override
  String get uiBeamContactInvite2BAB4C => 'Приглашение контакта через Beam';

  @override
  String get uiDevicesDF485C => 'Устройства';

  @override
  String get uiWARNC2FD77 => 'WARN';

  @override
  String get uiDOWN30E504 => 'DOWN';

  @override
  String get uiAVGRTTE96B26 => 'AVG RTT';

  @override
  String uiRoutingValueFC4557(String value) {
    return 'Маршрутизация — $value';
  }

  @override
  String uiActiveValueC78B63(String value) {
    return 'Активные ($value)';
  }

  @override
  String uiRecentValueB82237(String value) {
    return 'Недавние ($value)';
  }

  @override
  String get uiDirect24A173 => 'напрямую';

  @override
  String get uiRelayBD28B2 => 'ретранслятор';

  @override
  String get uiRoutingECF60A => 'маршрутизация';

  @override
  String uiInvitationValue6F0633(String value) {
    return 'Приглашение: $value';
  }

  @override
  String get uiMeshChatNearbyA35A63 => 'Общий чат сети (рядом)';

  @override
  String get uiVerifiedWithAnInviteBD826F => 'Проверено приглашением';

  @override
  String get uiHoldToTalkOrHold74FC22 =>
      'Удерживайте для разговора или зажмите пробел';

  @override
  String get uiEndToEndEncryptedMatrix9E4418 => 'Сквозное шифрование (Matrix)';

  @override
  String get uiVerifiedAED3B8 => 'Проверен';

  @override
  String uiValueValue64684F(String value, String value2) {
    return '$value · $value2';
  }

  @override
  String get uiPrimaryChannel53B8E1 => 'Основной канал';

  @override
  String uiChannelValue76ED1D(String value) {
    return 'Канал $value';
  }

  @override
  String get uiPublicChannelA9795B => 'Общедоступный канал';

  @override
  String get uiDescriptionCB3291 => 'описание';

  @override
  String uiTheirClockIsAboutValue7DB956(String value, String value2) {
    return 'Их часы отличаются примерно на $value $value2; здесь время этого устройства.';
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
  String get uiConestTransfer406028 => 'Передача Conest';

  @override
  String uiValueConestTransfersF846F8(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Передач Conest: $value',
      many: 'Передач Conest: $value',
      few: 'Передач Conest: $value',
      one: 'Передач Conest: $value',
    );
    return '$_temp0';
  }

  @override
  String uiViaValueValue37232D(String value, String value2) {
    return 'через $value ($value2)';
  }

  @override
  String get uiBackThroughTheContactWhoD09BD0 =>
      'обратно через контакт, передавший сообщение';

  @override
  String uiConestRelayValue4FB2DB(String value) {
    return 'Ретранслятор Conest $value';
  }

  @override
  String get uiConestIsAlreadyRunningEE8037 => 'Conest уже запущен';

  @override
  String get uiCloseTheExistingConestWindow83B30B =>
      'Сначала закройте текущее окно Conest. Второй экземпляр будет конфликтовать за порт локального ретранслятора и зашифрованное хранилище.';

  @override
  String get uiChooseWhereConestStoresData0CF613 =>
      'Выберите, где Conest хранит данные';

  @override
  String get uiGhostModeIsBestEffort694912 =>
      'Режим «Призрак» защищает приватность по возможности: история запусков ОС, журналы сбоев, метаданные сети, история оболочки, недавние файлы и системные кэши не контролируются приложением.';

  @override
  String get uiDefaultOnThisDevice10343F => 'По умолчанию на этом устройстве';

  @override
  String get uiUseTheNormalAppDataF44F79 =>
      'Обычная папка данных приложения и хранилище ключей устройства при выборе авторазблокировки.';

  @override
  String get uiGhostPortableBesideTheApp31A40D =>
      'Призрак / переносной рядом с приложением';

  @override
  String get uiStoreConestControlledFilesIn7DA307 =>
      'Хранить управляемые Conest файлы в папке conest_data рядом с приложением.';

  @override
  String get uiVaultUnlock602BF6 => 'Разблокировка хранилища';

  @override
  String get uiKeyFileAutoUnlock66AC4A => 'Авторазблокировка файлом ключа';

  @override
  String get uiKeepsTheKeyBesideTheB045D9 =>
      'Ключ хранится рядом с хранилищем. Любой с доступом к папке сможет открыть его.';

  @override
  String get uiAutoUnlockWithThisDeviceE7F781 =>
      'Авторазблокировка этим устройством';

  @override
  String get uiStoresTheVaultKeyInC7B1CD =>
      'Ключ хранилища сохраняется в защищённом хранилище системы.';

  @override
  String get uiPassphraseUnlock13B14C => 'Разблокировка парольной фразой';

  @override
  String get uiAskForAPassphraseOn4BA25C =>
      'Запрашивать парольную фразу при каждом запуске. Забытую фразу восстановить нельзя.';

  @override
  String get uiUnlockConest033EB6 => 'Разблокировать Conest';

  @override
  String get uiEnterThePassphraseForThis891200 =>
      'Введите парольную фразу хранилища.';

  @override
  String get uiNoUpdateIsAvailableRightA5EB48 =>
      'Сейчас нет доступных обновлений.';

  @override
  String uiValueIsAvailableOnTheD338C4(String value, String value2) {
    return '$value доступен в канале $value2.';
  }

  @override
  String uiCurrentBuildValue2FD415(String value) {
    return 'Текущая сборка: $value';
  }

  @override
  String get uiWhatSNew4D8DC5 => 'Что нового';

  @override
  String get uiSERVERLESSSECUREMESSENGER1E1891 =>
      '◢ БЕЗОПАСНЫЙ МЕССЕНДЖЕР БЕЗ СЕРВЕРА';

  @override
  String uiYourMatrixSessionValueWants580E45(String value) {
    return 'Ваш сеанс Matrix $value хочет проверить этот сеанс. Принимайте, только если вы начали проверку.';
  }

  @override
  String uiValueWantsToVerifyYou61FD9D(String value) {
    return '$value хочет проверить вас сравнением эмодзи. Проверьте полный адрес: бывают похожие. Принимайте, только если можете сравнить лично или по звонку; проверка помечает ключи доверенными.';
  }

  @override
  String uiCouldNotVerifyValue3AE1C4(String value) {
    return 'Не удалось проверить: $value';
  }

  @override
  String get uiSendWithoutResumableCopy0475F4 =>
      'Отправить без возобновляемой копии?';

  @override
  String uiValueCouldNotBeCopied06F61A(
    String value,
    String value2,
    String value3,
  ) {
    return 'Не удалось скопировать $value в закрытое хранилище передач.\n\n$value2\n\nПриложение может читать оригинал напрямую, но передача не возобновится после перезапуска, если файл переместят или истечёт разрешение.$value3';
  }

  @override
  String get uiUnmute7044C3 => 'Включить микрофон';

  @override
  String get uiMute0F0973 => 'Выключить микрофон';

  @override
  String get uiSpeakerOn93982E => 'Динамик включён';

  @override
  String get uiSpeakerOff97823A => 'Динамик выключен';

  @override
  String get uiCancelCallCE6C16 => 'Отменить звонок';

  @override
  String uiValueValueReturnToCall49F82C(String value, String value2) {
    return '$value$value2 · Вернуться к звонку';
  }

  @override
  String get uiContactDetailsD4EC65 => 'О контакте';

  @override
  String uiValueActiveMemberValue6700F2(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Активных участников: $value',
      many: 'Активных участников: $value',
      few: 'Активных участников: $value',
      one: 'Активных участников: $value',
    );
    return '$_temp0';
  }

  @override
  String get uiOwner89FF31 => 'Владелец';

  @override
  String uiEditValue75BE00(String value) {
    return 'Изменить $value';
  }

  @override
  String uiCouldNotSaveChatSettings2372B2(String value) {
    return 'Не удалось сохранить настройки чата: $value';
  }

  @override
  String get uiAddAContactToStart165431 =>
      'Добавьте контакт, чтобы начать общение';

  @override
  String get uiNoContactsFound816015 => 'Контакты не найдены';

  @override
  String uiOpenValue8DF02B(String value) {
    return 'Открыть #$value';
  }

  @override
  String get uiNoMessagesYetC04921 => 'Пока нет сообщений';

  @override
  String get uiNoActivityYetPairA7F5366 =>
      'Пока нет событий: добавьте контакт для начала журнала.';

  @override
  String get uiSENT5AD0CD => 'ОТПР';

  @override
  String get uiRECVBFC296 => 'ПОЛУЧ';

  @override
  String uiDeviceValue11AEA9(String value) {
    return 'устройство $value';
  }

  @override
  String get uiFreeForAllLocalChat5485CC =>
      'Открытый локальный чат • недоверенный';

  @override
  String get uiGroupsAE9629 => 'Группы';

  @override
  String get uiAddTrustedContactsBeforeCreating1084CC =>
      'Добавьте доверенные контакты перед созданием группы.';

  @override
  String get uiNoGroupsYet5009C6 => 'Пока нет групп.';

  @override
  String uiValueMemberSE75249(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value участника',
      many: '$value участников',
      few: '$value участника',
      one: '$value участник',
    );
    return '$_temp0';
  }

  @override
  String get uiContactsB0DD61 => 'Контакты';

  @override
  String get uiAppliesToFutureAdmissionsHistory78E3A0 =>
      'Для будущих вступлений. Уже полученную историю отозвать нельзя.';

  @override
  String uiValueAllRetainedHistory5E25F4(String value) {
    return '$valueВся сохранённая история';
  }

  @override
  String uiValueSinceAdmissionB2617B(String value) {
    return '$valueС момента вступления';
  }

  @override
  String uiDeleteValueF0396B(String value) {
    return 'Удалить «$value»';
  }

  @override
  String uiDeleteValueForEveryone12E724(String value) {
    return 'Удалить «$value» у всех?';
  }

  @override
  String uiValueMemberSOwnerValueE42E13(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Участников: $value • владелец $value2',
      many: 'Участников: $value • владелец $value2',
      few: 'Участников: $value • владелец $value2',
      one: 'Участников: $value • владелец $value2',
    );
    return '$_temp0';
  }

  @override
  String get uiGROUPTRUSTFANOUTMintPaired5DDF6E =>
      '// GROUP TRUST FANOUT · mint = paired';

  @override
  String get uiAddTrustedContact126717 => 'Добавить доверенный контакт';

  @override
  String get uiNoAvailableChats1FAA40 => 'Нет доступных чатов';

  @override
  String get uiForwardedMessageQueuedC82DA4 =>
      'Пересланное сообщение поставлено в очередь';

  @override
  String uiCouldNotForwardValue80193D(String value) {
    return 'Не удалось переслать: $value';
  }

  @override
  String get uiForwardedAttachmentQueued57C88B =>
      'Пересланное вложение поставлено в очередь';

  @override
  String uiCouldNotForwardAttachmentValue5165FD(String value) {
    return 'Не удалось переслать вложение: $value';
  }

  @override
  String get uiChatDetails15DAEC => 'О чате';

  @override
  String get uiConnectionDetailsAB30A5 => 'Сведения о соединении';

  @override
  String uiValueValue270519(String value, String value2) {
    return '$value / $value2';
  }

  @override
  String uiVoiceMessageValue2F0300(String value) {
    return 'Голосовое сообщение · $value';
  }

  @override
  String uiPlaybackFailedValue1C0E1A(String value) {
    return 'Ошибка воспроизведения: $value';
  }

  @override
  String get uiPreparingMicrophone0BBF4A => 'Подготовка микрофона…';

  @override
  String get uiPreparingPreview312E7B => 'Подготовка предпросмотра…';

  @override
  String uiVoiceMessagePreviewValue8235CB(String value) {
    return 'Предпросмотр голосового сообщения · $value';
  }

  @override
  String uiRecordingValueValue111FF1(String value, String value2) {
    return 'Запись$value · $value2';
  }

  @override
  String get uiSendingCF7655 => 'Отправка…';

  @override
  String uiValue72F816(String value) {
    return '$value×';
  }

  @override
  String get uiSingleChoice68E3E0 => 'Один вариант';

  @override
  String get uiMultipleChoiceB88936 => 'Несколько вариантов';

  @override
  String uiThisRemovesTheMessageFor2247A2(String value) {
    return 'Сообщение удалится у участников группы при синхронизации.$value';
  }

  @override
  String get uiCouldNotLocateThisMessage220E83 =>
      'Не удалось найти сообщение в текущем чате';

  @override
  String uiDeleteValueMessageValueForABA7AC(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Удалить сообщений для группы: $value?',
      many: 'Удалить сообщений для группы: $value?',
      few: 'Удалить сообщений для группы: $value?',
      one: 'Удалить сообщений для группы: $value?',
    );
    return '$_temp0';
  }

  @override
  String uiValueValue29C8B9(String value, String value2) {
    return '$value $value2';
  }

  @override
  String get uiNewC2A6B0 => 'новое';

  @override
  String get uiEditedA22FCA => 'изменено';

  @override
  String get uiCopyCachePathC23134 => 'Скопировать путь к кэшу';

  @override
  String get uiStopKeepingOfflineAABFC7 => 'Не хранить офлайн';

  @override
  String get uiKeepOffline123286 => 'Хранить офлайн';

  @override
  String get uiForwardFileC4B5CB => 'Переслать файл';

  @override
  String get uiLoadingHistory02CB12 => 'Загрузка истории…';

  @override
  String get uiLoadOlderMessages07471F => 'Загрузить более ранние сообщения';

  @override
  String get uiShareFileNow96E2A2 => 'Отправить файл сейчас';

  @override
  String get uiScheduleFile690A92 => 'Запланировать файл';

  @override
  String get uiDropToShareThisFile0B73E8 =>
      'Отпустите, чтобы отправить файл в группу';

  @override
  String get uiClosed88D86B => 'Закрыт';

  @override
  String get uiVisibleVotes460E7A => 'Открытые голоса';

  @override
  String uiValueVoteSWereNot02CC9A(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'В итоговую запись создателя не попало голосов: $value.',
      many: 'В итоговую запись создателя не попало голосов: $value.',
      few: 'В итоговую запись создателя не попало голосов: $value.',
      one: 'В итоговую запись создателя не попало голосов: $value.',
    );
    return '$_temp0';
  }

  @override
  String get uiVotingIsUnavailableWithThis9B92E7 =>
      'Голосование недоступно в этой версии Conest.';

  @override
  String get uiThisRemovesTheMessageHere61D27C =>
      'Сообщение удалится здесь; доступному контакту будет отправлена просьба удалить его копию.';

  @override
  String get uiThisRemovesTheMessageFrom6A47E2 =>
      'Сообщение удалится с этого устройства.';

  @override
  String get uiSendViaMatrix3868FE => 'Отправить через Matrix…';

  @override
  String get uiNotesFilesAndForwardsOnlyB0145F =>
      'Заметки, файлы и пересылки, только на этом устройстве';

  @override
  String uiValueSafetyValue82C755(String value, String value2) {
    return '$value • безопасность $value2';
  }

  @override
  String uiDropFilesToSendMax106011(String value) {
    return 'Перетащите файлы для отправки (до $value)';
  }

  @override
  String get uiFreeForAllLocalChatBC90D2 =>
      'Открытый локальный чат. Сообщения подписаны ключами сеанса, но участники не являются доверенными контактами.';

  @override
  String get uiNoLANLobbyMessagesYetBCDC4B =>
      'В общем чате LAN пока нет сообщений. Устройства Conest рядом получат сообщения, пока они в этой локальной сети.';

  @override
  String uiValueUntrusted519A32(String value) {
    return '$value • недоверенный';
  }

  @override
  String uiRemoveValueF4FE4B(String value) {
    return 'Удалить $value?';
  }

  @override
  String get uiAvailablePaths6EE503 => 'Доступные пути';

  @override
  String get uiRunACheckToMeasure5D76A5 =>
      'Запустите проверку задержки, доступности и свежести данных о связи. Сначала идут лучшие прямые пути или LAN, затем резервные ретрансляторы.';

  @override
  String get uiNoRouteHintsAreAdvertisedB25540 =>
      'Контакт не объявляет доступные маршруты.';

  @override
  String get uiEitherInputIsEnoughOn020B90 =>
      'Достаточно одного способа. Отсканируйте или вставьте QR-приглашение для прямого доверия либо введите текущую кодовую фразу, чтобы найти отправителя по LAN или настроенному ретранслятору. Если обмен не удастся, приложение предложит попросить собеседника добавить вас или отменить.';

  @override
  String get uiInvitePreview6433A0 => 'Предпросмотр приглашения';

  @override
  String uiValueValueValue98AECE(String value, String value2, String value3) {
    return '$value$value2 • $value3';
  }

  @override
  String get uiShareInviteDBCC1E => 'Поделиться приглашением';

  @override
  String get uiThisInviteWorksOnlyOnB106B0 =>
      'Приглашение работает только в общей сети: интернет-маршрут не включён. Включите ретрансляторы Iroh, ретранслятор Conest или транспорт (Nostr, почта) в Настройки → Связь, чтобы вас можно было добавить откуда угодно.';

  @override
  String get uiThisInviteAlsoListsYourEF3A4F =>
      'Приглашение также содержит маршруты для заблокированных сетей и слишком велико для одного QR-кода. Покажите его через Beam: другая камера считает анимированный QR за несколько секунд.';

  @override
  String get uiQRRenderingIsDeferredOn8A6997 =>
      'Отрисовка QR в Windows отложена.';

  @override
  String get uiUseTheCodephraseBelowOrB6A588 =>
      'Используйте кодовую фразу ниже или отрисуйте QR после открытия страницы.';

  @override
  String get uiScanningTheCompactQRIs9459D9 =>
      'Достаточно отсканировать компактный QR. Если камера не справляется, откройте его на весь экран или используйте текущую кодовую фразу.';

  @override
  String uiQRPayloadValueCharactersBABEDF(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Данные QR: $value символов',
      many: 'Данные QR: $value символов',
      few: 'Данные QR: $value символов',
      one: 'Данные QR: $value символов',
    );
    return '$_temp0';
  }

  @override
  String uiAlsoListsYourAddressesOnC5D815(String value) {
    return 'Также содержит ваши адреса в: $value.';
  }

  @override
  String uiPinnedValue834309(String value) {
    return 'Закреплён · $value';
  }

  @override
  String get uiNoVerifiedCiContactsAre3FD190 =>
      'Пока нет проверенных контактов ci6.';

  @override
  String get uiCloseUpTransferE6BA46 => 'Передача вблизи';

  @override
  String get uiALoopingLTFountainStream840218 =>
      'Циклический поток фонтанного кода LT переносит пропущенные, повторные и переставленные QR-кадры. Хеш итогового файла проверяется до принятия.';

  @override
  String get uiPUBLICVisibleToAnyoneNearbyA775C2 =>
      'ОБЩЕДОСТУПНО · видно всем рядом';

  @override
  String get uiCONTACTENCRYPTED879896 => 'ЗАШИФРОВАНО ДЛЯ КОНТАКТА';

  @override
  String get uiSIGNEDCONTACTINVITE752317 => 'ПОДПИСАННОЕ ПРИГЛАШЕНИЕ';

  @override
  String uiFrameValueValueSourceBlocks9C37CB(
    String value,
    int value2,
    String value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value2,
      locale: localeName,
      other: 'Кадр $value · исходных блоков: $value2 · $value3',
      many: 'Кадр $value · исходных блоков: $value2 · $value3',
      few: 'Кадр $value · исходных блоков: $value2 · $value3',
      one: 'Кадр $value · исходных блоков: $value2 · $value3',
    );
    return '$_temp0';
  }

  @override
  String get uiPointThisCameraAtThe2EA3F7 =>
      'Направьте камеру на анимированный QR Beam. Из нативного сканера выходят только декодированные кадры cb1.';

  @override
  String get uiNativeDesktopCameraCaptureIs4619C8 =>
      'Нативный захват камеры компьютера недоступен. Вставьте кадры cb1 ниже: декодирование протокола и проверка те же.';

  @override
  String uiValueValueBlocksValueFrames66F819(
    String value,
    String value2,
    String value3,
    String value4,
  ) {
    return 'Блоки: $value/$value2 · кадров: $value3 · неверных: $value4';
  }

  @override
  String get uiSignedContactInviteA7CC8B => 'Подписанное приглашение контакта';

  @override
  String get uiPUBLICUNTRUSTEDTheSignatureProves96FA7F =>
      'ОБЩЕДОСТУПНО / НЕДОВЕРЕННО. Подпись подтверждает один ключ для всех кадров, но не личность его владельца.';

  @override
  String get uiEncryptedAndAuthenticatedAsA68B7E4 =>
      'Зашифровано и подтверждено как закреплённый контакт Conest.';

  @override
  String get uiSignatureValidCompareTheFingerprintA8A1FE =>
      'Подпись верна. Сравните отпечаток лично.';

  @override
  String get uiAcceptAndSavePublicFile852517 =>
      'Принять и сохранить общедоступный файл';

  @override
  String get uiSaveFileBEDC84 => 'Сохранить файл';

  @override
  String get uiFullscreenCompactInviteQRCF6B8B =>
      'Компактный QR приглашения на весь экран';

  @override
  String uiValueCharactersIncreaseScreenBrightnessA5AF7D(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other:
          'Символов: $value. Увеличьте яркость экрана, если сканирование нестабильно.',
      many:
          'Символов: $value. Увеличьте яркость экрана, если сканирование нестабильно.',
      few:
          'Символов: $value. Увеличьте яркость экрана, если сканирование нестабильно.',
      one:
          'Символов: $value. Увеличьте яркость экрана, если сканирование нестабильно.',
    );
    return '$_temp0';
  }

  @override
  String get uiPersonalPreferencesBD0D61 => 'Личное / Настройки';

  @override
  String get uiNetworkRelay4F9A27 => 'Сеть / Ретранслятор';

  @override
  String get uiDanger58D175 => 'Опасные действия';

  @override
  String get uiAllowsOneToOneIroh45EEF1 =>
      'Разрешает личные голосовые звонки Iroh на этом устройстве. Выключите, чтобы не совершать и не принимать звонки.';

  @override
  String get uiPrivacyOfFilesYouSend4E4A5B => 'Приватность отправляемых файлов';

  @override
  String get uiLowA12494 => 'Низкий';

  @override
  String get uiMediumD40496 => 'Средний';

  @override
  String get uiHighB1A595 => 'Высокий';

  @override
  String get uiTransportPolicy088D79 => 'Политика транспорта';

  @override
  String get uiPerContactRoutingIsIntersected88E292 =>
      'Маршрутизация контактов ограничена этими флагами. Выключение одного ограничивает трафик, обоих — останавливает сетевую активность.';

  @override
  String get uiConnectivityIsFullyOffTheB12483 =>
      'Связь полностью выключена: приложение не отправляет и не принимает.';

  @override
  String uiValueCandidateRouteSAre175673(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Сейчас доступно маршрутов: $value.',
      many: 'Сейчас доступно маршрутов: $value.',
      few: 'Сейчас доступно маршрутов: $value.',
      one: 'Сейчас доступно маршрутов: $value.',
    );
    return '$_temp0';
  }

  @override
  String get uiConfiguredRelays3CA0DE => 'Настроенные ретрансляторы';

  @override
  String get uiNoRelaysAddedYetF791E7 => 'Ретрансляторы ещё не добавлены.';

  @override
  String uiCurrentBuildValueValue9A675D(String value, String value2) {
    return 'Текущая сборка: $value • $value2';
  }

  @override
  String uiCommitValue2E080C(String value) {
    return 'коммит $value';
  }

  @override
  String uiAvailableValue4B15F7(String value) {
    return 'Доступно: $value';
  }

  @override
  String get uiChecking494D0F => 'Проверка…';

  @override
  String get uiCheckForUpdates8604FF => 'Проверить обновления';

  @override
  String uiTrustNewIdentityForValue8B0612(String value) {
    return 'Доверять новой личности $value?';
  }

  @override
  String uiTheRelayIsNowSigningFF71FD(String value) {
    return 'Ретранслятор теперь подписывает другим открытым ключом Ed25519 ($value). Продолжайте, только если оператор подтвердил смену ключа; иначе возможна атака посредника.';
  }

  @override
  String get uiRelayIdentityChanged097638 =>
      'Личность ретранслятора изменилась';

  @override
  String get uiAConfiguredRelayIsSigning60EED0 =>
      'Настроенный ретранслятор подписывает новым ключом. Проверьте смену у оператора перед доверием.';

  @override
  String uiValueValue66746D(String value, String value2) {
    return '$value → $value2';
  }

  @override
  String get uiNoPendingContactRequests697615 =>
      'Нет ожидающих запросов контактов';

  @override
  String uiCouldNotReviewRequestValue82B3D5(String value) {
    return 'Не удалось просмотреть запрос: $value';
  }

  @override
  String uiAddValueF034EE(String value) {
    return 'Добавить $value?';
  }

  @override
  String uiCouldNotAddContactValue7F6C38(String value) {
    return 'Не удалось добавить контакт: $value';
  }

  @override
  String uiCouldNotRejectRequestValue2EFD58(String value) {
    return 'Не удалось отклонить запрос: $value';
  }

  @override
  String get uiContactRequestRejected447EE8 => 'Запрос контакта отклонён.';

  @override
  String uiContactRequestFromValue50B6AC(String value) {
    return 'Запрос контакта от $value';
  }

  @override
  String uiUnverifiedValueC1937C(String value) {
    return 'Не проверен · $value';
  }

  @override
  String uiContactRequestFailedValue28DD81(String value) {
    return 'Не удалось отправить запрос: $value';
  }

  @override
  String get uiRequestAgain7B0434 => 'Запросить снова';

  @override
  String uiTrustValueAsAFresh7BF87F(String value, String value2) {
    return 'Доверять $value как новому контакту? Сначала проверьте номер безопасности по другому каналу: прежние записи «$value2» будут архивированы только для чтения.';
  }

  @override
  String uiTrustThisAsAReinstallCBA4CC(String value) {
    return 'Считать это переустановкой «$value»? Старый контакт будет архивирован с историей только для чтения, новый заменит его. Отменить нельзя.';
  }

  @override
  String uiConfirmFailedValueBDE200(String value) {
    return 'Подтверждение не удалось: $value';
  }

  @override
  String uiRejectFailedValue5F5917(String value) {
    return 'Отклонение не удалось: $value';
  }

  @override
  String uiThisContactMayBeAD1405D(String value) {
    return 'Возможно, это «$value» после сброса. Перед обменом сообщениями проверьте номер безопасности по другому каналу.';
  }

  @override
  String uiImportedRelaysFromValue37C175(String value) {
    return 'Ретрансляторы импортированы из $value.';
  }

  @override
  String uiImportFailedValueBAFB4A(String value) {
    return 'Ошибка импорта: $value';
  }

  @override
  String uiThisWillRemoveValueRelay330EEB(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other:
          'Будут удалены маршруты ретрансляторов: $value, импортированные из $value2.',
      many:
          'Будут удалены маршруты ретрансляторов: $value, импортированные из $value2.',
      few:
          'Будут удалены маршруты ретрансляторов: $value, импортированные из $value2.',
      one:
          'Будут удалены маршруты ретрансляторов: $value, импортированные из $value2.',
    );
    return '$_temp0';
  }

  @override
  String uiRemoveFailedValue58F348(String value) {
    return 'Не удалось удалить: $value';
  }

  @override
  String get uiImportedRelayListsB0BD8B =>
      'Импортированные списки ретрансляторов';

  @override
  String get uiNoImportedLists6CBC34 => 'Нет импортированных списков.';

  @override
  String uiValueValueValueRouteS40FB98(
    String value,
    String value2,
    int value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value3,
      locale: localeName,
      other: '$value · $value2 · маршрутов: $value3',
      many: '$value · $value2 · маршрутов: $value3',
      few: '$value · $value2 · маршрутов: $value3',
      one: '$value · $value2 · маршрутов: $value3',
    );
    return '$_temp0';
  }

  @override
  String get uiLeaveBlankToImportUnsigned0D354E =>
      'Оставьте пустым для импорта без подписи (без доверия; предварительные проверки сохраняются). Для криптографически доверенного импорта укажите ключ оператора; подпись загружается с <URL>.ed25519.sig.';

  @override
  String uiValueF7CD86(String value) {
    return '// $value';
  }

  @override
  String get uiThemeA797E3 => 'Тема';

  @override
  String get uiAdaptiveIsUsingSystemDynamicBAA149 =>
      'Адаптивная тема использует динамические цвета системы.';

  @override
  String get uiMintAndPinkRemainTheC846F3 =>
      'Мятный и розовый остаются запасными акцентами Conest.';

  @override
  String get uiDecoration2DB87A => 'Оформление';

  @override
  String get uiAmbientGridScanlinesCornerReticles45D5C5 =>
      'Фоновая сетка, линии развёртки, метки углов и строка состояния. От минимального до полного оформления.';

  @override
  String get uiShellBDC1FD => 'Оболочка';

  @override
  String get uiHomeLayoutE19685 => 'Макет главного экрана';

  @override
  String uiCONESTCiValue7964DC(String value) {
    return 'CONEST · ci5 · $value';
  }

  @override
  String get uiQRUnavailable12869A => 'QR недоступен';

  @override
  String get uiUseTheCodephraseOrPayload187111 =>
      'Используйте кодовую фразу или данные приглашения ниже.';

  @override
  String uiTwoWayConfirmedValueE5A1A1(String value) {
    return 'подтверждено в обе стороны$value';
  }

  @override
  String uiPathAcceptsSendWaitingFor10B4B0(String value) {
    return 'путь принимает отправку; ожидается ответ$value';
  }

  @override
  String get uiUnavailable1D5EE3 => 'недоступен';

  @override
  String get uiUsable829A7C => 'доступен';

  @override
  String get uiOneWay5EF4D0 => 'в одну сторону';

  @override
  String get uiSkipC7E168 => 'пропуск';

  @override
  String get uiShareYourInviteThenEither5FEF78 =>
      'Поделитесь приглашением, затем отсканируйте QR или введите текущую кодовую фразу на другом устройстве для добавления контакта.';

  @override
  String get uiStartWithOneTrustedContact650B80 =>
      'Начните с одного доверенного контакта';

  @override
  String get uiThisReleasePairsThroughA883AA2 =>
      'Эта версия сопрягается по одному QR-приглашению или кодовой фразе, предпочитает LAN и использует интернет-ретрансляторы как резерв.';

  @override
  String get uiConnectivityIsOffEnableLAN39990E =>
      'Связь выключена. Включите LAN или интернет в настройках.';

  @override
  String get uiAutomaticAC9041 => 'Автоматически';

  @override
  String get uiPreferred0A3E0D => 'Предпочтительный';

  @override
  String get uiDisabledF4F447 => 'Отключён';

  @override
  String get uiAskFirst1AEB84 => 'Сначала спросить';

  @override
  String get uiRetryFailed7B6CA4 => 'Повторить неудачные';

  @override
  String get uiCancelAlbumDB0A07 => 'Отменить альбом';

  @override
  String get uiDeleteAlbum52E30F => 'Удалить альбом';

  @override
  String get menuForwardAlbum => 'Переслать альбом';

  @override
  String get menuSelect => 'Выбрать';

  @override
  String get menuSelectAlbum => 'Выбрать альбом';

  @override
  String uiValueSelectedB1DFAF(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Выбрано: $value',
      many: 'Выбрано: $value',
      few: 'Выбрано: $value',
      one: 'Выбрано: $value',
    );
    return '$_temp0';
  }

  @override
  String uiThisWillCancelValueActiveB3425E(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other:
          'Активные передачи ($value) будут отменены, список очищен. Сообщения и загруженные файлы сохранятся.',
      many:
          'Активные передачи ($value) будут отменены, список очищен. Сообщения и загруженные файлы сохранятся.',
      few:
          'Активные передачи ($value) будут отменены, список очищен. Сообщения и загруженные файлы сохранятся.',
      one:
          'Активные передачи ($value) будут отменены, список очищен. Сообщения и загруженные файлы сохранятся.',
    );
    return '$_temp0';
  }

  @override
  String get uiNoTransfersYetB8E5C1 => 'Пока нет передач.';

  @override
  String get uiAttachmentMetadataUnavailableE2C31D =>
      'Метаданные вложения недоступны';

  @override
  String uiValueMBPreparingDownload799D4A(String value) {
    return '$value МБ · подготовка загрузки…';
  }

  @override
  String uiValueMBDirectRouteRequired6379F0(String value) {
    return '$value МБ · нужен прямой маршрут';
  }

  @override
  String uiValueMBTapToDownload432280(String value) {
    return '$value МБ · нажмите для загрузки';
  }

  @override
  String get uiPreparingDownload8CB769 => 'Подготовка загрузки…';

  @override
  String uiTransferringValueValue10EEBE(String value, String value2) {
    return 'Передача · $value% · $value2';
  }

  @override
  String uiTransferringValue9D7F13(String value) {
    return 'Передача · $value';
  }

  @override
  String get uiVoiceMessage999DEB => 'Голосовое сообщение';

  @override
  String get uiSendAsMedia061D87 => 'Отправить как медиа';

  @override
  String get uiSendAsFileB50EAF => 'Отправить как файл';

  @override
  String get uiMEDIAB85FA2 => 'МЕДИА';

  @override
  String get uiFILEB4915D => 'ФАЙЛ';

  @override
  String get uiPausedByPeer63BD05 => 'Приостановлено собеседником';

  @override
  String get uiCouldNotDecodeThisImage3EAA16 =>
      'Не удалось декодировать изображение.';

  @override
  String uiValueValueValueDAEE95(String value, String value2, String value3) {
    return '$value  ·  $value2/$value3';
  }

  @override
  String uiValueCannotBeReachedOver14E8C2(String value, String value2) {
    return 'Сейчас $value недоступен через Conest. Отправить сообщение для $value2 обычным сообщением Matrix?\n\nОно попадёт в ваш личный чат Matrix без шифрования Conest: домашний сервер сможет прочитать его, если чат не зашифрован. Conest прекратит попытки доставки.';
  }

  @override
  String uiValueF69855(String value) {
    return '+$value';
  }

  @override
  String uiCouldNotPlayThisVideoF7D318(String value) {
    return 'Не удалось воспроизвести видео: $value';
  }

  @override
  String get uiYouLeft9F2CDB => 'Вы вышли';

  @override
  String uiReplyingToValue645786(String value) {
    return 'Ответ для $value';
  }

  @override
  String get uiNoScheduledMessages1DDB60 => 'Нет запланированных сообщений';

  @override
  String get uiScheduledAttachment08DB0E => 'Запланированное вложение';

  @override
  String uiValueValueValue209DD2(String value, String value2, String value3) {
    return '$value • $value2\n$value3';
  }

  @override
  String get uiSendNowDAE330 => 'Отправить сейчас';

  @override
  String get uiReschedule34B2DC => 'Перенести время';

  @override
  String get uiShareTextTo7B5086 => 'Поделиться текстом с…';

  @override
  String uiShareValueTo6E3BDD(String value) {
    return 'Поделиться $value с…';
  }

  @override
  String uiShareValueFilesToA46E17(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Поделиться файлами ($value) с…',
      many: 'Поделиться файлами ($value) с…',
      few: 'Поделиться файлами ($value) с…',
      one: 'Поделиться файлами ($value) с…',
    );
    return '$_temp0';
  }

  @override
  String get uiIfMessagesAndFilesFrom3DED27 =>
      'Если сообщения и файлы с телефона в одной сети не приходят, но ваши доходят, их блокирует брандмауэр Windows. Это разрешит другим устройствам из любой сети доступ к Conest на этом ПК; Windows запросит подтверждение.';

  @override
  String get uiServerRefusedSignOut66337B => 'Сервер отказал в выходе';

  @override
  String get uiServerNotReached62FED2 => 'Сервер недоступен';

  @override
  String uiThisServerDoesNotLet9EEC1F(String value) {
    return 'Сервер не позволяет Conest завершить сеанс ($value). Возможно, сеансы управляются на странице аккаунта.\n\nВсё равно выйти на этом устройстве? Затем удалите сеанс Conest на странице аккаунта или в другом приложении Matrix.';
  }

  @override
  String uiConestCouldNotSignThis3C1074(String value) {
    return 'Conest не смог завершить сеанс устройства на сервере ($value).\n\nВсё равно выйти на этом устройстве? Сеанс останется действителен на сервере, пока вы не удалите его в другом приложении Matrix.';
  }

  @override
  String get uiEnabledDF174A => 'Включено';

  @override
  String get uiYourEncryptedMatrixHistoryIsC16CD2 =>
      'Резервная копия зашифрованной истории Matrix уже есть. На новом устройстве выберите «Ввести ключ восстановления».';

  @override
  String get uiThisAccountAlreadyHasA0CF3D8 =>
      'У аккаунта уже есть ключ восстановления. Выберите «Ввести ключ восстановления» или «Проверить через другой сеанс», чтобы открыть историю на этом устройстве.';

  @override
  String uiMatrixValueED6C29(String value) {
    return 'Matrix: $value';
  }

  @override
  String uiValueValueB5F18A(String value, String value2) {
    return '$value$value2';
  }

  @override
  String get uiMatrixFallbackAA082C => 'Резерв через Matrix';

  @override
  String get uiMatrixAccountD69140 => 'Аккаунт Matrix';

  @override
  String get uiAccountsThatSignInThrough64868A =>
      'Аккаунты со входом через Google, GitHub, другого провайдера или matrix.org используют браузер.';

  @override
  String uiThisAccountIsOnValueB78C80(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Этот аккаунт на устройствах: $value.',
      many: 'Этот аккаунт на устройствах: $value.',
      few: 'Этот аккаунт на устройствах: $value.',
      one: 'Этот аккаунт на устройствах: $value.',
    );
    return '$_temp0';
  }

  @override
  String get uiUseConestOnMoreThanD2AA6A =>
      'Используйте Conest на нескольких устройствах: подключите телефон, планшет или компьютер к аккаунту. Контакты видят одного человека.';

  @override
  String get uiThisDeviceWasLinkedLess2E5122 =>
      'Устройство подключено менее суток назад и пока не может добавлять или удалять устройства.';

  @override
  String get uiPauseSyncingWithADevice89642E =>
      'Приостанавливать синхронизацию при отсутствии связи';

  @override
  String uiValueDaysEE919A(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Дней: $value',
      many: 'Дней: $value',
      few: 'Дней: $value',
      one: 'Дней: $value',
    );
    return '$_temp0';
  }

  @override
  String get uiChatsFromOtherNetworks13CDCD => 'Чаты из других сетей';

  @override
  String uiShowValueChatsInTheBC0E41(String value) {
    return 'Показывать чаты $value в списке';
  }

  @override
  String get uiChatWithDeltaChatUsers3B8607 =>
      'Общайтесь с пользователями Delta Chat через почтовый аккаунт. Сначала настройте почту выше.';

  @override
  String uiChatWithDeltaChatUsersABD3F5(String value) {
    return 'Общайтесь с пользователями Delta Chat как $value, лично и в группах. Сквозное шифрование (OpenPGP, без прямой секретности); почтовые серверы видят, кто кому пишет и когда.';
  }

  @override
  String get uiNoDeltaChatChatsYetF4C538 =>
      'Пока нет чатов Delta Chat. Поделитесь приглашением или присоединитесь по чужому.';

  @override
  String uiRequestValueE6C033(String value) {
    return 'Запрос: $value';
  }

  @override
  String get uiNobodyToAddYetStart0983BB =>
      'Пока некого добавить: сначала начните чат. Приглашением группы можно поделиться после её создания.';

  @override
  String get uiVerifiedEC734B => 'проверен';

  @override
  String uiAddValueF546E5(String value) {
    return 'Добавить $value';
  }

  @override
  String get uiChatDeleted73DC61 => 'Чат удалён';

  @override
  String get uiLeaveGroup925789 => 'Выйти из группы';

  @override
  String get uiWaitingForTheInviteTo1C712D =>
      'Ожидание ответа на приглашение; это может занять минуту.';

  @override
  String get uiEncryptedWithOpenPGPDeltaChat9C6326 =>
      'Зашифровано OpenPGP (Delta Chat), без прямой секретности. Почтовые серверы видят, кто кому пишет и когда.';

  @override
  String get uiARequestFromSomeoneYouAE0967 =>
      'Запрос от человека, с которым вы ещё не общались. Ответ принимает запрос.';

  @override
  String get uiReadA7AFDD => 'прочитано';

  @override
  String get uiNotSentBE2B9D => 'не отправлено';

  @override
  String get uiCouldNotJoinTheCall252D45 =>
      'Не удалось присоединиться к звонку. Проверьте маршрут или покиньте текущий звонок.';

  @override
  String uiCallInValue16F998(String value) {
    return 'Звонок в $value';
  }

  @override
  String uiValueStartedACallIn278E96(String value, String value2) {
    return '$value начал(а) звонок в $value2';
  }

  @override
  String get uiReturn24F096 => 'Вернуться';

  @override
  String get uiCouldNotUpdateTheCall33517D => 'Не удалось обновить звонок.';

  @override
  String get uiVoiceCallB8499D => 'Голосовой звонок';

  @override
  String uiCallViaValue0A68E8(String value) {
    return 'Звонок через $value';
  }

  @override
  String uiValueYouEFED9A(String value) {
    return '$value (вы)';
  }

  @override
  String get uiTalkingC34D84 => 'Говорите…';

  @override
  String get uiHoldToTalkSpace869505 => 'Удерживайте для разговора · Пробел';

  @override
  String uiVoiceCallValueBD3141(String value) {
    return 'Голосовой звонок · $value';
  }

  @override
  String uiStartedByValueValueParticipants99F03D(String value, int value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value2,
      locale: localeName,
      other: 'Начал(а) $value · участников: $value2',
      many: 'Начал(а) $value · участников: $value2',
      few: 'Начал(а) $value · участников: $value2',
      one: 'Начал(а) $value · участников: $value2',
    );
    return '$_temp0';
  }

  @override
  String get uiNodeRnsd0D8EEC => 'Узел (rnsd)';

  @override
  String get uiRNodeOnUSBF00220 => 'RNode через USB';

  @override
  String get uiRNodeOnBluetooth13657D => 'RNode через Bluetooth';

  @override
  String get uiRNodeOnWiFiC18593 => 'RNode через Wi-Fi';

  @override
  String get uiScanForRadios2B185E => 'Найти радиостанции';

  @override
  String get uiUseTheSameFrequencyBandwidthFC1A9F =>
      'Используйте те же частоту, полосу и коэффициент расширения, что у сети Reticulum радиостанции.';

  @override
  String get uiAppMode2965FD => 'Режим приложения';

  @override
  String get uiBoth1F4698 => 'Оба';

  @override
  String uiCouldNotStartTheChatAE2F54(String value) {
    return 'Не удалось начать чат: $value';
  }

  @override
  String uiMessagesAreEndToEndE786B5(String value) {
    return 'Сообщения защищены сквозным шифрованием, но ваши домашние серверы видят, кто с кем общается и когда. Проверьте $value, чтобы убедиться в личности.';
  }

  @override
  String get uiThisChatIsNotEncrypted799D99 =>
      'Этот чат не зашифрован: ваши домашние серверы могут его читать.';

  @override
  String get uiLoading33CE41 => 'Загрузка…';

  @override
  String get uiLoadEarlierMessages4AC08D => 'Загрузить предыдущие сообщения';

  @override
  String get uiEditing3B9BA1 => 'Редактирование';

  @override
  String uiReplyToValueValue666B4E(String value, String value2) {
    return 'Ответ для $value: $value2';
  }

  @override
  String get uiYouWereInvitedToThisE30D1E =>
      'Вас пригласили в этот чат Matrix.';

  @override
  String get uiEdited0E3C32 => 'изменено · ';

  @override
  String get uiUnableToDecryptThisMessage8A31CC =>
      'Пока не удалось расшифровать сообщение';

  @override
  String get uiUnsupportedMessage9E48EB => 'Неподдерживаемое сообщение';

  @override
  String uiImageUnavailableValueB024FC(String value) {
    return 'Изображение недоступно: $value';
  }

  @override
  String uiDownloadFailedValueB18BB6(String value) {
    return 'Ошибка загрузки: $value';
  }

  @override
  String get uiFile2C3CAF => 'Файл';

  @override
  String uiValueKiBEC48AF(String value) {
    return '$value КиБ';
  }

  @override
  String get uiCODEPHRASEE2C724 => 'КОДОВАЯ ФРАЗА';

  @override
  String uiROTATESINValueS5745B8(String value) {
    return 'СМЕНА ЧЕРЕЗ $value с';
  }

  @override
  String get uiROUTEINSPECTOR321AA4 => 'ИНСПЕКТОР МАРШРУТОВ';

  @override
  String get uiLIVE67B40B => '● ОНЛАЙН';

  @override
  String uiValueChatsAD9A3B(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Чатов: $value',
      many: 'Чатов: $value',
      few: 'Чатов: $value',
      one: 'Чатов: $value',
    );
    return '$_temp0';
  }

  @override
  String uiValueValue167E51(String value, String value2) {
    return '$value ($value2)';
  }

  @override
  String get uiNotDeliveredTheirRadioCould75D581 =>
      'не доставлено (радиостанция не смогла прочитать)';

  @override
  String get uiSenderNotVerified2BB0FA => 'отправитель не проверен';

  @override
  String get uiYouAreHidden56DCC1 => 'Вы скрыты';

  @override
  String get uiYouReadTheMeshChatAEACC5 =>
      'Вы читаете общий чат сети, но пользователи bitchat не видят вас и не могут вам писать. Включите «Доступен пользователям bitchat» в Настройки → Связь для отправки.';

  @override
  String get uiEveryoneNearbyOverBluetooth7B8D63 => 'Все рядом по Bluetooth';

  @override
  String get uiNoBitchatUsersNearbyYetD30471 =>
      'Пока нет пользователей bitchat рядом';

  @override
  String get uiPhonesInBluetoothRangeThatDCCC0D =>
      'Здесь появятся устройства в зоне Bluetooth, объявляющие о себе.';

  @override
  String get uiNearbyF1536C => 'Рядом';

  @override
  String get uiEveryoneInBluetoothRangeReadsA7628A =>
      'Чат читают все в зоне Bluetooth, любой может его ретранслировать. Сообщения подписаны, но не зашифрованы.';

  @override
  String get uiEncryptedBetweenTheTwoPhones3871C4 =>
      'Зашифровано между двумя устройствами (Noise bitchat); прямая секретность действует лишь пока вы рядом.';

  @override
  String get uiThisChatWasWithAn0507F9 =>
      'Чат вёлся с вашей прежней личностью bitchat. Если написать сейчас, собеседник узнает, что новая личность — тот же человек.';

  @override
  String uiValueValue64C067(String value, String value2) {
    return '$value#$value2';
  }

  @override
  String get uiVerifyThisSessionB5065C => 'Проверить этот сеанс';

  @override
  String get uiBluetoothMeshOn5A96FE => 'Сеть Bluetooth включена';

  @override
  String get uiStartingBluetoothE6928A => 'Запуск Bluetooth';

  @override
  String get uiBluetoothUnavailableF4B751 => 'Bluetooth недоступен';

  @override
  String uiBitchatUsersNearbySeeYou1B54FC(String value) {
    return 'Пользователи bitchat рядом видят вас как «$value», пока вы в зоне действия, и могут писать вам. Эта личность обновляется каждую неделю и не связана с вашей личностью в Conest.';
  }

  @override
  String get uiOffBitchatUsersDoNot054F9A =>
      'Выключено: пользователи bitchat не видят это устройство. Вы по-прежнему можете читать общий чат сети.';

  @override
  String uiPhonesNearbyWithoutInternetCan27CC7F(String value) {
    return 'Телефоны рядом без интернета могут использовать географические каналы bitchat через это устройство. Передаются только эти общедоступные подписанные сообщения. Устройство подключается к ретрансляторам используемых ими районов$value: те видят ваш интернет-адрес и район, поэтому могут примерно определить, где вы находитесь.';
  }

  @override
  String get uiOffBitchatUsersNearbyWithout030CFB =>
      'Выключено: пользователи bitchat рядом без интернета не могут обращаться к географическим каналам через вас.';

  @override
  String uiValueNearbyTheMeshChat31C0CA(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Рядом: $value · общий и личные чаты',
      many: 'Рядом: $value · общий и личные чаты',
      few: 'Рядом: $value · общий и личные чаты',
      one: 'Рядом: $value · общий и личные чаты',
    );
    return '$_temp0';
  }

  @override
  String get uiSignInToYourMatrix8D0037 => 'Войдите в аккаунт Matrix';

  @override
  String get uiNoRoomsFoundAD2C3E => 'Комнаты не найдены';

  @override
  String get uiMatrixInvitation525106 => 'Приглашение Matrix';

  @override
  String get uiEncryptedChat0D7563 => 'Зашифрованный чат';

  @override
  String get uiChat2CED57 => 'Чат';

  @override
  String get uiNoNostrChatsYet0A95D0 => 'Пока нет чатов Nostr';

  @override
  String get uiEncryptedOnNostrNIPRelaysA51F70 =>
      'Зашифровано в Nostr (NIP-17); ретрансляторы не видят автора и время написания. Без прямой секретности.';

  @override
  String get uiTestingRoutes19C586 => 'Проверка маршрутов…';

  @override
  String get uiTestRoutes52770A => 'Проверить маршруты';

  @override
  String get uiCheckingWhetherTheirAppCan51E401 =>
      'Проверка поддержки тестов маршрутов у собеседника…';

  @override
  String get uiTheirAppDidNotSay758036 =>
      'Приложение собеседника не сообщило о поддержке проверки маршрутов. Если версия та же, возможно, он сейчас недоступен.';

  @override
  String get uiNoRouteTookTheTestF2F6CB => 'Ни один маршрут не принял тест.';

  @override
  String uiTestedValueRoutesThatAnswer70B842(String value) {
    return 'Проверено: $value. Ответившие маршруты используются первыми.';
  }

  @override
  String get uiUSB09716C => 'USB';

  @override
  String get uiCopiedTheErrorHistoryCE02E2 => 'История ошибок скопирована.';

  @override
  String get uiNothingRecordedA27006 => 'Ничего не записано.';

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
    return 'Маршрут: $value';
  }

  @override
  String uiValueValue7B4608(String value, String value2) {
    return '$value · !$value2';
  }

  @override
  String get uiNetwork53EBC5 => 'Сеть';

  @override
  String uiImageIsLargerThanTheEE56C5(String value) {
    return 'Изображение превышает предел $value МБ.';
  }

  @override
  String uiFileIsLargerThanTheAF488F(String value) {
    return 'Файл превышает предел $value МБ.';
  }

  @override
  String uiSendValueBF4C3C(String value) {
    return 'Отправить $value';
  }

  @override
  String get uiRecent76EEC7 => 'Недавние';

  @override
  String get uiConestSeesOnlyThePhotosEE1926 =>
      'Conest видит только выбранные вами фото.';

  @override
  String get uiPhotosPermissionDeniedUseBrowseD672EE =>
      'Доступ к фото запрещён. Используйте «Обзор файлов…» для отправки любого файла или разрешите доступ в настройках системы.';

  @override
  String get uiNoPhotosOrVideosHereC729D1 => 'Здесь нет фото или видео.';

  @override
  String get uiCouldNotDecodeTheImage69AC9D =>
      'Не удалось декодировать изображение для поворота.';

  @override
  String uiRotationFailedValue176CC6(String value) {
    return 'Ошибка поворота: $value';
  }

  @override
  String uiValueOfValueVerified63B11D(String value, String value2) {
    return 'Проверено $value из $value2';
  }

  @override
  String get uiPointTheCameraAtA9BAFAF =>
      'Направьте камеру на QR-код приглашения Conest.';

  @override
  String get statusMatrixRoomsShowJoinsAndE8AC9E =>
      'Комнаты Matrix показывают входы и выходы.';

  @override
  String get statusMatrixRoomsHideJoinsAndE00610 =>
      'Комнаты Matrix скрывают входы и выходы.';

  @override
  String statusAppMode95B48F(String value) {
    return 'Режим приложения: $value.';
  }

  @override
  String statusCalling7A8C67(String value) {
    return 'Вызов $value…';
  }

  @override
  String get statusUpdatedHistoryVisibilityForFutureDA1A23 =>
      'Видимость истории для будущих участников обновлена.';

  @override
  String statusVaultUnlockFailedAE7813(String value) {
    return 'Не удалось разблокировать хранилище: $value';
  }

  @override
  String get statusDirectOnlineTransportIsUnavailableB1EFAE =>
      'Прямой интернет-транспорт недоступен; резерв через ретрансляторы работает.';

  @override
  String get statusNostrCarrierSetUpE82998 => 'Транспорт Nostr настроен.';

  @override
  String get statusNostrCarrierRemovedCB968A => 'Транспорт Nostr удалён.';

  @override
  String get statusNostrRelaysUpdatedARelay03F8F3 =>
      'Ретрансляторы Nostr обновлены: один закрылся.';

  @override
  String get statusTorCarrierSetUp3D2304 => 'Транспорт Tor настроен.';

  @override
  String get statusTorCarrierRemovedAAC23E => 'Транспорт Tor удалён.';

  @override
  String get statusBluetoothMeshOn11FD21 => 'Сеть Bluetooth включена.';

  @override
  String get statusBluetoothMeshOff2CE954 => 'Сеть Bluetooth выключена.';

  @override
  String get statusNostrMessagesOn35ABF5 => 'Сообщения Nostr включены.';

  @override
  String get statusNostrMessagesOff16BCA7 => 'Сообщения Nostr выключены.';

  @override
  String get statusDeltaChatOn1F38AA => 'Delta Chat включён.';

  @override
  String get statusDeltaChatOff8BDBD4 => 'Delta Chat выключен.';

  @override
  String statusBitchatUsersNearbyCanNow5536CD(String value) {
    return 'Пользователи bitchat рядом теперь видят вас как $value.';
  }

  @override
  String get statusBitchatUsersNoLongerSee68B46D =>
      'Пользователи bitchat больше вас не видят.';

  @override
  String statusMeshcoreCarrierSetUpThroughE51369(String value) {
    return 'Транспорт MeshCore настроен через $value.';
  }

  @override
  String get statusMeshcoreCarrierRemoved38FC35 => 'Транспорт MeshCore удалён.';

  @override
  String statusMeshtasticCarrierSetUpThroughAFA24A(String value) {
    return 'Транспорт Meshtastic настроен через $value.';
  }

  @override
  String get statusMeshtasticCarrierRemoved66387E =>
      'Транспорт Meshtastic удалён.';

  @override
  String get statusMeshtasticAppMessagesOn2C1888 =>
      'Сообщения приложения Meshtastic включены.';

  @override
  String get statusMeshtasticAppMessagesOffAFB9E8 =>
      'Сообщения приложения Meshtastic выключены.';

  @override
  String get statusMeshcoreAppMessagesOn2BF1E3 =>
      'Сообщения приложения MeshCore включены.';

  @override
  String get statusMeshcoreAppMessagesOffE59C90 =>
      'Сообщения приложения MeshCore выключены.';

  @override
  String statusReticulumCarrierSetUpThrough7EB41E(String value) {
    return 'Транспорт Reticulum настроен через $value.';
  }

  @override
  String get statusReticulumCarrierRemoved301C05 =>
      'Транспорт Reticulum удалён.';

  @override
  String statusEmailCarrierSetUpAs8427FD(String value) {
    return 'Почтовый транспорт настроен как $value.';
  }

  @override
  String get statusEmailCarrierRemoved036E51 => 'Почтовый транспорт удалён.';

  @override
  String statusImportedRelaySFromB1DB2D(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Импортировано ретрансляторов: $value из $value2.',
      many: 'Импортировано ретрансляторов: $value из $value2.',
      few: 'Импортировано ретрансляторов: $value из $value2.',
      one: 'Импортировано ретрансляторов: $value из $value2.',
    );
    return '$_temp0';
  }

  @override
  String statusRemovedImportedRelaySource3F4540(String value) {
    return 'Импортированный источник ретрансляторов $value удалён.';
  }

  @override
  String get statusPairingCodeRotatedAndAdvertised722FB9 =>
      'Код сопряжения сменён и объявлен.';

  @override
  String statusCheckedRouteSAvailableE9B9D6(
    int value,
    int value2,
    String value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Проверено маршрутов: $value; доступно: $value2. $value3',
      many: 'Проверено маршрутов: $value; доступно: $value2. $value3',
      few: 'Проверено маршрутов: $value; доступно: $value2. $value3',
      one: 'Проверено маршрутов: $value; доступно: $value2. $value3',
    );
    return '$_temp0';
  }

  @override
  String statusCheckedIrohPathSFor038B43(
    String value,
    String value2,
    String value3,
  ) {
    return 'Пути Iroh для $value проверены; доступность: $value2. $value3';
  }

  @override
  String statusNoPathsAreAdvertisedForA37EA3(String value) {
    return 'Для $value не объявлены пути.';
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
          'Проверено путей: $value для $value2; доступно: $value3$value4. Доступность: $value5. $value6',
      many:
          'Проверено путей: $value для $value2; доступно: $value3$value4. Доступность: $value5. $value6',
      few:
          'Проверено путей: $value для $value2; доступно: $value3$value4. Доступность: $value5. $value6',
      one:
          'Проверено путей: $value для $value2; доступно: $value3$value4. Доступность: $value5. $value6',
    );
    return '$_temp0';
  }

  @override
  String get statusDisplayNameUpdated3BD31A => 'Отображаемое имя обновлено.';

  @override
  String get statusBioCleared543896 => 'Описание очищено.';

  @override
  String get statusBioUpdated440110 => 'Описание обновлено.';

  @override
  String get statusContactProfileUpdated47ECF6 => 'Профиль контакта обновлён.';

  @override
  String get statusRelayModeEnabledB9ACB8 => 'Режим ретранслятора включён.';

  @override
  String get statusRelayModeDisabled723F4D => 'Режим ретранслятора выключен.';

  @override
  String get statusContactsCanNowContributeRelay147ECE =>
      'Контакты теперь могут автоматически предлагать ретрансляторы.';

  @override
  String get statusAutomaticContactRelayUsageDisabledE762A7 =>
      'Автоматическое использование ретрансляторов контактов выключено.';

  @override
  String get statusNotificationsEnabledF70668 => 'Уведомления включены.';

  @override
  String get statusNotificationsDisabledForThisDeviceE10A46 =>
      'Уведомления на этом устройстве выключены.';

  @override
  String get statusExperimentalVoiceCallsEnabledOn4081DE =>
      'Экспериментальные звонки на устройстве включены.';

  @override
  String get statusExperimentalVoiceCallsDisabledOn19A5AE =>
      'Экспериментальные звонки на устройстве выключены.';

  @override
  String get statusAndroidBackgroundRuntimeEnabledIfAA5168 =>
      'Фоновая работа Android включена. Ограничения батареи или фона могут задержать или остановить уведомления.';

  @override
  String get statusAndroidBackgroundRuntimeDisabled5FC9A0 =>
      'Фоновая работа Android выключена.';

  @override
  String get statusBackgroundVoiceCallAvailabilityEnabledA87223 =>
      'Фоновые звонки включены. Звонки поступают, только пока службе Conest разрешено работать.';

  @override
  String get statusBackgroundVoiceCallAvailabilityDisabledA71AD1 =>
      'Фоновые звонки выключены.';

  @override
  String get statusFreeSpaceReserveEnabledD7CE0E =>
      'Резерв 10% свободного места включён.';

  @override
  String get statusFreeSpaceReserveDisabledD3E635 =>
      'Резерв 10% свободного места выключен.';

  @override
  String statusRoutingPreferencesUpdatedFor05867B(String value) {
    return 'Настройки маршрутов для $value обновлены.';
  }

  @override
  String statusLocalRelayPortUpdatedTo7F815D(String value) {
    return 'Порт локального ретранслятора изменён на $value.';
  }

  @override
  String statusRelayAdded800692(String value) {
    return 'Ретранслятор $value добавлен.';
  }

  @override
  String statusRelayAddedFor087398(String value, String value2, String value3) {
    return 'Ретранслятор $value:$value2 добавлен для $value3.';
  }

  @override
  String statusRelayRemoved546A15(String value) {
    return 'Ретранслятор $value удалён.';
  }

  @override
  String statusTrustedNewIdentityForRelay4CDBFE(String value) {
    return 'Новая личность ретранслятора $value принята.';
  }

  @override
  String get statusContactRemovedE31CE0 => 'Контакт удалён.';

  @override
  String get statusContactRemovedLocallySendingA40D607 =>
      'Контакт удалён локально. Уведомление об удалении отправляется в фоне.';

  @override
  String get statusDeviceCreatedShareAQr06E7B6 =>
      'Устройство создано. Поделитесь QR-приглашением или текущей кодовой фразой, чтобы добавить контакт.';

  @override
  String statusContactAcceptedSendingApprovalOverDAD10C(String value) {
    return 'Контакт $value принят. Подтверждение отправляется по доступным путям.';
  }

  @override
  String statusContactSavedWaitingForThe41F77D(String value) {
    return 'Контакт $value сохранён. Ожидается одобрение собеседника.';
  }

  @override
  String statusReconnectedWithBC62EC(String value) {
    return 'Связь с $value восстановлена.';
  }

  @override
  String statusAskingToReconnectE93389(String value) {
    return 'Запрос переподключения к $value.';
  }

  @override
  String statusConfirmedIdentityReplacementForC93359(String value) {
    return 'Замена личности $value подтверждена.';
  }

  @override
  String statusRejectedIdentityReplacementForDEC894(String value) {
    return 'Замена личности $value отклонена.';
  }

  @override
  String get statusContactRequestCancelledQueuedItemsEC2567 =>
      'Запрос контакта отменён. Элементы в очереди остаются заблокированы.';

  @override
  String get statusSaved9D4AF6 => 'Сохранено.';

  @override
  String statusMessageSavedLocallyItWill0DBD03(String value) {
    return 'Сообщение сохранено локально и отправится после принятия запроса контактом $value.';
  }

  @override
  String statusTryingLanFirstThenRelay1F5BEC(String value) {
    return 'Сначала LAN, затем ретранслятор для $value.';
  }

  @override
  String get statusMessageQueuedTheAppWillA89BCC =>
      'Сообщение в очереди. Приложение повторит попытки по прямым путям и ретрансляторам при опросе.';

  @override
  String statusAttachmentIsWaitingForA3F032B(String value) {
    return 'Вложение ожидает маршрут: $value';
  }

  @override
  String statusCouldNotPrepareForDownloadE8FB18(String value) {
    return 'Не удалось подготовить $value к загрузке.';
  }

  @override
  String statusCreatedGroupF5D335(String value) {
    return 'Группа $value создана.';
  }

  @override
  String statusUpdatedGroup2140B7(String value) {
    return 'Группа $value обновлена.';
  }

  @override
  String statusRemovedAMemberFrom68CF04(String value) {
    return 'Участник удалён из $value.';
  }

  @override
  String statusLeftGroup9E3412(String value) {
    return 'Вы вышли из группы $value.';
  }

  @override
  String statusRemovedGroupFromYourList047F4B(String value) {
    return 'Группа $value убрана из вашего списка.';
  }

  @override
  String statusTransferredOwnershipOfToA126A1(String value, String value2) {
    return 'Владение $value передано $value2.';
  }

  @override
  String statusDeletedGroupForEveryoneDB26F8(String value) {
    return 'Группа $value удалена у всех.';
  }

  @override
  String statusUpdatedIn642C0A(String value, String value2) {
    return '$value обновлено в $value2.';
  }

  @override
  String statusSendingGroupMessageToD77236(String value) {
    return 'Отправка сообщения группы для $value.';
  }

  @override
  String statusSentToAsAPlainAF2DE6(String value) {
    return 'Отправлено для $value обычным сообщением Matrix.';
  }

  @override
  String statusCanceledAndDeletedPendingMessageCDCA88(String value) {
    return 'Ожидающее сообщение для $value отменено и удалено.';
  }

  @override
  String get statusMessageDeletedLocallyCE90EE => 'Сообщение удалено локально.';

  @override
  String statusMessageDeletedHereAndDeletion7C4E80(String value) {
    return 'Сообщение удалено здесь, запрос удаления отправлен для $value.';
  }

  @override
  String get statusMessageDeletedHereRemoteDeletionB6AE62 =>
      'Сообщение удалено здесь. Запрос удаления собеседнику пока не отправлен.';

  @override
  String get statusMessageEditedLocally187334 => 'Сообщение изменено локально.';

  @override
  String statusMessageEditQueuedTo695B15(String value) {
    return 'Изменение сообщения поставлено в очередь для $value.';
  }

  @override
  String get statusReactionUpdatedLocally97D795 =>
      'Реакция обновлена локально.';

  @override
  String statusReactionQueuedToD43BED(String value) {
    return 'Реакция поставлена в очередь для $value.';
  }

  @override
  String get statusLanLobbyMessageSavedLocallyFDE86E =>
      'Сообщение общего чата LAN сохранено локально: участники рядом недоступны.';

  @override
  String statusLanLobbyMessageSentTo82F0B0(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Сообщение общего чата LAN отправлено по маршрутам рядом: $value.',
      many: 'Сообщение общего чата LAN отправлено по маршрутам рядом: $value.',
      few: 'Сообщение общего чата LAN отправлено по маршрутам рядом: $value.',
      one: 'Сообщение общего чата LAN отправлено по маршрутам рядом: $value.',
    );
    return '$_temp0';
  }

  @override
  String statusGroupMembershipAckFrom43FCF1(String value, String value2) {
    return 'Подтверждение участия в группе $value от $value2.';
  }

  @override
  String statusReceivedItemSVia58B082(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Получено элементов: $value через $value2.',
      many: 'Получено элементов: $value через $value2.',
      few: 'Получено элементов: $value через $value2.',
      one: 'Получено элементов: $value через $value2.',
    );
    return '$_temp0';
  }

  @override
  String statusRoutePollFailedA1FD0C(String value) {
    return 'Ошибка опроса маршрутов: $value';
  }

  @override
  String statusLanReceivingIsOffPort5F04CB(String value) {
    return 'Приём LAN выключен: порт $value занят. Выберите другой порт локального ретранслятора в настройках.';
  }

  @override
  String statusRediscoveredLanRouteFor587829(String value, String value2) {
    return 'Маршрут LAN $value вновь найден для $value2.';
  }

  @override
  String statusLanDiscoveryUnavailable0E99AE(String value) {
    return 'Обнаружение LAN недоступно: $value';
  }

  @override
  String get statusUpdatedNearbyLanRoutesF8CAFC =>
      'Маршруты LAN рядом обновлены.';

  @override
  String statusRejectedMalformedAttachmentOfferFrom9FC96A(String value) {
    return 'Некорректное предложение вложения от $value отклонено.';
  }

  @override
  String get statusRejectedInvalidAttachmentMetadata849465 =>
      'Неверные метаданные вложения отклонены.';

  @override
  String statusDeclinedTheRequestQueuedMessagesABFFCB(String value) {
    return '$value отклонил(а) запрос. Сообщения и файлы в очереди остаются заблокированы.';
  }

  @override
  String statusNewContactRequestFromCF70B9(String value) {
    return 'Новый запрос контакта от $value.';
  }

  @override
  String statusLeftF4FE32(String value, String value2) {
    return '$value вышел(ла) из $value2.';
  }

  @override
  String statusRemovedYouTheConversationRemains3BB516(String value) {
    return '$value удалил(а) вас. Чат остаётся в локальном архиве.';
  }

  @override
  String statusUpdatedEditedMessageFrom1AB90D(String value) {
    return 'Обновлено изменённое сообщение от $value.';
  }

  @override
  String statusDeletedMessageRemovedBy5A9E79(String value) {
    return 'Убрано сообщение, удалённое $value.';
  }

  @override
  String statusAppliedAReactionFrom41011B(String value) {
    return 'Применена реакция от $value.';
  }

  @override
  String get statusAppliedDeferredDirectReactions1414C8 =>
      'Применены отложенные личные реакции.';

  @override
  String statusEncryptedMessageStoredForVia029324(String value, String value2) {
    return 'Зашифрованное сообщение для $value сохранено через $value2.';
  }

  @override
  String statusSentToViaWaitingForEA766D(String value, String value2) {
    return 'Отправлено для $value через $value2; ожидается подтверждение доставки.';
  }

  @override
  String statusDeliveryRetryPending93EAA3(String value) {
    return 'Повтор доставки ожидает: $value';
  }

  @override
  String statusGroupDeliveryRetryPending691CA4(String value) {
    return 'Повтор доставки группе ожидает: $value';
  }

  @override
  String statusRelayIdentityChangedVerifyWith6F3689(String value) {
    return 'Личность ретранслятора $value изменилась: проверьте у оператора.';
  }

  @override
  String statusRelayIdentityMismatchVerifyWith2D3B10(
    String value,
    String value2,
  ) {
    return 'Личность ретранслятора $value:$value2 не совпадает: проверьте у оператора.';
  }

  @override
  String get statusTheMatrixSignInExpired76ABA4 =>
      'Сеанс Matrix истёк. Войдите снова для использования Matrix.';

  @override
  String statusSignedInToMatrixAs5103D2(String value) {
    return 'Вход в Matrix как $value.';
  }

  @override
  String get statusSignedOutOfMatrix1D1860 => 'Выполнен выход из Matrix.';

  @override
  String statusSOtherDevicesHaveNot07F30F(String value, String value2) {
    return 'Другие устройства $value давно не получали вестей от $value2: сообщения могут исходить не от владельца.';
  }

  @override
  String statusReceivedItemSInstantlyViaA7773B(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other:
          'Мгновенно получено элементов через локальный ретранслятор: $value.',
      many:
          'Мгновенно получено элементов через локальный ретранслятор: $value.',
      few: 'Мгновенно получено элементов через локальный ретранслятор: $value.',
      one: 'Мгновенно получено элементов через локальный ретранслятор: $value.',
    );
    return '$_temp0';
  }

  @override
  String statusReceivedItemSViaLocal71A104(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Получено элементов через локальный ящик: $value.',
      many: 'Получено элементов через локальный ящик: $value.',
      few: 'Получено элементов через локальный ящик: $value.',
      one: 'Получено элементов через локальный ящик: $value.',
    );
    return '$_temp0';
  }

  @override
  String get statusNoNewProtocols =>
      'Новые протоколы ретрансляторов не обнаружены.';

  @override
  String get statusRouteExchangeRequested =>
      'Обмен сведениями о маршрутах запрошен.';

  @override
  String get statusRouteExchangePending =>
      'Запрос обмена маршрутами пока не отправлен.';

  @override
  String get statusKnownRoutes => 'известные маршруты';

  @override
  String get statusReachable => 'доступен';

  @override
  String get statusUnreachable => 'недоступен';

  @override
  String get statusUnknown => 'неизвестно';

  @override
  String get statusExpired => 'устарело';

  @override
  String get connectionsTitle => 'Соединения';

  @override
  String get connectionsDescription =>
      'Какие устройства доступны друг другу в обе стороны или в одну.';

  @override
  String get relayUdpHint => 'udp://host:port задаёт UDP';

  @override
  String get deltaFileActions => 'Действия с файлом';

  @override
  String get deltaForward => 'Переслать';

  @override
  String get deltaAttach => 'Прикрепить';

  @override
  String get deltaSendVoice => 'Отправить голосовое сообщение';

  @override
  String get deltaDiscardVoice => 'Удалить голосовое сообщение';

  @override
  String get deltaRecordVoice => 'Записать голосовое сообщение';

  @override
  String get deltaReact => 'Реакция';

  @override
  String get savedMessagesPreview => 'Заметки, файлы и пересылки для себя';

  @override
  String networkChatsTitle(String network) {
    return 'Чаты $network';
  }

  @override
  String get networkEncryptedMatrixChat => 'Зашифрованный чат Matrix';

  @override
  String get networkMatrixChat => 'Чат Matrix';

  @override
  String get networkEveryoneBluetooth => 'Все в зоне Bluetooth';

  @override
  String get inviteNoRoutes => 'маршруты не объявлены';

  @override
  String get deliveryPending => 'Ожидание доступного пути';

  @override
  String get deliveryLocal =>
      'Отправлено по LAN; ожидается подтверждение доставки';

  @override
  String get deliveryRelayed =>
      'В очереди ретранслятора; ожидается подтверждение доставки';

  @override
  String get deliveryDelivered => 'Доставлено';

  @override
  String get deliveryRead => 'Прочитано';

  @override
  String get reachabilityOnline => 'в сети';

  @override
  String get reachabilityRecent => 'был(а) недавно';

  @override
  String get reachabilityKnown => 'известен';

  @override
  String get transferApproval => 'Ожидание одобрения';

  @override
  String get transferPeer => 'Ожидание собеседника';

  @override
  String get routeLanDirect => 'Напрямую по LAN';

  @override
  String get routeInternetDirect => 'Напрямую через интернет';

  @override
  String get routeIrohDirect => 'Iroh напрямую';

  @override
  String get routeConestRelay => 'Ретранслятор Conest';

  @override
  String get routeOptical => 'Оптический';

  @override
  String get routeViaContact => 'Через контакт';

  @override
  String get themeSystem => 'Системная';

  @override
  String get themeLight => 'Signature · Светлая';

  @override
  String get themeDark => 'Signature · Тёмная';

  @override
  String get themeBlack => 'Signature · Чёрная (OLED)';

  @override
  String get themeAdaptive => 'Адаптивная (обои)';

  @override
  String get layoutSignalCards => 'Карточки связи';

  @override
  String get layoutStationFeed => 'Лента станции';

  @override
  String get layoutClassic => 'Классические строки';

  @override
  String get layoutSignalDescription => 'Устройства в виде карточек связи.';

  @override
  String get layoutFeedDescription => 'Журнал пакетов и событий по времени.';

  @override
  String get layoutClassicDescription => 'Компактный список в одну строку.';

  @override
  String get shellSignatureDescription => 'Собственная боковая панель Conest.';

  @override
  String get shellGarrisonDescription =>
      'В стиле Discord: панель ячеек и чаты.';

  @override
  String get shellCourierDescription =>
      'В стиле Telegram: единый простой список чатов.';

  @override
  String get connectionsBothWays => 'в обе стороны';

  @override
  String get connectionsInbound => 'только от них';

  @override
  String get connectionsFailing => 'сбой';

  @override
  String get connectionsUnknown => 'нет свежих данных';

  @override
  String voiceConnected(String time) {
    return 'Соединено · $time';
  }

  @override
  String messageClockAhead(String amount) {
    return 'Их часы спешат примерно на $amount; здесь время этого устройства.';
  }

  @override
  String messageClockBehind(String amount) {
    return 'Их часы отстают примерно на $amount; здесь время этого устройства.';
  }

  @override
  String messageNotRecentlyConfirmed(String date) {
    return 'Давно не подтверждено: другие устройства в последний раз считали его своим $date.';
  }

  @override
  String get routeLanDirectDescription =>
      'Напрямую на другое устройство в вашей локальной сети.';

  @override
  String get routeLanRelayDescription =>
      'Через узел ретрансляции другого устройства в вашей локальной сети.';

  @override
  String get routeLanLobbyDescription =>
      'Общий почтовый ящик лобби LAN; его может читать любой в сети.';

  @override
  String get routeInternetDirectDescription =>
      'Напрямую к узлу ретрансляции другого устройства через интернет.';

  @override
  String get routeIrohDirectDescription =>
      'Напрямую между устройствами по Iroh, со сквозным шифрованием.';

  @override
  String get routeIrohRelayDescription =>
      'Через сервер ретрансляции Iroh, который видит только зашифрованный трафик.';

  @override
  String get routeConestRelayDescription =>
      'Сервер Conest хранит и пересылает сообщения, видя только зашифрованные конверты.';

  @override
  String get routeMatrixDescription =>
      'Доставка через Matrix со сквозным шифрованием Conest; домашний сервер видит участников и время общения.';

  @override
  String get routePlainMatrixDescription =>
      'Обычное сообщение Matrix; домашний сервер может его прочитать, если комната не зашифрована.';

  @override
  String get routeNostrDescription =>
      'Доставка через Nostr со сквозным шифрованием Conest; ретрансляторы видят получателя и время, но не отправителя.';

  @override
  String get routeEmailDescription =>
      'Доставка по email со сквозным шифрованием Conest; почтовые серверы видят оба адреса и время.';

  @override
  String get routeReticulumDescription =>
      'Через Reticulum по радио или сети Reticulum, со сквозным шифрованием.';

  @override
  String get routeMeshtasticDescription =>
      'По радиосети Meshtastic, со сквозным шифрованием.';

  @override
  String get routeMeshCoreDescription =>
      'По радиосети MeshCore, со сквозным шифрованием.';

  @override
  String get routeBluetoothDescription =>
      'Через сеть Bluetooth и устройства поблизости, со сквозным шифрованием.';

  @override
  String get routeTorDescription =>
      'Между onion-сервисами через Tor; посредники не видят, кто с кем общается.';

  @override
  String get routeContactDescription =>
      'Пересылка через контакт, имеющий связь с другим устройством; шифрование остаётся сквозным, контакт видит только получателя и время.';

  @override
  String routeTestRoundTrip(String route, String ms) {
    return '$route: $ms мс туда и обратно';
  }

  @override
  String routeTestStored(String route) {
    return '$route: оставлено на ретрансляторе (ответ после получения)';
  }

  @override
  String routeTestNoAnswer(String route) {
    return '$route: нет ответа';
  }

  @override
  String transferTimeLeft(String time) {
    return 'осталось $time';
  }

  @override
  String transferQueuePosition(String position) {
    return 'очередь №$position';
  }

  @override
  String get transferTapRetry => 'нажмите для повтора';

  @override
  String get transferRerouting => 'Смена маршрута';

  @override
  String get routeShortLobby => 'Лобби';

  @override
  String get routeShortDirect => 'Напрямую';

  @override
  String get routeShortRelay => 'Ретранслятор';

  @override
  String get routeShortContact => 'Через контакт';

  @override
  String chatDraftPreview(String text) {
    return 'Черновик: $text';
  }

  @override
  String get routeAutomaticFallback => 'автопереключение ✓';

  @override
  String get releaseNightly => 'ночная';

  @override
  String get releaseStable => 'стабильная';

  @override
  String get callActive => 'Идёт звонок';

  @override
  String get callGeneric => 'Звонок';

  @override
  String get contactNotPinned => 'Не закреплён';

  @override
  String get groupUnknownMember => 'Участник';

  @override
  String get relaySourceSigned => 'подписан';

  @override
  String get relaySourceUnsigned => 'без подписи';

  @override
  String get beamFingerprintUnavailable => 'отпечаток недоступен';

  @override
  String get fileOriginalMetadataWarning =>
      'Вместе с ним будут отправлены данные о месте, камере, авторе и дате.';

  @override
  String get routeMarkSent => 'отправлено';

  @override
  String get routeMarkStored => 'ожидает на ретрансляторе';

  @override
  String get routeMarkReached => 'получено устройством';

  @override
  String get routeMarkDelivered => 'доставлено';

  @override
  String get routeMarkReceived => 'получено';

  @override
  String get relayHostOrLinkLabel => 'Хост, URL или ссылка реле';

  @override
  String get relayLinkHint => 'conest-relay://… от его установщика';

  @override
  String get brokenPartNotice => 'Здесь что-то пошло не так.';

  @override
  String get crashNoticeBody =>
      'В прошлый раз Conest неожиданно закрылся. Подробности остаются на этом устройстве; их можно скопировать в отчёт об ошибке.';

  @override
  String get crashNoticeDetails => 'Подробнее';

  @override
  String get crashNoticeDismiss => 'Скрыть';

  @override
  String get crashReportTitle => 'Что произошло';

  @override
  String get crashReportCopy => 'Копировать';

  @override
  String get crashReportClose => 'Закрыть';

  @override
  String get connectionsNetworks => 'Сети, в которых было это устройство';

  @override
  String get connectionsNetworkNow => 'Используется сейчас';

  @override
  String connectionsNetworkLastSeen(String date) {
    return 'Последний раз: $date';
  }

  @override
  String get connectionsRouteWorks => 'работает';

  @override
  String get connectionsRouteBlocked => 'заблокировано в этой сети';

  @override
  String get connectionsRouteFailing => 'сбои';

  @override
  String connectionsAsOf(String when) {
    return 'на $when';
  }

  @override
  String get bluetoothMeshNeedsAttention => 'Bluetooth-сеть требует внимания';

  @override
  String forwardSelectedTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Переслать $count сообщения',
      many: 'Переслать $count сообщений',
      few: 'Переслать $count сообщения',
      one: 'Переслать $count сообщение',
    );
    return '$_temp0';
  }

  @override
  String forwardedSummary(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Переслано $count сообщения',
      many: 'Переслано $count сообщений',
      few: 'Переслано $count сообщения',
      one: 'Переслано $count сообщение',
    );
    return '$_temp0';
  }

  @override
  String forwardSkipped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count файла ещё не на этом устройстве и пропущены',
      many: '$count файлов ещё не на этом устройстве и пропущены',
      few: '$count файла ещё не на этом устройстве и пропущены',
      one: '$count файл ещё не на этом устройстве и пропущен',
    );
    return '$_temp0';
  }

  @override
  String get torBlockedHint =>
      'Похоже, Tor заблокирован в этой сети. Мосты помогают обойти блокировку, но общедоступные тоже часто заблокированы: получите свои (см. ниже).';

  @override
  String get torGetBridgesTitle => 'Как получить свои мосты';

  @override
  String get torGetBridgesIntro =>
      'Tor Project раздаёт мосты такими способами. Запросите мосты obfs4 или webtunnel и вставьте строки выше.';

  @override
  String get torGetBridgesWeb => 'Сайт: bridges.torproject.org';

  @override
  String get torGetBridgesTelegram => 'Telegram: напишите @GetBridgesBot';

  @override
  String get torGetBridgesEmail =>
      'Почта: напишите на bridges@torproject.org с адреса Gmail или Riseup';

  @override
  String get torGetBridgesFriend =>
      'Или попросите человека, которому доверяете и который пользуется Tor, поделиться строкой моста.';

  @override
  String get transportsTitle => 'Связь за пределами этой сети';

  @override
  String get transportsIntro =>
      'Устройства в этой сети связываются с вами напрямую. Для всех остальных Conest нужен хотя бы один путь через интернет, а лучше три, потому что сети блокируют некоторые из них. Вот что работает в этой сети сейчас.';

  @override
  String get transportsChecking => 'Проверяем, что работает в этой сети…';

  @override
  String transportsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Настроено $count: рекомендуется 3',
      many: 'Настроено $count: рекомендуется 3',
      few: 'Настроено $count: рекомендуется 3',
      one: 'Настроен $count: рекомендуется 3',
      zero: 'Пока ни одного: нужен 1, рекомендуется 3',
    );
    return '$_temp0';
  }

  @override
  String get transportStateOn => 'Работает';

  @override
  String get transportStateWorks => 'Работает здесь';

  @override
  String get transportStateBlocked => 'Заблокировано здесь';

  @override
  String get transportStateNeedsSetup => 'Настраивается в Настройках';

  @override
  String get transportsEmailCost =>
      'Проверяет почтовый ящик: чуть больше трафика и заряда.';

  @override
  String get transportsSkipTitle =>
      'Связаться с вами смогут только устройства поблизости';

  @override
  String get transportsSkipBody =>
      'Без пути через интернет связаться с вами смогут только устройства в этой сети, а вы — только с ними. Настроить путь можно позже: Настройки, раздел «Подключение».';

  @override
  String get transportsSkipConfirm => 'Всё равно продолжить';

  @override
  String get transportsBanner =>
      'Сейчас с вами могут связаться только устройства в этой сети. Настройте путь через интернет.';

  @override
  String get transportsBannerAction => 'Настроить';

  @override
  String get transportsBannerDismiss => 'Не сейчас';

  @override
  String transportsTurnOnFailed(String name, String error) {
    return 'Не удалось включить $name: $error';
  }

  @override
  String get transportsHowToChoose => 'Как выбрать';

  @override
  String get settingsUserGuide => 'Руководство';

  @override
  String get settingsEnterSends => 'Enter отправляет сообщение';

  @override
  String get settingsEnterSendsHelp =>
      'Shift+Enter — новая строка. Если выключено: Enter — новая строка, Ctrl+Enter — отправить.';

  @override
  String get menuCopySelection => 'Копировать выделенное';

  @override
  String get linkLookalikeTitle => 'Открыть ссылку?';

  @override
  String linkLookalikeBody(String host) {
    return 'В адресе $host есть буквы из других алфавитов. Он может подделывать знакомый вам сайт.';
  }

  @override
  String get linkOpen => 'Открыть';

  @override
  String get carrierRemove => 'Удалить';

  @override
  String carrierRemoveTitle(String name) {
    return 'Удалить $name?';
  }

  @override
  String carrierRemoveBody(String name) {
    return 'Контакты больше не смогут связаться с вами через $name, а то, что это устройство хранит для него, будет забыто. При новой настройке у вас будет новый адрес. Чтобы просто остановить его на время, выключите переключатель.';
  }

  @override
  String get carrierPaused =>
      'Приостановлено: сохранено, но не используется. Включите, чтобы пользоваться снова.';

  @override
  String get emailChangeAccount => 'Сменить аккаунт';

  @override
  String get emailOtherServer => 'Другой сервер';

  @override
  String get actionSave => 'Сохранить';

  @override
  String get settingsLinksTitle =>
      'Ссылки, которые вы отправляете и открываете';

  @override
  String get settingsCleanLinks => 'Удалять слежку из ссылок';

  @override
  String get settingsCleanLinksHelp =>
      'Убирает части ссылки, по которым сайт узнаёт, кто ею поделился (например, ?si= или utm_), при отправке и при открытии. Использует правила ClearURLs.';

  @override
  String get settingsEmbedLinks => 'Ссылки с предпросмотром';

  @override
  String get settingsEmbedLinksHelp =>
      'Ссылки на посты в X, Instagram, Reddit, TikTok и похожих сайтах идут через сервис, который позволяет другим приложениям показать предпросмотр и переправляет браузер к посту. Сервисы взяты из списка embed-fixer; неработающий пропускается.';

  @override
  String get linkCleaned => 'Ссылка очищена';

  @override
  String get linkCleanedUndo => 'Отменить';

  @override
  String get menuOpenOriginalLink => 'Открыть исходную ссылку';

  @override
  String get editorSendOriginalAsFile =>
      'Отправить оригинал файлом (без сжатия)';

  @override
  String get linkPreviewShow => 'Показать предпросмотр ссылки';

  @override
  String get settingsLinkPreviews => 'Предпросмотр ссылок';

  @override
  String get settingsLinkPreviewsHelp =>
      'Показывает заголовок и картинку ссылки под сообщением. Это устройство загружает их с сайта, и сайт видит ваш IP-адрес: само — в чатах с вашими контактами и группами (не в режиме энергосбережения и не в роуминге), в остальных чатах — только по нажатию.';

  @override
  String get linkPreviewModeReceiver => 'Загружает каждый получатель';

  @override
  String get linkPreviewModeSender =>
      'Отправляются с сообщением (получатели не обращаются к сайту)';

  @override
  String get linkPreviewModeBoth => 'Оба способа';

  @override
  String get linkPreviewModeOff => 'Выключено';

  @override
  String get linkPreviewRemove => 'Отправить без предпросмотра';

  @override
  String get settingsLinkPreviewsTor => 'Загружать предпросмотр через Tor';

  @override
  String get settingsLinkPreviewsTorHelp =>
      'Когда Tor настроен, сайты видят выходной узел Tor, а не ваш адрес, и в вашей сети ничего о ссылке не запрашивается. Пока Tor не подключён, предпросмотр не загружается.';

  @override
  String linkPreviewFromSender(String host) {
    return '$host · предпросмотр от отправителя';
  }

  @override
  String get contentRoutingTitle => 'Что передавать через интернет';

  @override
  String get contentRoutingHelp =>
      'Локальная сеть всегда передаёт всё. Ваши контакты узнают об этом выборе: то, что исключено, ждёт транспорт, которому это разрешено.';

  @override
  String get contentRoutingEverything => 'Всё';

  @override
  String get contentRoutingMessagesAndSmallFiles => 'Сообщения и файлы до 1 МБ';

  @override
  String get contentRoutingMessagesOnly =>
      'Только сообщения (файлы — по локальной сети)';

  @override
  String get contentRoutingCustom => 'Своё';

  @override
  String get contentRoutingByTransport => 'По транспортам';

  @override
  String get contentClassText => 'Сообщения';

  @override
  String get contentClassOwnSync => 'Ваши устройства';

  @override
  String get contentClassHistory => 'История';

  @override
  String get contentClassFileSmall => 'Файлы до 1 МБ';

  @override
  String get contentClassFileMedium => 'Файлы до 30 МБ';

  @override
  String get contentClassFileLarge => 'Файлы больше';

  @override
  String get contentClassCallSignal => 'Звонки';

  @override
  String get contentRoutingCannotCarry =>
      'Этот транспорт не может это передавать';

  @override
  String get routeViaOwnDevice => 'Через другое ваше устройство';

  @override
  String get routeOwnDeviceDescription =>
      'Получено другим вашим устройством и передано на это, со сквозным шифрованием.';

  @override
  String get routeShortOwnDevice => 'Ваше устройство';

  @override
  String get backgroundReceiveTitle => 'Получать сообщения в фоне';

  @override
  String get backgroundReceiveHelp =>
      'Сообщения и звонки приходят, когда Conest закрыт. Пока он работает, Android показывает тихое уведомление.';

  @override
  String get batteryExemptionTitle => 'Оптимизация батареи';

  @override
  String get batteryExemptionAllowed =>
      'Без ограничений: Android не останавливает Conest в фоне.';

  @override
  String get batteryExemptionLimited =>
      'Android может остановить Conest в фоне, и тогда сообщения ждут, пока вы его не откроете.';

  @override
  String get batteryExemptionAllow => 'Разрешить';

  @override
  String get batteryExemptionPromptTitle => 'Продолжать получать сообщения';

  @override
  String get batteryExemptionPromptBody =>
      'Чтобы получать сообщения, когда Conest закрыт, Android должен разрешить ему работать в фоне. На следующем экране разрешите Conest работать без ограничений батареи.';

  @override
  String batteryExemptionVendorHint(String maker) {
    return 'На телефонах $maker также включите для Conest автозапуск и установите для него экономию батареи «Нет ограничений» (Настройки → Приложения → Conest).';
  }

  @override
  String get closeToTrayTitle => 'Оставаться в трее после закрытия';

  @override
  String get closeToTrayHelp =>
      'Сообщения продолжают приходить. Откройте Conest снова через значок в трее или закройте его там.';

  @override
  String get trayShow => 'Показать Conest';

  @override
  String get trayQuit => 'Выйти';

  @override
  String get notificationReply => 'Ответить';

  @override
  String get notificationMarkRead => 'Прочитано';

  @override
  String notificationReplyNotSent(String text) {
    return 'Не отправлено: $text';
  }

  @override
  String get startAtLoginTitle => 'Запускать Conest при входе в систему';

  @override
  String get startAtLoginHelp =>
      'Открывается в трее, готов принимать сообщения, без окна.';

  @override
  String get notificationNewMessage => 'Новое сообщение';

  @override
  String notificationNewMessageFrom(String name) {
    return 'Новое сообщение от $name';
  }

  @override
  String get notificationReplyNotSentPlain => 'Ответ не отправлен';

  @override
  String get notificationPreviewTitle => 'Показывать в уведомлениях';

  @override
  String get notificationPreviewFull => 'Имя и сообщение';

  @override
  String get notificationPreviewSender => 'Только имя';

  @override
  String get notificationPreviewHidden => 'Ничего';

  @override
  String get voiceSettingsTitle => 'Голос';

  @override
  String get voiceInputDevice => 'Микрофон';

  @override
  String get voiceOutputDevice => 'Динамик или наушники';

  @override
  String get voiceSystemDefault => 'Как в системе';

  @override
  String get voiceInputVolume => 'Громкость микрофона';

  @override
  String get voiceOutputVolume => 'Громкость звука';

  @override
  String get voiceMicTest => 'Проверка микрофона';

  @override
  String get voiceMicTestStart => 'Проверить';

  @override
  String get voiceMicTestStop => 'Остановить';

  @override
  String get voiceMicTestLoopback => 'Слышать себя';

  @override
  String get voiceMicTestUnavailable =>
      'Проверка микрофона сейчас недоступна (идёт звонок или в этой сборке нет звонков).';

  @override
  String get voiceInputMode => 'Передавать мой голос';

  @override
  String get voiceInputModeAlways => 'Всегда';

  @override
  String get voiceInputModeActivity => 'Когда я говорю';

  @override
  String get voiceInputModePushToTalk => 'Рация (по нажатию)';

  @override
  String get voiceSensitivityAutomatic =>
      'Подбирать чувствительность автоматически';

  @override
  String get voiceSensitivity => 'Чувствительность';

  @override
  String get voicePushToTalkKey => 'Клавиша рации';

  @override
  String get voicePushToTalkKeyNone => 'Только кнопка в звонке';

  @override
  String get voicePushToTalkKeyPress => 'Нажмите клавишу…';

  @override
  String get voicePushToTalkKeyHint => 'работает, пока Conest на экране';

  @override
  String get voiceClear => 'Сбросить';

  @override
  String get voiceProcessing => 'Обработка';

  @override
  String get voiceNoiseSuppression => 'Шумоподавление';

  @override
  String get voiceEchoCancellation => 'Подавление эха';

  @override
  String get voiceAutoGain => 'Автоматическая громкость';

  @override
  String get voiceCallSounds => 'Звуки звонка';

  @override
  String get voiceCallSoundsHint => 'Входящий звонок всё равно звонит.';

  @override
  String get voiceDevicesOnPhone =>
      'На Android микрофон и динамик для звонков выбирает телефон.';

  @override
  String get voiceSettingsButton => 'Настройки голоса';

  @override
  String voiceParticipantVolume(String name) {
    return 'Громкость: $name';
  }

  @override
  String get voiceHoldToTalk => 'Удерживайте, чтобы говорить';

  @override
  String get quietHoursTitle => 'Тихие часы';

  @override
  String get quietHoursHint => 'Уведомления приходят без звука и вибрации.';

  @override
  String quietHoursFrom(String time) {
    return 'С $time';
  }

  @override
  String quietHoursUntil(String time) {
    return 'До $time';
  }

  @override
  String get quietHoursCallsRing => 'Звонки всё равно звонят';

  @override
  String get muteForHour => 'На 1 час';

  @override
  String get muteForEightHours => 'На 8 часов';

  @override
  String get muteForDay => 'На 1 день';

  @override
  String get muteUntilUnmuted => 'Пока не включу';

  @override
  String get notifyMentionsOnly => 'Уведомлять только об упоминаниях';

  @override
  String get notifyAllMessages => 'Уведомлять обо всех сообщениях';

  @override
  String get relayAccessTitle => 'Доступ к ретранслятору';

  @override
  String get relayAccessUnknown =>
      'Этот ретранслятор не сообщил, кто может им пользоваться (старая версия или ещё не проверен).';

  @override
  String get relayAccessSessions =>
      'Защищённое соединение: чьи сообщения вы забираете, скрыто от сети.';

  @override
  String get relayAccessMessagesOpen =>
      'Оставлять сообщения здесь может любой.';

  @override
  String get relayAccessMessagesRegistered =>
      'Оставлять сообщения здесь могут только зарегистрированные.';

  @override
  String get relayAccessMessagesOff =>
      'Этот ретранслятор не принимает новые сообщения.';

  @override
  String get relayAccessRegistrationOpen => 'Зарегистрироваться может любой.';

  @override
  String get relayAccessRegistrationInvite =>
      'Для регистрации нужен код приглашения.';

  @override
  String get relayAccessRegistrationPassword =>
      'Для регистрации нужен пароль ретранслятора.';

  @override
  String get relayAccessRegistrationClosed => 'Регистрация закрыта.';

  @override
  String relayAccessRegistered(String date) {
    return 'Зарегистрировано на этом ретрансляторе до $date.';
  }

  @override
  String get relayAccessInviteLabel => 'Код приглашения';

  @override
  String get relayAccessPasswordLabel => 'Пароль';

  @override
  String get relayAccessRegister => 'Зарегистрироваться';

  @override
  String get relayAccessRegisteredNow => 'Зарегистрировано.';

  @override
  String relayAccessFailed(String error) {
    return 'Не удалось зарегистрироваться: $error';
  }

  @override
  String get circumventionTitle => 'Обход цензуры';

  @override
  String get circumventionIntro =>
      'Для сетей, которые блокируют или фильтруют Conest. «Автоматически» включает это только в сетях, где маршруты похоже заблокированы.';

  @override
  String get circumventionPrivateDns => 'Частный поиск имён (DNS через HTTPS)';

  @override
  String get circumventionSplitGreeting =>
      'Разделять приветствие защищённого соединения';

  @override
  String get circumventionSplitGreetingHint =>
      'Скрывает от простых фильтров, к какому серверу вы подключаетесь.';

  @override
  String get circumventionQuietLan => 'Скрытый поиск устройств рядом';

  @override
  String get circumventionQuietLanHint =>
      'Устройства рядом находят друг друга по зашифрованному сигналу, а не по узнаваемому.';

  @override
  String get circumventionAutomatic => 'Автоматически';

  @override
  String get circumventionAlways => 'Всегда';

  @override
  String get circumventionNever => 'Выкл.';

  @override
  String get circumventionActiveHere => 'Используется в этой сети.';

  @override
  String get circumventionIdleHere => 'Не используется в этой сети.';
}

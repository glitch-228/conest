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
}

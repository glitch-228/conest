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
}

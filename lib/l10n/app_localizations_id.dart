// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Indonesian (`id`).
class AppLocalizationsId extends AppLocalizations {
  AppLocalizationsId([String locale = 'id']) : super(locale);

  @override
  String get modeChooseTitle => 'Bagaimana tampilan Conest yang kamu inginkan?';

  @override
  String get modeChangeLater =>
      'Kamu bisa mengubahnya kapan saja di Pengaturan.';

  @override
  String get modeSimple => 'Sederhana';

  @override
  String get modeStandard => 'Standar';

  @override
  String get modeAdvanced => 'Lanjutan';

  @override
  String get modeSimpleDescription =>
      'Satu daftar obrolan, teks besar, dan hanya pengaturan yang kamu perlukan. Pesan menunjukkan terkirim, diterima, dan dibaca.';

  @override
  String get modeStandardDescription =>
      'Seperti aplikasi pesan yang kamu kenal: obrolan, grup, panggilan, dan berkas, dengan tanda diterima dan dibaca.';

  @override
  String get modeAdvancedDescription =>
      'Semuanya, termasuk rute yang dilalui setiap pesan, semua transport, dan diagnostik.';

  @override
  String get actionContinue => 'Lanjut';

  @override
  String get actionStart => 'Mulai';

  @override
  String get actionBack => 'Kembali';

  @override
  String get actionClose => 'Tutup';

  @override
  String get routesTitle => 'Cara Conest menjangkau orang lain';

  @override
  String get routesDirect =>
      'Conest mengirim pesan langsung ke kontakmu lewat jaringanmu dan internet, tanpa server di tengah. Ini sudah aktif.';

  @override
  String get routesOthers =>
      'Jika jalur itu diblokir atau tidak ada, Conest juga bisa memakai relay, Tor, Nostr, email, Matrix, jaringan Bluetooth ponsel di sekitar, atau radio LoRa. Masing-masing nonaktif sampai kamu menyalakannya di Pengaturan → Konektivitas.';

  @override
  String get routesAdvanced =>
      'Di mode lanjutan setiap pesan menunjukkan rute yang dilaluinya, dan profil kontak bisa menguji setiap rute.';

  @override
  String get tabChats => 'Obrolan';

  @override
  String get tabCalls => 'Panggilan';

  @override
  String get tabSettings => 'Pengaturan';

  @override
  String get callsEmpty =>
      'Belum ada panggilan. Buka obrolan dan ketuk tombol panggil.';

  @override
  String get callOutgoing => 'Keluar';

  @override
  String get callIncoming => 'Masuk';

  @override
  String get callMissed => 'Tak terjawab';

  @override
  String get callDeclined => 'Ditolak';

  @override
  String get callCancelled => 'Dibatalkan';

  @override
  String get callFailed => 'Gagal';

  @override
  String callDuration(int minutes, int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes mnt $seconds dtk',
      zero: '$seconds dtk',
    );
    return '$_temp0';
  }

  @override
  String get unknownContact => 'Kontak tidak dikenal';

  @override
  String get messageDetails => 'Detail pesan';

  @override
  String messageSentAt(String time) {
    return 'Dikirim $time';
  }

  @override
  String messageReceivedAt(String time) {
    return 'Diterima $time';
  }

  @override
  String messageDeliveredAt(String time) {
    return 'Sampai $time';
  }

  @override
  String messageReadAt(String time) {
    return 'Dibaca $time';
  }

  @override
  String memberDeliveredAt(String time) {
    return 'sampai $time';
  }

  @override
  String memberReadAt(String time) {
    return 'dibaca $time';
  }

  @override
  String get messageRoutes => 'Rute';

  @override
  String get messageArrivedBy => 'Tiba lewat';

  @override
  String get settingsShowAll => 'Tampilkan semua pengaturan';

  @override
  String get settingsLanguage => 'Bahasa';

  @override
  String get settingsLanguageSystem => 'Sama dengan perangkat';

  @override
  String get settingsAiTranslated =>
      'Terjemahan ini dibuat dengan AI dan mungkin berisi kesalahan. Kamu bisa membantu memperbaikinya di Weblate.';
}

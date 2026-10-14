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

  @override
  String get menuReply => 'Balas';

  @override
  String get menuReact => 'Reaksi 👍';

  @override
  String get menuForward => 'Teruskan';

  @override
  String get menuCopyMessage => 'Salin pesan';

  @override
  String get menuDownloadAttachment => 'Unduh lampiran';

  @override
  String get menuSaveAttachment => 'Simpan lampiran';

  @override
  String get menuCopyImage => 'Salin gambar';

  @override
  String get menuFreeUpSpace => 'Kosongkan ruang lokal';

  @override
  String get menuCancelTransfer => 'Batalkan transfer';

  @override
  String get menuRetryTransfer => 'Coba transfer lagi';

  @override
  String get menuForwardAttachment => 'Teruskan lampiran';

  @override
  String get menuCancelSending => 'Batalkan pengiriman';

  @override
  String get menuEditMessage => 'Edit pesan';

  @override
  String get menuDeleteMessage => 'Hapus pesan';

  @override
  String get menuEdit => 'Edit';

  @override
  String get menuDelete => 'Hapus';

  @override
  String get composerAttach => 'Lampirkan berkas atau gambar';

  @override
  String get composerSchedule => 'Jadwalkan pesan';

  @override
  String get composerSend => 'Kirim';

  @override
  String get searchChatsAndMessages => 'Cari obrolan dan pesan';

  @override
  String get searchChats => 'Cari obrolan';

  @override
  String get searchContacts => 'Cari kontak';

  @override
  String get archivedChats => 'Obrolan yang diarsipkan';

  @override
  String get actionSearch => 'Cari';

  @override
  String get settingsPersonal => 'Pribadi';

  @override
  String get settingsStorage => 'Penyimpanan';

  @override
  String get settingsConnectivity => 'Konektivitas';

  @override
  String get settingsRelays => 'Relay';

  @override
  String get settingsUpdates => 'Pembaruan';

  @override
  String get settingsAccount => 'Akun';

  @override
  String get onbNameRequired =>
      'Masukkan nama tampilan dan port lokal yang valid.';

  @override
  String get onbRelayPortInvalid =>
      'Jika kamu mengisi alamat relay internet, port relay juga harus valid.';

  @override
  String get onbRelayDesktop =>
      'Komputer menjadi relay secara bawaan dan mengumumkan rute LAN terdekat secara otomatis.';

  @override
  String get onbRelayAndroid =>
      'Di Android mode relay mati di awal. Nyalakan di Pengaturan hanya jika kamu ingin perangkat ini menjadi relay.';

  @override
  String get onbRelayOther =>
      'Mode relay bisa dinyalakan di Pengaturan jika perangkat ini perlu membantu mengirim lalu lintas.';

  @override
  String get onbTagline =>
      'Hubungi kontak langsung lewat jaringanmu atau internet, terenkripsi ujung ke ujung dengan forward secrecy. Saat jalur biasa diblokir, Conest beralih ke relay, Matrix, Nostr, email, Tor, radio LoRa, atau jaringan Bluetooth ponsel di sekitar.';

  @override
  String get onbFeatureForwardSecret => 'Obrolan dengan forward secrecy';

  @override
  String get onbFeatureDirect => 'Langsung lewat LAN dan internet';

  @override
  String get onbFeatureFallbacks => 'Cadangan lewat Tor, mesh, dan radio';

  @override
  String get onbFeatureMatrix => 'Juga klien Matrix';

  @override
  String get onbCreateTitle => 'Buat perangkat pertamamu';

  @override
  String get onbCreateHelp =>
      'Hanya nama tampilan yang diperlukan. Port lokal dipakai untuk pengiriman di LAN dan pemasangan dengan frasa kode. Relay internet opsional: kontak tetap terjangkau lewat internet tanpanya. Nyalakan rute lain nanti di Pengaturan → Konektivitas.';

  @override
  String get onbDisplayName => 'Nama tampilan';

  @override
  String get onbLocalPort => 'Port relay lokal / LAN';

  @override
  String get onbRelayHost => 'Alamat relay internet (opsional)';

  @override
  String get onbRelayPort => 'Port relay internet';

  @override
  String get onbCreateButton => 'Buat perangkat terenkripsi';

  @override
  String get onbMatrixInstead => 'Pakai sebagai klien Matrix saja';

  @override
  String get onbMatrixHelp =>
      'Hanya obrolan Matrix, tanpa identitas Conest. Kamu bisa beralih ke Keduanya (Conest dan Matrix berdampingan) nanti di Pengaturan → Konektivitas → Mode aplikasi.';

  @override
  String get groupCreate => 'Buat grup';

  @override
  String get groupTitle => 'Nama grup';

  @override
  String get roleMember => 'Anggota';

  @override
  String get roleModerator => 'Moderator';

  @override
  String get roleAdmin => 'Admin';

  @override
  String get actionCancel => 'Batal';

  @override
  String get actionCreate => 'Buat';

  @override
  String get actionCreating => 'Membuat…';

  @override
  String get contactAdd => 'Tambah kontak';

  @override
  String get contactAlias => 'Alias';

  @override
  String get contactInvitePayload => 'Isi undangan atau QR yang dipindai';

  @override
  String get contactScanQr => 'Pindai QR';

  @override
  String get contactCodephrase => 'Frasa kode saja';

  @override
  String get contactTrustPayload => 'Percayai QR / undangan';

  @override
  String get contactFindCodephrase => 'Cari dengan frasa kode';

  @override
  String get contactExchangeFailed => 'Pertukaran otomatis gagal';

  @override
  String contactExchangeFailedBody(String alias) {
    return 'Kamu menambahkan $alias, tetapi undanganmu tidak bisa dikirim balik secara otomatis. Minta pengguna lain memindai atau memasukkan undanganmu dari sisinya, atau batalkan dan hapus kontak satu arah ini sekarang.';
  }

  @override
  String get actionAbort => 'Batalkan';

  @override
  String get contactKeep => 'Simpan kontak';
}

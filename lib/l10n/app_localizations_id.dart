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

  @override
  String get uiPassphrase89950C => 'Frasa sandi';

  @override
  String get uiConfirmPassphraseEBAAC0 => 'Konfirmasi frasa sandi';

  @override
  String get uiUnlock1526A1 => 'Buka kunci';

  @override
  String get uiUpdateAvailable67FD3A => 'Pembaruan tersedia';

  @override
  String get uiLater56E2F5 => 'Nanti';

  @override
  String get uiHostAutoDetectsTCPUDP663D30 =>
      'host mendeteksi TCP/UDP otomatis; udp://host:port memaksa UDP';

  @override
  String get uiVerificationRequestDA06F9 => 'Permintaan verifikasi';

  @override
  String get uiIgnore98F55D => 'Abaikan';

  @override
  String get uiVerifyDDA6AC => 'Verifikasi';

  @override
  String uiCouldNotReadValueValue695755(String value, String value2) {
    return 'Tidak dapat membaca $value: $value2';
  }

  @override
  String uiCouldNotShareValueValue7BA3A3(String value, String value2) {
    return 'Tidak dapat membagikan $value: $value2';
  }

  @override
  String uiCouldNotSaveSidebarWidthB4DACB(String value) {
    return 'Tidak dapat menyimpan lebar bilah samping: $value';
  }

  @override
  String get uiNoAudioOutputDevicesWere17E473 =>
      'Tidak ada perangkat keluaran audio.';

  @override
  String get uiCallAudioOutput0C276F => 'Keluaran audio panggilan';

  @override
  String uiCallAudioRoutedToValueFFFBE8(String value) {
    return 'Audio panggilan dialihkan ke $value.';
  }

  @override
  String uiCouldNotChangeCallAudio6CE7B1(String value) {
    return 'Tidak dapat mengubah keluaran audio panggilan: $value';
  }

  @override
  String uiCouldNotOpenInviteValue6C4D06(String value) {
    return 'Tidak dapat membuka undangan: $value';
  }

  @override
  String uiCouldNotSendAttachmentValueEFF771(String value) {
    return 'Tidak dapat mengirim lampiran: $value';
  }

  @override
  String uiCouldNotSendMessageValue042C4F(String value) {
    return 'Tidak dapat mengirim pesan: $value';
  }

  @override
  String get uiSendFromOriginalFFF29A => 'Kirim dari berkas asli';

  @override
  String uiCouldNotSendGroupMessageB6C7D1(String value) {
    return 'Tidak dapat mengirim pesan grup: $value';
  }

  @override
  String uiCouldNotSendLANLobby8E7487(String value) {
    return 'Tidak dapat mengirim pesan lobi LAN: $value';
  }

  @override
  String uiCouldNotStageValuePathless514094(String value) {
    return 'Tidak dapat menyiapkan $value: berkas yang dijatuhkan tanpa jalur dibatasi 8 MB untuk melindungi memori.';
  }

  @override
  String get uiSelectAGroupBeforeDropping9DAB4C =>
      'Pilih grup sebelum menjatuhkan berkas.';

  @override
  String uiValueLocalFilePathUnavailable217177(String value) {
    return '$value: jalur berkas lokal tidak tersedia.';
  }

  @override
  String uiValueSentWithoutIt7E0635(String value) {
    return '$value Dikirim tanpanya.';
  }

  @override
  String get uiGroupFileScheduledB1DC66 => 'Berkas grup dijadwalkan.';

  @override
  String uiCouldNotScheduleValueValue25CED3(String value, String value2) {
    return 'Tidak dapat menjadwalkan $value: $value2';
  }

  @override
  String uiCouldNotOpenFilePicker8FF0C0(String value) {
    return 'Tidak dapat membuka pemilih berkas: $value';
  }

  @override
  String uiValuePickerReturnedNoData4670CA(String value) {
    return '$value: pemilih tidak mengembalikan data.';
  }

  @override
  String uiOnlyTheFirstValueFiles45FC47(String value, String value2) {
    return 'Hanya $value berkas pertama yang disiapkan (diterima $value2).';
  }

  @override
  String uiValueSkippedValueMBExceeds487B2A(String value, String value2) {
    return '$value dilewati: $value2 MB melebihi batas $value MB.';
  }

  @override
  String get uiTransfers812412 => 'Transfer';

  @override
  String uiValue75CED7(String value) {
    return '$value';
  }

  @override
  String get uiPreparingCallE86D6C => 'Menyiapkan panggilan…';

  @override
  String get uiCallingACD4A6 => 'Memanggil…';

  @override
  String get uiIncomingVoiceCallF68FD3 => 'Panggilan suara masuk';

  @override
  String get uiConnectingFD3E79 => 'Menghubungkan…';

  @override
  String get uiReconnecting8A8B95 => 'Menghubungkan kembali…';

  @override
  String get uiCallEnded9933A4 => 'Panggilan berakhir';

  @override
  String uiVoiceCallValue06FE1F(String value) {
    return 'Panggilan suara: $value';
  }

  @override
  String get uiMinimizeCall6CB0F0 => 'Perkecil panggilan';

  @override
  String get uiAcceptBB54DB => 'Terima';

  @override
  String get uiReject2B03B5 => 'Tolak';

  @override
  String get uiNoiseSuppression71DE3C => 'Peredam bising';

  @override
  String get uiAudioOutput2B89CC => 'Keluaran audio';

  @override
  String get uiDoneE9B450 => 'Selesai';

  @override
  String get uiHangUp66BE99 => 'Akhiri panggilan';

  @override
  String get uiCloseDetails433DA6 => 'Tutup detail';

  @override
  String get uiOpenFullProfile35063C => 'Buka profil lengkap';

  @override
  String get uiOpenGroupSettings0B568E => 'Buka pengaturan grup';

  @override
  String get uiNewFolderA71199 => 'Folder baru';

  @override
  String get uiFolderNameB2CE02 => 'Nama folder';

  @override
  String get uiMoveEarlier07DD6F => 'Pindahkan lebih awal';

  @override
  String get uiMoveLaterBB4C84 => 'Pindahkan lebih akhir';

  @override
  String get uiSaveEFC007 => 'Simpan';

  @override
  String get uiAddToFolderBFAD96 => 'Tambahkan ke folder';

  @override
  String get uiNewMessage1ED2E7 => 'Pesan baru';

  @override
  String get uiBackToChats8DE6F6 => 'Kembali ke obrolan';

  @override
  String get uiNavigationMenu6609F1 => 'Menu navigasi';

  @override
  String get uiAllChats398E5B => 'Semua obrolan';

  @override
  String get uiSearchAllChatsC825C8 => 'Cari semua obrolan';

  @override
  String get uiClearSearch67300D => 'Hapus pencarian';

  @override
  String get uiContactRequests082691 => 'Permintaan kontak';

  @override
  String get uiReviewPeopleWhoWantTo24A8CB =>
      'Tinjau orang yang ingin terhubung';

  @override
  String get uiNoChatsFoundC6BD82 => 'Obrolan tidak ditemukan';

  @override
  String get uiNoArchivedChatsEAE7F0 => 'Tidak ada obrolan diarsipkan';

  @override
  String get uiNoMatrixChatsYet23B023 => 'Belum ada obrolan Matrix';

  @override
  String get uiNewGroupF9850C => 'Grup baru';

  @override
  String get uiAddWithConestBeam19D1E2 => 'Tambahkan dengan Conest Beam';

  @override
  String get uiDirectMessagesE7596A => 'Pesan langsung';

  @override
  String get uiConestBeamE98B77 => 'Conest Beam';

  @override
  String get uiMyInviteF80A7A => 'Undangan saya';

  @override
  String get uiGroupDetailsDF844A => 'Detail grup';

  @override
  String get uiDebugBD604D => 'Debug';

  @override
  String get uiAdd61CC55 => 'Tambahkan';

  @override
  String get uiPollRoutesNow22318F => 'Periksa rute sekarang';

  @override
  String get uiContactProfile1B3A0E => 'Profil kontak';

  @override
  String get uiHistoryForNewMembersF419F2 => 'Riwayat untuk anggota baru';

  @override
  String get uiChooseHowToWindDownF7399D =>
      'Pilih cara mengakhiri grup ini. Pengalihan kepemilikan mempertahankan grup dengan pemilik baru dan menjadikan Anda admin. Menghapus untuk semua menghapus grup dari daftar setiap anggota dan tidak dapat dibatalkan.';

  @override
  String get uiTransferOwnershipA563C9 => 'Alihkan kepemilikan…';

  @override
  String get uiDeleteForEveryoneE055A8 => 'Hapus untuk semua';

  @override
  String get uiNoOtherActiveMembersToF9DE12 =>
      'Tidak ada anggota aktif lain untuk menerima kepemilikan.';

  @override
  String get uiTransferOwnershipA6819E => 'Alihkan kepemilikan';

  @override
  String get uiTransferCBB4CC => 'Alihkan';

  @override
  String uiOwnershipTransferredToValue14A10D(String value) {
    return 'Kepemilikan dialihkan ke $value.';
  }

  @override
  String get uiEveryMemberWillBeRemoved75A3FC =>
      'Semua anggota akan dikeluarkan dan grup ditandai telah ditinggalkan dalam daftar masing-masing. Riwayat pesan lokal tidak dihapus otomatis; tiap anggota dapat menghapusnya lewat Hapus dari daftar. Ini tidak dapat dibatalkan.';

  @override
  String get uiRemoveThisGroup38C4E8 => 'Hapus grup ini?';

  @override
  String get uiRemoveThisGroupFromYourDA7898 =>
      'Hapus grup ini dari daftar Anda? Riwayat pesan lokal akan dihapus. Anggota lain tidak diberi tahu; mereka sudah melihat Anda telah keluar.';

  @override
  String get uiRemoveE96390 => 'Hapus';

  @override
  String get uiChangeRole2B9BFD => 'Ubah peran';

  @override
  String get uiRemoveMember1C31D1 => 'Hapus anggota';

  @override
  String get uiChooseWhatFutureMembersCanC38992 =>
      'Pilih riwayat yang dapat dibaca anggota baru';

  @override
  String get uiAddMember170AD0 => 'Tambahkan anggota';

  @override
  String get uiDeleteGroup043336 => 'Hapus grup…';

  @override
  String get uiLeave7E3520 => 'Keluar';

  @override
  String get uiRemoveFromList23A976 => 'Hapus dari daftar';

  @override
  String get uiForwardMessage482959 => 'Teruskan pesan';

  @override
  String get uiSavedMessagesC0FA7E => 'Pesan tersimpan';

  @override
  String get uiThisAttachmentIsNotAvailableFE641A =>
      'Lampiran ini belum tersedia secara lokal.';

  @override
  String get uiDownloadThisFileBeforeForwarding60D7B5 =>
      'Unduh berkas ini sebelum meneruskannya.';

  @override
  String get uiSearchMessagesABEA65 => 'Cari pesan';

  @override
  String get uiStartVoiceCallExperimental6DE320 =>
      'Mulai panggilan suara (eksperimental)';

  @override
  String get uiChatOptionsA40D0F => 'Opsi obrolan';

  @override
  String get uiPausePreview805180 => 'Jeda pratinjau';

  @override
  String get uiPlayPreview47BB44 => 'Putar pratinjau';

  @override
  String get uiUnmutePreview12A31A => 'Aktifkan suara pratinjau';

  @override
  String get uiMutePreviewCE44BD => 'Bisukan pratinjau';

  @override
  String get uiPauseVoiceMessageECD12D => 'Jeda pesan suara';

  @override
  String get uiPlayVoiceMessageB16684 => 'Putar pesan suara';

  @override
  String get uiPlaybackSpeed6FF42B => 'Kecepatan putar';

  @override
  String get uiStopRecordingEE0D9D => 'Hentikan rekaman';

  @override
  String get uiDeleteRecording8B58CE => 'Hapus rekaman';

  @override
  String uiCouldNotLoadOlderGroup1A192E(String value) {
    return 'Tidak dapat memuat riwayat grup sebelumnya: $value';
  }

  @override
  String uiMessageScheduledForValueD2D788(String value) {
    return 'Pesan dijadwalkan pada $value.';
  }

  @override
  String get uiNewPoll6D62BD => 'Jajak pendapat baru';

  @override
  String get uiQuestion002FF5 => 'Pertanyaan';

  @override
  String get uiOptionsOnePerLine62FF3D => 'Opsi (satu per baris)';

  @override
  String get uiDeleteMessageD536CF => 'Hapus pesan?';

  @override
  String get uiDeleteSelectedMessages190A5F => 'Hapus pesan yang dipilih?';

  @override
  String uiDeleteFailedForOneMessage26C302(String value) {
    return 'Gagal menghapus satu pesan: $value';
  }

  @override
  String get uiNothingToCopyFromTheEC27E3 =>
      'Tidak ada yang dapat disalin dari pesan terpilih.';

  @override
  String uiCopiedValueMessageSC97E6E(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value pesan disalin.',
    );
    return '$_temp0';
  }

  @override
  String get uiNoSelectedAttachmentIsReady536B54 =>
      'Belum ada lampiran terpilih yang siap; transfer masih berlangsung.';

  @override
  String get uiCopiedMessageText9DC18F => 'Teks pesan disalin.';

  @override
  String get uiTheGroupFileIsNotF8A236 =>
      'Berkas grup tidak tersedia secara lokal.';

  @override
  String uiSavedValue0463E5(String value) {
    return '$value disimpan.';
  }

  @override
  String uiCouldNotSaveValueValue178005(String value, String value2) {
    return 'Tidak dapat menyimpan $value: $value2';
  }

  @override
  String get uiTheAndroidFileSaverIsDF910B =>
      'Penyimpan berkas Android tidak tersedia.';

  @override
  String get uiOpeningFilesIsUnavailableOnC6ADA2 =>
      'Membuka berkas tidak tersedia di platform ini.';

  @override
  String uiCouldNotOpenValueValue283326(String value, String value2) {
    return 'Tidak dapat membuka $value: $value2';
  }

  @override
  String get uiYou905CB3 => 'Anda';

  @override
  String get uiMessage68F414 => 'Pesan';

  @override
  String get uiMessageActions949184 => 'Tindakan pesan';

  @override
  String get uiTheAttachmentIsStillDownloadingF77317 =>
      'Lampiran masih diunduh.';

  @override
  String get uiShareOrScheduleAGroup2989F0 =>
      'Bagikan atau jadwalkan berkas grup';

  @override
  String get uiRecordingBelongsToAnotherConversation87E802 =>
      'Rekaman milik obrolan lain';

  @override
  String get uiFinishTheVoicePreviewIn142571 =>
      'Selesaikan pratinjau suara di obrolan asalnya';

  @override
  String get uiReviewUnsentVoiceMessage24931C =>
      'Tinjau pesan suara belum terkirim';

  @override
  String get uiCancelMicrophoneStartup9E9F8A => 'Batalkan pengaktifan mikrofon';

  @override
  String get uiReleaseToDiscardRecording4C5C71 =>
      'Lepas untuk membuang rekaman';

  @override
  String get uiRecordingLockedTapToFinish40CD88 =>
      'Rekaman dikunci · ketuk untuk selesai';

  @override
  String get uiReleaseToStopSlideLeft4686F1 =>
      'Lepas untuk berhenti · geser kiri untuk batal · geser atas untuk kunci';

  @override
  String get uiHoldToRecordAGroupC11B32 =>
      'Tahan untuk merekam pesan suara grup';

  @override
  String get uiCreatePoll8F5663 => 'Buat jajak pendapat';

  @override
  String get uiWriteToGroup5878DB => 'Tulis ke grup';

  @override
  String get uiWriteAReply0A58E1 => 'Tulis balasan';

  @override
  String get uiYouAreNoLongerIn571DA7 => 'Anda bukan lagi anggota grup ini';

  @override
  String get uiVote64F872 => 'Pilih';

  @override
  String get uiChooseOptionsEA120E => 'Pilih opsi';

  @override
  String get uiRetractVoteA5DA11 => 'Tarik suara';

  @override
  String get uiClosePollA6A189 => 'Tutup jajak pendapat';

  @override
  String get uiScheduleOneAttachmentAtAC580C3 =>
      'Jadwalkan satu lampiran setiap kali.';

  @override
  String get uiNotDeliveredYetSendViaF056E1 =>
      'Belum terkirim. Kirim lewat Matrix…';

  @override
  String get uiVoiceCallsAreTurnedOff692843 =>
      'Panggilan suara nonaktif. Aktifkan di Pengaturan untuk menelepon.';

  @override
  String get uiVoiceCallAudioIsUnavailable0B6C43 =>
      'Audio panggilan tidak tersedia dalam build ini.';

  @override
  String get uiRouteInspector0E65DE => 'Pemeriksa rute';

  @override
  String get uiThisContactRequestIsBlocked944F7D =>
      'Permintaan kontak ini diblokir.';

  @override
  String get uiMessageSavedHereUntilTheA49A2C =>
      'Pesan disimpan di sini sampai kontak menerima.';

  @override
  String get uiWriteAnEncryptedMessage9F7705 => 'Tulis pesan terenkripsi';

  @override
  String get uiWriteAReplyOrAddFC0A42 =>
      'Tulis balasan atau tambahkan keterangan';

  @override
  String get uiHoldToRecordAVoice06B1B5 => 'Tahan untuk merekam pesan suara';

  @override
  String get uiWriteToNearbyLANUsers291142 => 'Tulis ke pengguna LAN sekitar';

  @override
  String get uiBroadcast77CA3F => 'Siaran';

  @override
  String get uiThisRemovesTheLocalContact0D6D1E =>
      'Ini menghapus kontak dan riwayat pesan lokal. Aplikasi juga mencoba mengirim pemberitahuan penghapusan agar kontak ini hilang di sisi lain.';

  @override
  String get uiDescriptionBio505243 => 'Deskripsi / bio';

  @override
  String get uiCheckPaths917FF3 => 'Periksa jalur';

  @override
  String get uiCopyState9BFD16 => 'Salin status';

  @override
  String get uiRemoveContact7F9A8A => 'Hapus kontak';

  @override
  String get uiSaveProfile909BF3 => 'Simpan profil';

  @override
  String get uiShowAsBeam74375F => 'Tampilkan sebagai Beam';

  @override
  String get uiShowTheQRAnyway0B0CDF => 'Tetap tampilkan QR';

  @override
  String get uiOpenFullscreenQRC5418D => 'Buka QR layar penuh';

  @override
  String get uiShowQRCFBAC6 => 'Tampilkan QR';

  @override
  String get uiLegacyInviteC61C5D => 'Undangan lama';

  @override
  String get uiForContactsOnConestOr486754 =>
      'Untuk kontak dengan Conest 0.3.11 atau lebih lama. Rute jaringan terblokir tidak disertakan; rute tiba setelah terhubung.';

  @override
  String get uiRotateCodephraseNow89B2D5 => 'Ganti frasa kode sekarang';

  @override
  String get uiEncryptForContactE07450 => 'Enkripsi untuk kontak';

  @override
  String get uiPublicOpticalTransfer58E3F4 => 'Transfer optik publik';

  @override
  String get uiAnyoneWhoCanSeeTheFAB2D0 =>
      'Siapa pun yang melihat layar dapat menyusun ulang berkas ini. Tanda tangan menjamin integritasnya, tetapi berkas tidak rahasia.';

  @override
  String get uiChoosePublicFile6E2739 => 'Pilih berkas publik';

  @override
  String get uiKeepThisScreenVisibleUntil2261B8 =>
      'Biarkan layar ini terlihat sampai penerima melaporkan 100%.';

  @override
  String get uiReceiveConestBeamB05BCB => 'Terima Conest Beam';

  @override
  String get uiDesktopCameraActiveDA0F15 => 'Kamera desktop aktif';

  @override
  String get uiPasteOneCbFrame66EA2B => 'Tempel satu bingkai cb1';

  @override
  String get uiAddFrame2BBA30 => 'Tambahkan bingkai';

  @override
  String get uiContactAliasE07C25 => 'Alias kontak';

  @override
  String get uiWeComparedThisFingerprintIn952BEB =>
      'Kami membandingkan sidik jari ini langsung';

  @override
  String get uiTrustAndAddContact0962A2 => 'Percayai dan tambahkan kontak';

  @override
  String get uiSavedInPrivateConestStorage4C1334 =>
      'Disimpan di penyimpanan privat Conest:';

  @override
  String get uiResetIdentity8B0224 => 'Setel ulang identitas';

  @override
  String get uiThisClearsTheEncryptedVault864B3D =>
      'Ini menghapus brankas terenkripsi, kontak, dan pesan, lalu mengembalikan aplikasi ke keadaan awal.';

  @override
  String get uiReset44C57A => 'Setel ulang';

  @override
  String get uiNoIdentityIsActive6B2EE3 => 'Tidak ada identitas aktif.';

  @override
  String get uiSaveNameE73831 => 'Simpan nama';

  @override
  String get uiSaveBioBE2711 => 'Simpan bio';

  @override
  String get uiMessageNotifications595635 => 'Notifikasi pesan';

  @override
  String get uiShowASystemNotificationWhen90113B =>
      'Tampilkan notifikasi sistem saat pesan langsung tiba.';

  @override
  String get uiExperimentalVoiceCalls51098B => 'Panggilan suara eksperimental';

  @override
  String get uiExperimentalAndroidBackgroundReceive60828A =>
      'Penerimaan latar Android eksperimental';

  @override
  String get uiDisabledInReleaseBuildsThe45B7DF =>
      'Nonaktif pada build rilis: layanan latar depan belum menjalankan penerima Flutter tanpa antarmuka.';

  @override
  String get uiAllowVoiceCallsInBackground73C5C5 =>
      'Izinkan panggilan suara di latar';

  @override
  String get uiKeepsCallSignalingActiveAndC0A342 =>
      'Menjaga sinyal panggilan aktif dan menampilkan notifikasi panggilan selama layanan Conest berjalan. Memerlukan Panggilan suara eksperimental; kebijakan baterai Android atau paksa berhenti tetap dapat menghentikannya.';

  @override
  String get uiDonTSendReadConfirmations230076 => 'Jangan kirim tanda dibaca';

  @override
  String get uiDebugOnlyDeliveryAcknowledgementsStill7D6A9C =>
      'Khusus debug. Tanda terima terkirim tetap dikirim; tanda dibaca masuk tetap diproses.';

  @override
  String get uiRemoveMetadataFromFilesA4860E => 'Hapus metadata berkas';

  @override
  String get uiBeforeSendingRemovesLocationCamera4E390D =>
      'Menghapus lokasi, kamera, penulis, dan tanggal dari foto, video, PDF, serta dokumen kantor sebelum dikirim. Gambar tidak dikompresi ulang. Berkas lain dikirim apa adanya.';

  @override
  String get uiSendFilesUnderRandomNames5F79D4 =>
      'Kirim berkas dengan nama acak';

  @override
  String get uiReplacesFileNamesWithRandom16F099 =>
      'Mengganti nama berkas dengan huruf acak untuk Anda dan penerima (jenisnya, seperti .jpg, tetap).';

  @override
  String get uiKeepOfStorageFreeF00434 => 'Sisakan 10% penyimpanan kosong';

  @override
  String get uiReserveFreeSpaceForOther1AC9CF =>
      'Sisakan ruang untuk aplikasi lain. Jika nonaktif, transfer dapat memakai ruang ini tetapi tetap harus muat di disk.';

  @override
  String get uiLAN2ECD17 => 'LAN';

  @override
  String get uiSameNetworkListenerPairingBeacons5CF0A2 =>
      'Penerima jaringan yang sama, suar pemasangan, pengiriman LAN.';

  @override
  String get uiOnlineC3E839 => 'Daring';

  @override
  String get uiIrohMessagingAndFileTransfersC4D635 =>
      'Pesan dan transfer berkas Iroh melalui internet. Relai Conest khusus bersifat opsional.';

  @override
  String get uiIrohRelayFallbackE954F7 => 'Cadangan relai Iroh';

  @override
  String get uiUseIrohSBuiltIn631E03 =>
      'Gunakan relai bawaan Iroh untuk pesan dan berkas saat koneksi langsung gagal. Kedua pihak harus daring.';

  @override
  String get uiLimitIrohFilesToMiBB58353 =>
      'Batasi berkas Iroh hingga 100 MiB (disarankan)';

  @override
  String get uiAppliesToDirectOnlineAnd28F6F1 =>
      'Berlaku untuk transfer daring langsung dan relai Iroh. Nonaktifkan untuk berkas lebih besar; transfer mungkin lama. Batas LAN yang lebih besar tetap berlaku.';

  @override
  String get uiShareEmailAndMatrixAddressesD762EE =>
      'Bagikan alamat email dan Matrix ke anggota grup';

  @override
  String get uiLetsMembersOfYourGroups9912A5 =>
      'Mengizinkan anggota grup yang bukan kontak menghubungi Anda lewat email atau Matrix. Jika nonaktif, mereka hanya mendapat alamat Nostr, Tor, dan radio yang tidak menyebut nama Anda. Menonaktifkan menghentikan pembagian berikutnya; alamat yang sudah terlihat dapat disimpan.';

  @override
  String get uiAutomaticDownloads5E777B => 'Unduhan otomatis';

  @override
  String get uiVerifiedContactsOnlyLimitsAdapt8A1876 =>
      'Hanya kontak terverifikasi. Batas menyesuaikan Wi-Fi/Ethernet, seluler, dan roaming.';

  @override
  String get uiCustomIrohRelayURLsDBF979 => 'URL relai Iroh khusus';

  @override
  String get uiOneHTTPSURLPerLineDA8E70 =>
      'Satu URL HTTPS per baris; kosong memakai relai standar N0.';

  @override
  String get uiSaveIrohRelaysC144AD => 'Simpan relai Iroh';

  @override
  String get uiCheckAvailabilityFCC1A6 => 'Periksa ketersediaan';

  @override
  String get uiRunThisDeviceAsA9DEA14 => 'Jalankan perangkat ini sebagai relai';

  @override
  String get uiAllowTrustedContactsToUse001771 =>
      'Izinkan kontak tepercaya memakai perangkat ini sebagai relai.';

  @override
  String get uiAutoUseContactsAsRelaysC62C06 =>
      'Otomatis gunakan kontak sebagai relai';

  @override
  String get uiLocalRelayPort28A73C => 'Port relai lokal';

  @override
  String get uiSavePort1876F6 => 'Simpan port';

  @override
  String get uiRelayHostURLF11441 => 'Host / URL relai';

  @override
  String get uiRelayPortEA05DA => 'Port relai';

  @override
  String get uiDetectAddRelayE825AD => 'Deteksi dan tambah relai';

  @override
  String get uiErrorHistory25AFF8 => 'Riwayat galat';

  @override
  String get uiWhatWentWrongKeptAcross27FC1F =>
      'Catatan kesalahan disimpan lintas mulai ulang pada build ini agar dapat disalin untuk laporan bug.';

  @override
  String get uiReceiveUnstableUpdatesBF7122 => 'Terima pembaruan tidak stabil';

  @override
  String get uiAlsoOfferNightlyBuildsNewerA7FAB0 =>
      'Tawarkan juga build nightly: fitur lebih baru, pengujian lebih sedikit. Rilis stabil yang lebih baru selalu ditawarkan.';

  @override
  String get uiResetAppIdentity2E0F86 => 'Setel ulang identitas aplikasi';

  @override
  String get uiTrustNewKeyA181BE => 'Percayai kunci baru';

  @override
  String get uiVerifyThePersonAndCompare738F28 =>
      'Verifikasi orangnya dan bandingkan nomor keamanan lewat saluran lain sebelum menerima.';

  @override
  String get uiReviewE29A79 => 'Tinjau';

  @override
  String get uiDiscardChat319267 => 'Buang obrolan';

  @override
  String get uiConfirmIdentityReplacement0219C5 =>
      'Konfirmasi penggantian identitas?';

  @override
  String get uiItSThem394960 => 'Benar orangnya';

  @override
  String get uiRejectThisIdentityCB604F => 'Tolak identitas ini?';

  @override
  String get uiThisDeletesTheNewContactBB4444 =>
      'Ini menghapus kontak baru dan pesan masuk yang ditahan. Gunakan jika Anda menduga penyamaran.';

  @override
  String get uiNotThem685593 => 'Bukan orangnya';

  @override
  String get uiRemoveImportedList36FC81 => 'Hapus daftar impor?';

  @override
  String get uiNoBundledConestRelaysOnline46529B =>
      'Tidak ada relai Conest bawaan. Koneksi daring memakai Iroh; Anda juga dapat mengatur relai sendiri.';

  @override
  String get uiImportFromURL3F7B77 => 'Impor dari URL…';

  @override
  String get uiImportRelayListFromURL86E363 => 'Impor daftar relai dari URL';

  @override
  String get uiJSONURL6918BA => 'URL JSON';

  @override
  String get uiOperatorSPublicKeyOptionalA80E7A =>
      'Kunci publik operator (opsional, base64)';

  @override
  String get uiImportD6FBC9 => 'Impor';

  @override
  String get uiCLEAN2F3D27 => 'BERSIH';

  @override
  String get uiSUBTLEBB048B => 'HALUS';

  @override
  String get uiDEFAULTC18920 => 'BAWAAN';

  @override
  String get uiFULLCC0A74 => 'PENUH';

  @override
  String get uiLANFirstB360D1 => 'LAN dahulu';

  @override
  String get uiLANOnly94945D => 'Hanya LAN';

  @override
  String get uiOnlineFirst346B6D => 'Daring dahulu';

  @override
  String get uiOnlineOnlyF79CB9 => 'Hanya daring';

  @override
  String get uiOfflineE01FA7 => 'Luring';

  @override
  String get uiUsesLANWhenAvailableFallsA810EF =>
      'Gunakan LAN jika tersedia, lalu daring sebagai cadangan.';

  @override
  String get uiUsesLANOnlyNoRelay589D55 =>
      'Hanya LAN. Tidak ada lalu lintas relai untuk kontak ini.';

  @override
  String get uiUsesOnlineWhenAvailableFallsCE2CAF =>
      'Gunakan daring jika tersedia, lalu LAN sebagai cadangan.';

  @override
  String get uiUsesOnlineOnlyNoLAN193810 =>
      'Hanya daring. Tidak ada lalu lintas LAN untuk kontak ini.';

  @override
  String get uiNoTransportSelectedThisContact7969EB =>
      'Tidak ada transport dipilih; kontak ini tidak terjangkau.';

  @override
  String get uiGlobalConnectivityIsOffAdjustA7C644 =>
      'Konektivitas global nonaktif; ubah Pengaturan untuk mengirim.';

  @override
  String get uiSameNetworkDelivery94E793 => 'Pengiriman di jaringan yang sama';

  @override
  String get uiDisabledByGlobalSetting2CB06C =>
      'Nonaktif oleh pengaturan global';

  @override
  String get uiAllowIrohRelayFallback35227B => 'Izinkan cadangan relai Iroh';

  @override
  String get uiVisibleAndOnlineOnlyDirectEA8902 =>
      'Terlihat dan hanya daring; Iroh langsung diutamakan.';

  @override
  String get uiRelayInternetDeliveryD64AB6 => 'Pengiriman relai / internet';

  @override
  String get uiPrefer13F662 => 'Utamakan';

  @override
  String get uiCarryTheirMessages22FD33 => 'Teruskan pesannya';

  @override
  String get uiWhenThisContactCannotReach5C3FF8 =>
      'Saat kontak ini tidak dapat menjangkau seseorang tetapi perangkat Anda bisa, teruskan pesannya. Anda hanya melihat tujuan dan waktu; isi tetap terenkripsi.';

  @override
  String uiSaveValueFileSToB46C57(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Simpan $value berkas ke…',
    );
    return '$_temp0';
  }

  @override
  String get uiSaveCanceled1939D0 => 'Penyimpanan dibatalkan.';

  @override
  String get uiAlbumActions7B6D70 => 'Tindakan album';

  @override
  String get uiCancelSelectionF7F56C => 'Batalkan pilihan';

  @override
  String get uiCopyAF74F7 => 'Salin';

  @override
  String get uiSaveAttachments5A74EA => 'Simpan lampiran';

  @override
  String get uiCancelAndClearAllTransfers01B81D =>
      'Batalkan dan hapus semua transfer?';

  @override
  String get uiKeepTransfersDB8CC7 => 'Pertahankan transfer';

  @override
  String get uiCancelAndClearCCF59C => 'Batalkan dan hapus';

  @override
  String get uiPauseAll6F6099 => 'Jeda semua';

  @override
  String get uiResumeAll039916 => 'Lanjutkan semua';

  @override
  String get uiCancelAndClearAllTransfersACEBB3 =>
      'Batalkan dan hapus semua transfer';

  @override
  String get uiClearCompletedE63FC1 => 'Hapus yang selesai';

  @override
  String get uiMoveToTop44AFA6 => 'Pindahkan ke atas';

  @override
  String get uiPreparingDownloadF9B13B => 'Menyiapkan unduhan';

  @override
  String get uiDownloadA479C9 => 'Unduh';

  @override
  String get uiResumeB3BD0B => 'Lanjutkan';

  @override
  String get uiPause781961 => 'Jeda';

  @override
  String get uiRetry9F5CD8 => 'Coba lagi';

  @override
  String get uiContinueOverIrohRelay949702 => 'Lanjutkan lewat relai Iroh';

  @override
  String get uiDownloadAnyway42859F => 'Tetap unduh';

  @override
  String get uiPreparing96A9B7 => 'Menyiapkan';

  @override
  String get uiQueued6A5998 => 'Dalam antrean';

  @override
  String get uiWaiting33D306 => 'Menunggu';

  @override
  String get uiTransferring73F753 => 'Mentransfer';

  @override
  String get uiReconnecting9D80F9 => 'Menghubungkan kembali';

  @override
  String get uiPausedC7DFB6 => 'Dijeda';

  @override
  String get uiVerifying536244 => 'Memverifikasi';

  @override
  String get uiComplete1F5A1A => 'Selesai';

  @override
  String get uiCanceledF840AC => 'Dibatalkan';

  @override
  String get uiUnavailable2C9C1F => 'Tidak tersedia';

  @override
  String uiSavedValueToValue08F152(String value, String value2) {
    return '$value disimpan ke $value2.';
  }

  @override
  String uiGallerySaveFailedValueFalling0B82BB(String value) {
    return 'Gagal menyimpan ke galeri ($value); beralih ke dialog berkas.';
  }

  @override
  String uiSaveValue5769AA(String value) {
    return 'Simpan $value';
  }

  @override
  String uiSaveFailedValue534182(String value) {
    return 'Gagal menyimpan: $value';
  }

  @override
  String get uiTheAttachmentFileIsNotA67009 =>
      'Berkas lampiran tidak tersedia secara lokal.';

  @override
  String uiCopiedValueToClipboard669D0B(String value) {
    return '$value disalin ke papan klip.';
  }

  @override
  String uiCopiedValueTextOnlySystemB51B8D(String value) {
    return '\"$value\" disalin (hanya teks; papan klip biner sistem tidak tersedia).';
  }

  @override
  String uiCopyFailedValueFilenameCopiedF71C87(String value) {
    return 'Gagal menyalin: $value. Nama berkas disalin sebagai teks cadangan.';
  }

  @override
  String get uiCachePathIsNotReady0404B5 =>
      'Jalur cache belum siap; transfer masih berlangsung.';

  @override
  String uiCachePathCopiedValue4CC1C4(String value) {
    return 'Jalur cache disalin: $value';
  }

  @override
  String get uiVideoIsnTCachedLocally8920DD =>
      'Video belum tersimpan lokal; tunggu transfer selesai.';

  @override
  String uiCouldNotOpenVideoIn054087(String value) {
    return 'Tidak dapat membuka video di pemutar sistem: $value';
  }

  @override
  String get uiImageIsNotAvailableLocally12017F =>
      'Gambar tidak tersedia secara lokal.';

  @override
  String uiVideoStillTransferringValue3F4049(String value) {
    return 'Video masih ditransfer ($value%).';
  }

  @override
  String get uiVoiceMessageBytesAreNotF8339B => 'Data pesan suara belum siap.';

  @override
  String get uiSendMode265A2D => 'Mode pengiriman';

  @override
  String get uiLANRelayA05D48 => 'Relai LAN';

  @override
  String get uiLobbyFDB6D9 => 'Lobi';

  @override
  String get uiDirectBC8152 => 'Langsung';

  @override
  String get uiIroh84642D => 'Iroh';

  @override
  String get uiIrohRelayB128EA => 'Relai Iroh';

  @override
  String get uiRelay9F537F => 'Relai';

  @override
  String get uiMatrix58947E => 'Matrix';

  @override
  String get uiPlainMatrixBA9DE1 => 'Matrix biasa';

  @override
  String get uiNostr4D3AD8 => 'Nostr';

  @override
  String get uiEmail84ADD5 => 'Email';

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
  String get uiViaContactCF1F8E => 'Lewat kontak';

  @override
  String get uiSendViaMatrix062A08 => 'Kirim lewat Matrix?';

  @override
  String get uiKeepWaiting9BE1AB => 'Tetap menunggu';

  @override
  String get uiSendViaMatrix638038 => 'Kirim lewat Matrix';

  @override
  String uiNotSentViaMatrixValue99F62C(String value) {
    return 'Tidak terkirim lewat Matrix: $value';
  }

  @override
  String get uiMessageRoutesFBF32C => 'Rute pesan';

  @override
  String get uiWhatTheColouredMarksOnA10C8E => 'Arti tanda warna pada pesan';

  @override
  String get uiOpenInDefaultPlayerE64C20 => 'Buka di pemutar bawaan';

  @override
  String get uiCancelReplyBD62D2 => 'Batalkan balasan';

  @override
  String get uiScheduledMessages98CEF4 => 'Pesan terjadwal';

  @override
  String get uiEditScheduledMessage62AF88 => 'Edit pesan terjadwal';

  @override
  String get uiCaption3428D9 => 'Keterangan';

  @override
  String get uiNoChatsToShareIntoB50F2F => 'Belum ada obrolan tujuan berbagi.';

  @override
  String get uiLetDevicesOnThisNetwork42E2F0 =>
      'Izinkan perangkat jaringan ini mengakses PC ini';

  @override
  String get uiAllow3AD0E3 => 'Izinkan';

  @override
  String get uiKeepSignedIn611A13 => 'Tetap masuk';

  @override
  String get uiSignOutHereA6F129 => 'Keluar di perangkat ini';

  @override
  String get uiMatrixPassword34E218 => 'Kata sandi Matrix';

  @override
  String get uiPassword8BE3C9 => 'Kata sandi';

  @override
  String get uiYourServerAsksForIt1594FA =>
      'Server meminta ini untuk membuat kunci tanda tangan.';

  @override
  String get uiRecoveryIsAlreadySetUp371F7F => 'Pemulihan sudah disiapkan';

  @override
  String get uiOK9CE3BD => 'Oke';

  @override
  String get uiSaveYourRecoveryKey7851B3 => 'Simpan kunci pemulihan Anda';

  @override
  String get uiKeepThisKeySomewhereSafe0C0DFE =>
      'Simpan kunci ini di tempat aman. Anda memerlukannya untuk membaca riwayat Matrix terenkripsi pada perangkat baru. Kunci hanya ditampilkan sekali.';

  @override
  String get uiISavedIt3E2255 => 'Sudah saya simpan';

  @override
  String get uiEnterRecoveryKey4521B6 => 'Masukkan kunci pemulihan';

  @override
  String get uiEsTFromAnotherMatrixAppFCA0C9 =>
      'EsT… (dari aplikasi Matrix lain atau aplikasi ini)';

  @override
  String get uiSignOutDC1649 => 'Keluar';

  @override
  String get uiSetUpRecoveryFD3804 => 'Siapkan pemulihan';

  @override
  String get uiVerifyWithAnotherSession9ED031 => 'Verifikasi dengan sesi lain';

  @override
  String get uiShowJoinsLeavesAndProfile9FA764 =>
      'Tampilkan masuk, keluar, dan perubahan profil';

  @override
  String get uiInMatrixRoomsCollapsedIntoD20CAB =>
      'Dalam ruang Matrix, diringkas satu baris';

  @override
  String get uiMatrixUser70A560 => 'Pengguna Matrix';

  @override
  String get uiForExampleNameMatrixOrg63C60A => 'Misalnya @name:matrix.org';

  @override
  String get uiHomeserverOptional70DF85 => 'Homeserver (opsional)';

  @override
  String get uiFoundFromTheUserId69A3AB =>
      'Ditemukan dari ID pengguna jika kosong';

  @override
  String get uiSignInToMatrix652C8F => 'Masuk ke Matrix';

  @override
  String get uiSignInWithBrowserC995DF => 'Masuk dengan peramban';

  @override
  String get uiFinishSigningInInYour9F41A4 =>
      'Selesaikan masuk melalui peramban.';

  @override
  String get uiCopyLink2F84EE => 'Salin tautan';

  @override
  String get uiThisDeviceFA5A6D => 'Perangkat ini';

  @override
  String uiOutOfTouchSinceValueA037FD(String value) {
    return 'Tidak terhubung sejak $value: tidak ada sinkronisasi sampai Anda mengonfirmasi perangkat masih milik Anda.';
  }

  @override
  String uiLinkedValueDCADF7(String value) {
    return 'Ditautkan $value';
  }

  @override
  String get uiYourContactsWillStopAccepting5B0F03 =>
      'Kontak akan berhenti menerima apa pun dari perangkat itu. Perangkat tidak dapat dipulihkan; tautkan lagi sebagai perangkat baru.';

  @override
  String get uiStillMine38C8AE => 'Masih milik saya';

  @override
  String get uiRemoveDeviceA9C39D => 'Hapus perangkat';

  @override
  String get uiLinkADeviceE71635 => 'Tautkan perangkat';

  @override
  String get uiLinkThisDeviceToMy888A1A => 'Tautkan perangkat ini ke akun saya';

  @override
  String get uiCheckThatBothDevicesShow031E51 =>
      'Pastikan kedua perangkat menampilkan kode ini:';

  @override
  String get uiTheCodesMatch32C407 => 'Kode cocok';

  @override
  String get uiLinkedTheNewDeviceNow9900E5 =>
      'Tertaut. Perangkat baru kini memiliki akun dan kontak Anda; kontak akan melihatnya sebagai Anda.';

  @override
  String get uiConfirmTheCodeOnThe17BB1F =>
      'Konfirmasikan kode di perangkat baru juga.';

  @override
  String get uiWaitingForTheNewDevice75283F =>
      'Menunggu perangkat baru menjawab. Jika kode tidak muncul, pastikan perangkat baru masih menampilkan kodenya dan keduanya berada di jaringan sama atau daring.';

  @override
  String get uiOnTheNewDeviceOpen29AF5E =>
      'Di perangkat baru, buka Pengaturan → Perangkat → Tautkan perangkat ini ke akun saya, lalu pindai kodenya.';

  @override
  String get uiScanCode4596C2 => 'Pindai kode';

  @override
  String get uiOrPasteTheCodeE72792 => 'Atau tempel kode';

  @override
  String get uiLinkThisDeviceBF5E5C => 'Tautkan perangkat ini';

  @override
  String get uiThisDeviceIsNowLinked7EA826 =>
      'Perangkat ini kini tertaut ke akun Anda.';

  @override
  String get uiWaitingForTheOtherDeviceB39C3F => 'Menunggu perangkat lain…';

  @override
  String get uiOnTheDeviceYouAlready92C421 =>
      'Di perangkat yang sudah dipakai, buka Pengaturan → Perangkat → Tautkan perangkat, lalu pindai kode ini. Keduanya harus di jaringan sama atau daring.';

  @override
  String get uiDeltaChat8BDA67 => 'Delta Chat';

  @override
  String get uiBitchatA99B50 => 'bitchat';

  @override
  String get uiWithAFilterOfTheir4FD18E =>
      'Dengan filter tersendiri. Jika nonaktif, buka hanya dari pengaturan jaringannya.';

  @override
  String get uiYourDeltaChatInviteEE073F => 'Undangan Delta Chat Anda';

  @override
  String get uiShowTheQRCodeTo0769AD =>
      'Tampilkan kode QR kepada pengguna Delta Chat atau kirim tautan. Siapa pun yang memilikinya dapat memulai obrolan terverifikasi dengan Anda.';

  @override
  String get uiShowQRCode2DF2DD => 'Tampilkan kode QR';

  @override
  String get uiDeltaChatChats8EBCBC => 'Obrolan Delta Chat';

  @override
  String get uiGroup171A06 => 'Grup';

  @override
  String get uiJoinWithAnInviteC76024 => 'Gabung dengan undangan';

  @override
  String get uiJoinE0D731 => 'Gabung';

  @override
  String get uiNewDeltaChatGroup7D5142 => 'Grup Delta Chat baru';

  @override
  String get uiGroupNameEBB7E1 => 'Nama grup';

  @override
  String get uiMembers1CB449 => 'Anggota';

  @override
  String get uiGroupInviteD64669 => 'Undangan grup';

  @override
  String get uiYouAreNotInThisCF5BD5 => 'Anda tidak berada di grup ini';

  @override
  String get uiStartGroupCallC2A083 => 'Mulai panggilan grup';

  @override
  String get uiJoinGroupCallC9ECF8 => 'Gabung panggilan grup';

  @override
  String get uiPushToTalk032E78 => 'Tekan untuk bicara';

  @override
  String get uiCarryMessagesOverAReticulum1CE915 =>
      'Kirim pesan melalui jaringan Reticulum, misalnya radio LoRa (RNode) tanpa internet, lewat node yang menjalankan rnsd dengan antarmuka server TCP. Conest menyimpan identitas Reticulum sendiri; kontak mengetahuinya otomatis.';

  @override
  String get uiNodeAddressRnsdCD61E2 => 'Alamat node (rnsd)';

  @override
  String get uiUSBDeviceB47FF0 => 'Perangkat USB';

  @override
  String get uiRNodeAddress691283 => 'Alamat RNode';

  @override
  String get uiBluetoothAddress0E2BED => 'Alamat Bluetooth';

  @override
  String get uiTCPPortDE05BE => 'Port TCP';

  @override
  String get uiEU233558 => 'UE 869.525';

  @override
  String get uiUS5ED166 => 'AS 914.875';

  @override
  String get uiUseConestAsAMatrix6A44C5 =>
      'Gunakan Conest hanya sebagai klien Matrix?';

  @override
  String get uiYourConestChatsAreHiddenCFD853 =>
      'Obrolan Conest disembunyikan dan koneksinya dihentikan di perangkat ini sampai Anda beralih kembali. Tidak ada yang dihapus. Kontak tidak dapat menjangkau Anda lewat Conest sementara itu; aplikasi mereka terus mencoba dan mengirim saat Anda kembali.';

  @override
  String get uiSwitch3E44C9 => 'Beralih';

  @override
  String get uiSealAnimatedRings29BE2D => 'Segel (cincin animasi)';

  @override
  String get uiSigilRuneA0B8A7 => 'Sigil (rune)';

  @override
  String get uiBlockiePixelHashA265BA => 'Blockie (hash piksel)';

  @override
  String get uiMonogramInitials8C6019 => 'Monogram (inisial)';

  @override
  String get uiNewMatrixChatC065C8 => 'Obrolan Matrix baru';

  @override
  String get uiNameMatrixOrgD0BB06 => '@name:matrix.org';

  @override
  String get uiStartChat18BB58 => 'Mulai obrolan';

  @override
  String get uiCopyText06A76C => 'Salin teks';

  @override
  String uiVerifyValue1B6B79(String value) {
    return 'Verifikasi $value';
  }

  @override
  String get uiAttachAFileAE85E4 => 'Lampirkan berkas';

  @override
  String get uiMessageDeleted3271A7 => 'Pesan dihapus';

  @override
  String get uiUnableToDecryptFDF88B => 'Tidak dapat mendekripsi';

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
  String get uiDeclineB59CF9 => 'Tolak';

  @override
  String get uiCarryMessagesAsEncryptedEmail0D19EA =>
      'Kirim pesan sebagai email terenkripsi saat rute lain gagal, seperti Delta Chat. Server email melihat kedua alamat dan waktu, bukan isi. Kontak mendapat alamatnya otomatis.';

  @override
  String get uiUseMyOwnEmailAccountE78C1D => 'Gunakan akun email sendiri';

  @override
  String get uiNostrRelaysBD8BAD => 'Relai Nostr';

  @override
  String get uiCarryMessagesThroughPublicNostr729B94 =>
      'Kirim pesan lewat relai Nostr publik saat rute lain gagal. Relai melihat seseorang menulis kepada Anda dan kapan, bukan siapa atau isinya. Memakai kunci terpisah; kontak mengetahuinya otomatis.';

  @override
  String get uiRelaysYouReadFromOne020C0A =>
      'Relai untuk membaca (satu per baris, maks. 4)';

  @override
  String get uiSaveRelays91CBA8 => 'Simpan relai';

  @override
  String get uiDefaultRelays5C909F => 'Relai bawaan';

  @override
  String get uiNewChat009BF6 => 'Obrolan baru';

  @override
  String get uiNodeAddress896F20 => 'Alamat node';

  @override
  String get uiDeleteChatDB9121 => 'Hapus obrolan';

  @override
  String get uiTurnOnAppMessagesTo7DCA13 =>
      'Aktifkan pesan aplikasi untuk menulis';

  @override
  String get uiBitchatNearbyD0C416 => 'bitchat sekitar';

  @override
  String get uiMeshChat7BF668 => 'Obrolan mesh';

  @override
  String get uiHiddenTurnOnReachableBy0103C9 =>
      'Tersembunyi: aktifkan \"Dapat dihubungi pengguna bitchat\"';

  @override
  String get uiTheyDonTMatch27EF0C => 'Tidak cocok';

  @override
  String get uiTheyMatch6FB8EB => 'Cocok';

  @override
  String get uiNameBitchatUsersSee1CE7E3 =>
      'Nama yang dilihat pengguna bitchat';

  @override
  String get uiANameYouChooseStays17E677 =>
      'Nama pilihan Anda tetap sama saat identitas berubah, jadi orang di sekitar tahu itu masih Anda. Kosongkan untuk nama \"anon\" baru pada setiap identitas.';

  @override
  String get uiBluetoothMeshC8B7F1 => 'Mesh Bluetooth';

  @override
  String get uiReachContactsNearbyWithoutAny9E9649 =>
      'Hubungi kontak sekitar tanpa jaringan: pesan melompat antarpiranti lewat Bluetooth, melalui pengguna Conest maupun bitchat, dan perangkat ini meneruskan pesan orang lain. Perangkat ini tidak terlihat di bitchat. Pesannya tampak seperti pesan pribadi bitchat lainnya, dengan ID yang berubah tiap jam.';

  @override
  String get uiReachableByBitchatUsers568021 =>
      'Dapat dihubungi pengguna bitchat';

  @override
  String get uiShareInternetWithBitchatUsers572F90 =>
      'Bagikan internet ke pengguna bitchat';

  @override
  String get uiChangeNameE46692 => 'Ubah nama';

  @override
  String get uiNewIdentityA119CF => 'Identitas baru';

  @override
  String get uiBitchatChatsC74EC3 => 'Obrolan bitchat';

  @override
  String get uiTheMatrixClientIsNot01A5B4 =>
      'Klien Matrix tidak tersedia di perangkat ini, jadi Conest tidak dapat berjalan dalam mode khusus Matrix.';

  @override
  String get uiUseConest12EEF3 => 'Gunakan Conest';

  @override
  String get uiSearchRoomsCCE4F9 => 'Cari ruang';

  @override
  String get uiReachContactsThroughTorOnion8B8A98 =>
      'Hubungi kontak melalui layanan onion Tor: kedua pihak maupun jaringan tidak mengetahui lokasi pihak lain. Lebih lambat dari rute lain; tambahkan jembatan saat Tor diblokir.';

  @override
  String get uiBridgesOptionalOnePerLine110291 =>
      'Jembatan (opsional, satu per baris)';

  @override
  String get uiEEFEBFE80B7A =>
      '192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413';

  @override
  String get uiObfsEEFEAD0EDF =>
      'obfs4 192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413 cert=… iat-mode=0';

  @override
  String get uiLinesFromBridgesTorprojectOrgF08389 =>
      'Baris dari bridges.torproject.org diawali jenis: obfs4, webtunnel, snowflake, atau meek_lite (atau jembatan biasa: alamat dan sidik jari).';

  @override
  String get uiPlainBridgesOnlyAddressAnd7F0B60 =>
      'Build ini hanya mendukung jembatan biasa (alamat dan sidik jari).';

  @override
  String get uiUseTheseBridgesC1FA11 => 'Gunakan jembatan ini';

  @override
  String get uiNostrPrivateMessagesDF74A3 => 'Pesan pribadi Nostr';

  @override
  String get uiChatWithAnyoneOnNostrA867BC =>
      'Mengobrol dengan siapa pun di Nostr (0xchat, Amethyst, Damus, dan aplikasi NIP-17 lain), berdua atau grup kecil. Akun Nostr tersendiri, tidak ditautkan ke kontak Conest. Terenkripsi ujung ke ujung, tanpa kerahasiaan maju.';

  @override
  String get uiYourNostrAddress5CF7C6 => 'Alamat Nostr Anda';

  @override
  String get uiCopyWithYourRelaysD49669 => 'Salin (beserta relai Anda)';

  @override
  String get uiNostrChats3D786C => 'Obrolan Nostr';

  @override
  String get uiNewNostrChat68199C => 'Obrolan Nostr baru';

  @override
  String get uiNpubSeveralForAGroupE6ED77 => 'npub1… (beberapa untuk grup)';

  @override
  String get uiCarryShortMessagesOverAFA94B6 =>
      'Kirim pesan singkat lewat mesh LoRa MeshCore melalui radio pendamping, tanpa internet. Conest menambahkan kontak ke radio agar pesan mereka diterima.';

  @override
  String get uiMessagesWithMeshCoreAppUsersDE77BA =>
      'Pesan dengan pengguna aplikasi MeshCore';

  @override
  String get uiReadAndWriteTheMeshCore98E60E =>
      'Baca dan tulis pesan aplikasi MeshCore melalui radio ini: dengan kontaknya dan di kanal sebagai grup. Perlindungannya hanya sesuai yang diberikan MeshCore.';

  @override
  String get uiMeshCoreChats82C29C => 'Obrolan MeshCore';

  @override
  String get uiSendWithItsDetailsF287FB => 'Kirim beserta detailnya?';

  @override
  String get uiSendAnyway911263 => 'Tetap kirim';

  @override
  String get uiSaveTheErrorHistory0B3413 => 'Simpan riwayat galat';

  @override
  String uiSavedTheErrorHistoryTo5271C5(String value) {
    return 'Riwayat galat disimpan ke $value.';
  }

  @override
  String uiSavingTheErrorHistoryFailed72A33A(String value) {
    return 'Gagal menyimpan riwayat galat: $value';
  }

  @override
  String get uiSaveToAFile5BB648 => 'Simpan ke berkas';

  @override
  String get uiClear719EA3 => 'Hapus';

  @override
  String get uiFilterD7DECF => 'Filter';

  @override
  String get uiErrorsOnlyHideTheDebugECA1DD =>
      'Hanya galat (sembunyikan log debug)';

  @override
  String uiValueH171B92(String value) {
    return '$value jam';
  }

  @override
  String uiValueMin439C52(String value) {
    return '$value mnt';
  }

  @override
  String uiTheirClockIsAboutValueF406F1(String value) {
    return 'Jam mereka berbeda sekitar $value $value; waktu di sini mengikuti perangkat ini.';
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
  String get uiSent27E770 => 'terkirim';

  @override
  String get uiWaitingOnTheRelayED66FF => 'menunggu di relai';

  @override
  String get uiReachedTheirDevice0FE289 => 'tiba di perangkatnya';

  @override
  String get uiDeliveredF81891 => 'tersampaikan';

  @override
  String get uiReceived38428A => 'diterima';

  @override
  String get uiCarryShortMessagesOverADD8570 =>
      'Kirim pesan singkat lewat mesh LoRa Meshtastic tanpa internet melalui radio Meshtastic. Kontak memerlukan Conest dan radio di mesh yang sama.';

  @override
  String get uiFindDevices98771A => 'Cari perangkat';

  @override
  String get uiRadioAddressD288E6 => 'Alamat radio';

  @override
  String get uiMessagesWithMeshtasticAppUsers812B3A =>
      'Pesan dengan pengguna aplikasi Meshtastic';

  @override
  String get uiReadAndWriteTheMeshtastic995E5D =>
      'Baca dan tulis pesan aplikasi Meshtastic melalui radio ini: pesan langsung dan kanal sebagai grup. Perlindungannya hanya sesuai yang diberikan Meshtastic.';

  @override
  String get uiMeshtasticChats46BEF8 => 'Obrolan Meshtastic';

  @override
  String get uiClearSelection247FD6 => 'Hapus pilihan';

  @override
  String get uiBrowseFilesAF7C13 => 'Jelajahi berkas…';

  @override
  String get uiSelectMoreE38EF3 => 'Pilih lagi';

  @override
  String get uiAllowAllA16326 => 'Izinkan semua';

  @override
  String get uiCaptionDA5C59 => 'Keterangan…';

  @override
  String get uiOpenSettingsFD7108 => 'Buka pengaturan';

  @override
  String get uiDiscardChangesD3F0B4 => 'Buang perubahan?';

  @override
  String get uiYourEditsWillBeLostB34663 =>
      'Edit Anda akan hilang. Gambar asli tetap ada di galeri.';

  @override
  String get uiKeepEditingD4D9E3 => 'Lanjut mengedit';

  @override
  String get uiDiscard36FFF6 => 'Buang';

  @override
  String get uiRotateLeft6F72F3 => 'Putar ke kiri';

  @override
  String get uiRotateRightB75F23 => 'Putar ke kanan';

  @override
  String get uiApplyCropA43CCF => 'Terapkan pangkas';

  @override
  String get uiCropC5DB3D => 'Pangkas';

  @override
  String get uiVerifiedDownloadProgressBED7C2 =>
      'Progres unduhan terverifikasi';

  @override
  String get uiSharingWithGroup2AED71 => 'Berbagi dengan grup';

  @override
  String get uiOpenCF9B77 => 'Buka';

  @override
  String get uiStopSharing0E45AE => 'Berhenti berbagi';

  @override
  String get uiRemoveLocalCopy80FA01 => 'Hapus salinan lokal';

  @override
  String get uiScanInviteEFC78A => 'Pindai undangan';

  @override
  String uiValueValue176D15(String value, String value2) {
    return '$value:$value2';
  }

  @override
  String uiDefaultRelayValueBD3FD1(String value) {
    return 'relai bawaan $value';
  }

  @override
  String uiSamplesValueSlowOverMsValueAE2EBF(String value, String value2) {
    return 'samples=$value slowOver100ms=$value2 maxTotalMs=$value maxBuildMs=$value maxRasterMs=$value';
  }

  @override
  String get uiConversation2A20C7 => 'Percakapan';

  @override
  String uiSharedValueWithTheGroup163418(String value) {
    return '$value dibagikan ke grup sebagai lampiran biasa; sebagian anggota perlu memperbarui aplikasi untuk memutar suara.';
  }

  @override
  String uiSharedValueWithTheGroupAE4134(String value) {
    return '$value dibagikan ke grup.';
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
  String get uiNone3C6B18 => '(tidak ada)';

  @override
  String uiLANNodeValueOn5D539E(String value) {
    return 'Node LAN :$value aktif';
  }

  @override
  String get uiLANNodeUnavailable9CFA32 => 'Node LAN tidak tersedia';

  @override
  String uiLANValueA8EEF3(String value) {
    return 'LAN $value';
  }

  @override
  String uiRelayValueDownD6B267(String value) {
    return 'relai $value mati';
  }

  @override
  String uiRelayValueA6D70A(String value) {
    return 'relai $value';
  }

  @override
  String get uiNoInternetRelay55D2CE => 'tidak ada relai internet';

  @override
  String uiValueValue42DC94(String value, String value2) {
    return '$value=$value2';
  }

  @override
  String uiValueHasBeenOutOf039D48(String value) {
    return '$value sudah lama tidak terhubung: tidak ada sinkronisasi sampai Anda mengonfirmasinya di Pengaturan → Perangkat.';
  }

  @override
  String uiValueIsOneOfYourE4FD9C(String value) {
    return '$value kini perangkat Anda sendiri; obrolan lamanya tidak lagi ditampilkan.';
  }

  @override
  String uiYourDevicesDisagreeOnWhich2E7001(String value) {
    return 'Perangkat Anda tidak sepakat tentang perangkat dalam akun, dan gabungannya akan melebihi $value. Hapus satu di Pengaturan → Perangkat.';
  }

  @override
  String uiValueAddedADeviceValue710908(String value, String value2) {
    return '$value menambahkan perangkat: $value2.';
  }

  @override
  String uiUnknownValue9B520C(String value) {
    return '$value tidak dikenal';
  }

  @override
  String uiReadByAllValue43BA5A(String value) {
    return 'Dibaca semua ($value)';
  }

  @override
  String uiDeliveredToAllValue71E077(String value) {
    return 'Tersampaikan ke semua ($value)';
  }

  @override
  String uiAcceptedByValueOfValue826A0E(String value, String value2) {
    return 'Diterima $value dari $value2';
  }

  @override
  String uiWaitingForValueMemberS5A8BA6(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Menunggu $value anggota',
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
    return '$value dilewati: $value2 MB melebihi batas $value3 MB.';
  }

  @override
  String get uiRoute499952 => 'Rute';

  @override
  String get uiSafetyNumber5ED2D3 => 'Nomor keamanan';

  @override
  String get uiIrohEndpoint72F674 => 'Endpoint Iroh';

  @override
  String get uiDeviceA5A74A => 'Perangkat';

  @override
  String get uiLANLobbyC16DC8 => 'Lobi LAN';

  @override
  String uiMembersValue541E72(String value) {
    return 'Anggota · $value';
  }

  @override
  String get uiNodeOnlineFAC64A => 'Node · daring';

  @override
  String uiSafetyValueC542B8(String value) {
    return 'keamanan $value';
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
      other: '$value anggota',
    );
    return '$_temp0';
  }

  @override
  String get uiPairwise64A0EF => 'berpasangan';

  @override
  String get uiPasteMedia4831DE => 'Tempel media';

  @override
  String get uiRELAYA1C0CF => 'RELAI';

  @override
  String get uiSentAsAPlainMatrixAAE694 => 'Dikirim sebagai pesan Matrix biasa';

  @override
  String get uiOnlyOnThisDevice7D64C4 => 'Hanya di perangkat ini';

  @override
  String get uiConnectivityIsOffTurnOnE42D4A =>
      'Konektivitas mati. Aktifkan LAN atau Daring untuk bertukar undangan ini.';

  @override
  String get uiConnectivityIsOffTurnOnFA573F =>
      'Konektivitas mati. Aktifkan LAN atau Daring sebelum membagikan undangan.';

  @override
  String get uiReceiveBeam2CB58B => 'Terima Beam';

  @override
  String get uiSendEncryptedFile99D424 => 'Kirim berkas terenkripsi';

  @override
  String get uiSendPublicFileF81389 => 'Kirim berkas publik';

  @override
  String get uiBeamContactInvite2BAB4C => 'Undangan kontak Beam';

  @override
  String get uiDevicesDF485C => 'Perangkat';

  @override
  String get uiWARNC2FD77 => 'WARN';

  @override
  String get uiDOWN30E504 => 'DOWN';

  @override
  String get uiAVGRTTE96B26 => 'AVG RTT';

  @override
  String uiRoutingValueFC4557(String value) {
    return 'Perutean — $value';
  }

  @override
  String uiActiveValueC78B63(String value) {
    return 'Aktif ($value)';
  }

  @override
  String uiRecentValueB82237(String value) {
    return 'Terbaru ($value)';
  }

  @override
  String get uiDirect24A173 => 'langsung';

  @override
  String get uiRelayBD28B2 => 'relai';

  @override
  String get uiRoutingECF60A => 'merutekan';

  @override
  String uiInvitationValue6F0633(String value) {
    return 'Undangan: $value';
  }

  @override
  String get uiMeshChatNearbyA35A63 => 'Obrolan mesh (sekitar)';

  @override
  String get uiVerifiedWithAnInviteBD826F => 'Terverifikasi melalui undangan';

  @override
  String get uiHoldToTalkOrHold74FC22 => 'Tahan untuk bicara, atau tahan Spasi';

  @override
  String get uiEndToEndEncryptedMatrix9E4418 =>
      'Terenkripsi ujung ke ujung (Matrix)';

  @override
  String get uiVerifiedAED3B8 => 'Terverifikasi';

  @override
  String uiValueValue64684F(String value, String value2) {
    return '$value · $value2';
  }

  @override
  String get uiPrimaryChannel53B8E1 => 'Kanal utama';

  @override
  String uiChannelValue76ED1D(String value) {
    return 'Kanal $value';
  }

  @override
  String get uiPublicChannelA9795B => 'Kanal publik';

  @override
  String get uiDescriptionCB3291 => 'deskripsi';

  @override
  String uiTheirClockIsAboutValue7DB956(String value, String value2) {
    return 'Jam mereka berbeda sekitar $value $value2; waktu di sini mengikuti perangkat ini.';
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
  String get uiConestTransfer406028 => 'Transfer Conest';

  @override
  String uiValueConestTransfersF846F8(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value transfer Conest',
    );
    return '$_temp0';
  }

  @override
  String uiViaValueValue37232D(String value, String value2) {
    return 'lewat $value ($value2)';
  }

  @override
  String get uiBackThroughTheContactWhoD09BD0 =>
      'kembali melalui kontak yang meneruskan pesannya';

  @override
  String uiConestRelayValue4FB2DB(String value) {
    return 'Relai Conest $value';
  }

  @override
  String get uiConestIsAlreadyRunningEE8037 => 'Conest sudah berjalan';

  @override
  String get uiCloseTheExistingConestWindow83B30B =>
      'Tutup jendela Conest yang ada dahulu. Instans kedua dapat berebut port relai lokal dan brankas terenkripsi.';

  @override
  String get uiChooseWhereConestStoresData0CF613 =>
      'Pilih lokasi penyimpanan data Conest';

  @override
  String get uiGhostModeIsBestEffort694912 =>
      'Mode hantu mengupayakan privasi: riwayat peluncuran OS, log kerusakan, metadata jaringan, riwayat shell, berkas terbaru, dan cache platform di luar kendali aplikasi.';

  @override
  String get uiDefaultOnThisDevice10343F => 'Bawaan di perangkat ini';

  @override
  String get uiUseTheNormalAppDataF44F79 =>
      'Gunakan folder data aplikasi normal dan penyimpanan kunci perangkat saat buka kunci otomatis dipilih.';

  @override
  String get uiGhostPortableBesideTheApp31A40D =>
      'Hantu/portabel di samping aplikasi';

  @override
  String get uiStoreConestControlledFilesIn7DA307 =>
      'Simpan berkas yang dikelola Conest di folder conest_data di samping aplikasi.';

  @override
  String get uiVaultUnlock602BF6 => 'Buka kunci brankas';

  @override
  String get uiKeyFileAutoUnlock66AC4A => 'Buka otomatis dengan berkas kunci';

  @override
  String get uiKeepsTheKeyBesideTheB045D9 =>
      'Kunci disimpan di samping brankas. Siapa pun yang memiliki folder dapat membukanya.';

  @override
  String get uiAutoUnlockWithThisDeviceE7F781 =>
      'Buka otomatis dengan perangkat ini';

  @override
  String get uiStoresTheVaultKeyInC7B1CD =>
      'Kunci brankas disimpan di penyimpanan aman platform.';

  @override
  String get uiPassphraseUnlock13B14C => 'Buka dengan frasa sandi';

  @override
  String get uiAskForAPassphraseOn4BA25C =>
      'Minta frasa sandi setiap peluncuran. Frasa sandi yang terlupa tidak dapat dipulihkan.';

  @override
  String get uiUnlockConest033EB6 => 'Buka kunci Conest';

  @override
  String get uiEnterThePassphraseForThis891200 =>
      'Masukkan frasa sandi brankas ini.';

  @override
  String get uiNoUpdateIsAvailableRightA5EB48 =>
      'Belum ada pembaruan saat ini.';

  @override
  String uiValueIsAvailableOnTheD338C4(String value, String value2) {
    return '$value tersedia di kanal $value2.';
  }

  @override
  String uiCurrentBuildValue2FD415(String value) {
    return 'Build saat ini: $value';
  }

  @override
  String get uiWhatSNew4D8DC5 => 'Yang baru';

  @override
  String get uiSERVERLESSSECUREMESSENGER1E1891 =>
      '◢ MESSENGER AMAN TANPA SERVER';

  @override
  String uiYourMatrixSessionValueWants580E45(String value) {
    return 'Sesi Matrix Anda $value ingin memverifikasi sesi ini. Terima hanya jika Anda yang memulainya.';
  }

  @override
  String uiValueWantsToVerifyYou61FD9D(String value) {
    return '$value ingin memverifikasi Anda dengan membandingkan emoji. Periksa alamat lengkap karena ada yang mirip. Terima hanya jika dapat membandingkan langsung atau melalui panggilan; verifikasi menandai kuncinya tepercaya.';
  }

  @override
  String uiCouldNotVerifyValue3AE1C4(String value) {
    return 'Tidak dapat memverifikasi: $value';
  }

  @override
  String get uiSendWithoutResumableCopy0475F4 =>
      'Kirim tanpa salinan yang bisa dilanjutkan?';

  @override
  String uiValueCouldNotBeCopied06F61A(
    String value,
    String value2,
    String value3,
  ) {
    return '$value tidak dapat disalin ke penyimpanan transfer privat.\n\n$value2\n\nAplikasi dapat membaca berkas asli langsung, tetapi transfer tidak dapat dilanjutkan setelah mulai ulang jika berkas dipindahkan atau izinnya berakhir.$value3';
  }

  @override
  String get uiUnmute7044C3 => 'Aktifkan suara';

  @override
  String get uiMute0F0973 => 'Bisukan';

  @override
  String get uiSpeakerOn93982E => 'Pengeras suara aktif';

  @override
  String get uiSpeakerOff97823A => 'Pengeras suara nonaktif';

  @override
  String get uiCancelCallCE6C16 => 'Batalkan panggilan';

  @override
  String uiValueValueReturnToCall49F82C(String value, String value2) {
    return '$value$value2 · Kembali ke panggilan';
  }

  @override
  String get uiContactDetailsD4EC65 => 'Detail kontak';

  @override
  String uiValueActiveMemberValue6700F2(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value anggota aktif',
    );
    return '$_temp0';
  }

  @override
  String get uiOwner89FF31 => 'Pemilik';

  @override
  String uiEditValue75BE00(String value) {
    return 'Edit $value';
  }

  @override
  String uiCouldNotSaveChatSettings2372B2(String value) {
    return 'Tidak dapat menyimpan pengaturan obrolan: $value';
  }

  @override
  String get uiAddAContactToStart165431 =>
      'Tambahkan kontak untuk mulai mengobrol';

  @override
  String get uiNoContactsFound816015 => 'Kontak tidak ditemukan';

  @override
  String uiOpenValue8DF02B(String value) {
    return 'Buka #$value';
  }

  @override
  String get uiNoMessagesYetC04921 => 'Belum ada pesan';

  @override
  String get uiNoActivityYetPairA7F5366 =>
      'Belum ada aktivitas; pasangkan kontak untuk memulai log.';

  @override
  String get uiSENT5AD0CD => 'TERKIRIM';

  @override
  String get uiRECVBFC296 => 'DITERIMA';

  @override
  String uiDeviceValue11AEA9(String value) {
    return 'perangkat $value';
  }

  @override
  String get uiFreeForAllLocalChat5485CC =>
      'Obrolan lokal terbuka • tidak tepercaya';

  @override
  String get uiGroupsAE9629 => 'Grup';

  @override
  String get uiAddTrustedContactsBeforeCreating1084CC =>
      'Tambahkan kontak tepercaya sebelum membuat grup.';

  @override
  String get uiNoGroupsYet5009C6 => 'Belum ada grup.';

  @override
  String uiValueMemberSE75249(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value anggota',
    );
    return '$_temp0';
  }

  @override
  String get uiContactsB0DD61 => 'Kontak';

  @override
  String get uiAppliesToFutureAdmissionsHistory78E3A0 =>
      'Berlaku untuk anggota yang bergabung nanti. Riwayat yang sudah diterima tidak dapat ditarik.';

  @override
  String uiValueAllRetainedHistory5E25F4(String value) {
    return '${value}Semua riwayat tersimpan';
  }

  @override
  String uiValueSinceAdmissionB2617B(String value) {
    return '${value}Sejak bergabung';
  }

  @override
  String uiDeleteValueF0396B(String value) {
    return 'Hapus \"$value\"';
  }

  @override
  String uiDeleteValueForEveryone12E724(String value) {
    return 'Hapus \"$value\" untuk semua?';
  }

  @override
  String uiValueMemberSOwnerValueE42E13(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value anggota • pemilik $value2',
    );
    return '$_temp0';
  }

  @override
  String get uiGROUPTRUSTFANOUTMintPaired5DDF6E =>
      '// GROUP TRUST FANOUT · mint = paired';

  @override
  String get uiAddTrustedContact126717 => 'Tambahkan kontak tepercaya';

  @override
  String get uiNoAvailableChats1FAA40 => 'Tidak ada obrolan tersedia';

  @override
  String get uiForwardedMessageQueuedC82DA4 => 'Pesan terusan masuk antrean';

  @override
  String uiCouldNotForwardValue80193D(String value) {
    return 'Tidak dapat meneruskan: $value';
  }

  @override
  String get uiForwardedAttachmentQueued57C88B =>
      'Lampiran terusan masuk antrean';

  @override
  String uiCouldNotForwardAttachmentValue5165FD(String value) {
    return 'Tidak dapat meneruskan lampiran: $value';
  }

  @override
  String get uiChatDetails15DAEC => 'Detail obrolan';

  @override
  String get uiConnectionDetailsAB30A5 => 'Detail koneksi';

  @override
  String uiValueValue270519(String value, String value2) {
    return '$value / $value2';
  }

  @override
  String uiVoiceMessageValue2F0300(String value) {
    return 'Pesan suara · $value';
  }

  @override
  String uiPlaybackFailedValue1C0E1A(String value) {
    return 'Gagal memutar: $value';
  }

  @override
  String get uiPreparingMicrophone0BBF4A => 'Menyiapkan mikrofon…';

  @override
  String get uiPreparingPreview312E7B => 'Menyiapkan pratinjau…';

  @override
  String uiVoiceMessagePreviewValue8235CB(String value) {
    return 'Pratinjau pesan suara · $value';
  }

  @override
  String uiRecordingValueValue111FF1(String value, String value2) {
    return 'Merekam$value · $value2';
  }

  @override
  String get uiSendingCF7655 => 'Mengirim…';

  @override
  String uiValue72F816(String value) {
    return '$value×';
  }

  @override
  String get uiSingleChoice68E3E0 => 'Satu pilihan';

  @override
  String get uiMultipleChoiceB88936 => 'Beberapa pilihan';

  @override
  String uiThisRemovesTheMessageFor2247A2(String value) {
    return 'Ini menghapus pesan untuk anggota grup saat sinkronisasi.$value';
  }

  @override
  String get uiCouldNotLocateThisMessage220E83 =>
      'Pesan ini tidak ditemukan di obrolan saat ini';

  @override
  String uiDeleteValueMessageValueForABA7AC(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Hapus $value pesan untuk grup?',
    );
    return '$_temp0';
  }

  @override
  String uiValueValue29C8B9(String value, String value2) {
    return '$value $value2';
  }

  @override
  String get uiNewC2A6B0 => 'baru';

  @override
  String get uiEditedA22FCA => 'diedit';

  @override
  String get uiCopyCachePathC23134 => 'Salin jalur cache';

  @override
  String get uiStopKeepingOfflineAABFC7 => 'Berhenti simpan luring';

  @override
  String get uiKeepOffline123286 => 'Simpan luring';

  @override
  String get uiForwardFileC4B5CB => 'Teruskan berkas';

  @override
  String get uiLoadingHistory02CB12 => 'Memuat riwayat…';

  @override
  String get uiLoadOlderMessages07471F => 'Muat pesan sebelumnya';

  @override
  String get uiShareFileNow96E2A2 => 'Bagikan berkas sekarang';

  @override
  String get uiScheduleFile690A92 => 'Jadwalkan berkas';

  @override
  String get uiDropToShareThisFile0B73E8 =>
      'Jatuhkan untuk membagikan berkas ke grup';

  @override
  String get uiClosed88D86B => 'Ditutup';

  @override
  String get uiVisibleVotes460E7A => 'Suara terlihat';

  @override
  String uiValueVoteSWereNot02CC9A(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value suara tidak tercakup dalam catatan penutupan pembuat.',
    );
    return '$_temp0';
  }

  @override
  String get uiVotingIsUnavailableWithThis9B92E7 =>
      'Pemungutan suara tidak tersedia pada versi Conest ini.';

  @override
  String get uiThisRemovesTheMessageHere61D27C =>
      'Ini menghapus pesan di sini dan meminta kontak menghapus salinannya jika terjangkau.';

  @override
  String get uiThisRemovesTheMessageFrom6A47E2 =>
      'Ini menghapus pesan dari perangkat ini.';

  @override
  String get uiSendViaMatrix3868FE => 'Kirim lewat Matrix…';

  @override
  String get uiNotesFilesAndForwardsOnlyB0145F =>
      'Catatan, berkas, dan terusan, hanya di perangkat ini';

  @override
  String uiValueSafetyValue82C755(String value, String value2) {
    return '$value • keamanan $value2';
  }

  @override
  String uiDropFilesToSendMax106011(String value) {
    return 'Jatuhkan berkas untuk mengirim (maks. $value)';
  }

  @override
  String get uiFreeForAllLocalChatBC90D2 =>
      'Obrolan lokal terbuka. Pesan ditandatangani per sesi, tetapi peserta bukan kontak tepercaya.';

  @override
  String get uiNoLANLobbyMessagesYetBCDC4B =>
      'Belum ada pesan lobi LAN. Rekan Conest sekitar menerima pesan selama berada di LAN ini.';

  @override
  String uiValueUntrusted519A32(String value) {
    return '$value • tidak tepercaya';
  }

  @override
  String uiRemoveValueF4FE4B(String value) {
    return 'Hapus $value?';
  }

  @override
  String get uiAvailablePaths6EE503 => 'Jalur tersedia';

  @override
  String get uiRunACheckToMeasure5D76A5 =>
      'Jalankan pemeriksaan untuk mengukur latensi, ketersediaan, dan kebaruan keterjangkauan. Jalur diurutkan dari langsung/LAN terbaik, lalu relai cadangan.';

  @override
  String get uiNoRouteHintsAreAdvertisedB25540 =>
      'Tidak ada petunjuk rute yang diumumkan untuk kontak ini.';

  @override
  String get uiEitherInputIsEnoughOn020B90 =>
      'Salah satu masukan sudah cukup. Pindai atau tempel undangan QR untuk langsung memercayainya, atau masukkan frasa kode saat ini untuk menemukan pengirim lewat LAN sekitar atau relai yang dikonfigurasi. Jika pertukaran otomatis gagal, aplikasi menyarankan meminta pihak lain menambahkan Anda atau membatalkan.';

  @override
  String get uiInvitePreview6433A0 => 'Pratinjau undangan';

  @override
  String uiValueValueValue98AECE(String value, String value2, String value3) {
    return '$value$value2 • $value3';
  }

  @override
  String get uiShareInviteDBCC1E => 'Bagikan undangan';

  @override
  String get uiThisInviteWorksOnlyOnB106B0 =>
      'Undangan ini hanya bekerja di jaringan yang sama: tidak ada rute internet aktif. Aktifkan relai Iroh, relai Conest, atau pembawa (Nostr, email) di Pengaturan → Konektivitas agar kontak dapat menambahkan Anda dari mana saja.';

  @override
  String get uiThisInviteAlsoListsYourEF3A4F =>
      'Undangan ini juga berisi rute jaringan terblokir sehingga terlalu besar untuk satu kode QR. Tampilkan sebagai Beam, QR animasi yang dibaca kamera lain dalam beberapa detik.';

  @override
  String get uiQRRenderingIsDeferredOn8A6997 =>
      'Perenderan QR ditunda di Windows.';

  @override
  String get uiUseTheCodephraseBelowOrB6A588 =>
      'Gunakan frasa kode di bawah atau render QR setelah halaman terbuka.';

  @override
  String get uiScanningTheCompactQRIs9459D9 =>
      'Memindai QR ringkas saja sudah cukup. Jika kamera masih kesulitan, buka layar penuh atau gunakan frasa kode saat ini saja.';

  @override
  String uiQRPayloadValueCharactersBABEDF(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Isi QR: $value karakter',
    );
    return '$_temp0';
  }

  @override
  String uiAlsoListsYourAddressesOnC5D815(String value) {
    return 'Juga memuat alamat Anda di: $value.';
  }

  @override
  String uiPinnedValue834309(String value) {
    return 'Disematkan · $value';
  }

  @override
  String get uiNoVerifiedCiContactsAre3FD190 =>
      'Belum ada kontak ci6 terverifikasi.';

  @override
  String get uiCloseUpTransferE6BA46 => 'Transfer jarak dekat';

  @override
  String get uiALoopingLTFountainStream840218 =>
      'Aliran fountain LT berulang tahan bingkai QR hilang, duplikat, dan tidak berurutan. Hash berkas akhir diperiksa sebelum Anda menerimanya.';

  @override
  String get uiPUBLICVisibleToAnyoneNearbyA775C2 =>
      'PUBLIK · terlihat oleh siapa pun di sekitar';

  @override
  String get uiCONTACTENCRYPTED879896 => 'TERENKRIPSI UNTUK KONTAK';

  @override
  String get uiSIGNEDCONTACTINVITE752317 => 'UNDANGAN KONTAK BERTANDA TANGAN';

  @override
  String uiFrameValueValueSourceBlocks9C37CB(
    String value,
    int value2,
    String value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value2,
      locale: localeName,
      other: 'Bingkai $value · $value2 blok sumber · $value3',
    );
    return '$_temp0';
  }

  @override
  String get uiPointThisCameraAtThe2EA3F7 =>
      'Arahkan kamera ini ke QR Beam animasi. Hanya bingkai cb1 yang telah didekode keluar dari pemindai native.';

  @override
  String get uiNativeDesktopCameraCaptureIs4619C8 =>
      'Pengambilan kamera native desktop tidak tersedia. Tempel bingkai cb1 di bawah; decoder protokol dan verifikasinya sama.';

  @override
  String uiValueValueBlocksValueFrames66F819(
    String value,
    String value2,
    String value3,
    String value4,
  ) {
    return '$value/$value2 blok · $value3 bingkai · $value4 tidak valid';
  }

  @override
  String get uiSignedContactInviteA7CC8B => 'Undangan kontak bertanda tangan';

  @override
  String get uiPUBLICUNTRUSTEDTheSignatureProves96FA7F =>
      'PUBLIK / TIDAK TEPERCAYA. Tanda tangan membuktikan semua bingkai berasal dari satu kunci, bukan siapa pemiliknya.';

  @override
  String get uiEncryptedAndAuthenticatedAsA68B7E4 =>
      'Terenkripsi dan diautentikasi sebagai kontak Conest yang disematkan.';

  @override
  String get uiSignatureValidCompareTheFingerprintA8A1FE =>
      'Tanda tangan valid. Bandingkan sidik jari secara langsung.';

  @override
  String get uiAcceptAndSavePublicFile852517 =>
      'Terima dan simpan berkas publik';

  @override
  String get uiSaveFileBEDC84 => 'Simpan berkas';

  @override
  String get uiFullscreenCompactInviteQRCF6B8B =>
      'QR undangan ringkas layar penuh';

  @override
  String uiValueCharactersIncreaseScreenBrightnessA5AF7D(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value karakter. Naikkan kecerahan layar jika pemindaian sulit.',
    );
    return '$_temp0';
  }

  @override
  String get uiPersonalPreferencesBD0D61 => 'Pribadi / Preferensi';

  @override
  String get uiNetworkRelay4F9A27 => 'Jaringan / Relai';

  @override
  String get uiDanger58D175 => 'Bahaya';

  @override
  String get uiAllowsOneToOneIroh45EEF1 =>
      'Mengizinkan panggilan Iroh satu lawan satu di perangkat ini. Nonaktifkan untuk berhenti melakukan dan menerima panggilan.';

  @override
  String get uiPrivacyOfFilesYouSend4E4A5B => 'Privasi berkas yang Anda kirim';

  @override
  String get uiLowA12494 => 'Rendah';

  @override
  String get uiMediumD40496 => 'Sedang';

  @override
  String get uiHighB1A595 => 'Tinggi';

  @override
  String get uiTransportPolicy088D79 => 'Kebijakan transport';

  @override
  String get uiPerContactRoutingIsIntersected88E292 =>
      'Perutean per kontak dibatasi opsi ini. Menonaktifkan salah satunya membatasi lalu lintas; mematikan keduanya membuat aplikasi diam.';

  @override
  String get uiConnectivityIsFullyOffTheB12483 =>
      'Konektivitas sepenuhnya mati; aplikasi tidak mengirim atau menerima.';

  @override
  String uiValueCandidateRouteSAre175673(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Saat ini tersedia $value rute kandidat.',
    );
    return '$_temp0';
  }

  @override
  String get uiConfiguredRelays3CA0DE => 'Relai dikonfigurasi';

  @override
  String get uiNoRelaysAddedYetF791E7 => 'Belum ada relai ditambahkan.';

  @override
  String uiCurrentBuildValueValue9A675D(String value, String value2) {
    return 'Build saat ini: $value • $value2';
  }

  @override
  String uiCommitValue2E080C(String value) {
    return 'komit $value';
  }

  @override
  String uiAvailableValue4B15F7(String value) {
    return 'Tersedia: $value';
  }

  @override
  String get uiChecking494D0F => 'Memeriksa…';

  @override
  String get uiCheckForUpdates8604FF => 'Periksa pembaruan';

  @override
  String uiTrustNewIdentityForValue8B0612(String value) {
    return 'Percayai identitas baru untuk $value?';
  }

  @override
  String uiTheRelayIsNowSigningFF71FD(String value) {
    return 'Relai kini menandatangani dengan kunci publik Ed25519 berbeda ($value). Lanjutkan hanya jika operator mengonfirmasi pergantian kunci; jika tidak, ini bisa merupakan serangan perantara.';
  }

  @override
  String get uiRelayIdentityChanged097638 => 'Identitas relai berubah';

  @override
  String get uiAConfiguredRelayIsSigning60EED0 =>
      'Relai yang dikonfigurasi memakai kunci baru. Verifikasi dengan operator sebelum memercayainya.';

  @override
  String uiValueValue66746D(String value, String value2) {
    return '$value → $value2';
  }

  @override
  String get uiNoPendingContactRequests697615 =>
      'Tidak ada permintaan kontak tertunda';

  @override
  String uiCouldNotReviewRequestValue82B3D5(String value) {
    return 'Tidak dapat meninjau permintaan: $value';
  }

  @override
  String uiAddValueF034EE(String value) {
    return 'Tambahkan $value?';
  }

  @override
  String uiCouldNotAddContactValue7F6C38(String value) {
    return 'Tidak dapat menambahkan kontak: $value';
  }

  @override
  String uiCouldNotRejectRequestValue2EFD58(String value) {
    return 'Tidak dapat menolak permintaan: $value';
  }

  @override
  String get uiContactRequestRejected447EE8 => 'Permintaan kontak ditolak.';

  @override
  String uiContactRequestFromValue50B6AC(String value) {
    return 'Permintaan kontak dari $value';
  }

  @override
  String uiUnverifiedValueC1937C(String value) {
    return 'Belum diverifikasi · $value';
  }

  @override
  String uiContactRequestFailedValue28DD81(String value) {
    return 'Permintaan kontak gagal: $value';
  }

  @override
  String get uiRequestAgain7B0434 => 'Minta lagi';

  @override
  String uiTrustValueAsAFresh7BF87F(String value, String value2) {
    return 'Percayai $value sebagai kontak baru? Verifikasi nomor keamanan lewat saluran lain dahulu; menerima akan mengarsipkan entri \"$value2\" sebelumnya sebagai hanya baca.';
  }

  @override
  String uiTrustThisAsAReinstallCBA4CC(String value) {
    return 'Percayai ini sebagai instalasi ulang \"$value\"? Kontak lama diarsipkan (riwayat hanya baca), dan kontak baru menggantikannya. Tidak dapat dibatalkan.';
  }

  @override
  String uiConfirmFailedValueBDE200(String value) {
    return 'Konfirmasi gagal: $value';
  }

  @override
  String uiRejectFailedValue5F5917(String value) {
    return 'Penolakan gagal: $value';
  }

  @override
  String uiThisContactMayBeAD1405D(String value) {
    return 'Kontak ini mungkin hasil setel ulang \"$value\". Verifikasi nomor keamanannya lewat saluran lain sebelum bertukar pesan.';
  }

  @override
  String uiImportedRelaysFromValue37C175(String value) {
    return 'Relai diimpor dari $value.';
  }

  @override
  String uiImportFailedValueBAFB4A(String value) {
    return 'Impor gagal: $value';
  }

  @override
  String uiThisWillRemoveValueRelay330EEB(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Ini menghapus $value rute relai yang diimpor dari $value2.',
    );
    return '$_temp0';
  }

  @override
  String uiRemoveFailedValue58F348(String value) {
    return 'Gagal menghapus: $value';
  }

  @override
  String get uiImportedRelayListsB0BD8B => 'Daftar relai impor';

  @override
  String get uiNoImportedLists6CBC34 => 'Tidak ada daftar impor.';

  @override
  String uiValueValueValueRouteS40FB98(
    String value,
    String value2,
    int value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value3,
      locale: localeName,
      other: '$value · $value2 · $value3 rute',
    );
    return '$_temp0';
  }

  @override
  String get uiLeaveBlankToImportUnsigned0D354E =>
      'Kosongkan untuk impor tanpa tanda tangan (tidak tepercaya; pemeriksaan awal tetap menentukan penggunaan). Berikan kunci operator untuk impor tepercaya secara kriptografis; tanda tangan diambil dari <URL>.ed25519.sig.';

  @override
  String uiValueF7CD86(String value) {
    return '// $value';
  }

  @override
  String get uiThemeA797E3 => 'Tema';

  @override
  String get uiAdaptiveIsUsingSystemDynamicBAA149 =>
      'Tema adaptif memakai warna dinamis sistem.';

  @override
  String get uiMintAndPinkRemainTheC846F3 =>
      'Hijau mint dan merah muda tetap menjadi aksen cadangan Conest.';

  @override
  String get uiDecoration2DB87A => 'Dekorasi';

  @override
  String get uiAmbientGridScanlinesCornerReticles45D5C5 =>
      'Kisi latar, garis pindai, penanda sudut, dan tampilan status. Dari bersih hingga suasana penuh.';

  @override
  String get uiShellBDC1FD => 'Tampilan';

  @override
  String get uiHomeLayoutE19685 => 'Tata letak beranda';

  @override
  String uiCONESTCiValue7964DC(String value) {
    return 'CONEST · ci5 · $value';
  }

  @override
  String get uiQRUnavailable12869A => 'QR tidak tersedia';

  @override
  String get uiUseTheCodephraseOrPayload187111 =>
      'Gunakan frasa kode atau isi undangan di bawah.';

  @override
  String uiTwoWayConfirmedValueE5A1A1(String value) {
    return 'dua arah terkonfirmasi$value';
  }

  @override
  String uiPathAcceptsSendWaitingFor10B4B0(String value) {
    return 'jalur menerima pengiriman; menunggu balasan rekan$value';
  }

  @override
  String get uiUnavailable1D5EE3 => 'tidak tersedia';

  @override
  String get uiUsable829A7C => 'dapat digunakan';

  @override
  String get uiOneWay5EF4D0 => 'satu arah';

  @override
  String get uiSkipC7E168 => 'lewati';

  @override
  String get uiShareYourInviteThenEither5FEF78 =>
      'Bagikan undangan Anda, lalu pindai QR atau masukkan frasa kode saat ini di perangkat lain untuk menambahkan kontak.';

  @override
  String get uiStartWithOneTrustedContact650B80 =>
      'Mulai dengan satu kontak tepercaya';

  @override
  String get uiThisReleasePairsThroughA883AA2 =>
      'Versi ini memasangkan dengan undangan QR saja atau frasa kode saja, mengutamakan LAN sekitar, lalu relai internet sebagai cadangan.';

  @override
  String get uiConnectivityIsOffEnableLAN39990E =>
      'Konektivitas mati. Aktifkan LAN atau Daring di Pengaturan.';

  @override
  String get uiAutomaticAC9041 => 'Otomatis';

  @override
  String get uiPreferred0A3E0D => 'Diutamakan';

  @override
  String get uiDisabledF4F447 => 'Nonaktif';

  @override
  String get uiAskFirst1AEB84 => 'Tanya dahulu';

  @override
  String get uiRetryFailed7B6CA4 => 'Ulangi yang gagal';

  @override
  String get uiCancelAlbumDB0A07 => 'Batalkan album';

  @override
  String get uiDeleteAlbum52E30F => 'Hapus album';

  @override
  String get menuForwardAlbum => 'Teruskan album';

  @override
  String get menuSelect => 'Pilih';

  @override
  String get menuSelectAlbum => 'Pilih album';

  @override
  String uiValueSelectedB1DFAF(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value dipilih',
    );
    return '$_temp0';
  }

  @override
  String uiThisWillCancelValueActiveB3425E(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other:
          'Ini membatalkan $value transfer aktif dan menghapus daftar transfer. Pesan obrolan dan berkas yang selesai diunduh tetap ada.',
    );
    return '$_temp0';
  }

  @override
  String get uiNoTransfersYetB8E5C1 => 'Belum ada transfer.';

  @override
  String get uiAttachmentMetadataUnavailableE2C31D =>
      'Metadata lampiran tidak tersedia';

  @override
  String uiValueMBPreparingDownload799D4A(String value) {
    return '$value MB · menyiapkan unduhan…';
  }

  @override
  String uiValueMBDirectRouteRequired6379F0(String value) {
    return '$value MB · perlu rute langsung';
  }

  @override
  String uiValueMBTapToDownload432280(String value) {
    return '$value MB · ketuk untuk mengunduh';
  }

  @override
  String get uiPreparingDownload8CB769 => 'Menyiapkan unduhan…';

  @override
  String uiTransferringValueValue10EEBE(String value, String value2) {
    return 'Mentransfer · $value% · $value2';
  }

  @override
  String uiTransferringValue9D7F13(String value) {
    return 'Mentransfer · $value';
  }

  @override
  String get uiVoiceMessage999DEB => 'Pesan suara';

  @override
  String get uiSendAsMedia061D87 => 'Kirim sebagai media';

  @override
  String get uiSendAsFileB50EAF => 'Kirim sebagai berkas';

  @override
  String get uiMEDIAB85FA2 => 'MEDIA';

  @override
  String get uiFILEB4915D => 'BERKAS';

  @override
  String get uiPausedByPeer63BD05 => 'Dijeda oleh rekan';

  @override
  String get uiCouldNotDecodeThisImage3EAA16 =>
      'Tidak dapat mendekode gambar ini.';

  @override
  String uiValueValueValueDAEE95(String value, String value2, String value3) {
    return '$value  ·  $value2/$value3';
  }

  @override
  String uiValueCannotBeReachedOver14E8C2(String value, String value2) {
    return '$value tidak dapat dijangkau lewat Conest saat ini. Kirim pesan ini ke $value2 sebagai pesan Matrix biasa?\n\nPesan masuk ke obrolan langsung Matrix, tanpa enkripsi Conest: homeserver dapat membacanya kecuali obrolan itu terenkripsi. Conest berhenti mencoba mengirimnya.';
  }

  @override
  String uiValueF69855(String value) {
    return '+$value';
  }

  @override
  String uiCouldNotPlayThisVideoF7D318(String value) {
    return 'Tidak dapat memutar video ini: $value';
  }

  @override
  String get uiYouLeft9F2CDB => 'Anda keluar';

  @override
  String uiReplyingToValue645786(String value) {
    return 'Membalas $value';
  }

  @override
  String get uiNoScheduledMessages1DDB60 => 'Tidak ada pesan terjadwal';

  @override
  String get uiScheduledAttachment08DB0E => 'Lampiran terjadwal';

  @override
  String uiValueValueValue209DD2(String value, String value2, String value3) {
    return '$value • $value2\n$value3';
  }

  @override
  String get uiSendNowDAE330 => 'Kirim sekarang';

  @override
  String get uiReschedule34B2DC => 'Jadwalkan ulang';

  @override
  String get uiShareTextTo7B5086 => 'Bagikan teks ke…';

  @override
  String uiShareValueTo6E3BDD(String value) {
    return 'Bagikan $value ke…';
  }

  @override
  String uiShareValueFilesToA46E17(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Bagikan $value berkas ke…',
    );
    return '$_temp0';
  }

  @override
  String get uiIfMessagesAndFilesFrom3DED27 =>
      'Jika pesan dan berkas dari ponsel di jaringan sama tidak tiba (tetapi pesan Anda sampai), Windows Firewall memblokirnya. Ini mengizinkan perangkat lain di jaringan mana pun mengakses Conest di PC ini; Windows meminta konfirmasi.';

  @override
  String get uiServerRefusedSignOut66337B => 'Server menolak keluar';

  @override
  String get uiServerNotReached62FED2 => 'Server tidak terjangkau';

  @override
  String uiThisServerDoesNotLet9EEC1F(String value) {
    return 'Server ini tidak mengizinkan Conest mengakhiri sesi ($value). Sesi mungkin dikelola di halaman akun server.\n\nTetap keluar di perangkat ini? Lalu hapus sesi Conest dari halaman akun atau aplikasi Matrix lain.';
  }

  @override
  String uiConestCouldNotSignThis3C1074(String value) {
    return 'Conest tidak dapat mengeluarkan perangkat ini dari server ($value).\n\nTetap keluar di perangkat ini? Sesi tetap berlaku di server sampai Anda menghapusnya dari aplikasi Matrix lain.';
  }

  @override
  String get uiEnabledDF174A => 'Aktif';

  @override
  String get uiYourEncryptedMatrixHistoryIsC16CD2 =>
      'Riwayat Matrix terenkripsi sudah dicadangkan. Gunakan \"Masukkan kunci pemulihan\" di perangkat baru.';

  @override
  String get uiThisAccountAlreadyHasA0CF3D8 =>
      'Akun ini sudah memiliki kunci pemulihan. Gunakan \"Masukkan kunci pemulihan\" atau \"Verifikasi dengan sesi lain\" untuk membuka riwayat terenkripsi di sini.';

  @override
  String uiMatrixValueED6C29(String value) {
    return 'Matrix: $value';
  }

  @override
  String uiValueValueB5F18A(String value, String value2) {
    return '$value$value2';
  }

  @override
  String get uiMatrixFallbackAA082C => 'Cadangan Matrix';

  @override
  String get uiMatrixAccountD69140 => 'Akun Matrix';

  @override
  String get uiAccountsThatSignInThrough64868A =>
      'Akun yang masuk melalui Google, GitHub, penyedia lain, atau matrix.org memakai peramban.';

  @override
  String uiThisAccountIsOnValueB78C80(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Akun ini ada di $value perangkat.',
    );
    return '$_temp0';
  }

  @override
  String get uiUseConestOnMoreThanD2AA6A =>
      'Gunakan Conest di beberapa perangkat: tautkan ponsel, tablet, atau komputer ke akun ini. Kontak melihat satu orang.';

  @override
  String get uiThisDeviceWasLinkedLess2E5122 =>
      'Perangkat ini ditautkan kurang dari sehari lalu, jadi belum dapat menambah atau menghapus perangkat.';

  @override
  String get uiPauseSyncingWithADevice89642E =>
      'Jeda sinkronisasi perangkat yang tidak terhubung selama';

  @override
  String uiValueDaysEE919A(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value hari',
    );
    return '$_temp0';
  }

  @override
  String get uiChatsFromOtherNetworks13CDCD => 'Obrolan dari jaringan lain';

  @override
  String uiShowValueChatsInTheBC0E41(String value) {
    return 'Tampilkan obrolan $value dalam daftar';
  }

  @override
  String get uiChatWithDeltaChatUsers3B8607 =>
      'Mengobrol dengan pengguna Delta Chat melalui akun email. Atur Email di atas dahulu.';

  @override
  String uiChatWithDeltaChatUsersABD3F5(String value) {
    return 'Mengobrol dengan pengguna Delta Chat sebagai $value, berdua atau grup. Terenkripsi ujung ke ujung (OpenPGP, tanpa kerahasiaan maju); server email melihat siapa menulis kepada siapa dan kapan.';
  }

  @override
  String get uiNoDeltaChatChatsYetF4C538 =>
      'Belum ada obrolan Delta Chat. Bagikan undangan atau gabung dengan undangan orang lain.';

  @override
  String uiRequestValueE6C033(String value) {
    return 'Permintaan: $value';
  }

  @override
  String get uiNobodyToAddYetStart0983BB =>
      'Belum ada yang dapat ditambahkan: mulai obrolan dahulu. Undangan grup dapat dibagikan setelah grup dibuat.';

  @override
  String get uiVerifiedEC734B => 'terverifikasi';

  @override
  String uiAddValueF546E5(String value) {
    return 'Tambahkan $value';
  }

  @override
  String get uiChatDeleted73DC61 => 'Obrolan dihapus';

  @override
  String get uiLeaveGroup925789 => 'Keluar grup';

  @override
  String get uiWaitingForTheInviteTo1C712D =>
      'Menunggu undangan dijawab; mungkin perlu semenit.';

  @override
  String get uiEncryptedWithOpenPGPDeltaChat9C6326 =>
      'Dienkripsi dengan OpenPGP (Delta Chat), tanpa kerahasiaan maju. Server email melihat siapa menulis kepada siapa dan kapan.';

  @override
  String get uiARequestFromSomeoneYouAE0967 =>
      'Permintaan dari orang yang belum Anda ajak mengobrol. Membalas berarti menerima.';

  @override
  String get uiReadA7AFDD => 'dibaca';

  @override
  String get uiNotSentBE2B9D => 'tidak terkirim';

  @override
  String get uiCouldNotJoinTheCall252D45 =>
      'Tidak dapat bergabung. Periksa rute atau tinggalkan panggilan saat ini.';

  @override
  String uiCallInValue16F998(String value) {
    return 'Panggilan di $value';
  }

  @override
  String uiValueStartedACallIn278E96(String value, String value2) {
    return '$value memulai panggilan di $value2';
  }

  @override
  String get uiReturn24F096 => 'Kembali';

  @override
  String get uiCouldNotUpdateTheCall33517D =>
      'Tidak dapat memperbarui panggilan.';

  @override
  String get uiVoiceCallB8499D => 'Panggilan suara';

  @override
  String uiCallViaValue0A68E8(String value) {
    return 'Panggilan lewat $value';
  }

  @override
  String uiValueYouEFED9A(String value) {
    return '$value (Anda)';
  }

  @override
  String get uiTalkingC34D84 => 'Berbicara…';

  @override
  String get uiHoldToTalkSpace869505 => 'Tahan untuk bicara · Spasi';

  @override
  String uiVoiceCallValueBD3141(String value) {
    return 'Panggilan suara · $value';
  }

  @override
  String uiStartedByValueValueParticipants99F03D(String value, int value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value2,
      locale: localeName,
      other: 'Dimulai oleh $value · $value2 peserta',
    );
    return '$_temp0';
  }

  @override
  String get uiNodeRnsd0D8EEC => 'Node (rnsd)';

  @override
  String get uiRNodeOnUSBF00220 => 'RNode lewat USB';

  @override
  String get uiRNodeOnBluetooth13657D => 'RNode lewat Bluetooth';

  @override
  String get uiRNodeOnWiFiC18593 => 'RNode lewat Wi-Fi';

  @override
  String get uiScanForRadios2B185E => 'Pindai radio';

  @override
  String get uiUseTheSameFrequencyBandwidthFC1A9F =>
      'Gunakan frekuensi, lebar pita, dan faktor penyebaran yang sama dengan jaringan Reticulum yang diikuti radio.';

  @override
  String get uiAppMode2965FD => 'Mode aplikasi';

  @override
  String get uiBoth1F4698 => 'Keduanya';

  @override
  String uiCouldNotStartTheChatAE2F54(String value) {
    return 'Tidak dapat memulai obrolan: $value';
  }

  @override
  String uiMessagesAreEndToEndE786B5(String value) {
    return 'Pesan terenkripsi ujung ke ujung, tetapi homeserver Anda dan mereka melihat siapa mengobrol dengan siapa dan kapan. Verifikasi $value untuk memastikan identitasnya.';
  }

  @override
  String get uiThisChatIsNotEncrypted799D99 =>
      'Obrolan ini tidak terenkripsi: homeserver kedua pihak dapat membacanya.';

  @override
  String get uiLoading33CE41 => 'Memuat…';

  @override
  String get uiLoadEarlierMessages4AC08D => 'Muat pesan sebelumnya';

  @override
  String get uiEditing3B9BA1 => 'Mengedit';

  @override
  String uiReplyToValueValue666B4E(String value, String value2) {
    return 'Balas $value: $value2';
  }

  @override
  String get uiYouWereInvitedToThisE30D1E =>
      'Anda diundang ke obrolan Matrix ini.';

  @override
  String get uiEdited0E3C32 => 'diedit · ';

  @override
  String get uiUnableToDecryptThisMessage8A31CC =>
      'Belum dapat mendekripsi pesan ini';

  @override
  String get uiUnsupportedMessage9E48EB => 'Pesan tidak didukung';

  @override
  String uiImageUnavailableValueB024FC(String value) {
    return 'Gambar tidak tersedia: $value';
  }

  @override
  String uiDownloadFailedValueB18BB6(String value) {
    return 'Unduhan gagal: $value';
  }

  @override
  String get uiFile2C3CAF => 'Berkas';

  @override
  String uiValueKiBEC48AF(String value) {
    return '$value KiB';
  }

  @override
  String get uiCODEPHRASEE2C724 => 'FRASA KODE';

  @override
  String uiROTATESINValueS5745B8(String value) {
    return 'BERGANTI DALAM $value dtk';
  }

  @override
  String get uiROUTEINSPECTOR321AA4 => 'PEMERIKSA RUTE';

  @override
  String get uiLIVE67B40B => '● LANGSUNG';

  @override
  String uiValueChatsAD9A3B(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value obrolan',
    );
    return '$_temp0';
  }

  @override
  String uiValueValue167E51(String value, String value2) {
    return '$value ($value2)';
  }

  @override
  String get uiNotDeliveredTheirRadioCould75D581 =>
      'tidak tersampaikan (radio mereka tidak dapat membacanya)';

  @override
  String get uiSenderNotVerified2BB0FA => 'pengirim belum diverifikasi';

  @override
  String get uiYouAreHidden56DCC1 => 'Anda tersembunyi';

  @override
  String get uiYouReadTheMeshChatAEACC5 =>
      'Anda membaca obrolan mesh, tetapi pengguna bitchat tidak dapat melihat atau menulis kepada Anda. Aktifkan \"Dapat dihubungi pengguna bitchat\" di Pengaturan → Konektivitas untuk menulis.';

  @override
  String get uiEveryoneNearbyOverBluetooth7B8D63 =>
      'Semua orang sekitar lewat Bluetooth';

  @override
  String get uiNoBitchatUsersNearbyYetD30471 =>
      'Belum ada pengguna bitchat sekitar';

  @override
  String get uiPhonesInBluetoothRangeThatDCCC0D =>
      'Perangkat dalam jangkauan Bluetooth yang mengumumkan diri muncul di sini.';

  @override
  String get uiNearbyF1536C => 'Sekitar';

  @override
  String get uiEveryoneInBluetoothRangeReadsA7628A =>
      'Semua orang dalam jangkauan Bluetooth membaca obrolan ini dan dapat meneruskannya. Pesan bertanda tangan, tidak terenkripsi.';

  @override
  String get uiEncryptedBetweenTheTwoPhones3871C4 =>
      'Dienkripsi antara kedua perangkat (Noise bitchat), dengan kerahasiaan maju hanya saat keduanya berdekatan.';

  @override
  String get uiThisChatWasWithAn0507F9 =>
      'Obrolan ini memakai identitas bitchat lama Anda. Menulis sekarang memberi tahu mereka bahwa identitas baru milik orang yang sama.';

  @override
  String uiValueValue64C067(String value, String value2) {
    return '$value#$value2';
  }

  @override
  String get uiVerifyThisSessionB5065C => 'Verifikasi sesi ini';

  @override
  String get uiBluetoothMeshOn5A96FE => 'Mesh Bluetooth aktif';

  @override
  String get uiStartingBluetoothE6928A => 'Memulai Bluetooth';

  @override
  String get uiBluetoothUnavailableF4B751 => 'Bluetooth tidak tersedia';

  @override
  String uiBitchatUsersNearbySeeYou1B54FC(String value) {
    return 'Pengguna bitchat sekitar melihat Anda sebagai \"$value\" saat dalam jangkauan dan dapat mengirim pesan. Identitas yang mereka lihat diperbarui tiap minggu dan tidak terkait dengan identitas Conest Anda.';
  }

  @override
  String get uiOffBitchatUsersDoNot054F9A =>
      'Nonaktif: pengguna bitchat tidak melihat perangkat ini. Anda tetap bisa membaca obrolan mesh.';

  @override
  String uiPhonesNearbyWithoutInternetCan27CC7F(String value) {
    return 'Ponsel sekitar tanpa internet dapat memakai kanal lokasi bitchat lewat perangkat ini. Hanya pesan publik bertanda tangan tersebut yang lewat. Perangkat ini terhubung ke relai wilayah yang mereka gunakan$value: relai itu melihat alamat internet dan wilayah Anda sehingga dapat memperkirakan lokasi Anda.';
  }

  @override
  String get uiOffBitchatUsersNearbyWithout030CFB =>
      'Nonaktif: pengguna bitchat sekitar tanpa internet tidak dapat mengakses kanal lokasi lewat Anda.';

  @override
  String uiValueNearbyTheMeshChat31C0CA(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value di sekitar · obrolan mesh dan pribadi',
    );
    return '$_temp0';
  }

  @override
  String get uiSignInToYourMatrix8D0037 => 'Masuk ke akun Matrix Anda';

  @override
  String get uiNoRoomsFoundAD2C3E => 'Ruang tidak ditemukan';

  @override
  String get uiMatrixInvitation525106 => 'Undangan Matrix';

  @override
  String get uiEncryptedChat0D7563 => 'Obrolan terenkripsi';

  @override
  String get uiChat2CED57 => 'Obrolan';

  @override
  String get uiNoNostrChatsYet0A95D0 => 'Belum ada obrolan Nostr';

  @override
  String get uiEncryptedOnNostrNIPRelaysA51F70 =>
      'Dienkripsi di Nostr (NIP-17); relai tidak melihat siapa menulis atau kapan. Tanpa kerahasiaan maju.';

  @override
  String get uiTestingRoutes19C586 => 'Menguji rute…';

  @override
  String get uiTestRoutes52770A => 'Uji rute';

  @override
  String get uiCheckingWhetherTheirAppCan51E401 =>
      'Memeriksa dukungan uji rute aplikasi mereka…';

  @override
  String get uiTheirAppDidNotSay758036 =>
      'Aplikasi mereka tidak menyatakan dukungan uji rute. Jika memakai versi ini juga, mungkin sedang tidak terjangkau.';

  @override
  String get uiNoRouteTookTheTestF2F6CB => 'Tidak ada rute menerima pengujian.';

  @override
  String uiTestedValueRoutesThatAnswer70B842(String value) {
    return '$value diuji. Rute yang menjawab diutamakan untuk pesan.';
  }

  @override
  String get uiUSB09716C => 'USB';

  @override
  String get uiCopiedTheErrorHistoryCE02E2 => 'Riwayat galat disalin.';

  @override
  String get uiNothingRecordedA27006 => 'Belum ada catatan.';

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
    return 'Rute: $value';
  }

  @override
  String uiValueValue7B4608(String value, String value2) {
    return '$value · !$value2';
  }

  @override
  String get uiNetwork53EBC5 => 'Jaringan';

  @override
  String uiImageIsLargerThanTheEE56C5(String value) {
    return 'Gambar melebihi batas $value MB.';
  }

  @override
  String uiFileIsLargerThanTheAF488F(String value) {
    return 'Berkas melebihi batas $value MB.';
  }

  @override
  String uiSendValueBF4C3C(String value) {
    return 'Kirim $value';
  }

  @override
  String get uiRecent76EEC7 => 'Terbaru';

  @override
  String get uiConestSeesOnlyThePhotosEE1926 =>
      'Conest hanya melihat foto yang Anda pilih.';

  @override
  String get uiPhotosPermissionDeniedUseBrowseD672EE =>
      'Izin foto ditolak. Gunakan \"Jelajahi berkas…\" untuk mengirim berkas apa pun, atau berikan akses di pengaturan sistem.';

  @override
  String get uiNoPhotosOrVideosHereC729D1 =>
      'Tidak ada foto atau video di sini.';

  @override
  String get uiCouldNotDecodeTheImage69AC9D =>
      'Tidak dapat mendekode gambar untuk diputar.';

  @override
  String uiRotationFailedValue176CC6(String value) {
    return 'Gagal memutar: $value';
  }

  @override
  String uiValueOfValueVerified63B11D(String value, String value2) {
    return '$value dari $value2 terverifikasi';
  }

  @override
  String get uiPointTheCameraAtA9BAFAF =>
      'Arahkan kamera ke QR undangan Conest.';

  @override
  String get statusMatrixRoomsShowJoinsAndE8AC9E =>
      'Ruang Matrix menampilkan masuk dan keluar.';

  @override
  String get statusMatrixRoomsHideJoinsAndE00610 =>
      'Ruang Matrix menyembunyikan masuk dan keluar.';

  @override
  String statusAppMode95B48F(String value) {
    return 'Mode aplikasi: $value.';
  }

  @override
  String statusCalling7A8C67(String value) {
    return 'Memanggil $value…';
  }

  @override
  String get statusUpdatedHistoryVisibilityForFutureDA1A23 =>
      'Visibilitas riwayat untuk anggota grup mendatang diperbarui.';

  @override
  String statusVaultUnlockFailedAE7813(String value) {
    return 'Gagal membuka brankas: $value';
  }

  @override
  String get statusDirectOnlineTransportIsUnavailableB1EFAE =>
      'Transport daring langsung tidak tersedia; relai cadangan tetap aktif.';

  @override
  String get statusNostrCarrierSetUpE82998 => 'Pembawa Nostr disiapkan.';

  @override
  String get statusNostrCarrierRemovedCB968A => 'Pembawa Nostr dihapus.';

  @override
  String get statusNostrRelaysUpdatedARelay03F8F3 =>
      'Relai Nostr diperbarui: satu relai ditutup.';

  @override
  String get statusTorCarrierSetUp3D2304 => 'Pembawa Tor disiapkan.';

  @override
  String get statusTorCarrierRemovedAAC23E => 'Pembawa Tor dihapus.';

  @override
  String get statusBluetoothMeshOn11FD21 => 'Mesh Bluetooth aktif.';

  @override
  String get statusBluetoothMeshOff2CE954 => 'Mesh Bluetooth nonaktif.';

  @override
  String get statusNostrMessagesOn35ABF5 => 'Pesan Nostr aktif.';

  @override
  String get statusNostrMessagesOff16BCA7 => 'Pesan Nostr nonaktif.';

  @override
  String get statusDeltaChatOn1F38AA => 'Delta Chat aktif.';

  @override
  String get statusDeltaChatOff8BDBD4 => 'Delta Chat nonaktif.';

  @override
  String statusBitchatUsersNearbyCanNow5536CD(String value) {
    return 'Pengguna bitchat sekitar kini melihat Anda sebagai $value.';
  }

  @override
  String get statusBitchatUsersNoLongerSee68B46D =>
      'Pengguna bitchat tidak lagi melihat Anda.';

  @override
  String statusMeshcoreCarrierSetUpThroughE51369(String value) {
    return 'Pembawa MeshCore disiapkan lewat $value.';
  }

  @override
  String get statusMeshcoreCarrierRemoved38FC35 => 'Pembawa MeshCore dihapus.';

  @override
  String statusMeshtasticCarrierSetUpThroughAFA24A(String value) {
    return 'Pembawa Meshtastic disiapkan lewat $value.';
  }

  @override
  String get statusMeshtasticCarrierRemoved66387E =>
      'Pembawa Meshtastic dihapus.';

  @override
  String get statusMeshtasticAppMessagesOn2C1888 =>
      'Pesan aplikasi Meshtastic aktif.';

  @override
  String get statusMeshtasticAppMessagesOffAFB9E8 =>
      'Pesan aplikasi Meshtastic nonaktif.';

  @override
  String get statusMeshcoreAppMessagesOn2BF1E3 =>
      'Pesan aplikasi MeshCore aktif.';

  @override
  String get statusMeshcoreAppMessagesOffE59C90 =>
      'Pesan aplikasi MeshCore nonaktif.';

  @override
  String statusReticulumCarrierSetUpThrough7EB41E(String value) {
    return 'Pembawa Reticulum disiapkan lewat $value.';
  }

  @override
  String get statusReticulumCarrierRemoved301C05 =>
      'Pembawa Reticulum dihapus.';

  @override
  String statusEmailCarrierSetUpAs8427FD(String value) {
    return 'Pembawa email disiapkan sebagai $value.';
  }

  @override
  String get statusEmailCarrierRemoved036E51 => 'Pembawa email dihapus.';

  @override
  String statusImportedRelaySFromB1DB2D(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value relai diimpor dari $value2.',
    );
    return '$_temp0';
  }

  @override
  String statusRemovedImportedRelaySource3F4540(String value) {
    return 'Sumber relai impor $value dihapus.';
  }

  @override
  String get statusPairingCodeRotatedAndAdvertised722FB9 =>
      'Kode pemasangan diganti dan diumumkan.';

  @override
  String statusCheckedRouteSAvailableE9B9D6(
    int value,
    int value2,
    String value3,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value rute diperiksa; $value2 tersedia. $value3',
    );
    return '$_temp0';
  }

  @override
  String statusCheckedIrohPathSFor038B43(
    String value,
    String value2,
    String value3,
  ) {
    return 'Jalur Iroh untuk $value diperiksa; keterjangkauan $value2. $value3';
  }

  @override
  String statusNoPathsAreAdvertisedForA37EA3(String value) {
    return 'Tidak ada jalur diumumkan untuk $value.';
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
          '$value jalur untuk $value2 diperiksa; $value3 tersedia$value4. Keterjangkauan $value5. $value6',
    );
    return '$_temp0';
  }

  @override
  String get statusDisplayNameUpdated3BD31A => 'Nama tampilan diperbarui.';

  @override
  String get statusBioCleared543896 => 'Bio dihapus.';

  @override
  String get statusBioUpdated440110 => 'Bio diperbarui.';

  @override
  String get statusContactProfileUpdated47ECF6 => 'Profil kontak diperbarui.';

  @override
  String get statusRelayModeEnabledB9ACB8 => 'Mode relai aktif.';

  @override
  String get statusRelayModeDisabled723F4D => 'Mode relai nonaktif.';

  @override
  String get statusContactsCanNowContributeRelay147ECE =>
      'Kontak kini dapat menyediakan rute relai otomatis.';

  @override
  String get statusAutomaticContactRelayUsageDisabledE762A7 =>
      'Pemakaian relai kontak otomatis nonaktif.';

  @override
  String get statusNotificationsEnabledF70668 => 'Notifikasi aktif.';

  @override
  String get statusNotificationsDisabledForThisDeviceE10A46 =>
      'Notifikasi nonaktif di perangkat ini.';

  @override
  String get statusExperimentalVoiceCallsEnabledOn4081DE =>
      'Panggilan suara eksperimental aktif di perangkat ini.';

  @override
  String get statusExperimentalVoiceCallsDisabledOn19A5AE =>
      'Panggilan suara eksperimental nonaktif di perangkat ini.';

  @override
  String get statusAndroidBackgroundRuntimeEnabledIfAA5168 =>
      'Runtime latar Android aktif. Jika akses baterai/latar diblokir sistem, notifikasi mungkin terlambat atau tidak tiba.';

  @override
  String get statusAndroidBackgroundRuntimeDisabled5FC9A0 =>
      'Runtime latar Android nonaktif.';

  @override
  String get statusBackgroundVoiceCallAvailabilityEnabledA87223 =>
      'Panggilan suara latar aktif. Panggilan hanya tiba saat layanan Conest diizinkan berjalan.';

  @override
  String get statusBackgroundVoiceCallAvailabilityDisabledA71AD1 =>
      'Panggilan suara latar nonaktif.';

  @override
  String get statusFreeSpaceReserveEnabledD7CE0E =>
      'Cadangan ruang kosong 10% aktif.';

  @override
  String get statusFreeSpaceReserveDisabledD3E635 =>
      'Cadangan ruang kosong 10% nonaktif.';

  @override
  String statusRoutingPreferencesUpdatedFor05867B(String value) {
    return 'Preferensi rute untuk $value diperbarui.';
  }

  @override
  String statusLocalRelayPortUpdatedTo7F815D(String value) {
    return 'Port relai lokal diubah ke $value.';
  }

  @override
  String statusRelayAdded800692(String value) {
    return 'Relai $value ditambahkan.';
  }

  @override
  String statusRelayAddedFor087398(String value, String value2, String value3) {
    return 'Relai $value:$value2 ditambahkan untuk $value3.';
  }

  @override
  String statusRelayRemoved546A15(String value) {
    return 'Relai $value dihapus.';
  }

  @override
  String statusTrustedNewIdentityForRelay4CDBFE(String value) {
    return 'Identitas baru relai $value dipercaya.';
  }

  @override
  String get statusContactRemovedE31CE0 => 'Kontak dihapus.';

  @override
  String get statusContactRemovedLocallySendingA40D607 =>
      'Kontak dihapus lokal. Pemberitahuan penghapusan dikirim di latar.';

  @override
  String get statusDeviceCreatedShareAQr06E7B6 =>
      'Perangkat dibuat. Bagikan undangan QR atau frasa kode saat ini untuk menambahkan kontak.';

  @override
  String statusContactAcceptedSendingApprovalOverDAD10C(String value) {
    return 'Kontak $value diterima. Mengirim persetujuan lewat rute tersedia.';
  }

  @override
  String statusContactSavedWaitingForThe41F77D(String value) {
    return 'Kontak $value disimpan. Menunggu pihak lain menyetujui permintaan.';
  }

  @override
  String statusReconnectedWithBC62EC(String value) {
    return 'Terhubung kembali dengan $value.';
  }

  @override
  String statusAskingToReconnectE93389(String value) {
    return 'Meminta $value terhubung kembali.';
  }

  @override
  String statusConfirmedIdentityReplacementForC93359(String value) {
    return 'Penggantian identitas $value dikonfirmasi.';
  }

  @override
  String statusRejectedIdentityReplacementForDEC894(String value) {
    return 'Penggantian identitas $value ditolak.';
  }

  @override
  String get statusContactRequestCancelledQueuedItemsEC2567 =>
      'Permintaan kontak dibatalkan. Item antrean tetap diblokir.';

  @override
  String get statusSaved9D4AF6 => 'Disimpan.';

  @override
  String statusMessageSavedLocallyItWill0DBD03(String value) {
    return 'Pesan disimpan lokal. Akan dikirim setelah $value menerima permintaan kontak.';
  }

  @override
  String statusTryingLanFirstThenRelay1F5BEC(String value) {
    return 'Mencoba LAN dahulu, lalu relai untuk $value.';
  }

  @override
  String get statusMessageQueuedTheAppWillA89BCC =>
      'Pesan masuk antrean. Aplikasi mencoba lagi rute langsung dan relai saat memeriksa pesan.';

  @override
  String statusAttachmentIsWaitingForA3F032B(String value) {
    return 'Lampiran menunggu rute: $value';
  }

  @override
  String statusCouldNotPrepareForDownloadE8FB18(String value) {
    return 'Tidak dapat menyiapkan $value untuk diunduh.';
  }

  @override
  String statusCreatedGroupF5D335(String value) {
    return 'Grup $value dibuat.';
  }

  @override
  String statusUpdatedGroup2140B7(String value) {
    return 'Grup $value diperbarui.';
  }

  @override
  String statusRemovedAMemberFrom68CF04(String value) {
    return 'Anggota dihapus dari $value.';
  }

  @override
  String statusLeftGroup9E3412(String value) {
    return 'Keluar dari grup $value.';
  }

  @override
  String statusRemovedGroupFromYourList047F4B(String value) {
    return 'Grup $value dihapus dari daftar Anda.';
  }

  @override
  String statusTransferredOwnershipOfToA126A1(String value, String value2) {
    return 'Kepemilikan $value dialihkan ke $value2.';
  }

  @override
  String statusDeletedGroupForEveryoneDB26F8(String value) {
    return 'Grup $value dihapus untuk semua.';
  }

  @override
  String statusUpdatedIn642C0A(String value, String value2) {
    return '$value diperbarui di $value2.';
  }

  @override
  String statusSendingGroupMessageToD77236(String value) {
    return 'Mengirim pesan grup ke $value.';
  }

  @override
  String statusSentToAsAPlainAF2DE6(String value) {
    return 'Dikirim ke $value sebagai pesan Matrix biasa.';
  }

  @override
  String statusCanceledAndDeletedPendingMessageCDCA88(String value) {
    return 'Pesan tertunda ke $value dibatalkan dan dihapus.';
  }

  @override
  String get statusMessageDeletedLocallyCE90EE => 'Pesan dihapus lokal.';

  @override
  String statusMessageDeletedHereAndDeletion7C4E80(String value) {
    return 'Pesan dihapus di sini dan permintaan penghapusan dikirim ke $value.';
  }

  @override
  String get statusMessageDeletedHereRemoteDeletionB6AE62 =>
      'Pesan dihapus di sini. Penghapusan jarak jauh belum dapat dikirim.';

  @override
  String get statusMessageEditedLocally187334 => 'Pesan diedit lokal.';

  @override
  String statusMessageEditQueuedTo695B15(String value) {
    return 'Edit pesan masuk antrean ke $value.';
  }

  @override
  String get statusReactionUpdatedLocally97D795 => 'Reaksi diperbarui lokal.';

  @override
  String statusReactionQueuedToD43BED(String value) {
    return 'Reaksi masuk antrean ke $value.';
  }

  @override
  String get statusLanLobbyMessageSavedLocallyFDE86E =>
      'Pesan lobi LAN disimpan lokal; tidak ada peserta LAN sekitar yang terjangkau.';

  @override
  String statusLanLobbyMessageSentTo82F0B0(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'Pesan lobi LAN dikirim ke $value rute sekitar.',
    );
    return '$_temp0';
  }

  @override
  String statusGroupMembershipAckFrom43FCF1(String value, String value2) {
    return 'Konfirmasi keanggotaan grup $value dari $value2.';
  }

  @override
  String statusReceivedItemSVia58B082(int value, String value2) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value item diterima lewat $value2.',
    );
    return '$_temp0';
  }

  @override
  String statusRoutePollFailedA1FD0C(String value) {
    return 'Pemeriksaan rute gagal: $value';
  }

  @override
  String statusLanReceivingIsOffPort5F04CB(String value) {
    return 'Penerimaan LAN mati: port $value terpakai. Pilih port relai lokal lain di Pengaturan.';
  }

  @override
  String statusRediscoveredLanRouteFor587829(String value, String value2) {
    return 'Rute LAN $value ditemukan kembali untuk $value2.';
  }

  @override
  String statusLanDiscoveryUnavailable0E99AE(String value) {
    return 'Penemuan LAN tidak tersedia: $value';
  }

  @override
  String get statusUpdatedNearbyLanRoutesF8CAFC =>
      'Rute LAN sekitar diperbarui.';

  @override
  String statusRejectedMalformedAttachmentOfferFrom9FC96A(String value) {
    return 'Tawaran lampiran cacat dari $value ditolak.';
  }

  @override
  String get statusRejectedInvalidAttachmentMetadata849465 =>
      'Metadata lampiran tidak valid ditolak.';

  @override
  String statusDeclinedTheRequestQueuedMessagesABFFCB(String value) {
    return '$value menolak permintaan. Pesan dan berkas antrean tetap diblokir.';
  }

  @override
  String statusNewContactRequestFromCF70B9(String value) {
    return 'Permintaan kontak baru dari $value.';
  }

  @override
  String statusLeftF4FE32(String value, String value2) {
    return '$value keluar dari $value2.';
  }

  @override
  String statusRemovedYouTheConversationRemains3BB516(String value) {
    return '$value menghapus Anda. Obrolan tetap diarsipkan lokal.';
  }

  @override
  String statusUpdatedEditedMessageFrom1AB90D(String value) {
    return 'Pesan edit dari $value diperbarui.';
  }

  @override
  String statusDeletedMessageRemovedBy5A9E79(String value) {
    return 'Pesan yang dihapus oleh $value dibuang.';
  }

  @override
  String statusAppliedAReactionFrom41011B(String value) {
    return 'Reaksi dari $value diterapkan.';
  }

  @override
  String get statusAppliedDeferredDirectReactions1414C8 =>
      'Reaksi langsung tertunda diterapkan.';

  @override
  String statusEncryptedMessageStoredForVia029324(String value, String value2) {
    return 'Pesan terenkripsi untuk $value disimpan lewat $value2.';
  }

  @override
  String statusSentToViaWaitingForEA766D(String value, String value2) {
    return 'Dikirim ke $value lewat $value2; menunggu tanda terima.';
  }

  @override
  String statusDeliveryRetryPending93EAA3(String value) {
    return 'Percobaan ulang pengiriman tertunda: $value';
  }

  @override
  String statusGroupDeliveryRetryPending691CA4(String value) {
    return 'Percobaan ulang pengiriman grup tertunda: $value';
  }

  @override
  String statusRelayIdentityChangedVerifyWith6F3689(String value) {
    return 'Identitas relai $value berubah; verifikasi dengan operator.';
  }

  @override
  String statusRelayIdentityMismatchVerifyWith2D3B10(
    String value,
    String value2,
  ) {
    return 'Identitas relai $value:$value2 tidak cocok; verifikasi dengan operator.';
  }

  @override
  String get statusTheMatrixSignInExpired76ABA4 =>
      'Sesi Matrix berakhir. Masuk lagi untuk memakai Matrix.';

  @override
  String statusSignedInToMatrixAs5103D2(String value) {
    return 'Masuk ke Matrix sebagai $value.';
  }

  @override
  String get statusSignedOutOfMatrix1D1860 => 'Keluar dari Matrix.';

  @override
  String statusSOtherDevicesHaveNot07F30F(String value, String value2) {
    return 'Perangkat lain milik $value sudah lama tidak mendengar dari $value2: pesan perangkat itu mungkin bukan dari pemiliknya.';
  }

  @override
  String statusReceivedItemSInstantlyViaA7773B(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value item diterima langsung lewat relai lokal.',
    );
    return '$_temp0';
  }

  @override
  String statusReceivedItemSViaLocal71A104(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value item diterima lewat kotak masuk lokal.',
    );
    return '$_temp0';
  }

  @override
  String get statusNoNewProtocols =>
      'Tidak ada protokol relai baru terdeteksi.';

  @override
  String get statusRouteExchangeRequested => 'Pertukaran info rute diminta.';

  @override
  String get statusRouteExchangePending =>
      'Pertukaran info rute belum dapat dikirim.';

  @override
  String get statusKnownRoutes => 'rute dikenal';

  @override
  String get statusReachable => 'terjangkau';

  @override
  String get statusUnreachable => 'tidak terjangkau';

  @override
  String get statusUnknown => 'tidak diketahui';

  @override
  String get statusExpired => 'usang';

  @override
  String get connectionsTitle => 'Koneksi';

  @override
  String get connectionsDescription =>
      'Perangkat mana menjangkau yang lain, dua arah atau satu arah.';

  @override
  String get relayUdpHint => 'udp://host:port memaksa UDP';

  @override
  String get deltaFileActions => 'Tindakan berkas';

  @override
  String get deltaForward => 'Teruskan';

  @override
  String get deltaAttach => 'Lampirkan';

  @override
  String get deltaSendVoice => 'Kirim pesan suara';

  @override
  String get deltaDiscardVoice => 'Buang pesan suara';

  @override
  String get deltaRecordVoice => 'Rekam pesan suara';

  @override
  String get deltaReact => 'Reaksi';

  @override
  String get savedMessagesPreview => 'Catatan, berkas, dan terusan untuk Anda';

  @override
  String networkChatsTitle(String network) {
    return 'Obrolan $network';
  }

  @override
  String get networkEncryptedMatrixChat => 'Obrolan Matrix terenkripsi';

  @override
  String get networkMatrixChat => 'Obrolan Matrix';

  @override
  String get networkEveryoneBluetooth =>
      'Semua orang dalam jangkauan Bluetooth';

  @override
  String get inviteNoRoutes => 'tidak ada rute diumumkan';

  @override
  String get deliveryPending => 'Menunggu rute terjangkau';

  @override
  String get deliveryLocal => 'Terkirim lewat LAN; menunggu tanda terima';

  @override
  String get deliveryRelayed => 'Dalam antrean relai; menunggu tanda terima';

  @override
  String get deliveryDelivered => 'Tersampaikan';

  @override
  String get deliveryRead => 'Dibaca';

  @override
  String get reachabilityOnline => 'daring';

  @override
  String get reachabilityRecent => 'terlihat baru-baru ini';

  @override
  String get reachabilityKnown => 'dikenal';

  @override
  String get transferApproval => 'Menunggu persetujuan';

  @override
  String get transferPeer => 'Menunggu rekan';

  @override
  String get routeLanDirect => 'LAN langsung';

  @override
  String get routeInternetDirect => 'Internet langsung';

  @override
  String get routeIrohDirect => 'Iroh langsung';

  @override
  String get routeConestRelay => 'Relai Conest';

  @override
  String get routeOptical => 'Optik';

  @override
  String get routeViaContact => 'Lewat kontak';

  @override
  String get themeSystem => 'Sistem';

  @override
  String get themeLight => 'Signature · Terang';

  @override
  String get themeDark => 'Signature · Gelap';

  @override
  String get themeBlack => 'Signature · Hitam (OLED)';

  @override
  String get themeAdaptive => 'Adaptif (wallpaper)';

  @override
  String get layoutSignalCards => 'Kartu Sinyal';

  @override
  String get layoutStationFeed => 'Linimasa Stasiun';

  @override
  String get layoutClassic => 'Baris klasik';

  @override
  String get layoutSignalDescription => 'Rekan sebagai kartu tautan dasbor.';

  @override
  String get layoutFeedDescription => 'Log paket/aktivitas menurut waktu.';

  @override
  String get layoutClassicDescription => 'Daftar ringkas satu baris.';

  @override
  String get shellSignatureDescription => 'Bilah samping dasbor asli Conest.';

  @override
  String get shellGarrisonDescription =>
      'Seperti Discord: bilah sel dan percakapan.';

  @override
  String get shellCourierDescription =>
      'Seperti Telegram: satu daftar percakapan bersih.';

  @override
  String get connectionsBothWays => 'dua arah';

  @override
  String get connectionsInbound => 'hanya dari mereka';

  @override
  String get connectionsFailing => 'gagal';

  @override
  String get connectionsUnknown => 'tidak ada kabar baru';

  @override
  String voiceConnected(String time) {
    return 'Terhubung · $time';
  }

  @override
  String messageClockAhead(String amount) {
    return 'Jam mereka sekitar $amount lebih cepat; waktu di sini mengikuti perangkat ini.';
  }

  @override
  String messageClockBehind(String amount) {
    return 'Jam mereka sekitar $amount lebih lambat; waktu di sini mengikuti perangkat ini.';
  }

  @override
  String messageNotRecentlyConfirmed(String date) {
    return 'Belum dikonfirmasi baru-baru ini: perangkat lainnya terakhir menganggap perangkat ini miliknya pada $date.';
  }

  @override
  String get routeLanDirectDescription =>
      'Langsung ke perangkat lain di jaringan lokal Anda.';

  @override
  String get routeLanRelayDescription =>
      'Melalui simpul relai perangkat lain di jaringan lokal Anda.';

  @override
  String get routeLanLobbyDescription =>
      'Kotak pesan bersama lobi LAN; siapa pun di jaringan dapat membacanya.';

  @override
  String get routeInternetDirectDescription =>
      'Langsung ke simpul relai perangkat lain melalui internet.';

  @override
  String get routeIrohDirectDescription =>
      'Antarperangkat melalui Iroh, terenkripsi ujung ke ujung.';

  @override
  String get routeIrohRelayDescription =>
      'Melalui server relai Iroh, yang hanya melihat lalu lintas terenkripsi.';

  @override
  String get routeConestRelayDescription =>
      'Disimpan dan diteruskan oleh server relai Conest, yang hanya melihat amplop terenkripsi.';

  @override
  String get routeMatrixDescription =>
      'Dibawa oleh Matrix, tetap terenkripsi ujung ke ujung oleh Conest; homeserver melihat siapa berkomunikasi dan kapan.';

  @override
  String get routePlainMatrixDescription =>
      'Dikirim sebagai pesan Matrix biasa; homeserver dapat membacanya jika ruang tidak dienkripsi.';

  @override
  String get routeNostrDescription =>
      'Dibawa oleh relai Nostr, tetap terenkripsi ujung ke ujung oleh Conest; relai melihat penerima dan waktu, tanpa pengirim.';

  @override
  String get routeEmailDescription =>
      'Dibawa oleh email, tetap terenkripsi ujung ke ujung oleh Conest; server email melihat kedua alamat dan waktu.';

  @override
  String get routeReticulumDescription =>
      'Melalui Reticulum, lewat radio atau jaringan Reticulum, terenkripsi ujung ke ujung.';

  @override
  String get routeMeshtasticDescription =>
      'Melalui mesh radio Meshtastic, terenkripsi ujung ke ujung.';

  @override
  String get routeMeshCoreDescription =>
      'Melalui mesh radio MeshCore, terenkripsi ujung ke ujung.';

  @override
  String get routeBluetoothDescription =>
      'Melalui mesh Bluetooth lewat perangkat sekitar, terenkripsi ujung ke ujung.';

  @override
  String get routeTorDescription =>
      'Antarlayanan onion melalui Tor; perantara tidak melihat siapa berkomunikasi dengan siapa.';

  @override
  String get routeContactDescription =>
      'Diteruskan oleh kontak yang dapat menjangkau perangkat lain; tetap terenkripsi ujung ke ujung, kontak hanya melihat penerima dan waktu.';

  @override
  String routeTestRoundTrip(String route, String ms) {
    return '$route: $ms md pulang pergi';
  }

  @override
  String routeTestStored(String route) {
    return '$route: ditinggalkan di relai (dijawab setelah diambil)';
  }

  @override
  String routeTestNoAnswer(String route) {
    return '$route: tidak ada jawaban';
  }

  @override
  String transferTimeLeft(String time) {
    return 'tersisa $time';
  }

  @override
  String transferQueuePosition(String position) {
    return 'antrean #$position';
  }

  @override
  String get transferTapRetry => 'ketuk untuk mencoba lagi';

  @override
  String get transferRerouting => 'Mengalihkan rute';

  @override
  String get routeShortLobby => 'Lobi';

  @override
  String get routeShortDirect => 'Langsung';

  @override
  String get routeShortRelay => 'Relai';

  @override
  String get routeShortContact => 'Lewat kontak';

  @override
  String chatDraftPreview(String text) {
    return 'Draf: $text';
  }

  @override
  String get routeAutomaticFallback => 'alih otomatis ✓';

  @override
  String get releaseNightly => 'nightly';

  @override
  String get releaseStable => 'stabil';

  @override
  String get callActive => 'Panggilan aktif';

  @override
  String get callGeneric => 'Panggilan';

  @override
  String get contactNotPinned => 'Belum disematkan';

  @override
  String get groupUnknownMember => 'Seorang anggota';

  @override
  String get relaySourceSigned => 'bertanda tangan';

  @override
  String get relaySourceUnsigned => 'tanpa tanda tangan';

  @override
  String get beamFingerprintUnavailable => 'sidik jari tidak tersedia';

  @override
  String get fileOriginalMetadataWarning =>
      'Rincian lokasi, kamera, penulis, dan tanggal akan ikut dikirim.';

  @override
  String get routeMarkSent => 'terkirim';

  @override
  String get routeMarkStored => 'menunggu di relai';

  @override
  String get routeMarkReached => 'tiba di perangkatnya';

  @override
  String get routeMarkDelivered => 'tersampaikan';

  @override
  String get routeMarkReceived => 'diterima';

  @override
  String get relayHostOrLinkLabel => 'Host, URL, atau tautan relai';

  @override
  String get relayLinkHint => 'conest-relay://… dari pemasangnya';

  @override
  String get brokenPartNotice => 'Ada yang salah di sini.';

  @override
  String get crashNoticeBody =>
      'Conest tertutup tiba-tiba terakhir kali. Rinciannya tetap di perangkat ini; Anda dapat menyalinnya ke laporan bug.';

  @override
  String get crashNoticeDetails => 'Rincian';

  @override
  String get crashNoticeDismiss => 'Tutup pesan';

  @override
  String get crashReportTitle => 'Apa yang terjadi';

  @override
  String get crashReportCopy => 'Salin';

  @override
  String get crashReportClose => 'Tutup';

  @override
  String get connectionsNetworks =>
      'Jaringan yang pernah dipakai perangkat ini';

  @override
  String get connectionsNetworkNow => 'Sedang dipakai';

  @override
  String connectionsNetworkLastSeen(String date) {
    return 'Terakhir terlihat $date';
  }

  @override
  String get connectionsRouteWorks => 'berfungsi';

  @override
  String get connectionsRouteBlocked => 'diblokir di jaringan ini';

  @override
  String get connectionsRouteFailing => 'gagal';

  @override
  String connectionsAsOf(String when) {
    return 'per $when';
  }

  @override
  String get bluetoothMeshNeedsAttention =>
      'Jaringan Bluetooth perlu diperiksa';

  @override
  String forwardSelectedTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Teruskan $count pesan',
    );
    return '$_temp0';
  }

  @override
  String forwardedSummary(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pesan diteruskan',
    );
    return '$_temp0';
  }

  @override
  String forwardSkipped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count file belum ada di perangkat ini dan dilewati',
    );
    return '$_temp0';
  }

  @override
  String get torBlockedHint =>
      'Tor tampaknya diblokir di jaringan ini. Bridge bisa menembusnya, tetapi bridge publik juga sering diblokir: dapatkan bridge Anda sendiri (di bawah).';

  @override
  String get torGetBridgesTitle => 'Cara mendapatkan bridge Anda sendiri';

  @override
  String get torGetBridgesIntro =>
      'Tor Project membagikan bridge dengan cara-cara ini. Mintalah bridge obfs4 atau webtunnel, lalu tempelkan barisnya di atas.';

  @override
  String get torGetBridgesWeb => 'Situs web: bridges.torproject.org';

  @override
  String get torGetBridgesTelegram => 'Telegram: kirim pesan ke @GetBridgesBot';

  @override
  String get torGetBridgesEmail =>
      'Email: kirim ke bridges@torproject.org dari alamat Gmail atau Riseup';

  @override
  String get torGetBridgesFriend =>
      'Atau minta orang yang Anda percaya dan memakai Tor untuk membagikan satu baris bridge.';

  @override
  String get transportsTitle => 'Menjangkau orang di luar jaringan ini';

  @override
  String get transportsIntro =>
      'Perangkat di jaringan ini menjangkau Anda secara langsung. Untuk orang lain, Conest memerlukan setidaknya satu jalur lewat internet, dan tiga lebih baik, karena jaringan memblokir sebagian. Inilah yang berfungsi di jaringan ini sekarang.';

  @override
  String get transportsChecking =>
      'Memeriksa apa yang berfungsi di jaringan ini…';

  @override
  String transportsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count siap: disarankan 3',
      zero: 'Belum ada: perlu 1, disarankan 3',
    );
    return '$_temp0';
  }

  @override
  String get transportStateOn => 'Berfungsi';

  @override
  String get transportStateWorks => 'Berfungsi di sini';

  @override
  String get transportStateBlocked => 'Diblokir di sini';

  @override
  String get transportStateNeedsSetup => 'Atur nanti di Pengaturan';

  @override
  String get transportsEmailCost =>
      'Memeriksa kotak surat: sedikit lebih banyak data dan baterai.';

  @override
  String get transportsSkipTitle =>
      'Hanya perangkat di dekat Anda yang bisa menjangkau Anda';

  @override
  String get transportsSkipBody =>
      'Tanpa jalur lewat internet, hanya perangkat di jaringan ini yang bisa menjangkau Anda, dan Anda hanya bisa menjangkau mereka. Anda bisa mengaturnya nanti di Pengaturan, bagian Konektivitas.';

  @override
  String get transportsSkipConfirm => 'Tetap lanjutkan';

  @override
  String get transportsBanner =>
      'Saat ini hanya perangkat di jaringan ini yang bisa menjangkau Anda. Atur jalur lewat internet.';

  @override
  String get transportsBannerAction => 'Atur';

  @override
  String get transportsBannerDismiss => 'Nanti saja';

  @override
  String transportsTurnOnFailed(String name, String error) {
    return '$name tidak bisa dinyalakan: $error';
  }

  @override
  String get transportsHowToChoose => 'Cara memilih';

  @override
  String get settingsUserGuide => 'Panduan pengguna';

  @override
  String get settingsEnterSends => 'Enter mengirim pesan';

  @override
  String get settingsEnterSendsHelp =>
      'Shift+Enter membuat baris baru. Mati: Enter membuat baris baru dan Ctrl+Enter mengirim.';

  @override
  String get menuCopySelection => 'Salin teks yang dipilih';

  @override
  String get linkLookalikeTitle => 'Buka tautan ini?';

  @override
  String linkLookalikeBody(String host) {
    return 'Alamat $host memakai huruf dari abjad lain. Mungkin meniru situs yang Anda kenal.';
  }

  @override
  String get linkOpen => 'Buka';

  @override
  String get carrierRemove => 'Hapus';

  @override
  String carrierRemoveTitle(String name) {
    return 'Hapus $name?';
  }

  @override
  String carrierRemoveBody(String name) {
    return 'Kontak tidak akan bisa menjangkau Anda lewat $name lagi, dan yang disimpan perangkat ini untuknya dilupakan. Menyiapkannya lagi memberi Anda alamat baru. Untuk menghentikannya sementara, matikan sakelarnya saja.';
  }

  @override
  String get carrierPaused =>
      'Dijeda: disimpan, tidak dipakai. Nyalakan untuk memakainya lagi.';

  @override
  String get emailChangeAccount => 'Ganti akun';

  @override
  String get emailOtherServer => 'Pakai server lain';

  @override
  String get actionSave => 'Simpan';

  @override
  String get settingsLinksTitle => 'Tautan yang Anda kirim dan buka';

  @override
  String get settingsCleanLinks => 'Hapus pelacakan dari tautan';

  @override
  String get settingsCleanLinksHelp =>
      'Menghapus bagian tautan yang memberi tahu situs siapa yang membagikannya (seperti ?si= atau utm_), saat dikirim dan saat dibuka. Memakai aturan ClearURLs.';

  @override
  String get settingsEmbedLinks => 'Tautan yang menampilkan pratinjau';

  @override
  String get settingsEmbedLinksHelp =>
      'Tautan ke postingan di X, Instagram, Reddit, TikTok, dan situs serupa melewati layanan yang memungkinkan aplikasi lain menampilkan pratinjau dan meneruskan peramban ke postingan. Layanan diambil dari daftar embed-fixer; yang gagal dilewati.';

  @override
  String get linkCleaned => 'Tautan dibersihkan';

  @override
  String get linkCleanedUndo => 'Urungkan';

  @override
  String get menuOpenOriginalLink => 'Buka tautan asli';

  @override
  String get editorSendOriginalAsFile =>
      'Kirim asli sebagai file (tanpa kompresi)';

  @override
  String get linkPreviewShow => 'Tampilkan pratinjau tautan';

  @override
  String get settingsLinkPreviews => 'Pratinjau tautan';

  @override
  String get settingsLinkPreviewsHelp =>
      'Menampilkan judul dan gambar tautan di bawah pesan. Perangkat ini mengambilnya dari situs, yang lalu melihat alamat IP Anda: otomatis di obrolan dengan kontak dan grup Anda (tidak saat hemat baterai atau roaming), dan di obrolan lain hanya saat Anda mengetuk.';

  @override
  String get linkPreviewModeReceiver => 'Setiap penerima mengambilnya';

  @override
  String get linkPreviewModeSender =>
      'Dikirim bersama pesan (penerima tidak menghubungi situs)';

  @override
  String get linkPreviewModeBoth => 'Keduanya';

  @override
  String get linkPreviewModeOff => 'Mati';

  @override
  String get linkPreviewRemove => 'Kirim tanpa pratinjau';

  @override
  String get settingsLinkPreviewsTor => 'Ambil pratinjau lewat Tor';

  @override
  String get settingsLinkPreviewsTorHelp =>
      'Saat Tor disiapkan, situs melihat simpul keluar Tor, bukan alamat Anda, dan tidak ada yang dicari tentang tautan di jaringan Anda. Selama Tor belum terhubung, pratinjau tidak diambil.';

  @override
  String linkPreviewFromSender(String host) {
    return '$host · pratinjau dari pengirim';
  }

  @override
  String get contentRoutingTitle => 'Apa yang dikirim lewat internet';

  @override
  String get contentRoutingHelp =>
      'Jaringan lokal Anda selalu membawa semuanya. Kontak Anda mengetahui pilihan ini: yang dikecualikan menunggu jalur yang boleh membawanya.';

  @override
  String get contentRoutingEverything => 'Semuanya';

  @override
  String get contentRoutingMessagesAndSmallFiles =>
      'Pesan dan berkas hingga 1 MB';

  @override
  String get contentRoutingMessagesOnly =>
      'Hanya pesan (berkas lewat jaringan lokal)';

  @override
  String get contentRoutingCustom => 'Kustom';

  @override
  String get contentRoutingByTransport => 'Per jalur';

  @override
  String get contentClassText => 'Pesan';

  @override
  String get contentClassOwnSync => 'Perangkat Anda';

  @override
  String get contentClassHistory => 'Riwayat';

  @override
  String get contentClassFileSmall => 'Berkas ≤1 MB';

  @override
  String get contentClassFileMedium => 'Berkas ≤30 MB';

  @override
  String get contentClassFileLarge => 'Berkas lebih besar';

  @override
  String get contentClassCallSignal => 'Panggilan';

  @override
  String get contentRoutingCannotCarry => 'Jalur ini tidak dapat membawanya';

  @override
  String get routeViaOwnDevice => 'Lewat perangkat Anda yang lain';

  @override
  String get routeOwnDeviceDescription =>
      'Diterima oleh perangkat Anda yang lain, lalu diteruskan ke perangkat ini, terenkripsi ujung ke ujung.';

  @override
  String get routeShortOwnDevice => 'Perangkat Anda';

  @override
  String get backgroundReceiveTitle => 'Terima pesan di latar belakang';

  @override
  String get backgroundReceiveHelp =>
      'Pesan dan panggilan tetap masuk saat Conest ditutup. Android menampilkan notifikasi senyap selama berjalan.';

  @override
  String get batteryExemptionTitle => 'Optimasi baterai';

  @override
  String get batteryExemptionAllowed =>
      'Tanpa batasan: Android tidak menghentikan Conest di latar belakang.';

  @override
  String get batteryExemptionLimited =>
      'Android bisa menghentikan Conest di latar belakang, dan pesan menunggu sampai Anda membukanya.';

  @override
  String get batteryExemptionAllow => 'Izinkan';

  @override
  String get batteryExemptionPromptTitle => 'Tetap terima pesan';

  @override
  String get batteryExemptionPromptBody =>
      'Agar pesan tetap masuk saat Conest ditutup, Android harus mengizinkannya berjalan di latar belakang. Di layar berikutnya, izinkan Conest berjalan tanpa batasan baterai.';

  @override
  String batteryExemptionVendorHint(String maker) {
    return 'Di ponsel $maker, aktifkan juga Mulai otomatis untuk Conest dan atur penghemat bateranya ke \"Tanpa batasan\" (Setelan → Aplikasi → Conest).';
  }

  @override
  String get closeToTrayTitle => 'Tetap berjalan di baki saat ditutup';

  @override
  String get closeToTrayHelp =>
      'Pesan tetap masuk. Buka Conest lagi dari ikon baki, atau keluar dari sana.';

  @override
  String get trayShow => 'Tampilkan Conest';

  @override
  String get trayQuit => 'Keluar';

  @override
  String get notificationReply => 'Balas';

  @override
  String get notificationMarkRead => 'Tandai sudah dibaca';

  @override
  String notificationReplyNotSent(String text) {
    return 'Tidak terkirim: $text';
  }

  @override
  String get startAtLoginTitle => 'Jalankan Conest saat Anda masuk';

  @override
  String get startAtLoginHelp =>
      'Terbuka di baki sistem, siap menerima, tanpa jendela.';

  @override
  String get notificationNewMessage => 'Pesan baru';

  @override
  String notificationNewMessageFrom(String name) {
    return 'Pesan baru dari $name';
  }

  @override
  String get notificationReplyNotSentPlain => 'Sebuah balasan tidak terkirim';

  @override
  String get notificationPreviewTitle => 'Tampilkan di notifikasi';

  @override
  String get notificationPreviewFull => 'Nama dan pesan';

  @override
  String get notificationPreviewSender => 'Nama saja';

  @override
  String get notificationPreviewHidden => 'Tidak ada';

  @override
  String get voiceSettingsTitle => 'Suara';

  @override
  String get voiceInputDevice => 'Mikrofon';

  @override
  String get voiceOutputDevice => 'Speaker atau headphone';

  @override
  String get voiceSystemDefault => 'Bawaan sistem';

  @override
  String get voiceInputVolume => 'Volume mikrofon';

  @override
  String get voiceOutputVolume => 'Volume suara';

  @override
  String get voiceMicTest => 'Periksa mikrofon';

  @override
  String get voiceMicTestStart => 'Periksa';

  @override
  String get voiceMicTestStop => 'Berhenti';

  @override
  String get voiceMicTestLoopback => 'Dengar suara sendiri';

  @override
  String get voiceMicTestUnavailable =>
      'Tes mikrofon tidak tersedia sekarang (sedang panggilan, atau versi ini tanpa audio panggilan).';

  @override
  String get voiceInputMode => 'Kirim suara saya';

  @override
  String get voiceInputModeAlways => 'Selalu';

  @override
  String get voiceInputModeActivity => 'Saat saya bicara';

  @override
  String get voiceInputModePushToTalk => 'Tekan untuk bicara';

  @override
  String get voiceSensitivityAutomatic => 'Atur sensitivitas otomatis';

  @override
  String get voiceSensitivity => 'Sensitivitas';

  @override
  String get voicePushToTalkKey => 'Tombol tekan untuk bicara';

  @override
  String get voicePushToTalkKeyNone => 'Hanya tombol panggilan';

  @override
  String get voicePushToTalkKeyPress => 'Tekan sebuah tombol…';

  @override
  String get voicePushToTalkKeyHint => 'berfungsi saat Conest di depan';

  @override
  String get voiceClear => 'Hapus';

  @override
  String get voiceProcessing => 'Pemrosesan';

  @override
  String get voiceNoiseSuppression => 'Peredam bising';

  @override
  String get voiceEchoCancellation => 'Peredam gema';

  @override
  String get voiceAutoGain => 'Volume otomatis';

  @override
  String get voiceCallSounds => 'Suara panggilan';

  @override
  String get voiceCallSoundsHint => 'Panggilan masuk tetap berdering.';

  @override
  String get voiceDevicesOnPhone =>
      'Di Android, ponsel memilih mikrofon dan speaker untuk panggilan.';

  @override
  String get voiceSettingsButton => 'Pengaturan suara';

  @override
  String voiceParticipantVolume(String name) {
    return 'Volume $name';
  }

  @override
  String get voiceHoldToTalk => 'Tahan untuk bicara';

  @override
  String get quietHoursTitle => 'Jam tenang';

  @override
  String get quietHoursHint =>
      'Notifikasi tetap muncul, tanpa suara atau getar.';

  @override
  String quietHoursFrom(String time) {
    return 'Dari $time';
  }

  @override
  String quietHoursUntil(String time) {
    return 'Sampai $time';
  }

  @override
  String get quietHoursCallsRing => 'Panggilan tetap berdering';

  @override
  String get muteForHour => 'Selama 1 jam';

  @override
  String get muteForEightHours => 'Selama 8 jam';

  @override
  String get muteForDay => 'Selama 1 hari';

  @override
  String get muteUntilUnmuted => 'Sampai saya aktifkan lagi';

  @override
  String get notifyMentionsOnly => 'Beri tahu hanya saat disebut';

  @override
  String get notifyAllMessages => 'Beri tahu semua pesan';

  @override
  String get xmppEncOmemo2Unverified => 'encrypted, unverified (OMEMO)';

  @override
  String get xmppTrustPending => 'new device, not confirmed';

  @override
  String get xmppUnconfirmedMsg => 'From a new device you have not confirmed.';

  @override
  String get xmppEncOmemo2 => 'terenkripsi (OMEMO)';

  @override
  String get xmppEncLegacy => 'OMEMO lama (belum ditinjau)';

  @override
  String get xmppEncAuto => 'terenkripsi jika kontak mendukung';

  @override
  String get xmppEncRequired => 'selalu terenkripsi';

  @override
  String get xmppEncryptionMenu => 'Enkripsi dan kunci';

  @override
  String get xmppEncryptionTitle => 'Enkripsi';

  @override
  String get xmppEncryptionAuto => 'Saat kontak mendukung';

  @override
  String get xmppEncryptionOn => 'Selalu (jangan kirim jika tidak bisa)';

  @override
  String get xmppEncryptionOff => 'Tidak pernah';

  @override
  String get xmppKeysTitle => 'Kunci enkripsi';

  @override
  String get xmppKeysYours => 'Kunci Anda';

  @override
  String get xmppKeysYoursHint =>
      'Bandingkan sidik jari ini dengan kontak Anda, langsung atau lewat panggilan tepercaya, atau biarkan mereka memindai kodenya.';

  @override
  String xmppKeysTheirs(String name) {
    return 'Perangkat $name';
  }

  @override
  String get xmppKeysNone => 'Tidak ada perangkat OMEMO untuk kontak ini.';

  @override
  String get xmppTrustBlind => 'belum diverifikasi';

  @override
  String get xmppTrustVerified => 'terverifikasi';

  @override
  String get xmppTrustRefused => 'ditolak';

  @override
  String get xmppTrustVerify => 'Tandai terverifikasi';

  @override
  String get xmppTrustRefuse => 'Tolak perangkat ini';

  @override
  String get xmppTrustAllow => 'Izinkan lagi';

  @override
  String get xmppKeysScan => 'Pindai kode mereka';

  @override
  String get xmppKeysRefresh => 'Periksa perangkat';

  @override
  String get xmppKeysForget => 'Lupakan kunci perangkat ini';

  @override
  String get xmppKeysChanged =>
      'Kuncinya berubah: tidak ada yang dikirim sampai Anda melupakan kunci lama.';

  @override
  String xmppKeysScanMatch(String count) {
    return '$count perangkat terverifikasi.';
  }

  @override
  String get xmppKeysScanMismatch =>
      'Kode tidak cocok dengan kunci kontak ini. Jangan percayai.';

  @override
  String get xmppUnreadable => 'Pesan ini tidak dapat didekripsi.';

  @override
  String get xmppUntrustedMsg => 'Dari perangkat yang Anda tolak.';

  @override
  String get xmppLegacySwitch => 'OMEMO lama (eksperimental)';

  @override
  String get xmppLegacyHint =>
      'Mengobrol terenkripsi dengan aplikasi lama seperti Conversations, Dino, dan Gajim. Belum ditinjau, jadi pesan semacam itu tidak ditandai terenkripsi.';

  @override
  String get routeXmppDescription =>
      'Dibawa server XMPP, tetap terenkripsi ujung ke ujung oleh Conest; server melihat kedua akun dan waktunya.';

  @override
  String get xmppCarrierSubtitle => 'Bawa pesan melalui akun XMPP (Jabber)';

  @override
  String get xmppCreatedAccount => 'Akun dibuat oleh Conest';

  @override
  String get xmppOwnAccount => 'Akun Anda sendiri';

  @override
  String get xmppChangeAccount => 'Ganti akun';

  @override
  String get xmppServerField =>
      'Server XMPP (kosong: yang pertama menjawab di sini)';

  @override
  String get xmppUseOwnAccount => 'Gunakan akun XMPP saya sendiri';

  @override
  String get xmppOwnAccountNote =>
      'Conest masuk sebagai perangkat tambahan; aplikasi XMPP Anda yang lain tidak melihat pesannya.';

  @override
  String get xmppAddressField => 'Alamat XMPP (nama@server)';

  @override
  String get xmppPasswordField => 'Kata sandi';

  @override
  String get xmppRetracted => 'Pesan ditarik';

  @override
  String get xmppFile => 'Berkas';

  @override
  String get xmppNewChat => 'Obrolan XMPP baru';

  @override
  String get xmppNewChatAddress => 'Alamat atau tautan xmpp:';

  @override
  String get xmppGroupChat => 'Obrolan grup';

  @override
  String get xmppNickname => 'Nama panggilan Anda';

  @override
  String get xmppOpenChat => 'Buka';

  @override
  String get xmppMetadataTitle => 'Beberapa detail tetap ada di berkas ini';

  @override
  String get xmppMetadataBody =>
      'Conest tidak dapat menghapus semua detail tersembunyi (seperti lokasi atau perangkat) dari berkas ini. Tetap kirim?';

  @override
  String get xmppSendAnyway => 'Tetap kirim';

  @override
  String get xmppReply => 'Balas';

  @override
  String get xmppCopy => 'Salin';

  @override
  String get xmppEdit => 'Sunting';

  @override
  String get xmppRetract => 'Tarik';

  @override
  String get xmppChatGone => 'Obrolan ini sudah tidak ada.';

  @override
  String get xmppNotEncrypted => 'tidak terenkripsi';

  @override
  String get xmppLeaveRoom => 'Keluar dari obrolan grup';

  @override
  String get xmppDeleteChat => 'Hapus obrolan';

  @override
  String get xmppBlock => 'Blokir';

  @override
  String get xmppAccept => 'Terima';

  @override
  String get xmppRequest =>
      'Seseorang yang bukan kontak Anda menulis kepada Anda. Balasan dan tanda baca dikirim hanya setelah Anda menerima.';

  @override
  String get xmppRoomInvitation =>
      'Anda diundang ke obrolan grup ini. Bergabung?';

  @override
  String get xmppAttach => 'Lampirkan berkas';

  @override
  String get xmppMessageHint => 'Pesan';

  @override
  String get xmppEdited => 'disunting';

  @override
  String get xmppChats => 'Obrolan XMPP';

  @override
  String get xmppChatsSubtitle =>
      'Mengobrol dengan siapa pun di XMPP (Jabber), di samping obrolan Conest';

  @override
  String get xmppChatsOtherAccount =>
      'Gunakan akun lain selain yang dipakai Conest membawa pesan';

  @override
  String get xmppConnected => 'terhubung';

  @override
  String get xmppConnecting => 'menghubungkan';

  @override
  String appModeClientOnlyTitle(String network) {
    return 'Gunakan Conest sebagai klien $network?';
  }

  @override
  String get onbXmppInstead => 'Gunakan sebagai klien XMPP saja';

  @override
  String get xmppSignIn => 'Masuk ke akun XMPP Anda';

  @override
  String get xmppNoChats => 'Belum ada obrolan XMPP';

  @override
  String get xmppRequestShort => 'Permintaan obrolan';

  @override
  String get routeTelegramDescription =>
      'Dibawa oleh bot Telegram, tetap dienkripsi ujung ke ujung oleh Conest; Telegram melihat kedua bot dan waktunya.';

  @override
  String get telegramCarrierSubtitle =>
      'Bawa pesan lewat bot Telegram yang Anda buat';

  @override
  String get telegramChangeBot => 'Ganti bot';

  @override
  String get telegramBotHelp =>
      'Buat bot dengan @BotFather, aktifkan pesan antar-bot untuknya, lalu tempel tokennya di sini. Pakai bot yang hanya dibaca Conest. Kontak Anda melakukan hal yang sama.';

  @override
  String get telegramBotTokenField => 'Token bot';
}

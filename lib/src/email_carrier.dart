import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'carrier.dart';
import 'email/carrier_mail.dart';
import 'email/imap.dart';
import 'email/mail_socket.dart';
import 'email/smtp.dart';
import 'network_errors.dart';
import 'transport_models.dart';

/// Chatmail servers a new email carrier can create an account on. Any
/// chatmail server works; these are run by different operators.
const List<String> defaultChatmailDomains = ['nine.testrun.org'];

/// A device's address on the email carrier: its mail address and the
/// mailbox key senders encrypt its mail with.
class EmailAddress {
  const EmailAddress({required this.mail, required this.mailboxKey});

  /// Lower-case `local@domain`.
  final String mail;

  /// 32 random bytes; the OpenPGP password of mail to this address.
  final Uint8List mailboxKey;

  String encode() => '$mail|${base64Url.encode(mailboxKey)}';

  static EmailAddress? tryParse(String value) {
    final split = value.indexOf('|');
    if (split <= 0) return null;
    final mail = value.substring(0, split);
    if (!isPlausibleMailAddress(mail)) return null;
    try {
      final key = base64Url.decode(value.substring(split + 1));
      if (key.length != 32) return null;
      return EmailAddress(mail: mail, mailboxKey: key);
    } on FormatException {
      return null;
    }
  }
}

bool isValidEmailCarrierAddress(String address) =>
    EmailAddress.tryParse(address) != null;

/// The saved email carrier account.
class EmailCarrierConfig {
  const EmailCarrierConfig({
    required this.mail,
    required this.password,
    required this.imapHost,
    required this.imapPort,
    required this.smtpHost,
    required this.smtpPort,
    required this.mailboxKey,
    this.chatmail = false,
    this.uidValidity,
    this.lastUid = 0,
  });

  /// A new account on a chatmail server: a random name and password; the
  /// first login creates it.
  factory EmailCarrierConfig.chatmail(String domain, {Random? random}) {
    final source = random ?? Random.secure();
    String token(String alphabet, int length) => List.generate(
      length,
      (_) => alphabet[source.nextInt(alphabet.length)],
    ).join();
    return EmailCarrierConfig(
      mail: '${token('abcdefghijklmnopqrstuvwxyz0123456789', 9)}@$domain',
      password: token(
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789',
        32,
      ),
      imapHost: domain,
      imapPort: 993,
      smtpHost: domain,
      smtpPort: 465,
      mailboxKey: newMailboxKey(source),
      chatmail: true,
    );
  }

  final String mail;
  final String password;
  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;
  final Uint8List mailboxKey;
  final bool chatmail;

  /// Where reading resumes: the folder's UIDVALIDITY and the last UID read.
  final int? uidValidity;
  final int lastUid;

  static Uint8List newMailboxKey([Random? random]) {
    final source = random ?? Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => source.nextInt(256)));
  }

  EmailCarrierConfig copyWith({int? uidValidity, int? lastUid}) =>
      EmailCarrierConfig(
        mail: mail,
        password: password,
        imapHost: imapHost,
        imapPort: imapPort,
        smtpHost: smtpHost,
        smtpPort: smtpPort,
        mailboxKey: mailboxKey,
        chatmail: chatmail,
        uidValidity: uidValidity ?? this.uidValidity,
        lastUid: lastUid ?? this.lastUid,
      );

  Map<String, Object?> toJson() => {
    'mail': mail,
    'password': password,
    'imapHost': imapHost,
    'imapPort': imapPort,
    'smtpHost': smtpHost,
    'smtpPort': smtpPort,
    'mailboxKey': base64Url.encode(mailboxKey),
    if (chatmail) 'chatmail': true,
    if (uidValidity != null) 'uidValidity': uidValidity,
    if (lastUid > 0) 'lastUid': lastUid,
  };

  static EmailCarrierConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final mail = json['mail'];
    final password = json['password'];
    final imapHost = json['imapHost'];
    final imapPort = json['imapPort'];
    final smtpHost = json['smtpHost'];
    final smtpPort = json['smtpPort'];
    final key = json['mailboxKey'];
    if (mail is! String ||
        !isPlausibleMailAddress(mail) ||
        password is! String ||
        imapHost is! String ||
        imapPort is! int ||
        smtpHost is! String ||
        smtpPort is! int ||
        key is! String) {
      return null;
    }
    final Uint8List mailboxKey;
    try {
      mailboxKey = base64Url.decode(key);
    } on FormatException {
      return null;
    }
    if (mailboxKey.length != 32) return null;
    return EmailCarrierConfig(
      mail: mail,
      password: password,
      imapHost: imapHost,
      imapPort: imapPort,
      smtpHost: smtpHost,
      smtpPort: smtpPort,
      mailboxKey: mailboxKey,
      chatmail: json['chatmail'] == true,
      uidValidity: json['uidValidity'] as int?,
      lastUid: json['lastUid'] as int? ?? 0,
    );
  }

  @override
  String toString() => 'EmailCarrierConfig($mail via $imapHost/$smtpHost)';
}

enum EmailCarrierState { stopped, connecting, connected, failed }

/// The email side of the carrier: reads carrier mail from the account's
/// inbox (IMAP IDLE, or polling where IDLE is missing) and sends each frame
/// as one mail (SMTP). Mail that is not carrier mail for this mailbox key
/// is left untouched; carrier mail is deleted once read.
class EmailCarrierChannel implements ManagedCarrierChannel {
  EmailCarrierChannel({
    required EmailCarrierConfig config,
    required this.onFrame,
    this.onCursor,
    this.onStatusChanged,
    MailConnector? connector,
    this.tls = true,
    this.idleTimeout = const Duration(minutes: 25),
    this.pollInterval = const Duration(minutes: 1),
    DateTime Function()? now,
  }) : _config = config,
       _connector = connector,
       _now = now ?? DateTime.now;

  EmailCarrierConfig _config;
  final MailConnector? _connector;
  final DateTime Function() _now;

  /// TLS from the first byte; off only for servers on this machine.
  final bool tls;
  final Duration idleTimeout;
  final Duration pollInterval;

  /// A frame from the mail address [sender].
  final void Function(String sender, Uint8List frame) onFrame;

  /// The folder position after mail was read, to resume after a restart.
  final void Function(int uidValidity, int lastUid)? onCursor;
  final void Function()? onStatusChanged;

  EmailCarrierState _state = EmailCarrierState.stopped;
  String? _lastError;
  bool _started = false;
  int _generation = 0;
  Completer<void>? _wake;

  EmailCarrierConfig get config => _config;
  EmailCarrierState get state => _state;
  String? get lastError => _lastError;

  @override
  String? get localAddress =>
      EmailAddress(mail: _config.mail, mailboxKey: _config.mailboxKey).encode();

  @override
  String get routeLabel =>
      _config.mail.substring(_config.mail.indexOf('@') + 1);

  /// Logs in once; a chatmail server creates the account on first login.
  static Future<void> checkLogin(
    EmailCarrierConfig config, {
    MailConnector? connector,
    bool tls = true,
  }) async {
    final client = await ImapClient.connect(
      config.imapHost,
      config.imapPort,
      tls: tls,
      connector: connector,
    );
    try {
      await client.login(config.mail, config.password);
    } finally {
      await client.logout();
    }
  }

  @override
  void start() {
    if (_started) return;
    _started = true;
    unawaited(_readLoop(++_generation));
  }

  @override
  Future<void> stop() async {
    _started = false;
    _generation++;
    _wake?.complete();
    _wake = null;
    _setState(EmailCarrierState.stopped);
  }

  @override
  Future<void> sendFrame(String address, Uint8List frame) async {
    if (!_started) throw StateError('The email carrier is stopped.');
    final to = EmailAddress.tryParse(address);
    if (to == null) throw ArgumentError('Not an email carrier address.');
    await SmtpSender.send(
      host: _config.smtpHost,
      port: _config.smtpPort,
      user: _config.mail,
      password: _config.password,
      from: _config.mail,
      to: to.mail,
      tls: tls,
      connector: _connector,
      message: CarrierMail.build(
        from: _config.mail,
        to: to.mail,
        mailboxKey: to.mailboxKey,
        frame: frame,
        date: _now(),
      ),
    );
  }

  Future<void> _readLoop(int generation) async {
    bool current() => _started && generation == _generation;
    var backoff = const Duration(seconds: 2);
    while (current()) {
      ImapClient? client;
      try {
        _setState(EmailCarrierState.connecting);
        client = await ImapClient.connect(
          _config.imapHost,
          _config.imapPort,
          tls: tls,
          connector: _connector,
        );
        await client.login(_config.mail, _config.password);
        final (validity, next) = await client.select('INBOX');
        if (!current()) break;
        if (validity != _config.uidValidity) {
          // A new account, or UIDs restarted: start after the newest mail.
          // Nothing older can be carrier mail for this mailbox key, and a
          // large inbox of the user's own mail is never downloaded.
          final start = _config.uidValidity == null
              ? (next == null ? 0 : next - 1)
              : 0;
          _config = _config.copyWith(uidValidity: validity, lastUid: start);
          onCursor?.call(validity, start);
        }
        _lastError = null;
        _setState(EmailCarrierState.connected);
        backoff = const Duration(seconds: 2);
        while (current()) {
          await _readNew(client, generation);
          if (!current()) break;
          // Mail announced while reading: read again before waiting.
          if (client.takeNewMail()) continue;
          final wake = Completer<void>();
          _wake = wake;
          if (client.supportsIdle) {
            await client.idle(idleTimeout, stop: wake.future);
          } else {
            await Future.any([wake.future, Future<void>.delayed(pollInterval)]);
          }
        }
      } catch (error) {
        if (!current()) break;
        _lastError = describeNetworkError(error);
        _setState(EmailCarrierState.failed);
        final wake = Completer<void>();
        _wake = wake;
        await Future.any([wake.future, Future<void>.delayed(backoff)]);
        backoff = backoff * 2 > const Duration(minutes: 5)
            ? const Duration(minutes: 5)
            : backoff * 2;
      } finally {
        await client?.logout().catchError((Object _) {});
      }
    }
  }

  Future<void> _readNew(ImapClient client, int generation) async {
    bool current() => _started && generation == _generation;
    final uids = await client.uidsAfter(_config.lastUid);
    for (final uid in uids) {
      if (!current()) return;
      final size = await client.size(uid);
      if (size != null && size <= maxCarrierMailBytes) {
        final raw = await client.fetch(
          uid,
          maxBytes: maxCarrierMailBytes + 64 * 1024,
        );
        if (!current()) return;
        final mail = raw == null
            ? null
            : CarrierMail.read(raw, _config.mailboxKey);
        if (mail != null) {
          // Delivered before deleting: a duplicate after a crash is dropped
          // by the receiver, a lost frame would not come back.
          onFrame(mail.from, mail.frame);
          try {
            await client.delete(uid);
          } on ImapException {
            // A read-only or full mailbox keeps it; the cursor moves on.
          }
        }
      }
      if (!current()) return;
      _config = _config.copyWith(lastUid: uid);
      onCursor?.call(_config.uidValidity!, uid);
    }
  }

  void _setState(EmailCarrierState state) {
    if (_state == state) return;
    _state = state;
    onStatusChanged?.call();
  }
}

/// An email carrier adapter: one mail per envelope.
CarrierTransportAdapter createEmailCarrierAdapter({
  required CarrierSealer sealer,
  DateTime Function()? now,
}) => CarrierTransportAdapter(
  kind: TransportKind.deltaChat,
  sealer: sealer,
  framing: CarrierFraming.email,
  sendAttemptTimeout: const Duration(seconds: 90),
  isValidAddress: isValidEmailCarrierAddress,
  now: now,
);

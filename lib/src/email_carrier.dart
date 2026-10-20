import 'dart:async';
import 'dart:collection';
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
/// chatmail server works; these are run by different operators (from
/// chatmail.at/relays, October 2026). Networks block or throttle some of
/// them and not others, and which ones changes, so a new account goes to
/// whichever answer fastest here (see [reachableChatmailServers]).
const List<String> defaultChatmailDomains = [
  'nine.testrun.org',
  'chat.adminforge.de',
  'mailchat.pl',
  'tarpit.fun',
  'chat.vim.wtf',
  'd.gaufr.es',
  'e2ee.im',
  'toque.im',
  'chatmail.email',
  'chtml.ca',
  'mehl.cloud',
  'delta.disobey.net',
  'chika.aangat.lahat.computer',
  'uninterest.ing',
  'e2ee.wang',
  'chatmail.culturanerd.it',
  'chat.nuvon.app',
  'sweetfern.net',
  'nibblehole.com',
  'chatmail.woodpeckersnest.space',
];

/// Of [domains], those whose IMAP greeting arrives within [timeout] on this
/// network, fastest first. Every probe's connection is closed (no login is
/// tried), late ones too. Stops waiting once [enough] have answered.
Future<List<String>> reachableChatmailServers(
  List<String> domains, {
  MailConnector? connector,
  Future<MailSocket> Function(String host, String alpn)? viaHttpsPort,
  Duration timeout = const Duration(seconds: 20),
  int enough = 3,
  int parallel = 4,
  Duration headStart = const Duration(seconds: 4),
  void Function(String line)? log,
}) async {
  // Port 993 and port 443 at once: on a censoring network the mail port's
  // TLS can stall for longer than this whole probe, so trying 443 only
  // after it found nothing (seen on the device lab).
  // A port that connects and never greets is given up after a few seconds,
  // not left open until its read timeout.
  final direct =
      connector ??
      chatmailFallback(
        viaHttpsPort: (_, _) => Future.error(StateError('probe: 993 only')),
        greetingWait: const Duration(seconds: 6),
      );
  final https =
      viaHttpsPort ?? (connector == null ? connectViaHttpsPort : null);
  final answered = <String>[];
  final done = Completer<void>();
  if (domains.isEmpty) return const [];
  var pending = domains.length;
  void settle() {
    if (!done.isCompleted && (answered.length >= enough || pending == 0)) {
      done.complete();
    }
  }

  // A few servers at a time, each given a head start before the next: a
  // burst of 40 connections at once was held back by the device lab's
  // network for about 27 s (like a port scan), while one after another
  // they answered within a second.
  // Head starts still running when the probe ends are cancelled.
  final timers = <Timer>[];
  final queue = Queue.of(domains);
  var slots = parallel;
  void launch() {
    while (slots > 0 && queue.isNotEmpty && !done.isCompleted) {
      slots--;
      final domain = queue.removeFirst();
      final freed = Completer<void>();
      void free() {
        if (!freed.isCompleted) {
          freed.complete();
          slots++;
          launch();
        }
      }

      timers.add(Timer(headStart, free));
      final attempts = [
        ImapClient.connect(domain, 993, connector: direct),
        if (https != null)
          ImapClient.connect(
            domain,
            993,
            connector: (host, _, {required bool tls}) => https(host, 'imap'),
          ),
      ];
      var failed = 0;
      var won = false;
      final watch = Stopwatch()..start();
      for (final (index, attempt) in attempts.indexed) {
        final port = index == 0 ? '993' : '443';
        attempt.then(
          (client) {
            log?.call(
              '$domain:$port answered in ${watch.elapsedMilliseconds} ms',
            );
            unawaited(client.close().catchError((Object _) {}));
            if (won) return;
            won = true;
            if (!done.isCompleted) {
              answered.add(domain);
              // 443 answered first: sign-up goes there first too, rather
              // than waiting out a mail port that may stall for half a
              // minute.
              if (index == 1) chatmailReachedViaHttps.add(domain);
            }
            pending--;
            // Settled first: no server is started once enough answered.
            settle();
            free();
          },
          onError: (Object error) {
            log?.call(
              '$domain:$port failed after ${watch.elapsedMilliseconds} ms: '
              '$error',
            );
            if (++failed == attempts.length && !won) {
              pending--;
              // Settled first: no server is started once enough answered.
              settle();
              free();
            }
          },
        );
      }
    }
  }

  launch();
  await done.future.timeout(timeout, onTimeout: () {});
  for (final timer in timers) {
    timer.cancel();
  }
  return List.unmodifiable(answered);
}

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

/// Recognized external mail could not yet be durably saved. Keep its UID.
class OtherMailRetryException implements Exception {
  const OtherMailRetryException();
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
    this.onOtherMail,
    this.onOtherMailGaveUp,
    this.otherMailMaxBytes,
    MailConnector? connector,
    this.tls = true,
    this.idleTimeout = const Duration(minutes: 25),
    this.pollInterval = const Duration(minutes: 1),
    this.connectionLimitWait = const Duration(minutes: 10),
    DateTime Function()? now,
    void Function(String line)? log,
  }) : _config = config,
       _log = log,
       // Chatmail servers also listen on 443, for networks that block the
       // mail ports.
       _connector =
           connector ??
           (config.chatmail
               ? chatmailFallback(log: log, viaHttps: chatmailReachedViaHttps)
               : null),
       _now = now ?? DateTime.now;

  EmailCarrierConfig _config;
  final MailConnector? _connector;
  final DateTime Function() _now;
  final void Function(String line)? _log;

  /// TLS from the first byte; off only for servers on this machine.
  final bool tls;
  final Duration idleTimeout;
  final Duration pollInterval;

  /// How long to wait after the server refused another connection.
  final Duration connectionLimitWait;

  /// A frame from the mail address [sender].
  final void Function(String sender, Uint8List frame) onFrame;

  /// The folder position after mail was read, to resume after a restart.
  final void Function(int uidValidity, int lastUid)? onCursor;
  final void Function()? onStatusChanged;

  /// Mail that is not carrier mail (Delta Chat's, say): true when it was
  /// handled and may be deleted. Without it such mail is left alone.
  final Future<bool> Function(Uint8List raw)? onOtherMail;

  /// A message [onOtherMail] could not save after [maxOtherMailAttempts]
  /// tries: left on the server, and skipped.
  final void Function(int uid)? onOtherMailGaveUp;

  static const maxOtherMailAttempts = 3;
  final Map<int, int> _otherMailAttempts = {};

  /// Explicit larger budget for enabled external chats; carrier cap is unchanged.
  final int Function()? otherMailMaxBytes;

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
    void Function(String line)? log,
  }) async {
    final watch = Stopwatch()..start();
    String took() =>
        '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s';
    final client = await ImapClient.connect(
      config.imapHost,
      config.imapPort,
      tls: tls,
      connector:
          connector ??
          (config.chatmail
              ? chatmailFallback(log: log, viaHttps: chatmailReachedViaHttps)
              : null),
    );
    log?.call('IMAP ${config.imapHost} answered in ${took()}');
    try {
      await client.login(config.mail, config.password);
      log?.call('IMAP login at ${config.imapHost} done in ${took()}');
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

  /// Sends [message] (RFC 5322 text) from this account to [to].
  Future<void> sendMail(List<String> to, String message) async {
    if (!_started) throw StateError('The email carrier is stopped.');
    if (to.isEmpty) return;
    await SmtpSender.send(
      host: _config.smtpHost,
      port: _config.smtpPort,
      user: _config.mail,
      password: _config.password,
      from: _config.mail,
      to: to.first,
      moreRecipients: to.skip(1).toList(),
      tls: tls,
      connector: _connector,
      message: message,
    );
  }

  Future<void> _readLoop(int generation) async {
    bool current() => _started && generation == _generation;
    var backoff = const Duration(seconds: 2);
    while (current()) {
      ImapClient? client;
      // What it was doing, for the log when it fails.
      var step = 'connecting';
      try {
        _setState(EmailCarrierState.connecting);
        client = await ImapClient.connect(
          _config.imapHost,
          _config.imapPort,
          tls: tls,
          connector: _connector,
        );
        step = 'logging in';
        await client.login(_config.mail, _config.password);
        step = 'opening the inbox';
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
        var storageBackoff = const Duration(seconds: 2);
        while (current()) {
          step = 'reading new mail';
          if (await _readNew(client, generation)) {
            final wake = Completer<void>();
            _wake = wake;
            await Future.any([
              wake.future,
              Future<void>.delayed(storageBackoff),
            ]);
            storageBackoff = storageBackoff * 2 > const Duration(minutes: 5)
                ? const Duration(minutes: 5)
                : storageBackoff * 2;
            continue;
          }
          storageBackoff = const Duration(seconds: 2);
          if (!current()) break;
          // Mail announced while reading: read again before waiting.
          if (client.takeNewMail()) continue;
          final wake = Completer<void>();
          _wake = wake;
          step = 'waiting for mail';
          if (client.supportsIdle) {
            await client.idle(idleTimeout, stop: wake.future);
          } else {
            await Future.any([wake.future, Future<void>.delayed(pollInterval)]);
          }
        }
      } catch (error) {
        // Closed now, not after the wait (nor with a LOGOUT a stalled link
        // would hold up): the server counts open connections per account
        // and refused new ones once failed ones piled up (device lab).
        await client?.close().catchError((Object _) {});
        client = null;
        if (!current()) break;
        _lastError = describeNetworkError(error);
        // The server refuses more connections from this account: it still
        // holds ones the network dropped, until its own timeout, and every
        // earlier try only added to them (the lab phone's account).
        if ('$error'.contains('Maximum number of connections') &&
            backoff < connectionLimitWait) {
          backoff = connectionLimitWait;
        }
        _log?.call(
          'reading mail failed while $step: $error; '
          'next try in ${backoff.inSeconds} s',
        );
        _setState(EmailCarrierState.failed);
        final wake = Completer<void>();
        _wake = wake;
        await Future.any([wake.future, Future<void>.delayed(backoff)]);
        backoff = backoff * 2 > const Duration(minutes: 5)
            ? (backoff > const Duration(minutes: 5)
                  ? backoff
                  : const Duration(minutes: 5))
            : backoff * 2;
      } finally {
        await client?.logout().catchError((Object _) {});
      }
    }
  }

  Future<bool> _readNew(ImapClient client, int generation) async {
    bool current() => _started && generation == _generation;
    final uids = await client.uidsAfter(_config.lastUid);
    for (final uid in uids) {
      if (!current()) return false;
      final size = await client.size(uid);
      final maxBytes = onOtherMail == null
          ? maxCarrierMailBytes
          : (otherMailMaxBytes?.call() ?? maxCarrierMailBytes).clamp(
              maxCarrierMailBytes,
              42 * 1024 * 1024,
            );
      if (size != null && size >= 0 && size <= maxBytes) {
        final raw = await client.fetch(uid, maxBytes: maxBytes);
        if (!current()) return false;
        final mail = raw == null
            ? null
            : CarrierMail.read(raw, _config.mailboxKey);
        var handled = false;
        if (mail != null) {
          // Delivered before deleting: a duplicate after a crash is dropped
          // by the receiver, a lost frame would not come back.
          onFrame(mail.from, mail.frame);
          handled = true;
        } else if (raw != null && onOtherMail != null) {
          try {
            handled = await onOtherMail!(raw);
            _otherMailAttempts.remove(uid);
          } on OtherMailRetryException {
            // Do not advance the durable watermark past an unsaved message,
            // a few times: a message that can never be saved (no room, too
            // many chats) would otherwise be downloaded again and again and
            // hold back every mail after it, carrier frames included. Then
            // it stays on the server, unread.
            final attempts = (_otherMailAttempts[uid] ?? 0) + 1;
            if (attempts < maxOtherMailAttempts) {
              if (_otherMailAttempts.length >= 64) _otherMailAttempts.clear();
              _otherMailAttempts[uid] = attempts;
              return true;
            }
            _otherMailAttempts.remove(uid);
            onOtherMailGaveUp?.call(uid);
          } catch (_) {
            // Not read: left on the server.
          }
          if (!current()) return false;
        }
        if (handled) {
          try {
            await client.delete(uid);
          } on ImapException {
            // A read-only or full mailbox keeps it; the cursor moves on.
          }
        }
      }
      if (!current()) return false;
      _config = _config.copyWith(lastUid: uid);
      onCursor?.call(_config.uidValidity!, uid);
    }
    return false;
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

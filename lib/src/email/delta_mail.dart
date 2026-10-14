/// Delta Chat mail: Autocrypt headers and key gossip, PGP/MIME messages
/// with protected headers (as Delta Chat writes them), and the unencrypted
/// Securejoin request chatmail servers let through.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../attachment_safety.dart';
import 'carrier_mail.dart' show parseMailAddress;
import 'delta_content.dart';
import 'mime.dart';
import 'openpgp.dart';
import 'pgp.dart';

/// An `Autocrypt:` or `Autocrypt-Gossip:` header (Autocrypt level 1).
class AutocryptHeader {
  const AutocryptHeader({
    required this.addr,
    required this.keydata,
    this.mutual = false,
  });

  /// Lower case.
  final String addr;
  final Uint8List keydata;
  final bool mutual;

  /// Null when [value] is not a usable header: no address or key, or an
  /// attribute it does not know without the `_` that makes it optional.
  static AutocryptHeader? parse(String value) {
    String? addr;
    String? keydata;
    var mutual = false;
    for (final attribute in value.split(';')) {
      final equals = attribute.indexOf('=');
      if (equals <= 0) continue;
      final name = attribute.substring(0, equals).trim().toLowerCase();
      final content = attribute.substring(equals + 1).trim();
      switch (name) {
        case 'addr':
          addr = parseMailAddress(content);
        case 'keydata':
          keydata = content.replaceAll(RegExp(r'\s'), '');
        case 'prefer-encrypt':
          mutual = content.toLowerCase() == 'mutual';
        default:
          if (!name.startsWith('_')) return null;
      }
    }
    if (addr == null || keydata == null || keydata.isEmpty) return null;
    try {
      return AutocryptHeader(
        addr: addr,
        keydata: base64.decode(keydata),
        mutual: mutual,
      );
    } on FormatException {
      return null;
    }
  }

  /// The value, with spaces in the key data where the header may fold.
  String encode() {
    final key = base64.encode(keydata);
    final chunks = [
      for (var offset = 0; offset < key.length; offset += 72)
        key.substring(offset, min(offset + 72, key.length)),
    ];
    return 'addr=$addr;${mutual ? ' prefer-encrypt=mutual;' : ''} '
        'keydata=${chunks.join(' ')}';
  }
}

/// Someone to write to: their address and key.
typedef DeltaRecipient = ({String addr, PgpPublicKey key});

/// A Delta Chat message read from mail.
class DeltaIncoming {
  DeltaIncoming._({
    required this.from,
    required this.fromName,
    required this.to,
    required this.messageId,
    required this.date,
    required this.encrypted,
    required this.signer,
    required this.autocryptKey,
    required this.gossip,
    required this.headers,
    required this.text,
    required this.password,
    required this.intendedFor,
    required this.receiptsFor,
    required this.attachments,
    required this.reaction,
    required this.reactionText,
    required this.files,
    required this.postMessage,
  });

  /// The sender's address (lower case).
  final String from;
  final String? fromName;

  /// Addresses in To (lower case), from the protected headers when
  /// encrypted.
  final List<String> to;

  /// Without the angle brackets.
  final String messageId;
  final DateTime? date;
  final bool encrypted;

  /// The key whose good signature the message carries: the sender's
  /// Autocrypt key, or one already known for them. Null when unsigned or
  /// signed by an unknown key.
  final PgpPublicKey? signer;

  /// The key in the sender's Autocrypt header (protected one when
  /// encrypted), if any. It says nothing of who wrote the message unless
  /// [signer] is the same key.
  final PgpPublicKey? autocryptKey;

  /// Keys gossiped for other recipients, by address; only from signed
  /// messages.
  final Map<String, PgpPublicKey> gossip;

  /// Header fields; protected ones replace the outer ones.
  final MimeHeaders headers;

  /// The message text, empty when there is none.
  final String text;

  /// The shared secret it was encrypted with (Securejoin v3), if any.
  final String? password;

  /// Fingerprints the signer named as intended recipients (upper-case
  /// hex); empty when the signature names none.
  final List<String> intendedFor;

  /// For a read receipt (MDN): the Message-IDs it is about.
  final List<String> receiptsFor;

  /// Names of attached files (not read into Conest yet).
  final List<String> attachments;

  /// A reaction (an emoji on another message), not a message to show.
  final bool reaction;
  final String reactionText;
  final List<DeltaFile> files;

  /// Unprotected hint only. Author and signed ID authorize completion.
  final bool postMessage;
  String? get postMessageId => deltaMessageId(header('chat-post-message-id'));
  DeltaPendingFile? get pending =>
      DeltaPendingFile.parse(header('chat-post-message-metadata'));

  String? header(String name) => headers[name];

  bool get isChat => header('chat-version') != null;

  /// The Securejoin step (`vc-request`, `vc-auth-required`, …), if any.
  String? get secureJoin => header('secure-join')?.trim().toLowerCase();
}

/// Writing and reading Delta Chat mail.
abstract final class DeltaMail {
  /// Largest mail read as a Delta Chat message.
  static const int maxBytes = 2 * 1024 * 1024;

  /// Most gossiped keys read from one mail.
  static const int maxGossip = 64;

  /// Signature checks spent reading the keys in one mail (an honest key
  /// costs two).
  static const int maxKeyChecks = 160;

  /// A new Message-ID (without brackets) at [domain].
  static String newMessageId(String domain, Random random) {
    const alphabet =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    String token(int length) => List.generate(
      length,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
    return 'Mr.${token(11)}.${token(11)}@$domain';
  }

  /// An encrypted, signed chat message from [from] to [to] (encrypted to
  /// [key]'s owner too): the RFC 5322 text, CRLF line endings.
  static Future<String> build({
    required PgpSecretKey key,
    required String from,
    String? fromName,
    required List<DeltaRecipient> to,
    required String text,
    required String messageId,
    required DateTime date,
    List<DeltaRecipient> gossip = const [],
    List<(String, String)> extraHeaders = const [],
    String? inReplyTo,
    bool requestReadReceipt = false,
    String? subject,
    Random? random,
    List<DeltaFile> files = const [],
    bool reaction = false,
    bool postMessage = false,
  }) async {
    if (files.length > DeltaLimits.attachments ||
        files.fold<int>(0, (sum, f) => sum + f.bytes.length) >
            DeltaLimits.fileBytes) {
      throw ArgumentError('Delta Chat files must be at most 21 MiB.');
    }
    final source = random ?? Random.secure();
    final boundary = mimeBoundary(source);
    final named = fromName == null || fromName.trim().isEmpty
        ? '<$from>'
        : '${encodeMimeWord(fromName.trim())} <$from>';
    final inner = [
      'Content-Type: multipart/mixed; boundary="$boundary"; '
          'protected-headers="v1"; hp="cipher"',
      'From: $named',
      foldedHeader(
        'To',
        to.map((recipient) => '<${recipient.addr}>').join(', '),
      ),
      'Subject: ${encodeMimeWord(subject ?? 'Message from ${fromName ?? from}')}',
      'Date: ${rfc5322Date(date)}',
      'Message-ID: <$messageId>',
      if (inReplyTo != null) ...[
        'In-Reply-To: <$inReplyTo>',
        'References: <$inReplyTo>',
      ],
      'Chat-Version: 1.0',
      if (requestReadReceipt) 'Chat-Disposition-Notification-To: $from',
      for (final (name, value) in extraHeaders) foldedHeader(name, value),
      foldedHeader(
        'Autocrypt',
        AutocryptHeader(
          addr: from,
          keydata: key.publicKey.bytes,
          mutual: true,
        ).encode(),
      ),
      for (final recipient in gossip)
        foldedHeader(
          'Autocrypt-Gossip',
          AutocryptHeader(
            addr: recipient.addr,
            keydata: recipient.key.bytes,
          ).encode(),
        ),
      '',
      '--$boundary',
      'Content-Type: text/plain; charset="utf-8"',
      if (reaction) 'Content-Disposition: reaction',
      'Content-Transfer-Encoding: base64',
      '',
      base64Lines(utf8.encode(text)),
      for (final file in files) ...[
        '--$boundary',
        'Content-Type: ${sanitizeAttachmentMimeType(file.mimeType)}',
        "Content-Disposition: attachment; filename*=utf-8''${Uri.encodeComponent(sanitizeAttachmentFileName(file.name))}",
        'Content-Transfer-Encoding: base64',
        '',
        base64Lines(file.bytes),
      ],
      '--$boundary--',
      '',
    ].join('\r\n');
    final encrypted = await Pgp.encrypt(
      Uint8List.fromList(utf8.encode(inner)),
      [for (final recipient in to) recipient.key],
      signer: key,
      random: random,
      now: date,
    );
    return _encryptedEnvelope(
      from: from,
      messageId: messageId,
      date: date,
      armored: OpenPgpArmor.encode(encrypted),
      random: source,
      postMessage: postMessage,
    );
  }

  static String _encryptedEnvelope({
    required String from,
    required String messageId,
    required DateTime date,
    required String armored,
    required Random random,
    bool postMessage = false,
  }) {
    final boundary = mimeBoundary(random);
    return [
      'From: <$from>',
      'To: "hidden-recipients": ;',
      'Subject: [...]',
      if (postMessage) 'Chat-Is-Post-Message: 1',
      'Date: ${rfc5322Date(date)}',
      'Message-ID: <$messageId>',
      'Chat-Version: 1.0',
      'MIME-Version: 1.0',
      'Content-Type: multipart/encrypted; '
          'protocol="application/pgp-encrypted"; boundary="$boundary"',
      '',
      '--$boundary',
      'Content-Type: application/pgp-encrypted',
      'Content-Description: PGP/MIME version identification',
      '',
      'Version: 1',
      '',
      '--$boundary',
      'Content-Type: application/octet-stream; name="encrypted.asc"',
      'Content-Description: OpenPGP encrypted message',
      'Content-Disposition: inline; filename="encrypted.asc"',
      '',
      armored.trimRight(),
      '',
      '--$boundary--',
      '',
    ].join('\r\n');
  }

  /// The unencrypted first Securejoin message ([step] `vc-request` or
  /// `vg-request`), in the one shape chatmail servers accept unencrypted:
  /// a multipart/mixed with a single text part saying the step.
  static String buildRequest({
    required PgpSecretKey key,
    required String from,
    required String to,
    required String step,
    required String invitenumber,
    required String messageId,
    required DateTime date,
    Random? random,
  }) {
    final boundary = mimeBoundary(random ?? Random.secure());
    return [
      'From: <$from>',
      'To: <$to>',
      'Subject: Message from $from',
      'Date: ${rfc5322Date(date)}',
      'Message-ID: <$messageId>',
      'Chat-Version: 1.0',
      'Secure-Join: $step',
      'Secure-Join-Invitenumber: $invitenumber',
      foldedHeader(
        'Autocrypt',
        AutocryptHeader(
          addr: from,
          keydata: key.publicKey.bytes,
          mutual: true,
        ).encode(),
      ),
      'MIME-Version: 1.0',
      'Content-Type: multipart/mixed; boundary="$boundary"',
      '',
      '--$boundary',
      'Content-Type: text/plain; charset="utf-8"',
      '',
      'Secure-Join: $step',
      '--$boundary--',
      '',
    ].join('\r\n');
  }

  /// A Securejoin v3 message ([step] `vc-request-pubkey` or `vc-pubkey`)
  /// encrypted with the invite's shared secret [password]; `vc-pubkey`
  /// carries and is signed by [key], `vc-request-pubkey` is not.
  static Future<String> buildSecureJoinV3({
    required PgpSecretKey key,
    required String from,
    required String to,
    required String step,
    required String auth,
    required String password,
    required bool attachKey,
    required String messageId,
    required DateTime date,
    Random? random,
  }) async {
    final source = random ?? Random.secure();
    final inner = [
      'Content-Type: text/plain; charset="utf-8"; protected-headers="v1"; '
          'hp="cipher"',
      'From: <$from>',
      'To: <$to>',
      'Subject: Secure-Join',
      'Date: ${rfc5322Date(date)}',
      'Message-ID: <$messageId>',
      'Chat-Version: 1.0',
      'Secure-Join: $step',
      'Secure-Join-Auth: $auth',
      if (attachKey)
        foldedHeader(
          'Autocrypt',
          AutocryptHeader(
            addr: from,
            keydata: key.publicKey.bytes,
            mutual: true,
          ).encode(),
        ),
      '',
      'Secure-Join',
      '',
    ].join('\r\n');
    final encrypted = await Pgp.encryptWithPassword(
      Uint8List.fromList(utf8.encode(inner)),
      utf8.encode(password),
      signer: attachKey ? key : null,
      random: random,
      now: date,
    );
    return _encryptedEnvelope(
      from: from,
      messageId: messageId,
      date: date,
      armored: OpenPgpArmor.encode(encrypted),
      random: source,
    );
  }

  /// A read receipt (MDN, RFC 8098) for [original], encrypted like a chat
  /// message.
  static Future<String> buildReadReceipt({
    required PgpSecretKey key,
    required String from,
    required DeltaRecipient to,
    required String original,
    List<String> additional = const [],
    required String messageId,
    required DateTime date,
    Random? random,
  }) async {
    final source = random ?? Random.secure();
    final boundary = mimeBoundary(source);
    final inner = [
      'Content-Type: multipart/report; report-type=disposition-notification; '
          'boundary="$boundary"; protected-headers="v1"; hp="cipher"',
      'From: <$from>',
      'To: <${to.addr}>',
      'Subject: Receipt Notification',
      'Date: ${rfc5322Date(date)}',
      'Message-ID: <$messageId>',
      'Chat-Version: 1.0',
      foldedHeader(
        'Autocrypt',
        AutocryptHeader(
          addr: from,
          keydata: key.publicKey.bytes,
          mutual: true,
        ).encode(),
      ),
      '',
      '--$boundary',
      'Content-Type: text/plain; charset="utf-8"',
      '',
      'This is a receipt notification.',
      '--$boundary',
      'Content-Type: message/disposition-notification',
      '',
      'Original-Message-ID: <$original>',
      'Disposition: manual-action/MDN-sent-automatically; displayed',
      if (additional.isNotEmpty)
        foldedHeader(
          'Additional-Message-IDs',
          additional.map((id) => '<$id>').join(' '),
        ),
      '',
      '--$boundary--',
      '',
    ].join('\r\n');
    final encrypted = await Pgp.encrypt(
      Uint8List.fromList(utf8.encode(inner)),
      [to.key],
      signer: key,
      random: random,
      now: date,
    );
    return _encryptedEnvelope(
      from: from,
      messageId: messageId,
      date: date,
      armored: OpenPgpArmor.encode(encrypted),
      random: source,
    );
  }

  /// Reads [raw]: null when it is not mail Conest can read as Delta Chat
  /// (not MIME, encrypted to another key, a From that does not match).
  /// [knownKeys] gives keys already known for an address, to check
  /// signatures by.
  static Future<DeltaIncoming?> read(
    Uint8List raw,
    PgpSecretKey key, {
    Future<List<PgpPublicKey>> Function(String addr)? knownKeys,
    List<String> passwords = const [],
    DateTime? now,
  }) async {
    try {
      return await _read(raw, key, knownKeys, passwords, now);
    } on RangeError {
      return null; // damaged beyond what the parsers check
    } on ArgumentError {
      return null;
    }
  }

  static Future<DeltaIncoming?> _read(
    Uint8List raw,
    PgpSecretKey key,
    Future<List<PgpPublicKey>> Function(String addr)? knownKeys,
    List<String> passwords,
    DateTime? now,
  ) async {
    if (raw.length > DeltaLimits.fileMailBytes) return null;
    final MimeEntity outer;
    try {
      outer = MimeEntity.parse(raw, maxDecodedBytes: DeltaLimits.fileMailBytes);
    } on FormatException {
      return null;
    }
    final outerFrom = parseMailAddress(outer.headers['from']);
    if (outerFrom == null) return null;

    var headers = outer.headers;
    var content = outer;
    var encrypted = false;
    PgpDecrypted? decrypted;
    String? password;
    if (outer.mimeType == 'multipart/encrypted') {
      final armored = outer.parts
          .map((part) => latin1.decode(part.body))
          .where((text) => text.contains('-----BEGIN PGP MESSAGE-----'))
          .firstOrNull;
      if (armored == null) return null;
      try {
        final bytes = OpenPgpArmor.decode(armored);
        final packets = OpenPgpSymmetric.readPackets(bytes);
        if (packets.any((packet) => packet.$1 == 3)) {
          // Encrypted with a shared secret (Securejoin v3).
          final opened = await Pgp.decryptWithPasswords(bytes, [
            for (final secret in passwords) utf8.encode(secret),
          ], now: now);
          if (opened == null) return null;
          decrypted = opened.$1;
          password = utf8.decode(opened.$2);
        } else {
          decrypted = await Pgp.decrypt(
            bytes,
            key,
            now: now,
            maxPlaintextBytes: DeltaLimits.plaintextBytes,
          );
        }
        content = MimeEntity.parse(
          decrypted.data,
          maxDecodedBytes: DeltaLimits.fileBytes + maxBytes,
        );
      } on FormatException {
        return null;
      }
      encrypted = true;
      // Protected headers replace the outer ones, and only routing fields
      // come from outside: an outer Secure-Join or group header around
      // someone's signed message must not change what it means.
      final inner = {
        for (final (name, _) in content.headers.fields) name.toLowerCase(),
      };
      headers = MimeHeaders([
        for (final field in outer.headers.fields)
          if (!inner.contains(field.$1.toLowerCase()) &&
              const {
                'from',
                'message-id',
                'date',
                'autocrypt',
                'chat-version',
              }.contains(field.$1.toLowerCase()))
            field,
        for (final field in content.headers.fields)
          if (!const {
            'content-type',
            'content-transfer-encoding',
            'content-disposition',
            'mime-version',
          }.contains(field.$1.toLowerCase()))
            field,
      ]);
    }
    final to = [
      for (final address in splitAddressList(
        headers.raw('to').firstOrNull ?? '',
      ))
        ?parseMailAddress(address),
    ];
    if (to.length > DeltaLimits.members) return null;
    final from = parseMailAddress(headers['from']);
    if (from == null || from != outerFrom) return null;

    // One budget of signature checks for every key this mail carries: a
    // stranger's mail full of keys costs bounded time.
    final checks = PgpCheckBudget(maxKeyChecks);
    PgpPublicKey? autocryptKey;
    // The last two at most: each is a key to read.
    for (final value in headers.raw('autocrypt').reversed.take(2)) {
      final header = AutocryptHeader.parse(value);
      if (header == null || header.addr != from) continue;
      try {
        autocryptKey = await PgpPublicKey.parse(
          header.keydata,
          now: now,
          budget: checks,
        );
        break;
      } on FormatException {
        continue;
      }
    }
    PgpPublicKey? signer;
    final gossip = <String, PgpPublicKey>{};
    if (decrypted != null && decrypted.signed) {
      signer = await decrypted.verify([
        ?autocryptKey,
        ...?await knownKeys?.call(from),
      ]);
      if (signer != null) {
        // Only keys of the mail's own recipients, and not too many: each
        // costs two signature checks.
        final recipients = {
          for (final address in splitAddressList(
            headers.raw('to').firstOrNull ?? '',
          ))
            ?parseMailAddress(address),
        };
        var parsed = 0;
        for (final value in content.headers.raw('autocrypt-gossip')) {
          final header = AutocryptHeader.parse(value);
          if (header == null ||
              !recipients.contains(header.addr) ||
              gossip.containsKey(header.addr)) {
            continue;
          }
          if (++parsed > maxGossip) break;
          try {
            gossip[header.addr] = await PgpPublicKey.parse(
              header.keydata,
              now: now,
              budget: checks,
            );
          } on FormatException {
            continue;
          }
        }
      }
    }

    final receiptsFor = <String>[];
    if (content.mimeType == 'multipart/report' &&
        content.parameters['report-type'] == 'disposition-notification') {
      for (final part in content.parts) {
        if (part.mimeType != 'message/disposition-notification') continue;
        final fields = MimeHeaders.parse(latin1.decode(part.body));
        receiptsFor.addAll([
          ?_bareMessageId(fields['original-message-id']),
          for (final match in RegExp(
            r'<([^<>\s]+)>',
          ).allMatches(fields['additional-message-ids'] ?? '').take(100))
            match.group(1)!,
        ]);
      }
    }
    final files = <DeltaFile>[];
    var reaction = false;
    var reactionText = '';
    var decoded = 0;
    final voice = headers['chat-voice-message'] == '1';
    final duration = deltaDuration(headers['chat-duration']);
    final sticker = headers['chat-content'] == 'sticker';
    var invalidFiles = false;
    void walk(MimeEntity entity) {
      if (entity.isMultipart) {
        entity.parts.forEach(walk);
        return;
      }
      if (entity.disposition == 'reaction' && entity.mimeType == 'text/plain') {
        reaction = true;
        reactionText = deltaReaction(entity.text);
        return;
      }
      final name = entity.fileName;
      if (entity.disposition == 'attachment' ||
          (name != null && entity.mimeType != 'text/plain')) {
        decoded += entity.body.length;
        if (files.length >= DeltaLimits.attachments ||
            decoded > DeltaLimits.fileBytes) {
          invalidFiles = true;
          return;
        }
        final mime = deltaMimeType(entity.body);
        files.add(
          DeltaFile(
            name: sanitizeAttachmentFileName(name ?? 'attachment.bin'),
            bytes: entity.body,
            mimeType: mime,
            voice: voice && (mime.startsWith('audio/') || mime == 'video/mp4'),
            durationMs: duration,
            sticker: sticker && mime.startsWith('image/'),
          ),
        );
      }
    }

    if (receiptsFor.isEmpty) walk(content);
    if (invalidFiles || (raw.length > maxBytes && files.isEmpty)) return null;

    final messageId = _bareMessageId(headers['message-id']);
    if (messageId == null) return null;
    return DeltaIncoming._(
      from: from,
      fromName: _displayName(headers['from']),
      to: to,
      intendedFor: [
        for (final fingerprint in decrypted?.intendedRecipients ?? const [])
          fingerprint
              .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
              .join()
              .toUpperCase(),
      ],
      messageId: messageId,
      date: parseRfc5322Date(headers['date']),
      encrypted: encrypted,
      signer: signer,
      autocryptKey: autocryptKey,
      gossip: gossip,
      headers: headers,
      text: receiptsFor.isEmpty && !reaction ? _text(content) : '',
      password: password,
      receiptsFor: receiptsFor.take(100).toList(),
      attachments: [for (final file in files) file.name],
      files: files,
      reactionText: reactionText,
      postMessage: outer.headers['chat-is-post-message'] != null,
      reaction: reaction,
    );
  }

  /// The first text/plain part that is not an attachment, unflowed.
  static String _text(MimeEntity entity) {
    if (entity.isMultipart) {
      for (final part in entity.parts) {
        final text = _text(part);
        if (text.isNotEmpty) return text;
      }
      return '';
    }
    if (entity.mimeType != 'text/plain' ||
        entity.disposition == 'attachment' ||
        entity.disposition == 'reaction') {
      return '';
    }
    var text = entity.text.replaceAll('\r\n', '\n');
    if (entity.parameters['format']?.toLowerCase() == 'flowed') {
      final deleteSpace = entity.parameters['delsp']?.toLowerCase() == 'yes';
      final lines = text.split('\n');
      final out = StringBuffer();
      for (var index = 0; index < lines.length; index++) {
        var line = lines[index];
        if (line.startsWith(' ')) line = line.substring(1); // space-stuffed
        final soft = line.endsWith(' ') && line != '-- ';
        if (soft) {
          out.write(deleteSpace ? line.substring(0, line.length - 1) : line);
        } else {
          out.write(line);
          if (index < lines.length - 1) out.write('\n');
        }
      }
      text = out.toString();
    }
    return text.trimRight();
  }

  static String? _bareMessageId(String? value) {
    if (value == null) return null;
    final match = RegExp(r'<([^<>\s]+)>').firstMatch(value);
    final id = (match?.group(1) ?? value).trim();
    return id.isEmpty ||
            id.length > 250 ||
            id.contains(RegExp(r'[<>\s\x00-\x1f\x7f]'))
        ? null
        : id;
  }

  static String? _displayName(String? from) {
    if (from == null) return null;
    final angle = from.lastIndexOf('<');
    if (angle <= 0) return null;
    var name = from.substring(0, angle).trim();
    if (name.startsWith('"') && name.endsWith('"') && name.length >= 2) {
      name = name.substring(1, name.length - 1);
    }
    return name.isEmpty ? null : name;
  }
}

/// A Date header value (RFC 5322), in UTC.
String rfc5322Date(DateTime time) {
  final utc = time.toUtc();
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  String two(int value) => value.toString().padLeft(2, '0');
  return '${days[utc.weekday - 1]}, ${utc.day} ${_months[utc.month - 1]} '
      '${utc.year} ${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} '
      '+0000';
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Reads a Date header value; null when it does not parse.
DateTime? parseRfc5322Date(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|[A-Za-z]+)?',
  ).firstMatch(value);
  if (match == null) return null;
  final month = _months.indexWhere(
    (name) => name.toLowerCase() == match.group(2)!.toLowerCase(),
  );
  if (month < 0) return null;
  var time = DateTime.utc(
    int.parse(match.group(3)!),
    month + 1,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.tryParse(match.group(6) ?? '') ?? 0,
  );
  final zone = match.group(7);
  if (zone != null && (zone.startsWith('+') || zone.startsWith('-'))) {
    final minutes =
        int.parse(zone.substring(1, 3)) * 60 + int.parse(zone.substring(3, 5));
    time = time.subtract(
      Duration(minutes: zone.startsWith('+') ? minutes : -minutes),
    );
  }
  return time;
}

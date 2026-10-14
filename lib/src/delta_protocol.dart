/// Delta Chat's protocol over an email account, as pure state changes:
/// Securejoin (setup-contact and join-group, both sides), one-to-one and
/// group messages, member changes and read receipts. Each call takes the
/// chats and returns them changed, with the mail to send.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'delta_chats.dart';
import 'email/carrier_mail.dart' show isPlausibleMailAddress, parseMailAddress;
import 'email/delta_mail.dart';
import 'email/delta_content.dart';
import 'models.dart' show AttachmentDescriptor;

import 'email/mime.dart' show encodeMimeWord, splitAddressList;
import 'email/pgp.dart';

part 'delta_protocol_content.dart';

/// Mail to send: its recipients' addresses and the message text.
class DeltaOutgoingMail {
  const DeltaOutgoingMail({
    required this.to,
    required this.mail,
    this.chatKey,
    this.messageId,
  });

  final List<String> to;
  final String mail;

  /// The chat message it carries, to mark failed if it cannot go.
  final String? chatKey;
  final String? messageId;
}

/// What a call changed.
class DeltaStep {
  const DeltaStep(
    this.chats, {
    this.mails = const [],
    this.consumed = false,
    this.chatKey,
    this.retry = false,
  });

  final DeltaChats chats;
  final List<DeltaOutgoingMail> mails;

  /// The mail read was Delta Chat's and may be deleted from the server.
  final bool consumed;

  /// Recognized mail that must be retried after a transient storage failure.
  final bool retry;

  /// The chat the call made or wrote in, if any.
  final String? chatKey;
}

/// A Delta Chat invite (QR code or link): a contact's, or a group's.
class DeltaInvite {
  const DeltaInvite({
    required this.fingerprint,
    required this.addr,
    required this.auth,
    this.name,
    this.invitenumber,
    this.groupId,
    this.groupName,
    this.v3 = true,
  });

  final String fingerprint;
  final String addr;
  final String auth;
  final String? name;

  /// Securejoin v3 (`v=3`, or no invite number): the first message is
  /// encrypted with a secret from the invite instead of sent in the clear.
  final bool v3;

  /// Absent in invites that only work with Securejoin v3.
  final String? invitenumber;
  final String? groupId;
  final String? groupName;

  bool get isGroup => groupId != null;

  /// Reads `OPENPGP4FPR:` codes and `https://i.delta.chat/#` links.
  static DeltaInvite? parse(String text) {
    var value = text.trim();
    const link = 'https://i.delta.chat/#';
    const linkNoSlash = 'https://i.delta.chat#';
    const scheme = 'openpgp4fpr:';
    String payload;
    if (value.toLowerCase().startsWith(link)) {
      payload = value.substring(link.length).replaceFirst('&', '#');
    } else if (value.toLowerCase().startsWith(linkNoSlash)) {
      payload = value.substring(linkNoSlash.length).replaceFirst('&', '#');
    } else if (value.toLowerCase().startsWith(scheme)) {
      payload = value.substring(scheme.length).replaceFirst('%23', '#');
    } else {
      return null;
    }
    final hash = payload.indexOf('#');
    final fingerprint = (hash < 0 ? payload : payload.substring(0, hash))
        .replaceAll(' ', '')
        .toUpperCase();
    if (!RegExp(r'^[0-9A-F]{40}$').hasMatch(fingerprint)) return null;
    final parameters = <String, String>{};
    for (final pair in (hash < 0 ? '' : payload.substring(hash + 1)).split(
      '&',
    )) {
      final equals = pair.indexOf('=');
      if (equals <= 0) continue;
      try {
        parameters[pair.substring(0, equals)] = Uri.decodeComponent(
          pair.substring(equals + 1).replaceAll('+', ' '),
        );
      } on ArgumentError {
        continue;
      }
    }
    final addr = parameters['a']?.trim().toLowerCase();
    final auth = parameters['s'];
    if (addr == null || !isPlausibleMailAddress(addr)) return null;
    if (auth == null || !_validToken(auth)) return null;
    final invitenumber = parameters['i'] ?? parameters['j'];
    final groupId = parameters['x'];
    final validNumber = invitenumber != null && _validToken(invitenumber);
    return DeltaInvite(
      v3: parameters['v'] == '3' || !validNumber,
      fingerprint: fingerprint,
      addr: addr,
      auth: auth,
      name: _shortName(parameters['n']),
      invitenumber: validNumber ? invitenumber : null,
      groupId: groupId != null && _validToken(groupId) ? groupId : null,
      groupName: _shortName(parameters['g']),
    );
  }

  /// The `https://i.delta.chat/#…` link for this invite (classic
  /// Securejoin: Delta Chat answers with the invite number).
  String toLink() {
    String encode(String value) =>
        Uri.encodeComponent(value).replaceAll('%20', '+');
    return [
      'https://i.delta.chat/#$fingerprint',
      if (v3) 'v=3',
      if (groupId != null) 'x=$groupId',
      if (invitenumber != null) 'i=$invitenumber',
      's=$auth',
      'a=${encode(addr)}',
      if (name != null) 'n=${encode(name!)}',
      if (groupName != null) 'g=${encode(groupName!)}',
    ].join('&');
  }

  static bool _validToken(String value) =>
      value.isNotEmpty &&
      value.length <= 64 &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

  static String? _shortName(String? name) => _cleanName(name);
}

/// Invite secrets of this account: one pair for contacts, one per group.
class DeltaTokens {
  const DeltaTokens({
    required this.invitenumber,
    required this.auth,
    this.groups = const {},
  });

  factory DeltaTokens.create(Random random) =>
      DeltaTokens(invitenumber: _token(random), auth: _token(random));

  final String invitenumber;
  final String auth;

  /// By group id: (invitenumber, auth).
  final Map<String, (String, String)> groups;

  /// Most groups with invites of their own; the oldest invite stops
  /// working past it (each one is a secret tried on incoming mail).
  static const int maxGroups = 50;

  DeltaTokens withGroup(String groupId, Random random) {
    if (groups.containsKey(groupId)) return this;
    final next = {...groups, groupId: (_token(random), _token(random))};
    while (next.length > maxGroups) {
      next.remove(next.keys.first);
    }
    return DeltaTokens(invitenumber: invitenumber, auth: auth, groups: next);
  }

  Map<String, dynamic> toJson() => {
    'invitenumber': invitenumber,
    'auth': auth,
    if (groups.isNotEmpty)
      'groups': {
        for (final MapEntry(:key, :value) in groups.entries)
          key: [value.$1, value.$2],
      },
  };

  static DeltaTokens? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final invitenumber = json['invitenumber'];
    final auth = json['auth'];
    if (invitenumber is! String || auth is! String) return null;
    final groups = json['groups'];
    return DeltaTokens(
      invitenumber: invitenumber,
      auth: auth,
      groups: {
        if (groups is Map<String, dynamic>)
          for (final MapEntry(:key, :value) in groups.entries)
            if (value is List &&
                value.length == 2 &&
                value[0] is String &&
                value[1] is String)
              key: (value[0] as String, value[1] as String),
      },
    );
  }
}

String _token(Random random) {
  const alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  return List.generate(
    24,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
}

/// Delta Chat for one email account and its key.
class DeltaProtocol {
  DeltaProtocol({
    required this.key,
    required this.self,
    required this.tokens,
    this.selfName,
    this.saveFile,
    DateTime Function()? now,
    Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  final PgpSecretKey key;

  /// This account's address (lower case).
  final String self;
  final String? selfName;

  /// A completed private cache write. Failure leaves file mail unconsumed.
  final Future<AttachmentDescriptor> Function(
    DeltaFile file,
    String chatKey,
    String messageId,
    int index,
  )?
  saveFile;
  DeltaTokens tokens;
  final DateTime Function() _now;
  final Random _random;

  /// Keys read before, by fingerprint (reading one checks signatures).
  final Map<String, PgpPublicKey> _keys = {};

  /// When this account answered invite requests lately (whoever has an
  /// invite can make it send mail): at most [maxAnswersPerHour].
  final List<DateTime> _answers = [];
  static const int maxAnswersPerHour = 30;

  bool _answerAllowed() {
    final now = _now();
    _answers.removeWhere((at) => now.difference(at) > const Duration(hours: 1));
    if (_answers.length >= maxAnswersPerHour) return false;
    _answers.add(now);
    return true;
  }

  /// Longest text kept from a message.
  static const int maxTextChars = 10000;

  String get fingerprint => key.publicKey.fingerprintHex;

  String get _domain => self.substring(self.indexOf('@') + 1);

  /// This account's contact invite.
  DeltaInvite get invite => DeltaInvite(
    fingerprint: fingerprint,
    addr: self,
    name: selfName,
    invitenumber: tokens.invitenumber,
    auth: tokens.auth,
  );

  /// The invite to group [chat] (this account must be in it).
  DeltaInvite groupInvite(DeltaChat chat) {
    tokens = tokens.withGroup(chat.groupId!, _random);
    final (invitenumber, auth) = tokens.groups[chat.groupId]!;
    return DeltaInvite(
      fingerprint: fingerprint,
      addr: self,
      name: selfName,
      invitenumber: invitenumber,
      auth: auth,
      groupId: chat.groupId,
      groupName: chat.name,
    );
  }

  /// Keys that did not read (expired, damaged), not read again.
  final Set<String> _unreadable = {};

  Future<PgpPublicKey?> _keyOf(DeltaPeer? peer) async {
    final bytes = peer?.key;
    if (peer == null || bytes == null) return null;
    final cached = _keys[peer.fingerprint];
    if (cached != null) return cached;
    if (_unreadable.contains(peer.fingerprint)) return null;
    try {
      final parsed = await PgpPublicKey.parse(bytes, now: _now());
      if (parsed.fingerprintHex == peer.fingerprint) {
        _remember(parsed);
        return parsed;
      }
    } on FormatException {
      // Remembered below.
    }
    if (_unreadable.length > 4000) _unreadable.remove(_unreadable.first);
    _unreadable.add(peer.fingerprint);
    return null;
  }

  void _remember(PgpPublicKey key) {
    _unreadable.remove(key.fingerprintHex);
    _keys.remove(key.fingerprintHex);
    // The longest unused go first.
    while (_keys.length >= 4000) {
      _keys.remove(_keys.keys.first);
    }
    _keys[key.fingerprintHex] = key;
  }

  DateTime _clamp(DateTime? date) {
    final now = _now().toUtc();
    if (date == null || date.isAfter(now.add(const Duration(minutes: 10)))) {
      return now;
    }
    return date;
  }

  String _newMessageId() => DeltaMail.newMessageId(_domain, _random);

  /// The shared secret of Securejoin v3 for an invite by [inviter].
  static String _secret(String inviter, String auth) =>
      'securejoin/$inviter/$auth';

  // Reading mail.

  /// Reads one mail from the inbox. Mail that is not Delta Chat's (or not
  /// for this key) is left alone: `consumed` false.
  Future<DeltaStep> receive(DeltaChats chats, Uint8List raw) async {
    final read = await DeltaMail.read(
      raw,
      key,
      // Only the sender's keys are read, and only when needed.
      // At most a few, verified ones first: anyone can gossip keys under
      // any address.
      knownKeys: (addr) async => [
        for (final peer
            in (chats.peers.values.where((peer) => peer.addr == addr).toList()
                  ..sort((a, b) => (b.verified ? 1 : 0) - (a.verified ? 1 : 0)))
                .take(4))
          ?await _keyOf(peer),
      ],
      passwords: [
        for (final join in chats.joins) _secret(join.fingerprint, join.auth),
        _secret(fingerprint, tokens.auth),
        for (final (_, auth) in tokens.groups.values)
          _secret(fingerprint, auth),
      ],
      now: _now(),
    );
    if (read == null || read.from == self) return DeltaStep(chats);
    final step = read.secureJoin;
    if (step != null && step != 'vg-member-added') {
      return _handshake(chats, read, step);
    }
    final signer = read.signer;
    // Chat messages are encrypted to this account's key (a secret from an
    // invite is known to whoever has the invite), signed, and say so with
    // Chat-Version; other mail (the user's own, say) is left alone.
    if (!read.encrypted ||
        signer == null ||
        read.password != null ||
        !read.isChat ||
        !_forMe(read)) {
      return DeltaStep(chats);
    }
    _remember(signer);
    var next = _learn(chats, read, signer);
    if (read.receiptsFor.isNotEmpty) {
      for (final chat in next.chats.values) {
        if (!chat.members.contains(signer.fingerprintHex)) continue;
        for (final id in read.receiptsFor) {
          next = next.markReadBy(chat.key, id);
        }
      }
      return DeltaStep(next, consumed: true);
    }
    final groupId = read.header('chat-group-id')?.trim();
    if (groupId != null && groupId.isNotEmpty && groupId.length <= 64) {
      return _groupMessage(next, read, signer, groupId);
    }
    final peer =
        next.peers[signer.fingerprintHex] ??
        DeltaPeer(fingerprint: signer.fingerprintHex, addr: read.from);
    final chatKey = signer.fingerprintHex;
    final control = _receiveControl(next, read, signer, chatKey);
    if (control != null) return control;
    return _receiveContent(
      next,
      read,
      signer,
      chatKey,
      () => DeltaChat(
        key: chatKey,
        members: [chatKey],
        name: peer.name,
        kept: peer.verified,
      ),
    );
  }

  /// Mail meant for this account: it is in the signed To, and the signature
  /// names it if it names anyone. A signed message forwarded to someone
  /// else is not theirs to take as written to them.
  bool _forMe(DeltaIncoming read) =>
      read.to.contains(self) &&
      (read.intendedFor.isEmpty || read.intendedFor.contains(fingerprint));

  /// The sender's key and gossiped keys remembered.
  DeltaChats _learn(DeltaChats chats, DeltaIncoming read, PgpPublicKey signer) {
    final stamp = _clamp(read.date);
    final old = chats.peers[signer.fingerprintHex];
    final freshAvatar =
        old?.avatarAt == null || !stamp.isBefore(old!.avatarAt!);
    final avatar = freshAvatar
        ? deltaAvatar(read.header('chat-user-avatar'))
        : null;
    final hasAvatar = avatar != null || read.header('chat-user-avatar') == '0';
    var next = chats.withPeer(
      DeltaPeer(
        fingerprint: signer.fingerprintHex,
        addr: read.from,
        key: signer.bytes,
        name: _shortName(read.fromName),
        avatar: avatar,
        avatarAt: freshAvatar && hasAvatar ? stamp : null,
      ),
    );
    if (freshAvatar &&
        read.header('chat-user-avatar') == '0' &&
        next.peers.containsKey(signer.fingerprintHex)) {
      next = next.copyWith(
        peers: {
          ...next.peers,
          signer.fingerprintHex: next.peers[signer.fingerprintHex]!.copyWith(
            clearAvatar: true,
          ),
        },
      );
    }
    // Gossip only for the message's own recipients, and only about people
    // not known yet: a gossiped key never moves someone to another address.
    var added = 0;
    for (final MapEntry(key: addr, value: gossiped) in read.gossip.entries) {
      if (addr == self ||
          gossiped.fingerprintHex == fingerprint ||
          !read.to.contains(addr)) {
        continue;
      }
      final known = next.peers[gossiped.fingerprintHex];
      if (known != null) {
        if (known.key == null) {
          _remember(gossiped);
          next = next.withPeer(known.copyWith(key: gossiped.bytes));
        }
        continue;
      }
      if (++added > 100 || next.peers.length >= DeltaChats.maxPeers) break;
      _remember(gossiped);
      next = next.withPeer(
        DeltaPeer(
          fingerprint: gossiped.fingerprintHex,
          addr: addr,
          key: gossiped.bytes,
        ),
      );
    }
    return next;
  }

  /// A group message: membership changes from members, then the text.
  Future<DeltaStep> _groupMessage(
    DeltaChats chats,
    DeltaIncoming read,
    PgpPublicKey signer,
    String groupId,
  ) async {
    final chatKey = DeltaChat.groupKey(groupId);
    final sender = signer.fingerprintHex;
    final existing = chats.chats[chatKey];
    final senderIsMember =
        existing == null || existing.members.contains(sender);
    final control = _receiveControl(chats, read, signer, chatKey);
    if (control != null) return control;
    // Finish an already accepted file even when membership changed in transit.
    // Its signed author can complete that placeholder, without changing the group.
    if (existing != null &&
        (!senderIsMember || existing.left) &&
        read.postMessageId == null &&
        read.files.isNotEmpty &&
        existing.messages.any(
          (m) =>
              m.id == read.messageId &&
              m.author == sender &&
              m.pending != null &&
              !m.deleted,
        )) {
      return _receiveContent(chats, read, signer, chatKey, () => existing);
    }
    final date = _clamp(read.date);
    final now = _now().toUtc();
    final stamp = date.isAfter(now) ? now : date;
    final membersAt = existing?.membersAt;
    final fresh = membersAt == null || !stamp.isBefore(membersAt);
    final merged = senderIsMember
        ? _mergeMembers(chats, existing, read, signer, stamp)
        : existing;
    final removedFpr = read.header('chat-group-member-removed-fpr')?.trim();
    final removedAddr = read.header('chat-group-member-removed')?.trim();
    final addedAddr = read
        .header('chat-group-member-added')
        ?.trim()
        .toLowerCase();
    final removedSelf =
        removedFpr?.toUpperCase() == fingerprint ||
        removedAddr?.toLowerCase() == self;
    final addedSelf = addedAddr == self;

    final freshAvatar =
        existing?.avatarAt == null || !date.isBefore(existing!.avatarAt!);
    final avatar = senderIsMember && freshAvatar
        ? deltaAvatar(read.header('chat-group-avatar'))
        : null;
    final hasAvatar = avatar != null || read.header('chat-group-avatar') == '0';
    var next = chats;
    var members = merged.members;
    var left = existing?.left ?? false;
    final selfAdded = merged.memberAdded[fingerprint];
    final selfRemoved = merged.memberRemoved[fingerprint];
    if (selfRemoved != null &&
        (selfAdded == null || selfRemoved.isAfter(selfAdded))) {
      left = true;
    } else if (selfAdded != null &&
        selfRemoved != null &&
        !selfAdded.isBefore(selfRemoved)) {
      left = false;
    }
    var kept = existing?.kept ?? false;
    var changed = false;
    final notes = <String>[];
    if (senderIsMember && fresh) {
      changed = true;
      if (removedSelf && left) {
        left = true;
        notes.add(sender == fingerprint ? 'You left.' : 'You were removed.');
      } else if (!left || addedSelf || existing == null) {
        if (removedFpr != null || removedAddr != null) {
          final gone =
              removedFpr?.toUpperCase() ??
              chats.peers.values
                  .where((peer) => peer.addr == removedAddr?.toLowerCase())
                  .map((peer) => peer.fingerprint)
                  .firstOrNull;
          final removedAt = merged.memberRemoved[gone];
          final addedAt = merged.additionDates[gone];
          if (removedAt != null &&
              (addedAt == null || removedAt.isAfter(addedAt))) {
            members.remove(gone);
          }
          if (gone != null) {
            notes.add('${_nameOf(next, gone)} left the group.');
          }
        }
        if (addedAddr != null && !addedSelf) {
          final named = read
              .header('chat-group-member-added-fpr')
              ?.trim()
              .toUpperCase();
          final added =
              named != null && RegExp(r'^[0-9A-F]{40}$').hasMatch(named)
              ? named
              : read.gossip[addedAddr]?.fingerprintHex;
          if (added != null && members.contains(added)) {
            notes.add('${_nameOf(next, added)} joined.');
          }
        }
        if (addedSelf &&
            (selfRemoved == null ||
                (selfAdded != null && !selfAdded.isBefore(selfRemoved)))) {
          left = false;
          // Being added after joining by invite, or by someone verified.
          kept =
              kept ||
              chats.joins.any(
                (join) => join.groupId == groupId && join.fingerprint == sender,
              ) ||
              (chats.peers[sender]?.verified ?? false);
          next = next.copyWith(
            joins: [
              for (final join in next.joins)
                if (join.groupId != groupId) join,
            ],
          );
        }
      }
    }
    final name =
        _shortName(read.header('chat-group-name')) ?? existing?.name ?? 'Group';
    final chat =
        (existing ??
                DeltaChat(
                  key: chatKey,
                  members: members,
                  groupId: groupId,
                  name: name,
                ))
            .copyWith(
              members: members,
              name: senderIsMember && fresh ? name : null,
              left: left,
              membersAt: changed ? stamp : null,
              memberAdded: merged.memberAdded,
              memberRemoved: merged.memberRemoved,
              pastAddresses: merged.pastAddresses,
              avatar: avatar,
              avatarAt: senderIsMember && freshAvatar && hasAvatar
                  ? date
                  : null,
              clearAvatar:
                  senderIsMember &&
                  freshAvatar &&
                  read.header('chat-group-avatar') == '0',
              kept:
                  kept ||
                  chats.chats.values.any(
                    (other) =>
                        other.kept && !other.isGroup && other.key == sender,
                  ),
            );
    next = next.withChat(chat);
    for (final (index, note) in notes.indexed) {
      next = next.add(
        chatKey,
        DeltaChatMessage(
          id: '${read.messageId}#$index',
          author: sender,
          text: note,
          at: date,
          info: true,
        ),
        create: () => chat,
      );
    }
    final isSystem =
        read.secureJoin != null ||
        addedAddr != null ||
        removedFpr != null ||
        removedAddr != null;
    // Only members write in a group, and only while this account is in it.
    if (!isSystem &&
        senderIsMember &&
        !left &&
        (read.text.isNotEmpty ||
            read.files.isNotEmpty ||
            read.postMessageId != null)) {
      return _receiveContent(next, read, signer, chatKey, () => chat);
    }
    return DeltaStep(next, consumed: true, chatKey: chatKey);
  }

  String _nameOf(DeltaChats chats, String fingerprint) {
    if (fingerprint == this.fingerprint) return 'You';
    final peer = chats.peers[fingerprint];
    return peer?.name ?? peer?.addr ?? fingerprint.substring(0, 8);
  }

  static String? _shortName(String? name) => _cleanName(name);

  // Securejoin.

  Future<DeltaStep> _handshake(
    DeltaChats chats,
    DeltaIncoming read,
    String step,
  ) async {
    switch (step) {
      case 'vc-request' || 'vg-request':
        return _onRequest(chats, read, step);
      case 'vc-auth-required' || 'vg-auth-required':
        return _onAuthRequired(chats, read);
      case 'vc-request-pubkey':
        return _onRequestPubkey(chats, read);
      case 'vc-pubkey':
        return _onAuthRequired(chats, read, v3: true);
      case 'vc-request-with-auth' || 'vg-request-with-auth':
        return _onRequestWithAuth(chats, read, step);
      case 'vc-contact-confirm':
        final signer = read.signer;
        if (!read.encrypted || signer == null || !_forMe(read)) {
          return DeltaStep(chats);
        }
        final peer = chats.peers[signer.fingerprintHex];
        if (peer == null || !peer.verified) return DeltaStep(chats);
        return DeltaStep(
          chats.withPeer(peer.copyWith(addr: read.from)),
          consumed: true,
          chatKey: peer.fingerprint,
        );
      default:
        // Securejoin v3 steps and others Conest does not speak yet.
        return DeltaStep(chats);
    }
  }

  /// Alice: someone scanned an invite and asks for it.
  Future<DeltaStep> _onRequest(
    DeltaChats chats,
    DeltaIncoming read,
    String step,
  ) async {
    final invitenumber = read.header('secure-join-invitenumber')?.trim();
    final bobKey = read.autocryptKey;
    if (invitenumber == null || bobKey == null || !read.to.contains(self)) {
      return DeltaStep(chats);
    }
    final matches =
        _same(invitenumber, tokens.invitenumber) ||
        tokens.groups.values.any((group) => _same(invitenumber, group.$1));
    // Only requests with the invite count toward the answer budget.
    if (!matches || !_answerAllowed()) return DeltaStep(chats);
    _remember(bobKey);
    // An unsigned request says nothing of whose key it is: someone known
    // keeps their address (the answer goes to the requester only).
    final next = chats.peers.containsKey(bobKey.fingerprintHex)
        ? chats
        : chats.withPeer(
            DeltaPeer(
              fingerprint: bobKey.fingerprintHex,
              addr: read.from,
              key: bobKey.bytes,
            ),
          );
    final messageId = _newMessageId();
    final recipient = (addr: read.from, key: bobKey);
    final mail = await DeltaMail.build(
      key: key,
      from: self,
      fromName: selfName,
      to: [recipient],
      gossip: [recipient],
      text: 'Secure-Join: ${step.substring(0, 2)}-auth-required',
      messageId: messageId,
      date: _now(),
      extraHeaders: [('Secure-Join', '${step.substring(0, 2)}-auth-required')],
      random: _random,
    );
    return DeltaStep(
      next,
      consumed: true,
      mails: [
        DeltaOutgoingMail(to: [read.from], mail: mail),
      ],
    );
  }

  /// Alice (v3): someone with an invite asks for this account's key, in a
  /// mail encrypted with the invite's secret.
  Future<DeltaStep> _onRequestPubkey(
    DeltaChats chats,
    DeltaIncoming read,
  ) async {
    final auth = read.header('secure-join-auth')?.trim();
    final password = read.password;
    // Delta Chat writes these with hidden recipients: the secret, not the
    // To header, says it is for this account.
    if (auth == null || password == null) return DeltaStep(chats);
    final known =
        _same(auth, tokens.auth) ||
        tokens.groups.values.any((group) => _same(auth, group.$2));
    // The secret it came with must be the one of that same auth code.
    if (!known ||
        !_same(password, _secret(fingerprint, auth)) ||
        !_answerAllowed()) {
      return DeltaStep(chats);
    }
    final mail = await DeltaMail.buildSecureJoinV3(
      key: key,
      from: self,
      to: read.from,
      step: 'vc-pubkey',
      auth: auth,
      password: password,
      attachKey: true,
      messageId: _newMessageId(),
      date: _now(),
      random: _random,
    );
    return DeltaStep(
      chats,
      consumed: true,
      mails: [
        DeltaOutgoingMail(to: [read.from], mail: mail),
      ],
    );
  }

  /// Bob: the inviter answered with their key; it must be the invite's
  /// (for v3, in a mail with the invite's secret, signed by that key).
  Future<DeltaStep> _onAuthRequired(
    DeltaChats chats,
    DeltaIncoming read, {
    bool v3 = false,
  }) async {
    final signer = read.signer;
    // v3 answers come with hidden recipients; the invite's secret and the
    // invite's key binding them stand in for the To check.
    if (!read.encrypted || signer == null || (!v3 && !_forMe(read))) {
      return DeltaStep(chats);
    }
    final join = chats.joins
        .where(
          (join) =>
              join.fingerprint == signer.fingerprintHex &&
              (!v3 ||
                  (read.password != null &&
                      _same(
                        read.password!,
                        _secret(join.fingerprint, join.auth),
                      ))),
        )
        .firstOrNull;
    if (join == null) return DeltaStep(chats);
    _remember(signer);
    var next = chats
        .withPeer(
          DeltaPeer(
            fingerprint: signer.fingerprintHex,
            addr: read.from,
            key: signer.bytes,
            verified: true,
          ),
        )
        .withoutJoin(join);
    final mails = [await _requestWithAuth(join, signer, read.from)];
    if (join.groupId != null) {
      // Kept until the inviter adds this account.
      next = next.withJoin(join);
    }
    return DeltaStep(
      next,
      consumed: true,
      mails: mails,
      chatKey: join.groupId == null
          ? signer.fingerprintHex
          : DeltaChat.groupKey(join.groupId!),
    );
  }

  Future<DeltaOutgoingMail> _requestWithAuth(
    DeltaJoin join,
    PgpPublicKey alice,
    String addr,
  ) async {
    final step = join.groupId == null
        ? 'vc-request-with-auth'
        : 'vg-request-with-auth';
    final recipient = (addr: addr, key: alice);
    final mail = await DeltaMail.build(
      key: key,
      from: self,
      fromName: selfName,
      to: [recipient],
      gossip: [recipient],
      text: 'Secure-Join: $step',
      messageId: _newMessageId(),
      date: _now(),
      extraHeaders: [
        ('Secure-Join', step),
        ('Secure-Join-Auth', join.auth),
        ('Secure-Join-Fingerprint', fingerprint),
        if (join.groupId != null) ('Secure-Join-Group', join.groupId!),
      ],
      random: _random,
    );
    return DeltaOutgoingMail(to: [addr], mail: mail);
  }

  /// Alice: the joiner proves they scanned the invite.
  Future<DeltaStep> _onRequestWithAuth(
    DeltaChats chats,
    DeltaIncoming read,
    String step,
  ) async {
    final signer = read.signer;
    final auth = read.header('secure-join-auth')?.trim();
    final claimed = read
        .header('secure-join-fingerprint')
        ?.trim()
        .toUpperCase();
    if (!read.encrypted ||
        signer == null ||
        auth == null ||
        claimed != signer.fingerprintHex ||
        !_forMe(read)) {
      return DeltaStep(chats);
    }
    // Delta Chat's guard against a forwarded request: it carries this
    // account's own key as gossip.
    if (read.gossip.values.every((key) => key.fingerprintHex != fingerprint)) {
      return DeltaStep(chats);
    }
    String? groupId;
    if (_same(auth, tokens.auth)) {
      if (step != 'vc-request-with-auth') return DeltaStep(chats);
    } else {
      groupId = tokens.groups.entries
          .where((entry) => _same(auth, entry.value.$2))
          .map((entry) => entry.key)
          .firstOrNull;
      if (groupId == null) return DeltaStep(chats);
    }
    _remember(signer);
    final bob = signer.fingerprintHex;
    var next = chats.withPeer(
      DeltaPeer(
        fingerprint: bob,
        addr: read.from,
        key: signer.bytes,
        name: _shortName(read.fromName),
        verified: true,
      ),
    );
    if (groupId == null) {
      final chat =
          next.chats[bob] ??
          DeltaChat(key: bob, members: [bob], name: _shortName(read.fromName));
      next = next.withChat(chat.copyWith(kept: true));
      final recipient = (addr: read.from, key: signer);
      final mail = await DeltaMail.build(
        key: key,
        from: self,
        fromName: selfName,
        to: [recipient],
        gossip: [recipient],
        text: 'Secure-Join: vc-contact-confirm',
        messageId: _newMessageId(),
        date: _now(),
        extraHeaders: [('Secure-Join', 'vc-contact-confirm')],
        random: _random,
      );
      return DeltaStep(
        next,
        consumed: true,
        chatKey: bob,
        mails: [
          DeltaOutgoingMail(to: [read.from], mail: mail),
        ],
      );
    }
    final chatKey = DeltaChat.groupKey(groupId);
    final chat = next.chats[chatKey];
    if (chat == null || chat.left) return DeltaStep(chats);
    return addMember(next, chatKey, bob, secureJoin: true);
  }

  /// Bob: starts joining with [invite] (scanned or pasted).
  Future<DeltaStep> join(DeltaChats chats, DeltaInvite invite) async {
    if (invite.addr == self || invite.fingerprint == fingerprint) {
      throw ArgumentError('This is your own invite.');
    }
    final peer = DeltaPeer(
      fingerprint: invite.fingerprint,
      addr: invite.addr,
      name: invite.name,
    );
    var next = chats.withPeer(peer);
    final chatKey = invite.groupId == null
        ? invite.fingerprint
        : DeltaChat.groupKey(invite.groupId!);
    // A group chat someone else made here before the user joined is not
    // trusted: joining starts it afresh from the inviter.
    final known = next.chats[chatKey];
    final existing =
        known != null &&
            known.kept &&
            (!invite.isGroup || known.members.contains(invite.fingerprint))
        ? known
        : null;
    next = next.withChat(
      (existing ??
              DeltaChat(
                key: chatKey,
                members: [invite.fingerprint],
                groupId: invite.groupId,
                name: invite.groupName ?? invite.name,
                left: invite.isGroup,
              ))
          .copyWith(kept: true),
    );
    final join = DeltaJoin(
      fingerprint: invite.fingerprint,
      addr: invite.addr,
      auth: invite.auth,
      at: _now().toUtc(),
      groupId: invite.groupId,
      groupName: invite.groupName,
    );
    // The inviter's key already known: straight to the proof.
    final alice = await _keyOf(next.peers[invite.fingerprint]);
    if (alice != null) {
      // The key known already is the invite's: verified by it.
      next = next.withPeer(
        next.peers[invite.fingerprint]!.copyWith(verified: true),
      );
      return DeltaStep(
        invite.isGroup ? next.withJoin(join) : next,
        chatKey: chatKey,
        mails: [await _requestWithAuth(join, alice, invite.addr)],
      );
    }
    if (invite.v3) {
      // Encrypted with the invite's secret: nothing goes in the clear.
      final mail = await DeltaMail.buildSecureJoinV3(
        key: key,
        from: self,
        to: invite.addr,
        step: 'vc-request-pubkey',
        auth: invite.auth,
        password: _secret(invite.fingerprint, invite.auth),
        attachKey: false,
        messageId: _newMessageId(),
        date: _now(),
        random: _random,
      );
      return DeltaStep(
        next.withJoin(join),
        chatKey: chatKey,
        mails: [
          DeltaOutgoingMail(to: [invite.addr], mail: mail),
        ],
      );
    }
    final invitenumber = invite.invitenumber!;
    final mail = DeltaMail.buildRequest(
      key: key,
      from: self,
      to: invite.addr,
      step: invite.isGroup ? 'vg-request' : 'vc-request',
      invitenumber: invitenumber,
      messageId: _newMessageId(),
      date: _now(),
      random: _random,
    );
    return DeltaStep(
      next.withJoin(join),
      chatKey: chatKey,
      mails: [
        DeltaOutgoingMail(to: [invite.addr], mail: mail),
      ],
    );
  }

  // Writing.

  /// Writes [text] in chat [chatKey].
  Future<DeltaStep> send(
    DeltaChats chats,
    String chatKey,
    String text, {
    String? inReplyTo,
  }) async {
    final chat = chats.chats[chatKey];
    if (chat == null) throw StateError('No such chat.');
    if (chat.left) throw StateError('You are not in this group.');
    final trimmed = text.trim();
    if (trimmed.isEmpty) return DeltaStep(chats);
    if (trimmed.length > maxTextChars) {
      throw ArgumentError('Too long ($maxTextChars characters at most).');
    }
    final recipients = await _recipients(chats, chat);
    if (recipients.isEmpty) {
      throw StateError(
        chat.isGroup
            ? 'Nobody in this group can be written to yet.'
            : 'Waiting for ${_nameOf(chats, chat.key)} to answer the '
                  'invite.',
      );
    }
    final messageId = _newMessageId();
    final now = _now();
    final mail = await DeltaMail.build(
      key: key,
      from: self,
      fromName: selfName,
      to: recipients,
      gossip: chat.isGroup ? recipients : const [],
      text: trimmed,
      messageId: messageId,
      date: now,
      inReplyTo: inReplyTo,
      requestReadReceipt: true,
      extraHeaders: chat.isGroup ? _groupHeaders(chat, recipients) : const [],
      subject: chat.isGroup ? chat.name : null,
      random: _random,
    );
    final next = chats.add(
      chatKey,
      DeltaChatMessage(
        id: messageId,
        author: fingerprint,
        text: trimmed,
        at: now.toUtc(),
        outgoing: true,
      ),
      create: () => chat,
    );
    return DeltaStep(
      next,
      chatKey: chatKey,
      mails: [
        DeltaOutgoingMail(
          to: [for (final recipient in recipients) recipient.addr],
          mail: mail,
          chatKey: chatKey,
          messageId: messageId,
        ),
      ],
    );
  }

  Future<List<DeltaRecipient>> _recipients(
    DeltaChats chats,
    DeltaChat chat, {
    Iterable<String> extra = const [],
  }) async {
    final recipients = <DeltaRecipient>[];
    for (final member in {...chat.members, ...extra}) {
      if (member == fingerprint) continue;
      final peer = chats.peers[member];
      final parsed = await _keyOf(peer);
      if (peer != null && parsed != null) {
        recipients.add((addr: peer.addr, key: parsed));
      }
    }
    return recipients;
  }

  List<(String, String)> _groupHeaders(
    DeltaChat chat,
    List<DeltaRecipient> recipients,
  ) {
    final past = chat.memberRemoved.entries
        .where(
          (e) =>
              e.value.isAfter(
                chat.additionDates[e.key] ??
                    DateTime.fromMillisecondsSinceEpoch(0),
              ) &&
              chat.pastAddresses.containsKey(e.key),
        )
        .take(DeltaLimits.members)
        .toList();
    int seconds(DateTime date) => date.millisecondsSinceEpoch ~/ 1000;
    return [
      ('Chat-Group-ID', chat.groupId!),
      ('Chat-Group-Name', encodeMimeWord(chat.name ?? 'Group')),
      if (past.isNotEmpty)
        (
          'Chat-Group-Past-Members',
          past.map((e) => '<${chat.pastAddresses[e.key]}>').join(', '),
        ),
      (
        'Chat-Group-Member-Fpr',
        [
          for (final r in recipients) r.key.fingerprintHex,
          for (final e in past) e.key,
        ].join(' '),
      ),
      (
        'Chat-Group-Member-Timestamps',
        [
          for (final r in recipients)
            seconds(
              chat.additionDates[r.key.fingerprintHex] ??
                  DateTime.fromMillisecondsSinceEpoch(0),
            ),
          for (final e in past) seconds(e.value),
        ].join(' '),
      ),
    ];
  }

  /// A new group with [name] and [members] (fingerprints of peers with
  /// keys); its first message announces it.
  Future<DeltaStep> createGroup(
    DeltaChats chats,
    String name,
    List<String> members,
  ) async {
    if (members.length > DeltaLimits.members - 1) {
      throw ArgumentError('Too many group members.');
    }
    final stamp = _memberClock(_now());
    final groupId = _token(_random);
    final chat = DeltaChat(
      key: DeltaChat.groupKey(groupId),
      members: [
        for (final member in {...members})
          if (member != fingerprint) member,
      ]..sort(),
      groupId: groupId,
      name: _shortName(name) ?? 'Group',
      kept: true,
      membersAt: stamp,
      memberAdded: {
        for (final m in {...members, fingerprint}) m: stamp,
      },
    );
    var next = chats.withChat(chat);
    if (chat.members.isEmpty) return DeltaStep(next, chatKey: chat.key);
    return _systemMessage(
      next,
      chat,
      'Group "${chat.name}" created.',
      const [],
    );
  }

  /// Adds [member] to group [chatKey], telling everyone (and them, with
  /// everyone's keys).
  Future<DeltaStep> addMember(
    DeltaChats chats,
    String chatKey,
    String member, {
    bool secureJoin = false,
  }) async {
    final chat = chats.chats[chatKey];
    final peer = chats.peers[member];
    if (chat == null || !chat.isGroup || chat.left || peer == null) {
      throw StateError('Cannot add them to this group.');
    }
    if (!chat.members.contains(member) &&
        chat.members.length >= DeltaLimits.members - 1) {
      throw StateError('Too many group members.');
    }
    if (!chat.memberAdded.containsKey(member) &&
        !chat.memberRemoved.containsKey(member) &&
        {...chat.additionDates.keys, ...chat.memberRemoved.keys}.length >=
            DeltaLimits.members * 2) {
      throw StateError('Group member history is full. Create a new group.');
    }
    final removedAt = chat.memberRemoved[member] == null
        ? null
        : _memberClock(chat.memberRemoved[member]!);
    final addedAt = _memberClock(_now());
    final updated = chat.copyWith(
      memberAdded: {
        ...chat.additionDates,
        member: removedAt != null && removedAt.isAfter(addedAt)
            ? removedAt
            : addedAt,
      },
      members: {...chat.members, member}.toList()..sort(),
      membersAt: _now().toUtc(),
    );
    final next = chats.withChat(updated);
    return _systemMessage(
      next,
      updated,
      'Member ${peer.addr} added.',
      [
        ('Chat-Group-Member-Added', peer.addr),
        ('Chat-Group-Member-Added-Fpr', member),
        if (secureJoin) ('Secure-Join', 'vg-member-added'),
      ],
      note: '${_nameOf(chats, member)} joined.',
    );
  }

  /// Removes [member] from group [chatKey] (or leaves it, for this
  /// account's own fingerprint).
  Future<DeltaStep> removeMember(
    DeltaChats chats,
    String chatKey,
    String member,
  ) async {
    final chat = chats.chats[chatKey];
    if (chat == null || !chat.isGroup || chat.left) {
      throw StateError('Not a group you are in.');
    }
    final leaving = member == fingerprint;
    final addr = leaving ? self : chats.peers[member]?.addr;
    if (addr == null) throw StateError('Not in this group.');
    final oldAdd =
        chat.additionDates[member] ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final now = _memberClock(_now());
    final quantizedAdd = _memberClock(oldAdd);
    final removedAt = now.isAfter(quantizedAdd)
        ? now
        : quantizedAdd.add(const Duration(seconds: 1));
    final updated = chat.copyWith(
      members: [
        for (final m in chat.members)
          if (m != member) m,
      ],
      left: leaving,
      membersAt: now,
      memberRemoved: {...chat.memberRemoved, member: removedAt},
      pastAddresses: {...chat.pastAddresses, member: addr},
    );
    return _systemMessage(
      chats.withChat(updated),
      updated,
      leaving ? 'Group left.' : 'Member $addr removed.',
      [
        ('Chat-Group-Member-Removed', addr),
        ('Chat-Group-Member-Removed-Fpr', member),
      ],
      note: leaving ? 'You left.' : '${_nameOf(chats, member)} was removed.',
      extra: leaving ? const [] : [member],
    );
  }

  Future<DeltaStep> _systemMessage(
    DeltaChats chats,
    DeltaChat chat,
    String text,
    List<(String, String)> headers, {
    String? note,
    Iterable<String> extra = const [],
  }) async {
    final recipients = await _recipients(chats, chat, extra: extra);
    final messageId = _newMessageId();
    final now = _now();
    final mails = <DeltaOutgoingMail>[];
    if (recipients.isNotEmpty) {
      mails.add(
        DeltaOutgoingMail(
          to: [for (final recipient in recipients) recipient.addr],
          mail: await DeltaMail.build(
            key: key,
            from: self,
            fromName: selfName,
            to: recipients,
            gossip: recipients,
            text: text,
            messageId: messageId,
            date: now,
            extraHeaders: [..._groupHeaders(chat, recipients), ...headers],
            subject: chat.name,
            random: _random,
          ),
        ),
      );
    }
    final next = note == null
        ? chats
        : chats.add(
            chat.key,
            DeltaChatMessage(
              id: messageId,
              author: fingerprint,
              text: note,
              at: now.toUtc(),
              outgoing: true,
              info: true,
            ),
            create: () => chat,
          );
    return DeltaStep(next, mails: mails, chatKey: chat.key);
  }

  /// Chat [chatKey] read: read receipts to those who asked, one mail each.
  Future<DeltaStep> markRead(DeltaChats chats, String chatKey) async {
    final chat = chats.chats[chatKey];
    if (chat == null) return DeltaStep(chats);
    final owed = <String, List<String>>{};
    for (final message in chat.messages) {
      if (message.wantsReceipt && !message.outgoing) {
        (owed[message.author] ??= []).add(message.id);
      }
    }
    final mails = <DeltaOutgoingMail>[];
    // Receipts only once the chat is the user's: reading a stranger's
    // request does not tell them it was seen.
    if (chat.kept) {
      for (final MapEntry(key: author, value: ids) in owed.entries) {
        final peer = chats.peers[author];
        final parsed = await _keyOf(peer);
        if (peer == null || parsed == null) continue;
        final latest = ids.reversed.take(20).toList();
        mails.add(
          DeltaOutgoingMail(
            to: [peer.addr],
            mail: await DeltaMail.buildReadReceipt(
              key: key,
              from: self,
              to: (addr: peer.addr, key: parsed),
              original: latest.first,
              additional: latest.skip(1).toList(),
              messageId: _newMessageId(),
              date: _now(),
              random: _random,
            ),
          ),
        );
      }
    }
    return DeltaStep(chats.markRead(chatKey), mails: mails);
  }
}

/// Compares secrets in time that does not depend on where they differ.
bool _same(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var index = 0; index < a.length; index++) {
    difference |= a.codeUnitAt(index) ^ b.codeUnitAt(index);
  }
  return difference == 0;
}

/// A name from someone else (display name, group name): control
/// characters (line breaks above all) gone, at most 64 characters.
String? _cleanName(String? name) {
  final cleaned = name
      ?.replaceAll(RegExp(r'[\x00-\x1f\x7f\u0085\u2028\u2029]'), ' ')
      .trim();
  if (cleaned == null || cleaned.isEmpty) return null;
  return String.fromCharCodes(cleaned.runes.take(64));
}

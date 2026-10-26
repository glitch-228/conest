import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'omemo/omemo_engine.dart';
import 'omemo/omemo_suite.dart';
import 'omemo/omemo_xml.dart';
import 'xmpp_chats.dart';
import 'xmpp_omemo.dart';
import 'xmpp_session.dart';
import 'xmpp_socket.dart';
import 'xmpp_xml.dart';

/// The saved XMPP chats account (client mode).
class XmppClientConfig {
  const XmppClientConfig({
    required this.jid,
    required this.password,
    required this.resource,
    this.endpoints = const [],
  });

  final String jid;
  final String password;
  final String resource;
  final List<XmppEndpoint> endpoints;

  String get domain => jid.substring(jid.indexOf('@') + 1);

  Map<String, Object?> toJson() => {
    'jid': jid,
    'password': password,
    'resource': resource,
    if (endpoints.isNotEmpty)
      'endpoints': [for (final endpoint in endpoints) endpoint.toJson()],
  };

  static XmppClientConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final jid = json['jid'];
    final password = json['password'];
    final resource = json['resource'];
    if (jid is! String ||
        !isValidBareJid(jid) ||
        password is! String ||
        password.isEmpty ||
        resource is! String ||
        resource.isEmpty ||
        resource.length > 64) {
      return null;
    }
    final endpoints = json['endpoints'];
    return XmppClientConfig(
      jid: jid.toLowerCase(),
      password: password,
      resource: resource,
      endpoints: [
        if (endpoints is List)
          for (final endpoint in endpoints.take(8))
            ?XmppEndpoint.fromJson(endpoint),
      ],
    );
  }
}

/// Uploads [file] to an HTTP upload slot's PUT address with [headers].
typedef XmppHttpPut =
    Future<void> Function(Uri url, Map<String, String> headers, File file);

/// PUTs over HTTPS only, with a timeout.
Future<void> xmppHttpPut(
  Uri url,
  Map<String, String> headers,
  File file,
) async {
  if (url.scheme != 'https') {
    throw const XmppProtocolException('Upload address is not HTTPS.');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.putUrl(url);
    request.followRedirects = false;
    request.contentLength = await file.length();
    headers.forEach(request.headers.set);
    await request.addStream(file.openRead());
    final response = await request.close().timeout(const Duration(minutes: 5));
    await response.drain<void>();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Upload failed (${response.statusCode}).');
    }
  } finally {
    client.close(force: true);
  }
}

/// Headers an upload slot may set (XEP-0363 allows only these).
const Set<String> _uploadHeaders = {'authorization', 'cookie', 'expires'};

/// The XMPP client mode: the contact list, 1:1 chats, group chats (MUC),
/// history (MAM), copies of the account's other clients' messages
/// (carbons), delivery receipts and read markers, corrections,
/// retractions, replies, reactions and files (HTTP upload). Everything a
/// server or another account sends is checked: carbons and history only
/// from this account (or the room asked), corrections and retractions only
/// from the original sender, and sizes and counts are bounded.
class XmppChatClient {
  XmppChatClient({
    required this.session,
    required this.ownsSession,
    required XmppChats Function() chats,
    required void Function(XmppChats chats) save,
    required this.sendReadMarkers,
    this.omemo,
    this.httpPut = xmppHttpPut,
    this.log,
    DateTime Function()? now,
  }) : _chats = chats,
       _save = save,
       _now = now ?? DateTime.now;

  final XmppSession session;

  /// This client started the session (its own account) and stops it; a
  /// session shared with the carrier is left running.
  final bool ownsSession;
  final XmppChats Function() _chats;
  final void Function(XmppChats chats) _save;

  /// Whether read markers go out (Conest's read-receipt setting).
  final bool Function() sendReadMarkers;

  /// End-to-end encryption (OMEMO), if available.
  final XmppOmemo? omemo;
  final XmppHttpPut httpPut;
  final void Function(String line)? log;
  final DateTime Function() _now;

  /// Most history fetched per chat on each catch-up.
  static const int maxCatchUp = 200;

  /// Most open chat requests from strangers; more are dropped.
  static const int maxRequests = 100;

  /// Most group chats joined.
  static const int maxRooms = 50;

  String get jid => session.jid.toLowerCase();
  XmppChats get chats => _chats();

  bool _started = false;
  String? _uploadService;
  int? _uploadMaxBytes;
  final Map<String, String?> _mamQueries = {};

  /// Contacts with a presence subscription either way.
  final Map<String, String> _roster = {};

  bool get connected => session.state == XmppSessionState.connected;

  void start() {
    if (_started) return;
    _started = true;
    session.addListener(onStanza: _onStanza, onConnected: _onConnected);
    if (ownsSession) {
      session.start();
    } else {
      session.setPriority(0);
      if (connected) _onConnected(false);
    }
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    session.removeListener(onStanza: _onStanza, onConnected: _onConnected);
    if (ownsSession) await session.stop();
  }

  void _update(XmppChats Function(XmppChats chats) change) =>
      _save(change(_chats()));

  // Connection.

  void _onConnected(bool resumed) {
    if (resumed) return;
    unawaited(
      _setUp().catchError((Object error) {
        log?.call('XMPP chats: setup after connecting failed: $error');
      }),
    );
  }

  Future<void> _setUp() async {
    await Future.wait([
      _loadRoster(),
      _loadBlocklist(),
      _enableCarbons(),
      _discoverUpload(),
    ]);
    await _setUpOmemo();
    await _catchUp(null);
    final rooms = chats.chats.values.where(
      (chat) => chat.room && !chat.request,
    );
    for (final room in rooms.take(maxRooms)) {
      _joinPresence(room.jid, room.nick ?? _defaultNick);
      unawaited(
        _catchUp(room.jid).catchError((Object error) {
          log?.call('XMPP chats: history of ${room.jid} failed: $error');
        }),
      );
    }
  }

  Future<void> _setUpOmemo() async {
    final o = omemo;
    if (o == null) return;
    try {
      await o.setUp();
    } catch (error) {
      log?.call('XMPP chats: OMEMO could not be set up: $error');
    }
  }

  String get _defaultNick => jid.split('@').first;

  XmppElement _iq(String type, XmppElement child, {String? to}) => XmppElement(
    'iq',
    attributes: {'type': type, 'to': ?to},
    children: [child],
  );

  Future<void> _loadRoster() async {
    final result = await session.request(
      _iq('get', XmppElement('query', xmlns: XmppNs.roster)),
    );
    final names = <String, String>{};
    _roster.clear();
    for (final item
        in (result.child('query', XmppNs.roster)?.all('item') ??
                const <XmppElement>[])
            .take(5000)) {
      final contact = bareJid(item.attr('jid'));
      if (contact == null) continue;
      _roster[contact] = item.attr('subscription') ?? 'none';
      final name = item.attr('name');
      if (name != null && name.trim().isNotEmpty) {
        names[contact] = name.trim().substring(0, min(name.trim().length, 100));
      }
    }
    _update((chats) => chats.copyWith(names: names));
  }

  Future<void> _loadBlocklist() async {
    try {
      final result = await session.request(
        _iq('get', XmppElement('blocklist', xmlns: XmppNs.blocking)),
      );
      final blocked = {
        for (final item
            in (result.child('blocklist', XmppNs.blocking)?.all('item') ??
                    const <XmppElement>[])
                .take(1000))
          ?bareJid(item.attr('jid')),
      };
      _update((chats) => chats.copyWith(blocked: blocked));
    } on XmppStanzaError {
      // The server has no blocking; the local list still applies.
    }
  }

  Future<void> _enableCarbons() async {
    try {
      await session.request(
        _iq('set', XmppElement('enable', xmlns: XmppNs.carbons)),
      );
    } on XmppStanzaError {
      // No carbons on this server.
    }
  }

  Future<void> _discoverUpload() async {
    try {
      final items = await session.request(
        _iq(
          'get',
          XmppElement('query', xmlns: XmppNs.discoItems),
          to: session.domain,
        ),
      );
      final candidates = [
        session.domain,
        for (final item
            in (items.child('query', XmppNs.discoItems)?.all('item') ??
                    const <XmppElement>[])
                .take(20))
          ?item.attr('jid'),
      ];
      for (final candidate in candidates) {
        final info = await session.request(
          _iq(
            'get',
            XmppElement('query', xmlns: XmppNs.discoInfo),
            to: candidate,
          ),
        );
        final query = info.child('query', XmppNs.discoInfo);
        if (query == null) continue;
        if (query
            .all('feature')
            .any((f) => f.attr('var') == XmppNs.httpUpload)) {
          _uploadService = candidate;
          for (final form in query.all('x', XmppNs.dataForms)) {
            for (final field in form.all('field')) {
              if (field.attr('var') == 'max-file-size') {
                _uploadMaxBytes = int.tryParse(field.childText('value') ?? '');
              }
            }
          }
          return;
        }
      }
    } catch (error) {
      log?.call('XMPP chats: no file upload service: $error');
    }
  }

  /// Whether files can be sent (the server offers HTTP upload).
  bool get canSendFiles => _uploadService != null;

  /// History after the last message seen: this account's archive (null) or
  /// a room's, at most [maxCatchUp] messages.
  Future<void> _catchUp(String? room) async {
    final after = room == null
        ? chats.archiveLast
        : chats.chats[room]?.lastStanzaId;
    final queryId = session.newId();
    _mamQueries[queryId] = room;
    try {
      var fetched = 0;
      var cursor = after;
      while (fetched < maxCatchUp) {
        final result = await session.request(
          _iq(
            'set',
            XmppElement(
              'query',
              xmlns: XmppNs.mam,
              attributes: {'queryid': queryId},
              children: [
                XmppElement(
                  'set',
                  xmlns: XmppNs.rsm,
                  children: [
                    XmppElement('max', text: '50'),
                    if (cursor != null)
                      XmppElement('after', text: cursor)
                    // Without a position: the newest page only.
                    else
                      XmppElement('before'),
                  ],
                ),
              ],
            ),
            to: room,
          ),
          timeout: const Duration(seconds: 45),
        );
        final fin = result.child('fin', XmppNs.mam);
        final last = fin?.child('set', XmppNs.rsm)?.childText('last');
        fetched += 50;
        if (fin == null || fin.attr('complete') == 'true' || last == null) {
          break;
        }
        if (cursor == null) break;
        cursor = last;
      }
    } on XmppStanzaError catch (error) {
      log?.call('XMPP chats: no history for ${room ?? jid}: $error');
    } finally {
      // Late results of a finished query are not taken.
      Timer(const Duration(seconds: 5), () => _mamQueries.remove(queryId));
    }
  }

  // Incoming.

  void _onStanza(XmppElement stanza) {
    if (!_started) return;
    try {
      switch (stanza.name) {
        case 'message':
          _onMessage(stanza);
        case 'presence':
          _onPresence(stanza);
        case 'iq':
          _onRosterPush(stanza);
      }
    } catch (error) {
      log?.call('XMPP chats: a message could not be read: $error');
    }
  }

  void _onRosterPush(XmppElement iq) {
    final query = iq.child('query', XmppNs.roster);
    if (query == null) return;
    final names = {...chats.names};
    for (final item in query.all('item').take(100)) {
      final contact = bareJid(item.attr('jid'));
      if (contact == null) continue;
      if (item.attr('subscription') == 'remove') {
        _roster.remove(contact);
        names.remove(contact);
        continue;
      }
      _roster[contact] = item.attr('subscription') ?? 'none';
      final name = item.attr('name');
      if (name != null && name.trim().isNotEmpty) {
        names[contact] = name.trim().substring(0, min(name.trim().length, 100));
      }
    }
    _update((chats) => chats.copyWith(names: names));
  }

  void _onPresence(XmppElement presence) {
    final from = bareJid(presence.attr('from'));
    if (from == null) return;
    if (presence.attr('type') == 'subscribe') {
      // Someone the user writes with gets presence; strangers wait.
      final chat = chats.chats[from];
      if (chat != null && !chat.request) {
        _send(
          XmppElement(
            'presence',
            attributes: {'to': from, 'type': 'subscribed'},
          ),
        );
      }
    }
  }

  void _onMessage(XmppElement message, {DateTime? delayed, String? archiveId}) {
    final from = message.attr('from');
    final own = jid;
    // Copies of this account's own traffic: only from this account.
    for (final kind in const ['received', 'sent']) {
      final carbon = message.child(kind, XmppNs.carbons);
      if (carbon == null) continue;
      final sender = bareJid(from);
      if (sender != null && sender != own) return;
      final inner = carbon.child('forwarded', XmppNs.forward)?.child('message');
      if (inner != null) _onChatMessage(inner, carbonSent: kind == 'sent');
      return;
    }
    final result = message.child('result', XmppNs.mam);
    if (result != null) {
      final queryId = result.attr('queryid');
      if (queryId == null || !_mamQueries.containsKey(queryId)) return;
      final room = _mamQueries[queryId];
      final sender = bareJid(from);
      // Results of this account's archive come from it; a room's from it.
      if (room == null ? (sender != null && sender != own) : sender != room) {
        return;
      }
      final forwarded = result.child('forwarded', XmppNs.forward);
      final inner = forwarded?.child('message');
      if (inner == null) return;
      final stamp = DateTime.tryParse(
        forwarded?.child('delay', XmppNs.delay)?.attr('stamp') ?? '',
      );
      _onChatMessage(
        inner,
        delayed: stamp,
        archiveId: result.attr('id'),
        fromArchive: true,
        archiveRoom: room,
      );
      return;
    }
    _onChatMessage(message, delayed: delayed, archiveId: archiveId);
  }

  void _onChatMessage(
    XmppElement message, {
    bool carbonSent = false,
    DateTime? delayed,
    String? archiveId,
    bool fromArchive = false,
    String? archiveRoom,
    bool decrypted = false,
    XmppSecurity security = XmppSecurity.plain,
    String? securityNote,
  }) {
    final type = message.attr('type') ?? 'normal';
    final from = message.attr('from');
    final to = message.attr('to');
    final own = jid;
    if (type == 'error') {
      final id = message.attr('id');
      final peer = bareJid(from);
      if (id != null && peer != null) {
        _update(
          (chats) => chats.updateMessage(
            peer,
            (m) => m.outgoing && m.id == id,
            (m) => m.copyWith(state: XmppMessageState.failed),
          ),
        );
      }
      return;
    }
    if (type == 'headline') return;
    final room = type == 'groupchat';
    final fromBare = bareJid(from);
    if (fromBare == null && !(fromArchive && archiveRoom == null)) return;
    if (!decrypted && omemo != null && !room) {
      final encrypted = message.children
          .where(
            (child) =>
                child.name == 'encrypted' &&
                OmemoVersion.byNamespace(child.xmlns) != null,
          )
          .firstOrNull;
      if (encrypted != null) {
        final toBare = bareJid(to);
        final outgoingCopy = carbonSent || (fromBare ?? own) == own;
        final peer = outgoingCopy ? toBare : fromBare;
        if (peer == null || (peer == own && !outgoingCopy)) return;
        if (chats.blocked.contains(peer)) return;
        unawaited(
          _readEncrypted(
            message,
            encrypted,
            sender: outgoingCopy ? own : peer,
            peer: peer,
            carbonSent: carbonSent,
            delayed: delayed,
            archiveId: archiveId,
            fromArchive: fromArchive,
            archiveRoom: archiveRoom,
          ),
        );
        return;
      }
    }
    final String chatJid;
    final String sender;
    final bool outgoing;
    if (room) {
      chatJid = fromBare!;
      if (fromArchive && archiveRoom != chatJid) return;
      final chat = chats.chats[chatJid];
      // Only rooms this account joined.
      if (chat == null || !chat.room) return;
      sender = jidResource(from!) ?? '';
      outgoing = sender == (chat.nick ?? _defaultNick);
      final subject = message.child('subject');
      if (subject != null && message.child('body') == null) {
        final text = subject.text.trim();
        _update(
          (chats) => chats.withChat(
            chat.copyWith(
              title: text.isEmpty
                  ? null
                  : text.substring(0, min(text.length, 200)),
            ),
          ),
        );
        return;
      }
    } else {
      final toBare = bareJid(to);
      outgoing = carbonSent || (fromBare ?? own) == own;
      final peer = outgoing ? toBare : fromBare;
      if (peer == null || peer == own && !outgoing) return;
      chatJid = peer;
      sender = outgoing ? own : peer;
      if (chats.blocked.contains(peer)) return;
    }
    final stanzaId = archiveId ?? _stanzaIdBy(message, room ? chatJid : own);
    final at = _clampTime(delayed ?? _delayOf(message));
    if (!room && stanzaId != null && !carbonSent) {
      _update((chats) => chats.copyWith(archiveLast: stanzaId));
    }

    // Changes to earlier messages, each only by their own sender.
    final retract = message.child('retract', XmppNs.retract);
    if (retract != null) {
      final target = retract.attr('id');
      if (target != null) {
        _update(
          (chats) => chats.updateMessage(
            chatJid,
            (m) =>
                (room ? m.stanzaId == target : m.id == target) &&
                m.from == sender,
            (m) => m.copyWith(retracted: true, text: ''),
          ),
        );
      }
      return;
    }
    final reactions = message.child('reactions', XmppNs.reactions);
    if (reactions != null) {
      final target = reactions.attr('id');
      final emoji = {
        for (final reaction in reactions.all('reaction').take(16))
          if (reaction.text.trim().isNotEmpty &&
              reaction.text.trim().length <= 16)
            reaction.text.trim(),
      };
      if (target != null) {
        _update(
          (chats) => chats.updateMessage(
            chatJid,
            (m) => room ? m.stanzaId == target : m.id == target,
            (m) {
              final next = <String, Set<String>>{
                for (final MapEntry(:key, :value) in m.reactions.entries)
                  key: {...value}..remove(sender),
              };
              for (final symbol in emoji) {
                (next[symbol] ??= {}).add(sender);
              }
              next.removeWhere((_, senders) => senders.isEmpty);
              if (next.length > 32) return m;
              return m.copyWith(reactions: next);
            },
          ),
        );
      }
      return;
    }
    final replace = message.child('replace', XmppNs.correction);
    final body = message.childText('body');
    if (replace != null && body != null) {
      final target = replace.attr('id');
      if (target != null) {
        _update(
          (chats) => chats.updateMessage(
            chatJid,
            (m) =>
                m.id == target &&
                m.from == sender &&
                !m.retracted &&
                // A correction of an encrypted message must itself be
                // encrypted: a server could forge a plain one.
                (m.security == XmppSecurity.plain ||
                    (security != XmppSecurity.plain &&
                        security != XmppSecurity.unreadable)),
            (m) => m.copyWith(text: boundedXmppText(body), editedAt: at),
          ),
        );
      }
      return;
    }
    // Receipts and markers for this account's messages, from the peer.
    if (!room && !outgoing) {
      final received = message.child('received', XmppNs.receipts)?.attr('id');
      final displayed = message.child('displayed', XmppNs.markers)?.attr('id');
      if (received != null || displayed != null) {
        _update(
          (chats) => chats.updateMessage(
            chatJid,
            (m) => m.outgoing && m.id == (displayed ?? received),
            (m) => m.copyWith(
              state: displayed != null
                  ? XmppMessageState.read
                  : m.state == XmppMessageState.read
                  ? m.state
                  : XmppMessageState.delivered,
            ),
          ),
        );
      }
    }
    // A group chat invitation.
    if (!room && !outgoing) {
      final invite =
          bareJid(message.child('x', 'jabber:x:conference')?.attr('jid')) ??
          (message.child('x', XmppNs.mucUser)?.child('invite') != null
              ? fromBare
              : null);
      if (invite != null && !chats.chats.containsKey(invite)) {
        if (_requestCount() < maxRequests) {
          _update(
            (chats) => chats.withChat(
              XmppChat(jid: invite, room: true, request: true),
            ),
          );
        }
        return;
      }
    }
    final unreadable = security == XmppSecurity.unreadable;
    if ((body == null || body.trim().isEmpty) && !unreadable) return;
    final bodyText = body ?? '';
    final id =
        message.child('origin-id', XmppNs.stanzaId)?.attr('id') ??
        message.attr('id') ??
        stanzaId ??
        'x${at.microsecondsSinceEpoch}';
    if (room && outgoing) {
      // The room's copy of a message sent here: now it has the room's id.
      final existing = chats.chats[chatJid]?.messages.any(
        (m) => m.outgoing && m.id == id,
      );
      if (existing ?? false) {
        _update(
          (chats) => chats.updateMessage(
            chatJid,
            (m) => m.outgoing && m.id == id,
            (m) => m.copyWith(stanzaId: stanzaId, state: XmppMessageState.sent),
          ),
        );
        return;
      }
    }
    final known = chats.chats[chatJid];
    final request =
        !room && !outgoing && (known?.request ?? !_isContact(chatJid));
    if (known == null && request && _requestCount() >= maxRequests) return;
    final reply = message.child('reply', XmppNs.reply);
    final oob = message.child('x', XmppNs.oob)?.childText('url')?.trim();
    final fileUrl = oob != null && oob == bodyText.trim() && _isHttpsUrl(oob)
        ? oob
        : null;
    _update(
      (chats) => chats.addMessage(
        chatJid,
        XmppChatMessage(
          id: id,
          stanzaId: stanzaId,
          from: sender,
          text: boundedXmppText(bodyText),
          at: at,
          outgoing: outgoing,
          security: security,
          securityNote: securityNote,
          replyTo: reply?.attr('id'),
          replySnippet: () {
            final quoted = known?.messages
                .where(
                  (m) =>
                      m.id == reply?.attr('id') ||
                      m.stanzaId == reply?.attr('id'),
                )
                .firstOrNull;
            return quoted == null ? null : xmppSnippet(quoted.text);
          }(),
          fileUrl: fileUrl,
        ),
        room: room,
        request: request,
      ),
    );
    // Delivery receipts are answered (they say nothing about reading);
    // never for history or copies.
    if (!room &&
        !outgoing &&
        !fromArchive &&
        message.child('request', XmppNs.receipts) != null &&
        message.attr('id') != null &&
        !request) {
      _send(
        XmppElement(
          'message',
          attributes: {'to': from!, 'id': session.newId()},
          children: [
            XmppElement(
              'received',
              xmlns: XmppNs.receipts,
              attributes: {'id': message.attr('id')!},
            ),
            XmppElement('store', xmlns: XmppNs.hints),
          ],
        ),
      );
    }
  }

  /// Reads an encrypted message (in order, one at a time), then handles it
  /// as if it had arrived in the clear, marked with how it was protected.
  Future<void> _readEncrypted(
    XmppElement message,
    XmppElement encrypted, {
    required String sender,
    required String peer,
    required bool carbonSent,
    required DateTime? delayed,
    required String? archiveId,
    required bool fromArchive,
    required String? archiveRoom,
  }) async {
    final o = omemo!;
    try {
      final received = await o.decrypt(
        encrypted: encrypted,
        sender: sender,
        chat: peer,
      );
      if (!_started) return;
      if (received == null) return;
      final XmppElement merged;
      var security = XmppSecurity.plain;
      String? note;
      if (received.readable) {
        merged = omemoDecryptedMessage(message, received);
        if (received.trust == OmemoTrust.distrusted) {
          security = XmppSecurity.untrusted;
        } else {
          security = received.version == OmemoVersion.v2
              ? XmppSecurity.omemo2
              : XmppSecurity.legacyOmemo;
        }
      } else {
        merged = omemoDecryptedMessage(message, received);
        security = XmppSecurity.unreadable;
        note = received.failure;
      }
      _onChatMessage(
        merged,
        carbonSent: carbonSent,
        delayed: delayed,
        archiveId: archiveId,
        fromArchive: fromArchive,
        archiveRoom: archiveRoom,
        decrypted: true,
        security: security,
        securityNote: note,
      );
    } catch (error) {
      log?.call('XMPP chats: an encrypted message could not be read: $error');
    }
  }

  int _requestCount() =>
      chats.chats.values.where((chat) => chat.request).length;

  bool _isContact(String peer) {
    final subscription = _roster[peer];
    return subscription == 'both' ||
        subscription == 'from' ||
        subscription == 'to' ||
        (chats.chats[peer] != null && !chats.chats[peer]!.request);
  }

  static bool _isHttpsUrl(String value) {
    final url = Uri.tryParse(value);
    return url != null && url.scheme == 'https' && url.host.isNotEmpty;
  }

  String? _stanzaIdBy(XmppElement message, String by) {
    for (final element in message.all('stanza-id', XmppNs.stanzaId)) {
      if (element.attr('by')?.toLowerCase() == by) return element.attr('id');
    }
    return null;
  }

  DateTime? _delayOf(XmppElement message) => DateTime.tryParse(
    message.child('delay', XmppNs.delay)?.attr('stamp') ?? '',
  );

  /// The sender's time, unless it is in the future.
  DateTime _clampTime(DateTime? at) {
    final now = _now().toUtc();
    if (at == null) return now;
    return at.isAfter(now.add(const Duration(minutes: 10))) ? now : at.toUtc();
  }

  // Encryption.

  static XmppSecurity _securityOf(OmemoVersion version) =>
      version == OmemoVersion.v2
      ? XmppSecurity.omemo2
      : XmppSecurity.legacyOmemo;

  /// Whether a message to [chat] would be encrypted now. Fails (rather
  /// than answering "no") when that cannot be told.
  Future<bool> _wouldEncrypt(XmppChat chat) async =>
      await _versionFor(chat) != null;

  /// The OMEMO version to use for [chat], or null for plain messages.
  /// Throws when the contact's keys cannot be read: never falls back to
  /// plain text on its own.
  Future<OmemoVersion?> _versionFor(XmppChat chat) async {
    final o = omemo;
    if (o == null || chat.room || chat.encryption == XmppChatEncryption.off) {
      return null;
    }
    final version = await o.versionFor(chat.jid, refresh: true);
    if (version == null && chat.encryption == XmppChatEncryption.on) {
      throw StateError('${chat.jid} has no OMEMO devices.');
    }
    return version;
  }

  /// Moves the body of [stanza] into an OMEMO envelope when [chat] is
  /// encrypted. Returns the version used, or null when it stays plain.
  Future<OmemoVersion?> _encryptStanza(
    XmppChat chat,
    XmppElement stanza, {
    bool mustEncrypt = false,
  }) async {
    final o = omemo;
    final version = await _versionFor(chat);
    if (version == null) {
      if (mustEncrypt) {
        throw StateError('This chat is encrypted and cannot be corrected '
            'in the clear.');
      }
      return null;
    }
    if (o == null || o.engine == null) {
      throw StateError('Encryption is not ready yet.');
    }
    final body = stanza.child('body');
    if (body == null) return null;
    final reply = stanza.child('reply', XmppNs.reply);
    final inside = <XmppElement>[
      body,
      if (version == OmemoVersion.v2 && reply != null) reply,
    ];
    final plaintext = o.plaintextFor(
      version: version,
      to: chat.jid,
      content: inside,
      body: body.text,
    );
    final encrypted = await o.encrypt(
      jid: chat.jid,
      version: version,
      plaintext: plaintext,
    );
    stanza.children.removeWhere(inside.contains);
    for (final element in OmemoXml.fallback(version)) {
      stanza.add(element);
    }
    stanza.add(encrypted);
    return version;
  }

  /// Chooses how a chat is encrypted (the setting, not the keys).
  void setEncryption(String jid, XmppChatEncryption mode) {
    final chat = chats.chats[jid];
    if (chat == null || chat.room) return;
    _update((chats) => chats.withChat(chat.copyWith(encryption: mode)));
  }

  // Outgoing.

  void _send(XmppElement stanza) =>
      unawaited(session.send(stanza).catchError((Object _) {}));

  XmppChat _chat(String jid) {
    final chat = chats.chats[jid];
    if (chat == null) throw StateError('No such XMPP chat.');
    return chat;
  }

  XmppElement _message(XmppChat chat, String id) => XmppElement(
    'message',
    attributes: {
      'to': chat.jid,
      'type': chat.room ? 'groupchat' : 'chat',
      'id': id,
    },
  );

  /// Sends [text] to the chat [jid], as an answer to [replyTo] if given.
  Future<String> sendText(String jid, String text, {String? replyTo}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw ArgumentError('Nothing to send.');
    if (trimmed.length > XmppChats.maxTextChars) {
      throw ArgumentError('Too long for one message.');
    }
    final chat = _chat(jid);
    final id = session.newId();
    final quoted = replyTo == null
        ? null
        : chat.messages.where((m) => m.id == replyTo).firstOrNull;
    final stanza = _message(chat, id)
      ..add(XmppElement('body', text: trimmed))
      ..add(
        XmppElement(
          'origin-id',
          xmlns: XmppNs.stanzaId,
          attributes: {'id': id},
        ),
      )
      ..add(XmppElement('markable', xmlns: XmppNs.markers));
    if (!chat.room) stanza.add(XmppElement('request', xmlns: XmppNs.receipts));
    if (quoted != null) {
      stanza.add(
        XmppElement(
          'reply',
          xmlns: XmppNs.reply,
          attributes: {
            'id': chat.room ? (quoted.stanzaId ?? quoted.id) : quoted.id,
            'to': chat.room ? '${chat.jid}/${quoted.from}' : quoted.from,
          },
        ),
      );
    }
    _update(
      (chats) => chats.addMessage(
        jid,
        XmppChatMessage(
          id: id,
          from: chat.room ? (chat.nick ?? _defaultNick) : this.jid,
          text: trimmed,
          at: _now().toUtc(),
          outgoing: true,
          state: XmppMessageState.sending,
          replyTo: quoted?.id,
          replySnippet: quoted == null ? null : xmppSnippet(quoted.text),
        ),
        room: chat.room,
        countUnread: false,
      ),
    );
    try {
      final version = await _encryptStanza(chat, stanza);
      if (version != null) {
        _update(
          (chats) => chats.updateMessage(
            jid,
            (m) => m.outgoing && m.id == id,
            (m) => m.copyWith(security: _securityOf(version)),
          ),
        );
      }
      await session.send(stanza);
      _update(
        (chats) => chats.updateMessage(
          jid,
          (m) =>
              m.outgoing && m.id == id && m.state == XmppMessageState.sending,
          (m) => m.copyWith(state: XmppMessageState.sent),
        ),
      );
    } catch (error) {
      _update(
        (chats) => chats.updateMessage(
          jid,
          (m) => m.outgoing && m.id == id,
          (m) => m.copyWith(state: XmppMessageState.failed),
        ),
      );
      rethrow;
    }
    return id;
  }

  /// Corrects this account's message [id] (XEP-0308).
  Future<void> correct(String jid, String id, String text) async {
    final chat = _chat(jid);
    final original = chat.messages.where((m) => m.id == id).firstOrNull;
    if (original == null || !original.outgoing || original.retracted) {
      throw StateError('Only your own messages can be corrected.');
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length > XmppChats.maxTextChars) {
      throw ArgumentError('Not a valid correction.');
    }
    final correction = _message(chat, session.newId())
      ..add(XmppElement('body', text: trimmed))
      ..add(
        XmppElement(
          'replace',
          xmlns: XmppNs.correction,
          attributes: {'id': id},
        ),
      );
    // An encrypted message is only ever corrected in encrypted form.
    await _encryptStanza(
      chat,
      correction,
      mustEncrypt: original.security != XmppSecurity.plain,
    );
    await session.send(correction);
    _update(
      (chats) => chats.updateMessage(
        jid,
        (m) => m.id == id && m.outgoing,
        (m) => m.copyWith(text: trimmed, editedAt: _now().toUtc()),
      ),
    );
  }

  /// Retracts this account's message [id] (XEP-0424).
  Future<void> retract(String jid, String id) async {
    final chat = _chat(jid);
    final original = chat.messages.where((m) => m.id == id).firstOrNull;
    if (original == null || !original.outgoing) {
      throw StateError('Only your own messages can be retracted.');
    }
    final target = chat.room ? original.stanzaId : original.id;
    if (target == null) throw StateError('The room has not confirmed it yet.');
    await session.send(
      _message(chat, session.newId())
        ..add(
          XmppElement(
            'retract',
            xmlns: XmppNs.retract,
            attributes: {'id': target},
          ),
        )
        ..add(
          XmppElement(
            'fallback',
            xmlns: 'urn:xmpp:fallback:0',
            attributes: {'for': XmppNs.retract},
          ),
        )
        ..add(
          XmppElement(
            'body',
            text:
                'This person attempted to retract a previous message, '
                "but it's unsupported by your client.",
          ),
        )
        ..add(XmppElement('store', xmlns: XmppNs.hints)),
    );
    _update(
      (chats) => chats.updateMessage(
        jid,
        (m) => m.id == id && m.outgoing,
        (m) => m.copyWith(retracted: true, text: ''),
      ),
    );
  }

  /// Sets this account's reactions to message [id] (XEP-0444).
  Future<void> react(String jid, String id, Set<String> emoji) async {
    final chat = _chat(jid);
    final message = chat.messages.where((m) => m.id == id).firstOrNull;
    if (message == null) return;
    final target = chat.room ? message.stanzaId : message.id;
    if (target == null) throw StateError('The room has not confirmed it yet.');
    final me = chat.room ? (chat.nick ?? _defaultNick) : this.jid;
    await session.send(
      _message(chat, session.newId())
        ..add(
          XmppElement(
            'reactions',
            xmlns: XmppNs.reactions,
            attributes: {'id': target},
            children: [
              for (final symbol in emoji.take(16))
                XmppElement('reaction', text: symbol),
            ],
          ),
        )
        ..add(XmppElement('store', xmlns: XmppNs.hints)),
    );
    _update(
      (chats) => chats.updateMessage(jid, (m) => m.id == id, (m) {
        final next = <String, Set<String>>{
          for (final MapEntry(:key, :value) in m.reactions.entries)
            key: {...value}..remove(me),
        };
        for (final symbol in emoji) {
          (next[symbol] ??= {}).add(me);
        }
        next.removeWhere((_, senders) => senders.isEmpty);
        return m.copyWith(reactions: next);
      }),
    );
  }

  /// The chat [jid] was read: unread cleared, and a read marker sent for
  /// the newest message if the read-receipt setting allows.
  void markRead(String jid) {
    final chat = chats.chats[jid];
    if (chat == null) return;
    _update((chats) => chats.markRead(jid));
    if (!sendReadMarkers() || chat.request) return;
    final last = chat.messages
        .where((m) => !m.outgoing && !m.retracted)
        .lastOrNull;
    if (last == null) return;
    final target = chat.room ? last.stanzaId : last.id;
    if (target == null) return;
    _send(
      _message(chat, session.newId())
        ..add(
          XmppElement(
            'displayed',
            xmlns: XmppNs.markers,
            attributes: {'id': target},
          ),
        )
        ..add(XmppElement('store', xmlns: XmppNs.hints)),
    );
  }

  /// Starts (or opens) a 1:1 chat with [address].
  String startChat(String address) {
    final peer = parseXmppUri(address)?.jid ?? bareJid(address.trim());
    if (peer == null || !peer.contains('@') || peer == jid) {
      throw ArgumentError('Not an XMPP address: $address');
    }
    final existing = chats.chats[peer];
    if (existing == null) {
      _update((chats) => chats.withChat(XmppChat(jid: peer)));
    } else if (existing.request) {
      acceptRequest(peer);
    }
    _subscribe(peer);
    return peer;
  }

  void _subscribe(String peer) {
    _send(
      XmppElement('presence', attributes: {'to': peer, 'type': 'subscribe'}),
    );
  }

  /// Joins the group chat [address] (`room@server` or an `xmpp:` link) as
  /// [nick].
  String joinRoom(String address, {String? nick}) {
    final room = parseXmppUri(address)?.jid ?? bareJid(address.trim());
    if (room == null || !room.contains('@')) {
      throw ArgumentError('Not a group chat address: $address');
    }
    if (chats.chats.values.where((chat) => chat.room).length >= maxRooms &&
        !chats.chats.containsKey(room)) {
      throw StateError('At most $maxRooms group chats.');
    }
    final name = (nick ?? _defaultNick).trim();
    if (name.isEmpty || name.length > 64) {
      throw ArgumentError('Choose a nickname.');
    }
    _update(
      (chats) => chats.withChat(
        (chats.chats[room] ?? XmppChat(jid: room, room: true)).copyWith(
          request: false,
          nick: name,
        ),
      ),
    );
    if (connected) {
      _joinPresence(room, name);
      unawaited(_catchUp(room).catchError((Object _) {}));
    }
    return room;
  }

  void _joinPresence(String room, String nick) => _send(
    XmppElement(
      'presence',
      attributes: {'to': '$room/$nick'},
      children: [
        XmppElement(
          'x',
          xmlns: XmppNs.muc,
          // History comes from the archive instead.
          children: [
            XmppElement('history', attributes: {'maxstanzas': '0'}),
          ],
        ),
      ],
    ),
  );

  /// Leaves and forgets the chat [jid].
  void removeChat(String jid) {
    final chat = chats.chats[jid];
    if (chat == null) return;
    if (chat.room && !chat.request) {
      _send(
        XmppElement(
          'presence',
          attributes: {
            'to': '${chat.jid}/${chat.nick ?? _defaultNick}',
            'type': 'unavailable',
          },
        ),
      );
    }
    _update((chats) => chats.withoutChat(jid));
  }

  /// A stranger's chat becomes an ordinary one (a group chat invitation
  /// is joined).
  void acceptRequest(String jid) {
    final chat = chats.chats[jid];
    if (chat == null) return;
    if (chat.room) {
      joinRoom(jid);
      return;
    }
    _update((chats) => chats.withChat(chat.copyWith(request: false)));
    _send(
      XmppElement('presence', attributes: {'to': jid, 'type': 'subscribed'}),
    );
    _subscribe(jid);
  }

  /// Blocks [jid] on the server (XEP-0191) and drops its chat.
  Future<void> block(String jid) async {
    _update(
      (chats) =>
          chats.withoutChat(jid).copyWith(blocked: {...chats.blocked, jid}),
    );
    try {
      await session.request(
        _iq(
          'set',
          XmppElement(
            'block',
            xmlns: XmppNs.blocking,
            children: [
              XmppElement('item', attributes: {'jid': jid}),
            ],
          ),
        ),
      );
    } on XmppStanzaError catch (error) {
      log?.call('XMPP chats: the server could not block: $error');
    }
  }

  /// Sends the file at [path] (already a private, metadata-stripped copy)
  /// through the server's HTTP upload.
  Future<String> sendFile(String jid, File file, {String? contentType}) async {
    final service = _uploadService;
    if (service == null) throw StateError('This server takes no files.');
    if (await _wouldEncrypt(_chat(jid))) {
      throw StateError(
        'Files are not encrypted yet. Turn encryption off for this chat to '
        'send one.',
      );
    }
    final size = await file.length();
    if (_uploadMaxBytes case final max? when size > max) {
      throw ArgumentError(
        'The server takes files up to ${max ~/ (1024 * 1024)} MB.',
      );
    }
    final name = file.uri.pathSegments.last;
    final slot = await session.request(
      _iq(
        'get',
        XmppElement(
          'request',
          xmlns: XmppNs.httpUpload,
          attributes: {
            'filename': name.length > 100
                ? name.substring(name.length - 100)
                : name,
            'size': '$size',
            'content-type': contentType ?? 'application/octet-stream',
          },
        ),
        to: service,
      ),
    );
    final element = slot.child('slot', XmppNs.httpUpload);
    final put = Uri.tryParse(element?.child('put')?.attr('url') ?? '');
    final get = element?.child('get')?.attr('url');
    if (put == null ||
        get == null ||
        !_isHttpsUrl(get) ||
        put.scheme != 'https') {
      throw const XmppProtocolException('The upload slot is not usable.');
    }
    final headers = <String, String>{
      for (final header in element!.child('put')!.all('header').take(8))
        if (_uploadHeaders.contains(header.attr('name')?.toLowerCase()) &&
            !header.text.contains('\n'))
          header.attr('name')!: header.text,
    };
    await httpPut(put, headers, file);
    final chat = _chat(jid);
    final id = session.newId();
    await session.send(
      _message(chat, id)
        ..add(XmppElement('body', text: get))
        ..add(
          XmppElement(
            'x',
            xmlns: XmppNs.oob,
            children: [XmppElement('url', text: get)],
          ),
        )
        ..add(
          XmppElement(
            'origin-id',
            xmlns: XmppNs.stanzaId,
            attributes: {'id': id},
          ),
        ),
    );
    _update(
      (chats) => chats.addMessage(
        jid,
        XmppChatMessage(
          id: id,
          from: chat.room ? (chat.nick ?? _defaultNick) : this.jid,
          text: get,
          at: _now().toUtc(),
          outgoing: true,
          fileUrl: get,
        ),
        room: chat.room,
        countUnread: false,
      ),
    );
    return id;
  }
}

/// An `xmpp:` link: the address and what it asks (`join`, `message`).
class XmppUri {
  const XmppUri(this.jid, this.action);
  final String jid;
  final String? action;
}

XmppUri? parseXmppUri(String text) {
  final value = text.trim();
  if (!value.toLowerCase().startsWith('xmpp:')) return null;
  final rest = value.substring(5);
  final question = rest.indexOf('?');
  final address = Uri.decodeComponent(
    question < 0 ? rest : rest.substring(0, question),
  );
  final jid = bareJid(address);
  if (jid == null) return null;
  final action = question < 0
      ? null
      : rest.substring(question + 1).split(';').first;
  return XmppUri(jid, action);
}

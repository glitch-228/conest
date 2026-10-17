/// Automatic tests a debug build runs when started for them (Q6), so a
/// device can be tested from a shell over adb or ssh:
///
///   conest --debug-run=routes|messages|files|interactions|all|none
///          [--debug-name=NAME]            set up storage and an identity
///          [--debug-relay=HOST:PORT]      add a relay
///          [--debug-accept-invite=CODE]   add a contact (repeatable)
///          [--debug-approve]              approve contact requests
///          [--debug-serve=SECONDS]        wait this long for the others
///          [--debug-group=TITLE]          then make a group of everyone
///          [--debug-no-reserve]           files even on a nearly full disk
///          [--debug-linger=SECONDS]       stay online after the tests (until
///                                         every contact says it is done)
///          [--debug-expect-contacts=N]    stop waiting once N contacts can
///                                         be written to
///          [--debug-expect-group=TITLE]   wait (at most the serve time) to be
///                                         in that lab group, made elsewhere
///          [--debug-carriers=nostr,tor,email,bitchat,reticulum]
///                                         switch these carriers on first
///          [--debug-reticulum=HOST:PORT]  the Reticulum node to use
///          [--debug-chatmail=DOMAIN]      the chatmail server for email
///          [--debug-matrix=URL,USER,PASSWORD]  sign in to Matrix (lab
///                                         accounts on a lab homeserver)
///          [--debug-only-transport=KIND]  every other transport off (LAN
///                                         too), from before pairing: adds
///                                         contacts and talks over KIND
///          [--debug-report=PATH] [--debug-wait=20] [--debug-exit]
///   adb shell am start -n dev.conest.conest.debug/dev.conest.conest.MainActivity \
///       --es conestDebugArgs "--debug-run=all --debug-name=phone --debug-approve"
///
/// This device's invite is written next to the report (PATH.invite) as soon
/// as it has an identity, so a script can hand it to the other devices
/// while this one waits. Messages and files go to every contact and to
/// every group named lab-*, then everything is written down in one JSON
/// report (with the error history) at PATH, or next to the app's files.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'email_carrier.dart' show defaultChatmailDomains;
import 'messenger_controller.dart';
import 'models.dart';

class DebugRunRequest {
  const DebugRunRequest({
    required this.what,
    this.reportPath,
    this.exitAfter = false,
    this.wait = const Duration(seconds: 20),
    this.name,
    this.relay,
    this.invites = const [],
    this.approve = false,
    this.serve = Duration.zero,
    this.group,
    this.noReserve = false,
    this.linger = Duration.zero,
    this.carriers = const [],
    this.reticulum,
    this.chatmail,
    this.matrix,
    this.onlyTransport,
    this.expectContacts = 0,
    this.expectGroup,
  });

  /// 'routes', 'messages', 'files', 'interactions', 'all', or 'none'
  /// (only set up).
  final String what;
  final String? reportPath;
  final bool exitAfter;
  final Duration wait;

  /// Set up storage and an identity under this name, if there is none.
  final String? name;

  /// HOST:PORT of a relay to add.
  final String? relay;

  /// Invite codes of contacts to add.
  final List<String> invites;

  /// Approve contact requests (and stay reachable) while serving.
  final bool approve;

  /// How long to wait for the other devices before testing.
  final Duration serve;

  /// Make a group of every contact under this title (lab-…) after serving.
  final String? group;

  /// Turn off this (lab) identity's free-space reserve, so files can be
  /// tested on a disk that is nearly full.
  final bool noReserve;

  /// Stay online after the tests (answering the others, taking their late
  /// receipts) before the report is written.
  final Duration linger;

  /// Carriers to switch on before pairing, so the invite and the contact
  /// exchange carry their addresses: some of [carrierNames].
  final List<String> carriers;

  /// HOST:PORT of the Reticulum node (rnsd) for the reticulum carrier.
  final String? reticulum;

  /// The chatmail server for the email carrier (a network may block the
  /// default one).
  final String? chatmail;

  /// URL,USER,PASSWORD of a lab Matrix account.
  final String? matrix;

  /// The one transport left on for the whole run (pairing included).
  final TransportKind? onlyTransport;

  /// Contacts this device waits for (at most [serve]) before testing: the
  /// wait ends as soon as that many can be written to.
  final int expectContacts;

  /// A lab group another device makes: this one waits to be in it before
  /// the group tests, or it tests a group it has not joined yet.
  final String? expectGroup;

  static const List<String> carrierNames = [
    'nostr',
    'tor',
    'email',
    'bitchat',
    'reticulum',
  ];

  /// Public Reticulum testnet node, used when none is given.
  // reticulum.betweentheborders.com:4242 closed every connection within
  // two seconds (October 17); this hub keeps them.
  static const String defaultReticulum = 'rns.beleth.net:4242';

  static const Set<String> kinds = {
    'routes',
    'messages',
    'files',
    'interactions',
    'all',
    'none',
  };

  bool get setsUp => name != null;

  /// From command-line arguments; null when none asks for a run.
  static DebugRunRequest? fromArgs(List<String> args) {
    String? value(String name) {
      for (final arg in args) {
        if (arg.startsWith('--$name=')) return arg.substring(name.length + 3);
      }
      return null;
    }

    Duration seconds(String name, Duration fallback, int max) {
      final parsed = int.tryParse(value(name) ?? '');
      return parsed != null && parsed >= 0 && parsed <= max
          ? Duration(seconds: parsed)
          : fallback;
    }

    final what = value('debug-run');
    if (what == null || !kinds.contains(what)) return null;
    final name = value('debug-name');
    final group = value('debug-group');
    return DebugRunRequest(
      what: what,
      reportPath: value('debug-report'),
      exitAfter: args.contains('--debug-exit'),
      wait: seconds('debug-wait', const Duration(seconds: 20), 600),
      name: name != null && name.isNotEmpty && name.length <= 64 ? name : null,
      relay: value('debug-relay'),
      invites: [
        for (final arg in args)
          if (arg.startsWith('--debug-accept-invite='))
            arg.substring('--debug-accept-invite='.length),
      ].where((code) => code.isNotEmpty && code.length <= 16384).toList(),
      approve: args.contains('--debug-approve'),
      serve: seconds('debug-serve', Duration.zero, 3600),
      group: group != null && group.startsWith('lab-') && group.length <= 64
          ? group
          : null,
      noReserve: args.contains('--debug-no-reserve'),
      linger: seconds('debug-linger', Duration.zero, 3600),
      carriers: [
        for (final name in (value('debug-carriers') ?? '').split(','))
          if (carrierNames.contains(name.trim())) name.trim(),
      ],
      reticulum: value('debug-reticulum'),
      chatmail: value('debug-chatmail'),
      matrix: value('debug-matrix'),
      onlyTransport: TransportKind.values
          .where((kind) => kind.name == value('debug-only-transport'))
          .firstOrNull,
      expectContacts: (int.tryParse(value('debug-expect-contacts') ?? '') ?? 0)
          .clamp(0, 64),
      expectGroup: switch (value('debug-expect-group')) {
        final title? when title.startsWith('lab-') && title.length <= 64 =>
          title,
        _ => null,
      },
    );
  }

  /// From the Android intent extras: `conestDebugArgs` (space-separated,
  /// as on a command line, sent as "args:…") or `conestDebugRun` (a kind).
  static DebugRunRequest? fromExtra(String? extra) {
    if (extra == null) return null;
    if (extra.startsWith('args:')) {
      return fromArgs(
        extra.substring(5).split(' ').where((part) => part.isNotEmpty).toList(),
      );
    }
    return kinds.contains(extra.trim())
        ? DebugRunRequest(what: extra.trim())
        : null;
  }
}

/// Runs [request] on [controller] (already set up) and writes the report.
/// Returns where it was written.
Future<String> runDebugRequest(
  MessengerController controller,
  DebugRunRequest request, {
  required Future<String> Function() defaultReportPath,
}) async {
  final startedAt = DateTime.now().toUtc();
  final path = request.reportPath ?? await defaultReportPath();
  final steps = <Map<String, Object?>>[];
  Future<void> step(String name, Future<Object?> Function() work) async {
    try {
      final result = await work();
      steps.add({'step': name, 'ok': true, 'result': ?result});
    } catch (error) {
      steps.add({'step': name, 'ok': false, 'error': '$error'});
      controller.recordError('test', 'Lab step $name failed: $error');
    }
  }

  final name = request.name;
  if (name != null && !controller.hasIdentity) {
    await step('identity', () async {
      await controller.createIdentity(displayName: name);
      if (controller.needsUserModeChoice) {
        await controller.setUserMode(UserMode.advanced);
      }
      return controller.identity?.deviceId;
    });
  }
  // Before the invite, so it carries the relay's address (without LAN,
  // pairing has to find this device there).
  final relay = request.relay;
  if (relay != null && controller.hasIdentity) {
    await step('relay', () async {
      final at = relay.lastIndexOf(':');
      final port = int.parse(relay.substring(at + 1));
      await controller.addRelay(host: relay.substring(0, at), port: port);
      return relay;
    });
  }
  if (controller.hasIdentity) {
    for (final carrier in request.carriers) {
      // At most 90 s each: a carrier that hangs (the phone's chatmail sign-up
      // once did) must not keep the invite, and so every device, waiting.
      await step('carrier $carrier', () async {
        await Future<void>(() async {
          switch (carrier) {
            case 'nostr':
              await controller.enableNostrCarrier();
            case 'tor':
              await controller.enableTorCarrier();
            case 'email':
              await controller.enableChatmailCarrier(
                request.chatmail ?? defaultChatmailDomains.first,
              );
            case 'bitchat':
              await controller.enableBitchatCarrier();
            case 'reticulum':
              final node =
                  request.reticulum ?? DebugRunRequest.defaultReticulum;
              final at = node.lastIndexOf(':');
              await controller.enableReticulumCarrier(
                host: node.substring(0, at),
                port: int.parse(node.substring(at + 1)),
              );
          }
          // Ready (an address) before the invite is made: an invite carries
          // only the carriers that have one, and email or Tor get theirs
          // after signing up or connecting.
          final kind = switch (carrier) {
            'email' => TransportKind.deltaChat,
            _ => TransportKind.values.byName(carrier),
          };
          bool ready() => controller.carrierStatuses.any(
            (status) => status.kind == kind && status.ready,
          );
          final deadline = DateTime.now().add(const Duration(seconds: 85));
          while (!ready() && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          if (!ready()) throw StateError('$carrier did not become ready');
        }).timeout(const Duration(seconds: 90));
        return null;
      });
    }
    final matrix = request.matrix?.split(',');
    if (matrix != null && matrix.length == 3) {
      await step('matrix', () async {
        await controller.signInToMatrix(
          homeserver: matrix[0],
          user: matrix[1],
          password: matrix[2],
        );
        return matrix[1];
      });
    }
    final only = request.onlyTransport;
    final me = controller.identity;
    if (only != null && me != null) {
      await step('only $only', () async {
        await controller.updateGlobalConnectivity(
          me.connectivity.copyWith(
            lanEnabled: only == TransportKind.lan,
            transportPolicies: {
              for (final kind in TransportKind.values)
                kind: kind == only
                    ? TransportPolicy.automatic
                    : TransportPolicy.disabled,
            },
          ),
        );
        return only.name;
      });
    }
    await step('invite', () async {
      final code = (await controller.buildInvite()).encodePayload();
      await _writeWhole('$path.invite', code);
      return code;
    });
  }
  if (request.noReserve && controller.hasIdentity) {
    await step('no-reserve', () async {
      await controller.updateStorageReserveEnabled(false);
      return null;
    });
  }
  for (final (index, code) in request.invites.indexed) {
    await step('accept-invite-$index', () async {
      final result = await controller.addContactFromInvite(
        alias: 'lab-${index + 1}',
        payload: code,
        codephrase: '',
      );
      return result.toString();
    });
  }
  // Waits for the other devices (and approves them) before testing, until
  // the expected contacts can all be written to. When each became ready,
  // from the start: how long adding a contact took.
  final serveUntil = DateTime.now().add(request.serve);
  final pairedAfter = <String, int>{};
  void notePaired() {
    for (final contact in _contacts(controller)) {
      pairedAfter.putIfAbsent(
        contact.alias,
        () => DateTime.now().toUtc().difference(startedAt).inMilliseconds,
      );
    }
  }

  do {
    notePaired();
    if (request.expectContacts > 0 &&
        _contacts(controller).length >= request.expectContacts) {
      break;
    }
    if (request.approve) {
      for (final pending in controller.pendingContactRequests) {
        await step('approve ${pending.id}', () async {
          await controller.approvePendingContactRequest(pending.id);
          return pending.id;
        });
      }
    }
    if (DateTime.now().isBefore(serveUntil)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  } while (DateTime.now().isBefore(serveUntil));
  notePaired();
  final title = request.group;
  if (title != null) {
    // Everyone this device invited, accepted, or the group misses them
    // (Android once took longer than Windows' 30 s to accept).
    final until = DateTime.now().add(const Duration(minutes: 2));
    while (_contacts(controller).length < request.invites.length &&
        DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
  if (title != null &&
      !controller.visibleGroups.any((group) => group.title == title)) {
    await step('group', () async {
      final group = await controller.createGroup(
        title: title,
        members: _contacts(controller),
      );
      return group.groupId;
    });
  }
  if (request.expectGroup case final expected?) {
    await step('joined $expected', () async {
      final until = DateTime.now().add(request.serve);
      while (!_labGroups(controller).any((group) => group.title == expected) &&
          DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (!_labGroups(controller).any((group) => group.title == expected)) {
        throw StateError('not in $expected');
      }
      return DateTime.now().toUtc().difference(startedAt).inMilliseconds;
    });
  }
  await Future<void>.delayed(request.wait);
  final carriersAtStart = _carrierReport(controller);

  final what = request.what;
  final contacts = <Map<String, Object?>>[];
  if (what == 'routes' || what == 'all') {
    for (final contact in _contacts(controller)) {
      try {
        // Carriers (mail, Tor, Nostr) can take far longer than 15 s.
        final probes = request.wait * 3 > const Duration(seconds: 15)
            ? request.wait * 3
            : const Duration(seconds: 15);
        final report = await controller.runTransportExchangeTest(
          contact,
          probeTimeout: probes,
          remoteTimeout: probes + const Duration(seconds: 45),
        );
        contacts.add({
          'contact': contact.alias,
          'deviceId': contact.deviceId,
          'report': report.toJson(),
          'text': report.toText(),
        });
      } catch (error) {
        contacts.add({
          'contact': contact.alias,
          'deviceId': contact.deviceId,
          'error': '$error',
        });
      }
    }
  }
  if (what == 'messages' || what == 'all') {
    await _sendMessages(controller, step, request.wait);
  }
  if (what == 'files' || what == 'all') {
    await _sendFiles(controller, step);
  }
  if (what == 'messages' || what == 'files' || what == 'all') {
    // Time for receipts (and files) to come back.
    await Future<void>.delayed(request.wait * 3);
  }
  if (what == 'interactions' || what == 'all') {
    await _interact(controller, step, request.wait);
    await Future<void>.delayed(request.wait * 2);
    // And what the others did meanwhile, so their read marks show too.
    await step('read everything', () async {
      for (final contact in _contacts(controller)) {
        await controller.markConversationRead(contact.deviceId);
      }
      for (final group in _labGroups(controller)) {
        final last = controller
            .messagesForGroup(group.groupId)
            .where((m) => !m.outbound)
            .lastOrNull;
        if (last != null) {
          await controller.markGroupReadThroughMessage(group.groupId, last);
        }
      }
      return null;
    });
  }
  // Done: say so to every contact, over the transport being tested, then
  // stay (answering, taking late receipts) until each has said so too.
  for (final contact in _contacts(controller)) {
    await step('done ${contact.alias}', () async {
      await controller.sendMessage(contact: contact, body: _doneBody);
      return null;
    });
  }
  final lingerUntil = DateTime.now().add(request.linger);
  bool allDone() => _contacts(controller).every(
    (contact) => controller
        .messagesFor(contact.deviceId)
        .any((m) => !m.outbound && m.body == _doneBody),
  );
  while (!allDone() && DateTime.now().isBefore(lingerUntil)) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  // A moment for this device's own last receipts to arrive.
  await Future<void>.delayed(request.wait);
  final report = {
    'kind': what,
    'build': controller.debugBuildId,
    'deviceId': controller.identity?.deviceId,
    'name': controller.identity?.displayName,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': DateTime.now().toUtc().toIso8601String(),
    'steps': steps,
    'contacts': contacts,
    'pairedAfterMs': pairedAfter,
    // This device's relays in order, and the one it holds a waiting fetch
    // on (on battery, the only one it watches promptly).
    'relays': [
      for (final relay in controller.identity?.configuredRelays ?? const [])
        relay.label,
    ],
    'watchedRelay': controller.watchedRelay?.label,
    'carriers': {'start': carriersAtStart, 'end': _carrierReport(controller)},
    'chats': _chatReport(controller),
    'errorHistory': controller.exportErrorHistory(),
  };
  await _writeWhole(path, const JsonEncoder.withIndent('  ').convert(report));
  controller.recordError('test', 'Automatic $what run written to $path');
  return path;
}

List<ContactRecord> _contacts(MessengerController controller) => [
  for (final contact in controller.contacts)
    if (contact.canSendOutbound &&
        contact.deviceId != controller.identity?.deviceId)
      contact,
];

Iterable<GroupRecord> _labGroups(MessengerController controller) =>
    controller.visibleGroups.where(
      (group) =>
          group.title.startsWith('lab-') &&
          group.hasActiveMember(controller.identity?.deviceId ?? ''),
    );

typedef _Step =
    Future<void> Function(String name, Future<Object?> Function() work);

Future<void> _sendMessages(
  MessengerController controller,
  _Step step,
  Duration wait,
) async {
  final me = controller.identity?.displayName ?? 'lab';
  for (final contact in _contacts(controller)) {
    for (var i = 1; i <= 3; i++) {
      // One at a time, each waited for (at most [wait]): the step's result
      // is how long it took to be confirmed, in ms, or null.
      await step('message ${contact.alias} $i', () async {
        final body = 'lab $i from $me to ${contact.alias}';
        final sentAt = DateTime.now();
        await controller.sendMessage(contact: contact, body: body);
        final until = sentAt.add(wait);
        while (DateTime.now().isBefore(until)) {
          final message = controller
              .messagesFor(contact.deviceId)
              .where((m) => m.outbound && m.body == body)
              .lastOrNull;
          if (message != null &&
              (message.state == DeliveryState.delivered ||
                  message.state == DeliveryState.read)) {
            return DateTime.now().difference(sentAt).inMilliseconds;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        return null;
      });
    }
  }
  for (final group in _labGroups(controller)) {
    for (var i = 1; i <= 3; i++) {
      await step('group message ${group.title} $i', () async {
        await controller.sendGroupMessage(
          groupId: group.groupId,
          body: 'lab $i from $me to ${group.title}',
        );
        return null;
      });
    }
  }
}

Future<void> _sendFiles(MessengerController controller, _Step step) async {
  const sizes = [64 * 1024, 1024 * 1024, 8 * 1024 * 1024];
  final random = Random();
  Uint8List bytes(int size) =>
      Uint8List.fromList(List<int>.generate(size, (_) => random.nextInt(256)));
  for (final contact in _contacts(controller)) {
    for (final size in sizes) {
      await step('file ${contact.alias} $size', () async {
        await controller.sendAttachment(
          contact: contact,
          bytes: bytes(size),
          fileName: 'lab-$size.bin',
        );
        return null;
      });
    }
  }
  final folder = await Directory.systemTemp.createTemp('conest-lab-');
  for (final group in _labGroups(controller)) {
    for (final size in sizes) {
      await step('group file ${group.title} $size', () async {
        final file = File('${folder.path}/lab-$size.bin');
        await file.writeAsBytes(bytes(size), flush: true);
        return controller.publishGroupFile(
          groupId: group.groupId,
          path: file.path,
          fileName: 'lab-$size.bin',
          mimeType: 'application/octet-stream',
          keepMetadata: true,
        );
      });
    }
  }
}

/// What people do with messages, in every chat and lab group: read what
/// came, reply, react, edit, delete for everyone, and cancel a file
/// transfer. Each other device's report shows whether it arrived.
Future<void> _interact(
  MessengerController controller,
  _Step step,
  Duration wait,
) async {
  final me = controller.identity?.displayName ?? 'lab';
  bool inboundLab(ChatMessage message) =>
      !message.outbound && message.body.startsWith('lab ');
  // Until [ready] holds, at most [limit].
  Future<void> until(bool Function() ready, Duration limit) async {
    final end = DateTime.now().add(limit);
    while (!ready() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  bool sent(ChatMessage? message) =>
      message != null && message.state != DeliveryState.pending;

  for (final contact in _contacts(controller)) {
    final peer = contact.deviceId;
    ChatMessage? mine(String body) => controller
        .messagesFor(peer)
        .where((m) => m.outbound && m.body == body)
        .lastOrNull;
    await step('read ${contact.alias}', () async {
      await controller.markConversationRead(peer);
      return null;
    });
    final first = controller.messagesFor(peer).where(inboundLab).firstOrNull;
    if (first != null) {
      await step('reply ${contact.alias}', () async {
        await controller.sendMessage(
          contact: contact,
          body: 'lab reply from $me',
          replyTo: first,
        );
        return null;
      });
      await step('react ${contact.alias}', () async {
        await controller.toggleMessageReaction(
          contact: contact,
          messageId: first.id,
          emoji: '👍',
        );
        return null;
      });
    }
    await step('edit ${contact.alias}', () async {
      await controller.sendMessage(
        contact: contact,
        body: 'lab edit-me from $me',
      );
      final message = mine('lab edit-me from $me')!;
      await controller.editMessage(
        contact: contact,
        messageId: message.id,
        body: 'lab edited from $me',
      );
      return null;
    });
    await step('delete ${contact.alias}', () async {
      final body = 'lab delete-me from $me';
      await controller.sendMessage(contact: contact, body: body);
      // Deleting for everyone needs it sent.
      await until(() => sent(mine(body)), wait);
      await controller.deleteMessage(
        contact: contact,
        messageId: mine(body)!.id,
      );
      return null;
    });
    await step('cancel file ${contact.alias}', () async {
      // Big enough to be still on its way a moment later, even on LAN.
      const size = 128 * 1024 * 1024;
      final folder = await Directory.systemTemp.createTemp('conest-lab-');
      final file = File('${folder.path}/lab-cancel.bin');
      final out = await file.open(mode: FileMode.write);
      final chunk = Uint8List(1024 * 1024);
      for (var i = 0; i < size ~/ chunk.length; i++) {
        await out.writeFrom(chunk);
      }
      await out.close();
      await controller.sendAttachmentSource(
        contact: contact,
        source: StagedAttachment(
          id: 'lab-cancel',
          fileName: 'lab-cancel.bin',
          mimeType: 'application/octet-stream',
          sizeBytes: size,
          filePath: file.path,
          presentation: AttachmentPresentation.file,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final message = controller
          .messagesFor(peer)
          .where(
            (m) => m.outbound && m.attachment?.fileName == 'lab-cancel.bin',
          )
          .last;
      await controller.cancelAttachmentById(message.attachment!.id);
      await folder.delete(recursive: true);
      return message.state.name;
    });
  }
  for (final group in _labGroups(controller)) {
    final id = group.groupId;
    ChatMessage? mine(String body) => controller
        .messagesForGroup(id)
        .where((m) => m.outbound && m.body == body)
        .lastOrNull;
    final inbound = controller.messagesForGroup(id).where(inboundLab).toList();
    await step('read ${group.title}', () async {
      if (inbound.isNotEmpty) {
        await controller.markGroupReadThroughMessage(id, inbound.last);
      }
      return inbound.length;
    });
    if (inbound.isNotEmpty) {
      await step('reply ${group.title}', () async {
        await controller.sendGroupMessage(
          groupId: id,
          body: 'lab reply from $me',
          replyTo: inbound.first,
        );
        return null;
      });
      await step('react ${group.title}', () async {
        await controller.toggleGroupReaction(
          groupId: id,
          messageId: inbound.first.id,
          emoji: '👍',
        );
        return null;
      });
    }
    await step('edit ${group.title}', () async {
      await controller.sendGroupMessage(
        groupId: id,
        body: 'lab edit-me from $me',
      );
      await controller.changeGroupMessage(
        groupId: id,
        messageId: mine('lab edit-me from $me')!.id,
        body: 'lab edited from $me',
      );
      return null;
    });
    await step('delete ${group.title}', () async {
      final body = 'lab delete-me from $me';
      await controller.sendGroupMessage(groupId: id, body: body);
      await until(() => sent(mine(body)), wait);
      await controller.changeGroupMessage(
        groupId: id,
        messageId: mine(body)!.id,
        delete: true,
      );
      return null;
    });
  }
}

/// Each carrier's state: ready or not, and its last error.
List<Map<String, Object?>> _carrierReport(MessengerController controller) => [
  for (final status in controller.carrierStatuses)
    {
      'kind': status.kind.name,
      'ready': status.ready,
      if (status.lastError != null) 'error': status.lastError,
    },
  if (controller.matrixStatus case final matrix?)
    {
      'kind': 'matrix',
      'ready': matrix.signedIn && matrix.syncing,
      if (matrix.lastError != null) 'error': matrix.lastError,
    },
];

/// Sent to every contact when this device's tests are over.
const String _doneBody = 'lab-done';

/// What came of every lab message and file, per chat.
List<Map<String, Object?>> _chatReport(MessengerController controller) {
  Map<String, Object?> describe(ChatMessage message) => {
    'id': message.id,
    'outbound': message.outbound,
    'body': message.body,
    'file': message.attachment?.fileName ?? message.groupFile?.fileName,
    'state': message.state.name,
    'route': message.route?.name,
    'routes': [
      for (final trace in message.routeTrace)
        '${trace.route.name}:${trace.mark.name}',
    ],
    // When each mark came, in ms after the message was written; for one
    // that came in, when it arrived (both clocks: they are NTP-synced).
    'timeline': [
      for (final trace in message.routeTrace)
        '${trace.route.name}:${trace.mark.name}'
            '+${trace.at.difference(message.createdAt).inMilliseconds}',
    ],
    if (!message.outbound)
      'arrivedAt': message.arrivedAt.toUtc().toIso8601String(),
    'recipients': {
      for (final entry in message.recipientStates.entries)
        entry.key: entry.value.name,
    },
    if (message.isEdited) 'edited': true,
    if (message.replyToMessageId != null) 'replyTo': message.replyToMessageId,
    if (message.reactions.isNotEmpty)
      'reactions': {
        for (final entry in message.reactions.entries)
          entry.key: entry.value.length,
      },
    'at': message.createdAt.toUtc().toIso8601String(),
  };
  bool isLab(ChatMessage message) =>
      message.body.startsWith('lab ') ||
      (message.attachment?.fileName ?? message.groupFile?.fileName ?? '')
          .startsWith('lab-');
  return [
    for (final contact in _contacts(controller))
      {
        'contact': contact.alias,
        'deviceId': contact.deviceId,
        'messages': [
          for (final message in controller.messagesFor(contact.deviceId))
            if (isLab(message)) describe(message),
        ],
      },
    for (final group in _labGroups(controller))
      {
        'group': group.title,
        'groupId': group.groupId,
        'messages': [
          for (final message in controller.messagesForGroup(group.groupId))
            if (isLab(message)) describe(message),
        ],
      },
  ];
}

/// Whole or not at all: a script waiting for the file never reads half.
Future<void> _writeWhole(String path, String text) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final temporary = File('$path.tmp');
  await temporary.writeAsString(text, flush: true);
  await temporary.rename(file.path);
}

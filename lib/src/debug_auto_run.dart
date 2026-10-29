/// Automatic tests a debug build runs when started for them (Q6), so a
/// device can be tested from a shell over adb or ssh:
///
///   conest --debug-run=routes|messages|files|interactions|all|none
///          (or contacts: remove and add back every contact this device
///          added, and every member of the group it made; or burst: 20
///          messages to every chat and group half a second apart, and
///          1, 10 and 50 MB files; or calls: the device that makes the
///          group calls each contact for a minute, then the group; the
///          others answer and join; or serve: set up and pair once, then
///          run the phases the lab writes to PATH.cmd, see [LabPhase])
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
///          [--debug-email=MAIL,PASSWORD,IMAP_HOST,SMTP_HOST]
///                                         use this mail account instead of
///                                         signing up (a lab device's own,
///                                         kept from an earlier run)
///          [--debug-link-new]             join another lab device's account
///          [--debug-link-from=LINK_TEXT]  link that new device into this one
///          [--debug-matrix=URL,USER,PASSWORD]  sign in to Matrix (lab
///                                         accounts on a lab homeserver)
///          [--debug-only-transport=KIND]  every other transport off (LAN
///                                         too), from before pairing: adds
///                                         contacts and talks over KIND
///          [--debug-idle=SECONDS]         then stay online, idle, this long
///                                         (to measure battery and data)
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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'group_call/group_call_service.dart';
import 'group_file_download.dart';
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
    this.idle = Duration.zero,
    this.carriers = const [],
    this.reticulum,
    this.chatmail,
    this.email,
    this.matrix,
    this.onlyTransport,
    this.expectContacts = 0,
    this.expectGroup,
    this.burstFileSizes = const [
      1024 * 1024,
      10 * 1024 * 1024,
      50 * 1024 * 1024,
    ],
    this.callLength = const Duration(minutes: 1),
    this.linkNew = false,
    this.linkFrom,
  });

  /// 'routes', 'messages', 'files', 'interactions', 'all', 'contacts',
  /// 'burst', 'calls', 'none' (only set up), or 'serve' (set up, then run
  /// [LabPhase]s until told to stop).
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

  /// After everything (the linger too), stay online doing nothing this
  /// long: what an idle hour costs in battery and data.
  final Duration idle;

  /// Carriers to switch on before pairing, so the invite and the contact
  /// exchange carry their addresses: some of [carrierNames].
  final List<String> carriers;

  /// HOST:PORT of the Reticulum node (rnsd) for the reticulum carrier.
  final String? reticulum;

  /// The chatmail server for the email carrier (a network may block the
  /// default one).
  final String? chatmail;

  /// MAIL,PASSWORD,IMAP_HOST,SMTP_HOST of a mail account to use instead of
  /// signing up: chatmail servers limit sign-ups per address, and every
  /// fresh lab run would otherwise make new accounts. After a sign-up the
  /// account is written to `<report>.email` for the lab to keep.
  final String? email;

  /// URL,USER,PASSWORD of a lab Matrix account.
  final String? matrix;

  /// The one transport left on for the whole run (pairing included).
  final TransportKind? onlyTransport;

  /// Join another lab device's account as a new device: the link text is
  /// written to `<report>.link`, for that device's [linkFrom].
  final bool linkNew;

  /// Link the new device whose link text this is into this device's
  /// account.
  ///
  /// Either side writes the code it shows to `<report>.code` and confirms
  /// only once the lab puts the other side's code in `<report>.peer-code`
  /// and the two match, as a person comparing the screens would.
  final String? linkFrom;

  /// Contacts this device waits for (at most [serve]) before testing: the
  /// wait ends as soon as that many can be written to.
  final int expectContacts;

  /// A lab group another device makes: this one waits to be in it before
  /// the group tests, or it tests a group it has not joined yet.
  final String? expectGroup;

  /// The files 'burst' sends to every chat and group, by size.
  final List<int> burstFileSizes;

  /// How long each call of a 'calls' run lasts.
  final Duration callLength;

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
    'contacts',
    'burst',
    'calls',
    'none',
    'serve',
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
      idle: seconds('debug-idle', Duration.zero, 4 * 3600),
      carriers: [
        for (final name in (value('debug-carriers') ?? '').split(','))
          if (carrierNames.contains(name.trim())) name.trim(),
      ],
      reticulum: value('debug-reticulum'),
      chatmail: value('debug-chatmail'),
      email: switch (value('debug-email')) {
        final text? when text.split(',').length == 4 && text.length <= 1024 =>
          text,
        _ => null,
      },
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
      linkNew: args.contains('--debug-link-new'),
      linkFrom: switch (value('debug-link-from')) {
        final text? when text.isNotEmpty && text.length <= 4096 => text,
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

/// One phase of a 'serve' run: a line `ID KIND [TRANSPORT]` the lab appends
/// to `<report>.cmd` (KIND one of the run kinds, TRANSPORT a transport kind
/// left on alone, or `all` for everything set up at the start, the default),
/// or `ID stop`. The devices stay up and paired between phases: each phase
/// switches transports at runtime, runs, and writes `<report>.ID.json`.
class LabPhase {
  const LabPhase({required this.id, required this.kind, this.only});

  final String id;

  /// A run kind, or 'stop'.
  final String kind;

  /// The one transport left on; null for all of them.
  final TransportKind? only;

  static final RegExp _id = RegExp(r'^[A-Za-z0-9_-]{1,32}$');

  /// A serve run with no new phase for this long ends by itself.
  static const Duration maximumIdle = Duration(hours: 2);

  static const Set<String> phaseKinds = {
    'routes',
    'messages',
    'files',
    'interactions',
    'all',
    'contacts',
    'burst',
    'calls',
    'stop',
  };

  /// Null for anything else (blank lines, comments, typos).
  static LabPhase? parse(String line) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2 || parts.length > 3) return null;
    final [id, kind, ...rest] = parts;
    if (!_id.hasMatch(id) || !phaseKinds.contains(kind)) return null;
    final transport = rest.firstOrNull ?? 'all';
    if (transport == 'all') return LabPhase(id: id, kind: kind);
    final only = TransportKind.values
        .where((value) => value.name == transport)
        .firstOrNull;
    return only == null ? null : LabPhase(id: id, kind: kind, only: only);
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

  // Whenever a contact or a lab group membership comes or goes, from the
  // start to the end: how long removals and additions took to arrive here.
  final events = <Map<String, Object?>>[];
  var known = <String, String>{};
  var memberOf = <String>{};
  void observe() {
    final now = DateTime.now().toUtc().toIso8601String();
    final contactsNow = {
      for (final contact in _contacts(controller))
        contact.deviceId: contact.alias,
    };
    for (final MapEntry(:key, :value) in contactsNow.entries) {
      if (!known.containsKey(key)) {
        events.add({
          'at': now,
          'event': 'contact',
          'deviceId': key,
          'alias': value,
        });
      }
    }
    for (final MapEntry(:key, :value) in known.entries) {
      if (!contactsNow.containsKey(key)) {
        events.add({
          'at': now,
          'event': 'contact-gone',
          'deviceId': key,
          'alias': value,
        });
      }
    }
    known = contactsNow;
    final groupsNow = {for (final group in _labGroups(controller)) group.title};
    for (final title in groupsNow.difference(memberOf)) {
      events.add({'at': now, 'event': 'member', 'group': title});
    }
    for (final title in memberOf.difference(groupsNow)) {
      events.add({'at': now, 'event': 'member-gone', 'group': title});
    }
    memberOf = groupsNow;
  }

  // Contact requests are approved all along (removed contacts come back
  // during the tests, not only while serving).
  final approving = <String>{};
  Future<void> approvePending() async {
    for (final pending in controller.pendingContactRequests) {
      if (!approving.add(pending.id)) continue;
      await step('approve ${pending.id}', () async {
        await controller.approvePendingContactRequest(pending.id);
        return pending.id;
      });
    }
  }

  // Calls: answered and joined here, and their statistics written down
  // when each ends.
  final calls = <Map<String, Object?>>[];
  // The kind running now (a serve run's current phase).
  var running = request.what;
  String? callOpen;
  final joining = <String>{};
  final joinedAt = <String, DateTime>{};
  final leaving = <String>{};
  void watchCalls() {
    if (running != 'calls') return;
    final service = controller.voiceCallService;
    final active = service?.active;
    if (active != null &&
        !active.outgoing &&
        active.state == VoiceCallState.ringing &&
        request.approve) {
      unawaited(
        controller.acceptVoiceCall().catchError((Object error) {
          controller.recordError('test', 'Lab call answer failed: $error');
        }),
      );
    }
    final live = active != null && active.state != VoiceCallState.ended
        ? active.callId
        : null;
    if (callOpen != null && live != callOpen) {
      calls.add({
        'call': callOpen,
        'at': DateTime.now().toUtc().toIso8601String(),
        'stats': controller.voiceCallStats,
      });
    }
    callOpen = live;
    final rooms = controller.groupCallService?.rooms ?? const [];
    for (final room in rooms) {
      final lab = _labGroups(
        controller,
      ).any((group) => group.groupId == room.groupId);
      if (room.joined) {
        final since = joinedAt.putIfAbsent(room.callId, DateTime.now);
        // Alone in it (the one who started it left): leave, and write down
        // what the call's audio did.
        if (room.participants.length <= 1 &&
            DateTime.now().difference(since) > const Duration(seconds: 10) &&
            leaving.add(room.callId)) {
          final service = controller.groupCallService!;
          final entry = _groupCallEntry(controller, room);
          unawaited(
            service.leave().then<void>((_) {
              calls.add(entry);
            }, onError: (Object _) {}),
          );
        }
        continue;
      }
      if (lab && request.approve && joining.add(room.callId)) {
        unawaited(
          controller
              .joinOrStartGroupCall(room.groupId)
              .then<void>(
                (_) {},
                onError: (Object error) {
                  controller.recordError(
                    'test',
                    'Lab group call join failed: $error',
                  );
                },
              ),
        );
      }
    }
  }

  final ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
    observe();
    if (request.approve) unawaited(approvePending());
    watchCalls();
  });

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
              if (request.email case final account?) {
                final [mail, password, imap, smtp] = account.split(',');
                await controller.enableOwnEmailCarrier(
                  mail: mail,
                  password: password,
                  imapHost: imap,
                  smtpHost: smtp,
                );
              } else {
                await controller.enableChatmailCarrier(request.chatmail);
                // Kept by the lab for the next run (see [email]).
                if (controller.emailCarrierConfig case final config?) {
                  await _writeWhole(
                    '$path.email',
                    [
                      config.mail,
                      config.password,
                      config.imapHost,
                      config.smtpHost,
                    ].join(','),
                  );
                }
              }
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
    if (request.what == 'calls' || request.what == 'serve') {
      // On by default; lab data kept from earlier runs may have them off.
      // Before the invite: contacts learn at pairing that calls work here.
      await step('calls on', () async {
        await controller.updateExperimentalVoiceCallsEnabled(true);
        return null;
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
    if (request.linkNew || request.linkFrom != null) {
      await step('link', () => _linkLabDevices(controller, request, path));
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
  final invitedAt = <String, DateTime>{};
  for (final (index, code) in request.invites.indexed) {
    invitedAt['lab-${index + 1}'] = DateTime.now().toUtc();
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
  // For contacts this device asked for: from taking the invite.
  final pairedAfterInvite = <String, int>{};
  void notePaired() {
    final now = DateTime.now().toUtc();
    for (final contact in _contacts(controller)) {
      pairedAfter.putIfAbsent(
        contact.alias,
        () => now.difference(startedAt).inMilliseconds,
      );
      if (invitedAt[contact.alias] case final asked?) {
        pairedAfterInvite.putIfAbsent(
          contact.alias,
          () => now.difference(asked).inMilliseconds,
        );
      }
    }
  }

  do {
    notePaired();
    if (request.expectContacts > 0 &&
        _contacts(controller).length >= request.expectContacts) {
      break;
    }
    if (request.approve) await approvePending();
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
  // The tests of one kind, then the done exchange and the linger; returns
  // the carriers as they were at its start.
  Future<List<Map<String, Object?>>> runPhase(
    String what,
    String doneBody,
    List<Map<String, Object?>> contacts,
    List<Map<String, Object?>> timings,
  ) async {
    await Future<void>.delayed(request.wait);
    final carriersAtStart = _carrierReport(controller);

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
    if (what == 'contacts') {
      await _removeAndAddBack(controller, step, request, timings);
    }
    if (what == 'calls' && request.group != null) {
      await _callEveryone(controller, step, request, timings);
    }
    if (what == 'burst') {
      await _burst(controller, step, request.burstFileSizes);
      await _untilConfirmed(controller, const Duration(minutes: 3));
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
        await controller.sendMessage(contact: contact, body: doneBody);
        return null;
      });
    }
    final lingerUntil = DateTime.now().add(request.linger);
    bool allDone() => _contacts(controller).every(
      (contact) => controller
          .messagesFor(contact.deviceId)
          .any((m) => !m.outbound && m.body == doneBody),
    );
    while (!allDone() && DateTime.now().isBefore(lingerUntil)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // Still in a group call (the others left): leave it, and write down
    // what its audio did.
    if (controller.groupCallService?.active case final room?
        when room.joined && leaving.add(room.callId)) {
      await step('leave group call', () async {
        final entry = _groupCallEntry(controller, room);
        await controller.groupCallService!.leave();
        calls.add(entry);
        return null;
      });
    }
    // A moment for this device's own last receipts to arrive.
    await Future<void>.delayed(request.wait);
    return carriersAtStart;
  }

  // What happened since [from]: the whole run, or one serve phase (whose
  // chats then hold only what was sent or arrived during it).
  Map<String, Object?> reportFrom(
    ({DateTime at, int steps, int calls, int events}) from, {
    required String what,
    required TransportKind? only,
    required List<Map<String, Object?>> carriersAtStart,
    required List<Map<String, Object?>> contacts,
    required List<Map<String, Object?>> timings,
    String? phase,
    DateTime? idleFrom,
  }) => {
    'kind': what,
    'phase': ?phase,
    'build': controller.debugBuildId,
    'deviceId': controller.identity?.deviceId,
    'name': controller.identity?.displayName,
    'startedAt': from.at.toIso8601String(),
    'finishedAt': DateTime.now().toUtc().toIso8601String(),
    'steps': steps.sublist(from.steps),
    'contacts': contacts,
    'onlyTransport': only?.name,
    if (idleFrom != null)
      'idle': {
        'from': idleFrom.toIso8601String(),
        'seconds': request.idle.inSeconds,
      },
    'pairedAfterMs': pairedAfter,
    'pairedAfterInviteMs': pairedAfterInvite,
    'timings': timings,
    'calls': calls.sublist(from.calls),
    'events': events.sublist(from.events),
    // This device's relays in order, and the one it holds a waiting fetch
    // on (on battery, the only one it watches promptly).
    'relays': [
      for (final relay in controller.identity?.configuredRelays ?? const [])
        relay.label,
    ],
    'watchedRelay': controller.watchedRelay?.label,
    'carriers': {'start': carriersAtStart, 'end': _carrierReport(controller)},
    'chats': _chatReport(controller, since: phase == null ? null : from.at),
    'errorHistory': controller.exportErrorHistory(),
  };

  final contacts = <Map<String, Object?>>[];
  final timings = <Map<String, Object?>>[];
  List<Map<String, Object?>>? carriersAtStart;
  if (request.what == 'serve') {
    // Every transport as set up: what a phase on all of them goes back to.
    final setUp = controller.identity?.connectivity;
    final done = <String>{};
    final commands = File('$path.cmd');
    // A lab that went away (its script stopped) does not keep this device
    // running for ever.
    var idleSince = DateTime.now();
    while (DateTime.now().difference(idleSince) < LabPhase.maximumIdle) {
      List<String> lines;
      try {
        final text = commands.existsSync() ? await commands.readAsString() : '';
        // A line still being written (no newline yet) waits: "p1 messages"
        // must not run before " lan" is added to it.
        lines = text.split('\n');
        lines.removeLast();
      } catch (_) {
        lines = [];
      }
      final phase = lines
          .map(LabPhase.parse)
          .nonNulls
          .where((phase) => !done.contains(phase.id))
          .firstOrNull;
      if (phase == null) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }
      done.add(phase.id);
      if (phase.kind == 'stop') break;
      final from = (
        at: DateTime.now().toUtc(),
        steps: steps.length,
        calls: calls.length,
        events: events.length,
      );
      final only = phase.only;
      if (setUp != null) {
        await step('phase ${phase.id} on ${only?.name ?? 'all'}', () async {
          await controller.updateGlobalConnectivity(
            only == null
                ? setUp
                : setUp.copyWith(
                    lanEnabled: only == TransportKind.lan,
                    transportPolicies: {
                      for (final kind in TransportKind.values)
                        kind: kind == only
                            ? TransportPolicy.automatic
                            : TransportPolicy.disabled,
                    },
                  ),
          );
          return null;
        });
      }
      running = phase.kind;
      final phaseContacts = <Map<String, Object?>>[];
      final phaseTimings = <Map<String, Object?>>[];
      final carriers = await runPhase(
        phase.kind,
        '$_doneBody ${phase.id}',
        phaseContacts,
        phaseTimings,
      );
      running = 'serve';
      observe();
      await _writeWhole(
        '$path.${phase.id}.json',
        const JsonEncoder.withIndent('  ').convert(
          reportFrom(
            from,
            what: phase.kind,
            only: only,
            phase: phase.id,
            carriersAtStart: carriers,
            contacts: phaseContacts,
            timings: phaseTimings,
          ),
        ),
      );
      controller.recordError('test', 'Lab phase ${phase.id} written');
      idleSince = DateTime.now();
    }
    // Every transport back on, as set up: kept lab data starts the next run
    // from there.
    if (setUp != null) {
      await step('transports as set up', () async {
        await controller.updateGlobalConnectivity(setUp);
        return null;
      });
    }
  } else {
    carriersAtStart = await runPhase(
      request.what,
      _doneBody,
      contacts,
      timings,
    );
  }
  ticker.cancel();
  observe();
  // Without this run's own 250 ms ticker, which would cost what is measured.
  final idleFrom = DateTime.now().toUtc();
  if (request.idle > Duration.zero) await Future<void>.delayed(request.idle);
  final report = reportFrom(
    (at: startedAt, steps: 0, calls: 0, events: 0),
    what: request.what,
    only: request.onlyTransport,
    carriersAtStart: carriersAtStart ?? _carrierReport(controller),
    contacts: contacts,
    timings: timings,
    idleFrom: request.idle > Duration.zero ? idleFrom : null,
  );
  await _writeWhole(path, const JsonEncoder.withIndent('  ').convert(report));
  controller.recordError(
    'test',
    'Automatic ${request.what} run written to $path',
  );
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

/// Removes, then adds back, every contact this device added (by the invite
/// it took) and every other member of the lab group it made. The other
/// side's report shows when each change arrived ([runDebugRequest]'s
/// events); this one, how long adding back took until messages could go.
Future<void> _removeAndAddBack(
  MessengerController controller,
  _Step step,
  DebugRunRequest request,
  List<Map<String, Object?>> timings,
) async {
  Future<int?> until(bool Function() ready, Duration limit) async {
    final from = DateTime.now();
    final end = from.add(limit);
    while (!ready()) {
      if (!DateTime.now().isBefore(end)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return DateTime.now().difference(from).inMilliseconds;
  }

  final me = controller.identity?.displayName ?? 'lab';
  for (final (index, code) in request.invites.indexed) {
    final alias = 'lab-${index + 1}';
    final contact = _contacts(
      controller,
    ).where((contact) => contact.alias == alias).firstOrNull;
    if (contact == null) continue;
    final peer = contact.deviceId;
    await step('remove $alias', () async {
      timings.add({
        'task': 'remove',
        'deviceId': peer,
        'at': DateTime.now().toUtc().toIso8601String(),
      });
      await controller.removeContact(peer);
      return null;
    });
    // Time for the notice to arrive before the contact is asked again.
    await Future<void>.delayed(request.wait);
    await step('add back $alias', () async {
      final askedAt = DateTime.now().toUtc();
      await controller.addContactFromInvite(
        alias: alias,
        payload: code,
        codephrase: '',
      );
      final ms = await until(
        () => _contacts(controller).any((c) => c.deviceId == peer),
        const Duration(minutes: 2),
      );
      timings.add({
        'task': 'add-back',
        'deviceId': peer,
        'at': askedAt.toIso8601String(),
        'ms': ms,
      });
      if (ms == null) throw StateError('$alias not back within 2 min');
      // And a message over the renewed contact.
      final back = _contacts(controller).firstWhere((c) => c.deviceId == peer);
      final body = 'lab back from $me to $alias';
      await controller.sendMessage(contact: back, body: body);
      final delivered = await until(
        () => controller
            .messagesFor(peer)
            .any(
              (m) =>
                  m.outbound &&
                  m.body == body &&
                  (m.state == DeliveryState.delivered ||
                      m.state == DeliveryState.read),
            ),
        const Duration(minutes: 1),
      );
      timings.add({
        'task': 'message-after-add-back',
        'deviceId': peer,
        'ms': delivered,
      });
      return ms;
    });
  }
  final title = request.group;
  final group = title == null
      ? null
      : _labGroups(
          controller,
        ).where((group) => group.title == title).firstOrNull;
  if (group == null) return;
  final myId = controller.identity?.deviceId;
  for (final memberId in [...group.activeMemberDeviceIds]) {
    if (memberId == myId) continue;
    final contact = _contacts(
      controller,
    ).where((c) => c.deviceId == memberId).firstOrNull;
    if (contact == null) continue;
    await step('remove member ${contact.alias}', () async {
      timings.add({
        'task': 'remove-member',
        'deviceId': memberId,
        'group': group.title,
        'at': DateTime.now().toUtc().toIso8601String(),
      });
      await controller.removeGroupMember(
        groupId: group.groupId,
        memberDeviceId: memberId,
      );
      return null;
    });
    await Future<void>.delayed(request.wait);
    await step('add member back ${contact.alias}', () async {
      timings.add({
        'task': 'add-member',
        'deviceId': memberId,
        'group': group.title,
        'at': DateTime.now().toUtc().toIso8601String(),
      });
      await controller.addGroupMembers(
        groupId: group.groupId,
        members: [contact],
      );
      return null;
    });
  }
}

/// Calls every contact for a minute, one after another, then starts a
/// call in the lab group this device made and stays a minute: how long
/// each took to connect, and each call's audio statistics.
Future<void> _callEveryone(
  MessengerController controller,
  _Step step,
  DebugRunRequest request,
  List<Map<String, Object?>> timings,
) async {
  final length = request.callLength;
  final service = controller.voiceCallService;
  if (service == null) return;
  for (final contact in _contacts(controller)) {
    await step('call ${contact.alias}', () async {
      final started = DateTime.now();
      await service.startOutgoing(contact.deviceId);
      final until = started.add(const Duration(seconds: 30));
      while (service.active?.state != VoiceCallState.connected &&
          service.active != null &&
          DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final connected = service.active?.state == VoiceCallState.connected;
      final connectMs = connected
          ? DateTime.now().difference(started).inMilliseconds
          : null;
      if (connected) await Future<void>.delayed(length);
      final stats = controller.voiceCallStats;
      await service.end(reason: 'Lab call over');
      timings.add({
        'task': 'call',
        'deviceId': contact.deviceId,
        'at': started.toUtc().toIso8601String(),
        'ms': connectMs,
        'stats': stats,
      });
      // The other side writes its own down, then is ready for the next.
      await Future<void>.delayed(request.wait);
      if (!connected) throw StateError('not connected within 30 s');
      return connectMs;
    });
  }
  final group = _labGroups(
    controller,
  ).where((group) => group.title == request.group).firstOrNull;
  final groupCalls = controller.groupCallService;
  if (group == null || groupCalls == null) return;
  await step('group call ${group.title}', () async {
    final started = DateTime.now();
    await controller.joinOrStartGroupCall(group.groupId);
    // The most members seen in it at once (did they find each other?).
    var most = 0;
    final until = DateTime.now().add(length);
    while (DateTime.now().isBefore(until)) {
      most = max(
        most,
        groupCalls.roomFor(group.groupId)?.participants.length ?? 0,
      );
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    final room = groupCalls.roomFor(group.groupId);
    final stats = controller.voiceCallStats;
    await groupCalls.leave();
    timings.add({
      'task': 'group-call',
      'group': group.title,
      'at': started.toUtc().toIso8601String(),
      'participants': room?.participants.length,
      'mostParticipants': most,
      'stats': stats,
      if (room != null) 'frames': _groupCallFrames(room),
    });
    return room?.participants.length;
  });
}

/// Twenty messages to every chat and lab group, half a second apart (not
/// waiting for each), then a 1, a 10 and a 50 MB file to each: how long
/// each took shows in its marks ([_chatReport]).
Future<void> _burst(
  MessengerController controller,
  _Step step,
  List<int> sizes,
) async {
  final me = controller.identity?.displayName ?? 'lab';
  for (var i = 1; i <= 20; i++) {
    for (final contact in _contacts(controller)) {
      await step('burst ${contact.alias} $i', () async {
        await controller.sendMessage(
          contact: contact,
          body: 'lab burst $i from $me to ${contact.alias}',
        );
        return null;
      });
    }
    for (final group in _labGroups(controller)) {
      await step('burst ${group.title} $i', () async {
        await controller.sendGroupMessage(
          groupId: group.groupId,
          body: 'lab burst $i from $me to ${group.title}',
        );
        return null;
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  final folder = await Directory.systemTemp.createTemp('conest-lab-');
  final random = Random();
  for (final size in sizes) {
    final file = File('${folder.path}/lab-$size.bin');
    final out = await file.open(mode: FileMode.write);
    final chunk = Uint8List(min(size, 1024 * 1024));
    for (var written = 0; written < size; written += chunk.length) {
      for (var i = 0; i < chunk.length; i++) {
        chunk[i] = random.nextInt(256);
      }
      await out.writeFrom(chunk);
    }
    await out.close();
    for (final contact in _contacts(controller)) {
      await step('burst file ${contact.alias} $size', () async {
        await controller.sendAttachmentSource(
          contact: contact,
          source: StagedAttachment(
            id: 'lab-burst-$size',
            fileName: 'lab-$size.bin',
            mimeType: 'application/octet-stream',
            sizeBytes: size,
            filePath: file.path,
            presentation: AttachmentPresentation.file,
          ),
        );
        return null;
      });
    }
    for (final group in _labGroups(controller)) {
      await step('burst group file ${group.title} $size', () async {
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

/// Until every outgoing lab message to a contact is confirmed (or failed),
/// at most [limit].
Future<void> _untilConfirmed(
  MessengerController controller,
  Duration limit,
) async {
  bool done() => _contacts(controller).every(
    (contact) => controller
        .messagesFor(contact.deviceId)
        .where((m) => m.outbound && m.body.startsWith('lab burst'))
        .every(
          (m) =>
              m.state == DeliveryState.delivered ||
              m.state == DeliveryState.read ||
              m.state == DeliveryState.failed,
        ),
  );
  final end = DateTime.now().add(limit);
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
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
List<Map<String, Object?>> _chatReport(
  MessengerController controller, {
  DateTime? since,
}) {
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
    // The same, by recipient (group members), for the summary's timings.
    'traces': [
      for (final trace in message.routeTrace)
        {
          'route': trace.route.name,
          'mark': trace.mark.name,
          'ms': trace.at.difference(message.createdAt).inMilliseconds,
          'device': ?trace.deviceId,
        },
    ],
    'bytes': ?(message.attachment?.sizeBytes ?? message.groupFile?.sizeBytes),
    // A file that came in: whether all of it is here (the release gate
    // counts files that never finished).
    if (!message.outbound && message.attachment != null)
      'available': controller.attachmentAvailableLocally(
        message.attachment!.id,
      ),
    if (!message.outbound && message.groupFile != null)
      'available':
          controller.groupFileDownloadState(message.id) ==
          GroupFileDownloadState.complete,
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
      (message.body.startsWith('lab ') ||
          (message.attachment?.fileName ?? message.groupFile?.fileName ?? '')
              .startsWith('lab-')) &&
      (since == null ||
          !(message.outbound ? message.createdAt : message.arrivedAt).isBefore(
            since,
          ));
  return [
    for (final contact in _contacts(controller))
      {
        'contact': contact.alias,
        'deviceId': contact.deviceId,
        // The carriers this device knows an address of theirs on (kinds
        // only): a carrier without one cannot reach them.
        'carriers': [
          for (final kind in TransportKind.values)
            if (kind.isCarrier && contact.carrierAddress(kind) != null)
              kind.name,
        ],
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

/// Links this device and another lab device into one account (see
/// [DebugRunRequest.linkFrom]); returns the code both showed.
Future<String> _linkLabDevices(
  MessengerController controller,
  DebugRunRequest request,
  String path,
) async {
  final deadline = DateTime.now().add(
    request.serve > Duration.zero ? request.serve : const Duration(minutes: 5),
  );
  Future<void> until(bool Function() done, String what) async {
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Waited too long for $what.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  if (request.linkFrom case final text?) {
    await controller.startLinkFromQrCode(text);
  } else {
    await _writeWhole('$path.link', await controller.startLinkAsNewDevice());
  }
  await until(() => controller.linkCode != null, 'the code');
  final code = controller.linkCode!;
  await _writeWhole('$path.code', code);
  final peer = File('$path.peer-code');
  await until(peer.existsSync, "the other device's code");
  if ((await peer.readAsString()).trim() != code) {
    controller.cancelLink();
    throw StateError('The two devices show different codes.');
  }
  await controller.confirmLinkCode();
  await until(() => controller.linkState == LinkState.linked, 'the link');
  return code;
}

/// Whole or not at all: a script waiting for the file never reads half.
Future<void> _writeWhole(String path, String text) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final temporary = File('$path.tmp');
  await temporary.writeAsString(text, flush: true);
  await temporary.rename(file.path);
}

/// What a group call's audio and frames did on this device, read before it
/// leaves (leaving closes the audio and the room).
Map<String, Object?> _groupCallEntry(
  MessengerController controller,
  GroupCallRoom room,
) => {
  'groupCall': room.callId,
  'group': room.groupId,
  'at': DateTime.now().toUtc().toIso8601String(),
  'stats': controller.voiceCallStats,
  'frames': _groupCallFrames(room),
};

Map<String, Object?> _groupCallFrames(GroupCallRoom room) => {
  'sent': Map.of(room.framesSent),
  'heard': Map.of(room.framesHeard),
  'trouble': Map.of(room.frameTrouble),
  'authorityChanges': room.authorityChanges,
  'term': room.term,
  'coordinator': room.coordinator,
};

/// Automatic tests a debug build runs when started for them (Q6), so a
/// device can be tested from a shell over adb or ssh:
///
///   conest --debug-run=routes|messages|files|all|none
///          [--debug-name=NAME]            set up storage and an identity
///          [--debug-relay=HOST:PORT]      add a relay
///          [--debug-accept-invite=CODE]   add a contact (repeatable)
///          [--debug-approve]              approve contact requests
///          [--debug-serve=SECONDS]        wait this long for the others
///          [--debug-group=TITLE]          then make a group of everyone
///          [--debug-no-reserve]           files even on a nearly full disk
///          [--debug-linger=SECONDS]       stay online after the tests
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
  });

  /// 'routes', 'messages', 'files', 'all', or 'none' (only set up).
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

  static const Set<String> kinds = {
    'routes',
    'messages',
    'files',
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
  if (controller.hasIdentity) {
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
  final relay = request.relay;
  if (relay != null) {
    await step('relay', () async {
      final at = relay.lastIndexOf(':');
      final port = int.parse(relay.substring(at + 1));
      await controller.addRelay(host: relay.substring(0, at), port: port);
      return relay;
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
  // Waits for the other devices (and approves them) before testing.
  final serveUntil = DateTime.now().add(request.serve);
  do {
    if (request.approve) {
      for (final pending in controller.pendingContactRequests) {
        await step('approve ${pending.id}', () async {
          await controller.approvePendingContactRequest(pending.id);
          return pending.id;
        });
      }
    }
    if (DateTime.now().isBefore(serveUntil)) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  } while (DateTime.now().isBefore(serveUntil));
  final title = request.group;
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
  await Future<void>.delayed(request.wait);

  final what = request.what;
  final contacts = <Map<String, Object?>>[];
  if (what == 'routes' || what == 'all') {
    for (final contact in _contacts(controller)) {
      try {
        final report = await controller.runTransportExchangeTest(contact);
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
    await _sendMessages(controller, step);
  }
  if (what == 'files' || what == 'all') {
    await _sendFiles(controller, step);
  }
  if (what == 'messages' || what == 'files' || what == 'all') {
    // Time for receipts (and files) to come back.
    await Future<void>.delayed(request.wait * 3);
  }
  await Future<void>.delayed(request.linger);
  final report = {
    'kind': what,
    'build': controller.debugBuildId,
    'deviceId': controller.identity?.deviceId,
    'name': controller.identity?.displayName,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': DateTime.now().toUtc().toIso8601String(),
    'steps': steps,
    'contacts': contacts,
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

Future<void> _sendMessages(MessengerController controller, _Step step) async {
  final me = controller.identity?.displayName ?? 'lab';
  for (final contact in _contacts(controller)) {
    for (var i = 1; i <= 3; i++) {
      await step('message ${contact.alias} $i', () async {
        await controller.sendMessage(
          contact: contact,
          body: 'lab $i from $me to ${contact.alias}',
        );
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
    'recipients': {
      for (final entry in message.recipientStates.entries)
        entry.key: entry.value.name,
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

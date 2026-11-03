/// Gathers what "Report a problem" is built from, using only public
/// getters: transport states as fixed words, the crash records, the error
/// history, and the deny-list of names and servers to replace.
library;

import 'dart:io';

import 'build_info.dart';
import 'crash_catcher.dart';
import 'messenger_controller.dart';
import 'problem_report.dart';

/// Inputs for a report now. [controller] null (or without an identity yet)
/// is the crash notice at start, before the vault is open: the report then
/// has the header and the crash records only.
ProblemReportInputs collectProblemReportInputs({
  required ConestBuildInfo buildInfo,
  required String updateChannel,
  required CrashCatcher crashes,
  MessengerController? controller,
  DateTime? now,
}) {
  final open = controller != null && controller.hasIdentity;
  final transports = <ReportTransportLine>[];
  final deny = <String>[];
  if (open) {
    String state(bool ready, bool error) =>
        error ? 'error' : (ready ? 'ready' : 'not ready');
    for (final status in controller.carrierStatuses) {
      transports.add(
        ReportTransportLine(
          status.kind.name,
          state(status.ready, status.lastError != null),
        ),
      );
      _addAddress(deny, status.address);
    }
    final matrix = controller.matrixStatus;
    if (matrix != null) {
      transports.add(
        ReportTransportLine(
          'matrix',
          state(matrix.signedIn && matrix.syncing, matrix.lastError != null),
        ),
      );
      _addAddress(deny, matrix.userId);
    }
    transports
      ..add(
        ReportTransportLine(
          'localRelay',
          controller.localRelayRunning ? 'ready' : 'not ready',
        ),
      )
      ..add(
        ReportTransportLine(
          'pairingBeacon',
          controller.pairingBeaconRunning ? 'ready' : 'not ready',
        ),
      );
    final me = controller.identity;
    if (me != null) {
      deny
        ..add(me.displayName)
        ..add(me.accountId)
        ..add(me.deviceId);
    }
    for (final contact in controller.contacts) {
      deny
        ..add(contact.alias)
        ..add(contact.displayName);
    }
    for (final group in controller.groups) {
      deny.add(group.title);
      for (final profile in group.memberProfiles) {
        deny.add(profile.displayName);
      }
    }
    for (final relay in controller.configuredRelays) {
      deny.add(relay.host);
    }
    for (final host in controller.defaultRelayHosts) {
      deny.add(host.split(':').first);
    }
  }
  final records = [...crashes.previousRun.records, ...crashes.thisRun];
  return ProblemReportInputs(
    generatedAt: (now ?? DateTime.now()).toUtc(),
    appVersion: buildInfo.version,
    buildNumber: buildInfo.buildNumber,
    buildTag: buildInfo.buildTag,
    commit: buildInfo.commit,
    channel: buildInfo.channelLabel,
    updateChannel: updateChannel,
    platform: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    transports: transports,
    transportsAvailable: open,
    crashes: [
      for (final record in records)
        ReportCrash(record.at, record.kind, record.text),
    ],
    errors: open
        ? [
            for (final entry in controller.errorHistoryEntries)
              ReportError(entry.at, entry.kind, entry.text),
          ]
        : const [],
    errorHistoryAvailable: open && controller.errorHistoryEnabled,
    denyList: deny,
  );
}

/// An address (`user@server`, `@user:server`) is replaced whole, and so are
/// its two halves.
void _addAddress(List<String> deny, String? address) {
  if (address == null || address.isEmpty) return;
  deny.add(address);
  final parts = address.split(RegExp(r'[@:]'));
  for (final part in parts) {
    if (part.length >= 3) deny.add(part);
  }
}

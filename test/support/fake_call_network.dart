import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:conest/src/group_call/group_call_media.dart';
import 'package:conest/src/group_call/group_call_models.dart';
import 'package:conest/src/group_call/group_call_policy.dart';
import 'package:conest/src/group_call/group_call_service.dart';

class FakeCallMedia implements GroupCallMediaEngine {
  final played = <(int, int, Uint8List)>[];
  final participants = <int>{};
  final noise = <bool>[];
  bool opened = false;
  bool muted = false;
  bool enforceJitterSequences = false;
  final _highest = <int, int>{};
  @override
  bool get available => true;
  @override
  Future<void> open(String groupId) async {
    opened = true;
  }

  @override
  Future<void> setMuted(bool value) async {
    muted = value;
  }

  @override
  Future<void> setNoiseSuppression(bool enabled) async {
    noise.add(enabled);
  }

  @override
  void setParticipant(int index, bool active) {
    active ? participants.add(index) : participants.remove(index);
    if (!active) _highest.remove(index);
  }

  @override
  void play(int index, int sequence, Uint8List opus) {
    if (enforceJitterSequences && sequence <= (_highest[index] ?? 0)) return;
    _highest[index] = sequence;
    played.add((index, sequence, Uint8List.fromList(opus)));
  }

  @override
  double level(int index) => played.any((p) => p.$1 == index) ? 0.3 : 0;
  @override
  Future<void> close() async {
    opened = false;
    participants.clear();
    _highest.clear();
  }
}

class FakeCallPolicy implements GroupCallLinkPolicy {
  GroupCallLinkStats stats = const GroupCallLinkStats(
    desktop: true,
    mains: true,
    metered: false,
  );
  @override
  int meshLimit = groupCallMeshLimit;
  @override
  GroupCallLinkStats localStats({
    required int measuredRttMs,
    required double measuredLoss,
  }) => stats;
}

class FakeCallPeer {
  FakeCallPeer(this.id, this.service, this.media, this.policy, this.key);
  final String id;
  final GroupCallService service;
  final FakeCallMedia media;
  final FakeCallPolicy policy;
  final SimpleKeyPair key;
}

class FakeCallDatagram {
  FakeCallDatagram(this.sender, this.recipient, this.bytes);
  final String sender;
  final String recipient;
  final Uint8List bytes;
}

class _Delivery {
  _Delivery(this.at, this.work);
  final DateTime at;
  final Future<void> Function() work;
}

/// Deterministic fake datagrams and authenticated pairwise controls. Delivery
/// is queued: sending a control does not await its recipient's call actor.
class FakeCallNetwork {
  DateTime time = DateTime.utc(2026, 10, 13);
  Duration latency = Duration.zero;
  double loss = 0;

  /// Per-link delay, overriding [latency] (seeded through [random]).
  Duration Function(String from, String to, {required bool datagram})?
  linkDelay;
  Random random = Random(36);
  final peers = <String, FakeCallPeer>{};
  final currentMembers = <String>{};
  final unsupported = <String>{};
  final noRoute = <String>{};
  final dropped = <String>{};
  final blockedLinks = <(String, String)>{};
  final droppedSignals = <(String, String, String)>{};
  final signalGates = <(String, String, String), Future<void>>{};
  final signingGates = <String, Future<void>>{};
  final verificationGates = <(String, String), Future<void>>{};
  final incoming = <(String, String)>[];
  final summaries = <GroupCallSummary>[];
  final datagrams = <FakeCallDatagram>[];
  final signals = <(String, String, GroupCallSignal)>[];
  final _pending = <_Delivery>[];
  int memberLookups = 0;
  List<GroupCallMember> members(String _) => (memberLookups++, currentMembers)
      .$2
      .map(
        (id) => GroupCallMember(
          deviceId: id,
          name: id,
          canJoin: !unsupported.contains(id),
          directRoute: !noRoute.contains(id),
        ),
      )
      .toList();

  Future<FakeCallPeer> add(
    String id, {
    bool Function()? canOpenMedia,
    FakeCallMedia? mediaOverride,
    Future<void> Function(GroupCallSummary summary)? onSummary,
  }) async {
    final key = await Ed25519().newKeyPair();
    final media = mediaOverride ?? FakeCallMedia();
    final policy = FakeCallPolicy();
    currentMembers.add(id);
    final service = GroupCallService(
      localDeviceId: id,
      transport: _Transport(this, id),
      media: media,
      members: members,
      policy: policy,
      now: () => time,
      autoTick: false,
      canOpenMedia: canOpenMedia,
      onIncoming: (room) async {
        incoming.add((id, room.groupId));
      },
      onSummary: (summary) async {
        summaries.add(summary);
        await onSummary?.call(summary);
      },
      sign: (bytes) async {
        await signingGates[id];
        return Uint8List.fromList(
          (await Ed25519().sign(bytes, keyPair: key)).bytes,
        );
      },
      verify: (sender, bytes, signature) async {
        await verificationGates[(id, sender)];
        final peer = peers[sender];
        if (peer == null) return false;
        return Ed25519().verify(
          bytes,
          signature: Signature(
            signature,
            publicKey: await peer.key.extractPublicKey(),
          ),
        );
      },
    );
    final peer = FakeCallPeer(id, service, media, policy, key);
    peers[id] = peer;
    return peer;
  }

  bool _reachable(String a, String b) =>
      !dropped.contains(a) &&
      !dropped.contains(b) &&
      !blockedLinks.contains((a, b));
  void enqueue(
    Future<void> Function() work, {
    bool datagram = false,
    String? from,
    String? to,
  }) {
    if (datagram && random.nextDouble() < loss) return;
    final delay = linkDelay != null && from != null && to != null
        ? linkDelay!(from, to, datagram: datagram)
        : latency;
    _pending.add(_Delivery(time.add(delay), work));
  }

  Future<void> flush() async {
    var budget = 10000;
    while (_pending.any((item) => !item.at.isAfter(time))) {
      if (--budget == 0) throw StateError('Fake call delivery did not settle.');
      final index = _pending.indexWhere((item) => !item.at.isAfter(time));
      final item = _pending.removeAt(index);
      await item.work();
    }
  }

  Future<void> advance(Duration duration) async {
    final end = time.add(duration);
    while (time.isBefore(end)) {
      final remaining = end.difference(time);
      time = time.add(
        remaining < const Duration(milliseconds: 250)
            ? remaining
            : const Duration(milliseconds: 250),
      );
      await flush();
      for (final peer in peers.values) {
        if (!dropped.contains(peer.id)) await peer.service.tick();
      }
      await flush();
    }
  }

  Future<void> connect(Iterable<String> ids) async {
    final list = ids.toList();
    await peers[list.first]!.service.start('group');
    await flush();
    for (final id in list.skip(1)) {
      await peers[id]!.service.join('group');
      await flush();
    }
  }

  Future<void> dispose() async {
    for (final peer in peers.values) {
      await peer.service.dispose();
    }
    _pending.clear();
  }
}

class _Transport implements GroupCallTransport {
  _Transport(this.network, this.sender);
  final FakeCallNetwork network;
  final String sender;
  @override
  Future<void> sendSignal(
    GroupCallSignal signal,
    String recipientDeviceId,
  ) async {
    network.signals.add((sender, recipientDeviceId, signal));
    await network.signalGates[(sender, recipientDeviceId, signal.action)];
    network.enqueue(
      () async {
        if (network._reachable(sender, recipientDeviceId) &&
            !network.droppedSignals.contains((
              sender,
              recipientDeviceId,
              signal.action,
            ))) {
          await network.peers[recipientDeviceId]?.service.receiveSignal(
            signal,
            authenticatedSender: sender,
          );
        }
      },
      from: sender,
      to: recipientDeviceId,
    );
  }

  @override
  Future<void> sendDatagram(
    String groupId,
    String recipientDeviceId,
    Uint8List bytes,
  ) async {
    final copied = Uint8List.fromList(bytes);
    network.datagrams.add(FakeCallDatagram(sender, recipientDeviceId, copied));
    network.enqueue(
      () async {
        if (network._reachable(sender, recipientDeviceId)) {
          await network.peers[recipientDeviceId]?.service.receiveDatagram(
            groupId,
            sender,
            copied,
          );
        }
      },
      datagram: true,
      from: sender,
      to: recipientDeviceId,
    );
  }
}

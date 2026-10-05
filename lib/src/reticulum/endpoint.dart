import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'identity.dart';
import 'packet.dart';

/// A link to a Reticulum network that moves whole packets: a TCP
/// connection to rnsd, or an RNode radio.
abstract interface class RnsInterface {
  Stream<Uint8List> get packets;
  Future<void> send(Uint8List packet);

  /// Completes when the link ends, with the error if there was one.
  Future<Object?> get closed;
  Future<void> close();
}

/// How to reach a destination, learned from its announce.
class RnsPath {
  const RnsPath({
    required this.identity,
    required this.hops,
    required this.learnedAt,
    required this.emittedAt,
    this.nextHop,
  });

  final RnsIdentity identity;

  /// Hops as counted on arrival (1 = a neighbour on the same medium).
  final int hops;

  /// The transport node to send through when [hops] is above 1.
  final Uint8List? nextHop;
  final DateTime learnedAt;

  /// When the destination made the announce (seconds, from the announce).
  final int emittedAt;
}

/// A Reticulum endpoint (not a transport node): announces its own SINGLE
/// destination, learns paths from announces, and sends and receives
/// packets encrypted to destinations.
class RnsEndpoint {
  RnsEndpoint({
    required this.identity,
    required this.nameHash,
    required RnsInterface interface,
    this.onData,
    this.onAnnounce,
    this.acceptAllAnnounces = false,
    DateTime Function()? now,
  }) : _interface = interface,
       _now = now ?? DateTime.now,
       destinationHash = rnsDestinationHash(nameHash, identity.hash) {
    _subscription = interface.packets.listen(
      (raw) => unawaited(
        _handle(raw).catchError((Object _) {
          // A packet that cannot be handled (or answered) is dropped.
        }),
      ),
    );
  }

  final RnsIdentity identity;

  /// The 10-byte name hash of this endpoint's destination.
  final Uint8List nameHash;
  final Uint8List destinationHash;
  final RnsInterface _interface;
  final DateTime Function() _now;

  /// Decrypted data addressed to this endpoint.
  final void Function(Uint8List data)? onData;

  /// Valid announces of destinations this endpoint watches.
  final void Function(RnsAnnounce announce)? onAnnounce;

  /// Check and keep every announce heard, not only watched destinations
  /// (diagnostics and tests; each check costs a signature verification).
  final bool acceptAllAnnounces;

  late final StreamSubscription<Uint8List> _subscription;
  final LinkedHashMap<String, RnsPath> _paths = LinkedHashMap();
  final LinkedHashSet<String> _watched = LinkedHashSet();
  final LinkedHashSet<String> _seen = LinkedHashSet();
  final Map<String, Completer<void>> _pathWaiters = {};
  static const int _maxSeen = 4096;
  static const int _maxPaths = 1024;
  static const int _maxWatched = 1024;

  static final Uint8List _pathRequestDestination = rnsTruncatedHash(
    rnsNameHash('rnstransport', const ['path', 'request']),
  );

  RnsPath? pathTo(Uint8List destination) => _paths[_key(destination)];

  /// Keeps paths to [destination] from now on: its announces are checked
  /// and remembered. Announces of other destinations are ignored unhurt,
  /// so a busy network costs no signature checks.
  void watch(Uint8List destination) {
    final key = _key(destination);
    _watched
      ..remove(key)
      ..add(key);
    if (_watched.length > _maxWatched) _watched.remove(_watched.first);
  }

  Future<void> close() => _subscription.cancel();

  /// Announces this endpoint so the network learns a path to it.
  Future<void> announce({
    List<int> appData = const [],
    bool pathResponse = false,
  }) async {
    final packet = await RnsAnnounce.build(
      identity,
      nameHash,
      appData: appData,
      timeSeconds: _now().millisecondsSinceEpoch ~/ 1000,
      pathResponse: pathResponse,
    );
    await _interface.send(packet.pack());
  }

  DateTime? _lastPathResponse;

  /// Someone looks for this endpoint: answer with an announce, at most
  /// every ten seconds.
  Future<void> _answerPathRequest() async {
    final now = _now();
    final last = _lastPathResponse;
    if (last != null && now.difference(last) < const Duration(seconds: 10)) {
      return;
    }
    _lastPathResponse = now;
    await announce(pathResponse: true);
  }

  /// Asks the network for a path to [destination] and waits up to
  /// [timeout] for the answering announce.
  Future<bool> requestPath(Uint8List destination, {Duration? timeout}) async {
    final key = _key(destination);
    if (_paths.containsKey(key)) return true;
    watch(destination);
    final random = Random.secure();
    final packet = RnsPacket(
      packetType: RnsPacketType.data,
      destinationType: RnsDestinationType.plain,
      destinationHash: _pathRequestDestination,
      data: Uint8List.fromList([
        ...destination,
        ...List<int>.generate(16, (_) => random.nextInt(256)),
      ]),
    );
    final waiter = _pathWaiters.putIfAbsent(key, Completer<void>.new);
    try {
      await _interface.send(packet.pack());
      await waiter.future.timeout(timeout ?? const Duration(seconds: 15));
      return true;
    } on TimeoutException {
      return false;
    } finally {
      if (identical(_pathWaiters[key], waiter)) _pathWaiters.remove(key);
    }
  }

  /// Encrypts [data] to [recipient]'s SINGLE destination named by
  /// [recipientNameHash] (this endpoint's own name by default), and sends
  /// it along the known path (or to neighbours).
  Future<void> sendTo(
    RnsIdentity recipient,
    List<int> data, {
    Uint8List? recipientNameHash,
  }) async {
    if (data.length > rnsEncryptedMdu) {
      throw ArgumentError('Reticulum packet data is too large.');
    }
    final destination = rnsDestinationHash(
      recipientNameHash ?? nameHash,
      recipient.hash,
    );
    watch(destination);
    final path = _paths[_key(destination)];
    final packet = RnsPacket(
      packetType: RnsPacketType.data,
      destinationType: RnsDestinationType.single,
      destinationHash: destination,
      data: await recipient.encrypt(data),
      transportId: path != null && path.hops > 1 ? path.nextHop : null,
    );
    await _interface.send(packet.pack());
  }

  Future<void> _handle(Uint8List raw) async {
    final packet = RnsPacket.unpack(raw);
    if (packet == null) return;
    // Hops count the way Reticulum does: one more on arrival.
    final hops = packet.hops + 1;
    if (packet.packetType == RnsPacketType.announce) {
      // Announces are not deduplicated by hash: a path response repeats a
      // cached announce byte for byte, and must still restore a path.
      final key = _key(packet.destinationHash);
      if (!acceptAllAnnounces &&
          !_watched.contains(key) &&
          !_pathWaiters.containsKey(key)) {
        return;
      }
      final announce = await RnsAnnounce.validate(packet);
      if (announce == null) return;
      final emittedAt = announce.emittedAt;
      final known = _paths[key];
      // An older announce (a replay) must not move a fresher path.
      if (known != null && emittedAt < known.emittedAt) return;
      _paths.remove(key);
      if (_paths.length >= _maxPaths) {
        final victim = _paths.keys.firstWhere(
          (candidate) => !_watched.contains(candidate),
          orElse: () => _paths.keys.first,
        );
        _paths.remove(victim);
      }
      _paths[key] = RnsPath(
        identity: announce.identity,
        hops: hops,
        nextHop: announce.transportId,
        learnedAt: _now(),
        emittedAt: emittedAt,
      );
      _pathWaiters.remove(key)?.complete();
      onAnnounce?.call(announce);
      return;
    }
    final hash = _key(packet.hash);
    if (_seen.contains(hash)) return;
    _seen.add(hash);
    if (_seen.length > _maxSeen) _seen.remove(_seen.first);
    switch (packet.packetType) {
      case RnsPacketType.data
          when packet.destinationType == RnsDestinationType.plain &&
              _bytesEqual(packet.destinationHash, _pathRequestDestination) &&
              packet.data.length >= rnsTruncatedHashBytes &&
              _bytesEqual(
                packet.data.sublist(0, rnsTruncatedHashBytes),
                destinationHash,
              ):
        await _answerPathRequest();
      case RnsPacketType.data
          when packet.destinationType == RnsDestinationType.single &&
              _bytesEqual(packet.destinationHash, destinationHash):
        final clear = await identity.decrypt(packet.data);
        if (clear != null) onData?.call(clear);
      default:
        break;
    }
  }

  static String _key(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

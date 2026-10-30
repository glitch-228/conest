import 'route_striper.dart';

/// How a source delivers blocks. Not persisted (a source only lives as long
/// as the transfer is running in this process), but only ever appended to.
enum SourceRoute {
  /// A device of a peer or of this account, asked for blocks over the
  /// ordinary file-block path (LAN, Iroh, relays).
  peer,

  /// A relay that holds the encrypted blocks as blobs (M27 tier 2).
  relayBlob,
}

/// One place a file's blocks can be fetched from: a device and the way its
/// blocks come, or a relay's blob store.
class BlockSource {
  const BlockSource(this.route, this.id);
  const BlockSource.peer(String deviceId) : this(SourceRoute.peer, deviceId);
  const BlockSource.relayBlob(String relayId)
    : this(SourceRoute.relayBlob, relayId);

  final SourceRoute route;

  /// The device id, or the relay's key.
  final String id;

  @override
  bool operator ==(Object other) =>
      other is BlockSource && other.route == route && other.id == id;

  @override
  int get hashCode => Object.hash(route, id);

  @override
  String toString() => '${route.name}:$id';
}

/// The places one file's blocks come from, and which block was asked of
/// which. Blocks go to the source that would deliver them soonest (shared
/// with what is already on it, by measured speed); a source that fails
/// rests; a block that is late is asked of a second source too, within the
/// hedging budget; a source that serves a bad block is dropped for this
/// file. Every block is verified by the caller (the AEAD under the file
/// key), whichever source it came from.
///
/// Pure bookkeeping with an injectable clock: the caller sends and
/// receives.
class BlockSourceSet {
  BlockSourceSet({
    required BlockSource primary,
    required this.blockBytes,
    DateTime Function()? now,
    this.maxSources = 4,
    this.windowPerSource = 8,
    Map<BlockSource, double> priorBytesPerSecond = const {},
  }) : _now = now ?? DateTime.now,
       striper = RouteStriper<BlockSource>(
         now: now,
         priorBytesPerSecond: priorBytesPerSecond,
       ) {
    _sources.add(primary);
  }

  final DateTime Function() _now;

  /// Bytes in one block, for the hedging budget.
  final int blockBytes;

  /// At most this many sources (dropped ones do not count, and do not come
  /// back for this file).
  final int maxSources;

  /// At most this many blocks asked of one source at a time.
  final int windowPerSource;

  final RouteStriper<BlockSource> striper;

  final List<BlockSource> _sources = [];
  final Set<BlockSource> _dropped = {};
  final Map<int, List<_Request>> _requests = {};
  final Map<BlockSource, int> _delivered = {};

  /// Most sources remembered as dropped (a hostile feed of devices cannot
  /// grow this).
  static const int _maxDropped = 64;

  List<BlockSource> get sources => List.unmodifiable(_sources);
  bool contains(BlockSource source) => _sources.contains(source);
  bool wasDropped(BlockSource source) => _dropped.contains(source);

  /// Blocks [source] delivered for this file.
  int deliveredBy(BlockSource source) => _delivered[source] ?? 0;

  /// Blocks asked of [source] and not delivered yet.
  int inFlightOn(BlockSource source) {
    var count = 0;
    for (final requests in _requests.values) {
      for (final request in requests) {
        if (request.source == source) count++;
      }
    }
    return count;
  }

  /// Whether any block is asked and not delivered.
  bool get hasRequests => _requests.isNotEmpty;

  /// Takes [source] in, unless it is one already, was dropped for this
  /// file, or there are enough. True when added.
  bool add(BlockSource source) {
    if (_sources.contains(source) || _dropped.contains(source)) return false;
    if (_sources.length >= maxSources) return false;
    _sources.add(source);
    return true;
  }

  /// Takes [source] out for good (for this file): its asked blocks are
  /// released, and the indices that no other source was asked for are
  /// returned (to be asked again).
  List<int> drop(BlockSource source) {
    final released = _release(source);
    if (_sources.remove(source) && _dropped.length < _maxDropped) {
      _dropped.add(source);
    }
    return released;
  }

  /// Takes [source] out because it is gone for now (not blamed): it may be
  /// added again. Returns the indices to be asked again, as [drop].
  List<int> remove(BlockSource source) {
    final released = _release(source);
    _sources.remove(source);
    return released;
  }

  List<int> _release(BlockSource source) {
    final orphaned = <int>[];
    for (final index in _requests.keys.toList()) {
      final requests = _requests[index]!;
      for (final request in requests.where((r) => r.source == source)) {
        striper.cancelled(request.lease);
      }
      requests.removeWhere((r) => r.source == source);
      if (requests.isEmpty) {
        _requests.remove(index);
        orphaned.add(index);
      }
    }
    return orphaned;
  }

  /// Forgets asked blocks that are no longer outstanding in [stillAsked]
  /// (the caller keeps that set; whatever left it without being delivered
  /// is cancelled here, without blame).
  void reconcile(Set<int> stillAsked) {
    for (final index in _requests.keys.toList()) {
      if (stillAsked.contains(index)) continue;
      for (final request in _requests.remove(index)!) {
        striper.cancelled(request.lease);
      }
    }
  }

  /// The source the next request for [index] goes to: the best of those
  /// with room, not asked for [index] already. Sources that failed lately
  /// are used only when no other works, and then one block at a time.
  /// Null when every source is full (or none is left).
  BlockSource? choose(int index) {
    final asked = {
      for (final request in _requests[index] ?? const <_Request>[])
        request.source,
    };
    final counts = <BlockSource, int>{};
    for (final requests in _requests.values) {
      for (final request in requests) {
        counts[request.source] = (counts[request.source] ?? 0) + 1;
      }
    }
    final withRoom = [
      for (final source in _sources)
        if (!asked.contains(source) &&
            (counts[source] ?? 0) < windowPerSource)
          source,
    ];
    if (withRoom.isEmpty) return null;
    final resting = withRoom.where(striper.isResting).toList();
    final working = withRoom.where((s) => !striper.isResting(s)).toList();
    if (working.isNotEmpty) return striper.order(working).first;
    // Only sources that failed lately: one block at a time, to find out
    // whether they are back.
    final idle = resting.where((s) => (counts[s] ?? 0) == 0).toList();
    return idle.isEmpty ? null : striper.order(idle).first;
  }

  /// [index] is asked of [source].
  void begin(int index, BlockSource source, {bool hedge = false}) {
    final requests = _requests.putIfAbsent(index, () => []);
    if (requests.any((r) => r.source == source)) return;
    final probing = striper.unmeasured(source);
    requests.add(
      _Request(
        source,
        striper.begin(source, blockBytes, hedge: hedge, probing: probing),
        _now(),
        hedge,
      ),
    );
  }

  /// [index] arrived from [source] (verified by the caller). Other asks
  /// for it are cancelled without blame. Returns whether it had been asked
  /// of [source].
  bool delivered(int index, BlockSource source) {
    final requests = _requests.remove(index);
    var asked = false;
    for (final request in requests ?? const <_Request>[]) {
      if (request.source == source) {
        asked = true;
        striper.succeeded(request.lease);
      } else {
        striper.cancelled(request.lease);
      }
    }
    _delivered[source] = (_delivered[source] ?? 0) + 1;
    // A block that came after its ask was forgotten (a stall that ended):
    // the source works after all.
    if (!asked && _sources.contains(source)) striper.heardFrom(source);
    return asked;
  }

  /// The ask for [index] on [source] did not go through (or got no
  /// answer): [source] rests.
  void failed(int index, BlockSource source) {
    final requests = _requests[index];
    if (requests == null) return;
    for (final request in requests.where((r) => r.source == source).toList()) {
      striper.failed(request.lease);
      requests.remove(request);
    }
    if (requests.isEmpty) _requests.remove(index);
  }

  /// Nothing arrived in time: every asked block counts as failed on its
  /// source, and all are forgotten (to be asked again).
  void timedOut() {
    for (final requests in _requests.values) {
      for (final request in requests) {
        striper.failed(request.lease);
      }
    }
    _requests.clear();
  }

  /// [source] served a bad block for [index]. It is dropped for this file
  /// unless it is the only source left (then it is asked again, as before
  /// there were several). Returns the indices to be asked again (the bad
  /// one included) when dropped; empty when kept.
  List<int> corrupt(int index, BlockSource source) {
    if (!_sources.contains(source)) return const [];
    if (_sources.length <= 1) {
      failed(index, source);
      return const [];
    }
    final released = drop(source);
    return {...released, index}.toList();
  }

  /// How long until a block asked of one source only is late enough to be
  /// asked of a second too; null when nothing can be hedged.
  Duration? nextHedgeIn() {
    if (_sources.length < 2) return null;
    final now = _now();
    Duration? soonest;
    for (final requests in _requests.values) {
      if (requests.length != 1 || requests.single.hedge) continue;
      final request = requests.single;
      final due = request.at.add(striper.hedgeDelay(request.source));
      final wait = due.difference(now);
      final clamped = wait.isNegative ? Duration.zero : wait;
      if (soonest == null || clamped < soonest) soonest = clamped;
    }
    return soonest;
  }

  /// Blocks that are late on their only source, each paired with the
  /// second source it is now also asked of (the asks are recorded; the
  /// caller sends them), within the hedging budget.
  List<(int, BlockSource)> takeHedges() {
    if (_sources.length < 2) return const [];
    final now = _now();
    final due = <int>[];
    for (final entry in _requests.entries) {
      final requests = entry.value;
      if (requests.length != 1 || requests.single.hedge) continue;
      final request = requests.single;
      if (now.difference(request.at) >= striper.hedgeDelay(request.source)) {
        due.add(entry.key);
      }
    }
    due.sort();
    final taken = <(int, BlockSource)>[];
    for (final index in due) {
      final primary = _requests[index]!.single.source;
      striper.noteLate(primary);
      final backup = choose(index);
      if (backup == null) continue;
      if (!striper.mayHedge(
        blockBytes,
        probing: striper.unmeasured(primary) || striper.unmeasured(backup),
      )) {
        continue;
      }
      begin(index, backup, hedge: true);
      taken.add((index, backup));
    }
    return taken;
  }
}

class _Request {
  _Request(this.source, this.lease, this.at, this.hedge);
  final BlockSource source;
  final StripeLease<BlockSource> lease;
  final DateTime at;
  final bool hedge;
}

/// Which of the account's other devices said they hold which file (bounded:
/// a hostile or buggy device cannot grow it). Process-local; devices say it
/// again when asked.
class OwnDeviceFileIndex {
  OwnDeviceFileIndex({this.maxFiles = 256, this.maxDevicesPerFile = 8});

  final int maxFiles;
  final int maxDevicesPerFile;
  final Map<String, Set<String>> _byFile = {};

  /// [deviceId] holds [attachmentId]. False when it was refused (too many
  /// devices for the file) or known already.
  bool note(String attachmentId, String deviceId) {
    final existing = _byFile.remove(attachmentId);
    final devices = existing ?? <String>{};
    // Most recently noted files stay.
    _byFile[attachmentId] = devices;
    while (_byFile.length > maxFiles) {
      _byFile.remove(_byFile.keys.first);
    }
    if (devices.contains(deviceId) || devices.length >= maxDevicesPerFile) {
      return false;
    }
    devices.add(deviceId);
    return true;
  }

  Set<String> devicesWith(String attachmentId) =>
      Set.unmodifiable(_byFile[attachmentId] ?? const <String>{});

  /// [deviceId] no longer counts (unlinked, or it lost the file).
  void forgetDevice(String deviceId) {
    for (final devices in _byFile.values) {
      devices.remove(deviceId);
    }
  }

  void forgetFile(String attachmentId) => _byFile.remove(attachmentId);

  int get fileCount => _byFile.length;
}

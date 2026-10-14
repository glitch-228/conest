import 'package:conest/src/ratchet.dart';

/// Observes durable effects while retaining the real store's I/O behavior.
class ObservingRatchetStore implements RatchetStore {
  ObservingRatchetStore(this.delegate, this.onPeerWrite, this.beforePeerWrite);
  final RatchetStore delegate;
  final void Function(RatchetPeerState) onPeerWrite;
  final Future<void> Function() beforePeerWrite;

  @override
  List<int> get pickleKey => delegate.pickleKey;
  @override
  Future<String?> readAccount() => delegate.readAccount();
  @override
  Future<void> writeAccount(String pickle) => delegate.writeAccount(pickle);
  @override
  Future<RatchetPeerState?> readPeer(String deviceId) =>
      delegate.readPeer(deviceId);
  @override
  Future<void> deletePeer(String deviceId) => delegate.deletePeer(deviceId);
  @override
  Future<void> writePeer(String deviceId, RatchetPeerState state) async {
    await beforePeerWrite();
    await delegate.writePeer(deviceId, state);
    onPeerWrite(state);
  }
}

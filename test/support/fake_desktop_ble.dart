import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conest/src/bitchat/desktop_links.dart';
import 'package:conest/src/bitchat/mesh.dart';

/// Fake native poll source, optionally connected to the existing BLE mesh.
class FakeDesktopBleNative implements DesktopBleNative {
  FakeDesktopBleNative({this.links});

  final BitchatLinkLayer? links;
  final limits = <String, int>{};
  final events = <Map<String, dynamic>>[];
  final sends = <(String, Uint8List)>[];
  final broadcasts = <(Uint8List, String?)>[];
  final _ids = <String, String>{};
  final status = <String, dynamic>{
    'adapter': 'Mock adapter',
    'powered': true,
    'central': true,
    'peripheral': true,
    'problem': null,
    'droppedEvents': 0,
    'droppedInput': 0,
  };
  bool opened = false;
  int closes = 0;
  bool failOpen = false;
  bool failPoll = false;
  bool acceptSend = true;
  int broadcastCount = 1;
  StreamSubscription<(String, Uint8List)>? _subscription;

  String idFor(String peer) => _ids.putIfAbsent(
    peer,
    () => 'ble:${(_ids.length + 1).toRadixString(16).padLeft(16, '0')}',
  );

  @override
  Future<void> open() async {
    if (failOpen) throw StateError('fake open failure');
    opened = true;
    _subscription = links?.received.listen((event) {
      if (events.length >= 256) events.removeAt(0);
      events.add({'link': idFor(event.$1), 'data': base64Encode(event.$2)});
    });
  }

  @override
  Map<String, dynamic> poll() {
    if (failPoll) throw StateError('fake poll failure');
    final radio = links;
    if (radio != null) {
      limits
        ..clear()
        ..addEntries(
          radio.linkLimits.entries.map((e) => MapEntry(idFor(e.key), e.value)),
        );
    }
    final batch = events.take(32).toList();
    events.removeRange(0, batch.length);
    return {
      'events': batch,
      'links': {...limits},
      'status': {...status},
    };
  }

  @override
  bool sendTo(String link, Uint8List packet) {
    if (!acceptSend) return false;
    sends.add((link, Uint8List.fromList(packet)));
    final radio = links;
    if (radio != null) {
      final peer = _ids.entries.where((e) => e.value == link).firstOrNull?.key;
      if (peer == null) return false;
      unawaited(radio.sendTo(peer, packet));
    }
    return true;
  }

  @override
  int broadcast(Uint8List packet, {String? except}) {
    broadcasts.add((Uint8List.fromList(packet), except));
    final radio = links;
    if (radio == null) return broadcastCount;
    final skip = _ids.entries.where((e) => e.value == except).firstOrNull?.key;
    var sent = 0;
    for (final peer in radio.linkLimits.keys) {
      if (peer == skip || packet.length > radio.linkLimits[peer]!) continue;
      unawaited(radio.sendTo(peer, packet));
      sent++;
    }
    return sent;
  }

  @override
  Future<void> close() async {
    closes++;
    await _subscription?.cancel();
  }
}

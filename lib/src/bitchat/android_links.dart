import 'dart:async';

import 'package:flutter/services.dart';

import '../radio/android_radio_link.dart';
import 'mesh.dart';

/// The bitchat Bluetooth mesh through the Android BitchatBlePlugin: each
/// neighbour (as central or peripheral) is a link.
class AndroidBitchatLinks implements BitchatLinkLayer {
  AndroidBitchatLinks._();

  static const _methods = MethodChannel('dev.conest/bitchat');
  static const _events = EventChannel('dev.conest/bitchat/events');

  /// Starts advertising and scanning; asks for Bluetooth access first.
  static Future<AndroidBitchatLinks> start() async {
    if (!await AndroidRadioLinks.requestBluetoothPermission()) {
      throw StateError('Bluetooth access was not allowed.');
    }
    final links = AndroidBitchatLinks._();
    links._subscription = _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      if (event.containsKey('problem')) {
        links._problems.add(event['problem'] as String?);
        return;
      }
      final link = event['link'];
      if (link is! String) return;
      final data = event['data'];
      if (data is Uint8List) {
        links._received.add((link, data));
      } else if (event['up'] case final bool up) {
        if (up) {
          links.neighbours.add(link);
          links._limits[link] ??= 512;
        } else {
          links.neighbours.remove(link);
          links._limits.remove(link);
        }
        links._changes.add(null);
      }
      // The largest write the link takes (its ATT MTU minus 3).
      if (event['limit'] case final int limit when limit > 0) {
        links._limits[link] = limit;
      }
    });
    try {
      await _methods.invokeMethod<void>('start');
    } catch (_) {
      await links._subscription.cancel();
      await links._received.close();
      await links._changes.close();
      await links._problems.close();
      rethrow;
    }
    return links;
  }

  late final StreamSubscription<Object?> _subscription;
  final _received = StreamController<(String, Uint8List)>.broadcast();
  final _changes = StreamController<void>.broadcast();
  final _problems = StreamController<String?>.broadcast();

  /// Links to neighbours currently connected.
  final Set<String> neighbours = {};
  final Map<String, int> _limits = {};

  @override
  Map<String, int> get linkLimits => Map.unmodifiable(_limits);

  @override
  Future<void> sendTo(String link, Uint8List packet) async {
    final sent = await _methods.invokeMethod<bool>('sendTo', {
      'link': link,
      'bytes': packet,
    });
    if (sent != true) throw StateError('That phone is no longer nearby.');
  }

  Stream<void> get neighbourChanges => _changes.stream;

  @override
  Stream<(String, Uint8List)> get received => _received.stream;

  @override
  Stream<String?> get problems => _problems.stream;

  @override
  Future<void> broadcast(Uint8List packet, {String? except}) async {
    final sent = await _methods.invokeMethod<int>('broadcast', {
      'bytes': packet,
      'except': except,
    });
    if (except == null && (sent ?? 0) == 0) {
      throw StateError('No phones nearby.');
    }
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    try {
      await _methods.invokeMethod<void>('stop');
    } catch (_) {}
    await _received.close();
    await _changes.close();
    await _problems.close();
  }
}

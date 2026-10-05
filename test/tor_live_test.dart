// Runs over the real Tor network when CONEST_TOR_LIVE is set and the native
// library (CONEST_NATIVE_LIBRARY) has Arti: the device bootstraps, publishes
// its onion service and sends frames to itself through it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/tor_carrier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final skip = Platform.environment['CONEST_TOR_LIVE'] == null
      ? 'CONEST_TOR_LIVE is not set'
      : null;

  test(
    'frames reach this device through its own onion service',
    () async {
      final api = NativeTorApi.tryCreate();
      expect(api, isNotNull, reason: 'the native library has no Tor module');
      final directory = await Directory.systemTemp.createTemp('conest-tor-');
      addTearDown(() => directory.delete(recursive: true));
      final frames = <Uint8List>[];
      final progress = <double>[];
      final subscription = api!.events.listen((event) {
        switch (event['type']) {
          case 'frame':
            frames.add(base64Decode(event['data'] as String));
          case 'bootstrap':
            progress.add((event['fraction'] as num).toDouble());
        }
      });
      addTearDown(subscription.cancel);
      final state = Directory('${directory.path}/state')..createSync();
      final cache = Directory('${directory.path}/cache')..createSync();
      final address = await api.start(
        stateDirectory: state.path,
        cacheDirectory: cache.path,
        bridges: const [],
      );
      expect(isValidTorAddress(address), isTrue, reason: address);
      expect(progress, isNotEmpty);
      // A big frame and a small one, on the same cached stream; the onion
      // service may take a while to be published, so the first send retries.
      final big = Uint8List.fromList(
        List.generate(900 * 1024, (index) => index * 31),
      );
      final deadline = DateTime.now().add(const Duration(minutes: 6));
      while (true) {
        try {
          await api.send(address, big);
          break;
        } catch (error) {
          if (DateTime.now().isAfter(deadline)) rethrow;
          printOnFailure('send failed, retrying: $error');
          await Future<void>.delayed(const Duration(seconds: 10));
        }
      }
      await api.send(address, Uint8List.fromList([1, 2, 3]));
      while (frames.length < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(frames, hasLength(2));
      expect(frames.first, big);
      expect(frames.last, [1, 2, 3]);

      // Stopping and starting again keeps the address (keys persist).
      await api.stop();
      final again = await api.start(
        stateDirectory: state.path,
        cacheDirectory: cache.path,
        bridges: const [],
      );
      expect(again, address);
      await api.stop();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

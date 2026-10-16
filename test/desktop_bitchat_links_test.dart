import 'dart:convert';
import 'dart:typed_data';

import 'package:conest/src/bitchat/desktop_links.dart';
import 'package:conest/src/bitchat/platform_links.dart';
import 'package:conest/src/bitchat_carrier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_desktop_ble.dart';

const link = 'ble:0000000000000001';
const second = 'ble:0000000000000002';

void main() {
  test('Linux and Windows select the desktop connector', () async {
    for (final os in ['linux', 'windows']) {
      final native = FakeDesktopBleNative();
      final selected = await openPlatformBitchatLinks(
        operatingSystem: os,
        openDesktop: () => DesktopBitchatLinks.start(native: native),
        openAndroid: () => throw StateError('Android connector selected'),
      );
      expect(selected, isA<DesktopBitchatLinks>());
      expect(native.opened, isTrue);
      await selected.close();
    }
  });

  Future<DesktopBitchatLinks> start(FakeDesktopBleNative native) async {
    final links = await DesktopBitchatLinks.start(
      native: native,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(links.close);
    return links;
  }

  test(
    'native packets, link snapshots and problem recovery reach Dart',
    () async {
      final native = FakeDesktopBleNative()..limits[link] = 182;
      final links = await start(native);
      final packets = <(String, Uint8List)>[];
      final problems = <String?>[];
      final received = links.received.listen(packets.add);
      final reports = links.problems.listen(problems.add);
      addTearDown(received.cancel);
      addTearDown(reports.cancel);
      await Future<void>.delayed(Duration.zero);
      native.status['problem'] = 'This adapter cannot advertise.';
      native.events.add({
        'link': link,
        'data': base64Encode([1, 2, 3]),
      });
      links.pollNow();
      expect(native.opened, isTrue);
      expect(links.linkLimits, {link: 182});
      expect(packets.single.$1, link);
      expect(packets.single.$2, [1, 2, 3]);
      expect(problems.last, 'This adapter cannot advertise.');
      expect(links.adapterSummary, contains('Mock adapter'));
      expect(() => links.linkLimits[second] = 512, throwsUnsupportedError);

      native.limits
        ..clear()
        ..[second] = 100;
      native.status['problem'] = null;
      native.status['droppedEvents'] = 72;
      native.status['droppedInput'] = 91;
      links.pollNow();
      expect(links.linkLimits, {second: 100});
      expect(links.neighbours, {second});
      expect(problems.last, isNull);
      expect(links.droppedNativeEvents, 72);
      expect(links.droppedNativeInput, 91);
    },
  );

  test('send and broadcast preserve bytes and the excluded link', () async {
    final native = FakeDesktopBleNative()..limits[link] = 182;
    final links = await start(native);
    links.pollNow();
    final packet = Uint8List.fromList([1, 2, 3]);
    await links.sendTo(link, packet);
    await links.broadcast(packet, except: link);
    expect(native.sends.single.$1, link);
    expect(native.sends.single.$2, packet);
    expect(native.broadcasts.single.$1, packet);
    expect(native.broadcasts.single.$2, link);
    await expectLater(links.sendTo(link, Uint8List(183)), throwsStateError);
    await expectLater(links.sendTo(second, packet), throwsStateError);
    expect(native.sends, hasLength(1));
    native.acceptSend = false;
    await expectLater(links.sendTo(link, packet), throwsStateError);
    native.broadcastCount = 0;
    await expectLater(links.broadcast(packet), throwsStateError);
    await links.broadcast(packet, except: link); // relaying to nobody is fine
    await expectLater(links.broadcast(Uint8List(513)), throwsArgumentError);
  });

  test('malformed, oversized and stale radio events are dropped', () async {
    final native = FakeDesktopBleNative()..limits[link] = 512;
    native.limits['bad'] = 20;
    native.limits[second] = 999999;
    final links = await start(native);
    final packets = <(String, Uint8List)>[];
    final sub = links.received.listen(packets.add);
    addTearDown(sub.cancel);
    native.events.addAll([
      {'link': link, 'data': '?'},
      {
        'link': second,
        'data': base64Encode([1]),
      },
      {'link': link, 'data': base64Encode(Uint8List(4097))},
      {'link': link, 'data': ''},
      {'link': link, 'data': 42},
      {
        'link': link,
        'data': base64Encode([9]),
      },
    ]);
    links.pollNow();
    expect(links.linkLimits, {link: 512});
    expect(packets, hasLength(1));
    expect(packets.single.$2, [9]);
  });

  test('paused consumers cannot accumulate radio packets', () async {
    final native = FakeDesktopBleNative()..limits[link] = 512;
    final links = await start(native);
    final packets = <(String, Uint8List)>[];
    final sub = links.received.listen(packets.add)..pause();
    addTearDown(sub.cancel);
    for (var i = 0; i < 1000; i++) {
      native.events.add({
        'link': link,
        'data': base64Encode([1]),
      });
      links.pollNow();
    }
    expect(links.droppedPausedEvents, 1000);
    sub.resume();
    await Future<void>.delayed(Duration.zero);
    expect(packets, isEmpty);
    native.events.add({
      'link': link,
      'data': base64Encode([2]),
    });
    links.pollNow();
    expect(packets.single.$2, [2]);
  });

  test('poll failures clear stale links and a new snapshot recovers', () async {
    final native = FakeDesktopBleNative()..limits[link] = 512;
    final links = await start(native);
    final problems = <String?>[];
    final sub = links.problems.listen(problems.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(Duration.zero);
    links.pollNow();
    native.failPoll = true;
    links.pollNow();
    expect(links.linkLimits, isEmpty);
    expect(problems.last, contains('Bluetooth connection failed'));
    native.failPoll = false;
    links.pollNow();
    expect(links.linkLimits, {link: 512});
    expect(problems.last, isNull);
  });

  test(
    'close is idempotent and does not wait for paused streams',
    () async {
      final native = FakeDesktopBleNative()..limits[link] = 512;
      final links = await start(native);
      final sub = links.received.listen((_) {})..pause();
      await Future.wait([links.close(), links.close()]);
      expect(native.closes, 1);
      links.pollNow();
      expect(links.linkLimits, isEmpty);
      await expectLater(links.sendTo(link, Uint8List(1)), throwsStateError);
      await expectLater(links.broadcast(Uint8List(1)), throwsStateError);
      await sub.cancel();
    },
  );

  test('failed start releases the native source', () async {
    final native = FakeDesktopBleNative()..failOpen = true;
    await expectLater(
      DesktopBitchatLinks.start(native: native),
      throwsStateError,
    );
    expect(native.closes, 1);
  });

  test(
    'carrier retains central-only warning and exposes adapter state',
    () async {
      final native = FakeDesktopBleNative()..limits[link] = 182;
      native.status['peripheral'] = false;
      native.status['problem'] = 'Nearby phones cannot find this computer.';
      late DesktopBitchatLinks desktop;
      final channel = BitchatCarrierChannel(
        config: BitchatCarrierConfig.create(),
        connector: () async => desktop = await start(native),
        keyFor: (_) async => [],
        onFrame: (_, _) {},
      );
      addTearDown(channel.stop);
      channel.start();
      await Future<void>.delayed(Duration.zero);
      desktop.pollNow();
      expect(channel.state, BitchatCarrierState.running);
      expect(channel.lastError, 'Nearby phones cannot find this computer.');
      expect(channel.adapterStatus, contains('connecting'));
    },
  );
}

import 'dart:async';

import 'package:flutter/services.dart';

import 'byte_link.dart';

/// A USB serial device Android can open.
class AndroidUsbDevice {
  const AndroidUsbDevice({
    required this.id,
    required this.name,
    required this.supported,
  });

  /// The system device name, such as `/dev/bus/usb/001/002`.
  final String id;
  final String name;

  /// Whether a serial driver knows the device.
  final bool supported;
}

/// A Bluetooth LE device seen in a scan.
class AndroidBleDevice {
  const AndroidBleDevice({
    required this.address,
    required this.name,
    required this.rssi,
  });

  final String address;
  final String name;
  final int rssi;
}

/// Radio links through the Android RadioLinkPlugin: USB serial and
/// Bluetooth LE serial (Nordic UART service).
abstract final class AndroidRadioLinks {
  static const _methods = MethodChannel('dev.conest/radio');
  static const _events = EventChannel('dev.conest/radio/events');
  static const _system = MethodChannel('dev.conest.conest/system');

  static final Map<int, AndroidRadioLink> _open = {};
  static StreamSubscription<Object?>? _subscription;

  static void _listen() {
    _subscription ??= _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final link = _open[event['handle']];
      if (link == null) return;
      final data = event['data'];
      if (data is Uint8List) {
        link._input.add(data);
      } else if (event['closed'] == true) {
        _open.remove(link._handle);
        link._finish(event['error'] as String?);
      }
    });
  }

  static Future<List<AndroidUsbDevice>> listUsb() async {
    final devices = await _methods.invokeListMethod<Map>('listUsb') ?? [];
    return [
      for (final device in devices)
        AndroidUsbDevice(
          id: device['id'] as String,
          name: device['name'] as String? ?? device['id'] as String,
          supported: device['supported'] == true,
        ),
    ];
  }

  /// Asks for Bluetooth access where Android requires it; true when given.
  static Future<bool> requestBluetoothPermission() async =>
      await _system.invokeMethod<bool>('requestBluetoothPermissions') ?? false;

  static Future<List<AndroidBleDevice>> scanBle({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!await requestBluetoothPermission()) {
      throw StateError('Bluetooth access was not allowed.');
    }
    final devices =
        await _methods.invokeListMethod<Map>('scanBle', {
          'timeoutMs': timeout.inMilliseconds,
        }) ??
        [];
    return [
      for (final device in devices)
        AndroidBleDevice(
          address: device['address'] as String,
          name: device['name'] as String? ?? '',
          rssi: device['rssi'] as int? ?? 0,
        ),
    ]..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  static Future<AndroidRadioLink> openUsb(
    String id, {
    int baud = 115200,
  }) async {
    _listen();
    final handle = await _methods.invokeMethod<int>('openUsb', {
      'id': id,
      'baud': baud,
    });
    return _register(handle!, id, keepsMessages: false);
  }

  /// Opens a Bluetooth LE serial (Nordic UART) device. With
  /// [keepsMessages], each write goes as one characteristic write and each
  /// notification is one message (MeshCore); otherwise the link is a byte
  /// stream (RNode).
  static Future<AndroidRadioLink> openBle(
    String address, {
    bool keepsMessages = false,
  }) async {
    if (!await requestBluetoothPermission()) {
      throw StateError('Bluetooth access was not allowed.');
    }
    _listen();
    final handle = await _methods.invokeMethod<int>('openBle', {
      'address': address,
      'messages': keepsMessages,
    });
    return _register(handle!, address, keepsMessages: keepsMessages);
  }

  static AndroidRadioLink _register(
    int handle,
    String label, {
    required bool keepsMessages,
  }) {
    final link = AndroidRadioLink._(handle, label, keepsMessages);
    _open[handle] = link;
    return link;
  }
}

/// One open USB or Bluetooth link.
class AndroidRadioLink implements ByteLink {
  AndroidRadioLink._(this._handle, this.label, this.keepsMessages);

  final int _handle;
  @override
  final String label;
  @override
  final bool keepsMessages;
  final _input = StreamController<Uint8List>.broadcast();
  final _closed = Completer<Object?>();
  final WriteQueue _queue = WriteQueue();

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Future<Object?> get closed => _closed.future;

  @override
  Future<void> write(List<int> bytes) async {
    if (_closed.isCompleted) throw StateError('The radio link is closed.');
    await _queue.run(
      () => AndroidRadioLinks._methods.invokeMethod<void>('write', {
        'handle': _handle,
        'bytes': Uint8List.fromList(bytes),
      }),
    );
  }

  @override
  Future<void> close() async {
    AndroidRadioLinks._open.remove(_handle);
    try {
      await AndroidRadioLinks._methods.invokeMethod<void>('close', {
        'handle': _handle,
      });
    } catch (_) {}
    _finish(null);
  }

  void _finish(String? error) {
    if (_closed.isCompleted) return;
    _closed.complete(error);
    unawaited(_input.close());
  }
}

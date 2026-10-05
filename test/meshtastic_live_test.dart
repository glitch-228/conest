// Runs against real Meshtastic firmware (meshtasticd in simulation) when
// CONEST_MESHTASTIC_HOST is set; the debug workflow starts one.
import 'dart:async';
import 'dart:io';

import 'package:conest/src/meshtastic/radio.dart';
import 'package:conest/src/meshtastic_carrier.dart';
import 'package:conest/src/radio/byte_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final host = Platform.environment['CONEST_MESHTASTIC_HOST'];
  final skip = host == null ? 'CONEST_MESHTASTIC_HOST is not set' : null;

  test(
    'the client API handshake and a direct message work with meshtasticd',
    () async {
      MeshtasticRadio? radio;
      Object? lastError;
      for (var attempt = 0; attempt < 30 && radio == null; attempt++) {
        try {
          radio = await MeshtasticRadio.open(
            await TcpByteLink.connect(host!, defaultMeshtasticPort),
          );
        } catch (error) {
          lastError = error;
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      expect(radio, isNotNull, reason: '$lastError');
      addTearDown(radio!.close);
      expect(radio.myNodeNum, isNotNull);
      expect(radio.nodes, contains(radio.myNodeNum));
      // The firmware takes a direct message on Conest's port to a node it
      // has not heard of; delivery needs a second radio, so it is not
      // awaited here.
      await radio.send(
        to: 0x12345678,
        portnum: meshtasticConestPort,
        payload: List<int>.generate(meshtasticPayloadBytes, (i) => i % 256),
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      var closed = false;
      unawaited(radio.closed.then((_) => closed = true));
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse, reason: 'the radio dropped the connection');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

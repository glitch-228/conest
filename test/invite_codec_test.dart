import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/models.dart';

void main() {
  test(
    'contact invites round-trip through payload encoding with route hints',
    () {
      final invite = ContactInvite(
        version: 2,
        accountId: 'acc-a1',
        deviceId: 'dev-b2',
        displayName: 'Alice',
        bio: 'LAN-first test node',
        pairingNonce: 'nonce-a',
        pairingEpochMs: 1760000000000,
        relayCapable: true,
        publicKeyBase64: 'public-key',
        routeHints: const [
          PeerEndpoint(
            kind: PeerRouteKind.lan,
            host: '192.168.1.25',
            port: 7667,
          ),
          PeerEndpoint(
            kind: PeerRouteKind.relay,
            host: 'relay.example',
            port: 7667,
            protocol: PeerRouteProtocol.udp,
          ),
        ],
      );

      final payload = invite.encodePayload();
      final legacyPayload = invite.encodeLegacyPayload();
      final decoded = ContactInvite.decodePayload(payload);
      final legacyDecoded = ContactInvite.decodePayload(legacyPayload);

      expect(payload, startsWith('ci5|'));
      expect(payload.length, lessThan(legacyPayload.length));
      expect(decoded.deviceId, invite.deviceId);
      expect(decoded.bio, invite.bio);
      expect(decoded.pairingNonce, invite.pairingNonce);
      expect(decoded.pairingEpochMs, invite.pairingEpochMs);
      expect(decoded.relayCapable, isTrue);
      expect(decoded.routeHints.length, 2);
      expect(decoded.routeHints.first.kind, PeerRouteKind.lan);
      expect(decoded.routeHints.last.host, 'relay.example');
      expect(decoded.routeHints.last.protocol, PeerRouteProtocol.udp);
      expect(legacyDecoded.deviceId, invite.deviceId);
      expect(legacyDecoded.routeHints.last.protocol, PeerRouteProtocol.udp);
    },
  );

  test('peer endpoints normalize URL-style relay input with protocols', () {
    final udp = PeerEndpoint.normalized(
      kind: PeerRouteKind.relay,
      host: 'udp://everything-earnings.gl.at.ply.gg:21639',
      port: 7667,
    );
    final https = PeerEndpoint.normalized(
      kind: PeerRouteKind.relay,
      host: 'https://everything-earnings.gl.at.ply.gg',
      port: 7667,
    );
    final http = PeerEndpoint.normalized(
      kind: PeerRouteKind.relay,
      host: 'http://relay.local',
      port: 7667,
    );

    expect(udp.host, 'everything-earnings.gl.at.ply.gg');
    expect(udp.port, 21639);
    expect(udp.protocol, PeerRouteProtocol.udp);
    expect(udp.label, 'udp://everything-earnings.gl.at.ply.gg:21639');
    expect(https.host, 'everything-earnings.gl.at.ply.gg');
    expect(https.port, 443);
    expect(https.protocol, PeerRouteProtocol.https);
    expect(https.label, 'https://everything-earnings.gl.at.ply.gg:443');
    expect(http.host, 'relay.local');
    expect(http.port, 80);
    expect(http.protocol, PeerRouteProtocol.http);
  });

  test('peer endpoints reject invalid host and port input', () {
    expect(
      () => PeerEndpoint.normalized(
        kind: PeerRouteKind.relay,
        host: 'relay.example\r\nHost: attacker',
        port: 7667,
      ),
      throwsArgumentError,
    );
    expect(
      () => PeerEndpoint.normalized(
        kind: PeerRouteKind.relay,
        host: 'relay.example/path',
        port: 7667,
      ),
      throwsArgumentError,
    );
    expect(
      () => PeerEndpoint.normalized(
        kind: PeerRouteKind.relay,
        host: 'relay.example',
        port: 70000,
      ),
      throwsArgumentError,
    );
  });

  test(
    'legacy route json without protocol expands to tcp and udp variants',
    () {
      final invite = ContactInvite.fromJson({
        'version': 4,
        'accountId': 'acc-a1',
        'deviceId': 'dev-b2',
        'displayName': 'Alice',
        'publicKeyBase64': 'public-key',
        'routeHints': [
          {
            'kind': 'relay',
            'host': 'https://relay.example:21639',
            'port': 7667,
          },
        ],
      });

      expect(invite.routeHints.length, 2);
      expect(invite.routeHints.map((route) => route.host).toSet(), {
        'relay.example',
      });
      expect(invite.routeHints.map((route) => route.port).toSet(), {21639});
      expect(invite.routeHints.map((route) => route.protocol).toSet(), {
        PeerRouteProtocol.https,
        PeerRouteProtocol.udp,
      });
    },
  );

  test('dynamic codephrase is derived from payload and changes over time', () {
    final early = DateTime.utc(2026, 1, 1, 12, 0, 0);
    final invite = ContactInvite(
      version: 2,
      accountId: 'acc-a1',
      deviceId: 'dev-b2',
      displayName: 'Alice',
      bio: '',
      pairingNonce: 'nonce-a',
      pairingEpochMs: early.millisecondsSinceEpoch,
      relayCapable: false,
      publicKeyBase64: 'public-key',
      routeHints: const [],
    );
    final payload = invite.encodePayload();
    final later = early.add(Duration(seconds: pairingCodeWindow.inSeconds * 2));

    final earlyCode = currentPairingCodeSnapshotForPayload(payload, now: early);
    final laterCode = currentPairingCodeSnapshotForPayload(payload, now: later);

    expect(earlyCode.codephrase, isNot(laterCode.codephrase));
    expect(
      matchesDynamicCodephraseForPayload(
        payload,
        earlyCode.codephrase,
        now: early,
      ),
      isTrue,
    );
    expect(
      matchesDynamicCodephraseForPayload(
        payload,
        earlyCode.codephrase,
        now: later,
      ),
      isFalse,
    );
  });

  test('pairing announcements cover adjacent codephrase windows', () {
    final startedAt = DateTime.utc(2026, 1, 1, 12, 0, 0);
    final invite = ContactInvite(
      version: 4,
      accountId: 'acc-a1',
      deviceId: 'dev-b2',
      displayName: 'Alice',
      bio: '',
      pairingNonce: 'nonce-a',
      pairingEpochMs: startedAt.millisecondsSinceEpoch,
      relayCapable: false,
      publicKeyBase64: 'public-key',
      routeHints: const [],
    );
    final payload = invite.encodePayload();

    final codes = pairingCodephrasesForPayload(payload, now: startedAt);

    expect(pairingCodeWindow.inSeconds, 120);
    expect(codes.length, 2);
    expect(codes.toSet(), hasLength(codes.length));
    expect(
      codes,
      contains(
        currentPairingCodeSnapshotForPayload(
          payload,
          now: startedAt,
        ).codephrase,
      ),
    );
  });

  test('pairing epoch resets the visible codephrase timer', () {
    final rotatedAt = DateTime.utc(2026, 1, 1, 12, 0, 17);
    final invite = ContactInvite(
      version: 4,
      accountId: 'acc-a1',
      deviceId: 'dev-b2',
      displayName: 'Alice',
      bio: '',
      pairingNonce: 'nonce-b',
      pairingEpochMs: rotatedAt.millisecondsSinceEpoch,
      relayCapable: true,
      publicKeyBase64: 'public-key',
      routeHints: const [],
    );

    final snapshot = currentPairingCodeSnapshotForPayload(
      invite.encodePayload(),
      now: rotatedAt,
    );

    expect(snapshot.secondsRemaining, pairingCodeWindow.inSeconds);
  });

  test('reserved attachment and transfer models round-trip', () {
    final descriptor = AttachmentDescriptor(
      id: 'att-1',
      fileName: 'photo.jpg',
      mimeType: 'image/jpeg',
      sizeBytes: 1024,
      chunkSize: 256,
      chunkHashes: const [
        ChunkHash(index: 0, hashBase64: 'hash-a'),
        ChunkHash(index: 1, hashBase64: 'hash-b'),
      ],
      encryptionKeyBase64: 'key',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final session = TransferSession(
      id: 'xfer-1',
      attachment: descriptor,
      peerDeviceIds: const ['dev-a', 'dev-b'],
      state: TransferState.transferring,
      completedChunks: const [0],
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1, 0, 1),
    );

    final decoded = TransferSession.fromJson(session.toJson());

    expect(decoded.attachment.fileName, 'photo.jpg');
    expect(decoded.attachment.chunkHashes.length, 2);
    expect(decoded.state, TransferState.transferring);
    expect(decoded.completedChunks, const [0]);
  });
}

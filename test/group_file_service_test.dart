import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/src/group_file_download.dart';
import '../lib/src/group_file_manifest.dart';
import '../lib/src/group_file_service.dart';
import '../lib/src/group_history_event.dart';
import '../lib/src/models.dart';

void main() {
  test('signed identity has one store; discovery downloads and honors sharing', () async {
    final root = await Directory.systemTemp.createTemp('group-service-');
    final bytes = Uint8List.fromList([1, 2, 3]);
    final digest = sha256.convert(bytes).toString();
    final manifest = GroupFileManifest(
      fileName: 'sample.bin', mimeType: 'application/octet-stream',
      sizeBytes: bytes.length, fileHash: digest, pieceHashes: [digest],
    );
    final event = await GroupHistoryEvent.sign(
      groupId: 'group', authorAccountId: 'author', authorDeviceId: 'device',
      keyPair: await Ed25519().newKeyPair(), sequence: 1,
      previousEventId: null, lamport: 1, membershipId: 'a' * 64,
      kind: GroupEventKind.attachment, payload: manifest.toPayload(),
    );
    final sessions = <String, GroupFileSession>{};
    final saved = <String, GroupFilePreference>{};
    GroupFileService service(String name) => GroupFileService(
      root: Directory('${root.path}/$name'),
      authorizeEvent: (candidate) => candidate.verify(
        expectedGroupId: 'group', expectedAccountId: 'author',
        expectedDeviceId: 'device',
        expectedSigningKeyBase64: event.signingPublicKeyBase64,
      ),
      authorizePeer: (_, peer) async => peer == 'sender' || peer == 'receiver',
      receiveAllowed: (_, _, _) => true,
      loadPreferences: (_) async => GroupFilePreference(
        groupId: event.groupId, eventId: event.eventId,
      ),
      savePreferences: (_, value) async { saved[name] = value; },
      sendEncrypted: (_, peer, _, frame) async {
        await sessions[peer]!.transport.receive(name, frame);
      },
      cancelAndDrain: (_, _, _) async {},
    );
    final sender = service('sender');
    final receiver = service('receiver');
    try {
      sessions['sender'] = await sender.register(event);
      sessions['receiver'] = await receiver.register(event);
      final source = sessions['sender']!;
      final target = sessions['receiver']!;
      expect(identical(await receiver.register(event), target), isTrue);
      final staged = await File('${root.path}/source').writeAsBytes(bytes);
      await source.seedExisting(staged.path);
      await target.setPaused(true);
      await target.updateProvider('sender', [0], lan: true);
      expect(target.download.verifiedBytes, 0);
      await target.setPaused(false);
      expect(target.download.state, GroupFileDownloadState.complete);
      expect(await target.download.completedFile!.readAsBytes(), bytes);
      expect(saved['receiver']!.paused, isFalse);
      await source.setSharing(false);
      expect(await target.transport.queryAvailability('sender'), isEmpty);
      expect(await source.provider.readPiece('receiver', 0), isNull);
    } finally {
      await sender.close();
      await receiver.close();
      await root.delete(recursive: true);
    }
  });
}

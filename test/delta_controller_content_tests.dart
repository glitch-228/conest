part of 'messenger_controller_test.dart';

void deltaContentControllerTests() {
  group('Delta content through fake mail', () {
    late FakeMailServer server;
    late MessengerController alice, bob;
    late _MemoryVaultStore aliceVault, bobVault;
    late Directory root;
    late String aliceFp, bobFp, aliceMail, bobMail;
    late DateTime clock;
    Future<void> until(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(condition(), isTrue, reason: 'mail delivery must finish');
    }

    StagedAttachment source(Uint8List bytes, String name) => StagedAttachment(
      id: 'source',
      fileName: name,
      mimeType: 'application/octet-stream',
      sizeBytes: bytes.length,
      bytes: bytes,
    );
    Future<(PgpSecretKey, PgpSecretKey)> keys() async => (
      await PgpSecretKey.fromJson(
        (aliceVault._snapshot.carrierAccounts['deltaChats']
                as Map<String, dynamic>)['key']
            as Map<String, dynamic>,
      ),
      await PgpSecretKey.fromJson(
        (bobVault._snapshot.carrierAccounts['deltaChats']
                as Map<String, dynamic>)['key']
            as Map<String, dynamic>,
      ),
    );
    Future<String> fixture({
      required String id,
      String text = '',
      List<(String, String)> headers = const [],
      List<DeltaFile> files = const [],
      bool post = false,
    }) async {
      final (a, b) = await keys();
      return DeltaMail.build(
        key: a,
        from: aliceMail,
        to: [(addr: bobMail, key: b.publicKey)],
        text: text,
        messageId: id,
        date: clock,
        extraHeaders: headers,
        files: files,
        postMessage: post,
      );
    }

    setUp(() async {
      clock = DateTime.now().toUtc();
      server = await FakeMailServer.start();
      root = await Directory.systemTemp.createTemp('conest-delta-content');
      aliceVault = _MemoryVaultStore();
      bobVault = _MemoryVaultStore();
      alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        vaultStore: aliceVault,
        mailConnector: server.connect,
        nowProvider: () => clock,
        attachmentRootProvider: () async => Directory('${root.path}/alice'),
      );
      bob = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Bob',
        vaultStore: bobVault,
        mailConnector: server.connect,
        nowProvider: () => clock,
        attachmentRootProvider: () async => Directory('${root.path}/bob'),
      );
      await alice.enableChatmailCarrier('chat.test');
      await bob.enableChatmailCarrier('chat.test');
      await alice.enableDeltaChat();
      await bob.enableDeltaChat();
      aliceFp = alice.deltaFingerprint!;
      bobFp = bob.deltaFingerprint!;
      aliceMail = alice.emailCarrierConfig!.mail;
      bobMail = bob.emailCarrierConfig!.mail;
      await bob.joinDeltaChat(alice.deltaInviteLink!);
      await until(
        () =>
            (alice.deltaChats.peers[bobFp]?.verified ?? false) &&
            (bob.deltaChats.peers[aliceFp]?.verified ?? false),
      );
    });
    tearDown(() async {
      alice.dispose();
      bob.dispose();
      await server.close();
      await root.delete(recursive: true);
    });

    test('photo round trip direct and group, cache survives restart', () async {
      final photo = Uint8List.fromList(
        img.encodePng(img.Image(width: 4, height: 2)),
      );
      final group = await alice.createDeltaGroup('Files', [bobFp]);
      await until(() => bob.deltaChats.chats.containsKey(group));
      for (final key in [bobFp, group]) {
        await alice.sendDeltaAttachment(
          key,
          source(photo, 'photo.png'),
          caption: 'photo',
        );
        final incomingKey = key == bobFp ? aliceFp : group;
        await until(
          () => bob.deltaChats.chats[incomingKey]!.messages.any(
            (m) => m.attachments.isNotEmpty,
          ),
        );
        final file =
            bob.deltaChats.chats[incomingKey]!.messages.last.attachments.single;
        final path = await bob.attachmentCachePathFor(file.id);
        expect(path, isNotNull);
        expect(await File(path!).readAsBytes(), photo);
        expect(bob.attachmentDescriptorFor(file.id)?.fileName, 'photo.png');
        expect(bob.attachmentAvailableLocally(file.id), isTrue);
        await bob.sendDeltaAttachment(incomingKey, source(photo, 'reply.png'));
        await until(
          () => alice.deltaChats.chats[key]!.messages.any(
            (m) => !m.outgoing && m.attachments.isNotEmpty,
          ),
        );
      }
      await until(
        () => (server.mailboxes[bobMail] ?? []).every((m) => m.deleted),
      );
      final cached = bob.deltaChats.chats[aliceFp]!.messages
          .firstWhere((m) => m.attachments.isNotEmpty)
          .attachments
          .single;
      bob.dispose();
      bob = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Bob',
        vaultStore: bobVault,
        createIdentity: false,
        mailConnector: server.connect,
        attachmentRootProvider: () async => Directory('${root.path}/bob'),
      );
      await until(() => bob.deltaFingerprint != null);
      expect(
        await File(
          (await bob.attachmentCachePathFor(cached.id))!,
        ).readAsBytes(),
        photo,
      );
      expect(bob.attachmentAvailableLocally(cached.id), isTrue);
    });

    test(
      'pre post replacing, expiry and post first all travel through IMAP',
      () async {
        final bytes = Uint8List(150001)..[0] = 17;
        final pre = await fixture(
          id: 'pre1@example.org',
          text: 'caption',
          headers: [
            ('Chat-Post-Message-ID', '<post1@example.org>'),
            (
              'Chat-Post-Message-Metadata',
              '{"size":150001,"viewtype":"File","filename":"large.bin"}',
            ),
          ],
        );
        server.deliver(bobMail, pre);
        await until(
          () => bob.deltaChats.chats[aliceFp]!.messages.any(
            (m) => m.pending != null,
          ),
        );
        final count = bob.deltaChats.chats[aliceFp]!.messages.length;
        final post = await fixture(
          id: 'post1@example.org',
          post: true,
          files: [DeltaFile(name: 'large.bin', bytes: bytes)],
        );
        server.deliver(bobMail, post);
        await until(
          () => bob
              .deltaChats
              .chats[aliceFp]!
              .messages
              .last
              .attachments
              .isNotEmpty,
        );
        expect(bob.deltaChats.chats[aliceFp]!.messages, hasLength(count));
        expect(bob.deltaChats.chats[aliceFp]!.messages.last.text, 'caption');
        expect(
          await File(
            (await bob.attachmentCachePathFor(
              bob
                  .deltaChats
                  .chats[aliceFp]!
                  .messages
                  .last
                  .attachments
                  .single
                  .id,
            ))!,
          ).readAsBytes(),
          bytes,
        );
        server.deliver(
          bobMail,
          await fixture(
            id: 'pre2@example.org',
            headers: [
              ('Chat-Post-Message-ID', '<post2@example.org>'),
              (
                'Chat-Post-Message-Metadata',
                '{"size":150001,"viewtype":"File","filename":"missing.bin"}',
              ),
            ],
          ),
        );
        await until(
          () => bob.deltaChats.chats[aliceFp]!.messages.any(
            (m) => m.id == 'post2@example.org',
          ),
        );
        clock = clock.add(const Duration(days: 7));
        expect(
          bob.deltaChats.chats[aliceFp]!.messages.last.pendingExpired(clock),
          isTrue,
        );
        expect(
          bob.deltaChats.chats[aliceFp]!.messages.last.preview(clock),
          contains('not received'),
        );
        server.deliver(
          bobMail,
          await fixture(
            id: 'post3@example.org',
            post: true,
            files: [DeltaFile(name: 'first.bin', bytes: bytes)],
          ),
        );
        await until(
          () => bob.deltaChats.chats[aliceFp]!.messages.any(
            (m) => m.id == 'post3@example.org',
          ),
        );
        server.deliver(
          bobMail,
          await fixture(
            id: 'pre3@example.org',
            text: 'post first',
            headers: [
              ('Chat-Post-Message-ID', '<post3@example.org>'),
              (
                'Chat-Post-Message-Metadata',
                '{"size":150001,"viewtype":"File","filename":"first.bin"}',
              ),
            ],
          ),
        );
        await until(
          () =>
              bob.deltaChats.chats[aliceFp]!.messages.last.text == 'post first',
        );
        expect(
          bob.deltaChats.chats[aliceFp]!.messages.where(
            (m) => m.id == 'post3@example.org',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'outbound split crosses ordinary IMAP cap and keeps one local copy',
      () async {
        final bytes = Uint8List(1200 * 1024)..[0] = 42;
        await alice.sendDeltaAttachment(
          bobFp,
          source(bytes, 'large.bin'),
          caption: 'large',
        );
        await until(
          () => bob.deltaChats.chats[aliceFp]!.messages.any(
            (m) => m.attachments.isNotEmpty,
          ),
        );
        expect(bob.deltaChats.chats[aliceFp]!.messages, hasLength(1));
        expect(alice.deltaChats.chats[bobFp]!.messages, hasLength(1));
        expect(bob.deltaChats.chats[aliceFp]!.messages.single.text, 'large');
        expect(
          server.fetchedSizes.any((size) => size > maxCarrierMailBytes),
          isTrue,
        );
        await until(
          () => (server.mailboxes[bobMail] ?? []).every((m) => m.deleted),
        );
      },
    );

    test(
      'metadata removed, uncertain file asks, consent and random names apply',
      () async {
        final jpeg = img.encodeJpg(img.Image(width: 2, height: 2));
        final marker = latin1.encode('GPS location author Alice');
        final dirty = Uint8List.fromList([
          255,
          216,
          255,
          254,
          0,
          marker.length + 2,
          ...marker,
          ...jpeg.sublist(2),
        ]);
        await alice.setRandomizesFileNames(true);
        await alice.sendDeltaAttachment(
          bobFp,
          source(dirty, 'private-name.jpg'),
        );
        await until(
          () => bob.deltaChats.chats[aliceFp]!.messages.any(
            (m) => m.attachments.isNotEmpty,
          ),
        );
        final file =
            bob.deltaChats.chats[aliceFp]!.messages.last.attachments.single;
        expect(file.fileName, isNot('private-name.jpg'));
        expect(file.fileName, endsWith('.jpg'));
        expect(
          alice
              .deltaChats
              .chats[bobFp]!
              .messages
              .last
              .attachments
              .single
              .fileName,
          'private-name.jpg',
        );
        final bytes = await File(
          (await bob.attachmentCachePathFor(file.id))!,
        ).readAsBytes();
        expect(latin1.decode(bytes), isNot(contains('GPS location')));
        expect(img.decodeJpg(bytes), isNotNull);
        final broken = Uint8List.fromList([255, 216, 255, 225, 0, 12, 1]);
        await expectLater(
          alice.sendDeltaAttachment(bobFp, source(broken, 'broken.jpg')),
          throwsA(isA<FileMetadataException>()),
        );
        final before = alice.deltaChats.chats[bobFp]!.messages.length;
        await alice.sendDeltaAttachment(
          bobFp,
          source(broken, 'broken.jpg'),
          keepMetadata: true,
        );
        expect(alice.deltaChats.chats[bobFp]!.messages.length, before + 1);
        await expectLater(
          alice.sendDeltaAttachment(
            bobFp,
            StagedAttachment(
              id: 'huge',
              fileName: 'huge.bin',
              mimeType: 'application/octet-stream',
              sizeBytes: DeltaLimits.fileBytes + 1,
              filePath: '/not-opened',
            ),
          ),
          throwsArgumentError,
        );
      },
    );
  });
}

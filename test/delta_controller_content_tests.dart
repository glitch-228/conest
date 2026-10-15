part of 'messenger_controller_test.dart';

class _DeltaPersistenceVault extends _MemoryVaultStore {
  bool failDeltaSaves = false;
  Completer<void>? blockedWrite;
  Completer<void>? writeStarted;
  @override
  Future<void> save(VaultSnapshot snapshot) async {
    final blocked = blockedWrite;
    if (blocked != null) {
      blockedWrite = null;
      writeStarted?.complete();
      await blocked.future;
      throw const FileSystemException('simulated earlier vault write failure');
    }
    final delta = snapshot.networkChats['deltaChat'];
    if (failDeltaSaves &&
        delta is Map<String, dynamic> &&
        (delta['chats'] as List? ?? const []).any(
          (chat) =>
              chat is Map &&
              (chat['messages'] as List? ?? const []).any(
                (m) =>
                    m is Map &&
                    (m['attachments'] as List? ?? const []).isNotEmpty,
              ),
        )) {
      throw const FileSystemException('simulated Delta vault save failure');
    }
    await super.save(snapshot);
  }
}

void deltaContentControllerTests() {
  group('Delta content through fake mail', () {
    late FakeMailServer server;
    late MessengerController alice, bob;
    late _MemoryVaultStore aliceVault, bobVault;
    late Directory root;
    late String aliceFp, bobFp, aliceMail, bobMail;
    late DateTime clock;
    var storageFails = false;
    Future<void> until(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(
        condition(),
        isTrue,
        reason:
            'mail delivery must finish; state=${bob.emailCarrierConfig?.lastUid}, fetched=${server.fetched.length}, messages=${bob.deltaChats.chats[aliceFp]?.messages.length}',
      );
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
      bobVault = _DeltaPersistenceVault();
      storageFails = false;
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
        storageCapacityProvider: (_) async => StorageCapacity(
          freeBytes: storageFails ? 0 : 100 * 1024 * 1024 * 1024,
          totalBytes: 100 * 1024 * 1024 * 1024,
        ),
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

    testWidgets(
      'Delta managed photo, file and voice render through the shared viewer with file actions',
      (tester) async {
        late List<AttachmentDescriptor> files;
        await tester.runAsync(() async {
          final photo = Uint8List.fromList(
            img.encodePng(img.Image(width: 4, height: 2)),
          );
          for (final item in [
            (
              'photo-ui@example.org',
              DeltaFile(name: 'photo.png', bytes: photo),
              false,
            ),
            (
              'file-ui@example.org',
              DeltaFile(
                name: 'document.bin',
                bytes: Uint8List.fromList([1, 2, 3, 4]),
              ),
              false,
            ),
            (
              'voice-ui@example.org',
              DeltaFile(
                name: 'voice.ogg',
                bytes: Uint8List.fromList(ascii.encode('OggSfixture')),
              ),
              true,
            ),
          ]) {
            server.deliver(
              bobMail,
              await fixture(
                id: item.$1,
                files: [item.$2],
                headers: item.$3
                    ? [('Chat-Voice-Message', '1'), ('Chat-Duration', '3200')]
                    : const [],
              ),
            );
          }
          await until(
            () =>
                bob.deltaChats.chats[aliceFp]!.messages
                    .where((m) => m.attachments.isNotEmpty)
                    .length ==
                3,
          );
          files = [
            for (final m in bob.deltaChats.chats[aliceFp]!.messages)
              ...m.attachments,
          ];
          for (final file in files.where(
            (f) => f.mimeType.startsWith('image/'),
          )) {
            bob.attachmentBytesFor(file.id);
            await until(() => bob.attachmentBytesFor(file.id) != null);
          }
        });
        for (final file in files) {
          expect(file.encryptionKeyBase64, isEmpty);
          expect(file.effectiveChunkCount, 0);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 420,
                    child: Builder(
                      builder: (context) =>
                          buildDeltaAttachment(context, bob, file, false),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 80)),
          );
          await tester.pump();
          expect(find.text('Attachment metadata unavailable'), findsNothing);
          if (file.voiceMetadata != null) {
            expect(find.text('Voice message'), findsOneWidget);
            expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
            expect(find.byTooltip('Playback speed'), findsOneWidget);
          } else if (file.mimeType.startsWith('image/')) {
            expect(find.byType(Image), findsWidgets);
          } else {
            expect(find.text('document.bin'), findsOneWidget);
          }
          await tester.tap(find.byTooltip('File actions'));
          await tester.pumpAndSettle();
          for (final label in ['Open', 'Save', 'Forward']) {
            final item = tester.widget<PopupMenuItem<String>>(
              find.widgetWithText(PopupMenuItem<String>, label),
            );
            expect(item.enabled, isTrue);
          }
          if (file.mimeType.startsWith('image/')) {
            await tester.tap(find.text('Open'));
            await tester.pumpAndSettle();
            // Each filesystem await returns through the widget test's fake
            // clock; drain the cache lookup's I/O stages before navigation.
            for (var i = 0; i < 8; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump();
            }
            await tester.pumpAndSettle();
            expect(
              find.text('photo.png'),
              findsOneWidget,
              reason:
                  'status=${bob.statusMessage}; managed=${bob.deltaAttachmentAvailableLocally(file)}; texts=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}',
            );
            expect(find.byTooltip('Save'), findsOneWidget);
            await tester.pageBack();
          } else {
            await tester.tapAt(const Offset(5, 5));
          }
          await tester.pumpAndSettle();
        }
        final forged = AttachmentDescriptor(
          id: 'delta:unmanaged',
          fileName: 'forged.bin',
          mimeType: 'application/octet-stream',
          sizeBytes: 4,
          chunkSize: 65536,
          chunkHashes: const [],
          encryptionKeyBase64: '',
          fileHashBase64: files.first.fileHashBase64,
          createdAt: clock,
        );
        final mismatched = AttachmentDescriptor(
          id: files.first.id,
          fileName: 'forged.bin',
          mimeType: 'application/octet-stream',
          sizeBytes: 4,
          chunkSize: 65536,
          chunkHashes: const [],
          encryptionKeyBase64: '',
          fileHashBase64: files.first.fileHashBase64,
          createdAt: clock,
        );
        expect(bob.deltaAttachmentAvailableLocally(mismatched), isFalse);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 420,
                child: Builder(
                  builder: (context) =>
                      buildDeltaAttachment(context, bob, forged, false),
                ),
              ),
            ),
          ),
        );
        expect(find.text('Attachment metadata unavailable'), findsOneWidget);
        await tester.tap(find.byTooltip('File actions'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<PopupMenuItem<String>>(
                find.widgetWithText(PopupMenuItem<String>, 'Open'),
              )
              .enabled,
          isFalse,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

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
      'unsaved file keeps its UID and retries after storage recovers',
      () async {
        final photo = Uint8List.fromList(
          img.encodePng(img.Image(width: 3, height: 2)),
        );
        storageFails = true;
        await alice.sendDeltaAttachment(bobFp, source(photo, 'retry.png'));
        final id = alice.deltaChats.chats[bobFp]!.messages.last.id;
        bool isFile(FakeMail m) =>
            latin1.decode(m.raw).contains('Message-ID: <$id>');
        await until(() => server.mailboxes[bobMail]?.any(isFile) ?? false);
        final uid = server.mailboxes[bobMail]!.firstWhere(isFile).uid;
        await until(
          () => server.fetched.where((value) => value == uid).length >= 2,
        );
        expect(
          bob.deltaChats.chats[aliceFp]!.messages.where(
            (m) => m.attachments.isNotEmpty,
          ),
          isEmpty,
        );
        expect(bob.emailCarrierConfig!.lastUid, lessThan(uid));
        expect(
          server.mailboxes[bobMail]!.where((m) => m.uid == uid),
          hasLength(1),
        );
        storageFails = false;
        await until(
          () => bob.deltaChats.chats[aliceFp]!.messages.any(
            (m) => m.attachments.isNotEmpty,
          ),
        );
        await until(
          () => (server.mailboxes[bobMail] ?? []).every((m) => m.deleted),
        );
        expect(
          server.fetched.where((value) => value == uid).length,
          greaterThanOrEqualTo(2),
        );
      },
    );

    test(
      'saved file mail waits for the vault write before consumption',
      () async {
        final vault = bobVault as _DeltaPersistenceVault;
        final photo = Uint8List.fromList(
          img.encodePng(img.Image(width: 2, height: 1)),
        );
        vault.failDeltaSaves = true;
        await alice.sendDeltaAttachment(
          bobFp,
          source(photo, 'vault-retry.png'),
        );
        final id = alice.deltaChats.chats[bobFp]!.messages.last.id;
        bool isFile(FakeMail m) =>
            latin1.decode(m.raw).contains('Message-ID: <$id>');
        await until(() => server.mailboxes[bobMail]?.any(isFile) ?? false);
        final uid = server.mailboxes[bobMail]!.firstWhere(isFile).uid;
        await until(
          () => server.fetched.where((value) => value == uid).length >= 2,
        );
        expect(
          server.mailboxes[bobMail]!.where((m) => m.uid == uid),
          hasLength(1),
        );
        expect(bob.emailCarrierConfig!.lastUid, lessThan(uid));
        expect(
          DeltaChats.fromJson(
            vault._snapshot.networkChats['deltaChat'],
          ).chats[aliceFp]!.messages.where((m) => m.attachments.isNotEmpty),
          isEmpty,
        );
        vault.failDeltaSaves = false;
        await until(
          () => (server.mailboxes[bobMail] ?? []).every((m) => m.deleted),
        );
        final persisted = DeltaChats.fromJson(
          vault._snapshot.networkChats['deltaChat'],
        );
        expect(
          persisted.chats[aliceFp]!.messages.single.attachments,
          hasLength(1),
        );
        final path = await bob.attachmentCachePathFor(
          persisted.chats[aliceFp]!.messages.single.attachments.single.id,
        );
        expect(await File(path!).readAsBytes(), photo);
      },
    );

    test(
      'an earlier active vault write failure preserves the incoming file UID',
      () async {
        final vault = bobVault as _DeltaPersistenceVault;
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        Future<void>? failedSetting;
        const id = 'active-write@example.org';
        bool isFile(FakeMail m) =>
            latin1.decode(m.raw).contains('Message-ID: <$id>');
        server.beforeBodyFetch = (mail) async {
          if (!isFile(mail) || failedSetting != null) return;
          await bob.flushPendingChanges();
          vault.blockedWrite = release;
          vault.writeStarted = Completer<void>();
          failedSetting = expectLater(
            bob.setRandomizesFileNames(true),
            throwsA(isA<FileSystemException>()),
          );
          await vault.writeStarted!.future;
        };
        storageFails = true;
        final photo = Uint8List.fromList(
          img.encodePng(img.Image(width: 2, height: 2)),
        );
        server.deliver(
          bobMail,
          await fixture(
            id: id,
            files: [DeltaFile(name: 'pending-write.png', bytes: photo)],
          ),
        );
        final target = server.mailboxes[bobMail]!.firstWhere(isFile);
        final uid = target.uid;
        await until(
          () => server.fetched.contains(uid) && failedSetting != null,
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        release.complete();
        await failedSetting!;
        await until(
          () => server.fetched.where((value) => value == uid).length >= 2,
        );
        expect(bob.emailCarrierConfig!.lastUid, lessThan(uid));
        expect(target.deleted, isFalse);
        storageFails = false;
        await until(() => target.deleted);
        final persisted = DeltaChats.fromJson(
          vault._snapshot.networkChats['deltaChat'],
        );
        expect(
          persisted.chats[aliceFp]!.messages.single.attachments,
          hasLength(1),
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

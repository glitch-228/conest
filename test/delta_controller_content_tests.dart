part of 'messenger_controller_test.dart';

class _DeltaPersistenceVault extends _MemoryVaultStore {
  bool failDeltaSaves = false;
  bool failControlSaves = false;
  bool failJoinResponseSaves = false;
  int failedControlSaves = 0;
  String? blockDeltaMessage;
  Completer<void>? deltaWriteStarted;
  Completer<void>? deltaWriteRelease;
  int deltaSaves = 0;
  Completer<void>? blockedWrite;
  Completer<void>? writeStarted;
  @override
  Future<void> save(VaultSnapshot snapshot) async {
    if ((failControlSaves ||
            (failJoinResponseSaves &&
                (snapshot.networkChats['deltaChat']?['joins'] as List? ??
                        const [])
                    .isEmpty)) &&
        ((snapshot.carrierAccounts['deltaChats'] as Map?)?['outbox'] as List? ??
                const [])
            .isNotEmpty) {
      failedControlSaves++;
      throw const FileSystemException('simulated protocol outbox save failure');
    }
    final blocked = blockedWrite;
    if (blocked != null) {
      blockedWrite = null;
      writeStarted?.complete();
      await blocked.future;
      throw const FileSystemException('simulated earlier vault write failure');
    }
    final delta = snapshot.networkChats['deltaChat'];
    if (blockDeltaMessage != null &&
        delta != null &&
        (delta['chats'] as List? ?? const []).any(
          (c) => (c['messages'] as List? ?? const []).any(
            (m) => m['id'] == blockDeltaMessage,
          ),
        )) {
      blockDeltaMessage = null;
      deltaWriteStarted!.complete();
      await deltaWriteRelease!.future;
      throw const FileSystemException(
        'simulated replaced mailbox save failure',
      );
    }
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
    if (!identical(
      snapshot.networkChats['deltaChat'],
      _snapshot.networkChats['deltaChat'],
    )) {
      deltaSaves++;
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
    Object? smtpFailure;
    var smtpFailures = 0;
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
      aliceVault = _DeltaPersistenceVault();
      bobVault = _DeltaPersistenceVault();
      storageFails = false;
      smtpFailure = null;
      smtpFailures = 0;
      alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        vaultStore: aliceVault,
        mailConnector: (host, port, {required bool tls}) async {
          final error = smtpFailure;
          if (port == 465 && error != null) {
            smtpFailures++;
            throw error;
          }
          return server.connect(host, port, tls: tls);
        },
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

    test('Delta fetch batch of twenty mails writes the vault once', () async {
      final mails = <String>[];
      for (var i = 0; i < 20; i++) {
        mails.add(await fixture(id: 'batch-$i@example.org', text: 'batch $i'));
      }
      await bob.flushPendingChanges();
      final vault = bobVault as _DeltaPersistenceVault;
      final before = vault.deltaSaves;
      for (final mail in mails) {
        server.deliver(bobMail, mail);
      }
      await until(
        () =>
            bob.deltaChats.chats[aliceFp]!.messages
                .where((m) => m.id.startsWith('batch-'))
                .length ==
            20,
      );
      await until(() => (server.mailboxes[bobMail] ?? []).isEmpty);
      expect(vault.deltaSaves - before, 1);
      final saved = DeltaChats.fromJson(
        vault._snapshot.networkChats['deltaChat'],
      );
      expect(
        saved.chats[aliceFp]!.messages.where((m) => m.id.startsWith('batch-')),
        hasLength(20),
      );
    });

    test('Delta protocol reply survives a refused quota and restart', () async {
      final carol = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Carol',
        mailConnector: server.connect,
      );
      addTearDown(carol.dispose);
      await carol.enableChatmailCarrier('chat.test');
      await carol.enableDeltaChat();
      final carolFp = carol.deltaFingerprint!;
      alice.noteServerSlowDownForTesting(
        TransportKind.deltaChat,
        const Duration(minutes: 2),
      );
      await carol.joinDeltaChat(alice.deltaInviteLink!);
      List<dynamic> outbox() =>
          (aliceVault._snapshot.carrierAccounts['deltaChats'] as Map)['outbox']
              as List? ??
          const [];
      await until(() => outbox().isNotEmpty);
      await until(() => (server.mailboxes[aliceMail] ?? []).isEmpty);
      expect(carol.deltaChats.peers[aliceFp]?.verified, isNot(true));
      alice.dispose();
      alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        vaultStore: aliceVault,
        createIdentity: false,
        mailConnector: server.connect,
        attachmentRootProvider: () async => Directory('${root.path}/alice'),
      );
      await until(
        () =>
            (alice.deltaChats.peers[carolFp]?.verified ?? false) &&
            (carol.deltaChats.peers[aliceFp]?.verified ?? false),
      );
      await until(() => outbox().isEmpty);
    });

    test(
      'Delta permanently refused reply cannot block a later handshake',
      () async {
        final (_, key) = await keys();
        final auth =
            ((aliceVault._snapshot.carrierAccounts['deltaChats']
                        as Map)['tokens']
                    as Map)['auth']
                as String;
        server.recipientRefusals['gone@chat.test'] = 550;
        server.deliver(
          aliceMail,
          await DeltaMail.buildSecureJoinV3(
            key: key,
            from: 'gone@chat.test',
            to: aliceMail,
            step: 'vc-request-pubkey',
            auth: auth,
            password: 'securejoin/$aliceFp/$auth',
            attachKey: false,
            messageId: 'gone@example.org',
            date: clock,
          ),
        );
        await until(() => (server.mailboxes[aliceMail] ?? []).isEmpty);
        final carol = await _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Carol',
          mailConnector: server.connect,
        );
        addTearDown(carol.dispose);
        await carol.enableChatmailCarrier('chat.test');
        await carol.enableDeltaChat();
        await carol.joinDeltaChat(alice.deltaInviteLink!);
        await until(() => carol.deltaChats.peers[aliceFp]?.verified ?? false);
        await until(
          () =>
              ((aliceVault._snapshot.carrierAccounts['deltaChats']
                              as Map)['outbox']
                          as List? ??
                      const [])
                  .isEmpty,
        );
      },
    );

    test(
      'Delta refused protocol reply retries once email permits it',
      () async {
        smtpFailure = const LimiterRefused(
          LimiterRefusal.wouldWait,
          retryIn: Duration(seconds: 1),
        );
        final carol = await _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Carol',
          mailConnector: server.connect,
        );
        addTearDown(carol.dispose);
        await carol.enableChatmailCarrier('chat.test');
        await carol.enableDeltaChat();
        await carol.joinDeltaChat(alice.deltaInviteLink!);
        await until(
          () =>
              ((aliceVault._snapshot.carrierAccounts['deltaChats']
                              as Map)['outbox']
                          as List? ??
                      const [])
                  .isNotEmpty,
        );
        await until(() => smtpFailures > 0);
        smtpFailure = null;
        await until(() => carol.deltaChats.peers[aliceFp]?.verified ?? false);
        await until(
          () =>
              ((aliceVault._snapshot.carrierAccounts['deltaChats']
                              as Map)['outbox']
                          as List? ??
                      const [])
                  .isEmpty,
        );
      },
    );

    test('Delta email account changes keep separate quota histories', () async {
      final original = alice.limiterForTesting(TransportKind.deltaChat)!;
      original.pushedBack(retryAfter: const Duration(hours: 1));
      await alice.enableOwnEmailCarrier(
        mail: 'other@chat.test',
        password: 'other-password',
        imapHost: 'chat.test',
        smtpHost: 'chat.test',
      );
      final ordinary = alice.limiterForTesting(TransportKind.deltaChat)!;
      expect(ordinary, isNot(same(original)));
      expect(ordinary.budget.quota, 150);
      expect(ordinary.budget.window, const Duration(hours: 1));
      expect(ordinary.isResting, isFalse);
      ordinary.pushedBack(retryAfter: const Duration(minutes: 2));
      await alice.setCarrierPaused(TransportKind.deltaChat, true);
      await alice.setCarrierPaused(TransportKind.deltaChat, false);
      expect(alice.limiterForTesting(TransportKind.deltaChat), same(ordinary));
      expect(ordinary.isResting, isTrue);
    });

    test('Delta protocol reply waits for durable outbox storage', () async {
      final vault = _DeltaPersistenceVault()..failJoinResponseSaves = true;
      final carol = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Carol',
        vaultStore: vault,
        mailConnector: server.connect,
      );
      addTearDown(carol.dispose);
      await carol.enableChatmailCarrier('chat.test');
      await carol.enableDeltaChat();
      await carol.joinDeltaChat(alice.deltaInviteLink!);
      await until(() => vault.failedControlSaves > 0);
      final carolMail = carol.emailCarrierConfig!.mail;
      expect(server.mailboxes[carolMail], isNotEmpty);
      expect(server.mailboxes[carolMail]!.every((m) => !m.deleted), isTrue);
      expect(carol.deltaChats.peers[aliceFp]?.verified, isNot(true));
      expect(carol.deltaChats.joins, isNotEmpty);
      vault.failJoinResponseSaves = false;
      await until(() => carol.deltaChats.peers[aliceFp]?.verified ?? false);
      await until(() => (server.mailboxes[carolMail] ?? []).isEmpty);
    });

    test(
      'Delta failed batches retain their protocol reply allowance',
      () async {
        final vault = aliceVault as _DeltaPersistenceVault;
        vault.failControlSaves = true;
        final (_, key) = await keys();
        final auth =
            ((vault._snapshot.carrierAccounts['deltaChats'] as Map)['tokens']
                    as Map)['auth']
                as String;
        final requests = <String>[];
        for (var i = 0; i < 20; i++) {
          requests.add(
            await DeltaMail.buildSecureJoinV3(
              key: key,
              from: bobMail,
              to: aliceMail,
              step: 'vc-request-pubkey',
              auth: auth,
              password: 'securejoin/$aliceFp/$auth',
              attachKey: false,
              messageId: 'answer-retry-$i@example.org',
              date: clock,
            ),
          );
        }
        for (final request in requests) {
          server.deliver(aliceMail, request);
        }
        await until(() => vault.failedControlSaves >= 2);
        expect(server.mailboxes[aliceMail], hasLength(20));
        vault.failControlSaves = false;
        await until(() => (server.mailboxes[aliceMail] ?? []).isEmpty);
      },
    );

    test(
      'Delta stale save cannot restore a replaced same-address mailbox cursor',
      () async {
        final vault = bobVault as _DeltaPersistenceVault;
        vault.blockDeltaMessage = 'replaced@example.org';
        vault.deltaWriteStarted = Completer<void>();
        vault.deltaWriteRelease = Completer<void>();
        server.deliver(
          bobMail,
          await fixture(id: 'replaced@example.org', text: 'in the old mailbox'),
        );
        await vault.deltaWriteStarted!.future;
        await bob.enableOwnEmailCarrier(
          mail: bobMail,
          password: bob.emailCarrierConfig!.password,
          imapHost: 'different.test',
          smtpHost: 'chat.test',
        );
        await bob.setCarrierPaused(TransportKind.deltaChat, true);
        final replacement = bob.emailCarrierConfig!;
        vault.deltaWriteRelease!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(bob.emailCarrierConfig!.sameMailboxAs(replacement), isTrue);
        expect(bob.emailCarrierConfig!.lastUid, replacement.lastUid);
        expect(bob.emailCarrierConfig!.deferred, replacement.deferred);
      },
    );

    testWidgets(
      'Delta metered file waits behind Download and retains its UID across restart',
      (tester) async {
        late DeltaChat placeholder;
        late FakeMail target;
        final bytes = Uint8List(200000)..[0] = 19;
        await tester.runAsync(() async {
          bob.onConnectivityChanged(interfaceLabel: 'mobile');
          server.deliver(
            bobMail,
            await fixture(
              id: 'deferred@example.org',
              files: [DeltaFile(name: 'file.bin', bytes: bytes)],
            ),
          );
          target = server.mailboxes[bobMail]!.last;
          await until(
            () => bob.emailCarrierConfig!.deferred.any(
              (m) => m.uid == target.uid,
            ),
          );
          await bob.flushPendingChanges();
          expect(server.fetched, isNot(contains(target.uid)));
          expect(target.deleted, isFalse);
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
          placeholder = bob.deltaChats.chats.values.firstWhere(
            (c) => c.key.startsWith('deferred:'),
          );
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => openDeltaChat(context, bob, placeholder.key),
                  child: const Text('Open deferred'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open deferred'));
        await tester.pumpAndSettle();
        expect(find.text('Download'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.text('Download'));
          await until(() => target.deleted);
        });
        await tester.pumpAndSettle();
        final file =
            bob.deltaChats.chats[aliceFp]!.messages.last.attachments.single;
        expect(
          await tester.runAsync(
            () async => File(
              (await bob.attachmentCachePathFor(file.id))!,
            ).readAsBytes(),
          ),
          bytes,
        );
        expect(server.fetched.where((uid) => uid == target.uid), hasLength(1));
        expect(bob.emailCarrierConfig!.deferred, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    test('Delta storage preset defers files on an unmetered network', () async {
      await bob.updateGlobalConnectivity(
        bob.identity!.connectivity.copyWith(
          autoDownloadPreset: AutoDownloadPreset.low,
        ),
      );
      server.deliver(
        bobMail,
        await fixture(
          id: 'preset@example.org',
          files: [DeltaFile(name: 'large.bin', bytes: Uint8List(700000))],
        ),
      );
      final mail = server.mailboxes[bobMail]!.last;
      await until(
        () => bob.emailCarrierConfig!.deferred.any((m) => m.uid == mail.uid),
      );
      expect(server.fetched, isNot(contains(mail.uid)));
      expect(mail.deleted, isFalse);
    });

    test(
      'Delta opening a cached file updates the LRU used by admission',
      () async {
        bob.deltaAttachmentCacheLimitBytes = 12;
        for (var i = 1; i <= 2; i++) {
          server.deliver(
            bobMail,
            await fixture(
              id: 'lru-$i@example.org',
              files: [
                DeltaFile(
                  name: '$i.bin',
                  bytes: Uint8List.fromList(List.filled(4, i)),
                ),
              ],
            ),
          );
          await until(
            () => bob.deltaChats.chats[aliceFp]!.messages.any(
              (m) => m.id == 'lru-$i@example.org',
            ),
          );
        }
        final first = bob.deltaChats.chats[aliceFp]!.messages
            .firstWhere((m) => m.id == 'lru-1@example.org')
            .attachments
            .single;
        final second = bob.deltaChats.chats[aliceFp]!.messages
            .firstWhere((m) => m.id == 'lru-2@example.org')
            .attachments
            .single;
        clock = clock.add(const Duration(seconds: 1));
        expect(await bob.attachmentCachePathFor(first.id), isNotNull);
        server.deliver(
          bobMail,
          await fixture(
            id: 'lru-3@example.org',
            files: [
              DeltaFile(
                name: '3.bin',
                bytes: Uint8List.fromList(List.filled(8, 3)),
              ),
            ],
          ),
        );
        await until(
          () => bob.deltaChats.chats[aliceFp]!.messages.any(
            (m) => m.id == 'lru-3@example.org',
          ),
        );
        expect(bob.attachmentAvailableLocally(first.id), isTrue);
        expect(bob.attachmentAvailableLocally(second.id), isFalse);
      },
    );

    test(
      'Delta deleting a chat prunes its persisted cache references',
      () async {
        server.deliver(
          bobMail,
          await fixture(
            id: 'reference@example.org',
            files: [
              DeltaFile(
                name: 'file.bin',
                bytes: Uint8List.fromList([1, 2, 3, 4]),
              ),
            ],
          ),
        );
        await until(
          () => bob.deltaChats.chats[aliceFp]!.messages.any(
            (m) => m.attachments.isNotEmpty,
          ),
        );
        final descriptor =
            bob.deltaChats.chats[aliceFp]!.messages.last.attachments.single;
        expect(
          bobVault._snapshot.attachmentCacheReferences.any(
            (r) => r.attachmentId == descriptor.id,
          ),
          isTrue,
        );
        await bob.deleteDeltaChat(aliceFp);
        expect(
          bobVault._snapshot.attachmentCacheReferences.any(
            (r) => r.attachmentId == descriptor.id,
          ),
          isFalse,
        );
      },
    );

    for (final fullDisk in [false, true]) {
      test(
        'Delta legacy cache migration preserves files shared with archived chats${fullDisk ? ' on a full disk' : ''}',
        () async {
          server.deliver(
            bobMail,
            await fixture(
              id: 'archived@example.org',
              files: [
                DeltaFile(
                  name: 'file.bin',
                  bytes: Uint8List.fromList([1, 2, 3, 4]),
                ),
              ],
            ),
          );
          await until(
            () => bob.deltaChats.chats[aliceFp]!.messages.any(
              (m) => m.attachments.isNotEmpty,
            ),
          );
          final descriptor =
              bob.deltaChats.chats[aliceFp]!.messages.last.attachments.single;
          final archiveFile = AttachmentDescriptor.fromJson({
            ...descriptor.toJson(),
            'id': 'archive-shared',
          });
          await bob.addLinkArchiveForTesting(
            LinkArchive(
              id: 'delta-shared',
              createdAt: clock,
              contacts: const [],
              groups: const [],
              conversations: [
                ConversationRecord(
                  id: 'old-chat',
                  kind: ConversationKind.direct,
                  peerDeviceId: 'old-peer',
                  messages: [
                    ChatMessage(
                      id: 'old-message',
                      conversationId: 'old-chat',
                      senderDeviceId: 'old-peer',
                      recipientDeviceId: bob.identity!.deviceId,
                      body: '',
                      outbound: false,
                      state: DeliveryState.delivered,
                      createdAt: clock,
                      attachment: archiveFile,
                    ),
                  ],
                ),
              ],
            ),
          );
          final prefix = File(
            (await bob.attachmentCachePathFor(descriptor.id))!,
          );
          final legacy = File(
            '${root.path}/bob/cache/${attachmentStorageKey('sha256:${descriptor.fileHashBase64}')}',
          );
          await prefix.rename(legacy.path);
          await bob.flushPendingChanges();
          bob.dispose();
          bob = await _createController(
            relayClient: _FakeRelayClient(),
            displayName: 'Bob',
            vaultStore: bobVault,
            createIdentity: false,
            mailConnector: server.connect,
            storageCapacityProvider: (_) async => StorageCapacity(
              freeBytes: fullDisk ? 0 : 100 * 1024 * 1024 * 1024,
              totalBytes: 100 * 1024 * 1024 * 1024,
            ),
            attachmentRootProvider: () async => Directory('${root.path}/bob'),
          );
          await until(() => bob.deltaFingerprint != null);
          expect(await bob.attachmentCachePathFor(descriptor.id), isNotNull);
          expect(await legacy.readAsBytes(), [1, 2, 3, 4]);
          if (fullDisk) {
            expect(await prefix.exists(), isFalse);
            expect(
              await bob.attachmentCachePathFor(descriptor.id),
              legacy.path,
            );
          }
          expect(await bob.attachmentCachePathFor(archiveFile.id), legacy.path);
        },
      );
    }

    test(
      'Delta small metered attachments wait for explicit Download after the bounded control read',
      () async {
        bob.onConnectivityChanged(interfaceLabel: 'mobile');
        server.deliver(
          bobMail,
          await fixture(
            id: 'small-metered@example.org',
            files: [
              DeltaFile(
                name: 'small.bin',
                bytes: Uint8List.fromList([1, 2, 3, 4]),
              ),
            ],
          ),
        );
        final mail = server.mailboxes[bobMail]!.last;
        await until(
          () => bob.emailCarrierConfig!.deferred.any((m) => m.uid == mail.uid),
        );
        expect(mail.deleted, isFalse);
        expect(
          bob.deltaChats.chats[aliceFp]!.messages.where(
            (m) => m.attachments.isNotEmpty,
          ),
          isEmpty,
        );
        final message = bob.deltaChats.chats.values
            .firstWhere((c) => c.key.startsWith('deferred:'))
            .messages
            .single;
        await bob.downloadDeltaMail(message);
        expect(mail.deleted, isTrue);
        expect(
          bob.deltaChats.chats[aliceFp]!.messages.last.attachments,
          hasLength(1),
        );
      },
    );

    test(
      'Delta custom preset defers even tiny authenticated files on unmetered links',
      () async {
        await bob.updateGlobalConnectivity(
          bob.identity!.connectivity.copyWith(
            autoDownloadPreset: AutoDownloadPreset.custom,
          ),
        );
        server.deliver(
          bobMail,
          await fixture(
            id: 'custom-small@example.org',
            files: [
              DeltaFile(
                name: 'small.bin',
                bytes: Uint8List.fromList([1, 2, 3, 4]),
              ),
            ],
          ),
        );
        final mail = server.mailboxes[bobMail]!.last;
        await until(
          () => bob.emailCarrierConfig!.deferred.any((m) => m.uid == mail.uid),
        );
        expect(mail.deleted, isFalse);
        expect(
          bob.deltaChats.chats[aliceFp]!.messages.where(
            (m) => m.attachments.isNotEmpty,
          ),
          isEmpty,
        );
      },
    );

    test(
      'Delta prefix on a Conest archive file does not change cache ownership or saved references',
      () async {
        bob.deltaAttachmentCacheLimitBytes = 4;
        final bytes = Uint8List.fromList([1, 2, 3, 4]);
        server.deliver(
          bobMail,
          await fixture(
            id: 'shared-owner@example.org',
            files: [DeltaFile(name: 'shared.bin', bytes: bytes)],
          ),
        );
        await until(
          () => bob.deltaChats.chats[aliceFp]!.messages.any(
            (m) => m.attachments.isNotEmpty,
          ),
        );
        final delta =
            bob.deltaChats.chats[aliceFp]!.messages.last.attachments.single;
        final foreign = AttachmentDescriptor.fromJson({
          ...delta.toJson(),
          'id': 'delta:foreign',
        });
        final deltaPath = (await bob.attachmentCachePathFor(delta.id))!;
        final conestPath =
            '${root.path}/bob/cache/${attachmentStorageKey('sha256:${foreign.fileHashBase64}')}';
        await File(conestPath).writeAsBytes(bytes);
        await bob.addLinkArchiveForTesting(
          LinkArchive(
            id: 'foreign-prefix',
            createdAt: clock,
            contacts: const [],
            groups: const [],
            conversations: [
              ConversationRecord(
                id: 'old-chat',
                kind: ConversationKind.direct,
                peerDeviceId: 'old-peer',
                messages: [
                  ChatMessage(
                    id: 'old-message',
                    conversationId: 'old-chat',
                    senderDeviceId: 'old-peer',
                    recipientDeviceId: bob.identity!.deviceId,
                    body: '',
                    outbound: false,
                    state: DeliveryState.delivered,
                    createdAt: clock,
                    attachment: foreign,
                  ),
                ],
              ),
            ],
          ),
        );
        expect(await bob.attachmentCachePathFor(foreign.id), conestPath);
        expect(await bob.attachmentCachePathFor(delta.id), deltaPath);
        await bob.markAttachmentExplicitlySaved(foreign.id);
        server.deliver(
          bobMail,
          await fixture(id: 'unrelated-save@example.org', text: 'text'),
        );
        await until(
          () => bob.deltaChats.chats[aliceFp]!.messages.any(
            (m) => m.id == 'unrelated-save@example.org',
          ),
        );
        expect(
          bobVault._snapshot.attachmentCacheReferences
              .singleWhere((r) => r.attachmentId == foreign.id)
              .explicitlySaved,
          isTrue,
        );
        expect(await File(conestPath).readAsBytes(), bytes);
        server.deliver(
          bobMail,
          await fixture(
            id: 'new-owner@example.org',
            files: [
              DeltaFile(
                name: 'new.bin',
                bytes: Uint8List.fromList([5, 6, 7, 8]),
              ),
            ],
          ),
        );
        await until(
          () => bob.deltaChats.chats[aliceFp]!.messages.any(
            (m) => m.id == 'new-owner@example.org',
          ),
        );
        expect(bob.attachmentAvailableLocally(delta.id), isFalse);
        expect(await File(conestPath).readAsBytes(), bytes);
      },
    );

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

part of 'messenger_controller_test.dart';

/// Own-device sync, phase P1 (M33): what each device wants to sync, told to
/// the others and obeyed on every path.
void _ownDeviceSyncP1ControllerTests() {
  group('own devices say what they want to sync (M33 P1)', () {
    /// Alice (the laptop) and her phone as one account, and Bob, a contact
    /// of the account. [v2] switches the P1 events on for the devices.
    Future<
      ({
        MessengerController alice,
        MessengerController bob,
        MessengerController phone,
        _InProcessIrohNetwork network,
        _FakeRelayClient relay,
        void Function(Duration) advance,
        Future<void> Function() pollAll,
      })
    >
    linked({bool phoneV2 = true}) async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      var now = DateTime.now().toUtc();
      Future<MessengerController> make(String name, bool v2) async {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          transportRegistryFactory: network.registry,
          nowProvider: () => now,
        );
        controller.ownDeviceSyncV2ForTesting = v2;
        addTearDown(controller.dispose);
        return controller;
      }

      final alice = await make('Alice', true);
      final bob = await make('Bob', false);
      final phone = await make('Phone', phoneV2);
      Future<void> pollAll() async {
        for (final c in [alice, bob, phone]) {
          unawaited(c.pollNow());
        }
      }

      await _pairControllers(alice, bob);
      final qr = await phone.startLinkAsNewDevice();
      await alice.startLinkFromQrCode(qr);
      await _waitForIroh(
        () => phone.linkCode != null && alice.linkCode != null,
      );
      await phone.confirmLinkCode();
      await alice.confirmLinkCode();
      final phoneId = phone.identity!.deviceId;
      await _waitForIroh(() {
        unawaited(pollAll());
        return phone.linkState == LinkState.linked &&
            alice.ownDevices.any((d) => d.deviceId == phoneId) &&
            bob.linkedDevicesOf(alice.identity!.deviceId).isNotEmpty;
      }, reason: 'the phone was not linked');
      // The devices learn of each other's capabilities (v2 or not).
      await _waitForIroh(
        () {
          unawaited(pollAll());
          final one = alice.ownDevices.single.featureCapabilities;
          final two = phone.ownDevices.single.featureCapabilities;
          return one.contains(ApplicationCapability.multiSourceTransferV1) &&
              two.contains(ApplicationCapability.multiSourceTransferV1) &&
              one.contains(ApplicationCapability.ownDeviceSyncV2) == phoneV2 &&
              two.contains(ApplicationCapability.ownDeviceSyncV2);
        },
        reason: 'the devices did not learn what each understands',
        timeout: const Duration(seconds: 30),
      );
      return (
        alice: alice,
        bob: bob,
        phone: phone,
        network: network,
        relay: relay,
        advance: (Duration by) => now = now.add(by),
        pollAll: pollAll,
      );
    }

    Future<void> pump(
      Future<void> Function() pollAll, {
      int rounds = 12,
    }) async {
      for (var i = 0; i < rounds; i++) {
        await pollAll();
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    test('what a device wants is told to the others, and kept', () async {
      final f = await linked();
      final phoneId = f.phone.identity!.deviceId;
      final aliceId = f.alice.identity!.deviceId;
      final wanted = OwnDeviceSyncPrefs.forMode(
        OwnDeviceSyncMode.contactsOnly,
      ).withCategory(SyncCategory.saved, SyncAmount.all);
      await f.phone.setOwnDeviceSyncPrefs(wanted);
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.alice.ownDevicePrefsOfForTesting(phoneId) == wanted;
      }, reason: 'the laptop was not told what the phone wants');
      // And the other way: the laptop told the phone what it wants once.
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.phone.ownDevicePrefsOfForTesting(aliceId) != null;
      }, reason: 'the phone was not told what the laptop wants');
      expect(
        f.phone.ownDevicePrefsOfForTesting(aliceId),
        OwnDeviceSyncPrefs.legacy,
      );
      // What was chosen is kept in the vault's settings.
      expect(f.phone.ownDeviceSyncPrefs, wanted);
      expect(
        GlobalConnectivityPreferences.fromJson(
          f.phone.identity!.connectivity.toJson(),
        ).ownDeviceSync,
        wanted,
      );
    });

    test('a contact cannot say what an account\'s device wants', () async {
      final f = await linked();
      final aliceId = f.alice.identity!.deviceId;
      final bobId = f.bob.identity!.deviceId;
      // Bob is a contact, not one of the account's devices.
      await f.bob.sendAccountSyncForTesting(aliceId, {
        'type': 'prefs',
        ...OwnDeviceSyncPrefs.forMode(OwnDeviceSyncMode.full).toWire(),
      });
      await pump(f.pollAll);
      expect(f.alice.ownDevicePrefsOfForTesting(bobId), isNull);
    });

    test(
      'a device that wants no messages is sent none, and takes none',
      () async {
        final f = await linked();
        final phoneId = f.phone.identity!.deviceId;
        final bobId = f.bob.identity!.deviceId;
        final independent = OwnDeviceSyncPrefs.forMode(
          OwnDeviceSyncMode.independent,
        );
        await f.phone.setOwnDeviceSyncPrefs(independent);
        await _waitForIroh(() {
          unawaited(f.pollAll());
          return f.alice.ownDevicePrefsOfForTesting(phoneId) == independent;
        }, reason: 'the laptop was not told');
        // The phone cannot be reached, so whatever is for it stays queued.
        f.relay.shouldFailStore = (_, _, _, _, envelope) =>
            envelope.recipientDeviceId == phoneId;
        f.network.blockedPairs
          ..add((
            f.alice.identity!.irohEndpointId!,
            f.phone.identity!.irohEndpointId!,
          ))
          ..add((
            f.phone.identity!.irohEndpointId!,
            f.alice.identity!.irohEndpointId!,
          ));
        await f.alice.sendMessage(
          contact: f.alice.contacts.single,
          body: 'one',
        );
        await pump(f.pollAll, rounds: 6);
        expect(
          f.alice.queuedSyncForTesting('sent', phoneId),
          0,
          reason: 'something for a device that wants none was queued',
        );
        // What reaches it anyway (a laptop that was not told) is dropped.
        f.relay.shouldFailStore = null;
        f.network.blockedPairs.clear();
        await f.alice.sendAccountSyncForTesting(phoneId, {
          'type': 'sent',
          'chat': bobId,
          'id': 'sneaked-in',
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'payload': f.alice.encodeSyncPayloadForTesting('sneaked'),
        });
        await pump(f.pollAll);
        expect(
          f.phone.messagesFor(bobId).any((m) => m.id == 'sneaked-in'),
          isFalse,
          reason: 'the phone took what it does not want',
        );
        expect(f.phone.messagesFor(bobId).any((m) => m.body == 'one'), isFalse);
        // Wanting everything again brings the laptop's messages.
        await f.phone.setOwnDeviceSyncPrefs(
          OwnDeviceSyncPrefs.forMode(OwnDeviceSyncMode.full),
        );
        await f.alice.sendMessage(
          contact: f.alice.contacts.single,
          body: 'two',
        );
        await _waitForIroh(() {
          unawaited(f.pollAll());
          return f.phone.messagesFor(bobId).any((m) => m.body == 'two');
        }, reason: 'the phone did not get what it wanted again');
      },
    );

    test('Saved can sync while messages do not', () async {
      final f = await linked();
      final phoneId = f.phone.identity!.deviceId;
      final aliceId = f.alice.identity!.deviceId;
      final bobId = f.bob.identity!.deviceId;
      final wanted = OwnDeviceSyncPrefs.forMode(
        OwnDeviceSyncMode.contactsOnly,
      ).withCategory(SyncCategory.saved, SyncAmount.all);
      await f.phone.setOwnDeviceSyncPrefs(wanted);
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.alice.ownDevicePrefsOfForTesting(phoneId) == wanted;
      }, reason: 'the laptop was not told');
      await f.alice.sendMessage(contact: f.alice.contacts.single, body: 'chat');
      await f.alice.sendMessage(
        contact: f.alice.savedMessagesContact!,
        body: 'note',
      );
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.phone
            .messagesFor(f.phone.identity!.deviceId)
            .any((m) => m.body == 'note');
      }, reason: 'the note did not reach the phone');
      expect(f.phone.messagesFor(bobId).any((m) => m.body == 'chat'), isFalse);
      expect(f.alice.queuedSyncForTesting('sent', phoneId), 0);
      expect(aliceId, isNotEmpty);
    });

    test('history goes back only as far as both want', () async {
      final f = await linked();
      final aliceId = f.alice.identity!.deviceId;
      final phoneId = f.phone.identity!.deviceId;
      final bobId = f.bob.identity!.deviceId;
      for (final device in [f.alice, f.phone]) {
        await device.setOwnDeviceTouchDays(30);
      }
      // The phone takes nothing for now, so neither message reaches it live.
      final independent = OwnDeviceSyncPrefs.forMode(
        OwnDeviceSyncMode.independent,
      );
      await f.phone.setOwnDeviceSyncPrefs(independent);
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.alice.ownDevicePrefsOfForTesting(phoneId) == independent;
      }, reason: 'the laptop was not told');
      await f.alice.sendMessage(contact: f.alice.contacts.single, body: 'old');
      f.advance(const Duration(days: 8));
      await f.alice.sendMessage(contact: f.alice.contacts.single, body: 'new');
      // Then it wants a week of messages: asked for, from the laptop.
      final week = OwnDeviceSyncPrefs.forMode(
        OwnDeviceSyncMode.full,
      ).withWindowDays(7);
      await f.phone.setOwnDeviceSyncPrefs(week);
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.phone.messagesFor(bobId).any((m) => m.body == 'new');
      }, reason: 'the recent message did not come');
      await pump(f.pollAll, rounds: 20);
      expect(
        f.phone.messagesFor(bobId).any((m) => m.body == 'old'),
        isFalse,
        reason: 'a message from before the window was served',
      );
      // A month: it comes.
      await f.phone.setOwnDeviceSyncPrefs(week.withWindowDays(30));
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.alice.ownDevicePrefsOfForTesting(phoneId)?.windowDays == 30;
      }, reason: 'the laptop was not told');
      f.phone.forgetHistoryAsksForTesting();
      f.phone.askHistoryForTesting(aliceId);
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.phone.messagesFor(bobId).any((m) => m.body == 'old');
      }, reason: 'the older message did not come with the longer window');
    });

    test('a device that wants no messages is not passed the contact\'s '
        'either', () async {
      final f = await linked();
      final phoneId = f.phone.identity!.deviceId;
      final bobId = f.bob.identity!.deviceId;
      final aliceId = f.alice.identity!.deviceId;
      final independent = OwnDeviceSyncPrefs.forMode(
        OwnDeviceSyncMode.independent,
      );
      await f.phone.setOwnDeviceSyncPrefs(independent);
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.alice.ownDevicePrefsOfForTesting(phoneId) == independent;
      }, reason: 'the laptop was not told');
      // Bob cannot reach the phone: the laptop would pass his message on.
      f.relay.shouldFailStore = (_, _, _, _, envelope) =>
          envelope.recipientDeviceId == phoneId &&
          envelope.senderDeviceId == bobId;
      f.network.blockedPairs
        ..add((
          f.bob.identity!.irohEndpointId!,
          f.phone.identity!.irohEndpointId!,
        ))
        ..add((
          f.phone.identity!.irohEndpointId!,
          f.bob.identity!.irohEndpointId!,
        ));
      await f.bob.sendMessage(contact: f.bob.contacts.single, body: 'for you');
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.alice.messagesFor(bobId).any((m) => m.body == 'for you');
      }, reason: 'the laptop did not get Bob\'s message');
      await pump(f.pollAll, rounds: 20);
      expect(
        f.alice.queuedSyncForTesting('rx', phoneId),
        0,
        reason: 'the message was queued to pass on to a device that wants none',
      );
      expect(
        f.phone.messagesFor(bobId).any((m) => m.body == 'for you'),
        isFalse,
      );
      expect(aliceId, isNotEmpty);
    });

    test(
      'a laptop that wants no messages serves none, and sends none',
      () async {
        final f = await linked();
        final aliceId = f.alice.identity!.deviceId;
        final bobId = f.bob.identity!.deviceId;
        await f.alice.sendMessage(
          contact: f.alice.contacts.single,
          body: 'kept',
        );
        await pump(f.pollAll);
        final independent = OwnDeviceSyncPrefs.forMode(
          OwnDeviceSyncMode.independent,
        );
        await f.alice.setOwnDeviceSyncPrefs(independent);
        await _waitForIroh(() {
          unawaited(f.pollAll());
          return f.phone.ownDevicePrefsOfForTesting(aliceId) == independent;
        }, reason: 'the phone was not told');
        await f.alice.sendMessage(
          contact: f.alice.contacts.single,
          body: 'mine',
        );
        await pump(f.pollAll);
        expect(
          f.phone.messagesFor(bobId).any((m) => m.body == 'mine'),
          isFalse,
        );
        // A phone that asks for history without looking at what the laptop
        // wants (as an older build would): the laptop serves nothing.
        final before = f.alice.historyMessagesServedForTesting;
        final answeredBefore = f.alice.historyRequestsAnsweredForTesting;
        await f.phone.sendAccountSyncForTesting(aliceId, {
          'type': 'history_req',
          'chats': [
            {'chat': bobId},
          ],
        });
        await _waitForIroh(() {
          unawaited(f.pollAll());
          return f.alice.historyRequestsAnsweredForTesting > answeredBefore;
        }, reason: 'the request never reached the laptop');
        expect(
          f.alice.historyMessagesServedForTesting,
          before,
          reason: 'the laptop served history it does not want to sync',
        );
      },
    );

    test('a device that does not understand the P1 events is told none and '
        'gets what the app did before', () async {
      final f = await linked(phoneV2: false);
      final phoneId = f.phone.identity!.deviceId;
      final bobId = f.bob.identity!.deviceId;
      await f.alice.setOwnDeviceSyncPrefs(
        OwnDeviceSyncPrefs.forMode(
          OwnDeviceSyncMode.independent,
        ).withCategory(SyncCategory.messages, SyncAmount.recent),
      );
      expect(
        f.alice.prefsToldForTesting(phoneId),
        isFalse,
        reason: 'an older build was sent an event it does not know',
      );
      expect(f.alice.ownDevicePrefsOfForTesting(phoneId), isNull);
      await f.alice.sendMessage(contact: f.alice.contacts.single, body: 'hi');
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.phone.messagesFor(bobId).any((m) => m.body == 'hi');
      }, reason: 'the older build did not get its messages as before');
      expect(phoneId, isNotEmpty);
    });

    test('on mobile data a file from another device waits for the user, '
        'on Wi-Fi it comes by itself', () async {
      final f = await linked();
      final bobId = f.bob.identity!.deviceId;
      Uint8List bytes() {
        final data = Uint8List(200 * 1024);
        for (var i = 0; i < data.length; i += 7) {
          data[i] = (i * 31) & 0xff;
        }
        return data;
      }

      f.alice.onConnectivityChanged(interfaceLabel: 'mobile');
      await f.phone.sendAttachment(
        contact: f.phone.contacts.single,
        bytes: bytes(),
        fileName: 'metered.bin',
      );
      String? id;
      await _waitForIroh(() {
        unawaited(f.pollAll());
        final m = f.alice
            .messagesFor(bobId)
            .where((m) => m.attachment?.fileName == 'metered.bin')
            .firstOrNull;
        id = m?.attachment?.id;
        return id != null;
      }, reason: 'the laptop did not hear of the file');
      await pump(f.pollAll, rounds: 25);
      expect(
        f.alice.attachmentAvailableLocally(id!),
        isFalse,
        reason: 'the bytes came over mobile data by themselves',
      );
      expect(f.alice.attachmentAwaitingAcceptance(id!), isTrue);
      // On Wi-Fi the user's yes brings it.
      f.alice.onConnectivityChanged(interfaceLabel: 'wifi');
      await f.alice.acceptIncomingAttachment(id!);
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.alice.attachmentAvailableLocally(id!);
      }, reason: 'the file did not come after the user said yes');
    });

    // ---- settings, key by key ----------------------------------------

    Future<void> shareSettingsOn(
      ({
        MessengerController alice,
        MessengerController bob,
        MessengerController phone,
        _InProcessIrohNetwork network,
        _FakeRelayClient relay,
        void Function(Duration) advance,
        Future<void> Function() pollAll,
      })
      f,
    ) async {
      await f.alice.setShareSettings(true);
      await f.phone.setShareSettings(true);
    }

    void cutOff(
      ({
        MessengerController alice,
        MessengerController bob,
        MessengerController phone,
        _InProcessIrohNetwork network,
        _FakeRelayClient relay,
        void Function(Duration) advance,
        Future<void> Function() pollAll,
      })
      f,
    ) {
      final phoneId = f.phone.identity!.deviceId;
      final aliceId = f.alice.identity!.deviceId;
      f.relay.shouldFailStore = (_, _, _, _, envelope) =>
          envelope.recipientDeviceId == phoneId ||
          envelope.recipientDeviceId == aliceId &&
              envelope.senderDeviceId == phoneId;
      f.network.blockedPairs
        ..add((
          f.alice.identity!.irohEndpointId!,
          f.phone.identity!.irohEndpointId!,
        ))
        ..add((
          f.phone.identity!.irohEndpointId!,
          f.alice.identity!.irohEndpointId!,
        ));
    }

    void reconnect(
      ({
        MessengerController alice,
        MessengerController bob,
        MessengerController phone,
        _InProcessIrohNetwork network,
        _FakeRelayClient relay,
        void Function(Duration) advance,
        Future<void> Function() pollAll,
      })
      f,
    ) {
      f.relay.shouldFailStore = null;
      f.network.blockedPairs.clear();
    }

    Future<void> change(
      MessengerController device, {
      AutoDownloadPreset? preset,
      bool? storageReserve,
    }) => device.updateGlobalConnectivity(
      device.identity!.connectivity.copyWith(
        autoDownloadPreset: preset,
        storageReserveEnabled: storageReserve,
      ),
    );

    test(
      'a setting changed on one device reaches the other, with a clock',
      () async {
        final f = await linked();
        await shareSettingsOn(f);
        await change(f.alice, preset: AutoDownloadPreset.custom);
        await _waitForIroh(() {
          unawaited(f.pollAll());
          return f.phone.identity!.connectivity.autoDownloadPreset ==
              AutoDownloadPreset.custom;
        }, reason: 'the phone did not take the setting');
        final clock = HybridClock.parse(
          f.phone.identity!.connectivity.settingsClocks['autoDownloadPreset'],
        );
        expect(clock, isNotNull);
        expect(clock!.deviceId, f.alice.identity!.deviceId);
        // The clock of the setting that changed is later than the one the
        // laptop gave every setting when sharing began.
        final began = HybridClock.parse(
          f
              .alice
              .identity!
              .connectivity
              .settingsClocks['storageReserveEnabled'],
        );
        expect(began, isNotNull);
        expect(clock.isAfter(began!), isTrue);
      },
    );

    test(
      'two devices change different settings at once, and both stay',
      () async {
        final f = await linked();
        await shareSettingsOn(f);
        cutOff(f);
        await change(f.alice, preset: AutoDownloadPreset.custom);
        await change(f.phone, storageReserve: false);
        reconnect(f);
        await _waitForIroh(
          () {
            unawaited(f.alice.retryUnacknowledgedMessagesNow());
            unawaited(f.phone.retryUnacknowledgedMessagesNow());
            unawaited(f.pollAll());
            final one = f.alice.identity!.connectivity;
            final two = f.phone.identity!.connectivity;
            return one.autoDownloadPreset == AutoDownloadPreset.custom &&
                !one.storageReserveEnabled &&
                two.autoDownloadPreset == AutoDownloadPreset.custom &&
                !two.storageReserveEnabled;
          },
          reason: 'one of the changes was lost',
          timeout: const Duration(seconds: 30),
        );
      },
    );

    test('the later write of a setting wins, and the same millisecond goes '
        'to the higher device id', () async {
      final f = await linked();
      await shareSettingsOn(f);
      cutOff(f);
      // The same millisecond on both (the clock is still): the higher id wins.
      await change(f.alice, preset: AutoDownloadPreset.custom);
      await change(f.phone, preset: AutoDownloadPreset.high);
      final higher =
          f.alice.identity!.deviceId.compareTo(f.phone.identity!.deviceId) > 0;
      final expected = higher
          ? AutoDownloadPreset.custom
          : AutoDownloadPreset.high;
      reconnect(f);
      await _waitForIroh(
        () {
          unawaited(f.alice.retryUnacknowledgedMessagesNow());
          unawaited(f.phone.retryUnacknowledgedMessagesNow());
          unawaited(f.pollAll());
          return f.alice.identity!.connectivity.autoDownloadPreset ==
                  expected &&
              f.phone.identity!.connectivity.autoDownloadPreset == expected;
        },
        reason: 'the two did not agree on the winner',
        timeout: const Duration(seconds: 30),
      );
      // A later write beats it, whoever wrote it.
      f.advance(const Duration(seconds: 5));
      final loser = higher ? f.phone : f.alice;
      await change(loser, preset: AutoDownloadPreset.medium);
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.alice.identity!.connectivity.autoDownloadPreset ==
                AutoDownloadPreset.medium &&
            f.phone.identity!.connectivity.autoDownloadPreset ==
                AutoDownloadPreset.medium;
      }, reason: 'a later write did not win');
    });

    test('a clock far ahead of this device\'s own time is refused', () async {
      final f = await linked();
      await shareSettingsOn(f);
      final aliceId = f.alice.identity!.deviceId;
      final phoneId = f.phone.identity!.deviceId;
      final farAhead = DateTime.now()
          .toUtc()
          .add(const Duration(hours: 2))
          .millisecondsSinceEpoch;
      await f.phone.sendAccountSyncForTesting(aliceId, {
        'type': 'settings2',
        'k': {
          'autoDownloadPreset': [
            AutoDownloadPreset.high.name,
            farAhead,
            phoneId,
          ],
        },
      });
      await pump(f.pollAll);
      expect(
        f.alice.identity!.connectivity.autoDownloadPreset,
        isNot(AutoDownloadPreset.high),
      );
      expect(
        HybridClock.parse(
          f.alice.identity!.connectivity.settingsClocks['autoDownloadPreset'],
        )?.milliseconds,
        isNot(farAhead),
        reason: 'the clock that is far ahead was kept',
      );
    });

    test('a setting that lowers protection waits for the user', () async {
      final f = await linked();
      await shareSettingsOn(f);
      await f.phone.updateSuppressReadReceipts(true);
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.alice.identity!.suppressReadReceipts;
      }, reason: 'the stronger setting did not arrive');
      f.advance(const Duration(seconds: 5));
      await f.phone.updateSuppressReadReceipts(false);
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.alice.pendingSharedSettings.containsKey(
          'suppressReadReceipts',
        );
      }, reason: 'the weaker setting was not offered');
      expect(
        f.alice.identity!.suppressReadReceipts,
        isTrue,
        reason: 'a weaker privacy setting was applied without asking',
      );
      await f.alice.confirmSharedSetting('suppressReadReceipts');
      expect(f.alice.identity!.suppressReadReceipts, isFalse);
      expect(f.alice.pendingSharedSettings, isEmpty);
      // And it was not told back: the phone's own clock stays its own.
      expect(
        HybridClock.parse(
          f.phone.identity!.connectivity.settingsClocks['suppressReadReceipts'],
        )!.deviceId,
        f.phone.identity!.deviceId,
      );
    });

    test('a setting that lowers protection can be turned down', () async {
      final f = await linked();
      await shareSettingsOn(f);
      await f.phone.updateSuppressReadReceipts(true);
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.alice.identity!.suppressReadReceipts;
      }, reason: 'the stronger setting did not arrive');
      f.advance(const Duration(seconds: 5));
      await f.phone.updateSuppressReadReceipts(false);
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.alice.pendingSharedSettings.isNotEmpty;
      }, reason: 'the weaker setting was not offered');
      f.alice.dismissSharedSetting('suppressReadReceipts');
      expect(f.alice.pendingSharedSettings, isEmpty);
      expect(f.alice.identity!.suppressReadReceipts, isTrue);
    });

    test('a device that does not take settings key by key still gets the '
        'whole bundle', () async {
      final f = await linked(phoneV2: false);
      await shareSettingsOn(f);
      // (The whole bundle is dated to the second.)
      f.advance(const Duration(seconds: 5));
      await change(f.alice, preset: AutoDownloadPreset.custom);
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.phone.identity!.connectivity.autoDownloadPreset ==
            AutoDownloadPreset.custom;
      }, reason: 'the older build did not get the setting as before');
      expect(
        HybridClock.parse(
          f.phone.identity!.connectivity.settingsClocks['autoDownloadPreset'],
        )?.deviceId,
        f.phone.identity!.deviceId,
        reason: 'an older build was handled key by key',
      );
    });

    test('a setting event that was lost is repaired by the status', () async {
      final f = await linked();
      await shareSettingsOn(f);
      final aliceId = f.alice.identity!.deviceId;
      final phoneId = f.phone.identity!.deviceId;
      // The phone's event for this was lost on the way: it changed, and the
      // laptop never heard.
      await f.phone.changeStorageReserveWithoutTellingForTesting(false);
      await pump(f.pollAll);
      expect(f.alice.identity!.connectivity.storageReserveEnabled, isTrue);
      expect(
        f.alice.settingsClockHashForTesting(),
        isNot(f.phone.settingsClockHashForTesting()),
      );
      // The laptop says what it holds; the phone sees the clocks differ and
      // sends its settings.
      f.alice.sendSyncStatusForTesting(phoneId);
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return !f.alice.identity!.connectivity.storageReserveEnabled;
      }, reason: 'the lost setting was never repaired');
      expect(
        f.alice.settingsClockHashForTesting(),
        f.phone.settingsClockHashForTesting(),
      );
      expect(aliceId, isNotEmpty);
    });

    test('a status goes with the events after enough of them, or enough '
        'time', () async {
      final f = await linked();
      final phoneId = f.phone.identity!.deviceId;
      void event(int i) => f.alice.syncToOwnDevicesForTesting({
        'type': 'seen',
        'ids': ['chat|id$i'],
      }, only: phoneId);
      // A status resets the count (what came before the test is not held
      // against it).
      f.alice.sendSyncStatusForTesting(phoneId);
      final before = f.alice.statusSentCountForTesting;
      for (var i = 0; i < 49; i++) {
        event(i);
      }
      expect(
        f.alice.statusSentCountForTesting,
        before,
        reason: 'a status went before enough events',
      );
      event(49);
      final afterCount = f.alice.statusSentCountForTesting;
      expect(afterCount, before + 1, reason: 'no status after 50 events');
      // Few events, a long time.
      event(50);
      expect(f.alice.statusSentCountForTesting, afterCount);
      f.advance(const Duration(minutes: 31));
      event(51);
      expect(
        f.alice.statusSentCountForTesting,
        afterCount + 1,
        reason: 'no status after half an hour of contact',
      );
    });
  });
}

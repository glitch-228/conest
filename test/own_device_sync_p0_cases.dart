part of 'messenger_controller_test.dart';

/// Own-device sync, phase P0 (M33): the policy is enforced on every path,
/// and the fakes the later phases lean on are as strict as the real thing.
void _ownDeviceSyncP0ControllerTests() {
  group('strict fakes for own-device sync', () {
    Uint8List frame(int length) => Uint8List(length);

    test('the carrier fake refuses a frame over its size limit', () {
      final network = _FakeCarrierNetwork()..maxFrameBytes = 100;
      network.deliver('a', 'b', frame(100));
      expect(network.frames, hasLength(1));
      expect(
        () => network.deliver('a', 'b', frame(101)),
        throwsA(isA<_CarrierRefused>()),
      );
      expect(network.frames, hasLength(1), reason: 'nothing was accepted');
      expect(network.refusedOversize, 1);
    });

    test('the carrier fake accepts and loses the frames it is told to', () {
      final network = _FakeCarrierNetwork()..loseFrames.addAll({2, 3});
      for (var i = 0; i < 4; i++) {
        network.deliver('a', 'b', frame(i + 1));
      }
      expect(network.frames, hasLength(4), reason: 'all four were accepted');
      expect(network.lost, 2);
      expect(network.delivered.map((f) => f.$3.length), [1, 4]);
    });

    test('the carrier fake hands frames over last to first when told to', () {
      final network = _FakeCarrierNetwork()..reorderEvery = 3;
      for (var i = 1; i <= 4; i++) {
        network.deliver('a', 'b', frame(i));
      }
      // The first three came out reversed; the fourth is still held back.
      expect(network.delivered.map((f) => f.$3.length), [3, 2, 1]);
      network.flushReordered();
      expect(network.delivered.map((f) => f.$3.length), [3, 2, 1, 4]);
    });

    test('the carrier fake slows a sender down and says when to retry', () {
      var now = DateTime.utc(2026, 11, 7, 12);
      final network = _FakeCarrierNetwork()
        ..rateLimitFrames = 2
        ..rateLimitWindow = const Duration(minutes: 1)
        ..clock = () => now;
      network.deliver('a', 'b', frame(1));
      now = now.add(const Duration(seconds: 20));
      network.deliver('a', 'b', frame(1));
      // Another sender has its own budget.
      network.deliver('c', 'b', frame(1));
      _CarrierRefused? refused;
      try {
        network.deliver('a', 'b', frame(1));
      } on _CarrierRefused catch (error) {
        refused = error;
      }
      expect(refused, isNotNull);
      expect(refused!.retryAfter, const Duration(seconds: 40));
      expect(network.refusedRate, 1);
      now = now.add(const Duration(seconds: 41));
      network.deliver('a', 'b', frame(1));
      expect(network.frames, hasLength(4));
    });

    test('the defaults leave every frame as it was', () {
      final network = _FakeCarrierNetwork();
      for (var i = 0; i < 5; i++) {
        network.deliver('a', 'b', frame(1000 + i));
      }
      expect(network.frames, hasLength(5));
      expect(network.delivered, hasLength(5));
      expect(network.lost + network.refusedOversize + network.refusedRate, 0);
    });
  });

  group('own-device sync obeys the policy on every path (M33 P0)', () {
    /// Alice (the laptop) and her phone as one account, and Bob, a contact
    /// of the account.
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
    linked({EnergyPolicy? alicePolicy}) async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      var now = DateTime.now().toUtc();
      Future<MessengerController> make(
        String name, [
        EnergyPolicy? policy,
      ]) async {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          transportRegistryFactory: network.registry,
          nowProvider: () => now,
          energyPolicy: policy,
        );
        addTearDown(controller.dispose);
        return controller;
      }

      final alice = await make('Alice', alicePolicy);
      final bob = await make('Bob');
      final phone = await make('Phone');
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

    test(
      'paused holds what changes until it is resumed, and loses nothing',
      () async {
        final f = await linked();
        final phoneId = f.phone.identity!.deviceId;
        final aliceId = f.alice.identity!.deviceId;
        final bobId = f.bob.identity!.deviceId;
        await f.alice.setOwnDeviceSyncSpeed(SyncSpeed.paused);
        await f.alice.sendMessage(
          contact: f.alice.contacts.single,
          body: 'held',
        );
        await pump(f.pollAll);
        expect(
          f.bob.messagesFor(aliceId).any((m) => m.body == 'held'),
          isTrue,
          reason: 'the contact is not held up by pausing sync',
        );
        expect(
          f.phone.messagesFor(bobId).any((m) => m.body == 'held'),
          isFalse,
          reason: 'the other device is not told while paused',
        );
        expect(
          f.alice.queuedSyncForTesting('sent', phoneId),
          1,
          reason: 'it is kept for later',
        );
        await f.alice.setOwnDeviceSyncSpeed(SyncSpeed.steady);
        // Only the phone looks: the laptop sends what it held by itself.
        await _waitForIroh(
          () {
            unawaited(f.phone.pollNow());
            return f.phone.messagesFor(bobId).any((m) => m.body == 'held');
          },
          reason: 'the held message did not arrive after resuming',
          timeout: const Duration(seconds: 4),
        );
        expect(f.alice.queuedSyncForTesting('sent', phoneId), 0);
      },
    );

    test('the conditions reach the permission: cold in the background, '
        'mobile data, charging', () async {
      final power = _MutablePower(
        const PowerState(hasBattery: true, charging: false),
      );
      final f = await linked(alicePolicy: EnergyPolicy(source: power));
      final alice = f.alice;
      expect(alice.ownDeviceSyncPermission.allowed, isTrue);
      expect(alice.ownDeviceFilePermissionForTesting.allowed, isTrue);

      // Mobile data: files wait, text pages and live events do not.
      alice.onConnectivityChanged(interfaceLabel: 'mobile');
      expect(alice.ownDeviceFilePermissionForTesting.allowed, isFalse);
      expect(alice.ownDeviceSyncPermission.allowed, isTrue);
      alice.onConnectivityChanged(interfaceLabel: 'wifi');
      expect(alice.ownDeviceFilePermissionForTesting.allowed, isTrue);

      // Cold mode on battery with the app away: bulk waits, live goes.
      await alice.setEnergyBudget(EnergyBudgetSetting.cold);
      expect(alice.coldModeActive, isTrue);
      alice.setAppForegroundState(false);
      expect(alice.ownDeviceSyncPermission.allowed, isFalse);
      expect(alice.ownDeviceFilePermissionForTesting.allowed, isFalse);
      expect(alice.ownDeviceLivePermissionForTesting.allowed, isTrue);
      // The app is open again.
      alice.setAppForegroundState(true);
      expect(alice.ownDeviceSyncPermission.allowed, isTrue);
      // Plugged in on Wi-Fi: the background is fine.
      alice.setAppForegroundState(false);
      power.state = const PowerState(hasBattery: true, charging: true);
      await alice.refreshEnergyForTesting();
      expect(alice.ownDeviceSyncPermission.allowed, isTrue);
      // Plugged in, but on mobile data: not enough.
      alice.onConnectivityChanged(interfaceLabel: 'mobile');
      expect(alice.ownDeviceSyncPermission.allowed, isFalse);
    });

    test('confirming fast lasts six hours, and a restart-free expiry gives '
        'way to steady', () async {
      final f = await linked();
      final alice = f.alice;
      await alice.setOwnDeviceSyncSpeed(SyncSpeed.fast, confirmFast: true);
      expect(alice.ownDeviceSyncPolicy.fastConfirmed, isTrue);
      expect(alice.ownDeviceFilePermissionForTesting.speed, SyncSpeed.fast);
      f.advance(const Duration(hours: 5, minutes: 59));
      expect(alice.ownDeviceFilePermissionForTesting.speed, SyncSpeed.fast);
      f.advance(const Duration(minutes: 2));
      expect(alice.ownDeviceSyncPolicy.fastConfirmed, isFalse);
      expect(alice.ownDeviceFilePermissionForTesting.speed, SyncSpeed.steady);
      expect(
        alice.ownDeviceFilePermissionForTesting.bytesPerSecond,
        isNotNull,
        reason: 'steady is capped again',
      );
      // Asking for fast without confirming never counts.
      await alice.setOwnDeviceSyncSpeed(SyncSpeed.fast);
      expect(alice.ownDeviceSyncPolicy.fastConfirmed, isFalse);
    });

    test(
      'what waits for an own device does not keep a cold device awake',
      () async {
        final f = await linked();
        final phoneId = f.phone.identity!.deviceId;
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
        await f.alice.setEnergyBudget(EnergyBudgetSetting.cold);
        // A saved note is delivered at once; only the phone is told of it.
        await f.alice.sendMessage(
          contact: f.alice.savedMessagesContact!,
          body: 'note',
        );
        await pump(f.pollAll, rounds: 4);
        expect(
          f.alice.queuedSyncForTesting('sent', phoneId),
          1,
          reason: 'the phone was not reached, so it waits',
        );
        expect(
          f.alice.coldRetryDueForTesting,
          isNull,
          reason: 'a device that is away is not a reason to wake',
        );
      },
    );

    // ---- files: serving blocks to an own device ------------------------

    /// The phone sent a 3 MiB file to Bob, who has it. The laptop (set to
    /// wait for the user) knows of it from the phone and has not fetched it.
    Future<({String id, int ranges, Uint8List bytes})> phoneFileLaptopWaiting(
      ({
        MessengerController alice,
        MessengerController bob,
        MessengerController phone,
        _InProcessIrohNetwork network,
        _FakeRelayClient relay,
        void Function(Duration) advance,
        Future<void> Function() pollAll,
      })
      f, {
      int megabytes = 3,
    }) async {
      await f.alice.updateGlobalConnectivity(
        f.alice.identity!.connectivity.copyWith(
          autoDownloadPreset: AutoDownloadPreset.custom,
        ),
      );
      final bytes = Uint8List(megabytes * 1024 * 1024);
      for (var i = 0; i < bytes.length; i += 5) {
        bytes[i] = (i * 17 + (i >> 8)) & 0xff;
      }
      await f.phone.sendAttachment(
        contact: f.phone.contacts.single,
        bytes: bytes,
        fileName: 'p.bin',
      );
      final bobId = f.bob.identity!.deviceId;
      String? id;
      await _waitForIroh(
        () {
          unawaited(f.pollAll());
          final m = f.alice
              .messagesFor(bobId)
              .where((m) => m.attachment?.fileName == 'p.bin')
              .firstOrNull;
          id = m?.attachment?.id;
          if (id != null && f.bob.attachmentAwaitingAcceptance(id!)) {
            unawaited(f.bob.acceptIncomingAttachment(id!));
          }
          return id != null &&
              f.alice.attachmentAwaitingAcceptance(id!) &&
              f.bob.attachmentAvailableLocally(id!);
        },
        reason: 'the laptop did not hear of the phone\'s file',
        timeout: const Duration(seconds: 40),
      );
      return (id: id!, ranges: f.network.attachmentRanges, bytes: bytes);
    }

    test('a paused device serves no blocks to its own devices, and serves '
        'again once resumed', () async {
      final f = await linked();
      final file = await phoneFileLaptopWaiting(f);
      await f.phone.setOwnDeviceSyncSpeed(SyncSpeed.paused);
      await f.alice.acceptIncomingAttachment(file.id);
      for (var i = 0; i < 80; i++) {
        await f.pollAll();
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      expect(f.alice.attachmentAvailableLocally(file.id), isFalse);
      expect(
        f.network.attachmentRanges,
        file.ranges,
        reason: 'a block was served while paused',
      );
      await f.phone.setOwnDeviceSyncSpeed(SyncSpeed.steady);
      await _waitForIroh(
        () {
          unawaited(f.pollAll());
          return f.alice.attachmentAvailableLocally(file.id);
        },
        reason: 'the file did not come after resuming',
        timeout: const Duration(seconds: 60),
      );
      expect(
        await File(
          (await f.alice.attachmentCachePathFor(file.id))!,
        ).readAsBytes(),
        file.bytes,
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    for (final fast in [false, true]) {
      test(
        fast
            ? 'fast serves blocks to its own devices without spacing them'
            : 'steady spaces the blocks it serves to its own devices to the '
                  'cap',
        () async {
          final f = await linked();
          f.phone.steadySyncBytesPerSecondForTesting = 4 * 1024 * 1024;
          if (fast) {
            await f.phone.setOwnDeviceSyncSpeed(
              SyncSpeed.fast,
              confirmFast: true,
            );
          }
          final file = await phoneFileLaptopWaiting(f, megabytes: 9);
          await f.alice.acceptIncomingAttachment(file.id);
          await _waitForIroh(
            () {
              unawaited(f.pollAll());
              return f.alice.attachmentAvailableLocally(file.id);
            },
            reason: 'the file did not come',
            timeout: const Duration(seconds: 90),
          );
          expect(
            f.phone.ownServeDeferralsForTesting,
            fast ? 0 : greaterThanOrEqualTo(1),
          );
          expect(
            await File(
              (await f.alice.attachmentCachePathFor(file.id))!,
            ).readAsBytes(),
            file.bytes,
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    // ---- state kept for an own device ---------------------------------

    /// Fills what the laptop keeps for the phone: a reach report, a held
    /// sync event, a file the phone said it holds, a deferred block.
    Future<void> keepSomethingFor(
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
      final phoneId = f.phone.identity!.deviceId;
      final aliceId = f.alice.identity!.deviceId;
      await f.phone.sendAccountSyncForTesting(aliceId, {
        'type': 'reach',
        'heard': {'other': 30},
      });
      await _waitForIroh(() {
        unawaited(f.pollAll());
        return f.alice.ownReachForTesting(phoneId) != null;
      }, reason: 'the report did not come');
      await f.alice.setOwnDeviceSyncSpeed(SyncSpeed.paused);
      await f.alice.sendMessage(
        contact: f.alice.savedMessagesContact!,
        body: 'kept',
      );
      f.alice.ownDeviceHasFileForTesting(phoneId, 'file-1');
      f.alice.deferOwnServeForTesting(phoneId, const Duration(minutes: 5));
      f.alice.parkOwnBlockForTesting(phoneId, {
        'attachmentId': 'file-1',
        'index': 0,
      });
      expect(
        f.alice.ownDeviceSyncStateSizeForTesting(phoneId),
        greaterThanOrEqualTo(5),
      );
    }

    test('a block asked for while paused is kept and served when resumed, '
        'not left to the other device\'s slow retry', () async {
      final f = await linked();
      final file = await phoneFileLaptopWaiting(f);
      await f.phone.setOwnDeviceSyncSpeed(SyncSpeed.paused);
      await f.alice.acceptIncomingAttachment(file.id);
      await _waitForIroh(
        () {
          unawaited(f.pollAll());
          return f.phone.parkedOwnBlockCountForTesting == 1;
        },
        reason: 'the request was not kept',
        timeout: const Duration(seconds: 30),
      );
      expect(f.alice.attachmentAvailableLocally(file.id), isFalse);
      await f.phone.setOwnDeviceSyncSpeed(SyncSpeed.steady);
      expect(f.phone.parkedOwnBlockCountForTesting, 0);
      // Well inside the other device's own retry delay (30 s or more).
      await _waitForIroh(
        () {
          unawaited(f.pollAll());
          return f.alice.attachmentAvailableLocally(file.id);
        },
        reason: 'the kept request was not served on resuming',
        timeout: const Duration(seconds: 20),
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('disposing the controller cancels what waits to be served', () async {
      // Not through `linked`: that registers its own dispose.
      final solo = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Solo',
      );
      solo.deferOwnServeForTesting('some-device', const Duration(minutes: 5));
      final timers = solo.ownServeTimersForTesting;
      expect(timers, hasLength(1));
      expect(timers.single.isActive, isTrue);
      solo.dispose();
      expect(timers.single.isActive, isFalse);
      expect(solo.ownServeTimerCountForTesting, 0);
    });

    for (final trigger in [
      'the app is opened',
      'the network is not metered',
      'the device is plugged in',
    ]) {
      test(
        'requests kept for an own device are asked again when $trigger',
        () async {
          final power = _MutablePower(
            const PowerState(hasBattery: true, charging: false),
          );
          final f = await linked(alicePolicy: EnergyPolicy(source: power));
          final alice = f.alice;
          final phoneId = f.phone.identity!.deviceId;
          // What turns file bytes away, by trigger.
          if (trigger == 'the network is not metered') {
            alice.onConnectivityChanged(interfaceLabel: 'mobile');
          } else {
            // Cold, in the background, on battery.
            await alice.setEnergyBudget(EnergyBudgetSetting.cold);
            alice.setAppForegroundState(false);
          }
          expect(alice.ownDeviceFilePermissionForTesting.allowed, isFalse);
          alice.parkOwnBlockForTesting(phoneId, {
            'attachmentId': 'no-such-file',
            'index': 0,
          });
          expect(alice.parkedOwnBlockCountForTesting, 1);
          switch (trigger) {
            case 'the app is opened':
              alice.setAppForegroundState(true);
            case 'the network is not metered':
              alice.onConnectivityChanged(interfaceLabel: 'wifi');
            default:
              power.state = const PowerState(hasBattery: true, charging: true);
              await alice.refreshEnergyForTesting();
              await alice.syncColdMode();
          }
          expect(alice.parkedOwnBlockCountForTesting, 0, reason: trigger);
        },
      );
    }

    test('removing an own device clears everything kept for it', () async {
      final f = await linked();
      final phoneId = f.phone.identity!.deviceId;
      await keepSomethingFor(f);
      await f.alice.revokeAccountDevice(phoneId);
      expect(f.alice.ownDeviceSyncStateSizeForTesting(phoneId), 0);
      expect(f.alice.ownServeTimerCountForTesting, 0);
    });

    test('a vault reset clears what is kept for own devices, and no '
        'timer is left', () async {
      final f = await linked();
      final phoneId = f.phone.identity!.deviceId;
      await keepSomethingFor(f);
      await f.alice.resetIdentity();
      expect(f.alice.ownDeviceSyncStateSizeForTesting(phoneId), 0);
      expect(f.alice.ownServeTimerCountForTesting, 0);
    });

    // ---- files: how many sources a fetch may use ----------------------

    test('steady uses as many sources as its paths allow, and a confirmed '
        'fast sync uses more', () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      var now = DateTime.now().toUtc();
      Future<MessengerController> make(String name) async {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          transportRegistryFactory: network.registry,
          nowProvider: () => now,
        );
        addTearDown(controller.dispose);
        return controller;
      }

      final laptop = await make('Alice');
      final bob = await make('Bob');
      final phone = await make('Phone');
      final tablet = await make('Tablet');
      final all = [laptop, bob, phone, tablet];
      Future<void> pollAll() async {
        for (final c in all) {
          unawaited(c.pollNow());
        }
      }

      await _pairControllers(laptop, bob);
      for (final device in [phone, tablet]) {
        final qr = await device.startLinkAsNewDevice();
        await laptop.startLinkFromQrCode(qr);
        await _waitForIroh(
          () => device.linkCode != null && laptop.linkCode != null,
        );
        await device.confirmLinkCode();
        await laptop.confirmLinkCode();
        final deviceId = device.identity!.deviceId;
        await _waitForIroh(() {
          unawaited(pollAll());
          return device.linkState == LinkState.linked &&
              laptop.ownDevices.any((d) => d.deviceId == deviceId);
        }, reason: 'a device was not linked');
      }
      await _waitForIroh(
        () {
          unawaited(pollAll());
          return phone.ownDevices.length == 2 && tablet.ownDevices.length == 2;
        },
        reason: 'the devices did not learn of each other',
        timeout: const Duration(seconds: 30),
      );
      for (final waiting in [phone, tablet]) {
        await waiting.updateGlobalConnectivity(
          waiting.identity!.connectivity.copyWith(
            autoDownloadPreset: AutoDownloadPreset.custom,
          ),
        );
      }
      // The tablet may use one path in steady; fast lifts that.
      tablet.steadySyncPathsForTesting = 1;
      final bobId = bob.identity!.deviceId;
      final bytes = Uint8List(3 * 1024 * 1024);
      for (var i = 0; i < bytes.length; i += 3) {
        bytes[i] = (i * 131 + (i >> 9)) & 0xff;
      }
      await bob.sendAttachment(
        contact: bob.contacts.single,
        bytes: bytes,
        fileName: 'paths.bin',
      );
      String? id;
      await _waitForIroh(
        () {
          unawaited(pollAll());
          final m = laptop
              .messagesFor(bobId)
              .where((m) => m.attachment?.fileName == 'paths.bin')
              .firstOrNull;
          id = m?.attachment?.id;
          if (id != null && laptop.attachmentAwaitingAcceptance(id!)) {
            unawaited(laptop.acceptIncomingAttachment(id!));
          }
          return id != null && laptop.attachmentAvailableLocally(id!);
        },
        reason: 'the laptop did not get the file',
        timeout: const Duration(seconds: 40),
      );
      await _waitForIroh(
        () {
          unawaited(pollAll());
          now = now.add(const Duration(seconds: 5));
          return phone.blockSourcesForTesting(id!) != null &&
              tablet.blockSourcesForTesting(id!) != null;
        },
        reason: 'the phone and the tablet did not hear of the file',
        timeout: const Duration(seconds: 40),
      );
      final phoneId = phone.identity!.deviceId;
      final laptopSource = BlockSource.peer(laptop.identity!.deviceId);
      final phoneSource = BlockSource.peer(phoneId);
      // The phone fetches the file, then says it holds it.
      await phone.acceptIncomingAttachment(id!);
      await _waitForIroh(
        () {
          unawaited(pollAll());
          return phone.attachmentAvailableLocally(id!);
        },
        reason: 'the phone did not get the file',
        timeout: const Duration(seconds: 60),
      );
      await _waitForIroh(
        () {
          unawaited(pollAll());
          return tablet.ownDeviceFileHoldersForTesting(id!).contains(phoneId);
        },
        reason: 'the tablet did not hear that the phone holds it',
        timeout: const Duration(seconds: 40),
      );
      expect(
        tablet.blockSourcesForTesting(id!)!.sources,
        [laptopSource],
        reason: 'steady, one path: the phone is known but not used',
      );
      await tablet.setOwnDeviceSyncSpeed(SyncSpeed.fast, confirmFast: true);
      tablet.askForOtherSourcesForTesting(id!, forgetDevice: phoneId);
      await _waitForIroh(
        () {
          unawaited(pollAll());
          return tablet.blockSourcesForTesting(id!)?.contains(phoneSource) ==
              true;
        },
        reason: 'fast did not take the phone as a second source',
        timeout: const Duration(seconds: 40),
      );
    }, timeout: const Timeout(Duration(minutes: 4)));
  });
}

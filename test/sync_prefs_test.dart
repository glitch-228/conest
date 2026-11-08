import 'package:conest/src/models.dart';
import 'package:conest/src/sync/sync_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('presets', () {
    test('full syncs everything, Saved included', () {
      final full = OwnDeviceSyncPrefs.forMode(OwnDeviceSyncMode.full);
      expect(full.mode, OwnDeviceSyncMode.full);
      for (final category in SyncCategory.values) {
        expect(
          full.amount(category),
          isNot(SyncAmount.off),
          reason: '$category',
        );
      }
      expect(full.amount(SyncCategory.saved), SyncAmount.all);
      expect(full.amount(SyncCategory.messages), SyncAmount.recent);
    });

    test('contacts only leaves messages, media, files and Saved off', () {
      final prefs = OwnDeviceSyncPrefs.forMode(OwnDeviceSyncMode.contactsOnly);
      expect(prefs.amount(SyncCategory.contacts), SyncAmount.all);
      expect(prefs.amount(SyncCategory.settings), SyncAmount.all);
      for (final category in [
        SyncCategory.messages,
        SyncCategory.media,
        SyncCategory.files,
        SyncCategory.saved,
      ]) {
        expect(prefs.amount(category), SyncAmount.off, reason: '$category');
      }
    });

    test('independent syncs nothing', () {
      final prefs = OwnDeviceSyncPrefs.forMode(OwnDeviceSyncMode.independent);
      for (final category in SyncCategory.values) {
        expect(prefs.amount(category), SyncAmount.off, reason: '$category');
      }
    });

    test('Saved can be turned on on its own, and the mode becomes custom', () {
      final prefs = OwnDeviceSyncPrefs.forMode(
        OwnDeviceSyncMode.contactsOnly,
      ).withCategory(SyncCategory.saved, SyncAmount.all);
      expect(prefs.mode, OwnDeviceSyncMode.custom);
      expect(prefs.amount(SyncCategory.saved), SyncAmount.all);
      expect(prefs.amount(SyncCategory.messages), SyncAmount.off);
      expect(prefs.amount(SyncCategory.contacts), SyncAmount.all);
    });

    test('a vault without the field means what the app did before', () {
      final legacy = OwnDeviceSyncPrefs.legacy;
      expect(legacy.mode, OwnDeviceSyncMode.custom);
      expect(legacy.amount(SyncCategory.messages), SyncAmount.recent);
      expect(legacy.windowDays, 30);
      expect(legacy.amount(SyncCategory.saved), SyncAmount.all);
      expect(legacy.amount(SyncCategory.media), SyncAmount.off);
      expect(legacy.amount(SyncCategory.files), SyncAmount.off);
      expect(legacy.amount(SyncCategory.contacts), SyncAmount.all);
    });
  });

  group('stored and sent', () {
    test('it round-trips, and the default is not written', () {
      expect(OwnDeviceSyncPrefs.legacy.toJson(), isNull);
      final prefs = OwnDeviceSyncPrefs.forMode(OwnDeviceSyncMode.full)
          .withWindowDays(90)
          .withMobileData(true)
          .withCategory(SyncCategory.files, SyncAmount.off);
      final back = OwnDeviceSyncPrefs.fromJson(prefs.toJson());
      expect(back, prefs);
      expect(back!.windowDays, 90);
      expect(back.mobileData, isTrue);
      expect(back.amount(SyncCategory.files), SyncAmount.off);
    });

    test('names it does not know are skipped, and a bad amount is off', () {
      final prefs = OwnDeviceSyncPrefs.fromJson({
        'mode': 'nonsense',
        'cats': {
          'messages': 'all',
          'media': 'everything',
          'teleportation': 'all',
          'saved': 7,
        },
        'windowDays': 31,
      });
      expect(prefs, isNotNull);
      expect(prefs!.mode, OwnDeviceSyncMode.custom);
      expect(prefs.amount(SyncCategory.messages), SyncAmount.all);
      expect(prefs.amount(SyncCategory.media), SyncAmount.off);
      expect(prefs.amount(SyncCategory.saved), SyncAmount.off);
      // A category that is not named is off: fail closed.
      expect(prefs.amount(SyncCategory.files), SyncAmount.off);
      expect(OwnDeviceSyncPrefs.windowChoices, contains(prefs.windowDays));
    });

    test('what is not a map is not taken', () {
      expect(OwnDeviceSyncPrefs.fromJson(null), isNull);
      expect(OwnDeviceSyncPrefs.fromJson('full'), isNull);
      expect(OwnDeviceSyncPrefs.fromJson([1, 2]), isNull);
      expect(OwnDeviceSyncPrefs.fromJson({'cats': 'all'}), isNull);
    });

    test('the window is one of the choices', () {
      expect(OwnDeviceSyncPrefs.legacy.withWindowDays(1).windowDays, 7);
      expect(OwnDeviceSyncPrefs.legacy.withWindowDays(45).windowDays, 30);
      expect(OwnDeviceSyncPrefs.legacy.withWindowDays(9999).windowDays, 90);
    });
  });

  group('what two devices may sync', () {
    OwnDeviceSyncPrefs prefs(
      Map<SyncCategory, SyncAmount> cats, {
      int days = 30,
    }) => OwnDeviceSyncPrefs(
      mode: OwnDeviceSyncMode.custom,
      categories: cats,
      windowDays: days,
    );

    test('it is the smaller of the two, per category', () {
      final mine = prefs({
        SyncCategory.messages: SyncAmount.all,
        SyncCategory.saved: SyncAmount.all,
        SyncCategory.contacts: SyncAmount.off,
      });
      final theirs = prefs({
        SyncCategory.messages: SyncAmount.recent,
        SyncCategory.saved: SyncAmount.off,
        SyncCategory.contacts: SyncAmount.all,
      });
      final scope = OwnDeviceScope(mine: mine, theirs: theirs);
      expect(scope.amount(SyncCategory.messages), SyncAmount.recent);
      expect(scope.amount(SyncCategory.saved), SyncAmount.off);
      expect(scope.amount(SyncCategory.contacts), SyncAmount.off);
    });

    test('a device that has not said what it wants gets what the app did '
        'before', () {
      final scope = OwnDeviceScope(
        mine: OwnDeviceSyncPrefs.forMode(OwnDeviceSyncMode.full),
        theirs: null,
      );
      expect(scope.amount(SyncCategory.messages), SyncAmount.recent);
      expect(scope.amount(SyncCategory.saved), SyncAmount.all);
      expect(scope.amount(SyncCategory.media), SyncAmount.off);
    });

    test('the window is the shorter of the two when both are recent', () {
      final scope = OwnDeviceScope(
        mine: prefs({SyncCategory.messages: SyncAmount.recent}, days: 90),
        theirs: prefs({SyncCategory.messages: SyncAmount.recent}, days: 7),
      );
      expect(scope.windowFor(SyncCategory.messages), const Duration(days: 7));
      // `all` on one side leaves the other's window.
      final one = OwnDeviceScope(
        mine: prefs({SyncCategory.messages: SyncAmount.all}),
        theirs: prefs({SyncCategory.messages: SyncAmount.recent}, days: 7),
      );
      expect(one.windowFor(SyncCategory.messages), const Duration(days: 7));
      // `all` on both has none; off is no time at all.
      final both = OwnDeviceScope(
        mine: prefs({SyncCategory.saved: SyncAmount.all}),
        theirs: prefs({SyncCategory.saved: SyncAmount.all}),
      );
      expect(both.windowFor(SyncCategory.saved), isNull);
      expect(both.windowFor(SyncCategory.files), Duration.zero);
    });
  });

  group('which category an event is', () {
    test('messages, Saved, settings and the rest', () {
      expect(categoryOfSyncEvent('sent', 'saved'), SyncCategory.saved);
      expect(categoryOfSyncEvent('sent', 'dev-bob'), SyncCategory.messages);
      expect(categoryOfSyncEvent('rx', 'dev-bob'), SyncCategory.messages);
      expect(categoryOfSyncEvent('state', 'saved'), SyncCategory.saved);
      expect(categoryOfSyncEvent('read', 'dev-bob'), SyncCategory.messages);
      expect(categoryOfSyncEvent('group_message', 'g1'), SyncCategory.messages);
      expect(categoryOfSyncEvent('history_page', 'saved'), SyncCategory.saved);
      expect(categoryOfSyncEvent('history_req', null), SyncCategory.messages);
      // Who holds which file is said whatever the categories are.
      expect(categoryOfSyncEvent('have', null), isNull);
      expect(categoryOfSyncEvent('have_q', null), isNull);
      expect(categoryOfSyncEvent('settings', null), SyncCategory.settings);
      expect(categoryOfSyncEvent('settings2', null), SyncCategory.settings);
      // Bookkeeping that is not content goes whatever the categories say.
      expect(categoryOfSyncEvent('prefs', null), isNull);
      expect(categoryOfSyncEvent('reach', null), isNull);
      expect(categoryOfSyncEvent('seen', null), isNull);
      expect(categoryOfSyncEvent('digest', null), isNull);
      expect(categoryOfSyncEvent('unknown-type', null), isNull);
    });
  });

  group('in the vault', () {
    test('a vault that never chose reads and writes as before', () {
      const prefs = GlobalConnectivityPreferences();
      expect(prefs.ownDeviceSync, OwnDeviceSyncPrefs.legacy);
      expect(prefs.toJson().containsKey('ownDeviceSync'), isFalse);
      expect(prefs.toJson().containsKey('settingsClocks'), isFalse);
      final back = GlobalConnectivityPreferences.fromJson(prefs.toJson());
      expect(back.ownDeviceSyncChoice, isNull);
      expect(back.ownDeviceSync, OwnDeviceSyncPrefs.legacy);
    });

    test(
      'what was chosen, and when shared settings were written, are kept',
      () {
        final prefs = const GlobalConnectivityPreferences().copyWith(
          ownDeviceSync: OwnDeviceSyncPrefs.forMode(
            OwnDeviceSyncMode.contactsOnly,
          ).withCategory(SyncCategory.saved, SyncAmount.all),
          settingsClocks: const {'storageReserveEnabled': '1000|dev-a'},
        );
        final back = GlobalConnectivityPreferences.fromJson(prefs.toJson());
        expect(back.ownDeviceSync, prefs.ownDeviceSync);
        expect(back.ownDeviceSync.amount(SyncCategory.saved), SyncAmount.all);
        expect(back.settingsClocks, {'storageReserveEnabled': '1000|dev-a'});
      },
    );

    test('older and newer vaults load: unknown names are not guessed', () {
      final back = GlobalConnectivityPreferences.fromJson({
        'ownDeviceSync': {
          'mode': 'from-the-future',
          'cats': {'saved': 'everything', 'messages': 'all'},
        },
        'settingsClocks': {'ok': 'x|y', 'bad': 5},
      });
      expect(back.ownDeviceSync.amount(SyncCategory.saved), SyncAmount.off);
      expect(back.ownDeviceSync.amount(SyncCategory.messages), SyncAmount.all);
      expect(back.settingsClocks, {'ok': 'x|y'});
    });
  });
}

import 'package:conest/src/lan_direct.dart';
import 'package:conest/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

PeerEndpoint lan(String host, {int port = 7667}) =>
    PeerEndpoint(kind: PeerRouteKind.lan, host: host, port: port);

GroupMemberProfile profile(String id, List<PeerEndpoint> routes) =>
    GroupMemberProfile(
      accountId: 'acc-$id',
      deviceId: id,
      displayName: id,
      bio: '',
      relayCapable: false,
      publicKeyBase64: 'key-$id',
      routeHints: routes,
    );

void main() {
  group('prunePeerEndpointsByKind', () {
    final routes = [
      lan('192.168.1.5'),
      lan('169.254.3.4'),
      lan('fe80::1'),
      lan('fe80::2%3'),
      lan('10.0.0.2'),
    ];

    test('keeps everything by default: a vault that already holds a '
        'link-local route loads as it was', () {
      expect(prunePeerEndpointsByKind(routes).map((r) => r.host), [
        '192.168.1.5',
        '169.254.3.4',
        'fe80::1',
        'fe80::2%3',
        '10.0.0.2',
      ]);
    });

    test('drops link-local and zoned hosts when asked, nothing else', () {
      expect(
        prunePeerEndpointsByKind(
          routes,
          dropLinkScoped: true,
        ).map((r) => r.host),
        ['192.168.1.5', '10.0.0.2'],
      );
    });
  });

  group('GroupRecord.withoutLinkScopedRoutes', () {
    GroupRecord group(List<GroupMemberProfile> profiles) => GroupRecord(
      groupId: 'g1',
      title: 'Group',
      ownerDeviceId: 'dev-a',
      adminDeviceIds: const ['dev-a'],
      memberDeviceIds: const ['dev-a', 'dev-b'],
      removedDeviceIds: const [],
      memberProfiles: profiles,
      membershipVersion: 1,
      createdAt: DateTime.utc(2026, 11, 6),
      updatedAt: DateTime.utc(2026, 11, 6),
    );

    test('strips them from every member profile', () {
      final incoming = group([
        profile('dev-a', [lan('192.168.1.5'), lan('169.254.3.4')]),
        profile('dev-b', [lan('fe80::2%3')]),
      ]);
      final clean = incoming.withoutLinkScopedRoutes();
      expect(clean.memberProfiles.map((p) => p.routeHints.map((r) => r.host)), [
        ['192.168.1.5'],
        <String>[],
      ]);
    });

    test('returns the same record when there is nothing to strip', () {
      final incoming = group([
        profile('dev-a', [lan('192.168.1.5')]),
      ]);
      expect(identical(incoming.withoutLinkScopedRoutes(), incoming), isTrue);
    });
  });

  group('isValidLanDirectHost', () {
    test('rejects any zone: a contact must not point the file client at a '
        'link of ours', () {
      expect(isValidLanDirectHost('fe80::1'), isTrue);
      expect(isValidLanDirectHost('169.254.1.5'), isTrue);
      expect(isValidLanDirectHost('fe80::1%3'), isFalse);
      expect(isValidLanDirectHost('fe80::1%25eth0'), isFalse);
      expect(isValidLanDirectHost('fe80::1%lo'), isFalse);
    });
  });

  group('GlobalConnectivityPreferences.cableLinksEnabled', () {
    test(
      'is on for a vault that never heard of it and is not written then',
      () {
        final loaded = GlobalConnectivityPreferences.fromJson(
          const <String, dynamic>{},
        );
        expect(loaded.cableLinksEnabled, isTrue);
        expect(loaded.toJson().containsKey('cableLinksEnabled'), isFalse);
      },
    );

    test('off survives a save and load, and copyWith', () {
      final off = const GlobalConnectivityPreferences().copyWith(
        cableLinksEnabled: false,
      );
      expect(off.toJson()['cableLinksEnabled'], isFalse);
      expect(
        GlobalConnectivityPreferences.fromJson(off.toJson()).cableLinksEnabled,
        isFalse,
      );
      expect(off.copyWith(lanEnabled: false).cableLinksEnabled, isFalse);
    });
  });
}

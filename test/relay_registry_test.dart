import 'package:conest/src/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const real = 'REAL-IDENTITY-KEY';
  const evil = 'EVIL-IDENTITY-KEY';

  setUp(RelayClient.resetSessionsForTesting);
  tearDown(RelayClient.resetSessionsForTesting);

  group('hidden routes are kept by the identity they are pinned to', () {
    test(
      'a route pinned to another key cannot rename a real relay\'s site',
      () {
        RelayClient.registerBorrowedSite(
          '203.0.113.7',
          443,
          'www.bing.com',
          identity: real,
        );
        // A shared link pinned to someone else's key, for the same address,
        // naming a site the censor watches.
        RelayClient.registerBorrowedSite(
          '203.0.113.7',
          443,
          'blocked.example.org',
          identity: evil,
        );
        final registry = RelayClient.registry;
        expect(registry.siteFor(real, '203.0.113.7', 443), 'www.bing.com');
        expect(
          registry.siteFor(evil, '203.0.113.7', 443),
          'blocked.example.org',
        );
      },
    );

    test('nor redirect its secret path', () {
      RelayClient.registerWssPath(
        'relay.example.org',
        443,
        '/real-path-1',
        identity: real,
      );
      RelayClient.registerWssPath(
        'relay.example.org',
        443,
        '/evil-path-1',
        identity: evil,
      );
      final registry = RelayClient.registry;
      expect(registry.pathFor(real, 'relay.example.org', 443), '/real-path-1');
      expect(registry.pathFor(evil, 'relay.example.org', 443), '/evil-path-1');
      // A third identity has no route there at all.
      expect(registry.pathFor('OTHER', 'relay.example.org', 443), isNull);
    });

    test('the same identity re-announcing replaces its own entry', () {
      RelayClient.registerBorrowedSite(
        '203.0.113.7',
        443,
        'www.bing.com',
        identity: real,
      );
      RelayClient.registerBorrowedSite(
        '203.0.113.7',
        443,
        'www.microsoft.com',
        identity: real,
      );
      expect(
        RelayClient.registry.siteFor(real, '203.0.113.7', 443),
        'www.microsoft.com',
      );
      expect(RelayClient.registry.borrowedSites, hasLength(1));
    });

    test(
      'a route typed without a pin serves a pinned caller at its address',
      () {
        RelayClient.registerWssPath('relay.example.org', 443, '/typed-path-1');
        expect(
          RelayClient.registry.pathFor(real, 'relay.example.org', 443),
          '/typed-path-1',
        );
        // A pinned entry wins over it for that identity.
        RelayClient.registerWssPath(
          'relay.example.org',
          443,
          '/pinned-path-1',
          identity: real,
        );
        expect(
          RelayClient.registry.pathFor(real, 'relay.example.org', 443),
          '/pinned-path-1',
        );
        expect(
          RelayClient.registry.pathFor(evil, 'relay.example.org', 443),
          '/typed-path-1',
        );
      },
    );

    test('the maps stay bounded', () {
      for (var index = 0; index < 100; index++) {
        RelayClient.registerWssPath(
          'relay$index.example.org',
          443,
          '/path-$index',
          identity: real,
        );
        RelayClient.registerBorrowedSite(
          '10.0.0.$index',
          443,
          'site$index.example.org',
          identity: real,
        );
      }
      expect(RelayClient.registry.wssPaths.length, lessThanOrEqualTo(64));
      expect(RelayClient.registry.borrowedSites.length, lessThanOrEqualTo(64));
    });
  });

  group('the registry has an owner', () {
    test('clearing it forgets every map', () async {
      RelayClient.registerWssPath(
        'relay.example.org',
        443,
        '/path-1',
        identity: real,
      );
      RelayClient.registerBorrowedSite(
        '203.0.113.7',
        443,
        'www.bing.com',
        identity: real,
      );
      RelayClient.setRelayTokens({real: 'v1.token'});
      RelayClient.registerMailboxSecret('dev-1', List<int>.filled(32, 1));
      RelayClient.debugRegisterTlsCert(real, 'relay.example.org', [1, 2, 3]);
      final registry = RelayClient.registry;
      await registry.clear();
      expect(registry.wssPaths, isEmpty);
      expect(registry.borrowedSites, isEmpty);
      expect(registry.tokens, isEmpty);
      expect(registry.mailboxSecrets, isEmpty);
      expect(registry.tlsCerts, isEmpty);
      expect(registry.v2Known, isEmpty);
    });

    test('releasing the one in use empties it and puts a fresh one in', () {
      final owned = RelayRegistry();
      RelayClient.useRegistry(owned);
      RelayClient.registerWssPath(
        'relay.example.org',
        443,
        '/path-1',
        identity: real,
      );
      expect(owned.wssPaths, isNotEmpty);
      RelayClient.releaseRegistry(owned);
      expect(owned.wssPaths, isEmpty);
      expect(identical(RelayClient.registry, owned), isFalse);
      expect(RelayClient.registry.wssPaths, isEmpty);
    });

    test('releasing one that is not in use leaves the one in use alone', () {
      final other = RelayRegistry();
      final inUse = RelayRegistry();
      RelayClient.useRegistry(inUse);
      RelayClient.registerWssPath(
        'relay.example.org',
        443,
        '/path-1',
        identity: real,
      );
      RelayClient.releaseRegistry(other);
      expect(identical(RelayClient.registry, inUse), isTrue);
      expect(inUse.wssPaths, isNotEmpty);
    });
  });
}

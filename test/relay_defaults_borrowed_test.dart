import 'dart:convert';

import 'package:conest/src/models.dart';
import 'package:conest/src/relay_defaults.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a default relay list can carry a borrowed address with its site '
      '(M38 S1)', () {
    final list = parseUnsignedRelayList(
      jsonEncode({
        'version': 3,
        'issuedAt': '2026-11-08T00:00:00Z',
        'endpoints': [
          {
            'kind': 'relay',
            'host': '203.0.113.7',
            'port': 443,
            'protocol': 'borrowed',
            'path': 'www.bing.com',
          },
          {
            'kind': 'relay',
            'host': 'relay.example.org',
            'port': 443,
            'protocol': 'wss',
            'path': '/s3cret-path_1',
          },
          // Not a site name, and not a secret path for a borrowed entry.
          {
            'kind': 'relay',
            'host': '203.0.113.8',
            'port': 443,
            'protocol': 'borrowed',
            'path': '/s3cret-path_1',
          },
          {
            'kind': 'relay',
            'host': '203.0.113.9',
            'port': 443,
            'protocol': 'borrowed',
            'path': 'not_a_name',
          },
        ],
      }),
    )!;
    final byHost = {for (final spec in list.endpoints) spec.host: spec};
    expect(byHost['203.0.113.7']!.protocol, PeerRouteProtocol.borrowed);
    expect(byHost['203.0.113.7']!.path, 'www.bing.com');
    expect(byHost['relay.example.org']!.path, '/s3cret-path_1');
    // The bad ones keep no path, so the controller drops them (a hidden
    // address needs its path or name).
    expect(byHost['203.0.113.8']!.path, isNull);
    expect(byHost['203.0.113.9']!.path, isNull);
    expect(
      isValidHiddenRoutePath(
        PeerRouteProtocol.borrowed,
        byHost['203.0.113.8']!.path,
      ),
      isFalse,
    );
  });
}

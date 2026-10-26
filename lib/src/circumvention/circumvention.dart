import 'dart:async';
import 'dart:io';

import 'doh_resolver.dart';
import 'fragmenting_proxy.dart';

/// When a circumvention measure is used. Stored by name: append only.
enum CircumventionPolicy {
  /// When the current network seems to block routes (network history).
  automatic,

  /// On every network.
  always,

  /// Never.
  never,
}

/// The user's choices under Settings → Connectivity → Censorship
/// circumvention (M38).
class CircumventionPreferences {
  const CircumventionPreferences({
    this.privateDns = CircumventionPolicy.automatic,
    this.splitGreeting = CircumventionPolicy.automatic,
    this.quietLan = CircumventionPolicy.automatic,
  });

  /// Names looked up over DNS over HTTPS.
  final CircumventionPolicy privateDns;

  /// TLS ClientHellos sent in pieces that cut through the server name.
  final CircumventionPolicy splitGreeting;

  /// LAN discovery beacons sent only in their sealed form (when not in
  /// use, the old cleartext form goes along for older versions).
  final CircumventionPolicy quietLan;

  bool get isDefault =>
      privateDns == CircumventionPolicy.automatic &&
      splitGreeting == CircumventionPolicy.automatic &&
      quietLan == CircumventionPolicy.automatic;

  CircumventionPreferences copyWith({
    CircumventionPolicy? privateDns,
    CircumventionPolicy? splitGreeting,
    CircumventionPolicy? quietLan,
  }) => CircumventionPreferences(
    privateDns: privateDns ?? this.privateDns,
    splitGreeting: splitGreeting ?? this.splitGreeting,
    quietLan: quietLan ?? this.quietLan,
  );

  Map<String, dynamic> toJson() => {
    'privateDns': privateDns.name,
    'splitGreeting': splitGreeting.name,
    'quietLan': quietLan.name,
  };

  static CircumventionPolicy _policy(Object? value) =>
      CircumventionPolicy.values
          .where((policy) => policy.name == value)
          .firstOrNull ??
      CircumventionPolicy.automatic;

  factory CircumventionPreferences.fromJson(Object? json) {
    if (json is! Map) return const CircumventionPreferences();
    return CircumventionPreferences(
      privateDns: _policy(json['privateDns']),
      splitGreeting: _policy(json['splitGreeting']),
      quietLan: _policy(json['quietLan']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CircumventionPreferences &&
      other.privateDns == privateDns &&
      other.splitGreeting == splitGreeting &&
      other.quietLan == quietLan;

  @override
  int get hashCode => Object.hash(privateDns, splitGreeting, quietLan);
}

/// The app's way out to TLS servers when a network is in the way: one
/// place every connector (relays over HTTPS and wss, email, Nostr, link
/// previews, the Dart Matrix client) dials through. Off (plain connects)
/// unless the preferences say always, or say automatic and the current
/// network seems to block routes; that keeps battery and data as before
/// on networks where everything works.
class Circumvention {
  Circumvention({DohResolver? resolver}) : _doh = resolver ?? DohResolver();

  /// The one the app uses.
  static Circumvention instance = Circumvention();

  final DohResolver _doh;
  FragmentingProxy? _proxy;
  CircumventionPreferences preferences = const CircumventionPreferences();

  /// Whether the current network seems to block routes.
  bool blockedHere = false;

  bool _active(CircumventionPolicy policy) => switch (policy) {
    CircumventionPolicy.always => true,
    CircumventionPolicy.never => false,
    CircumventionPolicy.automatic => blockedHere,
  };

  bool get privateDnsActive => _active(preferences.privateDns);
  bool get splitGreetingActive => _active(preferences.splitGreeting);
  bool get quietLanActive => _active(preferences.quietLan);
  bool get anyActive => privateDnsActive || splitGreetingActive;

  /// Updates what is in use (the controller calls it as preferences and
  /// network history change).
  void update({CircumventionPreferences? preferences, bool? blockedHere}) {
    if (preferences != null) this.preferences = preferences;
    if (blockedHere != null) this.blockedHere = blockedHere;
    final proxy = _proxy;
    if (proxy != null) proxy.fragment = splitGreetingActive;
    if (!anyActive && proxy != null) {
      _proxy = null;
      unawaited(proxy.stop());
    }
  }

  Future<List<InternetAddress>> _resolve(String host) async {
    if (privateDnsActive) return _doh.resolve(host);
    return systemResolve(host);
  }

  FragmentingProxy _proxyNow() => _proxy ??= FragmentingProxy(
    resolve: _resolve,
    fragment: splitGreetingActive,
  );

  /// A TLS connection to [host]:[port] (SNI = [host]).
  Future<SecureSocket> secureConnect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 8),
    List<String>? supportedProtocols,
    bool Function(X509Certificate certificate)? onBadCertificate,
    SecurityContext? context,
  }) async {
    if (!anyActive) {
      return SecureSocket.connect(
        host,
        port,
        timeout: timeout,
        context: context,
        supportedProtocols: supportedProtocols,
        onBadCertificate: onBadCertificate,
      );
    }
    if (!splitGreetingActive) {
      final socket = await connect(host, port, timeout: timeout);
      try {
        return await SecureSocket.secure(
          socket,
          host: host,
          context: context,
          supportedProtocols: supportedProtocols,
          onBadCertificate: onBadCertificate,
        ).timeout(timeout);
      } catch (_) {
        socket.destroy();
        rethrow;
      }
    }
    return _proxyNow().secureConnect(
      host,
      port,
      timeout: timeout,
      context: context,
      supportedProtocols: supportedProtocols,
      onBadCertificate: onBadCertificate,
    );
  }

  /// A plain TCP connection to [host]:[port] (its name looked up over DoH
  /// when that is in use).
  Future<Socket> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!privateDnsActive) {
      return Socket.connect(host, port, timeout: timeout);
    }
    final addresses = await _doh.resolve(host);
    Object? lastError;
    for (final address in addresses.take(3)) {
      try {
        return await Socket.connect(address, port, timeout: timeout);
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? SocketException('No address for $host answered.');
  }

  /// Points [client] (its HTTPS requests) through the circumvention proxy
  /// while circumvention is in use; leaves it alone otherwise.
  Future<void> configure(HttpClient client) async {
    if (!anyActive) {
      client.findProxy = null;
      return;
    }
    final proxy = _proxyNow();
    await proxy.start();
    final directive = proxy.proxyDirective;
    client.findProxy = (uri) =>
        uri.scheme == 'https' || uri.scheme == 'wss' ? directive : 'DIRECT';
  }
}

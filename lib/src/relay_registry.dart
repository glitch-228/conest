part of 'relay_client.dart';

/// What the relay client has learned and been told about relays (M38 S0):
/// what each relay said about sessions, the secret paths and site names of
/// hidden routes, certificate hashes, tokens, mailbox keys, UDP cookies and
/// the open sessions.
///
/// It used to be static state with no owner: it survived a vault reset (the
/// secret paths of the old identity's relays stayed in memory), and a route
/// registered for an address replaced whatever any other route had there.
/// Now the controller owns one, empties it on a vault reset and when it goes
/// (see [RelayClient.useRegistry] and [RelayClient.releaseRegistry]), and
/// the hidden-route maps are keyed by the identity a route is pinned to as
/// well as its address, so a link pinned to another key cannot redirect or
/// rename a real relay's route.
class RelayRegistry {
  RelayRegistry();

  /// What each relay (by host and port) said in its health answers.
  final Map<String, RelayV2Info> v2Known = {};
  final Set<String> v2Learning = {};

  /// The secret each of this app's mailboxes derives its owner keys from.
  final Map<String, List<int>> mailboxSecrets = {};
  final Map<String, SimpleKeyPair> authKeys = {};

  /// Registration tokens, by relay identity.
  final Map<String, String> tokens = {};

  /// Cookies UDP relays gave, by host:port.
  final Map<String, String> udpCookies = {};

  /// TLS certificate hashes relays' identities signed, by identity|host.
  final Map<String, List<int>> tlsCerts = {};

  /// Hidden routes: secret paths and borrowed site names, by
  /// [hiddenKey].
  final Map<String, String> wssPaths = {};
  final Map<String, String> borrowedSites = {};

  /// The open relay sessions (pooled by relay and key).
  RelayV2Pool v2Pool = RelayV2Pool();

  /// The key a hidden route's path or site name is kept under: the identity
  /// it is pinned to (none: empty) and its address.
  static String hiddenKey(String? identity, String host, int port) =>
      '${identity ?? ''}|$host:$port';

  /// The secret path registered for [host]:[port] pinned to [identity], or
  /// the one registered with no identity (a route typed by the user, never
  /// one from a link, which is always pinned). Null: none.
  String? pathFor(String? identity, String host, int port) =>
      wssPaths[hiddenKey(identity, host, port)] ??
      wssPaths[hiddenKey(null, host, port)];

  /// The site name registered for a borrowed route, as [pathFor].
  String? siteFor(String? identity, String host, int port) =>
      borrowedSites[hiddenKey(identity, host, port)] ??
      borrowedSites[hiddenKey(null, host, port)];

  /// Forgets everything and closes the sessions.
  Future<void> clear() async {
    v2Known.clear();
    v2Learning.clear();
    mailboxSecrets.clear();
    authKeys.clear();
    tokens.clear();
    udpCookies.clear();
    tlsCerts.clear();
    wssPaths.clear();
    borrowedSites.clear();
    await v2Pool.closeAll();
  }
}

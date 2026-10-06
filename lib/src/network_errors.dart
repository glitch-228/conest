import 'dart:async';
import 'dart:io';

/// Socket errors that come and go with the network (a dropped or reset
/// connection, a failed name lookup, no route), by Linux, Android and
/// Windows error number.
const Set<int> _transientErrnos = {
  // Linux and Android.
  7, 32, 101, 103, 104, 110, 113,
  // Windows.
  10050, 10051, 10053, 10054, 10060, 10065, 11001, 11002, 11004,
};

/// Whether retrying [error] soon may work: the network dropped or changed,
/// rather than the server refusing.
bool isTransientNetworkError(Object error) {
  if (error is TimeoutException) return true;
  if (error is SocketException) {
    final code = error.osError?.errorCode;
    if (code != null && _transientErrnos.contains(code)) return true;
    final text = error.message.toLowerCase();
    return text.contains('failed host lookup') ||
        text.contains('connection reset') ||
        text.contains('connection abort') ||
        text.contains('connection closed');
  }
  return false;
}

/// [error] in words someone can act on, for status lines in settings.
/// Anything not recognised is shown as it is.
String describeNetworkError(Object error) {
  if (error is TimeoutException) {
    return 'Timed out: the server or the network is slow or unreachable.';
  }
  if (error is SocketException) {
    final host = error.address?.host;
    final where = host == null || host.isEmpty ? 'the server' : host;
    final code = error.osError?.errorCode;
    final text = '${error.message} ${error.osError?.message ?? ''}'
        .toLowerCase();
    if (text.contains('failed host lookup') ||
        code == 7 ||
        code == 11001 ||
        code == 11002 ||
        code == 11004) {
      final name = RegExp(r"lookup: '([^']+)'").firstMatch(error.message);
      return 'Cannot look up ${name?.group(1) ?? where}: no internet '
          'connection, or the name does not exist.';
    }
    if (text.contains('refused') || code == 111 || code == 10061) {
      return '$where refused the connection.';
    }
    if (code == 101 || code == 113 || code == 10051 || code == 10065) {
      return 'No route to $where: the device seems offline.';
    }
    if (text.contains('abort') ||
        text.contains('reset') ||
        text.contains('closed') ||
        code == 32 ||
        code == 103 ||
        code == 104 ||
        code == 10053 ||
        code == 10054) {
      return 'The connection to $where dropped, often because the network '
          'changed or a VPN or firewall cut it.';
    }
    if (text.contains('timed out') || code == 110 || code == 10060) {
      return 'Timed out reaching $where.';
    }
  }
  if (error is HandshakeException) {
    return 'The secure connection failed: ${error.osError?.message ?? error.message}';
  }
  return '$error';
}

/// The message of an error from a settings action: what was wrong with
/// the input, what is not possible now, or what the network did.
String describeActionError(Object error) => switch (error) {
  ArgumentError(:final message) => '$message',
  StateError(:final message) => message,
  _ => describeNetworkError(error),
};

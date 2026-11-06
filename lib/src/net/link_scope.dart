import 'dart:io';

/// Whether [host] only means something on one link: a link-local address
/// (169.254/16, fe80::/10) or anything with a zone (`%`). Such a host never
/// goes into the vault, an invite or a message to a contact.
bool isLinkScopedHost(String host) {
  final value = host.trim();
  if (value.contains('%')) return true;
  final address = InternetAddress.tryParse(value);
  return address != null && address.isLinkLocal;
}

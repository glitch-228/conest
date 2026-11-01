/// Bounded protocol replies, kept in the encrypted account vault until SMTP
/// accepts them. Chat messages use their existing failed-message retry flow.
library;

import 'carrier_mail.dart' show isPlausibleMailAddress;

class DeltaControlMail {
  const DeltaControlMail(this.id, this.to, this.mail);

  final String id;
  final List<String> to;
  final String mail;

  static const maxCount = 64;
  static const maxMailChars = 1024 * 1024;
  static const maxTotalChars = 8 * 1024 * 1024;

  Map<String, dynamic> toJson() => {'id': id, 'to': to, 'mail': mail};

  static List<DeltaControlMail> restore(Object? value) {
    if (value is! List) return const [];
    final result = <DeltaControlMail>[];
    final ids = <String>{};
    var total = 0;
    for (final row in value.take(maxCount)) {
      if (row is! Map) continue;
      final id = row['id'], to = row['to'], mail = row['mail'];
      if (id is! String ||
          id.isEmpty ||
          id.length > 128 ||
          to is! List ||
          to.isEmpty ||
          to.length > 64 ||
          to.any(
            (v) => v is! String || v.length > 320 || !isPlausibleMailAddress(v),
          ) ||
          mail is! String ||
          mail.isEmpty ||
          mail.length > maxMailChars ||
          mail.length > maxTotalChars - total ||
          !ids.add(id)) {
        continue;
      }
      total += mail.length;
      result.add(DeltaControlMail(id, List<String>.from(to), mail));
    }
    return result;
  }

  static List<DeltaControlMail> append(
    List<DeltaControlMail> pending,
    Iterable<DeltaControlMail> added,
  ) {
    final next = [...pending];
    var total = next.fold<int>(0, (sum, m) => sum + m.mail.length);
    for (final mail in added) {
      if (next.length >= maxCount ||
          mail.mail.length > maxMailChars ||
          mail.mail.length > maxTotalChars - total) {
        throw StateError('Delta Chat replies are waiting for email.');
      }
      next.add(mail);
      total += mail.mail.length;
    }
    return next;
  }
}

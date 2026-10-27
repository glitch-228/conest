import 'package:conest/src/notification_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quiet hours across midnight count from the day they start', () {
    // Weeknights only: Monday (1) to Friday (5), 22:00 to 07:00.
    const quiet = QuietHours(enabled: true, days: {1, 2, 3, 4, 5});
    final monday = DateTime(2026, 10, 26); // a Monday
    expect(quiet.quietAt(monday.add(const Duration(hours: 23))), isTrue);
    expect(quiet.quietAt(monday.add(const Duration(hours: 21))), isFalse);
    // Tuesday 06:00 is Monday night's.
    expect(quiet.quietAt(DateTime(2026, 10, 27, 6)), isTrue);
    expect(quiet.quietAt(DateTime(2026, 10, 27, 7)), isFalse);
    // Saturday 23:00 is not a weeknight; Saturday 06:00 is Friday night's.
    expect(quiet.quietAt(DateTime(2026, 10, 31, 23)), isFalse);
    expect(quiet.quietAt(DateTime(2026, 10, 31, 6)), isTrue);
    expect(quiet.quietAt(DateTime(2026, 11, 1, 6)), isFalse);
    // A daytime window, and off.
    final day = quiet.copyWith(startMinute: 9 * 60, endMinute: 17 * 60);
    expect(day.quietAt(DateTime(2026, 10, 26, 12)), isTrue);
    expect(day.quietAt(DateTime(2026, 10, 26, 18)), isFalse);
    expect(
      quiet.copyWith(enabled: false).quietAt(DateTime(2026, 10, 26, 23)),
      isFalse,
    );
  });

  test('quiet hours round-trip and refuse nonsense', () {
    final quiet = const QuietHours().copyWith(
      enabled: true,
      startMinute: 60,
      endMinute: 120,
      days: {6, 7},
      callsRing: false,
    );
    final again = QuietHours.fromJson(quiet.toJson());
    expect(again.enabled, isTrue);
    expect(again.startMinute, 60);
    expect(again.endMinute, 120);
    expect(again.days, {6, 7});
    expect(again.callsRing, isFalse);
    final wild = QuietHours.fromJson({
      'enabled': true,
      'startMinute': 99999,
      'days': [0, 3, 9],
    });
    expect(wild.startMinute, 22 * 60);
    expect(wild.days, {3});
    expect(QuietHours.fromJson('x').enabled, isFalse);
  });

  test('a mention is @ and the name, or a reply to you', () {
    bool m(String body, {bool reply = false, String name = 'Alice'}) =>
        mentionsMe(body: body, myName: name, replyToMe: reply);
    expect(m('hi @Alice'), isTrue);
    expect(m('@alice, look'), isTrue);
    expect(m('@Alicea is someone else'), isFalse);
    expect(m('Alice without the at'), isFalse);
    expect(m('nothing', reply: true), isTrue);
    expect(m('@Анна привет', name: 'Анна'), isTrue);
    expect(m('@Аннабель', name: 'Анна'), isFalse);
    expect(m('@Mary Jane here', name: 'Mary Jane'), isTrue);
    expect(m('@ ', name: ' '), isFalse);
  });
}

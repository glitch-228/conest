import 'package:conest/src/email/delta_outbox.dart';
import 'package:conest/src/email/smtp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Delta permanent rejection classification preserves auth and temporary errors',
    () {
      expect(
        const SmtpException(550, 'AUTH required').permanentRecipientFailure,
        isFalse,
      );
      expect(
        const SmtpException(
          450,
          'later',
          recipient: 'one@example.org',
        ).permanentRecipientFailure,
        isFalse,
      );
      expect(
        const SmtpException(
          552,
          'full',
          recipient: 'one@example.org',
        ).permanentRecipientFailure,
        isFalse,
      );
      expect(
        const SmtpException(
          550,
          'gone',
          recipient: 'one@example.org',
        ).permanentRecipientFailure,
        isTrue,
      );
    },
  );
  const mail = DeltaControlMail('id', ['one@example.org'], 'body');
  test('Delta outbox restores only bounded valid protocol mail', () {
    expect(
      DeltaControlMail.restore([
        mail.toJson(),
        mail.toJson(),
        {
          'id': 'bad',
          'to': ['bad\r\naddress'],
          'mail': 'body',
        },
        {
          'id': 'big',
          'to': ['one@example.org'],
          'mail': 'x' * (DeltaControlMail.maxMailChars + 1),
        },
      ]).map((m) => m.id),
      ['id'],
    );
    expect(
      DeltaControlMail.restore([
        for (var i = 0; i < 100; i++)
          DeltaControlMail('$i', mail.to, mail.mail).toJson(),
      ]),
      hasLength(DeltaControlMail.maxCount),
    );
  });
  test('Delta outbox refuses overflow without evicting pending replies', () {
    final pending = [
      for (var i = 0; i < DeltaControlMail.maxCount; i++)
        DeltaControlMail('$i', mail.to, mail.mail),
    ];
    expect(() => DeltaControlMail.append(pending, [mail]), throwsStateError);
    expect(pending, hasLength(DeltaControlMail.maxCount));
    final large = DeltaControlMail(
      'big',
      mail.to,
      'x' * DeltaControlMail.maxMailChars,
    );
    expect(
      () => DeltaControlMail.append(List.filled(8, large), [mail]),
      throwsStateError,
    );
    expect(
      () => DeltaControlMail.append([], [
        DeltaControlMail('big', mail.to, '${large.mail}x'),
      ]),
      throwsStateError,
    );
    expect(
      DeltaControlMail.restore([
        for (var i = 0; i < 12; i++)
          DeltaControlMail('$i', large.to, large.mail).toJson(),
      ]),
      hasLength(8),
    );
  });
}

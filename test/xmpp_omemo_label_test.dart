import 'package:conest/l10n/app_localizations.dart';
import 'package:conest/src/ui/xmpp_omemo_screens.dart';
import 'package:conest/src/xmpp/xmpp_chats.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// OMEMO 2 chats say "encrypted, unverified" unless every device of the
/// contact is verified.
void main() {
  XmppChat chatWith(XmppSecurity security) => XmppChat(
    jid: 'bob@example.org',
    messages: [
      XmppChatMessage(
        id: '1',
        from: 'bob@example.org',
        text: 'hi',
        at: DateTime.utc(2026),
        outgoing: false,
        security: security,
      ),
    ],
  );

  Future<String> label(
    WidgetTester tester,
    XmppChat chat, {
    required bool verified,
  }) async {
    late String result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            result = xmppEncryptionLabel(context, chat, verified: verified);
            return const SizedBox();
          },
        ),
      ),
    );
    return result;
  }

  testWidgets('unverified OMEMO 2 is labelled as such', (tester) async {
    final chat = chatWith(XmppSecurity.omemo2);
    final unverified = await label(tester, chat, verified: false);
    expect(unverified, contains('unverified'));
    final verified = await label(tester, chat, verified: true);
    expect(verified, isNot(contains('unverified')));
    expect(verified, contains('verified'));
    expect(xmppShowsLock(chat), isTrue);
  });

  testWidgets('legacy OMEMO is never called encrypted', (tester) async {
    final text = await label(
      tester,
      chatWith(XmppSecurity.legacyOmemo),
      verified: true,
    );
    expect(text, isNot(contains('encrypted')));
  });

  testWidgets('the edit-not-applied note comes beside the label', (
    tester,
  ) async {
    late String legacy;
    late String plain;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            XmppChatMessage message(XmppSecurity security) => XmppChatMessage(
              id: '1',
              from: 'bob@example.org',
              text: 'hi',
              at: DateTime.utc(2026),
              outgoing: false,
              security: security,
              securityNote: xmppEditNotAppliedNote,
            );
            legacy = xmppSecurityNote(
              context,
              message(XmppSecurity.legacyOmemo),
            )!;
            plain = xmppSecurityNote(context, message(XmppSecurity.plain))!;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(legacy, contains('legacy OMEMO'));
    expect(legacy, contains('not applied'));
    expect(plain, contains('not applied'));
    expect(plain, isNot(contains('legacy')));
  });
}

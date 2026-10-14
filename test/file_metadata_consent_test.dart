import 'package:conest/src/feature_models.dart';
import 'package:conest/src/ui/file_metadata_consent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final partial in [false, true]) {
    testWidgets(
      'file metadata dialog uses ${partial ? 'partial' : 'failed'} wording',
      (tester) async {
        bool? accepted;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  accepted = await showFileMetadataConsent(
                    context,
                    'photo.pdf',
                    partial: partial,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            partial
                ? 'Some details may remain in photo.pdf. Send it anyway?'
                : 'The location, camera, author and date details of photo.pdf '
                      'could not be removed. Send it with them?',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(accepted, isFalse);
      },
    );
  }
  test(
    'scheduled privacy flag is optional and survives round trips and editing',
    () {
      final old = ScheduledMessage.fromJson({
        'id': '1',
        'conversationId': 'peer',
        'conversationKind': 'direct',
        'body': '',
        'attachmentPath': 'scheduled/1.bin',
      });
      expect(old.attachmentPrivacyPrepared, isFalse);
      final prepared = ScheduledMessage.fromJson({
        ...old.toJson(),
        'attachmentPrivacyPrepared': true,
      });
      expect(
        prepared.copyWith(body: 'New caption').attachmentPrivacyPrepared,
        isTrue,
      );
      expect(
        ScheduledMessage.fromJson(prepared.toJson()).attachmentPrivacyPrepared,
        isTrue,
      );
    },
  );
}

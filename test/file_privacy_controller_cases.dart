import 'dart:io';

import 'package:conest/src/feature_models.dart';
import 'package:conest/src/messenger_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/file_privacy_fixtures.dart';

void registerFilePrivacyControllerTests({
  required Future<(MessengerController, MessengerController, Directory)> Function() pair,
  required Future<(String, List<int>)> Function(MessengerController,
      MessengerController, int) received,
}) {
  StagedAttachment source(File file, String name, int length) => StagedAttachment(
      id: 'q4b-source', fileName: name, mimeType: 'application/octet-stream',
      sizeBytes: length, filePath: file.path);

  test('partial file cleaning requires consent for direct and group sends', () async {
    final (alice, _, root) = await pair();
    final bytes = partialPdf();
    final file = await File('${root.path}/partial.pdf').writeAsBytes(bytes);
    await expectLater(alice.sendAttachmentSource(
      contact: alice.contacts.single,
      source: source(file, 'partial.pdf', bytes.length),
    ), throwsA(isA<AttachmentSpoolException>()
        .having((error) => error.keepsMetadata, 'requires consent', true)
        .having((error) => error.partialMetadata, 'partial wording', true)
        .having((error) => error.message, 'message',
            'Some details may remain in partial.pdf. Send it anyway?')));
    expect(alice.messagesFor(alice.contacts.single.deviceId)
        .where((message) => message.attachment != null), isEmpty);
    final group = await alice.createGroup(title: 'Partial', members: [alice.contacts.single]);
    await expectLater(alice.publishGroupFile(
      groupId: group.groupId, path: file.path, fileName: 'partial.pdf',
      mimeType: 'application/pdf',
    ), throwsA(isA<FileMetadataException>()
        .having((error) => error.partial, 'partial wording', true)
        .having((error) => error.toString(), 'message',
            'Some details may remain in partial.pdf. Send it anyway?')));
    expect(alice.messagesForGroup(group.groupId)
        .where((message) => message.groupFile != null), isEmpty);
  });

  test('scheduled cleaning failure asks now and the timer never asks again', () async {
    final (alice, bob, root) = await pair();
    final bytes = [255, 216, 255, 225, 0, 64, 71, 80, 83];
    final file = await File('${root.path}/broken.jpg').writeAsBytes(bytes);
    final attachment = source(file, 'broken.jpg', bytes.length);
    final later = DateTime.now().toUtc().add(const Duration(hours: 1));
    await expectLater(alice.scheduleAttachment(contact: alice.contacts.single,
      source: attachment, scheduledAt: later,
    ), throwsA(isA<FileMetadataException>().having((e) => e.partial, 'failed', false)));
    expect(alice.scheduledMessages, isEmpty);
    await expectLater(alice.scheduleAttachment(contact: alice.contacts.single,
      source: attachment, scheduledAt: later,
      confirmKeepingMetadata: (_) async => false,
    ), throwsA(isA<FileMetadataException>()));
    expect(await Directory('${root.path}/scheduled').list().toList(), isEmpty);
    var prompts = 0;
    final scheduled = await alice.scheduleAttachment(contact: alice.contacts.single,
      source: attachment,
      scheduledAt: DateTime.now().toUtc().add(const Duration(milliseconds: 250)),
      confirmKeepingMetadata: (error) async {
        prompts++;
        expect(error.fileName, 'broken.jpg');
        expect(alice.scheduledMessages, isEmpty, reason: 'ask before confirmation');
        // Model an incomplete I/O rewrite reported as failed. Consent must
        // queue the intact original, rather than this damaged candidate.
        final candidate = (await Directory('${root.path}/scheduled').list().toList()).single as File;
        await candidate.writeAsBytes(List.filled(bytes.length, 0));
        return true;
      },
    );
    expect(prompts, 1);
    expect(scheduled.attachmentPrivacyPrepared, isTrue);
    await file.delete();
    // The timer consumes the private copy; no UI callback survives into it.
    final (_, sent) = await received(alice, bob, 1);
    expect(sent, bytes);
    expect(alice.scheduledMessages.single.state, ScheduledMessageState.sent);
    expect(prompts, 1);
  });

  test('scheduled direct photos are cleaned and named before settings change', () async {
    final (alice, bob, root) = await pair();
    final bytes = privacyJpeg();
    final file = await File('${root.path}/holiday.jpg').writeAsBytes(bytes);
    await alice.setRandomizesFileNames(true);
    final scheduled = await alice.scheduleAttachment(contact: alice.contacts.single,
      source: source(file, 'holiday.jpg', bytes.length),
      scheduledAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    final prepared = File('${root.path}/${scheduled.attachmentPath}');
    final cleaned = await prepared.readAsBytes();
    expect(cleaned.length, lessThan(bytes.length));
    expect(scheduled.attachmentSizeBytes, cleaned.length);
    expect(scheduled.attachmentFileName, matches(RegExp(r'^[a-z2-7]{16}\.jpg$')));
    expect(String.fromCharCodes(cleaned), isNot(contains('GPSLatitude')));
    expect(await file.readAsBytes(), bytes);
    await alice.setRemovesFileMetadata(false);
    await alice.setRandomizesFileNames(false);
    await file.delete();
    await alice.sendScheduledMessageNow(scheduled.id);
    final (name, sent) = await received(alice, bob, 1);
    expect(name, scheduled.attachmentFileName);
    expect(sent, cleaned);
    expect(alice.scheduledMessages.single.state, ScheduledMessageState.sent);
  });

  test('scheduled group files clean at scheduling and retain the chosen random name', () async {
    final (alice, _, root) = await pair();
    final group = await alice.createGroup(title: 'Scheduled', members: [alice.contacts.single]);
    final bytes = privacyJpeg();
    final file = await File('${root.path}/group.jpg').writeAsBytes(bytes);
    await alice.setRandomizesFileNames(true);
    final scheduled = await alice.scheduleGroupAttachment(groupId: group.groupId,
      source: source(file, 'group.jpg', bytes.length),
      scheduledAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    final cleaned = await File('${root.path}/${scheduled.attachmentPath}').readAsBytes();
    expect(String.fromCharCodes(cleaned), isNot(contains('GPSLatitude')));
    expect(scheduled.attachmentSizeBytes, cleaned.length);
    await alice.setRemovesFileMetadata(false);
    await alice.setRandomizesFileNames(false);
    await file.delete();
    await alice.sendScheduledMessageNow(scheduled.id);
    final entry = alice.scheduledMessages.single;
    expect(entry.state, ScheduledMessageState.sent, reason: entry.failureReason);
    final message = alice.messagesForGroup(group.groupId)
        .singleWhere((message) => message.groupFile != null);
    expect(message.groupFile!.fileName, scheduled.attachmentFileName);
    expect(await File(alice.groupFilePathFor(message.id)!).readAsBytes(), cleaned);
  });

  test('scheduled partial group files ask once before their private copy is stored', () async {
    final (alice, _, root) = await pair();
    final group = await alice.createGroup(title: 'Partial schedule', members: [alice.contacts.single]);
    final bytes = partialPdf();
    final file = await File('${root.path}/partial.pdf').writeAsBytes(bytes);
    var prompts = 0;
    final scheduled = await alice.scheduleGroupAttachment(groupId: group.groupId,
      source: source(file, 'partial.pdf', bytes.length),
      scheduledAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      confirmKeepingMetadata: (error) async {
        prompts++;
        expect(error.partial, isTrue);
        expect(error.toString(), 'Some details may remain in partial.pdf. Send it anyway?');
        return true;
      },
    );
    expect(prompts, 1);
    await alice.sendScheduledMessageNow(scheduled.id);
    expect(alice.scheduledMessages.single.state, ScheduledMessageState.sent);
    expect(prompts, 1);
  });
  test('scheduled Saved messages retain metadata and the original name', () async {
    final (alice, _, root) = await pair();
    await alice.setRandomizesFileNames(true);
    final bytes = privacyJpeg();
    final file = await File('${root.path}/saved.jpg').writeAsBytes(bytes);
    final saved = alice.savedMessagesContact!;
    final scheduled = await alice.scheduleAttachment(contact: saved,
      source: source(file, 'saved.jpg', bytes.length),
      scheduledAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    expect(scheduled.attachmentFileName, 'saved.jpg');
    expect(await File('${root.path}/${scheduled.attachmentPath}').readAsBytes(), bytes);
    await alice.sendScheduledMessageNow(scheduled.id);
    expect(alice.scheduledMessages.single.state, ScheduledMessageState.sent);
    final message = alice.messagesFor(saved.deviceId).singleWhere((m) => m.attachment != null);
    expect(message.attachment!.fileName, 'saved.jpg');
    expect(await File((await alice.attachmentCachePathFor(message.attachment!.id))!).readAsBytes(), bytes);
  });

}

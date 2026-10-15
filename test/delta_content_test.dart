// Exact wire fixtures reference chatmail/core main
// d766641ce27eb5ff52baa72bd5f87d0baf378a18, mimefactory.rs,
// receive_imf.rs, reaction.rs and download/post_msg_metadata.rs.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' show getCrc32;
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/delta_chats.dart';
import 'package:conest/src/delta_protocol.dart';
import 'package:conest/src/email/delta_content.dart';
import 'package:conest/src/email/delta_mail.dart';
import 'package:conest/src/email/mime.dart';
import 'package:conest/src/email/openpgp.dart';
import 'package:conest/src/email/pgp.dart';
import 'package:conest/src/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  final clock = DateTime.utc(2026, 10, 14, 9);
  late PgpSecretKey alice, bob, carol, outsider;
  late DeltaProtocol receiver, sender;
  late DeltaChats chats;
  late List<DeltaFile> saved;
  late bool diskFails;
  var receivedAt = clock;
  String fp(PgpSecretKey k) => k.publicKey.fingerprintHex;
  String addr(PgpSecretKey k) => identical(k, alice)
      ? 'alice@example.org'
      : identical(k, bob)
      ? 'bob@example.org'
      : identical(k, carol)
      ? 'carol@example.org'
      : 'outsider@example.org';
  final photo = Uint8List.fromList(
    img.encodePng(img.Image(width: 2, height: 2)),
  );
  AttachmentDescriptor descriptor(DeltaFile f, {String id = 'local-file'}) =>
      AttachmentDescriptor(
        id: id,
        fileName: f.name,
        mimeType: f.mimeType,
        sizeBytes: f.bytes.length,
        chunkSize: 65536,
        chunkHashes: const [],
        encryptionKeyBase64: '',
        createdAt: clock,
        voiceMetadata: f.voice
            ? VoiceMessageMetadata(durationMs: f.durationMs)
            : null,
      );
  DeltaChat direct() => DeltaChat(
    key: fp(alice),
    members: [fp(alice)],
    kept: true,
    messages: [
      DeltaChatMessage(
        id: 'original@example.org',
        author: fp(alice),
        text: 'Original',
        at: clock,
      ),
    ],
  );
  const groupKey = 'g:test-group';
  DeltaChat group() => DeltaChat(
    key: groupKey,
    groupId: 'test-group',
    name: 'Team',
    members: [fp(alice), fp(carol)],
    kept: true,
    membersAt: clock,
    memberAdded: {fp(alice): clock, fp(bob): clock, fp(carol): clock},
    messages: direct().messages,
  );

  String filePart(
    Uint8List data, {
    String name = 'p.png',
    String mime = 'image/png',
  }) =>
      'Content-Type: $mime\r\nContent-Disposition: attachment; filename="$name"\r\n'
      'Content-Transfer-Encoding: base64\r\n\r\n${base64Lines(data)}';

  Future<Uint8List> coreMail({
    PgpSecretKey? author,
    String? from,
    String id = 'control@example.org',
    String text = '',
    List<(String, String)> headers = const [],
    List<String> parts = const [],
    bool reaction = false,
    bool receipt = false,
    bool grouped = false,
    String outer = '',
    DateTime? date,
  }) async {
    final key = author ?? alice;
    final inner = [
      'Content-Type: multipart/${receipt ? 'report; report-type=disposition-notification' : 'mixed'}; boundary="core"; protected-headers="v1"',
      'From: <${from ?? addr(key)}>',
      'To: <${addr(bob)}>',
      'Date: ${rfc5322Date(date ?? clock)}',
      'Message-ID: <$id>',
      'Chat-Version: 1.0',
      foldedHeader(
        'Autocrypt',
        AutocryptHeader(
          addr: from ?? addr(key),
          keydata: key.publicKey.bytes,
        ).encode(),
      ),
      if (grouped) 'Chat-Group-ID: test-group',
      for (final h in headers) foldedHeader(h.$1, h.$2),
      '',
      '--core',
      'Content-Type: text/plain; charset=utf-8',
      if (reaction) 'Content-Disposition: reaction',
      'Content-Transfer-Encoding: base64',
      '',
      base64Lines(utf8.encode(text)),
      for (final part in parts) ...['--core', part],
      '--core--',
      '',
    ].join('\r\n');
    final encrypted = await Pgp.encrypt(
      Uint8List.fromList(utf8.encode(inner)),
      [bob.publicKey],
      signer: key,
      now: clock,
    );
    return Uint8List.fromList(
      utf8.encode(
        'From: <${from ?? addr(key)}>\r\n$outer'
        'Content-Type: multipart/encrypted; boundary="outer"; protocol="application/pgp-encrypted"\r\n\r\n'
        '--outer\r\nContent-Type: application/pgp-encrypted\r\n\r\nVersion: 1\r\n'
        '--outer\r\nContent-Type: application/octet-stream\r\n\r\n'
        '${OpenPgpArmor.encode(encrypted)}\r\n--outer--\r\n',
      ),
    );
  }

  Future<DeltaStep> receive(Uint8List mail) async {
    final step = await receiver.receive(chats, mail);
    chats = step.chats;
    return step;
  }

  setUpAll(() async {
    alice = await PgpSecretKey.generate('<alice@example.org>', created: clock);
    bob = await PgpSecretKey.generate('<bob@example.org>', created: clock);
    carol = await PgpSecretKey.generate('<carol@example.org>', created: clock);
    outsider = await PgpSecretKey.generate(
      '<outsider@example.org>',
      created: clock,
    );
  });
  setUp(() {
    saved = [];
    diskFails = false;
    receivedAt = clock;
    receiver = DeltaProtocol(
      key: bob,
      self: addr(bob),
      tokens: DeltaTokens.create(Random(1)),
      now: () => receivedAt,
      saveFile: (f, chat, id, index) async {
        if (diskFails) throw StateError('disk full');
        saved.add(f);
        return descriptor(f, id: '$id/$index');
      },
    );
    sender = DeltaProtocol(
      key: alice,
      self: addr(alice),
      tokens: DeltaTokens.create(Random(2)),
      now: () => clock,
    );
    chats = DeltaChats(
      chats: {fp(alice): direct(), groupKey: group()},
      peers: {
        for (final k in [alice, carol])
          fp(k): DeltaPeer(
            fingerprint: fp(k),
            addr: addr(k),
            key: k.publicKey.bytes,
          ),
      },
    );
  });

  for (final grouped in [false, true]) {
    final kind = grouped ? 'group' : 'direct';
    String chatKey() => grouped ? groupKey : fp(alice);
    test(
      '$kind mixed control or system files stay unconsumed without changing state',
      () async {
        for (final header in [
          'reaction',
          'Chat-Edit',
          'Chat-Delete',
          'Chat-Post-Message-ID',
          'Secure-Join',
          'Chat-Group-Member-Added',
          'Chat-Group-Member-Removed',
        ]) {
          final before = jsonEncode(chats.toJson());
          final step = await receive(
            await coreMail(
              grouped: grouped,
              reaction: header == 'reaction',
              text: header == 'reaction' ? '👍' : 'control',
              headers: [
                if (header == 'reaction')
                  ('In-Reply-To', '<original@example.org>')
                else
                  (
                    header,
                    header == 'Secure-Join'
                        ? 'vc-contact-confirm'
                        : '<original@example.org>',
                  ),
              ],
              parts: [filePart(photo)],
            ),
          );
          expect(step.consumed, isFalse, reason: header);
          expect(
            step.retry,
            isFalse,
            reason: 'unsupported shape must not stall the inbox',
          );
          expect(jsonEncode(chats.toJson()), before);
          expect(saved, isEmpty);
        }
        final mail = await coreMail(
          grouped: grouped,
          receipt: true,
          parts: [
            'Content-Type: message/disposition-notification\r\n\r\nOriginal-Message-ID: <original@example.org>\r\nDisposition: manual-action/MDN-sent-manually; displayed\r\n',
            filePart(photo),
          ],
        );
        final read = (await DeltaMail.read(mail, bob, now: clock))!;
        expect(read.receiptsFor, ['original@example.org']);
        expect(read.files, hasLength(1));
        expect((await receive(mail)).consumed, isFalse);
        expect(saved, isEmpty);
      },
    );
    test('$kind oversized flowed edits leave the original intact', () async {
      final before = chats.chats[chatKey()]!.messages.single;
      final step = await receive(
        await coreMail(
          grouped: grouped,
          headers: [('Chat-Edit', '<original@example.org>')],
          parts: [
            'Content-Type: text/plain; format=flowed; delsp=yes\r\n'
                'Content-Transfer-Encoding: base64\r\n\r\n'
                '${base64Lines(utf8.encode('x' * (DeltaProtocol.maxTextChars * 4 + 1)))}',
          ],
        ),
      );
      expect(step.consumed, isTrue);
      final after = chats.chats[chatKey()]!.messages.single;
      expect(after.text, before.text);
      expect(after.editedAt, isNull);
    });
    test('$kind exact file mail saves bytes and uses actual MIME', () async {
      final step = await receive(
        await coreMail(
          grouped: grouped,
          text: 'caption',
          parts: [
            filePart(photo, mime: 'text/html', name: '../../p\u0001.png'),
          ],
        ),
      );
      expect(step.consumed, isTrue);
      expect(saved.single.bytes, photo);
      final file = chats.chats[chatKey()]!.messages.last.attachments.single;
      expect(file.mimeType, 'image/png');
      expect(file.fileName, isNot(contains('/')));
      expect(file.fileName, isNot(contains('\u0001')));
    });
    test(
      '$kind failed cache write leaves mail and chat message untouched',
      () async {
        diskFails = true;
        final before = chats.chats[chatKey()]!.messages.length;
        final step = await receive(
          await coreMail(grouped: grouped, parts: [filePart(photo)]),
        );
        expect(step.consumed, isFalse);
        expect(chats.chats[chatKey()]!.messages, hasLength(before));
      },
    );
    test(
      '$kind exact voice headers use milliseconds and playable audio bytes',
      () async {
        await receive(
          await coreMail(
            grouped: grouped,
            headers: [('Chat-Voice-Message', '1'), ('Chat-Duration', '152310')],
            parts: [
              filePart(
                Uint8List.fromList(ascii.encode('OggSfake')),
                name: 'voice.ogg',
                mime: 'audio/ogg',
              ),
            ],
          ),
        );
        final f = chats.chats[chatKey()]!.messages.last.attachments.single;
        expect(f.voiceMetadata!.durationMs, 152310);
        expect(f.mimeType, 'audio/ogg');
      },
    );
    test(
      '$kind add replace retract reaction without adding messages',
      () async {
        final before = chats.chats[chatKey()]!.messages.length;
        for (final emoji in ['👍', '❤️', '']) {
          await receive(
            await coreMail(
              grouped: grouped,
              reaction: true,
              text: emoji,
              headers: [('In-Reply-To', '<original@example.org>')],
            ),
          );
          expect(
            chats.chats[chatKey()]!.messages.first.reactions[fp(alice)],
            emoji,
          );
          expect(chats.chats[chatKey()]!.messages, hasLength(before));
        }
      },
    );
    test("$kind author's quoted core edit and delete apply in place", () async {
      await receive(
        await coreMail(
          grouped: grouped,
          text: '> Original\n\n✏️Edited',
          headers: [('Chat-Edit', '<original@example.org>')],
        ),
      );
      final edited = chats.chats[chatKey()]!.messages.first;
      expect(edited.text, 'Edited');
      expect(edited.editedAt, clock);
      await receive(
        await coreMail(
          grouped: grouped,
          text: 'deleted',
          headers: [('Chat-Delete', '<original@example.org>')],
        ),
      );
      expect(chats.chats[chatKey()]!.messages.first.deleted, isTrue);
      expect(chats.chats[chatKey()]!.messages.first.text, '');
    });
    test('$kind forged From with another key cannot edit or delete', () async {
      for (final header in ['Chat-Edit', 'Chat-Delete']) {
        await receive(
          await coreMail(
            grouped: grouped,
            from: addr(alice),
            author: outsider,
            text: 'forged',
            headers: [(header, '<original@example.org>')],
          ),
        );
        expect(chats.chats[chatKey()]!.messages.first.text, 'Original');
        expect(chats.chats[chatKey()]!.messages.first.deleted, isFalse);
      }
    });
    test('$kind unsigned edit cannot mutate the original', () async {
      final mail = Uint8List.fromList(
        utf8.encode(
          'From: <${addr(alice)}>\r\nTo: <${addr(bob)}>\r\nMessage-ID: <unsigned@example.org>\r\n'
          'Chat-Version: 1.0\r\nChat-Edit: <original@example.org>\r\n\r\nforged',
        ),
      );
      expect((await receive(mail)).consumed, isFalse);
      expect(chats.chats[chatKey()]!.messages.first.text, 'Original');
    });
  }

  test(
    'Delta text byte budgets apply before decoding plain and flowed text',
    () async {
      for (final format in ['', '; format=flowed']) {
        final mail = await coreMail(
          parts: [
            'Content-Type: text/plain; charset=utf-8$format\r\n'
                'Content-Transfer-Encoding: base64\r\n\r\n'
                '${base64Lines(Uint8List(DeltaMail.maxTextBytes + 1)..fillRange(0, DeltaMail.maxTextBytes + 1, 120))}',
            filePart(photo),
          ],
        );
        expect(await DeltaMail.read(mail, bob, now: clock), isNull);
        expect((await receive(mail)).consumed, isFalse);
        expect(saved, isEmpty);
      }
    },
  );

  test('Delta flowed text line budget rejects excess soft lines', () async {
    final mail = await coreMail(
      parts: [
        'Content-Type: text/plain; format=flowed; delsp=yes\r\n'
            'Content-Transfer-Encoding: base64\r\n\r\n'
            '${base64Lines(utf8.encode(' a \n' * (DeltaMail.maxTextLines + 1)))}',
        filePart(photo),
      ],
    );
    expect(await DeltaMail.read(mail, bob, now: clock), isNull);
    expect((await receive(mail)).consumed, isFalse);
    expect(saved, isEmpty);
  });

  test(
    'Delta flowed scanning retains stuffing, delsp and signature semantics',
    () async {
      final mail = await coreMail(
        parts: [
          'Content-Type: text/plain; format=flowed; delsp=yes\r\n'
              'Content-Transfer-Encoding: base64\r\n\r\n'
              '${base64Lines(utf8.encode(' hello \r\nworld\n  indented\n-- \nsig\r\n'))}',
        ],
      );
      final read = (await DeltaMail.read(mail, bob, now: clock))!;
      expect(read.text, 'helloworld\n indented\n-- \nsig');
    },
  );

  test('Delta reactions have the same pre-decode text budget', () async {
    final mail = await coreMail(
      reaction: true,
      headers: [('In-Reply-To', '<original@example.org>')],
      text: '👍 ${'x ' * (DeltaMail.maxTextBytes ~/ 2)}',
    );
    expect(await DeltaMail.read(mail, bob, now: clock), isNull);
    expect((await receive(mail)).consumed, isFalse);
    expect(chats.chats[fp(alice)]!.messages.single.reactions, isEmpty);
  });

  test(
    'another group member cannot edit or delete an author message',
    () async {
      for (final header in ['Chat-Edit', 'Chat-Delete']) {
        await receive(
          await coreMail(
            author: carol,
            grouped: true,
            text: 'wrong author',
            headers: [(header, '<original@example.org>')],
          ),
        );
        expect(chats.chats[groupKey]!.messages.first.text, 'Original');
        expect(chats.chats[groupKey]!.messages.first.deleted, isFalse);
      }
    },
  );
  test(
    'nonmember group reaction is ignored without granting membership',
    () async {
      await receive(
        await coreMail(
          author: outsider,
          grouped: true,
          reaction: true,
          text: '👍',
          headers: [('In-Reply-To', '<original@example.org>')],
        ),
      );
      expect(chats.chats[groupKey]!.messages.first.reactions, isEmpty);
      expect(chats.chats[groupKey]!.members, isNot(contains(fp(outsider))));
    },
  );
  test('stale reaction and edit do not undo newer changes', () async {
    await receive(
      await coreMail(
        reaction: true,
        text: '❤️',
        headers: [('In-Reply-To', '<original@example.org>')],
      ),
    );
    await receive(
      await coreMail(
        reaction: true,
        text: '',
        date: clock.subtract(const Duration(seconds: 1)),
        headers: [('In-Reply-To', '<original@example.org>')],
      ),
    );
    expect(chats.chats[fp(alice)]!.messages.first.reactions[fp(alice)], '❤️');
    await receive(
      await coreMail(
        text: 'New',
        headers: [('Chat-Edit', '<original@example.org>')],
      ),
    );
    await receive(
      await coreMail(
        text: 'Old',
        date: clock.subtract(const Duration(seconds: 1)),
        headers: [('Chat-Edit', '<original@example.org>')],
      ),
    );
    expect(chats.chats[fp(alice)]!.messages.first.text, 'New');
  });

  test(
    'removed author can edit and delete old messages but cannot react',
    () async {
      chats = chats.withChat(group().copyWith(members: [fp(carol)]));
      await receive(
        await coreMail(
          grouped: true,
          text: '✏️Edited after leaving',
          headers: [('Chat-Edit', '<original@example.org>')],
        ),
      );
      expect(
        chats.chats[groupKey]!.messages.first.text,
        'Edited after leaving',
      );
      await receive(
        await coreMail(
          grouped: true,
          reaction: true,
          text: '👍',
          headers: [('In-Reply-To', '<original@example.org>')],
        ),
      );
      expect(chats.chats[groupKey]!.messages.first.reactions, isEmpty);
      await receive(
        await coreMail(
          grouped: true,
          headers: [
            ('Chat-Delete', '<original@example.org> <unknown@example.org>'),
          ],
        ),
      );
      expect(chats.chats[groupKey]!.messages.first.deleted, isTrue);
      expect(chats.chats[groupKey]!.pendingControls, isEmpty);
      expect(chats.chats[groupKey]!.members, [fp(carol)]);
    },
  );

  final metadata = '{"size":150001,"viewtype":"Image","filename":"photo.png"}';
  Future<Uint8List> pre({PgpSecretKey? author}) => coreMail(
    id: 'pre@example.org',
    author: author,
    text: 'Photo caption',
    headers: [
      ('Chat-Post-Message-ID', '<post@example.org>'),
      ('Chat-Post-Message-Metadata', metadata),
    ],
  );
  Future<Uint8List> post({PgpSecretKey? author}) => coreMail(
    id: 'post@example.org',
    author: author,
    outer: 'Chat-Is-Post-Message: 1\r\n',
    parts: [filePart(photo)],
  );
  test(
    'pre then post replaces the placeholder and preserves caption and ID',
    () async {
      await receive(await pre());
      final placeholder = chats.chats[fp(alice)]!.messages.last;
      expect(placeholder.id, 'post@example.org');
      expect(placeholder.pending!.size, 150001);
      expect(placeholder.preMessageId, 'pre@example.org');
      expect(saved, isEmpty);
      final count = chats.chats[fp(alice)]!.messages.length;
      await receive(await post());
      final message = chats.chats[fp(alice)]!.messages.last;
      expect(chats.chats[fp(alice)]!.messages, hasLength(count));
      expect(message.id, placeholder.id);
      expect(message.text, 'Photo caption');
      expect(message.pending, isNull);
      expect(message.attachments.single.sizeBytes, photo.length);
    },
  );
  test(
    'post first and standalone post work; later pre supplies caption once',
    () async {
      await receive(await post());
      final count = chats.chats[fp(alice)]!.messages.length;
      expect(saved, hasLength(1));
      await receive(await pre());
      expect(chats.chats[fp(alice)]!.messages, hasLength(count));
      expect(chats.chats[fp(alice)]!.messages.last.text, 'Photo caption');
      expect(chats.chats[fp(alice)]!.messages.last.pending, isNull);
      await receive(await post());
      expect(saved, hasLength(1), reason: 'duplicate post must not save again');
    },
  );
  test(
    'pending timeout uses receipt clock and survives vault serialization',
    () async {
      await receive(await pre());
      final message = DeltaChats.fromJson(
        chats.toJson(),
      ).chats[fp(alice)]!.messages.last;
      expect(
        message.pendingExpired(clock.add(const Duration(days: 6))),
        isFalse,
      );
      expect(
        message.pendingExpired(clock.add(const Duration(days: 7))),
        isTrue,
      );
      expect(
        message.preview(clock.add(const Duration(days: 7))),
        contains('Photo caption'),
      );
    },
  );
  test('another signer cannot fill a group file placeholder', () async {
    await receive(
      await coreMail(
        grouped: true,
        id: 'pre@example.org',
        headers: [
          ('Chat-Post-Message-ID', '<post@example.org>'),
          ('Chat-Post-Message-Metadata', metadata),
        ],
      ),
    );
    await receive(
      await coreMail(
        grouped: true,
        id: 'post@example.org',
        author: carol,
        outer: 'Chat-Is-Post-Message: 1\r\n',
        parts: [filePart(photo)],
      ),
    );
    expect(chats.chats[groupKey]!.messages.last.pending, isNotNull);
    expect(saved, isEmpty);
  });
  for (final left in [false, true]) {
    test(
      'accepted group post completes after ${left ? 'local departure' : 'author removal'}',
      () async {
        await receive(
          await coreMail(
            grouped: true,
            id: 'pre@example.org',
            text: 'Accepted caption',
            headers: [
              ('Chat-Post-Message-ID', '<post@example.org>'),
              ('Chat-Post-Message-Metadata', metadata),
            ],
          ),
        );
        chats = chats.withChat(
          chats.chats[groupKey]!.copyWith(
            members: left ? [fp(alice), fp(carol)] : [fp(carol)],
            left: left,
          ),
        );
        final count = chats.chats[groupKey]!.messages.length;
        await receive(
          await coreMail(
            grouped: true,
            id: 'post@example.org',
            outer: 'Chat-Is-Post-Message: 1\r\n',
            headers: [('Chat-Group-Name', 'Delayed group change')],
            parts: [filePart(photo)],
          ),
        );
        final chat = chats.chats[groupKey]!;
        expect(chat.messages, hasLength(count));
        expect(chat.messages.last.pending, isNull);
        expect(chat.messages.last.attachments.single.sizeBytes, photo.length);
        expect(chat.messages.last.text, 'Accepted caption');
        expect(chat.name, 'Team');
        expect(chat.left, left);
        expect(chat.members, left ? [fp(alice), fp(carol)] : [fp(carol)]);
      },
    );
  }
  test(
    'outer pre/edit/delete/voice/avatar headers do not gain authority',
    () async {
      await receive(
        await coreMail(
          id: 'outer-injection@example.org',
          text: 'ordinary',
          outer:
              'Chat-Post-Message-ID: <post@example.org>\r\nChat-Edit: <original@example.org>\r\n'
              'Chat-Delete: <original@example.org>\r\nChat-Voice-Message: 1\r\nChat-User-Avatar: 0\r\n',
        ),
      );
      expect(chats.chats[fp(alice)]!.messages.first.text, 'Original');
      expect(chats.chats[fp(alice)]!.messages.last.pending, isNull);
    },
  );
  test(
    'sending splits only above exact core threshold with correct JSON and headers',
    () async {
      final outboundChats = DeltaChats(
        peers: {
          fp(bob): DeltaPeer(
            fingerprint: fp(bob),
            addr: addr(bob),
            key: bob.publicKey.bytes,
          ),
        },
        chats: {
          fp(bob): DeltaChat(key: fp(bob), members: [fp(bob)], kept: true),
        },
      );
      for (final size in [140000, 140001]) {
        final f = DeltaFile(name: 'video.bin', bytes: Uint8List(size));
        final step = await sender.sendFiles(
          outboundChats,
          fp(bob),
          'caption',
          [f],
          [descriptor(f)],
        );
        expect(step.mails, hasLength(size > 140000 ? 2 : 1));
        final read = await DeltaMail.read(
          Uint8List.fromList(utf8.encode(step.mails.last.mail)),
          bob,
          now: clock,
        );
        expect(read!.files.single.bytes.length, size);
        expect(read.postMessage, size > 140000);
        if (size > 140000) {
          final pre = await DeltaMail.read(
            Uint8List.fromList(utf8.encode(step.mails.first.mail)),
            bob,
            now: clock,
          );
          expect(pre!.postMessageId, read.messageId);
          expect(pre.pending!.toJson(), {
            'size': size,
            'viewtype': 'File',
            'filename': 'video.bin',
          });
          expect(pre.text, 'caption');
          expect(read.text, '');
        }
      }
    },
  );
  test('outbound reaction edit and deletion use exact core headers', () async {
    final outgoing = DeltaChats(
      peers: {
        fp(bob): DeltaPeer(
          fingerprint: fp(bob),
          addr: addr(bob),
          key: bob.publicKey.bytes,
        ),
      },
      chats: {
        fp(bob): DeltaChat(
          key: fp(bob),
          members: [fp(bob)],
          messages: [
            DeltaChatMessage(
              id: 'sent@example.org',
              author: fp(alice),
              text: 'Sent',
              at: clock,
              outgoing: true,
            ),
          ],
        ),
      },
    );
    final steps = [
      await sender.react(outgoing, fp(bob), 'sent@example.org', '👍'),
      await sender.edit(outgoing, fp(bob), 'sent@example.org', 'New'),
      await sender.deleteMessage(outgoing, fp(bob), 'sent@example.org'),
    ];
    final read = [
      for (final s in steps)
        (await DeltaMail.read(
          Uint8List.fromList(utf8.encode(s.mails.single.mail)),
          bob,
          now: clock,
        ))!,
    ];
    expect(read[0].reactionText, '👍');
    expect(read[0].header('in-reply-to'), '<sent@example.org>');
    expect(read[1].header('chat-edit'), '<sent@example.org>');
    expect(read[1].text, '✏️New');
    expect(read[2].header('chat-delete'), '<sent@example.org>');
  });

  test(
    'outgoing direct and group voice use protected millisecond headers and Voice split metadata',
    () async {
      final outgoing = DeltaChats(
        peers: {
          for (final k in [bob, carol])
            fp(k): DeltaPeer(
              fingerprint: fp(k),
              addr: addr(k),
              key: k.publicKey.bytes,
            ),
        },
        chats: {
          fp(bob): DeltaChat(key: fp(bob), members: [fp(bob)], kept: true),
          groupKey: group().copyWith(members: [fp(bob), fp(carol)]),
        },
      );
      for (final key in [fp(bob), groupKey]) {
        for (final size in [120, 150001]) {
          final bytes = Uint8List(size)..setRange(0, 4, ascii.encode('OggS'));
          final file = DeltaFile(
            name: 'voice.ogg',
            bytes: bytes,
            mimeType: 'audio/ogg',
            voice: true,
            durationMs: 152310,
          );
          final step = await sender.sendFiles(
            outgoing,
            key,
            '',
            [file],
            [descriptor(file)],
          );
          for (final mail in step.mails) {
            final read = (await DeltaMail.read(
              Uint8List.fromList(utf8.encode(mail.mail)),
              bob,
              now: clock,
            ))!;
            expect(read.header('chat-voice-message'), '1');
            expect(read.header('chat-duration'), '152310');
            expect(
              read.header('chat-group-id'),
              key == groupKey ? 'test-group' : null,
            );
            if (read.postMessageId != null) {
              expect(read.pending!.viewtype, 'Voice');
              expect(read.pending!.durationMs, 152310);
            } else {
              expect(read.files.single.voice, isTrue);
              expect(read.files.single.mimeType, 'audio/ogg');
              expect(read.files.single.bytes, bytes);
            }
          }
        }
      }
    },
  );

  test(
    'M4A voice is recognized from its content with an untrusted MIME hint',
    () async {
      final bytes = Uint8List.fromList([
        0,
        0,
        0,
        24,
        ...ascii.encode('ftypM4A '),
      ]);
      await receive(
        await coreMail(
          headers: [('Chat-Voice-Message', '1'), ('Chat-Duration', '3210')],
          parts: [
            filePart(
              bytes,
              name: 'voice.mp4',
              mime: 'application/octet-stream',
            ),
          ],
        ),
      );
      final file = chats.chats[fp(alice)]!.messages.last.attachments.single;
      expect(file.mimeType, 'audio/mp4');
      expect(file.voiceMetadata!.durationMs, 3210);
    },
  );
  test('exact avatar headers set and clear peer and group avatars', () async {
    await receive(
      await coreMail(
        grouped: true,
        text: 'avatar',
        headers: [
          ('Chat-User-Avatar', 'base64:${base64Encode(photo)}'),
          ('Chat-Group-Avatar', 'base64:${base64Encode(photo)}'),
        ],
      ),
    );
    expect(chats.peers[fp(alice)]!.avatar, photo);
    expect(chats.chats[groupKey]!.avatar, photo);
    final restored = DeltaChats.fromJson(chats.toJson());
    expect(restored.chats[groupKey]!.avatar, photo);
    await receive(
      await coreMail(
        grouped: true,
        id: 'remove-avatar@example.org',
        headers: [('Chat-User-Avatar', '0'), ('Chat-Group-Avatar', '0')],
      ),
    );
    expect(chats.peers[fp(alice)]!.avatar, isNull);
    expect(chats.chats[groupKey]!.avatar, isNull);
  });
  test('oversized avatars and forged MIME are refused before decoding', () {
    expect(
      deltaAvatar('base64:${'A' * (DeltaLimits.avatarEncodedBytes + 1)}'),
      isNull,
    );
    final wide = Uint8List.fromList(
      img.encodePng(img.Image(width: 513, height: 1)),
    );
    expect(deltaAvatar('base64:${base64Encode(wide)}'), isNull);
    expect(
      deltaAvatar('base64:${base64Encode(ascii.encode('<svg/>'))}'),
      isNull,
    );
    expect(deltaAvatar('base64:${base64Encode(photo)}'), photo);
  });
  test(
    'tiny PNG canvas refuses excess inflated IDAT before pixel decoding',
    () {
      List<int> chunk(String type, List<int> data) {
        final n = data.length;
        final typed = [...ascii.encode(type), ...data];
        final crc = getCrc32(typed);
        return [
          n >> 24,
          (n >> 16) & 255,
          (n >> 8) & 255,
          n & 255,
          ...typed,
          crc >> 24,
          (crc >> 16) & 255,
          (crc >> 8) & 255,
          crc & 255,
        ];
      }

      final tiny = img.encodePng(img.Image(width: 1, height: 1));
      final bad = Uint8List.fromList([
        ...tiny.sublist(0, 8),
        ...chunk('IHDR', tiny.sublist(16, 29)),
        ...chunk('IDAT', ZLibEncoder().convert(Uint8List(1024 * 1024))),
        ...chunk('IEND', const []),
      ]);
      expect(bad.length, lessThan(2048));
      expect(deltaAvatar('base64:${base64Encode(bad)}'), isNull);
      expect(deltaAvatar('base64:${base64Encode(tiny)}'), isNotNull);
    },
  );

  test('valid JPEG avatar is normalized to a bounded static PNG', () {
    final jpeg = img.encodeJpg(img.Image(width: 2, height: 3));
    final avatar = deltaAvatar('base64:${base64Encode(jpeg)}');
    expect(avatar, isNotNull);
    expect(deltaMimeType(avatar!), 'image/png');
    final decoded = img.decodePng(avatar)!;
    expect((decoded.width, decoded.height), (2, 3));
    expect(decoded.iccProfile, isNull);
  });

  test('too many attachments and aggregate decoded budget are refused', () async {
    final mail = await coreMail(parts: List.filled(21, filePart(photo)));
    expect((await receive(mail)).consumed, isFalse);
    expect(saved, isEmpty);
    expect(
      () => MimeEntity.parse(
        Uint8List.fromList(utf8.encode(filePart(Uint8List(16)))),
        maxDecodedBytes: 8,
      ),
      throwsFormatException,
    );
    expect(
      DeltaPendingFile.parse(
        '{"size":${DeltaLimits.fileBytes + 1},"filename":"huge","viewtype":"File"}',
      ),
      isNull,
    );
  });
  test('reaction token semantics and sanitized pending names are bounded', () {
    expect(deltaReaction('👍 ❤️'), '👍');
    expect(deltaReaction('A' * 30), '');
    final p = DeltaPendingFile.parse(
      '{"size":5,"filename":"../../${'x' * 500}.png","viewtype":"Image"}',
    )!;
    expect(p.name.length, lessThanOrEqualTo(120));
    expect(p.name, isNot(contains('/')));
  });
  test('stickers save as images; webxdc and calls show unsupported', () async {
    await receive(
      await coreMail(
        id: 'sticker@example.org',
        headers: [('Chat-Content', 'sticker')],
        parts: [filePart(photo)],
      ),
    );
    expect(saved.single.sticker, isTrue);
    await receive(
      await coreMail(
        id: 'app@example.org',
        parts: [filePart(Uint8List(1), name: 'app.xdc')],
      ),
    );
    expect(chats.chats[fp(alice)]!.messages.last.text, 'app (not supported)');
    expect(saved, hasLength(1));
    await receive(
      await coreMail(
        id: 'call@example.org',
        headers: [('Chat-Content', 'call')],
        text: 'call',
      ),
    );
    expect(chats.chats[fp(alice)]!.messages.last.text, 'Call (not supported)');
  });

  test('member clocks merge omissions and past members per identity', () async {
    final t2 = clock.add(const Duration(seconds: 10));
    receivedAt = t2;
    final t1secs = clock.millisecondsSinceEpoch ~/ 1000;
    final t2secs = t2.millisecondsSinceEpoch ~/ 1000;
    // Alice adds Carol at t2, while older mail only knows Bob.
    chats = chats.withChat(
      group().copyWith(
        memberAdded: {fp(alice): clock, fp(bob): clock, fp(carol): t2},
      ),
    );
    await receive(
      await coreMail(
        grouped: true,
        text: 'older list',
        headers: [
          ('Chat-Group-Member-Fpr', fp(bob)),
          ('Chat-Group-Member-Timestamps', '$t1secs'),
        ],
      ),
    );
    expect(chats.chats[groupKey]!.members, contains(fp(carol)));
    await receive(
      await coreMail(
        grouped: true,
        id: 'past@example.org',
        headers: [
          ('Chat-Group-Member-Fpr', '${fp(bob)} ${fp(carol)}'),
          ('Chat-Group-Past-Members', '<${addr(carol)}>'),
          ('Chat-Group-Member-Timestamps', '$t1secs ${t2secs + 1}'),
        ],
        text: 'removed',
      ),
    );
    // Clamp to local time; removals must strictly beat the add clock.
    receivedAt = t2.add(const Duration(seconds: 1));
    await receive(
      await coreMail(
        grouped: true,
        id: 'past2@example.org',
        headers: [
          ('Chat-Group-Member-Fpr', '${fp(bob)} ${fp(carol)}'),
          ('Chat-Group-Past-Members', '<${addr(carol)}>'),
          ('Chat-Group-Member-Timestamps', '$t1secs ${t2secs + 1}'),
        ],
        text: 'removed',
      ),
    );
    expect(chats.chats[groupKey]!.members, isNot(contains(fp(carol))));
    await receive(
      await coreMail(
        grouped: true,
        id: 'stale@example.org',
        headers: [
          ('Chat-Group-Member-Fpr', fp(bob)),
          ('Chat-Group-Member-Timestamps', '$t1secs'),
        ],
        text: 'older',
      ),
    );
    expect(chats.chats[groupKey]!.members, isNot(contains(fp(carol))));
    final restored = DeltaChats.fromJson(chats.toJson()).chats[groupKey]!;
    expect(
      restored.memberRemoved[fp(carol)],
      t2.add(const Duration(seconds: 1)),
    );
  });
  test('same-second removal stays newer than addition on the wire', () async {
    var localClock = clock.add(const Duration(milliseconds: 100));
    final protocol = DeltaProtocol(
      key: alice,
      self: addr(alice),
      tokens: DeltaTokens.create(Random(4)),
      now: () => localClock,
    );
    final outgoing = DeltaChats(
      peers: {
        for (final k in [bob, carol])
          fp(k): DeltaPeer(
            fingerprint: fp(k),
            addr: addr(k),
            key: k.publicKey.bytes,
          ),
      },
      chats: {
        groupKey: DeltaChat(
          key: groupKey,
          groupId: 'test-group',
          name: 'Team',
          members: [fp(bob), fp(carol)],
          kept: true,
          memberAdded: {
            fp(alice): localClock,
            fp(bob): localClock,
            fp(carol): localClock,
          },
        ),
      },
    );
    localClock = clock.add(const Duration(milliseconds: 200));
    final removed = await protocol.removeMember(outgoing, groupKey, fp(carol));
    expect(
      removed.chats.chats[groupKey]!.memberRemoved[fp(carol)],
      clock.add(const Duration(seconds: 1)),
    );
    await receive(Uint8List.fromList(utf8.encode(removed.mails.single.mail)));
    expect(chats.chats[groupKey]!.members, isNot(contains(fp(carol))));
  });

  test(
    'rejected stale member removal emits no misleading departure notice',
    () async {
      receivedAt = clock.add(const Duration(seconds: 20));
      chats = chats.withChat(
        group().copyWith(
          memberAdded: {
            fp(alice): clock,
            fp(bob): clock,
            fp(carol): clock.add(const Duration(seconds: 10)),
          },
        ),
      );
      final epoch = clock.millisecondsSinceEpoch ~/ 1000;
      await receive(
        await coreMail(
          grouped: true,
          date: receivedAt,
          headers: [
            ('Chat-Group-Member-Removed', addr(carol)),
            ('Chat-Group-Member-Removed-Fpr', fp(carol)),
            ('Chat-Group-Member-Fpr', '${fp(bob)} ${fp(carol)}'),
            ('Chat-Group-Past-Members', '<${addr(carol)}>'),
            ('Chat-Group-Member-Timestamps', '$epoch ${epoch + 1}'),
          ],
        ),
      );
      expect(chats.chats[groupKey]!.members, contains(fp(carol)));
      expect(
        chats.chats[groupKey]!.messages.where(
          (m) => m.info && m.text.contains('left the group'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'legacy explicit add rejoins only the named member after a tombstone',
    () async {
      final removedAt = clock.add(const Duration(seconds: 1));
      receivedAt = clock.add(const Duration(seconds: 2));
      chats = chats.withChat(
        group().copyWith(
          members: [fp(alice)],
          memberRemoved: {fp(carol): removedAt},
        ),
      );
      // A legacy add includes Carol in To and gossip, but no member clocks.
      final inner = await DeltaMail.build(
        key: alice,
        from: addr(alice),
        to: [
          (addr: addr(bob), key: bob.publicKey),
          (addr: addr(carol), key: carol.publicKey),
        ],
        gossip: [(addr: addr(carol), key: carol.publicKey)],
        text: 'Carol added',
        messageId: 'legacy-add@example.org',
        date: receivedAt,
        extraHeaders: [
          ('Chat-Group-ID', 'test-group'),
          ('Chat-Group-Member-Added', addr(carol)),
          ('Chat-Group-Member-Added-Fpr', fp(carol)),
        ],
      );
      await receive(Uint8List.fromList(utf8.encode(inner)));
      expect(chats.chats[groupKey]!.members, contains(fp(carol)));
      expect(chats.chats[groupKey]!.memberAdded[fp(carol)], receivedAt);
    },
  );

  test(
    'legacy removal cannot grow tombstones for unknown fingerprints',
    () async {
      final before = chats.chats[groupKey]!.memberRemoved.length;
      for (var i = 0; i < 5; i++) {
        await receive(
          await coreMail(
            grouped: true,
            id: 'unknown-remove-$i@example.org',
            headers: [
              (
                'Chat-Group-Member-Removed-Fpr',
                i.toRadixString(16).padLeft(40, '0'),
              ),
            ],
            text: 'remove',
          ),
        );
      }
      expect(chats.chats[groupKey]!.memberRemoved, hasLength(before));
      expect(chats.chats[groupKey]!.pastAddresses, isEmpty);
    },
  );

  test('avatar reader refuses animation flags even for one-frame WebP', () {
    // A complete, valid 1x1 VP8L frame in an animated RIFF container.
    final bytes = base64Decode(
      'UklGRlIAAABXRUJQVlA4WAoAAAACAAAAAAAAAAAAQU5JTQYAAAAAAAAAAABBTk1GJgAAAAAAAAAAAAAAAAAAAAAAAABWUDhMDgAAAC8AAAAABxAR/Q9ERP8D',
    );
    expect(img.decodeWebP(bytes), isNotNull);
    expect(deltaAvatar('base64:${base64Encode(bytes)}'), isNull);
  });

  test(
    'avatars reject lossless WebP allocation paths and retain bounded lossy WebP',
    () {
      // Structural meta-Huffman index 999 fixture: never pass it to image.decodeWebP.
      final attack = base64Decode(
        'UklGRlgAAABXRUJQVlA4TEwAAAAvH8AHAG7oeQei/wEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      );
      expect(deltaAvatar('base64:${base64Encode(attack)}'), isNull);
      final lossy = base64Decode(
        'UklGRjoAAABXRUJQVlA4IC4AAAAQAgCdASoCAAMAAUAmJaACdLoB+AH4AAPIAP7aJv/qcGDnz8oj/1BaGvl+IwAA',
      );
      final avatar = deltaAvatar('base64:${base64Encode(lossy)}');
      expect(avatar, isNotNull);
      expect(
        (img.decodePng(avatar!)!.width, img.decodePng(avatar)!.height),
        (2, 3),
      );
    },
  );

  test(
    'benign lossless WebP and GIF avatars are refused without entering those decoders',
    () {
      final lossless = base64Decode(
        'UklGRhoAAABXRUJQVlA4TA4AAAAvAAAAAAcQEf0PRET/Aw==',
      );
      expect(img.decodeWebP(lossless), isNotNull);
      expect(deltaAvatar('base64:${base64Encode(lossless)}'), isNull);
      final gif = img.encodeGif(img.Image(width: 1, height: 1));
      expect(deltaAvatar('base64:${base64Encode(gif)}'), isNull);
    },
  );

  test('excess edit quote prefixes and a Delta footer stay bounded', () async {
    await receive(
      await coreMail(
        text: '${'> quoted\n' * 5000}\n✏️New',
        headers: [('Chat-Edit', '<original@example.org>')],
      ),
    );
    expect(chats.chats[fp(alice)]!.messages.first.text, 'Original');
    await receive(
      await coreMail(
        text: '> Original\n\n✏️New\n\n-- \nStatus',
        headers: [('Chat-Edit', '<original@example.org>')],
      ),
    );
    expect(chats.chats[fp(alice)]!.messages.first.text, 'New');
  });

  test('packet and partial chunk budgets reject hostile armored data', () async {
    final packets = Uint8List.fromList([
      for (var i = 0; i <= OpenPgpSymmetric.maxPackets; i++) ...[0xca, 0],
    ]);
    expect(() => OpenPgpSymmetric.readPackets(packets), throwsFormatException);
    final raw = Uint8List.fromList(
      utf8.encode(
        'From: <${addr(alice)}>\r\n'
        'Content-Type: multipart/encrypted; boundary=x\r\n\r\n'
        '--x\r\nContent-Type: application/octet-stream\r\n\r\n${OpenPgpArmor.encode(packets)}\r\n--x--\r\n',
      ),
    );
    expect(await DeltaMail.read(raw, bob, now: clock), isNull);
    final chunks = Uint8List.fromList([
      0xd2,
      for (var i = 0; i <= OpenPgpSymmetric.maxPartialChunks; i++) ...[224, 0],
      0,
    ]);
    expect(() => OpenPgpSymmetric.readPackets(chunks), throwsFormatException);
  });

  test('JPEG cyclic EXIF is stripped before avatar decoding', () {
    final jpeg = img.encodeJpg(img.Image(width: 1, height: 1));
    final exif = [
      ...ascii.encode('Exif'),
      0,
      0,
      0x49,
      0x49,
      42,
      0,
      8,
      0,
      0,
      0,
      0,
      0,
      14,
      0,
      0,
      0,
      0,
      0,
      8,
      0,
      0,
      0,
    ];
    final dirty = Uint8List.fromList([
      255,
      216,
      255,
      225,
      0,
      exif.length + 2,
      ...exif,
      ...jpeg.sublist(2),
    ]);
    final clean = deltaAvatar('base64:${base64Encode(dirty)}');
    expect(clean, isNotNull);
    expect(img.decodePng(clean!)!.width, 1);
    expect(latin1.decode(clean), isNot(contains('Exif')));
  });

  test(
    'early delete is persisted and suppresses only its signed author',
    () async {
      await receive(
        await coreMail(
          grouped: true,
          headers: [('Chat-Delete', '<late@example.org>')],
        ),
      );
      chats = DeltaChats.fromJson(chats.toJson());
      await receive(
        await coreMail(
          grouped: true,
          id: 'late@example.org',
          parts: [filePart(photo)],
        ),
      );
      expect(chats.chats[groupKey]!.messages.last.deleted, isTrue);
      expect(saved, isEmpty);
      await receive(
        await coreMail(
          grouped: true,
          author: carol,
          headers: [('Chat-Delete', '<alice-late@example.org>')],
        ),
      );
      await receive(
        await coreMail(
          grouped: true,
          id: 'alice-late@example.org',
          text: 'Alice still here',
        ),
      );
      expect(chats.chats[groupKey]!.messages.last.text, 'Alice still here');
      expect(chats.chats[groupKey]!.messages.last.deleted, isFalse);
    },
  );

  test('early reaction is applied when the target arrives', () async {
    await receive(
      await coreMail(
        grouped: true,
        reaction: true,
        text: '👍',
        headers: [('In-Reply-To', '<react-late@example.org>')],
      ),
    );
    chats = DeltaChats.fromJson(chats.toJson());
    await receive(
      await coreMail(
        grouped: true,
        id: 'react-late@example.org',
        text: 'Later',
      ),
    );
    expect(chats.chats[groupKey]!.messages.last.reactions[fp(alice)], '👍');
  });

  for (final grouped in [false, true]) {
    test(
      '${grouped ? 'group' : 'direct'} deletion before the first chat message survives restart without granting membership',
      () async {
        chats = chats.copyWith(chats: {});
        await receive(
          await coreMail(
            grouped: grouped,
            headers: [('Chat-Delete', '<first@example.org>')],
          ),
        );
        expect(chats.chats, isEmpty);
        expect(chats.detachedControls, hasLength(1));
        chats = DeltaChats.fromJson(chats.toJson());
        await receive(
          await coreMail(
            grouped: grouped,
            id: 'first@example.org',
            text: 'Deleted before delivery',
            parts: [filePart(photo)],
          ),
        );
        final message =
            chats.chats[grouped ? groupKey : fp(alice)]!.messages.single;
        expect(message.deleted, isTrue);
        expect(message.text, isEmpty);
        expect(message.attachments, isEmpty);
        expect(saved, isEmpty);
      },
    );
  }

  test(
    'detached deletions stay bounded and cannot suppress a different group author',
    () async {
      chats = chats.copyWith(chats: {});
      await receive(
        await coreMail(
          grouped: true,
          headers: [('Chat-Delete', '<first@example.org>')],
        ),
      );
      await receive(
        await coreMail(
          author: carol,
          grouped: true,
          id: 'first@example.org',
          text: 'Different author',
        ),
      );
      expect(chats.chats[groupKey]!.messages.single.deleted, isFalse);
      chats = chats.copyWith(chats: {});
      for (var batch = 0; batch < 3; batch++) {
        await receive(
          await coreMail(
            grouped: true,
            headers: [
              (
                'Chat-Delete',
                [for (var i = 0; i < 100; i++) '<delete-$batch-$i@example.org>']
                    .join(' '),
              ),
            ],
          ),
        );
      }
      expect(chats.chats, isEmpty);
      expect(chats.detachedControls, hasLength(128));
      expect(
        DeltaChats.fromJson(chats.toJson()).detachedControls,
        hasLength(128),
      );
    },
  );

  test(
    'a fractional local member addition accepts a same-second legacy removal',
    () async {
      receivedAt = clock.add(const Duration(milliseconds: 100));
      chats = chats.withChat(
        group().copyWith(
          members: [fp(alice)],
          memberAdded: {fp(alice): clock, fp(bob): clock},
        ),
      );
      chats = (await receiver.addMember(chats, groupKey, fp(carol))).chats;
      expect(chats.chats[groupKey]!.members, contains(fp(carol)));
      await receive(
        await coreMail(
          grouped: true,
          headers: [
            ('Chat-Group-Member-Removed', addr(carol)),
            ('Chat-Group-Member-Removed-Fpr', fp(carol)),
          ],
        ),
      );
      expect(chats.chats[groupKey]!.members, isNot(contains(fp(carol))));
      expect(
        chats.chats[groupKey]!.memberRemoved[fp(carol)],
        clock.add(const Duration(seconds: 1)),
      );
    },
  );

  test('late pre preserves an explicitly emptied caption', () async {
    await receive(await post());
    await receive(
      await coreMail(
        text: '✏️',
        headers: [('Chat-Edit', '<post@example.org>')],
      ),
    );
    await receive(await pre());
    expect(chats.chats[fp(alice)]!.messages.last.text, '');
  });

  test('older avatar mail cannot reset a newer signed avatar', () async {
    await receive(
      await coreMail(
        grouped: true,
        headers: [
          ('Chat-User-Avatar', 'base64:${base64Encode(photo)}'),
          ('Chat-Group-Avatar', 'base64:${base64Encode(photo)}'),
        ],
        text: 'new',
      ),
    );
    await receive(
      await coreMail(
        grouped: true,
        id: 'older-avatar@example.org',
        date: clock.subtract(const Duration(seconds: 1)),
        headers: [('Chat-User-Avatar', '0'), ('Chat-Group-Avatar', '0')],
        text: 'old',
      ),
    );
    expect(chats.peers[fp(alice)]!.avatar, isNotNull);
    expect(chats.chats[groupKey]!.avatar, isNotNull);
  });

  test('empty unkept group requests remain capped', () {
    var store = const DeltaChats();
    for (var i = 0; i < DeltaChats.maxRequests + 1; i++) {
      store = store.withChat(
        DeltaChat(key: 'g:$i', groupId: '$i', members: const []),
      );
    }
    expect(store.chats, hasLength(DeltaChats.maxRequests));
  });

  test(
    'kept group creation is capped without evicting existing history or saving refused files',
    () async {
      while (chats.chats.length < DeltaChats.maxChats) {
        final id = 'bounded-${chats.chats.length}';
        chats = chats.withChat(
          DeltaChat(
            key: DeltaChat.groupKey(id),
            groupId: id,
            members: [fp(alice)],
            kept: true,
          ),
        );
      }
      final prior = chats.chats[fp(alice)]!.messages.single;
      for (var i = 0; i < 3; i++) {
        final step = await receive(
          await coreMail(
            id: 'new-group-$i@example.org',
            headers: [('Chat-Group-ID', 'overflow-$i')],
            parts: [filePart(photo)],
          ),
        );
        expect(step.consumed, isFalse);
        expect(step.retry, isTrue);
      }
      expect(chats.chats, hasLength(DeltaChats.maxChats));
      expect(saved, isEmpty);
      expect(chats.chats[fp(alice)]!.messages.single.id, prior.id);
      final full = chats;
      expect(
        identical(
          full.withChat(
            DeltaChat(key: 'g:another', members: const [], kept: true),
          ),
          full,
        ),
        isTrue,
      );
      expect(
        identical(
          full.add(
            'g:another',
            DeltaChatMessage(
              id: 'new@example.org',
              author: fp(alice),
              text: 'No room',
              at: clock,
            ),
            create: () => DeltaChat(key: 'g:another', members: const []),
          ),
          full,
        ),
        isTrue,
      );
      await receive(
        await coreMail(
          text: 'Updated',
          headers: [('Chat-Edit', '<original@example.org>')],
        ),
      );
      expect(chats.chats[fp(alice)]!.messages.single.text, 'Updated');
    },
  );

  test('old membersAt migrates into each current member clock', () {
    final legacy = DeltaChat.fromJson({
      'key': groupKey,
      'groupId': 'test-group',
      'members': [fp(alice), fp(carol)],
      'membersAt': clock.toIso8601String(),
      'messages': [],
    })!;
    expect(legacy.additionDates, {fp(alice): clock, fp(carol): clock});
  });
}

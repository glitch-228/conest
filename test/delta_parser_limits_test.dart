import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conest/src/email/imap.dart';
import 'package:conest/src/email/mail_socket.dart';
import 'package:conest/src/email/mime.dart';
import 'package:conest/src/email/openpgp.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScriptMailSocket implements MailSocket {
  _ScriptMailSocket(this.response) {
    _input.add(Uint8List.fromList(latin1.encode('* OK ready\r\n')));
  }
  final String response;
  final _input = StreamController<Uint8List>();
  @override
  Stream<Uint8List> get input => _input.stream;
  @override
  void write(List<int> bytes) {
    final tag = latin1.decode(bytes).split(' ').first;
    _input.add(
      Uint8List.fromList(latin1.encode(response.replaceAll('@TAG@', tag))),
    );
  }

  @override
  Future<void> close() => _input.close();
}

void main() {
  test(
    'mail socket counts tiny queued chunks and ignores empty chunks',
    () async {
      final input = StreamController<Uint8List>();
      final reader = MailLineReader(
        input.stream,
        maxBufferedBytes: 32,
        maxBufferedChunks: 4,
      );
      addTearDown(() async {
        await reader.cancel();
        await input.close();
      });
      for (var i = 0; i < 5; i++) {
        input.add(Uint8List(1));
      }
      await Future<void>.delayed(Duration.zero);
      await expectLater(reader.readBytes(1), throwsFormatException);
      final emptyInput = StreamController<Uint8List>();
      final emptyReader = MailLineReader(
        emptyInput.stream,
        maxBufferedBytes: 32,
        maxBufferedChunks: 4,
      );
      addTearDown(() async {
        await emptyReader.cancel();
        await emptyInput.close();
      });
      for (var i = 0; i < 100; i++) {
        emptyInput.add(Uint8List(0));
      }
      emptyInput.add(Uint8List.fromList([7]));
      await Future<void>.delayed(Duration.zero);
      expect(await emptyReader.readBytes(1), [7]);
    },
  );
  Future<ImapClient> client(String response) async {
    final socket = _ScriptMailSocket(response);
    final value = await ImapClient.connect(
      'test',
      993,
      connector: (host, port, {required tls}) async => socket,
    );
    addTearDown(value.close);
    return value;
  }

  test(
    'IMAP literal budget covers continuations before reading the next body',
    () async {
      final imap = await client(
        '* 1 FETCH (UID 1 BODY[] {4}\r\nabcd BODY[1] {4}\r\nefgh)\r\n@TAG@ OK\r\n',
      );
      await expectLater(
        imap.fetch(1, maxBytes: 4),
        throwsA(isA<ImapException>()),
      );
    },
  );
  test('IMAP literal budget covers separate responses in one command', () async {
    final imap = await client(
      '* 1 FETCH (UID 1 BODY[] {4}\r\nabcd)\r\n* 2 FETCH (UID 2 BODY[] {4}\r\nefgh)\r\n@TAG@ OK\r\n',
    );
    await expectLater(
      imap.fetch(1, maxBytes: 4),
      throwsA(isA<ImapException>()),
    );
  });
  test(
    'IMAP empty literal count and total response text are bounded',
    () async {
      final literals = await client(
        '* 1 FETCH (UID 1 BODY[] {0}\r\n${' {0}\r\n' * 17})\r\n@TAG@ OK\r\n',
      );
      await expectLater(
        literals.fetch(1, maxBytes: 1024),
        throwsA(isA<ImapException>()),
      );
      final text = await client(
        '${'* OK ${'x' * 65536}\r\n' * 17}@TAG@ OK\r\n',
      );
      await expectLater(
        text.fetch(1, maxBytes: 1024),
        throwsA(isA<ImapException>()),
      );
    },
  );
  test(
    'IMAP accepts the ordinary single body at its exact byte limit',
    () async {
      final imap = await client(
        '* 1 FETCH (UID 1 BODY[] {4}\r\nabcd)\r\n@TAG@ OK\r\n',
      );
      expect(await imap.fetch(1, maxBytes: 4), latin1.encode('abcd'));
    },
  );

  test(
    'undrained mail socket input is bounded during a storage wait',
    () async {
      final input = StreamController<Uint8List>();
      final reader = MailLineReader(input.stream, maxBufferedBytes: 32);
      addTearDown(() async {
        await reader.cancel();
        await input.close();
      });
      input.add(Uint8List(16));
      input.add(Uint8List(17));
      await Future<void>.delayed(Duration.zero);
      await expectLater(reader.readBytes(1), throwsFormatException);
    },
  );
  test(
    'mail socket cap includes pending bytes already split from a line',
    () async {
      final input = StreamController<Uint8List>();
      final reader = MailLineReader(input.stream, maxBufferedBytes: 32);
      addTearDown(() async {
        await reader.cancel();
        await input.close();
      });
      input.add(Uint8List.fromList(latin1.encode('ok\r\n${'x' * 20}')));
      expect(await reader.readLine(), 'ok');
      input.add(Uint8List(13));
      await Future<void>.delayed(Duration.zero);
      await expectLater(reader.readBytes(1), throwsFormatException);
    },
  );
  test(
    'a complete oversized server line is refused even with CRLF buffered',
    () async {
      final input = StreamController<Uint8List>();
      final reader = MailLineReader(input.stream);
      addTearDown(() async {
        await reader.cancel();
        await input.close();
      });
      input.add(
        Uint8List.fromList(
          latin1.encode('${'x' * (MailLineReader.maxLineBytes + 1)}\r\n'),
        ),
      );
      await expectLater(reader.readLine(), throwsFormatException);
    },
  );

  test('armor has byte, line and header budgets before retaining decoded chunks', () {
    final bytes = Uint8List.fromList(List.generate(256 * 1024, (i) => i % 256));
    final armored = OpenPgpArmor.encode(bytes);
    expect(OpenPgpArmor.decode(armored), bytes);
    expect(
      () => OpenPgpArmor.decode(armored, decodedLimit: 8),
      throwsFormatException,
    );
    expect(
      () => OpenPgpArmor.decode(
        '-----BEGIN PGP MESSAGE-----\n\n${'AA\n' * OpenPgpArmor.maxLines}-----END PGP MESSAGE-----\n',
      ),
      throwsFormatException,
    );
    expect(
      () => OpenPgpArmor.decode(
        '-----BEGIN PGP MESSAGE-----\n${'Version: v\n' * 65}\nAAAA\n-----END PGP MESSAGE-----\n',
      ),
      throwsFormatException,
    );
    expect(
      () => OpenPgpArmor.decode(
        '-----BEGIN PGP MESSAGE-----\n\n${'A' * 1025}\n-----END PGP MESSAGE-----\n',
      ),
      throwsFormatException,
    );
  });

  test(
    'MIME fields and folded header lines are bounded before materializing lists',
    () {
      expect(
        () => MimeHeaders.parse('X: v\n' * (MimeHeaders.maxFields + 1)),
        throwsFormatException,
      );
      expect(
        () => MimeHeaders.parse('X: v\n${' v\n' * MimeHeaders.maxLines}'),
        throwsFormatException,
      );
    },
  );
  test('MIME aggregate field budget spans all attachment leaves', () {
    final leaf = 'X: v\r\n' * 200;
    final raw =
        'Content-Type: multipart/mixed; boundary=x\r\n\r\n${'--x\r\n$leaf\r\n\r\n' * 21}--x--\r\n';
    expect(
      () => MimeEntity.parse(Uint8List.fromList(latin1.encode(raw))),
      throwsFormatException,
    );
  });
  test('MIME aggregate header bytes span all attachment leaves', () {
    final leaf = 'X: ${'v' * (250 * 1024)}\r\n';
    final raw =
        'Content-Type: multipart/mixed; boundary=x\r\n\r\n${'--x\r\n$leaf\r\n\r\n' * 5}--x--\r\n';
    expect(
      () => MimeEntity.parse(Uint8List.fromList(latin1.encode(raw))),
      throwsFormatException,
    );
  });
}

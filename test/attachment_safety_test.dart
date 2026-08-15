import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:conest/src/attachment_safety.dart';

void main() {
  test('attachment filenames remove traversal, controls, and bidi markers', () {
    final sanitized = sanitizeAttachmentFileName(
      '../folder\\evil\u202egnp.exe\u0000. ',
    );

    expect(sanitized, isNot(contains('/')));
    expect(sanitized, isNot(contains('\\')));
    expect(sanitized, isNot(contains('\u202e')));
    expect(sanitized, isNot(contains('\u0000')));
    expect(sanitized, isNot(endsWith('.')));
    expect(sanitized, isNot(endsWith(' ')));
    expect(sanitized.length, lessThanOrEqualTo(maxAttachmentFileNameLength));
  });

  test('platform-reserved and empty attachment names become safe', () {
    expect(sanitizeAttachmentFileName('CON.txt'), '_CON.txt');
    expect(sanitizeAttachmentFileName('..'), 'attachment.bin');
    expect(sanitizeAttachmentFileName('   '), 'attachment.bin');
  });

  test('logical attachment ids map to fixed SHA-256 disk names', () {
    final first = attachmentStorageKey('../../same-logical-id');
    final second = attachmentStorageKey('../../same-logical-id');
    final other = attachmentStorageKey('../../other-id');

    expect(first, hasLength(64));
    expect(first, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(second, first);
    expect(other, isNot(first));
  });

  test('path containment rejects escaped siblings on every platform style', () {
    final root = p.join(Directory.systemTemp.path, 'conest-root');
    expect(isContainedPath(root, p.join(root, 'safe.bin')), isTrue);
    expect(isContainedPath(root, p.join(root, '..', 'escaped.bin')), isFalse);
  });

  test('attachment MIME validation is bounded and syntactic', () {
    expect(isValidAttachmentMimeType('image/png'), isTrue);
    expect(isValidAttachmentMimeType('application/octet-stream'), isTrue);
    expect(isValidAttachmentMimeType('../evil'), isFalse);
    expect(isValidAttachmentMimeType('text/plain\nX-Evil: yes'), isFalse);
    expect(
      sanitizeAttachmentMimeType('not a mime'),
      'application/octet-stream',
    );
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const int maxAttachmentFileNameLength = 120;

final RegExp _mimePattern = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}$',
);

String attachmentStorageKey(String logicalId) =>
    sha256.convert(utf8.encode(logicalId)).toString();

String sanitizeAttachmentFileName(String input) {
  var value = input
      .replaceAll(RegExp(r'[/\\]+'), '_')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
      .replaceAll(RegExp(r'[\u202a-\u202e\u2066-\u2069]'), '')
      .replaceAll(RegExp(r'[<>:"|?*]'), '_')
      .trim();
  value = value.replaceFirst(RegExp(r'^[. ]+'), '');
  value = value.replaceFirst(RegExp(r'[. ]+$'), '');
  if (value.isEmpty || value == '.' || value == '..') {
    value = 'attachment.bin';
  }
  final dot = value.lastIndexOf('.');
  final stem = (dot > 0 ? value.substring(0, dot) : value).trim();
  final extension = dot > 0 ? value.substring(dot) : '';
  const reserved = <String>{
    'con',
    'prn',
    'aux',
    'nul',
    'com1',
    'com2',
    'com3',
    'com4',
    'com5',
    'com6',
    'com7',
    'com8',
    'com9',
    'lpt1',
    'lpt2',
    'lpt3',
    'lpt4',
    'lpt5',
    'lpt6',
    'lpt7',
    'lpt8',
    'lpt9',
  };
  if (reserved.contains(stem.toLowerCase())) {
    value = '_$value';
  }
  if (value.length > maxAttachmentFileNameLength) {
    final keepExtension = extension.length <= 20 ? extension : '';
    final maxStem = maxAttachmentFileNameLength - keepExtension.length;
    value = '${value.substring(0, maxStem)}$keepExtension';
  }
  return value;
}

bool isValidAttachmentMimeType(String input) =>
    input.length <= 128 && _mimePattern.hasMatch(input);

String sanitizeAttachmentMimeType(String input) {
  final value = input.trim().toLowerCase();
  return isValidAttachmentMimeType(value) ? value : 'application/octet-stream';
}

bool isContainedPath(String parentDirectory, String candidate) {
  final parent = p.normalize(p.absolute(parentDirectory));
  final child = p.normalize(p.absolute(candidate));
  return p.equals(parent, child) || p.isWithin(parent, child);
}

Future<void> restrictFileToOwner(File file) async {
  if (!Platform.isLinux && !Platform.isMacOS) return;
  final result = await Process.run('chmod', <String>['600', file.path]);
  if (result.exitCode != 0) {
    throw FileSystemException(
      'Could not restrict attachment permissions.',
      file.path,
    );
  }
}

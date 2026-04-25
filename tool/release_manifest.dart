import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

const _manifestName = 'RELEASE-MANIFEST.json';
const _signatureName = 'RELEASE-MANIFEST.ed25519.sig';
const _checksumName = 'SHA256SUMS.txt';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    stderr.writeln(
      'usage: dart run tool/release_manifest.dart <tag> [asset ...]\n'
      '\n'
      'Set CONEST_RELEASE_MANIFEST_PRIVATE_KEY to a base64 Ed25519 seed.\n'
      'If no assets are listed, every file in dist/ except release metadata is included.',
    );
    exit(args.isEmpty ? 2 : 0);
  }

  final tagName = args.first;
  final distDir = Directory('dist');
  if (!await distDir.exists()) {
    stderr.writeln('dist/ does not exist.');
    exit(2);
  }
  final privateSeedText =
      Platform.environment['CONEST_RELEASE_MANIFEST_PRIVATE_KEY']?.trim() ?? '';
  if (privateSeedText.isEmpty) {
    stderr.writeln('CONEST_RELEASE_MANIFEST_PRIVATE_KEY is required.');
    exit(2);
  }
  final privateSeed = _decodeBase64Flexible(privateSeedText);
  if (privateSeed.length != 32) {
    stderr.writeln(
      'CONEST_RELEASE_MANIFEST_PRIVATE_KEY must decode to 32 bytes.',
    );
    exit(2);
  }

  final assetFiles = args.length > 1
      ? args.skip(1).map((name) => File('dist/$name')).toList()
      : await distDir
            .list()
            .where((entry) => entry is File)
            .cast<File>()
            .where((file) => !_isReleaseMetadata(file.uri.pathSegments.last))
            .toList();
  assetFiles.sort((left, right) => left.path.compareTo(right.path));
  if (assetFiles.isEmpty) {
    stderr.writeln('No release assets found.');
    exit(2);
  }
  for (final file in assetFiles) {
    if (!await file.exists()) {
      stderr.writeln('Missing asset: ${file.path}');
      exit(2);
    }
  }

  final manifest = {
    'version': 1,
    'tagName': tagName,
    'assets': [
      for (final file in assetFiles)
        {
          'name': file.uri.pathSegments.last,
          'sha256': sha256.convert(await file.readAsBytes()).toString(),
          'sizeBytes': await file.length(),
        },
    ],
  };
  final manifestBytes = utf8.encode(
    const JsonEncoder.withIndent('  ').convert(manifest),
  );
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(privateSeed);
  final signature = await algorithm.sign(manifestBytes, keyPair: keyPair);
  final publicKey = await keyPair.extractPublicKey();

  await File('dist/$_manifestName').writeAsBytes(manifestBytes, flush: true);
  await File(
    'dist/$_signatureName',
  ).writeAsString('${base64Encode(signature.bytes)}\n', flush: true);
  await _writeSha256Sums(distDir);

  stdout.writeln('Wrote dist/$_manifestName');
  stdout.writeln('Wrote dist/$_signatureName');
  stdout.writeln('Wrote dist/$_checksumName');
  stdout.writeln(
    'CONEST_RELEASE_MANIFEST_PUBLIC_KEY=${base64Encode(publicKey.bytes)}',
  );
}

bool _isReleaseMetadata(String name) {
  return name == _manifestName ||
      name == _signatureName ||
      name == _checksumName;
}

Future<void> _writeSha256Sums(Directory distDir) async {
  final files = await distDir
      .list()
      .where((entry) => entry is File)
      .cast<File>()
      .where((file) => file.uri.pathSegments.last != _checksumName)
      .toList();
  files.sort((left, right) => left.path.compareTo(right.path));
  final lines = <String>[];
  for (final file in files) {
    final name = file.uri.pathSegments.last;
    final digest = sha256.convert(await file.readAsBytes()).toString();
    lines.add('$digest  $name');
  }
  await File('dist/$_checksumName').writeAsString('${lines.join('\n')}\n');
}

List<int> _decodeBase64Flexible(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), '');
  try {
    return base64Decode(normalized);
  } on FormatException {
    return base64Url.decode(base64Url.normalize(normalized));
  }
}

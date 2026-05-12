import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

const _manifestName = 'RELEASE-MANIFEST.json';
const _signatureName = 'RELEASE-MANIFEST.ed25519.sig';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stderr.writeln(
      'usage: dart run tool/verify_release_manifest.dart [--dist <dir>] '
      '[--public-key <base64>]\n'
      '\n'
      'If --public-key is omitted, CONEST_RELEASE_MANIFEST_PUBLIC_KEY is used.\n'
      'Verifies the manifest signature and that every listed asset matches the '
      'recorded sha256 and size on disk.',
    );
    exit(0);
  }

  var distPath = 'dist';
  String? publicKeyText;
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (arg == '--dist') {
      index++;
      if (index >= args.length) {
        stderr.writeln('--dist requires a directory.');
        exit(2);
      }
      distPath = args[index];
    } else if (arg.startsWith('--dist=')) {
      distPath = arg.substring('--dist='.length);
    } else if (arg == '--public-key') {
      index++;
      if (index >= args.length) {
        stderr.writeln('--public-key requires a value.');
        exit(2);
      }
      publicKeyText = args[index];
    } else if (arg.startsWith('--public-key=')) {
      publicKeyText = arg.substring('--public-key='.length);
    } else {
      stderr.writeln('Unknown argument: $arg');
      exit(2);
    }
  }

  publicKeyText ??=
      Platform.environment['CONEST_RELEASE_MANIFEST_PUBLIC_KEY']?.trim();
  if (publicKeyText == null || publicKeyText.isEmpty) {
    stderr.writeln(
      'Public key is required (pass --public-key or set '
      'CONEST_RELEASE_MANIFEST_PUBLIC_KEY).',
    );
    exit(2);
  }

  final distDir = Directory(distPath);
  final manifestFile = File('${distDir.path}/$_manifestName');
  final signatureFile = File('${distDir.path}/$_signatureName');
  if (!await manifestFile.exists()) {
    stderr.writeln('Missing $_manifestName in ${distDir.path}.');
    exit(2);
  }
  if (!await signatureFile.exists()) {
    stderr.writeln('Missing $_signatureName in ${distDir.path}.');
    exit(2);
  }

  final manifestBytes = await manifestFile.readAsBytes();
  final signatureBytes = _decodeBase64Flexible(
    (await signatureFile.readAsString()).trim(),
  );
  final publicKeyBytes = _decodeBase64Flexible(publicKeyText.trim());

  final algorithm = Ed25519();
  final verified = await algorithm.verify(
    manifestBytes,
    signature: Signature(
      signatureBytes,
      publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
    ),
  );
  if (!verified) {
    stderr.writeln('Signature verification FAILED.');
    exit(1);
  }
  stdout.writeln('Signature OK.');

  final decoded = jsonDecode(utf8.decode(manifestBytes));
  if (decoded is! Map<String, dynamic>) {
    stderr.writeln('Manifest is not a JSON object.');
    exit(1);
  }
  final assets = decoded['assets'];
  if (assets is! List) {
    stderr.writeln('Manifest assets must be a list.');
    exit(1);
  }

  var ok = true;
  for (final entry in assets) {
    if (entry is! Map) {
      stderr.writeln('Manifest asset entry is not an object: $entry');
      ok = false;
      continue;
    }
    final name = entry['name'] as String?;
    final expectedSha = (entry['sha256'] as String?)?.toLowerCase();
    final expectedSize = entry['sizeBytes'] as int?;
    if (name == null || expectedSha == null) {
      stderr.writeln('Manifest asset entry missing name/sha256: $entry');
      ok = false;
      continue;
    }
    final assetFile = File('${distDir.path}/$name');
    if (!await assetFile.exists()) {
      stderr.writeln('Missing asset on disk: $name');
      ok = false;
      continue;
    }
    final actualBytes = await assetFile.readAsBytes();
    final actualSha = sha256.convert(actualBytes).toString();
    if (actualSha != expectedSha) {
      stderr.writeln(
        'SHA256 mismatch for $name: expected $expectedSha got $actualSha',
      );
      ok = false;
      continue;
    }
    if (expectedSize != null && expectedSize != actualBytes.length) {
      stderr.writeln(
        'Size mismatch for $name: expected $expectedSize got ${actualBytes.length}',
      );
      ok = false;
      continue;
    }
    stdout.writeln('OK $name');
  }
  if (!ok) {
    exit(1);
  }
}

List<int> _decodeBase64Flexible(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), '');
  try {
    return base64Decode(normalized);
  } on FormatException {
    return base64Url.decode(base64Url.normalize(normalized));
  }
}

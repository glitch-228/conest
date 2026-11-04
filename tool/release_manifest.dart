import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import 'release_channel_lib.dart';

const _checksumName = 'SHA256SUMS.txt';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    stderr.writeln(
      'usage: dart run tool/release_manifest.dart [--dist <dir>] '
      '--channel <stable|nightly|canary> [--android-version-code <n>] '
      '[--release-notes <path>] <tag> [asset ...]\n'
      '\n'
      '--channel must equal what tool/release_channel.sh says for the tag.\n'
      '\n'
      'Set CONEST_RELEASE_MANIFEST_PRIVATE_KEY to a base64 Ed25519 seed.\n'
      'If no assets are listed, every file in the dist dir except release metadata is included.\n'
      '--release-notes <path>: optional UTF-8 text file. When passed, the\n'
      '  contents are embedded as the manifest\'s signed `releaseNotes` field.',
    );
    exit(args.isEmpty ? 2 : 0);
  }

  var distPath = 'dist';
  String? channelArg;
  int? androidVersionCode;
  String? releaseNotesPath;
  final positional = <String>[];
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
    } else if (arg == '--channel') {
      index++;
      channelArg = index < args.length ? args[index] : null;
    } else if (arg.startsWith('--channel=')) {
      channelArg = arg.substring('--channel='.length);
    } else if (arg == '--android-version-code') {
      index++;
      androidVersionCode = index < args.length
          ? int.tryParse(args[index])
          : null;
      if (androidVersionCode == null || androidVersionCode <= 0) {
        stderr.writeln('--android-version-code requires a positive number.');
        exit(2);
      }
    } else if (arg == '--release-notes') {
      index++;
      if (index >= args.length) {
        stderr.writeln('--release-notes requires a path.');
        exit(2);
      }
      releaseNotesPath = args[index];
    } else if (arg.startsWith('--release-notes=')) {
      releaseNotesPath = arg.substring('--release-notes='.length);
    } else {
      positional.add(arg);
    }
  }
  if (positional.isEmpty) {
    stderr.writeln('Missing release tag.');
    exit(2);
  }

  final tagName = positional.first;
  if (channelArg == null) {
    stderr.writeln('--channel is required.');
    exit(2);
  }
  // The signed channel is the tag's own, by the one rule the workflow uses.
  await requireChannelOfTag(channelArg, tagName);
  final channel = channelArg;
  final names = manifestNamesFor(channel);
  final manifestName = names.manifest;
  final signatureName = names.signature;
  final distDir = Directory(distPath);
  if (!await distDir.exists()) {
    stderr.writeln('${distDir.path} does not exist.');
    exit(2);
  }
  // A canary release never carries the standard pair, nor the others the
  // canary pair.
  final otherNames = manifestNamesFor(
    channel == 'canary' ? 'stable' : 'canary',
  );
  for (final other in [otherNames.manifest, otherNames.signature]) {
    if (await File('${distDir.path}/$other').exists()) {
      stderr.writeln(
        '${distDir.path}/$other does not belong in a $channel release.',
      );
      exit(2);
    }
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

  final assetFiles = positional.length > 1
      ? positional.skip(1).map((name) => File('${distDir.path}/$name')).toList()
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

  String? releaseNotesText;
  if (releaseNotesPath != null) {
    final notesFile = File(releaseNotesPath);
    if (!await notesFile.exists()) {
      stderr.writeln('Release notes file not found: ${notesFile.path}');
      exit(2);
    }
    final raw = await notesFile.readAsString();
    if (raw.trim().isNotEmpty) {
      releaseNotesText = raw;
    }
  }

  final manifest = <String, dynamic>{
    // Keep the v1 wire discriminator for the first additive-schema rollout.
    // Existing updaters ignore the new signed fields; current ones require and
    // validate them. A future release can cut over to the v2 discriminator.
    'version': 1,
    'tagName': tagName,
    'releaseVersion': tagName.startsWith('v') ? tagName.substring(1) : tagName,
    'channel': channel,
    'minimumSupervisorVersion':
        Platform.environment['CONEST_MINIMUM_SUPERVISOR_VERSION']?.trim() ??
        '0.1.0',
    'androidVersionCode': ?androidVersionCode,
    'releaseNotes': ?releaseNotesText,
    'assets': [
      for (final file in assetFiles)
        {
          'name': file.uri.pathSegments.last,
          'sha256': sha256.convert(await file.readAsBytes()).toString(),
          'sizeBytes': await file.length(),
          ..._assetTarget(file.uri.pathSegments.last),
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

  await File(
    '${distDir.path}/$manifestName',
  ).writeAsBytes(manifestBytes, flush: true);
  await File(
    '${distDir.path}/$signatureName',
  ).writeAsString('${base64Encode(signature.bytes)}\n', flush: true);
  await _writeSha256Sums(distDir);

  stdout.writeln('Wrote ${distDir.path}/$manifestName');
  stdout.writeln('Wrote ${distDir.path}/$signatureName');
  stdout.writeln('Wrote ${distDir.path}/$_checksumName');
  stdout.writeln(
    'CONEST_RELEASE_MANIFEST_PUBLIC_KEY=${base64Encode(publicKey.bytes)}',
  );
}

Map<String, String> _assetTarget(String name) {
  final lower = name.toLowerCase();
  final role =
      lower.contains('relay-supervisor') || lower.contains('relay_supervisor')
      ? 'relay-supervisor'
      : lower.contains('conest-relay') || lower.contains('conest_relay')
      ? 'relay'
      : lower.contains('updater')
      ? 'app-updater'
      : 'app';
  final platform = lower.contains('windows') || lower.endsWith('.exe')
      ? 'windows'
      : lower.contains('android') || lower.endsWith('.apk')
      ? 'android'
      : lower.contains('linux')
      ? 'linux'
      : 'any';
  final architecture = lower.contains('arm64') || lower.contains('aarch64')
      ? 'arm64'
      : lower.contains('x64') || lower.contains('x86_64')
      ? 'x86_64'
      : 'any';
  return {'role': role, 'platform': platform, 'architecture': architecture};
}

bool _isReleaseMetadata(String name) {
  return allManifestNames().contains(name) || name == _checksumName;
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
  await File(
    '${distDir.path}/$_checksumName',
  ).writeAsString('${lines.join('\n')}\n');
}

List<int> _decodeBase64Flexible(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), '');
  try {
    return base64Decode(normalized);
  } on FormatException {
    return base64Url.decode(base64Url.normalize(normalized));
  }
}

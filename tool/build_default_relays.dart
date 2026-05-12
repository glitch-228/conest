import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

const _defaultInput = 'tool/default_relays.input.json';
const _defaultManifest = 'assets/default_relays.json';
const _defaultSignature = 'assets/default_relays.ed25519.sig';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stderr.writeln(
      'usage: dart run tool/build_default_relays.dart '
      '[--input <path>] [--manifest <path>] [--signature <path>]\n'
      '\n'
      'Set CONEST_DEFAULT_RELAYS_PRIVATE_KEY to a base64 Ed25519 seed.\n'
      'If unset, a fresh dev keypair is generated and its public key is printed.',
    );
    exit(0);
  }

  var inputPath = _defaultInput;
  var manifestPath = _defaultManifest;
  var signaturePath = _defaultSignature;
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    String? pickValue(String flag) {
      if (arg == flag) {
        if (index + 1 >= args.length) {
          stderr.writeln('$flag requires a path.');
          exit(2);
        }
        return args[++index];
      }
      if (arg.startsWith('$flag=')) {
        return arg.substring(flag.length + 1);
      }
      return null;
    }

    final input = pickValue('--input');
    if (input != null) {
      inputPath = input;
      continue;
    }
    final manifest = pickValue('--manifest');
    if (manifest != null) {
      manifestPath = manifest;
      continue;
    }
    final signature = pickValue('--signature');
    if (signature != null) {
      signaturePath = signature;
      continue;
    }
    stderr.writeln('Unknown argument: $arg');
    exit(2);
  }

  final inputFile = File(inputPath);
  if (!await inputFile.exists()) {
    stderr.writeln('Input not found: ${inputFile.path}');
    exit(2);
  }
  final inputJson = await inputFile.readAsString();
  final Object? parsed;
  try {
    parsed = jsonDecode(inputJson);
  } on FormatException catch (error) {
    stderr.writeln('Input is not valid JSON: $error');
    exit(2);
  }
  if (parsed is! Map<String, dynamic>) {
    stderr.writeln('Input must be a JSON object.');
    exit(2);
  }
  if (parsed['version'] is! num) {
    stderr.writeln('Input must include an integer "version".');
    exit(2);
  }
  if (parsed['issuedAt'] is! String ||
      DateTime.tryParse(parsed['issuedAt'] as String) == null) {
    stderr.writeln('Input must include an ISO-8601 "issuedAt".');
    exit(2);
  }
  if (parsed['endpoints'] is! List) {
    stderr.writeln('Input must include an "endpoints" array.');
    exit(2);
  }

  final algorithm = Ed25519();
  final seedText =
      Platform.environment['CONEST_DEFAULT_RELAYS_PRIVATE_KEY']?.trim() ?? '';
  final SimpleKeyPair keyPair;
  if (seedText.isEmpty) {
    keyPair = await algorithm.newKeyPair();
    stderr.writeln(
      'CONEST_DEFAULT_RELAYS_PRIVATE_KEY not set — generated a dev keypair.',
    );
  } else {
    final List<int> seed;
    try {
      seed = base64Decode(seedText);
    } on FormatException catch (error) {
      stderr.writeln('CONEST_DEFAULT_RELAYS_PRIVATE_KEY is not base64: $error');
      exit(2);
    }
    if (seed.length != 32) {
      stderr.writeln(
        'CONEST_DEFAULT_RELAYS_PRIVATE_KEY must decode to 32 bytes.',
      );
      exit(2);
    }
    keyPair = await algorithm.newKeyPairFromSeed(seed);
  }

  final manifestBytes = utf8.encode(
    const JsonEncoder.withIndent('  ').convert(parsed),
  );
  final signature = await algorithm.sign(manifestBytes, keyPair: keyPair);
  final publicKey = await keyPair.extractPublicKey();

  final manifestFile = File(manifestPath);
  final signatureFile = File(signaturePath);
  await manifestFile.create(recursive: true);
  await signatureFile.create(recursive: true);
  await manifestFile.writeAsBytes(manifestBytes, flush: true);
  await signatureFile.writeAsString(
    '${base64Encode(signature.bytes)}\n',
    flush: true,
  );

  stdout.writeln('Wrote ${manifestFile.path}');
  stdout.writeln('Wrote ${signatureFile.path}');
  stdout.writeln(
    'CONEST_DEFAULT_RELAYS_PUBLIC_KEY=${base64Encode(publicKey.bytes)}',
  );
}

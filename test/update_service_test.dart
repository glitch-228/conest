import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:conest/src/build_info.dart';
import 'package:conest/src/platform_bridge.dart';
import 'package:conest/src/update_service.dart';

class _FakePlatformBridge extends PlatformBridge {
  String? installedApkPath;
  bool failInstall = false;

  @override
  Future<void> installDownloadedApk(String path) async {
    if (failInstall) throw StateError('No installer.');
    installedApkPath = path;
  }
}

class _ManifestSigner {
  _ManifestSigner._(this._algorithm, this._keyPair, this.publicKeyBase64);

  final Ed25519 _algorithm;
  final KeyPair _keyPair;
  final String publicKeyBase64;

  static Future<_ManifestSigner> create() async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return _ManifestSigner._(algorithm, keyPair, base64Encode(publicKey.bytes));
  }

  Future<_ManifestFiles> sign({
    required String tagName,
    required Map<String, _ManifestAssetFixture> assets,
    // What the real release tool signs: the channel and the release version
    // (derived from the tag unless a test wants a wrong one).
    String? channel,
    String? releaseVersion,
    bool omitChannel = false,
    int? androidVersionCode,
  }) async {
    final manifest = jsonEncode({
      'version': 1,
      'tagName': tagName,
      'releaseVersion':
          releaseVersion ??
          (tagName.startsWith('v') ? tagName.substring(1) : tagName),
      if (!omitChannel) 'channel': channel ?? _channelOfTag(tagName),
      'minimumSupervisorVersion': '0.1.0',
      'androidVersionCode': ?androidVersionCode,
      'assets': [
        for (final entry in assets.entries)
          {
            'name': entry.key,
            'sha256': entry.value.sha256Hex,
            'sizeBytes': entry.value.sizeBytes,
          },
      ],
    });
    final manifestBytes = utf8.encode(manifest);
    final signature = await _algorithm.sign(manifestBytes, keyPair: _keyPair);
    return _ManifestFiles(
      manifestBytes: manifestBytes,
      signatureText: base64Encode(signature.bytes),
    );
  }
}

String _channelOfTag(String tag) => tag.contains('-canary.')
    ? 'canary'
    : tag.contains('nightly')
    ? 'nightly'
    : 'stable';

class _ManifestAssetFixture {
  const _ManifestAssetFixture({
    required this.sha256Hex,
    required this.sizeBytes,
  });

  final String sha256Hex;
  final int sizeBytes;
}

class _ManifestFiles {
  const _ManifestFiles({
    required this.manifestBytes,
    required this.signatureText,
  });

  final List<int> manifestBytes;
  final String signatureText;
}

List<int> _zipBytes(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive);
}

Map<String, dynamic> _assetJson({
  required String name,
  required String baseUrl,
  required String path,
  required int size,
}) {
  return {'name': name, 'browser_download_url': '$baseUrl$path', 'size': size};
}

List<Map<String, dynamic>> _releaseTrustAssets({
  required String baseUrl,
  required _ManifestFiles files,
  String manifestPath = '/RELEASE-MANIFEST.json',
  String signaturePath = '/RELEASE-MANIFEST.ed25519.sig',
  // Canary releases carry their own pair of names, and not the standard one.
  bool canary = false,
}) {
  return [
    _assetJson(
      name: 'SHA256SUMS.txt',
      baseUrl: baseUrl,
      path: '/SHA256SUMS.txt',
      size: 128,
    ),
    _assetJson(
      name: canary ? 'RELEASE-MANIFEST.canary.json' : 'RELEASE-MANIFEST.json',
      baseUrl: baseUrl,
      path: manifestPath,
      size: files.manifestBytes.length,
    ),
    _assetJson(
      name: canary
          ? 'RELEASE-MANIFEST.canary.ed25519.sig'
          : 'RELEASE-MANIFEST.ed25519.sig',
      baseUrl: baseUrl,
      path: signaturePath,
      size: files.signatureText.length,
    ),
  ];
}

List<Map<String, dynamic>> _trustAssetsFor(
  String tag,
  String? style,
  String baseUrl,
  _ManifestFiles files,
) {
  List<Map<String, dynamic>> pair(bool canary) => _releaseTrustAssets(
    baseUrl: baseUrl,
    files: files,
    manifestPath: '/$tag-manifest.json',
    signaturePath: '/$tag-manifest.sig',
    canary: canary,
  );
  final own = tag.contains('-canary.');
  final assets = switch (style) {
    'canary' => pair(true),
    'standard' => pair(false),
    'both' => [...pair(true), ...pair(false)],
    'no-signature' => [
      for (final asset in pair(own))
        if (!(asset['name'] as String).endsWith('.sig')) asset,
    ],
    _ => pair(own),
  };
  // The checksum file is the same in both pairs.
  final seen = <String>{};
  return [
    for (final asset in assets)
      if (seen.add(asset['name'] as String)) asset,
  ];
}

/// Metadata of the last request to the fake release list.
class _ReleaseServerLog {
  final List<String> listQueries = [];
}

/// A GitHub-style release object as the real API sends it: each asset with
/// its uploader and counters, so a release is about 25 KB like the real
/// ones (a list of 100 would exceed the updater's metadata cap).
Map<String, dynamic> _realisticAsset(Map<String, dynamic> asset, int id) => {
  ...asset,
  'url': 'https://api.example.invalid/repos/glitch-228/conest/assets/$id',
  'id': id,
  'node_id': 'RA_kwDOExampleExampleExample$id',
  'label': null,
  'uploader': {
    for (final key in [
      'login',
      'node_id',
      'avatar_url',
      'gravatar_id',
      'url',
      'html_url',
      'followers_url',
      'following_url',
      'gists_url',
      'starred_url',
      'subscriptions_url',
      'organizations_url',
      'repos_url',
      'events_url',
      'received_events_url',
    ])
      key: 'https://api.example.invalid/users/github-actions%5Bbot%5D/$key',
    'id': 41898282,
    'type': 'Bot',
    'site_admin': false,
  },
  'content_type': 'application/octet-stream',
  'state': 'uploaded',
  'download_count': 1234,
  'created_at': '2026-10-06T10:00:00Z',
  'updated_at': '2026-10-06T10:00:00Z',
};

/// Serves signed GitHub-style releases for Linux; returns the API base URL.
///
/// As strict as GitHub where the updater depends on it: the list is newest
/// first (the order given), pages hold `per_page` entries (default 30, at
/// most 100), canary releases carry only the `.canary.` manifest pair and
/// the others only the standard pair, and every release object has
/// realistic size.
Future<String> _serveReleases(
  _ManifestSigner signer,
  List<(String tag, bool prerelease)> releases, {
  _ReleaseServerLog? log,
  Map<String, _ManifestFiles>? overrides,
  // Per tag: which manifest file names the release carries instead of the
  // right ones: 'canary', 'standard', 'both' or 'no-signature'.
  Map<String, String> pairStyle = const {},
  // Per tag: the Android versionCode signed into the manifest.
  Map<String, int> androidCodes = const {},
  // The release list is answered only once this completes.
  Future<void>? listGate,
  // Downloads of the app files are answered only once this completes.
  Future<void>? downloadGate,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final baseUrl = 'http://${server.address.host}:${server.port}';
  final files = <String, _ManifestFiles>{};
  for (final (tag, _) in releases) {
    files[tag] =
        overrides?[tag] ??
        await signer.sign(
          tagName: tag,
          androidVersionCode: androidCodes[tag],
          assets: {
            'conest-linux-x64-$tag.zip': _ManifestAssetFixture(
              sha256Hex: 'e' * 64,
              sizeBytes: 10,
            ),
            'conest-android-arm64-$tag.apk': _ManifestAssetFixture(
              sha256Hex: 'e' * 64,
              sizeBytes: 10,
            ),
          },
        );
  }
  server.listen((request) async {
    final path = request.uri.path;
    if (path == '/repos/glitch-228/conest/releases') {
      log?.listQueries.add(request.uri.query);
      await listGate;
      final perPage =
          (int.tryParse(request.uri.queryParameters['per_page'] ?? '') ?? 30)
              .clamp(1, 100);
      var nextId = 1;
      request.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode([
            for (final (tag, prerelease) in releases.take(perPage))
              {
                'tag_name': tag,
                'name': tag,
                'html_url': 'https://example.invalid/$tag',
                'published_at': '2026-10-06T10:00:00Z',
                'prerelease': prerelease,
                'draft': false,
                'assets': [
                  for (final asset in [
                    _assetJson(
                      name: 'conest-linux-x64-$tag.zip',
                      baseUrl: baseUrl,
                      path: '/$tag.zip',
                      size: 10,
                    ),
                    _assetJson(
                      name: 'conest-android-arm64-$tag.apk',
                      baseUrl: baseUrl,
                      path: '/$tag.apk',
                      size: 10,
                    ),
                    ..._trustAssetsFor(
                      tag,
                      pairStyle[tag],
                      baseUrl,
                      files[tag]!,
                    ),
                    // The rest of a real release.
                    for (final name in [
                      'conest-windows-x64-portable-$tag.zip',
                      'conest_relay-linux-x64-$tag',
                      'conest_relay-linux-arm64-$tag',
                      'conest_relay-windows-x64-$tag.exe',
                      'conest_updater-linux-x64-$tag',
                      'conest_updater-windows-x64-$tag.exe',
                      'conest_relay_supervisor-linux-x64-$tag',
                      'conest_relay_supervisor-linux-arm64-$tag',
                      'conest_relay_supervisor-windows-x64-$tag.exe',
                      'install-relay.sh',
                    ])
                      _assetJson(
                        name: name,
                        baseUrl: baseUrl,
                        path: '/other/$name',
                        size: 12345,
                      ),
                  ])
                    _realisticAsset(asset, nextId++),
                ],
                'body': 'Changes since the last release.\n' * 4,
              },
          ]),
        );
    } else if (path.endsWith('.apk') || path.endsWith('.zip')) {
      await downloadGate;
      request.response.add(List<int>.filled(10, 1));
    } else if (path.endsWith('-manifest.json')) {
      request.response.add(
        files[path.substring(1, path.length - 14)]!.manifestBytes,
      );
    } else if (path.endsWith('-manifest.sig')) {
      request.response.write(
        files[path.substring(1, path.length - 13)]!.signatureText,
      );
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  });
  return baseUrl;
}

UpdateService _serviceFor({
  required String baseUrl,
  required _ManifestSigner signer,
  required UpdateChannel channel,
  required String buildTag,
  required Directory support,
  UpdateTargetPlatform platform = UpdateTargetPlatform.linux,
  String buildNumber = '1',
  String? publicKey,
}) => UpdateService(
  buildInfo: ConestBuildInfo(
    appName: 'Conest',
    packageName: 'dev.conest.conest',
    version: buildTag.substring(1).split('-').first,
    buildNumber: buildNumber,
    channel: channel,
    isDebugBuild: false,
    buildTag: buildTag,
  ),
  targetPlatform: platform,
  apiBaseUri: Uri.parse(baseUrl),
  releaseManifestPublicKeyBase64: publicKey ?? signer.publicKeyBase64,
  applicationSupportDirectoryProvider: () async => support,
  tempDirectoryProvider: () async =>
      await Directory.systemTemp.createTemp('conest-updates-temp'),
  exitCallback: (_) {},
);

void main() {
  test('stable installs get nightlies only when they ask for them', () async {
    final signer = await _ManifestSigner.create();
    final baseUrl = await _serveReleases(signer, [
      ('v0.3.12-nightly.20261007.1', true),
      ('v0.3.11', false),
    ]);
    final support = await Directory.systemTemp.createTemp('conest-upd-');
    addTearDown(() => support.delete(recursive: true));
    final service = _serviceFor(
      baseUrl: baseUrl,
      signer: signer,
      channel: UpdateChannel.stable,
      buildTag: 'v0.3.10',
      support: support,
    );
    expect(service.receiveUnstableUpdates, isFalse);
    expect(await service.checkForUpdate(userInitiated: true), isTrue);
    expect(service.availableUpdate?.release.tagName, 'v0.3.11');

    await service.setReceiveUnstableUpdates(true);
    expect(
      service.availableUpdate?.release.tagName,
      'v0.3.12-nightly.20261007.1',
    );
    // The choice is kept for the next start.
    final restarted = _serviceFor(
      baseUrl: baseUrl,
      signer: signer,
      channel: UpdateChannel.stable,
      buildTag: 'v0.3.10',
      support: support,
    );
    await restarted.loadPreferences();
    expect(restarted.receiveUnstableUpdates, isTrue);
  });

  test('nightly installs can always move to a newer stable release', () async {
    final signer = await _ManifestSigner.create();
    final baseUrl = await _serveReleases(signer, [
      ('v0.3.11-nightly.20261006.1', true),
      ('v0.3.11', false),
    ]);
    final support = await Directory.systemTemp.createTemp('conest-upd-');
    addTearDown(() => support.delete(recursive: true));
    final service = _serviceFor(
      baseUrl: baseUrl,
      signer: signer,
      channel: UpdateChannel.nightly,
      buildTag: 'v0.3.11-nightly.20261005.1',
      support: support,
    );
    // Nightlies are on by default, and the stable release is newer.
    expect(service.receiveUnstableUpdates, isTrue);
    expect(await service.checkForUpdate(userInitiated: true), isTrue);
    expect(service.availableUpdate?.release.tagName, 'v0.3.11');
    // With nightlies turned off, stable is still offered.
    await service.setReceiveUnstableUpdates(false);
    expect(service.availableUpdate?.release.tagName, 'v0.3.11');
    // The nightly default was saved on first use, so after moving to the
    // stable release the install keeps receiving nightlies until turned off.
    final firstUse = await Directory.systemTemp.createTemp('conest-upd-');
    addTearDown(() => firstUse.delete(recursive: true));
    await _serviceFor(
      baseUrl: baseUrl,
      signer: signer,
      channel: UpdateChannel.nightly,
      buildTag: 'v0.3.11-nightly.20261005.1',
      support: firstUse,
    ).loadPreferences();
    final asStable = _serviceFor(
      baseUrl: baseUrl,
      signer: signer,
      channel: UpdateChannel.stable,
      buildTag: 'v0.3.11',
      support: firstUse,
    );
    await asStable.loadPreferences();
    expect(asStable.receiveUnstableUpdates, isTrue);
  });

  test('nightly updates prefer signed manifest notes over release body', () {
    expect(
      resolveReleaseNotes(
        manifestNotes: 'Signed attachment migration warning.',
        releaseBody: 'Unsigned release body.',
      ),
      'Signed attachment migration warning.',
    );
  });

  test('automatic startup checks can be disabled for ghost mode', () async {
    var requestCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    unawaited(
      server.listen((request) async {
        requestCount++;
        request.response.statusCode = HttpStatus.ok;
        request.response.write('[]');
        await request.response.close();
      }).asFuture<void>(),
    );

    final service = UpdateService(
      buildInfo: ConestBuildInfo(
        appName: 'Conest',
        packageName: 'dev.conest.conest',
        version: '0.0.9',
        buildNumber: '1',
        channel: UpdateChannel.stable,
        isDebugBuild: true,
      ),
      targetPlatform: UpdateTargetPlatform.linux,
      apiBaseUri: Uri.parse('http://${server.address.host}:${server.port}'),
      automaticStartupChecksEnabled: false,
      exitCallback: (_) {},
    );

    await service.ensureStartupCheck();

    expect(service.lastCheckedAt, isNull);
    expect(requestCount, 0);
  });

  test('stable channel selects the newest non-prerelease release', () async {
    final signer = await _ManifestSigner.create();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final baseUrl = 'http://${server.address.host}:${server.port}';
    final stableFiles = await signer.sign(
      tagName: 'v0.1.0',
      assets: const {
        'conest-linux-x64-v0.1.0.zip': _ManifestAssetFixture(
          sha256Hex:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          sizeBytes: 10,
        ),
      },
    );
    final nightlyFiles = await signer.sign(
      tagName: 'v0.1.0-nightly.20260422.2',
      assets: const {
        'conest-linux-x64-debug-v0.1.0-nightly.20260422.2.zip':
            _ManifestAssetFixture(
              sha256Hex:
                  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
              sizeBytes: 10,
            ),
      },
    );
    server.listen((request) async {
      if (request.uri.path == '/repos/glitch-228/conest/releases') {
        final body = jsonEncode([
          {
            'tag_name': 'v0.1.0-nightly.20260422.2',
            'name': 'nightly',
            'html_url': 'https://example.invalid/nightly',
            'published_at': '2026-04-22T10:00:00Z',
            'prerelease': true,
            'draft': false,
            'assets': [
              {
                'name': 'conest-linux-x64-debug-v0.1.0-nightly.20260422.2.zip',
                'browser_download_url': '$baseUrl/nightly.zip',
                'size': 10,
              },
              ..._releaseTrustAssets(
                baseUrl: baseUrl,
                files: nightlyFiles,
                manifestPath: '/nightly-manifest.json',
                signaturePath: '/nightly-manifest.sig',
              ),
            ],
          },
          {
            'tag_name': 'v0.1.0',
            'name': 'stable',
            'html_url': 'https://example.invalid/stable',
            'published_at': '2026-04-22T09:00:00Z',
            'prerelease': false,
            'draft': false,
            'assets': [
              {
                'name': 'conest-linux-x64-v0.1.0.zip',
                'browser_download_url': '$baseUrl/stable.zip',
                'size': 10,
              },
              ..._releaseTrustAssets(baseUrl: baseUrl, files: stableFiles),
            ],
          },
        ]);
        request.response
          ..headers.contentType = ContentType.json
          ..write(body);
        await request.response.close();
        return;
      }
      if (request.uri.path == '/stable-sums.txt') {
        request.response.write('${'a' * 64}  conest-linux-x64-v0.1.0.zip\n');
        await request.response.close();
        return;
      }
      if (request.uri.path == '/RELEASE-MANIFEST.json') {
        request.response.add(stableFiles.manifestBytes);
        await request.response.close();
        return;
      }
      if (request.uri.path == '/RELEASE-MANIFEST.ed25519.sig') {
        request.response.write(stableFiles.signatureText);
        await request.response.close();
        return;
      }
      if (request.uri.path == '/nightly-manifest.json') {
        request.response.add(nightlyFiles.manifestBytes);
        await request.response.close();
        return;
      }
      if (request.uri.path == '/nightly-manifest.sig') {
        request.response.write(nightlyFiles.signatureText);
        await request.response.close();
        return;
      }
      if (request.uri.path == '/SHA256SUMS.txt') {
        request.response.write(
          '${'b' * 64}  conest-linux-x64-debug-v0.1.0-nightly.20260422.2.zip\n',
        );
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    final service = UpdateService(
      buildInfo: ConestBuildInfo(
        appName: 'Conest',
        packageName: 'dev.conest.conest',
        version: '0.0.9',
        buildNumber: '1',
        channel: UpdateChannel.stable,
        isDebugBuild: false,
      ),
      targetPlatform: UpdateTargetPlatform.linux,
      apiBaseUri: Uri.parse(baseUrl),
      releaseManifestPublicKeyBase64: signer.publicKeyBase64,
      applicationSupportDirectoryProvider: () async =>
          await Directory.systemTemp.createTemp('conest-updates-test'),
      tempDirectoryProvider: () async =>
          await Directory.systemTemp.createTemp('conest-updates-temp'),
      exitCallback: (_) {},
    );

    final available = await service.checkForUpdate(userInitiated: true);

    expect(available, isTrue);
    expect(service.availableUpdate?.release.tagName, 'v0.1.0');
    expect(service.availableUpdate?.asset.name, 'conest-linux-x64-v0.1.0.zip');
  });

  test('nightly channel selects the newest prerelease nightly', () async {
    final signer = await _ManifestSigner.create();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final baseUrl = 'http://${server.address.host}:${server.port}';
    final oldFiles = await signer.sign(
      tagName: 'v0.1.0-nightly.20260420.1',
      assets: const {
        'conest-windows-x64-debug-portable-v0.1.0-nightly.20260420.1.zip':
            _ManifestAssetFixture(
              sha256Hex:
                  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
              sizeBytes: 10,
            ),
      },
    );
    final newFiles = await signer.sign(
      tagName: 'v0.1.0-nightly.20260422.3',
      assets: const {
        'conest-windows-x64-debug-portable-v0.1.0-nightly.20260422.3.zip':
            _ManifestAssetFixture(
              sha256Hex:
                  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
              sizeBytes: 10,
            ),
      },
    );
    server.listen((request) async {
      if (request.uri.path == '/repos/glitch-228/conest/releases') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode([
              {
                'tag_name': 'v0.1.0-nightly.20260420.1',
                'name': 'old nightly',
                'html_url': 'https://example.invalid/old',
                'published_at': '2026-04-20T09:00:00Z',
                'prerelease': true,
                'draft': false,
                'assets': [
                  {
                    'name':
                        'conest-windows-x64-debug-portable-v0.1.0-nightly.20260420.1.zip',
                    'browser_download_url': '$baseUrl/old.zip',
                    'size': 10,
                  },
                  ..._releaseTrustAssets(
                    baseUrl: baseUrl,
                    files: oldFiles,
                    manifestPath: '/old-manifest.json',
                    signaturePath: '/old-manifest.sig',
                  ),
                ],
              },
              {
                'tag_name': 'v0.1.0-nightly.20260422.3',
                'name': 'new nightly',
                'html_url': 'https://example.invalid/new',
                'published_at': '2026-04-22T09:00:00Z',
                'prerelease': true,
                'draft': false,
                'assets': [
                  {
                    'name':
                        'conest-windows-x64-debug-portable-v0.1.0-nightly.20260422.3.zip',
                    'browser_download_url': '$baseUrl/new.zip',
                    'size': 10,
                  },
                  ..._releaseTrustAssets(
                    baseUrl: baseUrl,
                    files: newFiles,
                    manifestPath: '/new-manifest.json',
                    signaturePath: '/new-manifest.sig',
                  ),
                ],
              },
            ]),
          );
        await request.response.close();
        return;
      }
      if (request.uri.path == '/old-sums.txt') {
        request.response.write(
          '${'c' * 64}  conest-windows-x64-debug-portable-v0.1.0-nightly.20260420.1.zip\n',
        );
        await request.response.close();
        return;
      }
      if (request.uri.path == '/new-sums.txt') {
        request.response.write(
          '${'d' * 64}  conest-windows-x64-debug-portable-v0.1.0-nightly.20260422.3.zip\n',
        );
        await request.response.close();
        return;
      }
      if (request.uri.path == '/old-manifest.json') {
        request.response.add(oldFiles.manifestBytes);
        await request.response.close();
        return;
      }
      if (request.uri.path == '/old-manifest.sig') {
        request.response.write(oldFiles.signatureText);
        await request.response.close();
        return;
      }
      if (request.uri.path == '/new-manifest.json') {
        request.response.add(newFiles.manifestBytes);
        await request.response.close();
        return;
      }
      if (request.uri.path == '/new-manifest.sig') {
        request.response.write(newFiles.signatureText);
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    final service = UpdateService(
      buildInfo: ConestBuildInfo(
        appName: 'Conest',
        packageName: 'dev.conest.conest',
        version: '0.1.0',
        buildNumber: '1',
        channel: UpdateChannel.nightly,
        isDebugBuild: true,
        buildTag: 'v0.1.0-nightly.20260419.1',
      ),
      targetPlatform: UpdateTargetPlatform.windows,
      apiBaseUri: Uri.parse(baseUrl),
      releaseManifestPublicKeyBase64: signer.publicKeyBase64,
      applicationSupportDirectoryProvider: () async =>
          await Directory.systemTemp.createTemp('conest-updates-test'),
      tempDirectoryProvider: () async =>
          await Directory.systemTemp.createTemp('conest-updates-temp'),
      exitCallback: (_) {},
    );

    final available = await service.checkForUpdate(userInitiated: true);

    expect(available, isTrue);
    expect(
      service.availableUpdate?.release.tagName,
      'v0.1.0-nightly.20260422.3',
    );
    expect(
      service.availableUpdate?.asset.name,
      'conest-windows-x64-debug-portable-v0.1.0-nightly.20260422.3.zip',
    );
  });

  test(
    'downloaded Android update is checksum-verified and passed to installer',
    () async {
      final signer = await _ManifestSigner.create();
      final apkBytes = utf8.encode('fake apk bytes');
      final apkHash = sha256.convert(apkBytes).toString();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final baseUrl = 'http://${server.address.host}:${server.port}';
      final manifestFiles = await signer.sign(
        tagName: 'v0.1.0-nightly.20260422.4',
        assets: {
          'conest-android-arm64-debug-v0.1.0-nightly.20260422.4.apk':
              _ManifestAssetFixture(
                sha256Hex: apkHash,
                sizeBytes: apkBytes.length,
              ),
        },
      );
      server.listen((request) async {
        switch (request.uri.path) {
          case '/repos/glitch-228/conest/releases':
            request.response
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode([
                  {
                    'tag_name': 'v0.1.0-nightly.20260422.4',
                    'name': 'nightly',
                    'html_url': 'https://example.invalid/nightly',
                    'published_at': '2026-04-22T09:00:00Z',
                    'prerelease': true,
                    'draft': false,
                    'assets': [
                      {
                        'name':
                            'conest-android-arm64-debug-v0.1.0-nightly.20260422.4.apk',
                        'browser_download_url': '$baseUrl/app.apk',
                        'size': apkBytes.length,
                      },
                      ..._releaseTrustAssets(
                        baseUrl: baseUrl,
                        files: manifestFiles,
                      ),
                    ],
                  },
                ]),
              );
            await request.response.close();
            return;
          case '/SHA256SUMS.txt':
            request.response.write(
              '$apkHash  conest-android-arm64-debug-v0.1.0-nightly.20260422.4.apk\n',
            );
            await request.response.close();
            return;
          case '/RELEASE-MANIFEST.json':
            request.response.add(manifestFiles.manifestBytes);
            await request.response.close();
            return;
          case '/RELEASE-MANIFEST.ed25519.sig':
            request.response.write(manifestFiles.signatureText);
            await request.response.close();
            return;
          case '/app.apk':
            request.response.add(apkBytes);
            await request.response.close();
            return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });

      final platformBridge = _FakePlatformBridge();
      var handOvers = 0;
      var failedHandOvers = 0;
      final supportDir = await Directory.systemTemp.createTemp(
        'conest-updates-test',
      );
      final tempDir = await Directory.systemTemp.createTemp(
        'conest-updates-temp',
      );
      addTearDown(() async {
        if (await supportDir.exists()) {
          await supportDir.delete(recursive: true);
        }
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final service = UpdateService(
        buildInfo: ConestBuildInfo(
          appName: 'Conest',
          packageName: 'dev.conest.conest',
          version: '0.1.0',
          buildNumber: '1',
          channel: UpdateChannel.nightly,
          isDebugBuild: true,
          buildTag: 'v0.1.0-nightly.20260419.1',
        ),
        platformBridge: platformBridge,
        targetPlatform: UpdateTargetPlatform.android,
        apiBaseUri: Uri.parse(baseUrl),
        releaseManifestPublicKeyBase64: signer.publicKeyBase64,
        applicationSupportDirectoryProvider: () async => supportDir,
        tempDirectoryProvider: () async => tempDir,
        exitCallback: (_) {},
        onHandOver: () async => handOvers++,
        onHandOverFailed: () => failedHandOvers++,
      );

      await service.checkForUpdate(userInitiated: true);
      await service.downloadAndApplyAvailableUpdate();

      expect(platformBridge.installedApkPath, isNotNull);
      expect(await File(platformBridge.installedApkPath!).exists(), isTrue);
      expect(service.lastError, isNull);
      expect((handOvers, failedHandOvers), (1, 0));

      // The installer does not open: the app runs on, so a later end
      // counts as a crash again.
      platformBridge.failInstall = true;
      await service.downloadAndApplyAvailableUpdate();
      expect(service.lastError, isNotNull);
      expect((handOvers, failedHandOvers), (2, 1));
    },
  );

  test('desktop updater launch is awaited before exiting', () async {
    final signer = await _ManifestSigner.create();
    final helperBytes = utf8.encode('fake staged helper');
    final zipBytes = _zipBytes({
      'conest_updater': helperBytes,
      'data/version.txt': utf8.encode('v0.1.1'),
    });
    final zipHash = sha256.convert(zipBytes).toString();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final baseUrl = 'http://${server.address.host}:${server.port}';
    final manifestFiles = await signer.sign(
      tagName: 'v0.1.1',
      assets: {
        'conest-linux-x64-v0.1.1.zip': _ManifestAssetFixture(
          sha256Hex: zipHash,
          sizeBytes: zipBytes.length,
        ),
      },
    );
    server.listen((request) async {
      switch (request.uri.path) {
        case '/repos/glitch-228/conest/releases':
          request.response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode([
                {
                  'tag_name': 'v0.1.1',
                  'name': 'stable',
                  'html_url': 'https://example.invalid/stable',
                  'published_at': '2026-04-22T09:00:00Z',
                  'prerelease': false,
                  'draft': false,
                  'assets': [
                    {
                      'name': 'conest-linux-x64-v0.1.1.zip',
                      'browser_download_url': '$baseUrl/app.zip',
                      'size': zipBytes.length,
                    },
                    ..._releaseTrustAssets(
                      baseUrl: baseUrl,
                      files: manifestFiles,
                    ),
                  ],
                },
              ]),
            );
          await request.response.close();
          return;
        case '/RELEASE-MANIFEST.json':
          request.response.add(manifestFiles.manifestBytes);
          await request.response.close();
          return;
        case '/RELEASE-MANIFEST.ed25519.sig':
          request.response.write(manifestFiles.signatureText);
          await request.response.close();
          return;
        case '/app.zip':
          request.response.add(zipBytes);
          await request.response.close();
          return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    final supportDir = await Directory.systemTemp.createTemp(
      'conest-updates-test',
    );
    final tempDir = await Directory.systemTemp.createTemp(
      'conest-updates-temp',
    );
    addTearDown(() async {
      if (await supportDir.exists()) {
        await supportDir.delete(recursive: true);
      }
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    var launcherFinished = false;
    var handedOver = false;
    var exited = false;
    int? exitCode;
    String? launchedExecutable;
    List<String>? launchedArguments;
    final service = UpdateService(
      buildInfo: ConestBuildInfo(
        appName: 'Conest',
        packageName: 'dev.conest.conest',
        version: '0.1.0',
        buildNumber: '1',
        channel: UpdateChannel.stable,
        isDebugBuild: false,
      ),
      targetPlatform: UpdateTargetPlatform.linux,
      apiBaseUri: Uri.parse(baseUrl),
      releaseManifestPublicKeyBase64: signer.publicKeyBase64,
      applicationSupportDirectoryProvider: () async => supportDir,
      tempDirectoryProvider: () async => tempDir,
      desktopUpdaterLauncher: (executable, arguments) async {
        expect(exited, isFalse);
        launchedExecutable = executable;
        launchedArguments = arguments;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        launcherFinished = true;
      },
      exitCallback: (code) {
        expect(launcherFinished, isTrue);
        // The app was told before it ends (no crash notice next start).
        expect(handedOver, isTrue);
        exited = true;
        exitCode = code;
      },
      onHandOver: () async {
        expect(launcherFinished, isTrue);
        // The app's save is waited for before it ends.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        handedOver = true;
      },
    );

    await service.checkForUpdate(userInitiated: true);
    await service.downloadAndApplyAvailableUpdate();

    expect(service.lastError, isNull);
    expect(exited, isTrue);
    expect(exitCode, 0);
    expect(launchedExecutable, isNotNull);
    expect(p.basename(launchedExecutable!), 'conest_updater');
    expect(p.isWithin(tempDir.path, launchedExecutable!), isTrue);
    expect(await File(launchedExecutable!).readAsBytes(), helperBytes);

    final arguments = launchedArguments!;
    final stagingDir = arguments[arguments.indexOf('--staging-dir') + 1];
    final bundleDir = arguments[arguments.indexOf('--bundle-dir') + 1];
    final appBinary = arguments[arguments.indexOf('--app-binary') + 1];
    expect(
      await File(p.join(stagingDir, 'data', 'version.txt')).readAsString(),
      'v0.1.1',
    );
    expect(bundleDir, File(Platform.resolvedExecutable).parent.path);
    expect(appBinary, p.basename(Platform.resolvedExecutable));
  });

  test('signed release manifest failures block update selection', () async {
    Future<String?> runCase({
      required _ManifestSigner signer,
      required List<Map<String, dynamic>> Function(
        String baseUrl,
        _ManifestFiles files,
      )
      assetsForRelease,
      required Future<_ManifestFiles> Function() filesProvider,
      required FutureOr<void> Function(
        HttpRequest request,
        _ManifestFiles files,
      )
      handleManifestRequest,
    }) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final baseUrl = 'http://${server.address.host}:${server.port}';
      final files = await filesProvider();
      server.listen((request) async {
        if (request.uri.path == '/repos/glitch-228/conest/releases') {
          request.response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode([
                {
                  'tag_name': 'v0.1.0',
                  'name': 'stable',
                  'html_url': 'https://example.invalid/stable',
                  'published_at': '2026-04-22T09:00:00Z',
                  'prerelease': false,
                  'draft': false,
                  'assets': [
                    _assetJson(
                      name: 'conest-linux-x64-v0.1.0.zip',
                      baseUrl: baseUrl,
                      path: '/app.zip',
                      size: 10,
                    ),
                    ...assetsForRelease(baseUrl, files),
                  ],
                },
              ]),
            );
          await request.response.close();
          return;
        }
        if (request.uri.path == '/SHA256SUMS.txt') {
          request.response.write('${'a' * 64}  conest-linux-x64-v0.1.0.zip\n');
          await request.response.close();
          return;
        }
        await Future.sync(() => handleManifestRequest(request, files));
      });

      final service = UpdateService(
        buildInfo: ConestBuildInfo(
          appName: 'Conest',
          packageName: 'dev.conest.conest',
          version: '0.0.9',
          buildNumber: '1',
          channel: UpdateChannel.stable,
          isDebugBuild: false,
        ),
        targetPlatform: UpdateTargetPlatform.linux,
        apiBaseUri: Uri.parse(baseUrl),
        releaseManifestPublicKeyBase64: signer.publicKeyBase64,
        applicationSupportDirectoryProvider: () async =>
            await Directory.systemTemp.createTemp('conest-updates-test'),
        tempDirectoryProvider: () async =>
            await Directory.systemTemp.createTemp('conest-updates-temp'),
        exitCallback: (_) {},
      );

      final available = await service.checkForUpdate(userInitiated: true);
      expect(available, isFalse);
      return service.lastError;
    }

    final signer = await _ManifestSigner.create();
    final validFiles = await signer.sign(
      tagName: 'v0.1.0',
      assets: const {
        'conest-linux-x64-v0.1.0.zip': _ManifestAssetFixture(
          sha256Hex:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          sizeBytes: 10,
        ),
      },
    );

    final missingManifestError = await runCase(
      signer: signer,
      filesProvider: () async => validFiles,
      assetsForRelease: (baseUrl, files) => [
        _assetJson(
          name: 'SHA256SUMS.txt',
          baseUrl: baseUrl,
          path: '/SHA256SUMS.txt',
          size: 128,
        ),
        _assetJson(
          name: 'RELEASE-MANIFEST.ed25519.sig',
          baseUrl: baseUrl,
          path: '/RELEASE-MANIFEST.ed25519.sig',
          size: files.signatureText.length,
        ),
      ],
      handleManifestRequest: (request, files) async {
        if (request.uri.path == '/RELEASE-MANIFEST.ed25519.sig') {
          request.response.write(files.signatureText);
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      },
    );
    expect(missingManifestError, contains('RELEASE-MANIFEST.json'));

    final tamperedManifestError = await runCase(
      signer: signer,
      filesProvider: () async => validFiles,
      assetsForRelease: (baseUrl, files) =>
          _releaseTrustAssets(baseUrl: baseUrl, files: files),
      handleManifestRequest: (request, files) async {
        if (request.uri.path == '/RELEASE-MANIFEST.json') {
          request.response.add(
            utf8.encode(
              jsonEncode({
                'version': 1,
                'tagName': 'v0.1.0',
                'assets': const [],
              }),
            ),
          );
        } else if (request.uri.path == '/RELEASE-MANIFEST.ed25519.sig') {
          request.response.write(files.signatureText);
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      },
    );
    expect(tamperedManifestError, contains('signature verification failed'));

    final tamperedSignatureError = await runCase(
      signer: signer,
      filesProvider: () async => validFiles,
      assetsForRelease: (baseUrl, files) =>
          _releaseTrustAssets(baseUrl: baseUrl, files: files),
      handleManifestRequest: (request, files) async {
        if (request.uri.path == '/RELEASE-MANIFEST.json') {
          request.response.add(files.manifestBytes);
        } else if (request.uri.path == '/RELEASE-MANIFEST.ed25519.sig') {
          final signatureBytes = base64Decode(files.signatureText);
          signatureBytes[0] = signatureBytes[0] ^ 0x01;
          request.response.write(base64Encode(signatureBytes));
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      },
    );
    expect(tamperedSignatureError, contains('signature verification failed'));

    final wrongTagFiles = await signer.sign(
      tagName: 'v0.1.1',
      assets: const {
        'conest-linux-x64-v0.1.0.zip': _ManifestAssetFixture(
          sha256Hex:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          sizeBytes: 10,
        ),
      },
    );
    final wrongTagError = await runCase(
      signer: signer,
      filesProvider: () async => wrongTagFiles,
      assetsForRelease: (baseUrl, files) =>
          _releaseTrustAssets(baseUrl: baseUrl, files: files),
      handleManifestRequest: (request, files) async {
        if (request.uri.path == '/RELEASE-MANIFEST.json') {
          request.response.add(files.manifestBytes);
        } else if (request.uri.path == '/RELEASE-MANIFEST.ed25519.sig') {
          request.response.write(files.signatureText);
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      },
    );
    expect(wrongTagError, contains('does not match'));

    final missingDigestFiles = await signer.sign(
      tagName: 'v0.1.0',
      assets: const {
        'other.zip': _ManifestAssetFixture(
          sha256Hex:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          sizeBytes: 10,
        ),
      },
    );
    final missingDigestError = await runCase(
      signer: signer,
      filesProvider: () async => missingDigestFiles,
      assetsForRelease: (baseUrl, files) =>
          _releaseTrustAssets(baseUrl: baseUrl, files: files),
      handleManifestRequest: (request, files) async {
        if (request.uri.path == '/RELEASE-MANIFEST.json') {
          request.response.add(files.manifestBytes);
        } else if (request.uri.path == '/RELEASE-MANIFEST.ed25519.sig') {
          request.response.write(files.signatureText);
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      },
    );
    expect(missingDigestError, contains('does not include conest-linux'));
  });

  test('parseSha256Sums accepts standard checksum lines', () {
    final parsed = parseSha256Sums(
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  app.zip\n',
    );

    expect(
      parsed['app.zip'],
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    );
  });

  test('semantic release ordering rejects downgrade and replay tags', () {
    expect(isReleaseTagNewerThan('v0.9.99', 'v0.10.0'), isFalse);
    expect(isReleaseTagNewerThan('v0.10.0', 'v0.10.0'), isFalse);
    expect(
      isReleaseTagNewerThan(
        'v0.10.0-nightly.20260713.9',
        'v0.10.0-nightly.20260713.10',
      ),
      isFalse,
    );
    expect(
      isReleaseTagNewerThan(
        'v0.10.0-nightly.20260713.11',
        'v0.10.0-nightly.20260713.10',
      ),
      isTrue,
    );
    expect(isReleaseTagNewerThan('not-a-version', 'v0.10.0'), isFalse);
  });

  group('release channels', () {
    // Fixed tags and dates: nothing here reads the clock.
    const stable042 = ('v0.4.2', false);
    const nightlyA = ('v0.4.3-nightly.20261029.1', true);
    const canaryA = ('v0.4.3-canary.20261030.1', true);
    const canaryB = ('v0.4.3-canary.20261103.2', true);

    Future<(UpdateService, Directory)> serviceOver(
      List<(String, bool)> releases, {
      required UpdateChannel channel,
      required String buildTag,
      UpdateChannel? follow,
      Map<String, _ManifestFiles>? overrides,
      Map<String, String> pairStyle = const {},
      Map<String, int> androidCodes = const {},
      Future<void>? listGate,
      Future<void>? downloadGate,
      _ReleaseServerLog? log,
      String? publicKey,
      UpdateTargetPlatform platform = UpdateTargetPlatform.linux,
      String buildNumber = '1',
      _ManifestSigner? signer,
    }) async {
      final usedSigner = signer ?? await _ManifestSigner.create();
      final baseUrl = await _serveReleases(
        usedSigner,
        releases,
        overrides: overrides,
        pairStyle: pairStyle,
        androidCodes: androidCodes,
        listGate: listGate,
        downloadGate: downloadGate,
        log: log,
      );
      final support = await Directory.systemTemp.createTemp('conest-upd-');
      addTearDown(() => support.delete(recursive: true));
      if (follow != null) {
        await File(
          p.join(support.path, 'update_preferences.json'),
        ).writeAsString(jsonEncode({'channel': follow.label}));
      }
      final service = _serviceFor(
        baseUrl: baseUrl,
        signer: usedSigner,
        channel: channel,
        buildTag: buildTag,
        support: support,
        publicKey: publicKey,
        platform: platform,
        buildNumber: buildNumber,
      );
      addTearDown(service.dispose);
      return (service, support);
    }

    test('a canary install takes the newest canary', () async {
      final (service, _) = await serviceOver(
        [canaryB, canaryA, nightlyA, stable042],
        channel: UpdateChannel.canary,
        buildTag: 'v0.4.3-canary.20261031.1',
      );
      expect(service.updateChannel, UpdateChannel.canary);
      expect(await service.checkForUpdate(userInitiated: true), isTrue);
      expect(service.availableUpdate?.release.tagName, canaryB.$1);
    });

    test(
      'a canary install also takes a newer nightly, and a newer stable',
      () async {
        final (service, _) = await serviceOver(
          [('v0.4.3-nightly.20261031.1', true), canaryA, stable042],
          channel: UpdateChannel.canary,
          buildTag: 'v0.4.3-canary.20261029.1',
        );
        expect(await service.checkForUpdate(), isTrue);
        expect(
          service.availableUpdate?.release.tagName,
          'v0.4.3-nightly.20261031.1',
        );
        final (toStable, _) = await serviceOver(
          [('v0.4.3', false), canaryB, nightlyA],
          channel: UpdateChannel.canary,
          buildTag: 'v0.4.3-canary.20261102.1',
        );
        expect(await toStable.checkForUpdate(), isTrue);
        expect(toStable.availableUpdate?.release.tagName, 'v0.4.3');
      },
    );

    test('same-day canary beats nightly; later nightly beats canary', () async {
      final (sameDay, _) = await serviceOver(
        [('v0.4.3-nightly.20261103.9', true), canaryB],
        channel: UpdateChannel.canary,
        buildTag: 'v0.4.3-canary.20261030.1',
      );
      expect(await sameDay.checkForUpdate(), isTrue);
      expect(sameDay.availableUpdate?.release.tagName, canaryB.$1);
      // A canary user on today's canary moves to a nightly only when it is
      // from a later date.
      final (notYet, _) = await serviceOver(
        [('v0.4.3-nightly.20261103.9', true), canaryB],
        channel: UpdateChannel.canary,
        buildTag: canaryB.$1,
      );
      expect(await notYet.checkForUpdate(), isFalse);
    });

    test('a nightly install never takes a canary', () async {
      final (service, _) = await serviceOver(
        [canaryB, canaryA, nightlyA, stable042],
        channel: UpdateChannel.nightly,
        buildTag: 'v0.4.3-nightly.20261028.1',
      );
      expect(await service.checkForUpdate(), isTrue);
      expect(service.availableUpdate?.release.tagName, nightlyA.$1);
      // Only a canary is newer: nothing is offered.
      final (only, _) = await serviceOver(
        [canaryB, canaryA, nightlyA],
        channel: UpdateChannel.nightly,
        buildTag: nightlyA.$1,
      );
      expect(await only.checkForUpdate(), isFalse);
      expect(only.availableUpdate, isNull);
      expect(only.waitingForNewerThanInstalled, isFalse);
    });

    test('a stable install takes only stable', () async {
      final (service, _) = await serviceOver(
        [canaryB, nightlyA, stable042],
        channel: UpdateChannel.stable,
        buildTag: 'v0.4.1',
      );
      expect(await service.checkForUpdate(), isTrue);
      expect(service.availableUpdate?.release.tagName, 'v0.4.2');
    });

    test('switching up takes effect at once; the choice is kept', () async {
      final (service, support) = await serviceOver(
        [canaryB, nightlyA, stable042],
        channel: UpdateChannel.nightly,
        buildTag: 'v0.4.3-nightly.20261028.1',
      );
      expect(await service.checkForUpdate(), isTrue);
      expect(service.availableUpdate?.release.tagName, nightlyA.$1);
      await service.setUpdateChannel(UpdateChannel.canary);
      expect(service.availableUpdate?.release.tagName, canaryB.$1);
      final saved = jsonDecode(
        await File(
          p.join(support.path, 'update_preferences.json'),
        ).readAsString(),
      );
      // Both keys: an older build reading the file still behaves.
      expect(saved, {'channel': 'canary', 'receiveUnstableUpdates': true});
    });

    test(
      'switching down waits for a release newer than the installed build',
      () async {
        final (service, _) = await serviceOver(
          [canaryB, nightlyA, stable042],
          channel: UpdateChannel.canary,
          buildTag: canaryB.$1,
        );
        await service.setUpdateChannel(UpdateChannel.nightly);
        expect(service.availableUpdate, isNull);
        expect(service.waitingForNewerThanInstalled, isTrue);
        expect(service.statusMessage, contains('Staying on it'));
        await service.setUpdateChannel(UpdateChannel.stable);
        expect(service.availableUpdate, isNull);
        expect(service.waitingForNewerThanInstalled, isTrue);
        // A nightly newer than the build arrives: it is offered.
        final (later, _) = await serviceOver(
          [('v0.4.3-nightly.20261104.1', true), canaryB, nightlyA],
          channel: UpdateChannel.canary,
          buildTag: canaryB.$1,
          follow: UpdateChannel.nightly,
        );
        expect(await later.checkForUpdate(), isTrue);
        expect(later.waitingForNewerThanInstalled, isFalse);
        expect(
          later.availableUpdate?.release.tagName,
          'v0.4.3-nightly.20261104.1',
        );
        // A stable of the same core is newer than the canary too.
        final (stableCame, _) = await serviceOver(
          [('v0.4.3', false), canaryB],
          channel: UpdateChannel.canary,
          buildTag: canaryB.$1,
          follow: UpdateChannel.stable,
        );
        expect(await stableCame.checkForUpdate(), isTrue);
        expect(stableCame.availableUpdate?.release.tagName, 'v0.4.3');
      },
    );

    test('no downgrade and no reinstall, whatever the choice', () async {
      final (newer, _) = await serviceOver(
        [canaryA, nightlyA, stable042, ('v0.4.0', false)],
        channel: UpdateChannel.canary,
        buildTag: 'v0.4.4-canary.20261105.1',
      );
      expect(await newer.checkForUpdate(), isFalse);
      expect(newer.availableUpdate, isNull);
      final (same, _) = await serviceOver(
        [canaryA],
        channel: UpdateChannel.canary,
        buildTag: canaryA.$1,
      );
      expect(await same.checkForUpdate(), isFalse);
      expect(same.statusMessage, contains('Already on the latest'));
    });

    test('an invalid canary tag or a wrong flag is never offered', () async {
      final (service, _) = await serviceOver(
        [
          ('v0.4.3-canary.1', true),
          ('v0.4.9-canary.20261105.1', false),
          ('v0.4.9-canary.20261399.1', true),
          ('v0.4.9-rc.1', true),
        ],
        channel: UpdateChannel.canary,
        buildTag: 'v0.4.3-canary.20261031.1',
      );
      expect(await service.checkForUpdate(), isFalse);
      expect(service.availableUpdate, isNull);
    });

    Future<String?> refusal(UpdateService service) async {
      expect(await service.checkForUpdate(userInitiated: true), isFalse);
      expect(service.availableUpdate, isNull);
      return service.lastError;
    }

    Future<_ManifestFiles> signed(
      _ManifestSigner signer,
      String tag, {
      String? channel,
      String? releaseVersion,
      bool omitChannel = false,
    }) => signer.sign(
      tagName: tag,
      channel: channel,
      releaseVersion: releaseVersion,
      omitChannel: omitChannel,
      assets: {
        'conest-linux-x64-$tag.zip': _ManifestAssetFixture(
          sha256Hex: 'e' * 64,
          sizeBytes: 10,
        ),
      },
    );

    test('a manifest of another channel is refused on every line', () async {
      final signer = await _ManifestSigner.create();
      // A nightly release carrying a canary-signed manifest, and the reverse.
      final (nightly, _) = await serviceOver(
        [nightlyA],
        channel: UpdateChannel.nightly,
        buildTag: 'v0.4.3-nightly.20261028.1',
        signer: signer,
        overrides: {
          nightlyA.$1: await signed(signer, nightlyA.$1, channel: 'canary'),
        },
      );
      expect(
        await refusal(nightly),
        contains('channel canary does not match nightly'),
      );
      final (canary, _) = await serviceOver(
        [canaryA],
        channel: UpdateChannel.canary,
        buildTag: 'v0.4.3-canary.20261029.1',
        signer: signer,
        overrides: {
          canaryA.$1: await signed(signer, canaryA.$1, channel: 'nightly'),
        },
      );
      expect(
        await refusal(canary),
        contains('channel nightly does not match canary'),
      );
      final (stable, _) = await serviceOver(
        [stable042],
        channel: UpdateChannel.stable,
        buildTag: 'v0.4.1',
        signer: signer,
        overrides: {
          stable042.$1: await signed(signer, 'v0.4.2', channel: 'nightly'),
        },
      );
      expect(await refusal(stable), contains('does not match stable'));
    });

    test(
      'a manifest without a channel, or for another version, is refused',
      () async {
        final signer = await _ManifestSigner.create();
        final (noChannel, _) = await serviceOver(
          [canaryA],
          channel: UpdateChannel.canary,
          buildTag: 'v0.4.3-canary.20261029.1',
          signer: signer,
          overrides: {
            canaryA.$1: await signed(signer, canaryA.$1, omitChannel: true),
          },
        );
        expect(await refusal(noChannel), contains('channel none'));
        final (version, _) = await serviceOver(
          [canaryB],
          channel: UpdateChannel.canary,
          buildTag: 'v0.4.3-canary.20261029.1',
          signer: signer,
          overrides: {
            canaryB.$1: await signed(
              signer,
              canaryB.$1,
              releaseVersion: '0.4.3-canary.20261030.1',
            ),
          },
        );
        expect(
          await refusal(version),
          contains('version 0.4.3-canary.20261030.1 does not match'),
        );
        final (tag, _) = await serviceOver(
          [canaryB],
          channel: UpdateChannel.canary,
          buildTag: 'v0.4.3-canary.20261029.1',
          signer: signer,
          overrides: {canaryB.$1: await signed(signer, canaryA.$1)},
        );
        expect(await refusal(tag), contains('does not match'));
      },
    );

    test(
      'a canary release never carries the standard pair, nor the reverse',
      () async {
        for (final (releases, style, channel) in [
          ([canaryA], 'standard', UpdateChannel.canary),
          ([canaryA], 'both', UpdateChannel.canary),
          ([nightlyA], 'canary', UpdateChannel.nightly),
          ([nightlyA], 'both', UpdateChannel.nightly),
        ]) {
          final (service, _) = await serviceOver(
            releases,
            channel: channel,
            buildTag: 'v0.4.3-${channel.label}.20261027.1',
            pairStyle: {releases.first.$1: style},
            follow: channel,
          );
          expect(await refusal(service), isNotNull, reason: '$style');
        }
      },
    );

    test('the signature is still required on every line', () async {
      final signer = await _ManifestSigner.create();
      // Tampered bytes under the right signature.
      final good = await signed(signer, canaryA.$1, channel: 'canary');
      final tampered = _ManifestFiles(
        manifestBytes: utf8.encode(
          utf8.decode(good.manifestBytes).replaceFirst('"canary"', '"stable"'),
        ),
        signatureText: good.signatureText,
      );
      final (tamper, _) = await serviceOver(
        [canaryA],
        channel: UpdateChannel.canary,
        buildTag: 'v0.4.3-canary.20261029.1',
        signer: signer,
        overrides: {canaryA.$1: tampered},
      );
      expect(await refusal(tamper), contains('signature verification failed'));
      // Another key.
      final other = await _ManifestSigner.create();
      final (wrongKey, _) = await serviceOver(
        [canaryA],
        channel: UpdateChannel.canary,
        buildTag: 'v0.4.3-canary.20261029.1',
        signer: signer,
        publicKey: other.publicKeyBase64,
      );
      expect(
        await refusal(wrongKey),
        contains('signature verification failed'),
      );
      // No signature file.
      final (missing, _) = await serviceOver(
        [canaryA],
        channel: UpdateChannel.canary,
        buildTag: 'v0.4.3-canary.20261029.1',
        pairStyle: {canaryA.$1: 'no-signature'},
      );
      expect(await refusal(missing), contains('does not include'));
    });

    test('Android waits for a release with a higher versionCode', () async {
      Future<UpdateService> over(int? code) async {
        final (service, _) = await serviceOver(
          [canaryB],
          channel: UpdateChannel.canary,
          buildTag: 'v0.4.3-canary.20261031.1',
          platform: UpdateTargetPlatform.android,
          buildNumber: '306100',
          androidCodes: {if (code != null) canaryB.$1: code},
        );
        return service;
      }

      final low = await over(306050);
      expect(await low.checkForUpdate(), isFalse);
      expect(low.waitingForNewerThanInstalled, isTrue);
      expect(await (await over(306100)).checkForUpdate(), isTrue);
      expect(await (await over(306200)).checkForUpdate(), isTrue);
      // Releases from before the field existed carry none.
      expect(await (await over(null)).checkForUpdate(), isTrue);
    });

    test('the saved choice is read from every kind of file', () async {
      Future<UpdateChannel> read(UpdateChannel build, String? content) async {
        final support = await Directory.systemTemp.createTemp('conest-upd-');
        addTearDown(() => support.delete(recursive: true));
        if (content != null) {
          await File(
            p.join(support.path, 'update_preferences.json'),
          ).writeAsString(content);
        }
        final service = _serviceFor(
          baseUrl: 'http://127.0.0.1:1',
          signer: await _ManifestSigner.create(),
          channel: build,
          buildTag: 'v0.4.3',
          support: support,
        );
        addTearDown(service.dispose);
        await service.loadPreferences();
        return service.updateChannel;
      }

      // A legacy file (only the old switch).
      expect(
        await read(UpdateChannel.stable, '{"receiveUnstableUpdates":true}'),
        UpdateChannel.nightly,
      );
      expect(
        await read(UpdateChannel.stable, '{"receiveUnstableUpdates":false}'),
        UpdateChannel.stable,
      );
      expect(
        await read(UpdateChannel.nightly, '{"receiveUnstableUpdates":false}'),
        UpdateChannel.stable,
      );
      // A canary build follows canary from a legacy file.
      expect(
        await read(UpdateChannel.canary, '{"receiveUnstableUpdates":false}'),
        UpdateChannel.canary,
      );
      // The new key wins over the old one.
      expect(
        await read(
          UpdateChannel.stable,
          '{"channel":"canary","receiveUnstableUpdates":false}',
        ),
        UpdateChannel.canary,
      );
      expect(
        await read(
          UpdateChannel.canary,
          '{"channel":"stable","receiveUnstableUpdates":false}',
        ),
        UpdateChannel.stable,
      );
      // An unknown name falls back to the old key, then the build's own.
      expect(
        await read(
          UpdateChannel.stable,
          '{"channel":"weekly","receiveUnstableUpdates":true}',
        ),
        UpdateChannel.nightly,
      );
      expect(
        await read(UpdateChannel.nightly, '{"channel":"weekly"}'),
        UpdateChannel.nightly,
      );
      expect(
        await read(UpdateChannel.canary, '{"channel":7}'),
        UpdateChannel.canary,
      );
      // Damaged, or none.
      expect(
        await read(UpdateChannel.nightly, 'not json'),
        UpdateChannel.nightly,
      );
      expect(await read(UpdateChannel.stable, '[]'), UpdateChannel.stable);
      expect(await read(UpdateChannel.canary, null), UpdateChannel.canary);
    });

    test('a check that starts during the load uses the saved choice', () async {
      final (service, _) = await serviceOver(
        [canaryB, stable042],
        channel: UpdateChannel.stable,
        buildTag: 'v0.4.1',
        follow: UpdateChannel.canary,
      );
      final load = service.loadPreferences();
      final check = service.checkForUpdate();
      await load;
      expect(await check, isTrue);
      expect(service.availableUpdate?.release.tagName, canaryB.$1);
      expect(
        identical(service.loadPreferences(), service.loadPreferences()),
        isTrue,
      );
    });

    test('quick switches are saved in order', () async {
      final (service, support) = await serviceOver(
        [stable042],
        channel: UpdateChannel.stable,
        buildTag: 'v0.4.1',
      );
      await Future.wait([
        service.setUpdateChannel(UpdateChannel.canary),
        service.setUpdateChannel(UpdateChannel.nightly),
      ]);
      final saved = jsonDecode(
        await File(
          p.join(support.path, 'update_preferences.json'),
        ).readAsString(),
      );
      expect(saved['channel'], service.updateChannel.label);
    });

    test(
      'a check that a switch overtakes writes nothing, then re-checks',
      () async {
        final gate = Completer<void>();
        final (service, _) = await serviceOver(
          [canaryB, nightlyA, stable042],
          channel: UpdateChannel.stable,
          buildTag: 'v0.4.1',
          listGate: gate.future,
        );
        final seen = <String?>[];
        service.addListener(
          () => seen.add(service.availableUpdate?.release.tagName),
        );
        final first = service.checkForUpdate(userInitiated: true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(service.isChecking, isTrue);
        // The user switches while the stable-line check waits for GitHub.
        await service.setUpdateChannel(UpdateChannel.canary);
        expect(service.availableUpdate, isNull);
        gate.complete();
        await first;
        for (var i = 0; i < 100 && service.availableUpdate == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        // The stale stable result was never shown; the canary one was.
        expect(seen, isNot(contains('v0.4.2')));
        expect(service.availableUpdate?.release.tagName, canaryB.$1);
        expect(service.statusMessage, contains('available'));
      },
    );

    test('the channel cannot be switched while a download runs', () async {
      final gate = Completer<void>();
      final (service, _) = await serviceOver(
        [canaryB, nightlyA],
        channel: UpdateChannel.canary,
        buildTag: 'v0.4.3-canary.20261031.1',
        downloadGate: gate.future,
      );
      expect(await service.checkForUpdate(), isTrue);
      final download = service.downloadAndApplyAvailableUpdate();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.isDownloading, isTrue);
      await service.setUpdateChannel(UpdateChannel.nightly);
      expect(service.updateChannel, UpdateChannel.canary);
      expect(service.availableUpdate?.release.tagName, canaryB.$1);
      gate.complete();
      await download;
    });

    test(
      'a switch drops the offer, so nothing from the old line downloads',
      () async {
        final (service, _) = await serviceOver(
          [canaryB, nightlyA],
          channel: UpdateChannel.canary,
          buildTag: 'v0.4.3-canary.20261031.1',
        );
        expect(await service.checkForUpdate(), isTrue);
        await service.setUpdateChannel(UpdateChannel.nightly);
        expect(service.availableUpdate, isNull);
        await service.downloadAndApplyAvailableUpdate();
        expect(service.isDownloading, isFalse);
        expect(service.lastError, isNull);
      },
    );

    test('a check that ends after dispose does nothing', () async {
      final gate = Completer<void>();
      final (service, _) = await serviceOver(
        [canaryB],
        channel: UpdateChannel.canary,
        buildTag: 'v0.4.3-canary.20261031.1',
        listGate: gate.future,
      );
      final check = service.checkForUpdate();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await service.setUpdateChannel(UpdateChannel.nightly);
      service.dispose();
      gate.complete();
      await check;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // No exception, and a call after dispose is a no-op.
      expect(await service.checkForUpdate(), isFalse);
    });

    test('the release list is requested in pages that fit the cap', () async {
      // Pruning keeps 10 canaries; old clients read the first 20 (relay
      // supervisor, install script) or 30 (older apps) entries.
      final releases = <(String, bool)>[
        for (var day = 20; day > 10; day--)
          ('v0.4.3-canary.202611$day.1', true),
        ('v0.4.3-nightly.20261029.1', true),
        ('v0.4.3-nightly.20261028.1', true),
        stable042,
        ('v0.4.2-nightly.20261020.1', true),
        for (var i = 1; i <= 30; i++) ('v0.3.$i', false),
      ];
      for (final window in [20, 30]) {
        final seen = releases.take(window).toList();
        expect(
          seen.any(
            (r) => r.$1.contains('nightly') && r.$1.startsWith('v0.4.3'),
          ),
          isTrue,
          reason: '$window',
        );
        expect(seen.any((r) => r.$1 == 'v0.4.2'), isTrue, reason: '$window');
      }
      final log = _ReleaseServerLog();
      final (service, _) = await serviceOver(
        releases,
        channel: UpdateChannel.nightly,
        buildTag: 'v0.4.3-nightly.20261027.1',
        log: log,
      );
      expect(await service.checkForUpdate(), isTrue);
      expect(
        service.availableUpdate?.release.tagName,
        'v0.4.3-nightly.20261029.1',
      );
      expect(log.listQueries, ['per_page=40']);
      // A full page of such releases is larger than the 1 MB metadata cap,
      // which is why the list has its own.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final base = await _serveReleases(await _ManifestSigner.create(), [
        for (var i = 1; i <= 40; i++) ('v0.3.$i', false),
      ]);
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('$base/repos/glitch-228/conest/releases?per_page=40'),
      );
      final response = await request.close();
      final size = (await response.fold<List<int>>(
        [],
        (a, b) => a..addAll(b),
      )).length;
      client.close();
      expect(size, greaterThan(1024 * 1024));
      expect(size, lessThan(4 * 1024 * 1024));
    });

    test('a real v0.4.2 manifest passes the new parsing', () {
      final json =
          jsonDecode(
                File(
                  'test/fixtures/release_manifest_v0.4.2.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final manifest = ReleaseManifest.fromJson(json);
      expect(manifest.channel, 'stable');
      expect(manifest.releaseVersion, '0.4.2');
      expect(manifest.androidVersionCode, isNull);
      expect(
        ReleaseManifest.fromJson({
          ...json,
          'channel': 'canary',
          'androidVersionCode': 306100,
        }).androidVersionCode,
        306100,
      );
      expect(
        () => ReleaseManifest.fromJson({...json, 'androidVersionCode': -1}),
        throwsFormatException,
      );
      expect(
        () => ReleaseManifest.fromJson({
          ...json,
          'version': 2,
          'channel': 'weekly',
        }),
        throwsFormatException,
      );
    });
  });
}

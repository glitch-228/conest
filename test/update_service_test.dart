import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/build_info.dart';
import 'package:conest/src/platform_bridge.dart';
import 'package:conest/src/update_service.dart';

class _FakePlatformBridge extends PlatformBridge {
  String? installedApkPath;

  @override
  Future<void> installDownloadedApk(String path) async {
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
  }) async {
    final manifest = jsonEncode({
      'version': 1,
      'tagName': tagName,
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
}) {
  return [
    _assetJson(
      name: 'SHA256SUMS.txt',
      baseUrl: baseUrl,
      path: '/SHA256SUMS.txt',
      size: 128,
    ),
    _assetJson(
      name: 'RELEASE-MANIFEST.json',
      baseUrl: baseUrl,
      path: manifestPath,
      size: files.manifestBytes.length,
    ),
    _assetJson(
      name: 'RELEASE-MANIFEST.ed25519.sig',
      baseUrl: baseUrl,
      path: signaturePath,
      size: files.signatureText.length,
    ),
  ];
}

void main() {
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
        ),
        platformBridge: platformBridge,
        targetPlatform: UpdateTargetPlatform.android,
        apiBaseUri: Uri.parse(baseUrl),
        releaseManifestPublicKeyBase64: signer.publicKeyBase64,
        applicationSupportDirectoryProvider: () async => supportDir,
        tempDirectoryProvider: () async => tempDir,
        exitCallback: (_) {},
      );

      await service.checkForUpdate(userInitiated: true);
      await service.downloadAndApplyAvailableUpdate();

      expect(platformBridge.installedApkPath, isNotNull);
      expect(await File(platformBridge.installedApkPath!).exists(), isTrue);
      expect(service.lastError, isNull);
    },
  );

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
}

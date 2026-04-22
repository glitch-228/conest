import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

void main() {
  test('stable channel selects the newest non-prerelease release', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
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
                'browser_download_url':
                    'http://${server.address.host}:${server.port}/nightly.zip',
                'size': 10,
              },
              {
                'name': 'SHA256SUMS.txt',
                'browser_download_url':
                    'http://${server.address.host}:${server.port}/SHA256SUMS.txt',
                'size': 10,
              },
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
                'browser_download_url':
                    'http://${server.address.host}:${server.port}/stable.zip',
                'size': 10,
              },
              {
                'name': 'SHA256SUMS.txt',
                'browser_download_url':
                    'http://${server.address.host}:${server.port}/stable-sums.txt',
                'size': 10,
              },
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
      apiBaseUri: Uri.parse('http://${server.address.host}:${server.port}'),
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
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
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
                    'browser_download_url':
                        'http://${server.address.host}:${server.port}/old.zip',
                    'size': 10,
                  },
                  {
                    'name': 'SHA256SUMS.txt',
                    'browser_download_url':
                        'http://${server.address.host}:${server.port}/old-sums.txt',
                    'size': 10,
                  },
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
                    'browser_download_url':
                        'http://${server.address.host}:${server.port}/new.zip',
                    'size': 10,
                  },
                  {
                    'name': 'SHA256SUMS.txt',
                    'browser_download_url':
                        'http://${server.address.host}:${server.port}/new-sums.txt',
                    'size': 10,
                  },
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
      apiBaseUri: Uri.parse('http://${server.address.host}:${server.port}'),
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
      final apkBytes = utf8.encode('fake apk bytes');
      final apkHash = sha256.convert(apkBytes).toString();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
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
                        'browser_download_url':
                            'http://${server.address.host}:${server.port}/app.apk',
                        'size': apkBytes.length,
                      },
                      {
                        'name': 'SHA256SUMS.txt',
                        'browser_download_url':
                            'http://${server.address.host}:${server.port}/SHA256SUMS.txt',
                        'size': 128,
                      },
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
        apiBaseUri: Uri.parse('http://${server.address.host}:${server.port}'),
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

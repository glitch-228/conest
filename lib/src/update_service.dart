import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'build_info.dart';
import 'platform_bridge.dart';

enum UpdateTargetPlatform {
  android('android'),
  linux('linux'),
  windows('windows'),
  unsupported('unsupported');

  const UpdateTargetPlatform(this.label);

  final String label;
}

UpdateTargetPlatform detectUpdateTargetPlatform() {
  if (kIsWeb) {
    return UpdateTargetPlatform.unsupported;
  }
  if (Platform.isAndroid) {
    return UpdateTargetPlatform.android;
  }
  if (Platform.isLinux) {
    return UpdateTargetPlatform.linux;
  }
  if (Platform.isWindows) {
    return UpdateTargetPlatform.windows;
  }
  return UpdateTargetPlatform.unsupported;
}

class GithubReleaseAsset {
  const GithubReleaseAsset({
    required this.name,
    required this.downloadUri,
    required this.sizeBytes,
  });

  final String name;
  final Uri downloadUri;
  final int sizeBytes;
}

class GithubReleaseInfo {
  const GithubReleaseInfo({
    required this.tagName,
    required this.name,
    required this.htmlUri,
    required this.publishedAt,
    required this.prerelease,
    required this.draft,
    required this.assets,
  });

  final String tagName;
  final String name;
  final Uri htmlUri;
  final DateTime publishedAt;
  final bool prerelease;
  final bool draft;
  final List<GithubReleaseAsset> assets;
}

class UpdateAvailability {
  const UpdateAvailability({
    required this.release,
    required this.asset,
    required this.sha256Hex,
  });

  final GithubReleaseInfo release;
  final GithubReleaseAsset asset;
  final String sha256Hex;
}

const _releaseManifestName = 'RELEASE-MANIFEST.json';
const _releaseManifestSignatureName = 'RELEASE-MANIFEST.ed25519.sig';
const _releaseManifestPublicKeyFromEnvironment = String.fromEnvironment(
  'CONEST_RELEASE_MANIFEST_PUBLIC_KEY',
);

class ReleaseManifestAsset {
  const ReleaseManifestAsset({
    required this.name,
    required this.sha256Hex,
    required this.sizeBytes,
  });

  final String name;
  final String sha256Hex;
  final int? sizeBytes;

  factory ReleaseManifestAsset.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String? ?? '';
    final sha256Hex = (json['sha256'] as String? ?? '').toLowerCase();
    final size = json['sizeBytes'] as int?;
    if (name.isEmpty) {
      throw const FormatException('Release manifest asset name is empty.');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256Hex)) {
      throw FormatException('Release manifest has invalid sha256 for $name.');
    }
    if (size != null && size < 0) {
      throw FormatException('Release manifest has invalid size for $name.');
    }
    return ReleaseManifestAsset(
      name: name,
      sha256Hex: sha256Hex,
      sizeBytes: size,
    );
  }
}

class ReleaseManifest {
  const ReleaseManifest({
    required this.version,
    required this.tagName,
    required this.assets,
  });

  final int version;
  final String tagName;
  final Map<String, ReleaseManifestAsset> assets;

  factory ReleaseManifest.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? 0;
    if (version != 1) {
      throw FormatException('Unsupported release manifest version: $version.');
    }
    final tagName = json['tagName'] as String? ?? '';
    if (tagName.isEmpty) {
      throw const FormatException('Release manifest tagName is empty.');
    }
    final assetValues = json['assets'] as List<dynamic>? ?? const [];
    final assets = <String, ReleaseManifestAsset>{};
    for (final value in assetValues) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException(
          'Release manifest asset must be an object.',
        );
      }
      final asset = ReleaseManifestAsset.fromJson(value);
      if (assets.containsKey(asset.name)) {
        throw FormatException(
          'Release manifest has duplicate asset ${asset.name}.',
        );
      }
      assets[asset.name] = asset;
    }
    if (assets.isEmpty) {
      throw const FormatException('Release manifest has no assets.');
    }
    return ReleaseManifest(version: version, tagName: tagName, assets: assets);
  }

  ReleaseManifestAsset assetFor(GithubReleaseAsset asset) {
    final manifestAsset = assets[asset.name];
    if (manifestAsset == null) {
      throw StateError(
        'Release manifest for $tagName does not include ${asset.name}.',
      );
    }
    final expectedSize = manifestAsset.sizeBytes;
    if (expectedSize != null &&
        asset.sizeBytes > 0 &&
        expectedSize != asset.sizeBytes) {
      throw StateError(
        'Release manifest size mismatch for ${asset.name}: expected $expectedSize, GitHub reported ${asset.sizeBytes}.',
      );
    }
    return manifestAsset;
  }
}

@visibleForTesting
Map<String, String> parseSha256Sums(String content) {
  final values = <String, String>{};
  final lines = const LineSplitter().convert(content);
  final pattern = RegExp(r'^([A-Fa-f0-9]{64})\s+\*?(.+)$');
  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }
    final match = pattern.firstMatch(line);
    if (match == null) {
      continue;
    }
    values[match.group(2)!] = match.group(1)!.toLowerCase();
  }
  return values;
}

class UpdateService extends ChangeNotifier {
  UpdateService({
    required this.buildInfo,
    PlatformBridge? platformBridge,
    HttpClient Function()? httpClientFactory,
    Future<Directory> Function()? applicationSupportDirectoryProvider,
    Future<Directory> Function()? tempDirectoryProvider,
    DateTime Function()? nowProvider,
    UpdateTargetPlatform? targetPlatform,
    Uri? apiBaseUri,
    String repositoryOwner = 'glitch-228',
    String repositoryName = 'conest',
    String? releaseManifestPublicKeyBase64,
    void Function(int code)? exitCallback,
  }) : _platformBridge = platformBridge ?? PlatformBridge(),
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _applicationSupportDirectoryProvider =
           applicationSupportDirectoryProvider ??
           getApplicationSupportDirectory,
       _tempDirectoryProvider = tempDirectoryProvider ?? getTemporaryDirectory,
       _nowProvider = nowProvider ?? DateTime.now,
       _targetPlatform = targetPlatform ?? detectUpdateTargetPlatform(),
       _apiBaseUri = apiBaseUri ?? Uri.parse('https://api.github.com'),
       _repositoryOwner = repositoryOwner,
       _repositoryName = repositoryName,
       _releaseManifestPublicKeyBase64 =
           releaseManifestPublicKeyBase64 ??
           _releaseManifestPublicKeyFromEnvironment,
       _exitCallback = exitCallback ?? exit;

  final ConestBuildInfo buildInfo;
  final PlatformBridge _platformBridge;
  final HttpClient Function() _httpClientFactory;
  final Future<Directory> Function() _applicationSupportDirectoryProvider;
  final Future<Directory> Function() _tempDirectoryProvider;
  final DateTime Function() _nowProvider;
  final UpdateTargetPlatform _targetPlatform;
  final Uri _apiBaseUri;
  final String _repositoryOwner;
  final String _repositoryName;
  final String _releaseManifestPublicKeyBase64;
  final void Function(int code) _exitCallback;

  bool _startupCheckStarted = false;
  bool _checking = false;
  bool _downloading = false;
  double? _downloadProgress;
  UpdateAvailability? _availableUpdate;
  DateTime? _lastCheckedAt;
  String? _statusMessage;
  String? _lastError;
  String? _dismissedPromptTagForSession;

  bool get supportsUpdates =>
      _targetPlatform != UpdateTargetPlatform.unsupported;
  UpdateTargetPlatform get targetPlatform => _targetPlatform;
  bool get isChecking => _checking;
  bool get isDownloading => _downloading;
  double? get downloadProgress => _downloadProgress;
  UpdateAvailability? get availableUpdate => _availableUpdate;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  String? get statusMessage => _statusMessage;
  String? get lastError => _lastError;

  bool get shouldPromptForAvailableUpdate {
    final available = _availableUpdate;
    if (available == null || _downloading) {
      return false;
    }
    return _dismissedPromptTagForSession != available.release.tagName;
  }

  Future<void> ensureStartupCheck() async {
    if (_startupCheckStarted || !supportsUpdates) {
      return;
    }
    _startupCheckStarted = true;
    await checkForUpdate(userInitiated: false);
  }

  void dismissPromptForSession(String tag) {
    _dismissedPromptTagForSession = tag;
    notifyListeners();
  }

  Future<bool> checkForUpdate({bool userInitiated = false}) async {
    if (!supportsUpdates || _checking) {
      return _availableUpdate != null;
    }
    _checking = true;
    if (userInitiated) {
      _statusMessage = 'Checking for ${buildInfo.channelLabel} updates...';
    }
    _lastError = null;
    notifyListeners();
    try {
      final releases = await _fetchReleases();
      final selected = _selectRelease(releases);
      if (selected == null) {
        _availableUpdate = null;
        _statusMessage = 'No ${buildInfo.channelLabel} releases found.';
        return false;
      }
      if (_matchesCurrentBuild(selected.tagName)) {
        _availableUpdate = null;
        _statusMessage =
            'Already on the latest ${buildInfo.channelLabel} build.';
        return false;
      }
      final asset = _selectPlatformAsset(selected);
      if (asset == null) {
        _availableUpdate = null;
        _statusMessage =
            'Latest ${buildInfo.channelLabel} release has no ${_targetPlatform.label} app asset.';
        return false;
      }
      final manifest = await _fetchVerifiedReleaseManifest(selected);
      final manifestAsset = manifest.assetFor(asset);
      _availableUpdate = UpdateAvailability(
        release: selected,
        asset: asset,
        sha256Hex: manifestAsset.sha256Hex,
      );
      _statusMessage =
          'Update ${selected.tagName} is available for ${_targetPlatform.label}.';
      return true;
    } catch (error) {
      _lastError = error.toString();
      if (userInitiated) {
        _statusMessage = 'Update check failed: $error';
      }
      return false;
    } finally {
      _checking = false;
      _lastCheckedAt = _nowProvider().toUtc();
      notifyListeners();
    }
  }

  Future<void> downloadAndApplyAvailableUpdate() async {
    final available = _availableUpdate;
    if (available == null || _downloading) {
      return;
    }
    _downloading = true;
    _downloadProgress = 0;
    _lastError = null;
    _dismissedPromptTagForSession = available.release.tagName;
    _statusMessage =
        'Downloading ${available.release.tagName} for ${_targetPlatform.label}...';
    notifyListeners();
    try {
      final supportDir = await _applicationSupportDirectoryProvider();
      final updateRoot = Directory(
        p.join(supportDir.path, 'updates', available.release.tagName),
      );
      if (await updateRoot.exists()) {
        await updateRoot.delete(recursive: true);
      }
      await updateRoot.create(recursive: true);
      final archiveFile = File(p.join(updateRoot.path, available.asset.name));
      await _downloadBinary(
        available.asset.downloadUri,
        archiveFile,
        expectedSha256Hex: available.sha256Hex,
      );
      if (_targetPlatform == UpdateTargetPlatform.android) {
        await _platformBridge.installDownloadedApk(archiveFile.path);
        _statusMessage =
            'Installer opened for ${available.release.tagName}. Confirm the Android install to finish updating.';
        return;
      }
      await _prepareAndApplyDesktopUpdate(
        archiveFile: archiveFile,
        releaseTag: available.release.tagName,
      );
    } catch (error) {
      _lastError = error.toString();
      _statusMessage = 'Update failed: $error';
    } finally {
      _downloading = false;
      _downloadProgress = null;
      notifyListeners();
    }
  }

  Future<List<GithubReleaseInfo>> _fetchReleases() async {
    final response = await _requestJson(
      _apiBaseUri.resolve('/repos/$_repositoryOwner/$_repositoryName/releases'),
    );
    final list = response as List<dynamic>;
    return list.whereType<Map<String, dynamic>>().map(_releaseFromJson).toList()
      ..sort((left, right) => right.publishedAt.compareTo(left.publishedAt));
  }

  GithubReleaseInfo _releaseFromJson(Map<String, dynamic> json) {
    final assets = (json['assets'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (assetJson) => GithubReleaseAsset(
            name: assetJson['name'] as String,
            downloadUri: Uri.parse(assetJson['browser_download_url'] as String),
            sizeBytes: assetJson['size'] as int? ?? 0,
          ),
        )
        .toList();
    return GithubReleaseInfo(
      tagName: json['tag_name'] as String? ?? '',
      name: json['name'] as String? ?? '',
      htmlUri: Uri.parse(
        json['html_url'] as String? ??
            'https://github.com/$_repositoryOwner/$_repositoryName',
      ),
      publishedAt:
          DateTime.tryParse(json['published_at'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      prerelease: json['prerelease'] as bool? ?? false,
      draft: json['draft'] as bool? ?? false,
      assets: assets,
    );
  }

  GithubReleaseInfo? _selectRelease(List<GithubReleaseInfo> releases) {
    final filtered = releases.where((release) {
      if (release.draft) {
        return false;
      }
      return switch (buildInfo.channel) {
        UpdateChannel.nightly =>
          release.prerelease &&
              release.tagName.toLowerCase().contains('nightly'),
        UpdateChannel.stable => !release.prerelease,
      };
    });
    return filtered.isEmpty ? null : filtered.first;
  }

  GithubReleaseAsset? _selectPlatformAsset(GithubReleaseInfo release) {
    final assets = release.assets.where((asset) {
      final name = asset.name.toLowerCase();
      if (name.contains('relay')) {
        return false;
      }
      return switch (_targetPlatform) {
        UpdateTargetPlatform.android =>
          name.endsWith('.apk') && name.contains('android'),
        UpdateTargetPlatform.linux =>
          name.endsWith('.zip') && name.contains('linux'),
        UpdateTargetPlatform.windows =>
          name.endsWith('.zip') &&
              name.contains('windows') &&
              name.contains('portable'),
        UpdateTargetPlatform.unsupported => false,
      };
    });
    return assets.isEmpty ? null : assets.first;
  }

  bool _matchesCurrentBuild(String releaseTag) {
    final normalizedRelease = _normalizeReleaseIdentity(releaseTag);
    final currentTag = buildInfo.buildTag;
    if (currentTag != null && currentTag.trim().isNotEmpty) {
      return _normalizeReleaseIdentity(currentTag) == normalizedRelease;
    }
    if (buildInfo.channel == UpdateChannel.stable) {
      return _normalizeReleaseIdentity(buildInfo.version) == normalizedRelease;
    }
    return false;
  }

  String _normalizeReleaseIdentity(String value) {
    final trimmed = value.trim().toLowerCase();
    return trimmed.startsWith('v') ? trimmed.substring(1) : trimmed;
  }

  Future<dynamic> _requestJson(Uri uri) async {
    final text = await _downloadText(uri);
    return jsonDecode(text);
  }

  Future<String> _downloadText(Uri uri) async {
    return utf8.decode(await _downloadBytes(uri));
  }

  Future<List<int>> _downloadBytes(Uri uri) async {
    final client = _httpClientFactory();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      final response = await request.close();
      if (response.statusCode >= 400) {
        throw HttpException(
          'HTTP ${response.statusCode} while requesting $uri',
          uri: uri,
        );
      }
      return await consolidateHttpClientResponseBytes(response);
    } finally {
      client.close(force: true);
    }
  }

  Future<ReleaseManifest> _fetchVerifiedReleaseManifest(
    GithubReleaseInfo release,
  ) async {
    final publicKeyText = _releaseManifestPublicKeyBase64.trim();
    if (publicKeyText.isEmpty) {
      throw StateError(
        'No release manifest public key is configured for update verification.',
      );
    }
    final manifestAsset = _requiredReleaseAsset(release, _releaseManifestName);
    final signatureAsset = _requiredReleaseAsset(
      release,
      _releaseManifestSignatureName,
    );
    final manifestBytes = await _downloadBytes(manifestAsset.downloadUri);
    final signatureText = utf8.decode(
      await _downloadBytes(signatureAsset.downloadUri),
    );
    final publicKeyBytes = _decodeBase64Flexible(publicKeyText);
    final signatureBytes = _decodeBase64Flexible(signatureText.trim());
    final algorithm = Ed25519();
    final verified = await algorithm.verify(
      manifestBytes,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      ),
    );
    if (!verified) {
      throw StateError(
        'Release manifest signature verification failed for ${release.tagName}.',
      );
    }
    final decoded = jsonDecode(utf8.decode(manifestBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Release manifest must be a JSON object.');
    }
    final manifest = ReleaseManifest.fromJson(decoded);
    if (_normalizeReleaseIdentity(manifest.tagName) !=
        _normalizeReleaseIdentity(release.tagName)) {
      throw StateError(
        'Release manifest tag ${manifest.tagName} does not match ${release.tagName}.',
      );
    }
    return manifest;
  }

  GithubReleaseAsset _requiredReleaseAsset(
    GithubReleaseInfo release,
    String name,
  ) {
    final matches = release.assets.where((asset) => asset.name == name);
    if (matches.isEmpty) {
      throw StateError('Release ${release.tagName} does not include $name.');
    }
    return matches.first;
  }

  List<int> _decodeBase64Flexible(String value) {
    final normalized = value.trim().replaceAll(RegExp(r'\s+'), '');
    try {
      return base64Decode(normalized);
    } on FormatException {
      final padded = base64Url.normalize(normalized);
      return base64Url.decode(padded);
    }
  }

  Future<void> _downloadBinary(
    Uri uri,
    File destination, {
    required String expectedSha256Hex,
  }) async {
    final client = _httpClientFactory();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      final response = await request.close();
      if (response.statusCode >= 400) {
        throw HttpException(
          'HTTP ${response.statusCode} while downloading $uri',
          uri: uri,
        );
      }
      await destination.parent.create(recursive: true);
      final sink = destination.openWrite();
      final contentLength = response.contentLength;
      var received = 0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (contentLength > 0) {
            _downloadProgress = received / contentLength;
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
      final digest = sha256
          .convert(await destination.readAsBytes())
          .toString()
          .toLowerCase();
      if (digest != expectedSha256Hex.toLowerCase()) {
        throw StateError(
          'SHA256 mismatch for ${destination.path}: expected $expectedSha256Hex, got $digest.',
        );
      }
      _downloadProgress = 1;
      notifyListeners();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _prepareAndApplyDesktopUpdate({
    required File archiveFile,
    required String releaseTag,
  }) async {
    final supportDir = await _applicationSupportDirectoryProvider();
    final stagingRoot = Directory(
      p.join(supportDir.path, 'updates', releaseTag, 'staging'),
    );
    if (await stagingRoot.exists()) {
      await stagingRoot.delete(recursive: true);
    }
    await stagingRoot.create(recursive: true);
    final archive = ZipDecoder().decodeBytes(await archiveFile.readAsBytes());
    await _extractArchive(archive, stagingRoot);
    final sourceRoot = await _resolveArchiveRoot(stagingRoot);
    final appExecutable = File(Platform.resolvedExecutable);
    final bundleDir = appExecutable.parent;
    final helperName = _targetPlatform == UpdateTargetPlatform.windows
        ? 'conest_updater.exe'
        : 'conest_updater';
    final bundledHelper = File(p.join(bundleDir.path, helperName));
    final stagedHelper = File(p.join(sourceRoot.path, helperName));
    final helperSource = await bundledHelper.exists()
        ? bundledHelper
        : stagedHelper;
    if (!await helperSource.exists()) {
      throw StateError(
        'Desktop updater helper $helperName was not found in the current bundle or the downloaded update.',
      );
    }
    if (_targetPlatform == UpdateTargetPlatform.linux) {
      await _ensureExecutable(sourceRoot, p.basename(appExecutable.path));
      await _ensureExecutable(sourceRoot, helperName);
    }
    final tempDir = await _tempDirectoryProvider();
    final helperRunDir = Directory(
      p.join(
        tempDir.path,
        'conest-updater-${releaseTag.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}',
      ),
    );
    if (await helperRunDir.exists()) {
      await helperRunDir.delete(recursive: true);
    }
    await helperRunDir.create(recursive: true);
    final launchedHelper = await helperSource.copy(
      p.join(helperRunDir.path, helperName),
    );
    if (_targetPlatform == UpdateTargetPlatform.linux) {
      await Process.run('chmod', ['755', launchedHelper.path]);
    }
    _statusMessage = 'Restarting to apply $releaseTag...';
    notifyListeners();
    unawaited(
      Process.start(launchedHelper.path, [
        '--staging-dir',
        sourceRoot.path,
        '--bundle-dir',
        bundleDir.path,
        '--app-binary',
        p.basename(appExecutable.path),
      ], mode: ProcessStartMode.detached),
    );
    _exitCallback(0);
  }

  Future<void> _extractArchive(Archive archive, Directory outputDir) async {
    for (final entry in archive) {
      final normalized = p.normalize(entry.name.replaceAll('\\', '/'));
      if (normalized.isEmpty ||
          normalized == '.' ||
          normalized == '..' ||
          p.isAbsolute(normalized) ||
          normalized.startsWith('../')) {
        throw StateError('Unsafe archive entry: ${entry.name}');
      }
      final outPath = p.join(outputDir.path, normalized);
      if (entry.isFile) {
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(entry.content as List<int>, flush: true);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
  }

  Future<Directory> _resolveArchiveRoot(Directory stagingRoot) async {
    final entries = await stagingRoot
        .list()
        .map((entry) => p.basename(entry.path))
        .toList();
    if (entries.length == 1) {
      final candidate = Directory(p.join(stagingRoot.path, entries.first));
      if (await candidate.exists()) {
        return candidate;
      }
    }
    return stagingRoot;
  }

  Future<void> _ensureExecutable(
    Directory sourceRoot,
    String relativeName,
  ) async {
    final file = File(p.join(sourceRoot.path, relativeName));
    if (!await file.exists()) {
      return;
    }
    await Process.run('chmod', ['755', file.path]);
  }

  String get _userAgent =>
      'Conest/${buildInfo.version} (${buildInfo.channelLabel}; ${_targetPlatform.label})';
}

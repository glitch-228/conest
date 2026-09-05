import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pub_semver/pub_semver.dart';

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
    this.body,
  });

  final String tagName;
  final String name;
  final Uri htmlUri;
  final DateTime publishedAt;
  final bool prerelease;
  final bool draft;
  final List<GithubReleaseAsset> assets;
  final String? body;
}

class UpdateAvailability {
  const UpdateAvailability({
    required this.release,
    required this.asset,
    required this.sha256Hex,
    this.releaseNotes,
  });

  final GithubReleaseInfo release;
  final GithubReleaseAsset asset;
  final String sha256Hex;

  /// Resolved release notes text. Manifest-baked notes are preferred (signed,
  /// tamper-proof); the GitHub release body is consulted as a fallback when
  /// the manifest does not embed notes. Null when no source produced text.
  final String? releaseNotes;
}

typedef DesktopUpdaterLauncher =
    Future<void> Function(String executable, List<String> arguments);

const _releaseManifestName = 'RELEASE-MANIFEST.json';
const _releaseManifestSignatureName = 'RELEASE-MANIFEST.ed25519.sig';
const int _maxMetadataBytes = 1024 * 1024;
const int _maxManifestBytes = 512 * 1024;
const int _maxManifestSignatureBytes = 4096;
const int _maxUpdateAssetBytes = 1024 * 1024 * 1024;
const Duration _metadataTimeout = Duration(seconds: 15);
const Duration _assetTimeout = Duration(minutes: 10);
const _releaseManifestPublicKeyFromEnvironment = String.fromEnvironment(
  'CONEST_RELEASE_MANIFEST_PUBLIC_KEY',
);

class ReleaseManifestAsset {
  const ReleaseManifestAsset({
    required this.name,
    required this.sha256Hex,
    required this.sizeBytes,
    this.role,
    this.platform,
    this.architecture,
  });

  final String name;
  final String sha256Hex;
  final int? sizeBytes;
  final String? role;
  final String? platform;
  final String? architecture;

  factory ReleaseManifestAsset.fromJson(
    Map<String, dynamic> json, {
    bool requireTargetMetadata = false,
  }) {
    final name = json['name'] as String? ?? '';
    final sha256Hex = (json['sha256'] as String? ?? '').toLowerCase();
    final size = json['sizeBytes'] as int?;
    if (name.isEmpty) {
      throw const FormatException('Release manifest asset name is empty.');
    }
    if (name.length > 160 || p.basename(name) != name) {
      throw const FormatException('Release manifest asset name is unsafe.');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256Hex)) {
      throw FormatException('Release manifest has invalid sha256 for $name.');
    }
    if (size == null || size <= 0 || size > _maxUpdateAssetBytes) {
      throw FormatException('Release manifest has invalid size for $name.');
    }
    final role = json['role'] as String?;
    final platform = json['platform'] as String?;
    final architecture = json['architecture'] as String?;
    if (requireTargetMetadata &&
        ((role?.isEmpty ?? true) ||
            (platform?.isEmpty ?? true) ||
            (architecture?.isEmpty ?? true))) {
      throw FormatException(
        'Release manifest target metadata is missing for $name.',
      );
    }
    return ReleaseManifestAsset(
      name: name,
      sha256Hex: sha256Hex,
      sizeBytes: size,
      role: role,
      platform: platform,
      architecture: architecture,
    );
  }
}

class ReleaseManifest {
  const ReleaseManifest({
    required this.version,
    required this.tagName,
    required this.assets,
    this.releaseNotes,
    this.releaseVersion,
    this.channel,
    this.minimumSupervisorVersion,
  });

  final int version;
  final String tagName;
  final Map<String, ReleaseManifestAsset> assets;

  /// Optional, signed release notes baked into the manifest at build time.
  /// Empty or null on nightlies and on legacy manifests; renders as the
  /// "What's new" section in the update prompt when present.
  final String? releaseNotes;
  final String? releaseVersion;
  final String? channel;
  final String? minimumSupervisorVersion;

  factory ReleaseManifest.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? 0;
    if (version != 1 && version != 2) {
      throw FormatException('Unsupported release manifest version: $version.');
    }
    final tagName = json['tagName'] as String? ?? '';
    if (tagName.isEmpty) {
      throw const FormatException('Release manifest tagName is empty.');
    }
    final assetValues = json['assets'] as List<dynamic>? ?? const [];
    if (tagName.length > 128 || assetValues.length > 128) {
      throw const FormatException('Release manifest metadata is too large.');
    }
    final assets = <String, ReleaseManifestAsset>{};
    for (final value in assetValues) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException(
          'Release manifest asset must be an object.',
        );
      }
      final asset = ReleaseManifestAsset.fromJson(
        value,
        requireTargetMetadata: version >= 2,
      );
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
    final rawNotes = json['releaseNotes'];
    if (rawNotes is String && rawNotes.length > 64 * 1024) {
      throw const FormatException('Release notes are too large.');
    }
    final notes = rawNotes is String && rawNotes.trim().isNotEmpty
        ? rawNotes
        : null;
    final releaseVersion = json['releaseVersion'] as String?;
    final channel = json['channel'] as String?;
    final minimumSupervisorVersion =
        json['minimumSupervisorVersion'] as String?;
    if (version >= 2 &&
        ((releaseVersion?.isEmpty ?? true) ||
            (channel != 'stable' && channel != 'nightly') ||
            (minimumSupervisorVersion?.isEmpty ?? true))) {
      throw const FormatException(
        'Release manifest v2 metadata is incomplete.',
      );
    }
    return ReleaseManifest(
      version: version,
      tagName: tagName,
      assets: assets,
      releaseNotes: notes,
      releaseVersion: releaseVersion,
      channel: channel,
      minimumSupervisorVersion: minimumSupervisorVersion,
    );
  }

  ReleaseManifestAsset assetFor(GithubReleaseAsset asset) {
    final manifestAsset = assets[asset.name];
    if (manifestAsset == null) {
      throw StateError(
        'Release manifest for $tagName does not include ${asset.name}.',
      );
    }
    final expectedSize = manifestAsset.sizeBytes!;
    if (asset.sizeBytes <= 0 || expectedSize != asset.sizeBytes) {
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

@visibleForTesting
bool isReleaseTagNewerThan(String releaseTag, String currentTag) {
  String normalize(String value) {
    final trimmed = value.trim().toLowerCase();
    return trimmed.startsWith('v') ? trimmed.substring(1) : trimmed;
  }

  try {
    return Version.parse(normalize(releaseTag)) >
        Version.parse(normalize(currentTag));
  } catch (_) {
    return false;
  }
}

@visibleForTesting
String? resolveReleaseNotes({
  required String? manifestNotes,
  required String? releaseBody,
}) {
  if (manifestNotes != null && manifestNotes.trim().isNotEmpty) {
    return manifestNotes;
  }
  if (releaseBody != null && releaseBody.trim().isNotEmpty) {
    return releaseBody;
  }
  return null;
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
    DesktopUpdaterLauncher? desktopUpdaterLauncher,
    void Function(int code)? exitCallback,
    bool automaticStartupChecksEnabled = true,
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
       _desktopUpdaterLauncher =
           desktopUpdaterLauncher ?? _launchDetachedDesktopUpdater,
       _exitCallback = exitCallback ?? exit,
       _automaticStartupChecksEnabled = automaticStartupChecksEnabled;

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
  final DesktopUpdaterLauncher _desktopUpdaterLauncher;
  final void Function(int code) _exitCallback;
  final bool _automaticStartupChecksEnabled;

  bool _startupCheckStarted = false;
  bool _checking = false;
  bool _downloading = false;
  double? _downloadProgress;
  UpdateAvailability? _availableUpdate;
  DateTime? _lastCheckedAt;
  String? _statusMessage;
  String? _lastError;
  String? _dismissedPromptTagForSession;

  bool get supportsUpdates {
    // Debug builds are CI/local artifacts, never GitHub releases. Keeping
    // them outside the updater prevents a debug install from silently
    // replacing itself with a nightly that lacks the diagnostic protocol.
    if (buildInfo.channel == UpdateChannel.debug) {
      return false;
    }
    if (_targetPlatform == UpdateTargetPlatform.unsupported) {
      return false;
    }
    // A release build without a manifest verification key cannot safely apply
    // updates. Treat updates as unsupported so the UI shows a single clear
    // state instead of failing every poll with a generic error. Debug builds
    // keep the previous behavior so tests and local development still work.
    if (!buildInfo.isDebugBuild &&
        _releaseManifestPublicKeyBase64.trim().isEmpty) {
      return false;
    }
    return true;
  }

  /// True when this build is shipping-shaped (release mode, supported
  /// platform) but is missing the manifest verification key. Surfaces a
  /// dedicated "misconfigured build" state to the UI without falsely claiming
  /// updates are available.
  bool get isMissingReleaseManifestKey =>
      !buildInfo.isDebugBuild &&
      _targetPlatform != UpdateTargetPlatform.unsupported &&
      _releaseManifestPublicKeyBase64.trim().isEmpty;
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
    if (!_automaticStartupChecksEnabled ||
        _startupCheckStarted ||
        !supportsUpdates) {
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
      if (!_isNewerThanCurrentBuild(selected.tagName)) {
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
      final releaseNotes = _resolveReleaseNotes(
        manifest: manifest,
        release: selected,
      );
      _availableUpdate = UpdateAvailability(
        release: selected,
        asset: asset,
        sha256Hex: manifestAsset.sha256Hex,
        releaseNotes: releaseNotes,
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
        expectedSizeBytes: available.asset.sizeBytes,
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
    if (list.length > 128) {
      throw const FormatException(
        'Release metadata contains too many entries.',
      );
    }
    return list.whereType<Map<String, dynamic>>().map(_releaseFromJson).toList()
      ..sort((left, right) => right.publishedAt.compareTo(left.publishedAt));
  }

  GithubReleaseInfo _releaseFromJson(Map<String, dynamic> json) {
    final rawAssets = json['assets'] as List<dynamic>? ?? const [];
    if (rawAssets.length > 128) {
      throw const FormatException('Release has too many assets.');
    }
    final assets = rawAssets.whereType<Map<String, dynamic>>().map((assetJson) {
      final name = assetJson['name'] as String;
      final size = assetJson['size'] as int? ?? 0;
      if (name.isEmpty ||
          name.length > 160 ||
          p.basename(name) != name ||
          size <= 0 ||
          size > _maxUpdateAssetBytes) {
        throw const FormatException('Release asset metadata is invalid.');
      }
      return GithubReleaseAsset(
        name: name,
        downloadUri: Uri.parse(assetJson['browser_download_url'] as String),
        sizeBytes: size,
      );
    }).toList();
    final rawBody = json['body'];
    final body =
        rawBody is String &&
            rawBody.length <= 64 * 1024 &&
            rawBody.trim().isNotEmpty
        ? rawBody
        : null;
    final tagName = json['tag_name'] as String? ?? '';
    final releaseName = json['name'] as String? ?? '';
    if (tagName.length > 128 || releaseName.length > 256) {
      throw const FormatException('Release metadata fields are too large.');
    }
    return GithubReleaseInfo(
      tagName: tagName,
      name: releaseName,
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
      body: body,
    );
  }

  GithubReleaseInfo? _selectRelease(List<GithubReleaseInfo> releases) {
    final filtered = releases
        .where((release) {
          if (release.draft) {
            return false;
          }
          return switch (buildInfo.channel) {
            UpdateChannel.debug => false,
            UpdateChannel.nightly =>
              release.prerelease &&
                  release.tagName.toLowerCase().contains('nightly'),
            UpdateChannel.stable => !release.prerelease,
          };
        })
        .where((release) => _versionForTag(release.tagName) != null)
        .toList();
    filtered.sort(
      (left, right) => _versionForTag(
        right.tagName,
      )!.compareTo(_versionForTag(left.tagName)!),
    );
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

  /// Returns the resolved release notes for an available update.
  ///
  /// Order of precedence:
  ///   1. Every channel prefers `manifest.releaseNotes` — signed,
  ///      tamper-proof, baked in at build time.
  ///   2. Both channels fall back to the GitHub release `body`, which the
  ///      release workflow populates with `RELEASE_NOTES.md` (stable) or
  ///      `git log <prev-tag>..<tag>` (nightly / prerelease).
  String? _resolveReleaseNotes({
    required ReleaseManifest manifest,
    required GithubReleaseInfo release,
  }) => resolveReleaseNotes(
    manifestNotes: manifest.releaseNotes,
    releaseBody: release.body,
  );

  bool _isNewerThanCurrentBuild(String releaseTag) {
    final currentTag = buildInfo.buildTag;
    return isReleaseTagNewerThan(
      releaseTag,
      currentTag != null && currentTag.trim().isNotEmpty
          ? currentTag
          : buildInfo.version,
    );
  }

  Version? _versionForTag(String value) {
    try {
      return Version.parse(_normalizeReleaseIdentity(value));
    } catch (_) {
      return null;
    }
  }

  String _normalizeReleaseIdentity(String value) {
    final trimmed = value.trim().toLowerCase();
    return trimmed.startsWith('v') ? trimmed.substring(1) : trimmed;
  }

  Future<dynamic> _requestJson(Uri uri) async {
    final text = await _downloadText(uri, maxBytes: _maxMetadataBytes);
    return jsonDecode(text);
  }

  Future<String> _downloadText(Uri uri, {required int maxBytes}) async {
    return utf8.decode(await _downloadBytes(uri, maxBytes: maxBytes));
  }

  Future<List<int>> _downloadBytes(
    Uri uri, {
    required int maxBytes,
    Duration timeout = _metadataTimeout,
  }) async {
    _validateUpdateUri(uri);
    final client = _httpClientFactory();
    try {
      client.connectionTimeout = timeout;
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      final response = await request.close().timeout(timeout);
      if (response.statusCode >= 400) {
        throw HttpException(
          'HTTP ${response.statusCode} while requesting $uri',
          uri: uri,
        );
      }
      if (response.contentLength > maxBytes) {
        throw StateError('Update response exceeds the allowed size.');
      }
      final builder = BytesBuilder(copy: false);
      var received = 0;
      await (() async {
        await for (final chunk in response.timeout(timeout)) {
          received += chunk.length;
          if (received > maxBytes) {
            throw StateError('Update response exceeds the allowed size.');
          }
          builder.add(chunk);
        }
      })().timeout(timeout);
      return builder.takeBytes();
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
    if (manifestAsset.sizeBytes > _maxManifestBytes ||
        signatureAsset.sizeBytes > _maxManifestSignatureBytes) {
      throw StateError('Release trust metadata exceeds the allowed size.');
    }
    final manifestBytes = await _downloadBytes(
      manifestAsset.downloadUri,
      maxBytes: _maxManifestBytes,
    );
    final signatureText = utf8.decode(
      await _downloadBytes(
        signatureAsset.downloadUri,
        maxBytes: _maxManifestSignatureBytes,
      ),
    );
    final publicKeyBytes = _decodeBase64Flexible(publicKeyText);
    final signatureBytes = _decodeBase64Flexible(signatureText.trim());
    if (publicKeyBytes.length != 32 || signatureBytes.length != 64) {
      throw const FormatException(
        'Release signing key or signature is invalid.',
      );
    }
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
    required int expectedSizeBytes,
  }) async {
    _validateUpdateUri(uri);
    if (expectedSizeBytes <= 0 || expectedSizeBytes > _maxUpdateAssetBytes) {
      throw StateError('Update asset size is missing or exceeds the limit.');
    }
    final client = _httpClientFactory();
    final partial = File('${destination.path}.part');
    try {
      client.connectionTimeout = _metadataTimeout;
      final request = await client.getUrl(uri).timeout(_metadataTimeout);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      final response = await request.close().timeout(_metadataTimeout);
      if (response.statusCode >= 400) {
        throw HttpException(
          'HTTP ${response.statusCode} while downloading $uri',
          uri: uri,
        );
      }
      if (response.contentLength > 0 &&
          response.contentLength != expectedSizeBytes) {
        throw StateError('Update Content-Length does not match the manifest.');
      }
      await destination.parent.create(recursive: true);
      if (await partial.exists()) await partial.delete();
      final sink = partial.openWrite();
      var received = 0;
      try {
        await (() async {
          await for (final chunk in response.timeout(_metadataTimeout)) {
            received += chunk.length;
            if (received > expectedSizeBytes ||
                received > _maxUpdateAssetBytes) {
              throw StateError('Update download exceeded its signed size.');
            }
            sink.add(chunk);
            _downloadProgress = received / expectedSizeBytes;
            notifyListeners();
          }
        })().timeout(_assetTimeout);
      } finally {
        await sink.close();
      }
      if (received != expectedSizeBytes) {
        throw StateError('Update download ended before its signed size.');
      }
      final digest = (await sha256.bind(partial.openRead()).first)
          .toString()
          .toLowerCase();
      if (digest != expectedSha256Hex.toLowerCase()) {
        throw StateError(
          'SHA256 mismatch for ${destination.path}: expected $expectedSha256Hex, got $digest.',
        );
      }
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
      _downloadProgress = 1;
      notifyListeners();
    } catch (_) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  void _validateUpdateUri(Uri uri) {
    if (uri.scheme == 'https') return;
    final address = InternetAddress.tryParse(uri.host);
    if (uri.scheme == 'http' && address?.isLoopback == true) return;
    throw StateError('Update downloads require HTTPS.');
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
    var expandedBytes = 0;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      expandedBytes += entry.size;
      if (entry.size < 0 || expandedBytes > 2 * _maxUpdateAssetBytes) {
        throw StateError('Update archive expands beyond the allowed size.');
      }
    }
    await _extractArchive(archive, stagingRoot);
    final sourceRoot = await _resolveArchiveRoot(stagingRoot);
    final appExecutable = File(Platform.resolvedExecutable);
    final bundleDir = appExecutable.parent;
    final helperName = _targetPlatform == UpdateTargetPlatform.windows
        ? 'conest_updater.exe'
        : 'conest_updater';
    final bundledHelper = File(p.join(bundleDir.path, helperName));
    final stagedHelper = File(p.join(sourceRoot.path, helperName));
    final helperSource = await stagedHelper.exists()
        ? stagedHelper
        : bundledHelper;
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
    // nightly.11: pass the application-support directory so the updater
    // can wait for the previous instance's conest.lock to be releasable
    // before launching the new binary (Windows file-lock teardown races
    // were the user-reported "Conest is already running" with no window).
    final appSupportDir = await _applicationSupportDirectoryProvider();
    await _desktopUpdaterLauncher(launchedHelper.path, [
      '--staging-dir',
      sourceRoot.path,
      '--bundle-dir',
      bundleDir.path,
      '--app-binary',
      p.basename(appExecutable.path),
      '--data-root',
      appSupportDir.path,
    ]);
    _exitCallback(0);
  }

  Future<void> _extractArchive(Archive archive, Directory outputDir) async {
    for (final entry in archive) {
      final rawName = entry.name.replaceAll('\\', '/');
      // Reject Windows-style drive letters or UNC roots even when running on
      // a POSIX host where p.isAbsolute would otherwise miss them.
      if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(rawName) ||
          rawName.startsWith('//')) {
        throw StateError('Unsafe archive entry: ${entry.name}');
      }
      final normalized = p.posix.normalize(rawName);
      if (normalized.isEmpty ||
          normalized == '.' ||
          normalized == '..' ||
          p.posix.isAbsolute(normalized) ||
          p.isAbsolute(normalized) ||
          normalized.startsWith('../') ||
          normalized.contains('/../')) {
        throw StateError('Unsafe archive entry: ${entry.name}');
      }
      final outPath = p.join(outputDir.path, normalized);
      if (entry.isFile) {
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(entry.content as List<int>, flush: true);
      } else if (entry.isSymbolicLink) {
        // The desktop updater bundles plain files only. Refuse symlinks so a
        // malicious or malformed archive cannot smuggle one in.
        throw StateError(
          'Archive contains a symbolic link entry which is not allowed: ${entry.name}',
        );
      } else if (rawName.endsWith('/')) {
        await Directory(outPath).create(recursive: true);
      } else {
        throw StateError('Unsupported archive entry type: ${entry.name}');
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

Future<void> _launchDetachedDesktopUpdater(
  String executable,
  List<String> arguments,
) async {
  await Process.start(executable, arguments, mode: ProcessStartMode.detached);
}

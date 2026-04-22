import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

enum UpdateChannel {
  stable('stable'),
  nightly('nightly');

  const UpdateChannel(this.label);

  final String label;

  static UpdateChannel parse(String? value) {
    return switch (value?.trim().toLowerCase()) {
      'nightly' || 'beta' || 'debug' => UpdateChannel.nightly,
      _ => UpdateChannel.stable,
    };
  }
}

class ConestBuildInfo {
  ConestBuildInfo({
    required this.appName,
    required this.packageName,
    required this.version,
    required this.buildNumber,
    required this.channel,
    required this.isDebugBuild,
    this.buildTag,
    this.commit,
  });

  final String appName;
  final String packageName;
  final String version;
  final String buildNumber;
  final UpdateChannel channel;
  final bool isDebugBuild;
  final String? buildTag;
  final String? commit;

  String get channelLabel => channel.label;

  String get displayVersion {
    final tag = buildTag?.trim();
    if (tag != null && tag.isNotEmpty) {
      return tag;
    }
    return version;
  }

  bool get hasExactReleaseTag {
    final tag = buildTag?.trim();
    return tag != null && tag.isNotEmpty;
  }

  static Future<ConestBuildInfo> load({
    Future<PackageInfo> Function()? packageInfoLoader,
  }) async {
    final packageInfo = await (packageInfoLoader ?? PackageInfo.fromPlatform)
        .call();
    const envTag = String.fromEnvironment('CONEST_BUILD_TAG');
    const envChannel = String.fromEnvironment('CONEST_BUILD_CHANNEL');
    const envCommit = String.fromEnvironment('CONEST_BUILD_COMMIT');
    final tag = envTag.trim();
    final commit = envCommit.trim();
    return ConestBuildInfo(
      appName: packageInfo.appName,
      packageName: packageInfo.packageName,
      version: packageInfo.version,
      buildNumber: packageInfo.buildNumber,
      channel: envChannel.trim().isNotEmpty
          ? UpdateChannel.parse(envChannel)
          : (kDebugMode ? UpdateChannel.nightly : UpdateChannel.stable),
      isDebugBuild: kDebugMode,
      buildTag: tag.isEmpty ? null : tag,
      commit: commit.isEmpty ? null : commit,
    );
  }
}

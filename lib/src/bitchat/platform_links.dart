import 'dart:io';

import 'android_links.dart';
import 'desktop_links.dart';
import 'mesh.dart';

/// Select the OS link implementation; optional factories keep the selection
/// testable without Bluetooth hardware or a native library.
Future<BitchatLinkLayer> openPlatformBitchatLinks({
  String? operatingSystem,
  Future<BitchatLinkLayer> Function()? openAndroid,
  Future<BitchatLinkLayer> Function()? openDesktop,
}) => switch (operatingSystem ?? Platform.operatingSystem) {
  'android' => (openAndroid ?? AndroidBitchatLinks.start)(),
  'linux' || 'windows' => (openDesktop ?? DesktopBitchatLinks.start)(),
  _ => throw UnsupportedError(
    'The Bluetooth mesh needs Android, Linux or Windows.',
  ),
};

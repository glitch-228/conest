import 'dart:typed_data';
import 'dart:ui' as ui;

import 'xmpp_registration.dart';

/// Whether the engine reads [image] as a picture within the CAPTCHA size
/// limits, asked of its decoder without decoding any pixels. A second layer
/// behind the header check: whatever the header said, the decoder's own idea
/// of the size decides.
Future<bool> captchaImageFitsToShow(Uint8List image) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(image);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return descriptor.width > 0 &&
        descriptor.height > 0 &&
        descriptor.width <= maxCaptchaSide &&
        descriptor.height <= maxCaptchaSide &&
        descriptor.width * descriptor.height <= maxCaptchaPixels;
  } catch (_) {
    return false;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

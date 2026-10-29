import 'dart:io';

import 'package:path/path.dart' as p;

import '../media_sanitizer.dart';

/// A file ready for an XMPP upload: a private copy with its metadata
/// removed (the same cleaning as Conest's own files), or the reason it
/// could not be.
class XmppUploadFile {
  const XmppUploadFile(this.file, this.status);
  final File file;
  final SanitizeStatus status;

  /// Metadata may remain: sending needs the user's consent.
  bool get needsConsent =>
      status == SanitizeStatus.partial || status == SanitizeStatus.failed;

  Future<void> discard() async {
    try {
      await file.parent.delete(recursive: true);
    } catch (_) {}
  }
}

/// Copies [path] into a fresh temporary folder (keeping its name, which
/// the upload shows) and strips its metadata.
Future<XmppUploadFile> prepareXmppUpload(String path) async {
  final folder = await Directory.systemTemp.createTemp('conest_xmpp_');
  final copy = await File(path).copy(p.join(folder.path, p.basename(path)));
  final status = await MediaSanitizer.sanitizeFile(copy.path);
  return XmppUploadFile(copy, status);
}

/// A content type for [name] from its extension, for the upload slot.
String xmppContentType(String name) =>
    switch (p.extension(name).toLowerCase()) {
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.mp4' => 'video/mp4',
      '.webm' => 'video/webm',
      '.mp3' => 'audio/mpeg',
      '.ogg' || '.opus' => 'audio/ogg',
      '.m4a' => 'audio/mp4',
      '.pdf' => 'application/pdf',
      '.txt' => 'text/plain',
      _ => 'application/octet-stream',
    };

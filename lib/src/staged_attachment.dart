import 'dart:io';
import 'dart:typed_data';

/// nightly.10 central staging model: every input pipeline (media picker,
/// drag-and-drop, clipboard paste, Ctrl+V) builds these and hands them to
/// `MessengerController.stageAttachments`. The composer renders the
/// staged list as previews-with-X above the TextField; Send commits the
/// bundle via `sendStagedBundle`.
///
/// Bytes are kept lazy when possible — a desktop drag-drop of a 1 GB
/// file shouldn't sit in RAM until the user taps Send. The picker and
/// clipboard paths populate `bytes` directly because they've already
/// read the content; the file/drag-drop paths populate `filePath` and
/// `readBytes()` reads on demand.
class StagedAttachment {
  StagedAttachment({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    Uint8List? bytes,
    String? filePath,
    this.poster,
    this.caption = '',
  }) : _bytes = bytes,
       _filePath = filePath,
       assert(
         bytes != null || filePath != null,
         'StagedAttachment needs either bytes or a filePath',
       );

  /// Ephemeral id used by the X-to-cancel button to identify which staged
  /// item to drop. Not stable across app restarts.
  final String id;

  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final Uint8List? _bytes;
  final String? _filePath;
  final Uint8List? poster;
  final String caption;

  /// True when the bytes are already resident (picker, clipboard paste).
  /// False when only the file path is known (drag-drop, file picker).
  bool get hasInlineBytes => _bytes != null;

  Future<Uint8List> readBytes() async {
    final inline = _bytes;
    if (inline != null) return inline;
    final path = _filePath;
    if (path != null) {
      return await File(path).readAsBytes();
    }
    throw StateError('StagedAttachment has no source.');
  }

  /// Cheap preview bytes for the staged tray. Returns the inline bytes
  /// directly if small enough, otherwise null and the UI shows a generic
  /// file-type icon. Doesn't trigger a disk read.
  Uint8List? get previewBytesIfCheap {
    final b = _bytes;
    if (b == null || b.length > 512 * 1024) return null;
    return b;
  }

  /// Returns a copy with [caption] replaced. Bytes / file path / poster
  /// are shared (not copied) — cheap.
  StagedAttachment copyWith({String? caption}) {
    return StagedAttachment(
      id: id,
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      bytes: _bytes,
      filePath: _filePath,
      poster: poster,
      caption: caption ?? this.caption,
    );
  }
}

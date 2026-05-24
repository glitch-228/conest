import 'dart:collection';
import 'dart:io';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:photo_manager/photo_manager.dart';

import 'conest_theme.dart';

/// Outcome of the media picker sheet: send a single asset, send a batch of
/// already-resolved bytes (multi-select), or fall through to the general
/// file-picker flow.
class MediaPickerResult {
  MediaPickerResult.send({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  }) : fallbackToFilePicker = false,
       items = null;

  MediaPickerResult.sendMultiple({required this.items})
    : bytes = null,
      fileName = null,
      mimeType = null,
      fallbackToFilePicker = false;

  bool get hasItems => items != null && items!.isNotEmpty;

  MediaPickerResult.fallback()
    : bytes = null,
      fileName = null,
      mimeType = null,
      fallbackToFilePicker = true,
      items = null;

  final Uint8List? bytes;
  final String? fileName;
  final String? mimeType;
  final bool fallbackToFilePicker;
  final List<
    ({
      Uint8List bytes,
      String fileName,
      String mimeType,
      String caption,
      Uint8List? poster,
    })
  >?
  items;
}

/// True on platforms where photo_manager actually has a backing implementation.
bool get _supportsGallery {
  if (kIsWeb) return false;
  return Platform.isAndroid || Platform.isIOS;
}

/// Bottom-sheet entry point. Returns the chosen action, or null if the user
/// dismissed without picking anything.
Future<MediaPickerResult?> showMediaPickerSheet({
  required BuildContext context,
  required ConestPalette palette,
  required int maxBytes,
}) async {
  if (!_supportsGallery) {
    // Desktop / web have no native gallery — fall through to the file picker.
    return MediaPickerResult.fallback();
  }
  return showModalBottomSheet<MediaPickerResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: palette.paper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) =>
        _MediaPickerSheet(palette: palette, maxBytes: maxBytes),
  );
}

class _MediaPickerSheet extends StatefulWidget {
  const _MediaPickerSheet({required this.palette, required this.maxBytes});

  final ConestPalette palette;
  final int maxBytes;

  @override
  State<_MediaPickerSheet> createState() => _MediaPickerSheetState();
}

class _MediaPickerSheetState extends State<_MediaPickerSheet> {
  // Picker cap matches MessengerController.maxAttachmentsPerSend; the sender
  // splits larger batches into albums of 6 on the fly.
  static const int _maxBatch = 30;

  PermissionState? _permission;
  List<AssetEntity> _assets = const [];
  bool _loading = true;
  final LinkedHashSet<String> _selectedIds = LinkedHashSet<String>();
  final Map<String, String> _captionsById = <String, String>{};
  final Map<String, TextEditingController> _captionControllers =
      <String, TextEditingController>{};
  final Map<String, int?> _sizeBytesById = <String, int?>{};
  bool _sending = false;

  bool get _selectionMode => _selectedIds.isNotEmpty;

  TextEditingController _captionControllerFor(String id) {
    return _captionControllers.putIfAbsent(id, () {
      final c = TextEditingController(text: _captionsById[id] ?? '');
      c.addListener(() {
        _captionsById[id] = c.text;
      });
      return c;
    });
  }

  Future<int?> _resolveAssetSize(AssetEntity asset) async {
    if (_sizeBytesById.containsKey(asset.id)) return _sizeBytesById[asset.id];
    try {
      final file = await asset.file;
      if (file == null) {
        _sizeBytesById[asset.id] = null;
        return null;
      }
      final length = await file.length();
      _sizeBytesById[asset.id] = length;
      return length;
    } catch (_) {
      _sizeBytesById[asset.id] = null;
      return null;
    }
  }

  @override
  void dispose() {
    for (final c in _captionControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!mounted) return;
    setState(() => _permission = permission);
    if (permission.isAuth || permission.hasAccess) {
      try {
        final paths = await PhotoManager.getAssetPathList(
          type: RequestType.common,
          onlyAll: true,
          filterOption: FilterOptionGroup(
            orders: const [
              OrderOption(type: OrderOptionType.createDate, asc: false),
            ],
          ),
        );
        if (paths.isEmpty) {
          if (mounted) setState(() => _loading = false);
          return;
        }
        final assets = await paths.first.getAssetListPaged(page: 0, size: 60);
        if (!mounted) return;
        setState(() {
          _assets = assets;
          _loading = false;
        });
      } catch (_) {
        if (mounted) setState(() => _loading = false);
      }
    } else {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  String _humanDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _mimeForAsset(AssetEntity asset, String fileName) {
    final lower = fileName.toLowerCase();
    if (asset.type == AssetType.video) {
      if (lower.endsWith('.mov')) return 'video/quicktime';
      if (lower.endsWith('.webm')) return 'video/webm';
      return 'video/mp4';
    }
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  void _toggleSelection(AssetEntity asset) {
    setState(() {
      if (_selectedIds.contains(asset.id)) {
        _selectedIds.remove(asset.id);
      } else if (_selectedIds.length < _maxBatch) {
        _selectedIds.add(asset.id);
      } else {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Max $_maxBatch items per send.')),
        );
      }
    });
  }

  void _longPressAsset(AssetEntity asset) {
    if (_selectedIds.contains(asset.id)) {
      return;
    }
    setState(() {
      if (_selectedIds.length < _maxBatch) {
        _selectedIds.add(asset.id);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedIds.clear());
  }

  Future<void> _sendSelected() async {
    if (_sending || _selectedIds.isEmpty) return;
    setState(() => _sending = true);
    final byId = {for (final a in _assets) a.id: a};
    final items =
        <
          ({
            Uint8List bytes,
            String fileName,
            String mimeType,
            String caption,
            Uint8List? poster,
          })
        >[];
    for (final id in _selectedIds) {
      final asset = byId[id];
      if (asset == null) continue;
      try {
        final file = await asset.file;
        if (file == null) continue;
        final bytes = await file.readAsBytes();
        final fileName = asset.title ?? 'media-${asset.id}';
        // For videos, photo_manager already generates a thumbnail —
        // reuse it as the offer-envelope poster so the receiver sees a
        // preview before the full bytes finish transferring.
        Uint8List? poster;
        if (asset.type == AssetType.video) {
          try {
            poster = await asset.thumbnailDataWithSize(
              const ThumbnailSize.square(320),
            );
            // Cap at ~32 KB to fit in the relay envelope.
            if (poster != null && poster.length > 32 * 1024) {
              poster = null;
            }
          } catch (_) {
            poster = null;
          }
        }
        items.add((
          bytes: bytes,
          fileName: fileName,
          mimeType: _mimeForAsset(asset, fileName),
          caption: _captionsById[id]?.trim() ?? '',
          poster: poster,
        ));
      } catch (_) {
        // Skip unreadable assets; the rest of the batch still goes.
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(MediaPickerResult.sendMultiple(items: items));
  }

  Future<void> _pickAsset(AssetEntity asset) async {
    if (_selectionMode) {
      _toggleSelection(asset);
      return;
    }
    final file = await asset.file;
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final fileName = asset.title ?? 'media-${asset.id}';
    final mime = _mimeForAsset(asset, fileName);
    if (asset.type == AssetType.image) {
      // Editor pops with edited bytes ONLY on explicit Send. Back / cancel
      // (with or without dirty edits) pops with null — never silently
      // sends the unedited original. The previous `edited ?? bytes`
      // fallback shipped the original on cancel, which the user reported.
      final edited = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          builder: (_) =>
              MediaEditorScreen(sourceBytes: bytes, palette: widget.palette),
        ),
      );
      if (!mounted) return;
      if (edited == null) {
        // User backed out — do not send.
        return;
      }
      if (edited.length > widget.maxBytes) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              'Image is larger than the ${widget.maxBytes ~/ (1024 * 1024)} MB cap.',
            ),
          ),
        );
        return;
      }
      Navigator.of(context).pop(
        MediaPickerResult.send(
          bytes: edited,
          fileName: fileName,
          mimeType: 'image/jpeg',
        ),
      );
    } else {
      if (bytes.length > widget.maxBytes) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              'Video is larger than the ${widget.maxBytes ~/ (1024 * 1024)} MB cap.',
            ),
          ),
        );
        return;
      }
      Navigator.of(context).pop(
        MediaPickerResult.send(
          bytes: bytes,
          fileName: fileName,
          mimeType: mime,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return SafeArea(
      top: false,
      child: SizedBox(
        height: mq.size.height * 0.7,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: widget.palette.stroke,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (_selectionMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _clearSelection,
                      icon: const Icon(Icons.close),
                      tooltip: 'Clear selection',
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${_selectedIds.length} selected',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _sending ? null : _sendSelected,
                      icon: const Icon(Icons.send),
                      label: Text('Send ${_selectedIds.length}'),
                    ),
                  ],
                ),
              )
            else
              const SizedBox(height: 12),
            Expanded(child: _buildBody()),
            if (_selectionMode) _buildCaptionStrip(),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      Navigator.of(context).pop(MediaPickerResult.fallback()),
                  icon: const Icon(Icons.folder_outlined),
                  label: const Text('Browse files…'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCaptionStrip() {
    final byId = {for (final a in _assets) a.id: a};
    final entries = _selectedIds
        .map((id) => byId[id])
        .whereType<AssetEntity>()
        .toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: widget.palette.paperStrong,
        border: Border(top: BorderSide(color: widget.palette.stroke)),
      ),
      constraints: const BoxConstraints(maxHeight: 140),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final asset = entries[i];
          return SizedBox(
            width: 200,
            child: Row(
              children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: FutureBuilder<Uint8List?>(
                    future: asset.thumbnailDataWithSize(
                      const ThumbnailSize.square(120),
                    ),
                    builder: (context, snap) {
                      final thumb = snap.data;
                      return thumb != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.memory(thumb, fit: BoxFit.cover),
                            )
                          : Container(color: widget.palette.stroke);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _captionControllerFor(asset.id),
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Caption…',
                      hintStyle: TextStyle(color: widget.palette.inkSoft),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    maxLines: 2,
                    minLines: 1,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final permission = _permission;
    if (permission == null || (!permission.isAuth && !permission.hasAccess)) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, color: widget.palette.inkSoft, size: 36),
            const SizedBox(height: 12),
            Text(
              'Photos permission denied. Use "Browse files…" to send any file, or grant access in system settings.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: widget.palette.inkSoft),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => PhotoManager.openSetting(),
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
    }
    if (_assets.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            'No recent photos or videos.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: widget.palette.inkSoft),
          ),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: _assets.length,
      itemBuilder: (context, i) {
        final asset = _assets[i];
        final selectionIndex = _selectedIds.toList().indexOf(asset.id);
        return _AssetTile(
          asset: asset,
          palette: widget.palette,
          humanSize: _humanSize,
          humanDuration: _humanDuration,
          sizeBytesFuture: _resolveAssetSize(asset),
          maxBytes: widget.maxBytes,
          selectionIndex: selectionIndex >= 0 ? selectionIndex + 1 : null,
          onTap: () => _pickAsset(asset),
          onLongPress: () => _longPressAsset(asset),
        );
      },
    );
  }
}

class _AssetTile extends StatelessWidget {
  const _AssetTile({
    required this.asset,
    required this.palette,
    required this.humanSize,
    required this.humanDuration,
    required this.onTap,
    required this.onLongPress,
    required this.sizeBytesFuture,
    required this.maxBytes,
    this.selectionIndex,
  });

  final AssetEntity asset;
  final ConestPalette palette;
  final String Function(int) humanSize;
  final String Function(Duration) humanDuration;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Future<int?> sizeBytesFuture;
  final int maxBytes;
  final int? selectionIndex;

  @override
  Widget build(BuildContext context) {
    final selected = selectionIndex != null;
    final errorColor = Theme.of(context).colorScheme.error;
    return FutureBuilder<int?>(
      future: sizeBytesFuture,
      builder: (context, sizeSnap) {
        final size = sizeSnap.data;
        final overCap = size != null && size > maxBytes;
        return InkWell(
          onTap: overCap
              ? () {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(
                      content: Text(
                        'Skipped: ${humanSize(size)} is over the '
                        '${maxBytes ~/ (1024 * 1024)} MB cap.',
                      ),
                    ),
                  );
                }
              : onTap,
          onLongPress: overCap ? null : onLongPress,
          child: FutureBuilder<Uint8List?>(
            future: asset.thumbnailDataWithSize(
              const ThumbnailSize.square(300),
            ),
            builder: (context, snap) {
              final thumb = snap.data;
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (thumb != null)
                    Image.memory(
                      thumb,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    )
                  else
                    Container(color: palette.stroke),
                  if (selected && !overCap)
                    Container(color: palette.primary.withValues(alpha: 0.30)),
                  if (overCap)
                    Container(color: errorColor.withValues(alpha: 0.18)),
                  if (asset.type == AssetType.video)
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: _BadgeChip(
                        icon: Icons.play_arrow,
                        text: humanDuration(asset.videoDuration),
                      ),
                    ),
                  // Size badge (bottom-right). Loading… until resolved.
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: _BadgeChip(
                      text: size == null ? '…' : humanSize(size),
                      foreground: overCap ? errorColor : null,
                    ),
                  ),
                  if (selected && !overCap)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: CircleAvatar(
                        radius: 12,
                        backgroundColor: palette.primary,
                        child: Text(
                          '${selectionIndex!}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  if (overCap)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: errorColor, width: 2),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _BadgeChip extends StatelessWidget {
  const _BadgeChip({this.icon, required this.text, this.foreground});

  final IconData? icon;
  final String text;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final color = foreground ?? Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 2),
          ],
          Text(text, style: TextStyle(color: color, fontSize: 10)),
        ],
      ),
    );
  }
}

/// Full-screen editor for images: rotate ±90°, then free-form crop, then send.
class MediaEditorScreen extends StatefulWidget {
  const MediaEditorScreen({
    super.key,
    required this.sourceBytes,
    required this.palette,
  });

  final Uint8List sourceBytes;
  final ConestPalette palette;

  @override
  State<MediaEditorScreen> createState() => _MediaEditorScreenState();
}

class _MediaEditorScreenState extends State<MediaEditorScreen> {
  /// Long-edge cap for decoded bitmaps. A 4032×3024 phone photo is ~37 MP /
  /// ~50 MB RGBA decoded — chaining 2–3 rotations on a low-RAM Android device
  /// OOMs the host. Capping at 2048 keeps peak decoded memory under 16 MB.
  static const int _maxLongEdge = 2048;

  late Uint8List _current = widget.sourceBytes;
  final CropController _cropController = CropController();
  bool _cropMode = false;
  bool _busy = false;
  bool _initializedDownscale = false;
  bool _isDirty = false;

  Future<bool> _confirmDiscard() async {
    if (!_isDirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text(
          'Your edits will be lost. The original image stays in your gallery.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  @override
  void initState() {
    super.initState();
    // Downscale once on entry so subsequent rotations operate on a smaller
    // bitmap. Done in a microtask so the first frame renders the original
    // bytes immediately.
    Future<void>.microtask(_maybeDownscaleSource);
  }

  Future<void> _maybeDownscaleSource() async {
    if (_initializedDownscale || !mounted) return;
    _initializedDownscale = true;
    try {
      final decoded = img.decodeImage(_current);
      if (decoded == null) return;
      final longEdge = decoded.width > decoded.height
          ? decoded.width
          : decoded.height;
      if (longEdge <= _maxLongEdge) return;
      final scale = _maxLongEdge / longEdge;
      final resized = img.copyResize(
        decoded,
        width: (decoded.width * scale).round(),
        height: (decoded.height * scale).round(),
      );
      final encoded = Uint8List.fromList(img.encodeJpg(resized, quality: 92));
      if (!mounted) return;
      setState(() => _current = encoded);
    } catch (error) {
      debugPrint('Conest editor downscale failed: $error');
    }
  }

  Future<void> _rotate(int quarterTurns) async {
    setState(() => _busy = true);
    try {
      final decoded = img.decodeImage(_current);
      if (decoded == null) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text('Could not decode the image to rotate it.'),
            ),
          );
          setState(() => _busy = false);
        }
        return;
      }
      final rotated = img.copyRotate(decoded, angle: quarterTurns * 90);
      final encoded = Uint8List.fromList(img.encodeJpg(rotated, quality: 92));
      if (!mounted) return;
      setState(() {
        _current = encoded;
        _busy = false;
        _isDirty = true;
      });
    } catch (error) {
      debugPrint('Conest rotate failed: $error');
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('Rotation failed: $error')));
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    return PopScope<Object?>(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final ok = await _confirmDiscard();
        if (!mounted) return;
        if (ok) {
          navigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('Edit'),
          actions: [
            IconButton(
              onPressed: _busy ? null : () => _rotate(-1),
              icon: const Icon(Icons.rotate_left),
              tooltip: 'Rotate left',
            ),
            IconButton(
              onPressed: _busy ? null : () => _rotate(1),
              icon: const Icon(Icons.rotate_right),
              tooltip: 'Rotate right',
            ),
            IconButton(
              onPressed: _busy
                  ? null
                  : () => setState(() => _cropMode = !_cropMode),
              icon: Icon(_cropMode ? Icons.check : Icons.crop),
              tooltip: _cropMode ? 'Apply crop' : 'Crop',
            ),
            IconButton(
              onPressed: _busy
                  ? null
                  : () {
                      if (_cropMode) {
                        _cropController.crop();
                      } else {
                        Navigator.of(context).pop(_current);
                      }
                    },
              icon: const Icon(Icons.send),
              tooltip: 'Send',
            ),
          ],
        ),
        body: _cropMode
            ? Crop(
                controller: _cropController,
                image: _current,
                onCropped: (result) {
                  if (result is CropSuccess) {
                    setState(() {
                      _current = result.croppedImage;
                      _cropMode = false;
                      _isDirty = true;
                    });
                    Navigator.of(context).pop(_current);
                  } else {
                    setState(() => _cropMode = false);
                  }
                },
                baseColor: Colors.black,
                maskColor: Colors.black.withValues(alpha: 0.6),
                progressIndicator: const CircularProgressIndicator(),
              )
            : Center(
                child: InteractiveViewer(
                  child: Image.memory(_current, fit: BoxFit.contain),
                ),
              ),
        bottomNavigationBar: _busy
            ? LinearProgressIndicator(color: palette.primary)
            : null,
      ),
    );
  }
}

// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:image/image.dart' as img;
import 'package:photo_manager/photo_manager.dart';

import 'conest_theme.dart';

/// Outcome of the media picker sheet: send a single asset, send a batch of
/// already-resolved bytes (multi-select), or fall through to the general
/// file-picker flow.
class MediaPickerResult {
  MediaPickerResult.send({
    required Uint8List bytes,
    required this.fileName,
    required this.mimeType,
  }) : bytes = bytes,
       fallbackToFilePicker = false,
       filePath = null,
       sizeBytes = bytes.length,
       items = null;

  MediaPickerResult.sendFile({
    required this.filePath,
    required this.sizeBytes,
    required this.fileName,
    required this.mimeType,
  }) : bytes = null,
       fallbackToFilePicker = false,
       items = null;

  MediaPickerResult.sendMultiple({required this.items})
    : bytes = null,
      filePath = null,
      sizeBytes = null,
      fileName = null,
      mimeType = null,
      fallbackToFilePicker = false;

  bool get hasItems => items != null && items!.isNotEmpty;

  MediaPickerResult.fallback()
    : bytes = null,
      filePath = null,
      sizeBytes = null,
      fileName = null,
      mimeType = null,
      fallbackToFilePicker = true,
      items = null;

  final Uint8List? bytes;
  final String? filePath;
  final int? sizeBytes;
  final String? fileName;
  final String? mimeType;
  final bool fallbackToFilePicker;
  final List<
    ({
      Uint8List? bytes,
      String? filePath,
      int sizeBytes,
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

/// The device's photo library; tests substitute a fake.
abstract interface class MediaLibrary {
  Future<PermissionState> requestPermission();

  /// Albums, the one with everything ("Recent") first.
  Future<List<AssetPathEntity>> albums();
  Future<int> countOf(AssetPathEntity album);
  Future<List<AssetEntity>> page(
    AssetPathEntity album, {
    required int page,
    required int size,
  });
  Future<Uint8List?> thumbnail(AssetEntity asset, int size);
  Future<File?> file(AssetEntity asset);

  /// Lets the user pick more photos when only some are shared.
  Future<void> presentLimited();
  Future<void> openSettings();
  void addChangeListener(VoidCallback listener);
  void removeChangeListener(VoidCallback listener);
}

/// [MediaLibrary] over photo_manager (Android and iOS).
class PhotoManagerLibrary implements MediaLibrary {
  PhotoManagerLibrary();

  final Map<VoidCallback, ValueChanged<MethodCall>> _listeners = {};

  @override
  Future<PermissionState> requestPermission() =>
      PhotoManager.requestPermissionExtend();

  @override
  Future<List<AssetPathEntity>> albums() async {
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      filterOption: FilterOptionGroup(
        orders: const [
          OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    return [...albums.where((a) => a.isAll), ...albums.where((a) => !a.isAll)];
  }

  @override
  Future<int> countOf(AssetPathEntity album) => album.assetCountAsync;

  @override
  Future<List<AssetEntity>> page(
    AssetPathEntity album, {
    required int page,
    required int size,
  }) => album.getAssetListPaged(page: page, size: size);

  @override
  Future<Uint8List?> thumbnail(AssetEntity asset, int size) =>
      asset.thumbnailDataWithSize(ThumbnailSize.square(size), quality: 80);

  @override
  Future<File?> file(AssetEntity asset) => asset.file;

  @override
  Future<void> presentLimited() =>
      PhotoManager.presentLimited(type: RequestType.common);

  @override
  Future<void> openSettings() => PhotoManager.openSetting();

  @override
  void addChangeListener(VoidCallback listener) {
    if (_listeners.isEmpty) unawaited(PhotoManager.startChangeNotify());
    final callback = _listeners[listener] = (_) => listener();
    PhotoManager.addChangeCallback(callback);
  }

  @override
  void removeChangeListener(VoidCallback listener) {
    final callback = _listeners.remove(listener);
    if (callback == null) return;
    PhotoManager.removeChangeCallback(callback);
    if (_listeners.isEmpty) unawaited(PhotoManager.stopChangeNotify());
  }
}

/// Thumbnails shared by every tile and the caption strip, so scrolling back
/// or reopening the sheet does not ask the platform again.
class _ThumbnailCache {
  static const int _capacity = 600;
  static final LinkedHashMap<String, Future<Uint8List?>> _entries =
      LinkedHashMap();

  static Future<Uint8List?> get(
    MediaLibrary library,
    AssetEntity asset,
    int size,
  ) {
    final key = '${asset.id}@$size@${asset.modifiedDateSecond}';
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return cached;
    }
    final future = library.thumbnail(asset, size).catchError((Object _) {
      _entries.remove(key);
      return null;
    });
    _entries[key] = future;
    while (_entries.length > _capacity) {
      _entries.remove(_entries.keys.first);
    }
    return future;
  }
}

/// Bottom-sheet entry point. Returns the chosen action, or null if the user
/// dismissed without picking anything. [library] replaces the device's
/// photo library (tests).
Future<MediaPickerResult?> showMediaPickerSheet({
  required BuildContext context,
  required ConestPalette palette,
  required int maxBytes,
  MediaLibrary? library,
}) async {
  if (library == null && !_supportsGallery) {
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
    builder: (sheetCtx) => _MediaPickerSheet(
      palette: palette,
      maxBytes: maxBytes,
      library: library ?? PhotoManagerLibrary(),
    ),
  );
}

class _MediaPickerSheet extends StatefulWidget {
  const _MediaPickerSheet({
    required this.palette,
    required this.maxBytes,
    required this.library,
  });

  final ConestPalette palette;
  final int maxBytes;
  final MediaLibrary library;

  @override
  State<_MediaPickerSheet> createState() => _MediaPickerSheetState();
}

class _MediaPickerSheetState extends State<_MediaPickerSheet> {
  // Picker cap matches MessengerController.maxAttachmentsPerSend; the sender
  // splits larger batches into albums of 6 on the fly.
  static const int _maxBatch = 30;
  static const int _pageSize = 80;
  static const int _thumbnailSize = 200;

  MediaLibrary get _library => widget.library;

  PermissionState? _permission;
  List<AssetPathEntity> _albums = const [];
  AssetPathEntity? _album;
  final List<AssetEntity> _assets = [];
  int _total = 0;
  int _nextPage = 0;
  bool _loadingMore = false;
  bool _loading = true;

  /// Bumped when the album changes or reloads; pages for an older one are
  /// dropped.
  int _generation = 0;
  Timer? _reloadDebounce;
  final ScrollController _scroll = ScrollController();

  /// Selected assets in selection order, kept across album switches.
  final LinkedHashMap<String, AssetEntity> _selected =
      LinkedHashMap<String, AssetEntity>();
  final Map<String, String> _captionsById = <String, String>{};
  final Map<String, TextEditingController> _captionControllers =
      <String, TextEditingController>{};
  final Map<String, int?> _sizeBytesById = <String, int?>{};
  bool _sending = false;
  String? _preparing;

  bool get _selectionMode => _selected.isNotEmpty;

  TextEditingController _captionControllerFor(String id) {
    return _captionControllers.putIfAbsent(id, () {
      final c = TextEditingController(text: _captionsById[id] ?? '');
      c.addListener(() {
        _captionsById[id] = c.text;
      });
      return c;
    });
  }

  /// The file size; resolving it may copy the original (Android 10), so
  /// only selected or opened assets are asked.
  Future<int?> _resolveAssetSize(AssetEntity asset) async {
    if (_sizeBytesById.containsKey(asset.id)) return _sizeBytesById[asset.id];
    try {
      final file = await _library.file(asset);
      final length = file == null ? null : await file.length();
      _sizeBytesById[asset.id] = length;
      return length;
    } catch (_) {
      _sizeBytesById[asset.id] = null;
      return null;
    }
  }

  @override
  void dispose() {
    _library.removeChangeListener(_libraryChanged);
    _reloadDebounce?.cancel();
    _scroll.dispose();
    for (final c in _captionControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    _bootstrap();
  }

  bool get _hasAccess {
    final permission = _permission;
    return permission != null && (permission.isAuth || permission.hasAccess);
  }

  Future<void> _bootstrap() async {
    final permission = await _library.requestPermission();
    if (!mounted) return;
    setState(() => _permission = permission);
    if (!_hasAccess) {
      setState(() => _loading = false);
      return;
    }
    _library.addChangeListener(_libraryChanged);
    await _reload();
  }

  /// The library changed (new photos, or a different limited selection).
  void _libraryChanged() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) unawaited(_reload());
    });
  }

  Future<void> _reload() async {
    try {
      final albums = await _library.albums();
      if (!mounted) return;
      final current = _album;
      final album =
          albums.where((a) => a.id == current?.id).firstOrNull ??
          albums.firstOrNull;
      setState(() => _albums = albums);
      if (album == null) {
        setState(() {
          _assets.clear();
          _total = 0;
          _loading = false;
        });
        return;
      }
      await _openAlbum(album);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openAlbum(AssetPathEntity album) async {
    // Switched in one step, so a page load already running for the old album
    // sees the new generation only together with the new album.
    final generation = ++_generation;
    setState(() {
      _album = album;
      _assets.clear();
      _total = 0;
      _nextPage = 0;
      _loadingMore = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    final total = await _library.countOf(album);
    if (!mounted || generation != _generation) return;
    setState(() => _total = total);
    await _loadMore();
    if (mounted) setState(() => _loading = false);
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    // Two screens ahead, so the next page is there before it is needed.
    if (position.extentAfter < position.viewportDimension * 2) {
      unawaited(_loadMore());
    }
  }

  Future<void> _loadMore() async {
    final album = _album;
    if (album == null || _loadingMore || _assets.length >= _total) return;
    final generation = _generation;
    _loadingMore = true;
    try {
      final page = await _library.page(album, page: _nextPage, size: _pageSize);
      if (!mounted || generation != _generation || album != _album) return;
      setState(() {
        _assets.addAll(page);
        _nextPage++;
        // A library that shrank while paging ends here.
        if (page.isEmpty) _total = _assets.length;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _total = _assets.length);
      }
    } finally {
      if (generation == _generation) _loadingMore = false;
    }
    // A short first page may not fill the screen.
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeLoadMore();
      });
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

  void _showSnack(String text) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(text)));
  }

  void _select(AssetEntity asset) {
    if (_selected.length >= _maxBatch) {
      _showSnack('Max $_maxBatch items per send.');
      return;
    }
    setState(() => _selected[asset.id] = asset);
    // Too large for this chat: dropped again once its size is known.
    unawaited(() async {
      final size = await _resolveAssetSize(asset);
      if (!mounted || size == null || size <= widget.maxBytes) return;
      if (_selected.remove(asset.id) != null) {
        setState(() {});
        _showSnack(
          'Skipped: ${_humanSize(size)} is over the '
          '${widget.maxBytes ~/ (1024 * 1024)} MB cap.',
        );
      }
    }());
  }

  void _toggleSelection(AssetEntity asset) {
    if (_selected.containsKey(asset.id)) {
      setState(() => _selected.remove(asset.id));
    } else {
      _select(asset);
    }
  }

  void _longPressAsset(AssetEntity asset) {
    if (!_selected.containsKey(asset.id)) _select(asset);
  }

  void _clearSelection() {
    setState(() => _selected.clear());
  }

  Future<void> _sendSelected() async {
    if (_sending || _selected.isEmpty) return;
    final assets = _selected.values.toList();
    var prepared = 0;
    setState(() {
      _sending = true;
      _preparing = '0/${assets.length}';
    });
    var tooLarge = 0;
    // Files are resolved together (each may be copied out of the library),
    // in selection order.
    final results = await Future.wait(
      assets.map((asset) async {
        try {
          final file = await _library.file(asset);
          if (file == null) return null;
          final sizeBytes = await file.length();
          if (sizeBytes > widget.maxBytes) {
            tooLarge++;
            return null;
          }
          final fileName = asset.title ?? 'media-${asset.id}';
          // For videos, photo_manager already generates a thumbnail —
          // reuse it as the offer-envelope poster so the receiver sees a
          // preview before the full bytes finish transferring.
          Uint8List? poster;
          if (asset.type == AssetType.video) {
            try {
              poster = await _library.thumbnail(asset, 320);
              // Cap at ~32 KB to fit in the relay envelope.
              if (poster != null && poster.length > 32 * 1024) {
                poster = null;
              }
            } catch (_) {
              poster = null;
            }
          }
          return (
            bytes: null,
            filePath: file.path,
            sizeBytes: sizeBytes,
            fileName: fileName,
            mimeType: _mimeForAsset(asset, fileName),
            caption: _captionsById[asset.id]?.trim() ?? '',
            poster: poster,
          );
        } catch (_) {
          // Skip unreadable assets; the rest of the batch still goes.
          return null;
        } finally {
          prepared++;
          if (mounted) {
            setState(() => _preparing = '$prepared/${assets.length}');
          }
        }
      }),
    );
    if (!mounted) return;
    if (tooLarge > 0) {
      _showSnack(
        '$tooLarge over the ${widget.maxBytes ~/ (1024 * 1024)} MB cap '
        'skipped.',
      );
    }
    Navigator.of(
      context,
    ).pop(MediaPickerResult.sendMultiple(items: results.nonNulls.toList()));
  }

  Future<void> _pickAsset(AssetEntity asset) async {
    if (_selectionMode) {
      _toggleSelection(asset);
      return;
    }
    final file = await _library.file(asset);
    if (file == null || !mounted) return;
    final fileName = asset.title ?? 'media-${asset.id}';
    final mime = _mimeForAsset(asset, fileName);
    if (asset.type == AssetType.image) {
      final sizeBytes = await file.length();
      if (!mounted) return;
      if (sizeBytes > widget.maxBytes) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              'Image is larger than the '
              '${widget.maxBytes ~/ (1024 * 1024)} MB cap.',
            ),
          ),
        );
        return;
      }
      // The editor is intentionally an inline-only surface. Large images
      // bypass it and remain path-backed so selecting one cannot consume an
      // unbounded amount of heap; the chat renders a generic card unless a
      // bounded poster is available.
      if (sizeBytes > 8 * 1024 * 1024) {
        Navigator.of(context).pop(
          MediaPickerResult.sendFile(
            filePath: file.path,
            sizeBytes: sizeBytes,
            fileName: fileName,
            mimeType: mime,
          ),
        );
        return;
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
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
      return;
    }
    final sizeBytes = await file.length();
    if (sizeBytes > widget.maxBytes) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'File is larger than the ${widget.maxBytes ~/ (1024 * 1024)} MB cap.',
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(
      MediaPickerResult.sendFile(
        filePath: file.path,
        sizeBytes: sizeBytes,
        fileName: fileName,
        mimeType: mime,
      ),
    );
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
                    Expanded(
                      child: Text(
                        '${_selected.length} selected',
                        style: Theme.of(context).textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _sending ? null : _sendSelected,
                      icon: _preparing == null
                          ? const Icon(Icons.send)
                          : const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                      label: Text(_preparing ?? 'Send ${_selected.length}'),
                    ),
                  ],
                ),
              )
            else if (_albums.length > 1)
              _buildAlbumSwitcher()
            else
              const SizedBox(height: 12),
            if (_permission == PermissionState.limited) _buildLimitedBanner(),
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

  Widget _buildAlbumSwitcher() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: DropdownButton<String>(
          key: const ValueKey('media-album'),
          value: _album?.id,
          underline: const SizedBox.shrink(),
          items: [
            for (final album in _albums)
              DropdownMenuItem(
                value: album.id,
                child: Text(album.isAll ? 'Recent' : album.name),
              ),
          ],
          onChanged: (id) {
            final album = _albums.where((a) => a.id == id).firstOrNull;
            if (album != null && album.id != _album?.id) {
              unawaited(_openAlbum(album));
            }
          },
        ),
      ),
    );
  }

  /// Android 14+ and iOS can share only some photos with the app.
  Widget _buildLimitedBanner() {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: widget.palette.paperStrong,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Conest sees only the photos you picked.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: () async {
              await _library.presentLimited();
              if (mounted) await _reload();
            },
            child: const Text('Select more'),
          ),
          TextButton(
            onPressed: _library.openSettings,
            child: const Text('Allow all'),
          ),
        ],
      ),
    );
  }

  Widget _buildCaptionStrip() {
    final entries = _selected.values.toList();
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
                    // The grid's thumbnail, already cached.
                    future: _ThumbnailCache.get(
                      _library,
                      asset,
                      _thumbnailSize,
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
              onPressed: _library.openSettings,
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
            'No photos or videos here.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: widget.palette.inkSoft),
          ),
        ),
      );
    }
    final order = {
      for (final (index, id) in _selected.keys.indexed) id: index + 1,
    };
    return GridView.builder(
      key: const ValueKey('media-grid'),
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: _assets.length,
      itemBuilder: (context, i) {
        final asset = _assets[i];
        return _AssetTile(
          key: ValueKey(asset.id),
          asset: asset,
          library: _library,
          thumbnailSize: _thumbnailSize,
          palette: widget.palette,
          humanDuration: _humanDuration,
          selectionIndex: order[asset.id],
          onTap: () => _pickAsset(asset),
          onLongPress: () => _longPressAsset(asset),
        );
      },
    );
  }
}

/// One grid cell. Sizes are not shown here: finding one may copy the whole
/// original out of the library, so only selected items are measured.
class _AssetTile extends StatefulWidget {
  const _AssetTile({
    super.key,
    required this.asset,
    required this.library,
    required this.thumbnailSize,
    required this.palette,
    required this.humanDuration,
    required this.onTap,
    required this.onLongPress,
    this.selectionIndex,
  });

  final AssetEntity asset;
  final MediaLibrary library;
  final int thumbnailSize;
  final ConestPalette palette;
  final String Function(Duration) humanDuration;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final int? selectionIndex;

  @override
  State<_AssetTile> createState() => _AssetTileState();
}

class _AssetTileState extends State<_AssetTile> {
  late Future<Uint8List?> _thumb = _load();

  Future<Uint8List?> _load() =>
      _ThumbnailCache.get(widget.library, widget.asset, widget.thumbnailSize);

  @override
  void didUpdateWidget(covariant _AssetTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) _thumb = _load();
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selectionIndex != null;
    return InkWell(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: _thumb,
            builder: (context, snap) {
              final thumb = snap.data;
              return thumb != null
                  ? Image.memory(
                      thumb,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    )
                  : Container(color: widget.palette.stroke);
            },
          ),
          if (selected)
            Container(color: widget.palette.primary.withValues(alpha: 0.30)),
          if (widget.asset.type == AssetType.video)
            Positioned(
              left: 4,
              bottom: 4,
              child: _BadgeChip(
                icon: Icons.play_arrow,
                text: widget.humanDuration(widget.asset.videoDuration),
              ),
            ),
          if (selected)
            Positioned(
              top: 4,
              right: 4,
              child: CircleAvatar(
                radius: 12,
                backgroundColor: widget.palette.primary,
                child: Text(
                  '${widget.selectionIndex!}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BadgeChip extends StatelessWidget {
  const _BadgeChip({this.icon, required this.text});

  final IconData? icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    const color = Colors.white;
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

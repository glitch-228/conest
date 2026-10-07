import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/conest_theme.dart';
import 'package:conest/src/media_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

/// A 1×1 transparent PNG.
final Uint8List _pixel = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
  0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);

class _FakeLibrary implements MediaLibrary {
  _FakeLibrary({int recent = 300})
    : _albums = {
        'all': [for (var i = 0; i < recent; i++) _asset('r$i')],
        'camera': [for (var i = 0; i < 5; i++) _asset('c$i')],
      };

  PermissionState permission = PermissionState.authorized;
  final Map<String, List<AssetEntity>> _albums;
  final Directory files = Directory.systemTemp.createTempSync('conest-media-');
  int fileCalls = 0;
  int albumLoads = 0;
  int limitedPicks = 0;

  /// While set, pages of "Recent" wait for it.
  Completer<void>? hold;
  final List<VoidCallback> listeners = [];

  static AssetEntity _asset(String id) =>
      AssetEntity(id: id, typeInt: 1, width: 10, height: 10, title: '$id.jpg');

  @override
  Future<PermissionState> requestPermission() async => permission;

  @override
  Future<List<AssetPathEntity>> albums() async {
    albumLoads++;
    return [
      AssetPathEntity(id: 'all', name: 'All', isAll: true),
      AssetPathEntity(id: 'camera', name: 'Camera'),
    ];
  }

  @override
  Future<int> countOf(AssetPathEntity album) async => _albums[album.id]!.length;

  @override
  Future<List<AssetEntity>> page(
    AssetPathEntity album, {
    required int page,
    required int size,
  }) async {
    if (album.id == 'all') await hold?.future;
    return _albums[album.id]!.skip(page * size).take(size).toList();
  }

  @override
  Future<Uint8List?> thumbnail(AssetEntity asset, int size) async => _pixel;

  @override
  Future<File?> file(AssetEntity asset) async {
    fileCalls++;
    final file = File('${files.path}/${asset.id}.jpg');
    if (!file.existsSync()) file.writeAsBytesSync(List.filled(100, 1));
    return file;
  }

  @override
  Future<void> presentLimited() async => limitedPicks++;

  @override
  Future<void> openSettings() async {}

  @override
  void addChangeListener(VoidCallback listener) => listeners.add(listener);

  @override
  void removeChangeListener(VoidCallback listener) =>
      listeners.remove(listener);
}

void main() {
  late _FakeLibrary library;
  MediaPickerResult? result;

  setUp(() {
    library = _FakeLibrary();
    result = null;
  });
  tearDown(() => library.files.deleteSync(recursive: true));

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showMediaPickerSheet(
                  context: context,
                  palette: ConestPalette(),
                  maxBytes: 1024 * 1024,
                  library: library,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  int tiles(WidgetTester tester) {
    final grid = tester.widget<GridView>(
      find.byKey(const ValueKey('media-grid')),
    );
    return (grid.childrenDelegate as SliverChildBuilderDelegate).childCount!;
  }

  testWidgets('pages through the whole library without opening files', (
    tester,
  ) async {
    await open(tester);
    expect(tiles(tester), 80);
    for (var i = 0; i < 20 && tiles(tester) < 300; i++) {
      await tester.drag(
        find.byKey(const ValueKey('media-grid')),
        const Offset(0, -3000),
      );
      await tester.pumpAndSettle();
    }
    expect(tiles(tester), 300);
    expect(library.fileCalls, 0);
    expect(library.listeners, hasLength(1));
  });

  testWidgets('switches albums', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('media-album')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Camera').last);
    await tester.pumpAndSettle();
    expect(tiles(tester), 5);
  });

  testWidgets('a page still loading for the previous album is dropped', (
    tester,
  ) async {
    await open(tester);
    library.hold = Completer<void>();
    // Scrolling asks for the next page of Recent, which now waits.
    await tester.drag(
      find.byKey(const ValueKey('media-grid')),
      const Offset(0, -3000),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('media-album')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Camera').last);
    await tester.pumpAndSettle();
    library.hold!.complete();
    await tester.pumpAndSettle();
    expect(tiles(tester), 5);
  });

  testWidgets('limited access offers to pick more and reloads', (tester) async {
    library.permission = PermissionState.limited;
    await open(tester);
    expect(
      find.text('Conest sees only the photos you picked.'),
      findsOneWidget,
    );
    final loads = library.albumLoads;
    await tester.tap(find.text('Select more'));
    await tester.pumpAndSettle();
    expect(library.limitedPicks, 1);
    expect(library.albumLoads, loads + 1);
  });

  testWidgets('sends the selection in order and closes the sheet', (
    tester,
  ) async {
    await open(tester);
    final grid = find.byKey(const ValueKey('media-grid'));
    final cells = find.descendant(of: grid, matching: find.byType(InkWell));
    await tester.longPress(cells.at(2));
    await tester.pumpAndSettle();
    await tester.tap(cells.at(0));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Send 2'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(result?.items?.map((item) => item.fileName), ['r2.jpg', 'r0.jpg']);
  });
}

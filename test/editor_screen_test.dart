import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:private_manga_reader/data/app_database.dart';
import 'package:private_manga_reader/data/library_repository.dart';
import 'package:private_manga_reader/data/network_repository.dart';
import 'package:private_manga_reader/models/entities.dart';
import 'package:private_manga_reader/screens/editor_screen.dart';
import 'package:private_manga_reader/services/archive_import_service.dart';
import 'package:private_manga_reader/services/backup_service.dart';
import 'package:private_manga_reader/services/import_service.dart';
import 'package:private_manga_reader/services/network_credential_store.dart';
import 'package:private_manga_reader/services/network_library_service.dart';
import 'package:private_manga_reader/services/storage_service.dart';
import 'package:private_manga_reader/state/app_controller.dart';
import 'package:private_manga_reader/theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory sandbox;
  late AppDatabase database;
  late LibraryRepository repository;
  late NetworkLibraryService networkLibrary;
  late AppController controller;
  late Comic comic;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp(
      'private-shelf-editor-test-',
    );
    database = AppDatabase(
      factory: databaseFactoryFfi,
      overridePath: p.join(sandbox.path, 'library.db'),
    );
    repository = LibraryRepository(database);
    final storage = StorageService(
      rootOverride: Directory(p.join(sandbox.path, 'files')),
    );
    await storage.initialize();
    final importer = ImportService(repository, storage);
    final archiveImporter = ArchiveImportService(repository, storage, importer);
    final networkRepository = NetworkRepository(database);
    networkLibrary = NetworkLibraryService(
      networkRepository,
      storage,
      archiveImporter,
      MemoryNetworkCredentialStore(),
    );
    controller = AppController(
      repository,
      storage,
      importer,
      archiveImporter,
      BackupService(repository, storage),
      networkRepository,
      networkLibrary,
    );

    comic = await repository.createComic('编辑验证');
    for (var index = 1; index <= 3; index++) {
      final file = File(p.join(sandbox.path, '$index.png'));
      final image = img.Image(width: 12, height: 16);
      img.fill(image, color: img.ColorRgb8(index * 30, 80, 150));
      await file.writeAsBytes(img.encodePng(image), flush: true);
      await importer.importFiles(
        comicId: comic.id,
        files: <PlatformFile>[_TestPlatformFile(file)],
        duplicatePolicy: DuplicatePolicy.keep,
      );
    }
    await controller.initialize();
  });

  tearDown(() async {
    await networkLibrary.dispose();
    await database.close();
    if (await sandbox.exists()) {
      // Windows 下图片/数据库句柄释放有延迟，删除临时目录带重试。
      for (var attempt = 0; attempt < 8; attempt++) {
        try {
          await sandbox.delete(recursive: true);
          break;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    }
  });

  testWidgets('用户可以选择一张图片、确认删除并保存结果', (tester) async {
    final semantics = tester.ensureSemantics();
    _setPhoneView(tester);
    try {
      await _openEditor(tester, controller, comic);
      expect(find.text('3 / 1000 张'), findsOneWidget);

      final secondPage = _pageSelector('第 2 张');
      _expectLabels(tester, '当前语义标签');
      expect(secondPage, findsOneWidget);
      await tester.tap(secondPage);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('已选择 1 张'), findsOneWidget);

      await tester.tap(find.text('删除'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('删除选中的 1 张图片？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('2 / 1000 张'), findsOneWidget);

      await _saveAndWait(tester);
      final savedItems = await tester.runAsync(
        () => repository.loadItems(comic.id),
      );
      expect(savedItems, hasLength(2));
    } finally {
      await _releaseWidgetTree(tester);
      semantics.dispose();
    }
  });

  testWidgets('批量选择两张图片可以一次删除并保存', (tester) async {
    final semantics = tester.ensureSemantics();
    _setPhoneView(tester);
    try {
      await _openEditor(tester, controller, comic);
      expect(find.text('3 / 1000 张'), findsOneWidget);

      final firstPage = _pageSelector('第 1 张');
      final thirdPage = _pageSelector('第 3 张');
      expect(firstPage, findsOneWidget);
      expect(thirdPage, findsOneWidget);
      await tester.tap(firstPage);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(thirdPage);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('已选择 2 张'), findsOneWidget);

      await tester.tap(find.text('删除'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('删除选中的 2 张图片？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('1 / 1000 张'), findsOneWidget);

      await _saveAndWait(tester);
      final savedItems = (await tester.runAsync(
        () => repository.loadItems(comic.id),
      ))!;
      expect(savedItems, hasLength(1));
      expect(savedItems.single.asset.originalFileName, '2.png');
    } finally {
      await _releaseWidgetTree(tester);
      semantics.dispose();
    }
  });

  testWidgets('删除后点取消退出，数据库与原始图片引用保持不变', (tester) async {
    final semantics = tester.ensureSemantics();
    _setPhoneView(tester);
    try {
      await _openEditor(tester, controller, comic);
      expect(find.text('3 / 1000 张'), findsOneWidget);

      await tester.tap(_pageSelector('第 2 张'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('已选择 1 张'), findsOneWidget);

      await tester.tap(find.text('删除'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('删除选中的 1 张图片？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('2 / 1000 张'), findsOneWidget);

      // 取消编辑：编辑草稿被丢弃，不落库。
      await tester.tap(find.text('取消'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('打开编辑'), findsOneWidget, reason: '编辑页应已退出');
      final keptItems = await tester.runAsync(
        () => repository.loadItems(comic.id),
      );
      expect(keptItems, hasLength(3));
    } finally {
      await _releaseWidgetTree(tester);
      semantics.dispose();
    }
  });

  testWidgets('保存后重新进入编辑页仍显示保存后的张数', (tester) async {
    final semantics = tester.ensureSemantics();
    _setPhoneView(tester);
    try {
      await _openEditor(tester, controller, comic);
      expect(find.text('3 / 1000 张'), findsOneWidget);

      await tester.tap(_pageSelector('第 2 张'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('删除'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pump(const Duration(milliseconds: 300));
      await _saveAndWait(tester);
      expect(find.text('打开编辑'), findsOneWidget, reason: '保存后应返回上一页');

      // 重新进入编辑页，仍保持保存后的 2 张。
      await tester.tap(find.text('打开编辑'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      expect(find.text('2 / 1000 张'), findsOneWidget);
      final savedItems = await tester.runAsync(
        () => repository.loadItems(comic.id),
      );
      expect(savedItems, hasLength(2));
    } finally {
      await _releaseWidgetTree(tester);
      semantics.dispose();
    }
  });

  testWidgets('长按拖动第 3 张到第 1 位不崩溃且保存后顺序生效', (tester) async {
    final semantics = tester.ensureSemantics();
    _setPhoneView(tester);
    try {
      await _openEditor(tester, controller, comic);
      expect(find.text('3 / 1000 张'), findsOneWidget);

      final third = _pageSelector('第 3 张');
      final first = _pageSelector('第 1 张');
      final start = tester.getCenter(third);
      final target = tester.getCenter(first);
      final gesture = await tester.startGesture(start);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
      // 分两步移动：先小步激活拖拽，再一次性移到目标位。
      await gesture.moveBy(const Offset(8, 0));
      await tester.pump();
      await gesture.moveBy(target - start);
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await _saveAndWait(tester);
      final savedItems = (await tester.runAsync(
        () => repository.loadItems(comic.id),
      ))!;
      expect(savedItems, hasLength(3));
      expect(
        savedItems.map((item) => item.asset.originalFileName).toList(),
        <String>['3.png', '1.png', '2.png'],
        reason: '第 3 张应移动到第 1 位',
      );
    } finally {
      await _releaseWidgetTree(tester);
      semantics.dispose();
    }
  });
}

void _setPhoneView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder _pageSelector(String label) => find.byWidgetPredicate(
  (widget) =>
      widget is Semantics &&
      widget.properties.label == '$label，未选择，点按选择',
  description: '$label 的选择入口',
);

void _expectLabels(WidgetTester tester, String reason) {
  final labels = tester
      .widgetList<Semantics>(find.byType(Semantics, skipOffstage: false))
      .map((widget) => widget.properties.label)
      .whereType<String>()
      .toList();
  expect(labels, isNotEmpty, reason: '$reason：$labels');
}

Future<void> _openEditor(
  WidgetTester tester,
  AppController controller,
  Comic comic,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildShelfTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      EditorScreen(controller: controller, comicId: comic.id),
                ),
              ),
              child: const Text('打开编辑'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开编辑'));
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  // 推入动画必须完整走完：路由若停在过渡中间态，LongPressDraggable
  // 的长按拖拽不会启动（tap 可以、长按不行），这是测试环境的帧推进问题。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<void> _saveAndWait(WidgetTester tester) async {
  // _save 的整条真实异步链（DB 事务 + refresh 查询 + 路由 pop）必须在
  // runAsync 的真实事件循环窗口内完成，fake-async 区里续体不会被推进。
  await tester.runAsync(() async {
    await tester.tap(find.text('保存'));
    await Future<void>.delayed(const Duration(seconds: 2));
  });
  // 保存后推进退场动画直至路由完全移除（起帧 → 推进 → 重建 → 再推进）。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _releaseWidgetTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
}

final class _TestPlatformFile extends PlatformFile {
  _TestPlatformFile(this.file);

  final File file;

  @override
  String get name => p.basename(file.path);

  @override
  Uri get uri => file.uri;

  @override
  XFile get xFile => XFile(file.path);

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() async* {
    await for (final chunk in file.openRead()) {
      yield Uint8List.fromList(chunk);
    }
  }
}
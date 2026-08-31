import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:private_manga_reader/data/app_database.dart';
import 'package:private_manga_reader/data/library_repository.dart';
import 'package:private_manga_reader/data/network_repository.dart';
import 'package:private_manga_reader/models/entities.dart';
import 'package:private_manga_reader/screens/library_screen.dart';
import 'package:private_manga_reader/services/archive_import_service.dart';
import 'package:private_manga_reader/services/backup_service.dart';
import 'package:private_manga_reader/services/import_service.dart';
import 'package:private_manga_reader/services/network_credential_store.dart';
import 'package:private_manga_reader/services/network_library_service.dart';
import 'package:private_manga_reader/services/privacy_service.dart';
import 'package:private_manga_reader/services/storage_service.dart';
import 'package:private_manga_reader/state/app_controller.dart';
import 'package:private_manga_reader/theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  testWidgets('书单内系统返回回到拾画阁而不是退出应用', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final sandbox = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('shelf-back-test-'),
    ))!;
    final database = AppDatabase(
      factory: databaseFactoryFfi,
      overridePath: p.join(sandbox.path, 'library.db'),
    );
    final repository = LibraryRepository(database);
    final storage = StorageService(
      rootOverride: Directory(p.join(sandbox.path, 'files')),
    );
    await tester.runAsync(storage.initialize);
    final importer = ImportService(repository, storage);
    final archiveImporter = ArchiveImportService(repository, storage, importer);
    final networkRepository = NetworkRepository(database);
    final networkLibrary = NetworkLibraryService(
      networkRepository,
      storage,
      archiveImporter,
      MemoryNetworkCredentialStore(),
    );
    final controller = AppController(
      repository,
      storage,
      importer,
      archiveImporter,
      BackupService(repository, storage),
      networkRepository,
      networkLibrary,
      privacyAuthenticator: const AllowPrivacyAuthenticator(),
    );
    addTearDown(() async {
      await networkLibrary.dispose();
      await database.close();
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    await tester.runAsync(() async {
      final comic = await repository.createComic('返回测试漫画');
      final list = await repository.createReadingList('返回测试书单');
      await repository.addComicsToReadingList(list.id, <String>[comic.id]);
      await controller.initialize();
    });
    expect(
      controller.readingLists.map((item) => item.name),
      contains('返回测试书单'),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildShelfTheme(Brightness.light),
        home: LibraryScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    final readingListChip = find.widgetWithText(ActionChip, '书单');
    await tester.ensureVisible(readingListChip);
    await tester.pump();
    await tester.tap(readingListChip);
    await tester.pumpAndSettle();
    expect(find.text('本地书单'), findsOneWidget);
    expect(find.text('返回测试书单'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, '返回测试书单'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('返回测试书单'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('拾画阁'), findsOneWidget);
    expect(find.text('返回测试漫画'), findsOneWidget);
  });

  testWidgets('书架使用三列、文件夹分组与验证后私密区', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final sandbox = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('shelf-ui-test-'),
    ))!;
    final database = AppDatabase(
      factory: databaseFactoryFfi,
      overridePath: p.join(sandbox.path, 'library.db'),
    );
    final repository = LibraryRepository(database);
    final storage = StorageService(
      rootOverride: Directory(p.join(sandbox.path, 'files')),
    );
    await tester.runAsync(storage.initialize);
    final importer = ImportService(repository, storage);
    final archiveImporter = ArchiveImportService(repository, storage, importer);
    final networkRepository = NetworkRepository(database);
    final networkLibrary = NetworkLibraryService(
      networkRepository,
      storage,
      archiveImporter,
      MemoryNetworkCredentialStore(),
    );
    final controller = AppController(
      repository,
      storage,
      importer,
      archiveImporter,
      BackupService(repository, storage),
      networkRepository,
      networkLibrary,
      privacyAuthenticator: const AllowPrivacyAuthenticator(),
    );
    addTearDown(() async {
      await networkLibrary.dispose();
      await database.close();
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    late String firstId;
    await tester.runAsync(() async {
      final first = await repository.createComic('第一本');
      firstId = first.id;
      await repository.createComic('第二本');
      final grouped = await repository.createComic('文件夹内漫画');
      final folder = await repository.createFolder('待看漫画');
      await repository.moveComicsToFolder(<String>[grouped.id], folder.id);
      await controller.initialize();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildShelfTheme(Brightness.light),
        home: LibraryScreen(controller: controller),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    final scopeSwitcher = tester.widget<AnimatedSwitcher>(
      find.byKey(const ValueKey<String>('library-scope-switcher')),
    );
    expect(scopeSwitcher.duration, const Duration(milliseconds: 280));
    final grid = tester.widget<GridView>(
      find.byKey(const ValueKey<String>('library-three-column-grid')),
    );
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      3,
    );
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(grid.padding, const EdgeInsets.fromLTRB(16, 12, 16, 104));
    expect(delegate.crossAxisSpacing, 14);
    expect(delegate.mainAxisSpacing, 24);
    expect(delegate.mainAxisExtent, greaterThan(190));
    expect(tester.widget<Text>(find.text('第一本')).maxLines, 2);
    expect(find.text('待看漫画'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('folder-mosaic-surface')),
      findsOneWidget,
    );
    for (var index = 0; index < 4; index++) {
      expect(
        find.byKey(ValueKey<String>('folder-mosaic-slot-$index')),
        findsOneWidget,
      );
    }

    await tester.tap(find.byTooltip('整理书架'));
    await tester.pumpAndSettle();
    expect(find.text('整理书架'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) => widget is LongPressDraggable),
      findsNWidgets(3),
    );
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    expect(find.text('阅读画布'), findsOneWidget);
    expect(find.text('画纸'), findsOneWidget);
    expect(find.text('夜间'), findsOneWidget);
    await tester.tap(find.text('夜间'));
    await tester.pumpAndSettle();
    expect(controller.preferences.surfaceMode, ReaderSurfaceMode.night);
    await tester.tap(find.text('图片间距'));
    await tester.pumpAndSettle();
    expect(find.text('只改变阅读显示，不处理或重编码原图。'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.tap(find.text('待看漫画'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('文件夹内漫画'), findsOneWidget);

    await tester.tap(find.byTooltip('返回书架'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('批量管理'));
    await tester.tap(find.text('第一本'));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('私密').last);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('第一本'), findsNothing);

    await tester.tap(find.text('私密').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('第一本'), findsOneWidget);
    expect(
      controller.library
          .firstWhere((item) => item.comic.id == firstId)
          .comic
          .isPrivate,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('主书架直接把一本漫画拖到另一本会询问并合成四宫格书单', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final sandbox = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('shelf-group-drag-test-'),
    ))!;
    final database = AppDatabase(
      factory: databaseFactoryFfi,
      overridePath: p.join(sandbox.path, 'library.db'),
    );
    final repository = LibraryRepository(database);
    final storage = StorageService(
      rootOverride: Directory(p.join(sandbox.path, 'files')),
    );
    await tester.runAsync(storage.initialize);
    final importer = ImportService(repository, storage);
    final archiveImporter = ArchiveImportService(repository, storage, importer);
    final networkRepository = NetworkRepository(database);
    final networkLibrary = NetworkLibraryService(
      networkRepository,
      storage,
      archiveImporter,
      MemoryNetworkCredentialStore(),
    );
    final controller = AppController(
      repository,
      storage,
      importer,
      archiveImporter,
      BackupService(repository, storage),
      networkRepository,
      networkLibrary,
      privacyAuthenticator: const AllowPrivacyAuthenticator(),
    );
    addTearDown(() async {
      await networkLibrary.dispose();
      await database.close();
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    late String sourceId;
    late String targetId;
    await tester.runAsync(() async {
      sourceId = (await repository.createComic('拖动来源')).id;
      targetId = (await repository.createComic('合组目标')).id;
      await repository.createComic('未参与漫画');
      await controller.initialize();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShelfTheme(Brightness.light),
        home: LibraryScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    final source = find.byKey(ValueKey<String>('shelf-entry-comic:$sourceId'));
    final target = find.byKey(ValueKey<String>('shelf-entry-comic:$targetId'));
    final sourceSize = tester.getSize(source);
    final gesture = await tester.startGesture(tester.getCenter(source));
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('shelf-drag-feedback'))),
      sourceSize,
    );
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 700));
    final targetScale = tester.widget<AnimatedScale>(
      find.byKey(ValueKey<String>('shelf-drop-scale-comic:$targetId')),
    );
    expect(targetScale.scale, greaterThan(1));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('合成书单'), findsNWidgets(2));
    expect(find.text('是否将《拖动来源》和《合组目标》合成一个书单？'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('shelf-group-composer-sheet')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('shelf-group-composer-preview')),
      findsOneWidget,
    );
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(controller.folders, isEmpty);
    expect(controller.summaryFor(sourceId)!.comic.folderId, isNull);
    expect(controller.summaryFor(targetId)!.comic.folderId, isNull);

    final confirmGesture = await tester.startGesture(tester.getCenter(source));
    await tester.pump(const Duration(milliseconds: 600));
    await confirmGesture.moveTo(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 700));
    await confirmGesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '合成书单'));
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 40; attempt++) {
      if (controller.folders.isNotEmpty &&
          controller.shelfEntries.any(
            (entry) => entry.key.startsWith('folder:'),
          )) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(controller.folders, hasLength(1));
    expect(controller.folders.single.name, '新建书单');
    expect(find.text('新建书单'), findsOneWidget);
    for (var index = 0; index < 4; index++) {
      expect(
        find.byKey(ValueKey<String>('folder-mosaic-slot-$index')),
        findsOneWidget,
      );
    }

    final folderId = controller.folders.single.id;
    await tester.tap(
      find.byKey(ValueKey<String>('shelf-entry-folder:$folderId')),
    );
    await tester.pumpAndSettle();
    final groupedSource = find.byKey(
      ValueKey<String>('shelf-entry-comic:$sourceId'),
    );
    final groupedTarget = find.byKey(
      ValueKey<String>('shelf-entry-comic:$targetId'),
    );
    final sourceRect = tester.getRect(groupedSource);
    final reorderInsideGesture = await tester.startGesture(
      tester.getCenter(groupedTarget),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await reorderInsideGesture.moveTo(
      Offset(sourceRect.center.dx, sourceRect.bottom - 2),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await reorderInsideGesture.up();
    for (var attempt = 0; attempt < 40; attempt++) {
      final insideOrder = controller.library
          .where((summary) => summary.comic.folderId == folderId)
          .map((summary) => summary.comic.id)
          .toList();
      if (insideOrder.isNotEmpty && insideOrder.first == targetId) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    expect(
      controller.library
          .where((summary) => summary.comic.folderId == folderId)
          .map((summary) => summary.comic.id),
      <String>[targetId, sourceId],
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    final moveOutGesture = await tester.startGesture(
      tester.getCenter(groupedSource),
    );
    await tester.pump(const Duration(milliseconds: 600));
    final moveOutTarget = find.byKey(
      const ValueKey<String>('folder-drag-out-target'),
    );
    expect(moveOutTarget, findsOneWidget);
    await moveOutGesture.moveTo(tester.getCenter(moveOutTarget));
    await tester.pump(const Duration(milliseconds: 180));
    await moveOutGesture.up();
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 40; attempt++) {
      final movedToRoot =
          controller.summaryFor(sourceId)?.comic.folderId == null &&
          controller.shelfEntries.any(
            (entry) => entry.key == 'comic:$sourceId',
          );
      if (movedToRoot) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    expect(controller.summaryFor(sourceId)!.comic.folderId, isNull);
    expect(
      controller.shelfEntries.map((entry) => entry.key),
      contains('comic:$sourceId'),
    );
    await tester.tap(find.byTooltip('返回书架'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('shelf-entry-comic:$sourceId')),
      findsOneWidget,
    );
    expect(
      controller.library.where((summary) => summary.comic.folderId == folderId),
      hasLength(1),
    );
  });

  testWidgets('拖动漫画靠近书架底边会自动向下滚动', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final sandbox = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('shelf-edge-scroll-test-'),
    ))!;
    final database = AppDatabase(
      factory: databaseFactoryFfi,
      overridePath: p.join(sandbox.path, 'library.db'),
    );
    final repository = LibraryRepository(database);
    final storage = StorageService(
      rootOverride: Directory(p.join(sandbox.path, 'files')),
    );
    await tester.runAsync(storage.initialize);
    final importer = ImportService(repository, storage);
    final archiveImporter = ArchiveImportService(repository, storage, importer);
    final networkRepository = NetworkRepository(database);
    final networkLibrary = NetworkLibraryService(
      networkRepository,
      storage,
      archiveImporter,
      MemoryNetworkCredentialStore(),
    );
    final controller = AppController(
      repository,
      storage,
      importer,
      archiveImporter,
      BackupService(repository, storage),
      networkRepository,
      networkLibrary,
      privacyAuthenticator: const AllowPrivacyAuthenticator(),
    );
    addTearDown(() async {
      await networkLibrary.dispose();
      await database.close();
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    late String firstId;
    await tester.runAsync(() async {
      firstId = (await repository.createComic('第 1 本')).id;
      for (var index = 2; index <= 40; index++) {
        await repository.createComic('第 $index 本');
      }
      await controller.initialize();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShelfTheme(Brightness.light),
        home: LibraryScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    final grid = find.byKey(
      const ValueKey<String>('library-three-column-grid'),
    );
    final scrollable = find.descendant(
      of: grid,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0);

    final first = find.byKey(ValueKey<String>('shelf-entry-comic:$firstId'));
    final gesture = await tester.startGesture(tester.getCenter(first));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(const Offset(180, 700));
    await tester.pump(const Duration(seconds: 1));

    expect(position.pixels, greaterThan(0));
    await gesture.cancel();
  });

  testWidgets('主书架无需进入整理模式即可拖动漫画并持久化顺序', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final sandbox = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('shelf-direct-reorder-test-'),
    ))!;
    final database = AppDatabase(
      factory: databaseFactoryFfi,
      overridePath: p.join(sandbox.path, 'library.db'),
    );
    final repository = LibraryRepository(database);
    final storage = StorageService(
      rootOverride: Directory(p.join(sandbox.path, 'files')),
    );
    await tester.runAsync(storage.initialize);
    final importer = ImportService(repository, storage);
    final archiveImporter = ArchiveImportService(repository, storage, importer);
    final networkRepository = NetworkRepository(database);
    final networkLibrary = NetworkLibraryService(
      networkRepository,
      storage,
      archiveImporter,
      MemoryNetworkCredentialStore(),
    );
    final controller = AppController(
      repository,
      storage,
      importer,
      archiveImporter,
      BackupService(repository, storage),
      networkRepository,
      networkLibrary,
      privacyAuthenticator: const AllowPrivacyAuthenticator(),
    );
    addTearDown(() async {
      await networkLibrary.dispose();
      await database.close();
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    late String firstId;
    late String secondId;
    late String thirdId;
    await tester.runAsync(() async {
      firstId = (await repository.createComic('第一本')).id;
      secondId = (await repository.createComic('第二本')).id;
      thirdId = (await repository.createComic('第三本')).id;
      await controller.initialize();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShelfTheme(Brightness.light),
        home: LibraryScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('整理书架'), findsNothing);

    final source = find.byKey(ValueKey<String>('shelf-entry-comic:$thirdId'));
    final target = find.byKey(ValueKey<String>('shelf-entry-comic:$firstId'));
    final targetRect = tester.getRect(target);
    final gesture = await tester.startGesture(tester.getCenter(source));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(
      Offset(targetRect.center.dx, targetRect.top + targetRect.height * 0.92),
    );
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.up();
    await tester.pumpAndSettle();

    for (var attempt = 0; attempt < 40; attempt++) {
      final rootEntries = controller.shelfEntries
          .where((entry) => entry.scope == 'root')
          .toList();
      if (rootEntries.isNotEmpty && rootEntries.first.entityId == thirdId) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }

    expect(
      controller.shelfEntries
          .where((entry) => entry.scope == 'root')
          .map((entry) => entry.entityId),
      <String>[thirdId, firstId, secondId],
    );
    final persisted = await tester.runAsync(repository.loadShelfEntries);
    expect(
      persisted!
          .where((entry) => entry.scope == 'root')
          .map((entry) => entry.entityId)
          .take(2),
      <String>[thirdId, firstId],
    );
  });

  testWidgets('拖入已有书单必须先确认且取消不改变漫画归属', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final sandbox = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('shelf-add-group-test-'),
    ))!;
    final database = AppDatabase(
      factory: databaseFactoryFfi,
      overridePath: p.join(sandbox.path, 'library.db'),
    );
    final repository = LibraryRepository(database);
    final storage = StorageService(
      rootOverride: Directory(p.join(sandbox.path, 'files')),
    );
    await tester.runAsync(storage.initialize);
    final importer = ImportService(repository, storage);
    final archiveImporter = ArchiveImportService(repository, storage, importer);
    final networkRepository = NetworkRepository(database);
    final networkLibrary = NetworkLibraryService(
      networkRepository,
      storage,
      archiveImporter,
      MemoryNetworkCredentialStore(),
    );
    final controller = AppController(
      repository,
      storage,
      importer,
      archiveImporter,
      BackupService(repository, storage),
      networkRepository,
      networkLibrary,
      privacyAuthenticator: const AllowPrivacyAuthenticator(),
    );
    addTearDown(() async {
      await networkLibrary.dispose();
      await database.close();
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    late String comicId;
    late String folderId;
    await tester.runAsync(() async {
      comicId = (await repository.createComic('待加入漫画')).id;
      folderId = (await repository.createFolder('周末书单')).id;
      await controller.initialize();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShelfTheme(Brightness.light),
        home: LibraryScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    final source = find.byKey(ValueKey<String>('shelf-entry-comic:$comicId'));
    final target = find.byKey(ValueKey<String>('shelf-entry-folder:$folderId'));
    final gesture = await tester.startGesture(tester.getCenter(source));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('加入书单'), findsOneWidget);
    expect(find.text('是否将《待加入漫画》加入《周末书单》？'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('shelf-add-to-group-sheet')),
      findsOneWidget,
    );
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.summaryFor(comicId)!.comic.folderId, isNull);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(controller.summaryFor(comicId)!.comic.folderId, isNull);

    final secondGesture = await tester.startGesture(tester.getCenter(source));
    await tester.pump(const Duration(milliseconds: 600));
    await secondGesture.moveTo(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 700));
    await secondGesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '加入'));
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 40; attempt++) {
      if (controller.summaryFor(comicId)?.comic.folderId == folderId) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    expect(controller.summaryFor(comicId)!.comic.folderId, folderId);
  });
}

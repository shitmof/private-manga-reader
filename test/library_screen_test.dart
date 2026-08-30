import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:private_manga_reader/data/app_database.dart';
import 'package:private_manga_reader/data/library_repository.dart';
import 'package:private_manga_reader/data/network_repository.dart';
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

    final grid = tester.widget<GridView>(
      find.byKey(const ValueKey<String>('library-three-column-grid')),
    );
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      3,
    );
    expect(find.text('待看漫画'), findsOneWidget);
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
}

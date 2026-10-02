import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:private_manga_reader/data/app_database.dart';
import 'package:private_manga_reader/data/library_repository.dart';
import 'package:private_manga_reader/data/network_repository.dart';
import 'package:private_manga_reader/models/entities.dart';
import 'package:private_manga_reader/screens/reader_screen.dart';
import 'package:private_manga_reader/services/archive_import_service.dart';
import 'package:private_manga_reader/services/backup_service.dart';
import 'package:private_manga_reader/services/import_service.dart';
import 'package:private_manga_reader/services/network_credential_store.dart';
import 'package:private_manga_reader/services/network_library_service.dart';
import 'package:private_manga_reader/services/privacy_service.dart';
import 'package:private_manga_reader/services/storage_service.dart';
import 'package:private_manga_reader/state/app_controller.dart';
import 'package:private_manga_reader/theme.dart';
import 'package:private_manga_reader/widgets/reader_edge_scrubber.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  const privacyChannel = MethodChannel('private_manga_reader/privacy');
  late Directory sandbox;
  late AppDatabase database;
  late LibraryRepository repository;
  late NetworkLibraryService networkLibrary;
  late AppController controller;
  late _RecordingAuthenticator authenticator;
  late Comic comic;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('reader-regression-');
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
    authenticator = _RecordingAuthenticator();
    controller = AppController(
      repository,
      storage,
      importer,
      archiveImporter,
      BackupService(repository, storage),
      networkRepository,
      networkLibrary,
      privacyAuthenticator: authenticator,
    );
    comic = await repository.createComic('阅读回归');
    final file = File(p.join(sandbox.path, 'page.png'));
    await file.writeAsBytes(img.encodePng(img.Image(width: 12, height: 12)));
    await importer.importFiles(
      comicId: comic.id,
      files: [_LocalPlatformFile(file)],
      duplicatePolicy: DuplicatePolicy.keep,
    );
    await controller.initialize();
  });

  tearDown(() async {
    await networkLibrary.dispose();
    await database.close();
    controller.dispose();
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Future<void> openReader(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildShelfTheme(Brightness.light),
          home: ReaderScreen(controller: controller, comicId: comic.id),
        ),
      );
      for (var i = 0; i < 50; i++) {
        if (find.byType(ListView).evaluate().isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
      await tester.pump();
    });
    expect(find.byType(ListView), findsOneWidget);
  }

  Future<void> closeReader(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  testWidgets('私密文件夹内的普通漫画也申请阅读截屏保护并成对释放', (tester) async {
    final calls = <bool>[];
    PrivateScreenGuard.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(privacyChannel, (call) async {
          if (call.method == 'setScreenSecure') {
            calls.add(call.arguments as bool);
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(privacyChannel, null);
      PrivateScreenGuard.resetForTesting();
    });
    final folder = await tester.runAsync(() => controller.createFolder('私密分组'));
    await tester.runAsync(() async {
      await controller.setFolderPrivate(folder!.id, true);
      await controller.moveComicsToFolder([comic.id], folder.id);
    });
    expect(controller.summaryFor(comic.id)!.comic.isPrivate, isFalse);
    expect(controller.preferences.incognito, isFalse);

    await openReader(tester);
    expect(calls, [true]);
    await closeReader(tester);
    expect(calls, [true, false]);
  });

  test('私密分组漫画导出前重新验证，拒绝时不生成文件，授权后保留原图', () async {
    final folder = await controller.createFolder('私密分组');
    await controller.setFolderPrivate(folder.id, true);
    await controller.moveComicsToFolder([comic.id], folder.id);
    expect(controller.summaryFor(comic.id)!.comic.isPrivate, isFalse);
    final before = await sandbox.list(recursive: true).toList();

    await expectLater(controller.createComicExport(comic.id), throwsStateError);
    expect(authenticator.attempts, 1);
    expect(controller.operation, isNull);
    final after = await sandbox.list(recursive: true).toList();
    expect(after.length, before.length);

    authenticator.allowed = true;
    final exported = await controller.createComicExport(comic.id);
    expect(authenticator.attempts, 2);
    expect(exported.pageCount, 1);
    expect(await exported.file.exists(), isTrue);
    expect(await controller.loadItems(comic.id), hasLength(1));
  });

  testWidgets('长漫画切换图片间距后保持当前页内位置，定位与保存进度使用新间距', (tester) async {
    await tester.runAsync(() async {
      final item = (await controller.loadItems(comic.id)).single;
      for (var i = 1; i < 80; i++) {
        await repository.attachAsset(comicId: comic.id, asset: item.asset);
      }
      await controller.refresh();
    });
    await openReader(tester);
    final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;
    scroll.jumpTo(50 * 360 + 70);
    await tester.pump();
    expect(
      tester
          .widget<ReaderEdgeScrubber>(find.byType(ReaderEdgeScrubber))
          .currentPage,
      51,
    );

    controller.preferencesWriteHook = (_) async {};
    await controller.updatePreferences(
      controller.preferences.copyWith(imageGap: 10),
    );
    await tester.pump();
    await tester.pump();
    expect(scroll.offset, closeTo(50 * 370 + 70, 0.01));
    expect(
      tester
          .widget<ReaderEdgeScrubber>(find.byType(ReaderEdgeScrubber))
          .currentPage,
      51,
    );

    final scrubber = tester.widget<ReaderEdgeScrubber>(
      find.byType(ReaderEdgeScrubber),
    );
    scrubber.onChanged(60 / 79);
    await tester.pump();
    expect(scroll.offset, closeTo(60 * 370, 0.01));
    expect(
      tester
          .widget<ReaderEdgeScrubber>(find.byType(ReaderEdgeScrubber))
          .currentPage,
      61,
    );
    await controller.updatePreferences(
      controller.preferences.copyWith(imageGap: 0),
    );
    await tester.pump();
    await tester.pump();
    expect(scroll.offset, closeTo(60 * 360, 0.01));
    await closeReader(tester);
    final saved = await tester.runAsync(() => repository.getComic(comic.id));
    final progress = saved!.comic;
    expect(progress.lastReadPosition, 60);
    expect(progress.lastReadOffset, closeTo(0, 0.01));
  });

  testWidgets('阅读设置面板不关闭时往返切换画纸与夜间，背景文字控件同步', (tester) async {
    await openReader(tester);
    controller.preferencesWriteHook = (_) async {};
    await tester.tapAt(const Offset(120, 120));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('阅读设置'));
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.text('阅读设置').evaluate().isNotEmpty) break;
      }
    });
    await tester.pumpAndSettle();

    Color? panelColor() => tester
        .widget<Material>(
          find
              .ancestor(of: find.text('阅读设置'), matching: find.byType(Material))
              .first,
        )
        .color;
    Color? headingColor() {
      final heading = find.text('阅读设置');
      return tester.widget<Text>(heading).style?.color ??
          DefaultTextStyle.of(tester.element(heading)).style.color;
    }

    for (var round = 0; round < 2; round++) {
      await tester.tap(find.text('夜间'));
      await tester.pumpAndSettle();
      expect(panelColor(), const Color(0xFF20242A));
      expect(headingColor(), Colors.white);
      final nightContext = tester.element(find.text('夜间'));
      expect(Theme.of(nightContext).brightness, Brightness.dark);
      expect(controller.preferences.surfaceMode, ReaderSurfaceMode.night);
      expect(
        tester
            .widget<Scaffold>(
              find.byKey(const ValueKey<String>('reader-canvas')),
            )
            .backgroundColor,
        const Color(0xFF0B0D10),
      );

      await tester.tap(find.text('画纸'));
      await tester.pumpAndSettle();
      expect(panelColor(), ShelfColors.surface);
      expect(headingColor(), ShelfColors.ink);
      final paperContext = tester.element(find.text('画纸'));
      expect(Theme.of(paperContext).brightness, Brightness.light);
      expect(controller.preferences.surfaceMode, ReaderSurfaceMode.paper);
    }
    await closeReader(tester);
  });
}

class _RecordingAuthenticator implements PrivacyAuthenticator {
  bool allowed = false;
  int attempts = 0;

  @override
  Future<bool> authenticate({required String reason}) async {
    attempts++;
    return allowed;
  }
}

final class _LocalPlatformFile extends PlatformFile {
  _LocalPlatformFile(this.file);

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

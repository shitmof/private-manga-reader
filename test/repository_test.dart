import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as legacy_archive;
import 'package:cross_file/cross_file.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:private_manga_reader/data/app_database.dart';
import 'package:private_manga_reader/data/library_repository.dart';
import 'package:private_manga_reader/models/entities.dart';
import 'package:private_manga_reader/services/backup_service.dart';
import 'package:private_manga_reader/services/archive_import_service.dart';
import 'package:private_manga_reader/services/import_service.dart';
import 'package:private_manga_reader/services/storage_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory sandbox;
  late AppDatabase database;
  late LibraryRepository repository;
  late StorageService storage;
  late ImportService importer;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('private-shelf-test-');
    database = AppDatabase(
      factory: databaseFactoryFfi,
      overridePath: p.join(sandbox.path, 'library.db'),
    );
    repository = LibraryRepository(database);
    storage = StorageService(
      rootOverride: Directory(p.join(sandbox.path, 'files')),
    );
    await storage.initialize();
    importer = ImportService(repository, storage);
  });

  tearDown(() async {
    await database.close();
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('原图导入前后哈希一致，删除源文件后私有副本仍存在', () async {
    final comic = await repository.createComic('哈希测试');
    final source = await _createPng(sandbox, 'source.png');
    final before = (await sha256.bind(source.openRead()).first).toString();

    final report = await importer.importFiles(
      comicId: comic.id,
      files: <PlatformFile>[_TestPlatformFile(source)],
      duplicatePolicy: DuplicatePolicy.skip,
    );
    expect(report.imported, 1);
    final items = await repository.loadItems(comic.id);
    expect(items, hasLength(1));
    final privateCopy = File(storage.resolve(items.single.asset.storedPath));
    final after = (await sha256.bind(privateCopy.openRead()).first).toString();
    expect(after, before);

    await source.delete();
    expect(await privateCopy.exists(), isTrue);
  });

  test('同一原图跨漫画只存一份，删除一个引用不影响另一本', () async {
    final first = await repository.createComic('第一本');
    final second = await repository.createComic('第二本');
    final source = await _createPng(sandbox, 'shared.png');
    final platformFile = _TestPlatformFile(source);
    await importer.importFiles(
      comicId: first.id,
      files: <PlatformFile>[platformFile],
      duplicatePolicy: DuplicatePolicy.keep,
    );
    await importer.importFiles(
      comicId: second.id,
      files: <PlatformFile>[platformFile],
      duplicatePolicy: DuplicatePolicy.keep,
    );

    final stats = await repository.loadStats(thumbnailBytes: 0);
    expect(stats.assetCount, 1);
    expect(stats.referenceCount, 2);
    final firstItem = (await repository.loadItems(first.id)).single;
    await repository.removeItem(firstItem.id);
    expect(await repository.loadItems(first.id), isEmpty);
    expect(await repository.loadItems(second.id), hasLength(1));
  });

  test('v1 数据库升级后旧漫画保持不变并支持回收站恢复', () async {
    final path = p.join(sandbox.path, 'legacy-v1.db');
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE assets (
              id TEXT PRIMARY KEY,
              content_hash TEXT NOT NULL UNIQUE,
              original_file_name TEXT NOT NULL,
              mime_type TEXT NOT NULL,
              extension TEXT NOT NULL,
              byte_size INTEGER NOT NULL,
              width INTEGER NOT NULL DEFAULT 0,
              height INTEGER NOT NULL DEFAULT 0,
              stored_path TEXT NOT NULL,
              thumbnail_path TEXT NOT NULL,
              created_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE comics (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              cover_asset_id TEXT,
              sort_index INTEGER NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              last_read_position INTEGER NOT NULL DEFAULT 0,
              last_read_offset REAL NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('''
            CREATE TABLE comic_items (
              id TEXT PRIMARY KEY,
              comic_id TEXT NOT NULL,
              asset_id TEXT NOT NULL,
              position INTEGER NOT NULL,
              created_at TEXT NOT NULL
            )
          ''');
          await db.execute(
            'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
        },
      ),
    );
    const created = '2026-08-29T00:00:00.000Z';
    await legacy.insert('assets', <String, Object?>{
      'id': 'legacy-asset',
      'content_hash': 'legacy-hash',
      'original_file_name': '001.png',
      'mime_type': 'image/png',
      'extension': 'png',
      'byte_size': 321,
      'width': 10,
      'height': 20,
      'stored_path': 'assets/legacy-hash.png',
      'thumbnail_path': 'thumbnails/legacy-hash.jpg',
      'created_at': created,
    });
    await legacy.insert('comics', <String, Object?>{
      'id': 'legacy-comic',
      'title': '升级前漫画',
      'cover_asset_id': 'legacy-asset',
      'sort_index': 0,
      'created_at': created,
      'updated_at': created,
      'last_read_position': 7,
      'last_read_offset': 12.5,
    });
    await legacy.insert('comic_items', <String, Object?>{
      'id': 'legacy-item',
      'comic_id': 'legacy-comic',
      'asset_id': 'legacy-asset',
      'position': 0,
      'created_at': created,
    });
    await legacy.close();

    final migratedDatabase = AppDatabase(
      factory: databaseFactoryFfi,
      overridePath: path,
    );
    final migrated = LibraryRepository(migratedDatabase);
    addTearDown(migratedDatabase.close);

    final beforeDelete = await migrated.loadLibrary();
    expect(beforeDelete, hasLength(1));
    expect(beforeDelete.single.comic.title, '升级前漫画');
    expect(beforeDelete.single.comic.lastReadPosition, 7);
    expect(beforeDelete.single.itemCount, 1);
    expect(beforeDelete.single.totalBytes, 321);

    await migrated.deleteComic('legacy-comic');
    expect(await migrated.loadLibrary(), isEmpty);
    expect(await migrated.loadDeletedComics(), hasLength(1));

    await migrated.restoreComic('legacy-comic');
    expect(await migrated.loadLibrary(), hasLength(1));
    expect(await migrated.loadDeletedComics(), isEmpty);
  });

  test('1000 张可重排且第 1001 张被产品上限拦截', () async {
    final comic = await repository.createComic('千图测试');
    final asset = AssetRecord(
      id: 'asset-1',
      contentHash: 'hash-1',
      originalFileName: 'same.png',
      mimeType: 'image/png',
      extension: 'png',
      byteSize: 10,
      width: 2,
      height: 2,
      storedPath: 'assets/hash-1.png',
      thumbnailPath: 'thumbnails/hash-1.jpg',
      createdAt: DateTime.utc(2026, 8, 29),
    );
    for (var index = 0; index < 1000; index++) {
      await repository.attachAsset(comicId: comic.id, asset: asset);
    }
    final items = await repository.loadItems(comic.id);
    expect(items, hasLength(1000));

    await repository.reorderItems(
      comic.id,
      items.reversed.map((item) => item.id).toList(growable: false),
    );
    final reversed = await repository.loadItems(comic.id);
    expect(reversed.first.id, items.last.id);
    expect(reversed.last.id, items.first.id);
    await expectLater(
      repository.attachAsset(comicId: comic.id, asset: asset),
      throwsA(isA<StateError>()),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('完整备份可恢复名称、封面、顺序、进度与原图', () async {
    final comic = await repository.createComic('备份原名');
    final source = await _createPng(sandbox, 'backup.png');
    await importer.importFiles(
      comicId: comic.id,
      files: <PlatformFile>[_TestPlatformFile(source)],
      duplicatePolicy: DuplicatePolicy.keep,
    );
    final item = (await repository.loadItems(comic.id)).single;
    await repository.setCover(comic.id, item.asset.id);
    await repository.saveProgress(comic.id, 0, 12.5);
    final backupService = BackupService(repository, storage);
    final backup = await backupService.createBackup();

    await repository.renameComic(comic.id, '被修改');
    await repository.removeItem(item.id);
    await backupService.restoreBackup(_TestPlatformFile(backup));

    final restored = await repository.getComic(comic.id);
    expect(restored?.comic.title, '备份原名');
    expect(restored?.comic.coverAssetId, item.asset.id);
    expect(restored?.comic.lastReadOffset, 12.5);
    final restoredItems = await repository.loadItems(comic.id);
    expect(restoredItems, hasLength(1));
    final restoredFile = File(
      storage.resolve(restoredItems.single.asset.storedPath),
    );
    expect(await restoredFile.exists(), isTrue);
    expect(
      (await sha256.bind(restoredFile.openRead()).first).toString(),
      item.asset.contentHash,
    );
  });

  test('多个漫画压缩包按选择队列与文件名自然顺序连续追加', () async {
    final comic = await repository.createComic('压缩包队列');
    final existing = await _createPng(sandbox, 'existing.png');
    await importer.importFiles(
      comicId: comic.id,
      files: <PlatformFile>[_TestPlatformFile(existing)],
      duplicatePolicy: DuplicatePolicy.keep,
    );

    final first =
        await _createZip(sandbox, 'chapter-a.cbz', <String, List<int>>{
          'chapter/10.png': _pngBytes(10),
          'chapter/2.png': _pngBytes(2),
          'chapter/1.png': _pngBytes(1),
        });
    final second = await _createZip(
      sandbox,
      'chapter-b.zip',
      <String, List<int>>{'004.png': _pngBytes(4), '003.png': _pngBytes(3)},
    );
    final archiveImporter = ArchiveImportService(repository, storage, importer);
    final selection = await archiveImporter.prepareArchives(<PlatformFile>[
      _TestPlatformFile(first),
      _TestPlatformFile(second),
    ]);
    addTearDown(selection.dispose);

    expect(selection.archives.map((item) => item.format), <String>[
      'zip',
      'zip',
    ]);
    expect(selection.totalPages, 5);
    final report = await archiveImporter.importPrepared(
      comicId: comic.id,
      selection: selection,
      duplicatePolicy: DuplicatePolicy.keep,
    );
    expect(report.imported, 5);
    expect(report.failures, isEmpty);

    final names = (await repository.loadItems(
      comic.id,
    )).map((item) => item.asset.originalFileName).toList(growable: false);
    expect(names, <String>[
      'existing.png',
      '1.png',
      '2.png',
      '10.png',
      '003.png',
      '004.png',
    ]);
  });
}

Future<File> _createPng(Directory directory, String name) async {
  final image = img.Image(width: 4, height: 6);
  img.fill(image, color: img.ColorRgb8(35, 117, 199));
  final file = File(p.join(directory.path, name));
  await file.writeAsBytes(img.encodePng(image), flush: true);
  return file;
}

List<int> _pngBytes(int seed) {
  final image = img.Image(width: 4, height: 6);
  img.fill(
    image,
    color: img.ColorRgb8(seed * 17 % 255, seed * 31 % 255, seed * 47 % 255),
  );
  return img.encodePng(image);
}

Future<File> _createZip(
  Directory directory,
  String name,
  Map<String, List<int>> entries,
) async {
  final archive = legacy_archive.Archive();
  for (final entry in entries.entries) {
    archive.addFile(legacy_archive.ArchiveFile.bytes(entry.key, entry.value));
  }
  final bytes = legacy_archive.ZipEncoder().encodeBytes(archive);
  final file = File(p.join(directory.path, name));
  await file.writeAsBytes(bytes, flush: true);
  return file;
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

import 'dart:io';
import 'dart:typed_data';

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
    storage = StorageService(rootOverride: Directory(p.join(sandbox.path, 'files')));
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
    final restoredFile = File(storage.resolve(restoredItems.single.asset.storedPath));
    expect(await restoredFile.exists(), isTrue);
    expect(
      (await sha256.bind(restoredFile.openRead()).first).toString(),
      item.asset.contentHash,
    );
  });
}

Future<File> _createPng(Directory directory, String name) async {
  final image = img.Image(width: 4, height: 6);
  img.fill(image, color: img.ColorRgb8(35, 117, 199));
  final file = File(p.join(directory.path, name));
  await file.writeAsBytes(img.encodePng(image), flush: true);
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

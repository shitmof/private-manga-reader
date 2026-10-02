import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:private_manga_reader/data/app_database.dart';
import 'package:private_manga_reader/data/library_repository.dart';
import 'package:private_manga_reader/models/entities.dart';
import 'package:private_manga_reader/services/import_service.dart';
import 'package:private_manga_reader/services/storage_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory sandbox;
  late AppDatabase database;
  late LibraryRepository repository;
  late StorageService storage;
  late ImportService importer;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('import-integrity-');
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('private_manga_reader/storage'),
          null,
        );
    await database.close();
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Future<File> validImage(String name) async {
    final file = File(p.join(sandbox.path, name));
    await file.writeAsBytes(img.encodePng(img.Image(width: 6, height: 9)));
    return file;
  }

  for (final policy in DuplicatePolicy.values) {
    test('重导有效副本修复损坏原图并保留稳定引用：${policy.name}', () async {
      final source = await validImage('source.png');
      final comic = await repository.createComic('原书');
      await importer.importFiles(
        comicId: comic.id,
        files: [_DiskFile(source)],
        duplicatePolicy: DuplicatePolicy.keep,
      );
      final item = (await repository.loadItems(comic.id)).single;
      await repository.setCover(comic.id, item.asset.id);
      final bookmark = await repository.saveBookmark(
        comicId: comic.id,
        itemId: item.id,
      );
      final original = File(storage.resolve(item.asset.storedPath));
      await original.writeAsBytes(List<int>.filled(256, 0));
      final report = await importer.importFiles(
        comicId: comic.id,
        files: [_DiskFile(source)],
        duplicatePolicy: policy,
      );
      expect(report.hasProblems, isFalse);
      expect(
        await original.readAsBytes(),
        await source.readAsBytes(),
        reason: '成功或跳过重复前都必须恢复已有原图',
      );
      final items = await repository.loadItems(comic.id);
      expect(items.first.id, item.id);
      expect(items.every((page) => page.asset.id == item.asset.id), isTrue);
      expect(items.length, policy == DuplicatePolicy.keep ? 2 : 1);
      expect((await repository.loadBookmarks(comic.id)).single.id, bookmark.id);
      expect(
        (await repository.allAssets()).single.contentHash,
        sha256.convert(await source.readAsBytes()).toString(),
      );
      expect(await storage.temporaryDirectory.list().toList(), isEmpty);
    });
  }

  test('无效 PNG 不计为成功、不留下原图或资产，后面的有效图正常导入', () async {
    final invalid = File(p.join(sandbox.path, 'invalid.png'));
    await invalid.writeAsBytes(List<int>.filled(256, 0));
    final valid = await validImage('valid.png');
    final comic = await repository.createComic('有效图片');
    final report = await importer.importFiles(
      comicId: comic.id,
      files: [_DiskFile(invalid), _DiskFile(valid)],
      duplicatePolicy: DuplicatePolicy.keep,
    );
    expect(report.imported, 1);
    expect(report.failures.single.sourceIndex, 0);
    expect(report.failures.single.reason, contains('图片'));
    expect(await repository.itemCount(comic.id), 1);
    expect(await repository.allAssets(), hasLength(1));
    expect(await storage.assetsDirectory.list().toList(), hasLength(1));
    expect(await storage.temporaryDirectory.list().toList(), isEmpty);
  });

  test('旧版零尺寸资产重导后修复元数据，保持页面和书签 ID', () async {
    final source = await validImage('legacy.png');
    final hash = sha256.convert(await source.readAsBytes()).toString();
    final stored = File(p.join(storage.assetsDirectory.path, '$hash.png'));
    await stored.writeAsBytes(await source.readAsBytes());
    final comic = await repository.createComic('旧格式');
    await repository.attachAsset(
      comicId: comic.id,
      asset: AssetRecord(
        id: 'legacy-asset',
        contentHash: hash,
        originalFileName: 'legacy.png',
        mimeType: 'image/png',
        extension: 'png',
        byteSize: await source.length(),
        width: 0,
        height: 0,
        storedPath: storage.relative(stored.path),
        thumbnailPath: 'thumbnails/$hash.jpg',
        createdAt: DateTime.now().toUtc(),
      ),
    );
    final before = (await repository.loadItems(comic.id)).single;
    final bookmark = await repository.saveBookmark(
      comicId: comic.id,
      itemId: before.id,
    );
    final report = await importer.importFiles(
      comicId: comic.id,
      files: [_DiskFile(source)],
      duplicatePolicy: DuplicatePolicy.skip,
    );
    expect(report.hasProblems, isFalse);
    expect(report.skippedDuplicates, 1);
    final after = (await repository.loadItems(comic.id)).single;
    expect(after.id, before.id);
    expect(after.asset.id, 'legacy-asset');
    expect((after.asset.width, after.asset.height), (6, 9));
    expect((await repository.loadBookmarks(comic.id)).single.id, bookmark.id);
  });

  test('Dart 不支持的格式由平台确认可解码后保留真实尺寸和原始字节', () async {
    // Decoder-boundary contract: the native probe supplies dimensions. These
    // bytes are an intentionally opaque stand-in, not a real HEIC decode test.
    final source = File(p.join(sandbox.path, 'platform-only.heic'));
    await source.writeAsBytes(List.generate(64, (i) => i));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('private_manga_reader/storage'),
          (call) async {
            expect(call.method, 'getImageDimensions');
            expect(
              (call.arguments as Map)['path'],
              startsWith(storage.root.path),
            );
            return <String, Object?>{'width': 64, 'height': 96};
          },
        );
    final comic = await repository.createComic('设备支持格式');
    final report = await importer.importFiles(
      comicId: comic.id,
      files: [_DiskFile(source)],
      duplicatePolicy: DuplicatePolicy.keep,
    );
    expect(report.hasProblems, isFalse);
    final item = (await repository.loadItems(comic.id)).single;
    expect(item.asset.width, 64);
    expect(item.asset.height, 96);
    expect(
      await File(storage.resolve(item.asset.storedPath)).readAsBytes(),
      await source.readAsBytes(),
    );
  });

  test('图片源读取中断后不留半文件，不阻断后一张有效图片', () async {
    final valid = await validImage('after-failure.png');
    final comic = await repository.createComic('流失败');
    final report = await importer.importFiles(
      comicId: comic.id,
      files: [_BrokenStreamFile(valid), _DiskFile(valid)],
      duplicatePolicy: DuplicatePolicy.keep,
    );
    expect(report.imported, 1);
    expect(report.failures, hasLength(1));
    expect(await storage.temporaryDirectory.list().toList(), isEmpty);
    expect(await repository.itemCount(comic.id), 1);
  });

  test('单本 1001 张图片真实入库，位置连续且原图只保留一份', () async {
    final source = await validImage('repeat.png');
    final comic = await repository.createComic('长篇');
    final files = List<PlatformFile>.generate(1001, (_) => _DiskFile(source));
    final report = await importer.importFiles(
      comicId: comic.id,
      files: files,
      duplicatePolicy: DuplicatePolicy.keep,
    );
    expect(report.hasProblems, isFalse);
    expect(report.imported, 1001);
    final items = await repository.loadItems(comic.id);
    expect(items, hasLength(1001));
    expect(
      items.map((item) => item.position),
      List.generate(1001, (index) => index),
    );
    expect(items.map((item) => item.id).toSet(), hasLength(1001));
    expect(await repository.allAssets(), hasLength(1));
    expect(await storage.assetsDirectory.list().toList(), hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 2)));

  for (final policy in DuplicatePolicy.values) {
    test('已有页数加本次选择超限时预检拒绝，未读取或部分写入：${policy.name}', () async {
      final source = await validImage('capacity.png');
      final comic = await repository.createComic('已有一页');
      await importer.importFiles(
        comicId: comic.id,
        files: [_DiskFile(source)],
        duplicatePolicy: DuplicatePolicy.keep,
      );
      final before = (await repository.loadItems(comic.id)).single;
      var reads = 0;
      final file = _DiskFile(source, onRead: () => reads++);
      final files = List<PlatformFile>.filled(
        LibraryRepository.maxItemsPerComic,
        file,
      );
      final report = await importer.importFiles(
        comicId: comic.id,
        files: files,
        duplicatePolicy: policy,
      );
      expect(report.imported, 0);
      expect(report.failures, hasLength(files.length));
      expect(report.failures.first.reason, contains('已有 1 张'));
      expect(report.failures.first.reason, contains('10000'));
      expect(report.failures.last.sourceIndex, files.length - 1);
      expect(reads, 0);
      expect((await repository.loadItems(comic.id)).single.id, before.id);
      expect(await storage.temporaryDirectory.list().toList(), isEmpty);
    });
  }
}

final class _BrokenStreamFile extends PlatformFile {
  _BrokenStreamFile(this.file);
  final File file;
  @override
  String get name => 'interrupted.png';
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
    yield Uint8List.fromList([137, 80, 78, 71]);
    throw const FileSystemException('源读取中断');
  }
}

final class _DiskFile extends PlatformFile {
  _DiskFile(this.file, {this.onRead});
  final File file;
  final void Function()? onRead;
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
    onRead?.call();
    await for (final chunk in file.openRead()) {
      yield Uint8List.fromList(chunk);
    }
  }
}

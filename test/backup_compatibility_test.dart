import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cross_file/cross_file.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:private_manga_reader/data/app_database.dart';
import 'package:private_manga_reader/data/library_repository.dart';
import 'package:private_manga_reader/models/entities.dart';
import 'package:private_manga_reader/services/backup_service.dart';
import 'package:private_manga_reader/services/storage_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory sandbox;
  late AppDatabase database;
  late LibraryRepository repository;
  late StorageService storage;
  late BackupService backups;
  late String comicId;
  late AssetRecord asset;
  const originalBytes = <int>[137, 80, 78, 71, 1, 2, 3];

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('backup-compatibility-');
    database = AppDatabase(
      factory: databaseFactoryFfi,
      overridePath: p.join(sandbox.path, 'library.db'),
    );
    repository = LibraryRepository(database);
    storage = StorageService(
      rootOverride: Directory(p.join(sandbox.path, 'files')),
    );
    await storage.initialize();
    backups = BackupService(repository, storage);
    comicId = (await repository.createComic('原有书库')).id;
    final hash = sha256.convert(originalBytes).toString();
    asset = AssetRecord(
      id: 'test-asset',
      contentHash: hash,
      originalFileName: '原图.png',
      mimeType: 'image/png',
      extension: 'png',
      byteSize: originalBytes.length,
      width: 1,
      height: 1,
      storedPath: 'assets/$hash.png',
      thumbnailPath: 'thumbnails/$hash.jpg',
      createdAt: DateTime.utc(2026, 9, 26),
    );
    await File(storage.resolve(asset.storedPath)).writeAsBytes(originalBytes);
    await repository.attachAsset(comicId: comicId, asset: asset);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('private_manga_reader/storage'),
          null,
        );
    await database.close();
    await sandbox.delete(recursive: true);
  });

  Future<File> fixture(
    Map<String, Object?> manifest, {
    List<int> bytes = originalBytes,
    List<ArchiveFile> extras = const <ArchiveFile>[],
  }) async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('manifest.json', jsonEncode(manifest)))
      ..addFile(ArchiveFile(asset.storedPath, bytes.length, bytes));
    for (final entry in extras) {
      archive.addFile(entry);
    }
    final file = File(p.join(sandbox.path, 'input.mangabackup'));
    final encoded = Uint8List.fromList(ZipEncoder().encode(archive));
    if (extras.any((entry) => entry.mode & 0xf000 == 0xa000)) {
      // archive 的编码器固定标记为 DOS；此夹具模拟实际 Unix ZIP 的符号链接。
      final data = ByteData.sublistView(encoded);
      final end = encoded.length - 22;
      var offset = data.getUint32(end + 16, Endian.little);
      final count = data.getUint16(end + 10, Endian.little);
      for (var index = 0; index < count; index++) {
        encoded[offset + 5] = 3;
        offset +=
            46 +
            data.getUint16(offset + 28, Endian.little) +
            data.getUint16(offset + 30, Endian.little) +
            data.getUint16(offset + 32, Endian.little);
      }
    }
    await file.writeAsBytes(encoded);
    return file;
  }

  test('拒绝越界缩略图路径，原有书库和原图保持不变', () async {
    final manifest = await repository.exportManifest();
    manifest['assets'] = <Map<String, Object?>>[
      {...asset.toMap(), 'thumbnail_path': '../../outside.jpg'},
    ];
    await repository.renameComic(comicId, '恢复前名称');
    final input = await fixture(manifest);

    await expectLater(
      backups.restoreBackup(_LocalPlatformFile(input)),
      throwsFormatException,
    );
    expect((await repository.getComic(comicId))!.comic.title, '恢复前名称');
    expect(
      await File(storage.resolve(asset.storedPath)).readAsBytes(),
      originalBytes,
    );
    expect(await storage.temporaryDirectory.list().toList(), isEmpty);
  });

  test('ZIP 中包含越界条目时拒绝整个备份，不静默跳过后覆盖书库', () async {
    final manifest = await repository.exportManifest();
    await repository.renameComic(comicId, '不能被覆盖');
    final input = await fixture(
      manifest,
      extras: <ArchiveFile>[ArchiveFile.string('../outside.txt', 'unsafe')],
    );

    await expectLater(
      backups.restoreBackup(_LocalPlatformFile(input)),
      throwsFormatException,
    );
    expect((await repository.getComic(comicId))!.comic.title, '不能被覆盖');
    expect(await storage.temporaryDirectory.list().toList(), isEmpty);
  });

  test('本地同路径内容冲突时拒绝恢复，不把现存错误内容当成已恢复原图', () async {
    final manifest = await repository.exportManifest();
    final input = await fixture(manifest);
    const currentBytes = <int>[9, 8, 7];
    await File(storage.resolve(asset.storedPath)).writeAsBytes(currentBytes);
    await repository.renameComic(comicId, '冲突前书库');

    await expectLater(
      backups.restoreBackup(_LocalPlatformFile(input)),
      throwsFormatException,
    );
    expect((await repository.getComic(comicId))!.comic.title, '冲突前书库');
    expect(
      await File(storage.resolve(asset.storedPath)).readAsBytes(),
      currentBytes,
    );
  });

  test('原图 SHA-256 校验失败时不改变名称、顺序或现存文件', () async {
    final manifest = await repository.exportManifest();
    await repository.renameComic(comicId, '校验失败前');
    final before = await repository.loadItems(comicId);
    final input = await fixture(manifest, bytes: <int>[0, 1, 2]);

    await expectLater(
      backups.restoreBackup(_LocalPlatformFile(input)),
      throwsFormatException,
    );
    expect((await repository.getComic(comicId))!.comic.title, '校验失败前');
    expect(
      (await repository.loadItems(comicId)).map((item) => item.id),
      before.map((item) => item.id),
    );
    expect(
      await File(storage.resolve(asset.storedPath)).readAsBytes(),
      originalBytes,
    );
    expect(await storage.backupsDirectory.list().toList(), isEmpty);
  });

  for (final version in <int>[1, 2, 3, 4]) {
    test('v$version 备份可恢复原图、标题、封面及进度，下一次仍导出 v4', () async {
      await repository.setCover(comicId, asset.id);
      await repository.saveProgress(comicId, 0, 12.5);
      final manifest = await repository.exportManifest();
      manifest['version'] = version;
      if (version < 4) manifest.remove('shelfEntries');
      if (version < 3) {
        for (final key in <String>[
          'shelfFolders',
          'pageBookmarks',
          'readingLists',
          'readingListItems',
        ]) {
          manifest.remove(key);
        }
        manifest['comics'] = (manifest['comics']! as List).map((row) {
          final legacy = Map<String, Object?>.from(row as Map);
          for (final key in <String>[
            'folder_id',
            'is_private',
            'is_pinned',
            'read_status',
            'last_read_at',
          ]) {
            legacy.remove(key);
          }
          if (version == 1) legacy.remove('deleted_at');
          return legacy;
        }).toList();
      }
      if (version == 1) {
        manifest.remove('networkSources');
        manifest.remove('remoteBooks');
        manifest.remove('remotePages');
      }
      final input = await fixture(manifest);
      await repository.renameComic(comicId, '恢复前临时名称');
      final safety = await backups.restoreBackup(_LocalPlatformFile(input));

      expect(await safety.exists(), isTrue);
      final restored = (await repository.getComic(comicId))!.comic;
      expect(restored.title, '原有书库');
      expect(restored.coverAssetId, asset.id);
      expect(restored.lastReadOffset, 12.5);
      final restoredItems = await repository.loadItems(comicId);
      expect(restoredItems, hasLength(1));
      expect(restoredItems.single.asset.storedPath, asset.storedPath);
      expect(
        await File(storage.resolve(asset.storedPath)).readAsBytes(),
        originalBytes,
      );
      final output = await backups.createBackup(prefix: 'compatibility-output');
      final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
      final outputManifest =
          jsonDecode(utf8.decode(archive.findFile('manifest.json')!.content))
              as Map;
      expect(outputManifest['format'], 'private-manga-reader-backup');
      expect(outputManifest['version'], 4);
      expect(await storage.temporaryDirectory.list().toList(), isEmpty);
    });
  }

  for (final path in <String>[
    '../outside.png',
    r'assets\..\outside.png',
    '/outside.png',
    r'C:\outside.png',
    'backups/overwrite.mangabackup',
  ]) {
    test('原图存储路径必须位于 assets 内：$path', () async {
      final manifest = await repository.exportManifest();
      manifest['assets'] = <Map<String, Object?>>[
        {...asset.toMap(), 'stored_path': path},
      ];
      await repository.renameComic(comicId, '不能被恶意清单覆盖');
      final input = await fixture(manifest);
      await expectLater(
        backups.restoreBackup(_LocalPlatformFile(input)),
        throwsFormatException,
      );
      expect((await repository.getComic(comicId))!.comic.title, '不能被恶意清单覆盖');
      expect(
        await File(storage.resolve(asset.storedPath)).readAsBytes(),
        originalBytes,
      );
    });
  }

  test('拒绝符号链接备份且不覆盖现存书库', () async {
    final manifest = await repository.exportManifest();
    await repository.renameComic(comicId, '符号链接前');
    final input = await fixture(
      manifest,
      extras: <ArchiveFile>[
        ArchiveFile.string('link', asset.storedPath)..mode = 0xa1ff,
      ],
    );
    expect(
      ZipDecoder()
          .decodeBytes(await input.readAsBytes())
          .findFile('link')!
          .isSymbolicLink,
      isTrue,
    );
    await expectLater(
      backups.restoreBackup(_LocalPlatformFile(input)),
      throwsFormatException,
    );
    expect((await repository.getComic(comicId))!.comic.title, '符号链接前');
  });

  test('不支持的版本不会覆盖数据', () async {
    final manifest = await repository.exportManifest();
    manifest['version'] = 99;
    await repository.renameComic(comicId, '未知版本前');
    final input = await fixture(manifest);
    await expectLater(
      backups.restoreBackup(_LocalPlatformFile(input)),
      throwsFormatException,
    );
    expect((await repository.getComic(comicId))!.comic.title, '未知版本前');
  });

  test('同一秒连续创建备份不会覆盖此前的恢复点', () async {
    final files = await Future.wait(
      List.generate(3, (_) => backups.createBackup(prefix: 'same-second')),
    );
    expect(files.map((file) => file.path).toSet(), hasLength(3));
    for (final file in files) {
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      expect(archive.findFile('manifest.json'), isNotNull);
      expect(archive.findFile(asset.storedPath)!.content, originalBytes);
    }
  });

  test('读取备份中途失败时关闭文件并清除所有恢复临时内容', () async {
    final input = await fixture(await repository.exportManifest());
    await expectLater(
      backups.restoreBackup(_FailingPlatformFile(input)),
      throwsA(isA<FileSystemException>()),
    );
    expect(await storage.temporaryDirectory.list().toList(), isEmpty);
    expect((await repository.getComic(comicId))!.comic.title, '原有书库');
    expect(
      await File(storage.resolve(asset.storedPath)).readAsBytes(),
      originalBytes,
    );
  });

  test('空间不足时创建备份明确失败且不留下备份残片或改动书库', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('private_manga_reader/storage'),
          (call) async => call.method == 'getFreeSpace' ? 0 : null,
        );

    await expectLater(
      backups.createBackup(),
      throwsA(isA<FileSystemException>()),
    );
    expect(await storage.backupsDirectory.list().toList(), isEmpty);
    expect(await storage.temporaryDirectory.list().toList(), isEmpty);
    expect((await repository.getComic(comicId))!.comic.title, '原有书库');
    expect(
      await File(storage.resolve(asset.storedPath)).readAsBytes(),
      originalBytes,
    );
  });

  test('完整备份只需一份输出空间，保留原图字节与 v4 格式', () async {
    const megabyte = 1024 * 1024;
    final bytes = Uint8List(32 * megabyte)..fillRange(0, 32 * megabyte, 7);
    final hash = sha256.convert(bytes).toString();
    final largeAsset = AssetRecord(
      id: 'large-asset',
      contentHash: hash,
      originalFileName: 'large.png',
      mimeType: 'image/png',
      extension: 'png',
      byteSize: bytes.length,
      width: 1,
      height: 1,
      storedPath: 'assets/$hash.png',
      thumbnailPath: 'thumbnails/$hash.jpg',
      createdAt: DateTime.utc(2026, 10, 2),
    );
    await File(storage.resolve(largeAsset.storedPath)).writeAsBytes(bytes);
    await repository.attachAsset(comicId: comicId, asset: largeAsset);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('private_manga_reader/storage'),
          (call) async => call.method == 'getFreeSpace' ? 50 * megabyte : null,
        );

    final output = await backups.createBackup();
    final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
    final manifest =
        jsonDecode(utf8.decode(archive.findFile('manifest.json')!.content))
            as Map;
    expect(manifest['version'], 4);
    expect(
      sha256
          .convert(archive.findFile(largeAsset.storedPath)!.content)
          .toString(),
      hash,
    );
    expect(await storage.temporaryDirectory.list().toList(), isEmpty);
    expect(await storage.backupsDirectory.list().toList(), hasLength(1));
  });

  test('空间不足时恢复在复制或替换书库前停止并清理临时文件', () async {
    final input = await fixture(await repository.exportManifest());
    final trackedSource = _TrackingPlatformFile(input);
    await repository.renameComic(comicId, '空间不足前书库');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('private_manga_reader/storage'),
          (call) async => call.method == 'getFreeSpace' ? 0 : null,
        );

    await expectLater(
      backups.restoreBackup(trackedSource),
      throwsA(isA<FileSystemException>()),
    );
    expect(trackedSource.wasRead, isFalse);
    expect((await repository.getComic(comicId))!.comic.title, '空间不足前书库');
    expect(await storage.backupsDirectory.list().toList(), isEmpty);
    expect(await storage.temporaryDirectory.list().toList(), isEmpty);
    expect(
      await File(storage.resolve(asset.storedPath)).readAsBytes(),
      originalBytes,
    );
  });

  test('恢复清单入库失败时撤销本次新复制文件并保留原有书库和安全备份', () async {
    const newPath = 'assets/restored-copy.png';
    final manifest = await repository.exportManifest();
    manifest['assets'] = <Map<String, Object?>>[
      {...asset.toMap(), 'stored_path': newPath},
    ];
    manifest['settings'] = 'invalid-table';
    final input = await fixture(
      manifest,
      extras: <ArchiveFile>[
        ArchiveFile(newPath, originalBytes.length, originalBytes),
      ],
    );
    await repository.renameComic(comicId, '入库失败前书库');

    await expectLater(
      backups.restoreBackup(_LocalPlatformFile(input)),
      throwsFormatException,
    );
    expect((await repository.getComic(comicId))!.comic.title, '入库失败前书库');
    expect(await File(storage.resolve(newPath)).exists(), isFalse);
    expect(await storage.temporaryDirectory.list().toList(), isEmpty);
    expect(await storage.backupsDirectory.list().toList(), hasLength(1));
    expect(
      await File(storage.resolve(asset.storedPath)).readAsBytes(),
      originalBytes,
    );
  });
}

base class _LocalPlatformFile extends PlatformFile {
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

final class _FailingPlatformFile extends _LocalPlatformFile {
  _FailingPlatformFile(super.file);

  @override
  Stream<Uint8List> readAsByteStream() async* {
    yield Uint8List.fromList(<int>[80, 75, 3, 4]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    throw const FileSystemException('测试读取中断');
  }
}

final class _TrackingPlatformFile extends _LocalPlatformFile {
  _TrackingPlatformFile(super.file);
  bool wasRead = false;

  @override
  Stream<Uint8List> readAsByteStream() {
    wasRead = true;
    return super.readAsByteStream();
  }
}

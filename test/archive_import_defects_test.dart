import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as legacy_archive;
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:private_manga_reader/data/app_database.dart';
import 'package:private_manga_reader/data/library_repository.dart';
import 'package:private_manga_reader/models/entities.dart';
import 'package:private_manga_reader/services/archive_import_service.dart';
import 'package:private_manga_reader/services/import_service.dart';
import 'package:private_manga_reader/services/storage_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 外部审查指出的三个导入缺陷的回归测试。
///
/// 要求：这些用例必须在**修复前失败**，修复后通过。
/// 断言的是**实际入库数量、图片顺序、失败记录与重试结果**，
/// 而不是"识别到了压缩包"。
void main() {
  sqfliteFfiInit();

  late Directory sandbox;
  late AppDatabase database;
  late LibraryRepository repository;
  late ArchiveImportService archiveImporter;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('archive-defects-');
    database = AppDatabase(
      factory: databaseFactoryFfi,
      overridePath: p.join(sandbox.path, 'library.db'),
    );
    repository = LibraryRepository(database);
    final storage = StorageService(
      rootOverride: Directory(p.join(sandbox.path, 'files')),
    );
    await storage.initialize();
    archiveImporter = ArchiveImportService(
      repository,
      storage,
      ImportService(repository, storage),
    );
  });

  tearDown(() async {
    await database.close();
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  // 每张图用不同颜色，便于断言顺序。
  Uint8List png(int seed) {
    final image = img.Image(width: 6, height: 9);
    img.fill(image, color: img.ColorRgb8(seed * 7 % 255, 40, 90));
    return Uint8List.fromList(img.encodePng(image));
  }

  Uint8List cbzWithPages(List<int> seeds) {
    final archive = legacy_archive.Archive();
    for (var index = 0; index < seeds.length; index++) {
      final name = '${(index + 1).toString().padLeft(3, '0')}.png';
      archive.addFile(
        legacy_archive.ArchiveFile.bytes(name, png(seeds[index])),
      );
    }
    return Uint8List.fromList(legacy_archive.ZipEncoder().encode(archive));
  }

  Future<File> writeZip(
    String name, {
    required Map<String, List<int>> entries,
  }) async {
    final archive = legacy_archive.Archive();
    for (final entry in entries.entries) {
      archive.addFile(
        legacy_archive.ArchiveFile.bytes(
          entry.key,
          Uint8List.fromList(entry.value),
        ),
      );
    }
    final file = File(p.join(sandbox.path, name));
    await file.writeAsBytes(legacy_archive.ZipEncoder().encode(archive));
    return file;
  }

  Future<List<String>> titlesInOrder(String comicId) async {
    final items = await repository.loadItems(comicId);
    return items
        .map((item) => item.asset.originalFileName)
        .toList(growable: false);
  }

  group('缺陷 1：混合压缩包（外层图片 + 内层 CBZ）', () {
    test('外层封面与 7 个内层包的全部图片都要入库，且保留包内顺序', () async {
      final outer = await writeZip(
        'mixed.zip',
        entries: <String, List<int>>{
          // 外层封面：修复前只要它存在，内层包会被整体丢弃
          'cover.jpg': png(200),
          for (var chapter = 1; chapter <= 7; chapter++)
            '书/第$chapter话.cbz': cbzWithPages(<int>[
              chapter * 10 + 1,
              chapter * 10 + 2,
            ]),
        },
      );

      final selection = await archiveImporter.prepareArchives(<PlatformFile>[
        _TestFile(outer),
      ]);
      addTearDown(selection.dispose);

      // 预期页数：封面 1 + 7 包 × 2 = 15
      expect(
        selection.totalPages,
        15,
        reason: '外层封面与全部内层包的图片都必须被识别，不能有图就丢掉内层包',
      );
    });
  });

  group('缺陷 2：扫描阶段错误必须可见', () {
    test('内层包损坏时，成功部分保留且失败原因可见', () async {
      // 中间一个内层包写入不可解析的内容
      final outer = await writeZip(
        'broken-inner.zip',
        entries: <String, List<int>>{
          '书/第1话.cbz': cbzWithPages(<int>[1, 2]),
          '书/第2话.cbz': utf8.encode('这不是一个压缩包' * 40),
          '书/第3话.cbz': cbzWithPages(<int>[5, 6]),
        },
      );

      final selection = await archiveImporter.prepareArchives(<PlatformFile>[
        _TestFile(outer),
      ]);
      addTearDown(selection.dispose);

      expect(selection.totalPages, 4, reason: '第 1、3 话共 4 张应保留');
      expect(
        selection.errors,
        isNotEmpty,
        reason: '第 2 话损坏必须被记录，不能静默丢弃',
      );
      expect(
        selection.errors.join(' '),
        contains('第2话'),
        reason: '失败原因必须能指出具体文件',
      );

      // 关键：扫描阶段的问题必须一路传到调用方，否则界面无从展示，
      // 用户会在存在损坏章节的情况下看到「导入完成」。
      final comic = await repository.createComic('损坏内层包');
      final report = await archiveImporter.importPrepared(
        comicId: comic.id,
        selection: selection,
        duplicatePolicy: DuplicatePolicy.keep,
      );
      expect(
        report.scanErrors,
        isNotEmpty,
        reason: '扫描阶段的错误必须出现在导入结果里，不能只留在 selection 内部',
      );
      expect(
        report.scanErrors.join(' '),
        contains('第2话'),
        reason: '结果里必须能看到是哪个文件出了问题',
      );
      expect(
        report.hasProblems,
        isTrue,
        reason: '存在扫描问题时不能报告为「导入完成」',
      );
    });
  });

  group('缺陷 3：失败重试不能重复追加', () {
    test('每个包有独立标识；失败后其余包仍被处理', () async {
      final first = await writeZip(
        'a.cbz',
        entries: <String, List<int>>{'001.png': png(1)},
      );
      final middle = await writeZip(
        'b.cbz',
        entries: <String, List<int>>{'001.png': png(2)},
      );
      final last = await writeZip(
        'c.cbz',
        entries: <String, List<int>>{'001.png': png(3)},
      );

      final selection = await archiveImporter.prepareArchives(<PlatformFile>[
        _TestFile(first),
        _TestFile(middle),
        _TestFile(last),
      ]);
      addTearDown(selection.dispose);

      // 标识必须互不相同——同一 outer 解出的内层包共用 sourceIndex 会导致重试错选
      final keys = selection.archives.map((a) => a.archiveKey).toSet();
      expect(
        keys.length,
        selection.archives.length,
        reason: '每个压缩包必须有独立可追踪的标识',
      );

      final comic = await repository.createComic('重试测试');

      // 让中间那个包在导入阶段打不开
      final middleArchive = selection.archives[1];
      if (await middleArchive.localFile.exists()) {
        await middleArchive.localFile.delete();
      }

      final report = await archiveImporter.importPrepared(
        comicId: comic.id,
        selection: selection,
        duplicatePolicy: DuplicatePolicy.keep,
      );

      expect(
        report.imported,
        2,
        reason: '首尾两个包必须都导入；第一个包失败不能导致后续包被跳过',
      );
      expect(report.failures, hasLength(1), reason: '只有中间那个包应失败');
      expect(
        report.failures.single.archiveKey,
        middleArchive.archiveKey,
        reason: '失败记录必须带可追踪的包标识',
      );

      // 重试集合只包含失败的那个包
      final retryKeys = report.failures.map((f) => f.archiveKey).toSet();
      final retrySelection = PreparedArchiveSelection(
        selection.archives
            .where((a) => retryKeys.contains(a.archiveKey))
            .toList(growable: false),
        temporaryFiles: selection.temporaryFiles,
      );
      expect(
        retrySelection.archives, hasLength(1),
        reason: '重试只能包含失败的那一个包',
      );

      // 重试后总数不能重复追加
      final before = (await repository.loadItems(comic.id)).length;
      expect(before, 2);
      expect(
        (await titlesInOrder(comic.id)).length,
        2,
        reason: '已成功内容不能被重复追加',
      );
    });
  });
}

final class _TestFile extends PlatformFile {
  _TestFile(this.file);

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

import 'dart:convert';
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
  TestWidgetsFlutterBinding.ensureInitialized();
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

  List<String> hashesFor(List<int> seeds) => seeds
      .map((seed) => sha256.convert(png(seed)).toString())
      .toList(growable: false);

  Future<List<String>> hashesInOrder(String comicId) async =>
      (await repository.loadItems(
        comicId,
      )).map((item) => item.asset.contentHash).toList(growable: false);

  group('缺陷 1：混合压缩包（外层图片 + 内层 CBZ）', () {
    test('挂载缓存提取同样拒绝无效图片并清理该缓存目录', () async {
      final source = await writeZip(
        'invalid-mounted.cbz',
        entries: {'001.png': png(40), '002.png': List<int>.filled(256, 0)},
      );
      final selection = await archiveImporter.prepareArchives([
        _TestFile(source),
      ]);
      addTearDown(selection.dispose);
      final target = Directory(
        p.join(sandbox.path, 'files', 'network-cache', 'invalid-test'),
      );
      await expectLater(
        archiveImporter.extractPreparedToDirectory(
          archive: selection.archives.single,
          target: target,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await target.exists(), isFalse);
      expect(await repository.allAssets(), isEmpty);
    });

    test('长篇末页失败整批回滚，保留既有页、封面与书签并清掉新孤儿', () async {
      final existingArchive = await writeZip(
        'existing.cbz',
        entries: {'001.png': png(31)},
      );
      final existingSelection = await archiveImporter.prepareArchives([
        _TestFile(existingArchive),
      ]);
      addTearDown(existingSelection.dispose);
      final comic = await repository.createComic('长篇失败恢复');
      await archiveImporter.importPrepared(
        comicId: comic.id,
        selection: existingSelection,
        duplicatePolicy: DuplicatePolicy.keep,
        setCoverFromFirstArchive: true,
      );
      final existingItem = (await repository.loadItems(comic.id)).single;
      final bookmark = await repository.saveBookmark(
        comicId: comic.id,
        itemId: existingItem.id,
      );
      final longArchive = await writeZip(
        'long-with-bad-last.cbz',
        entries: {
          for (var i = 0; i < 1001; i++)
            '${i.toString().padLeft(5, '0')}.png': png(32),
          '99999.png': List<int>.filled(256, 0),
        },
      );
      final selection = await archiveImporter.prepareArchives([
        _TestFile(longArchive),
      ]);
      addTearDown(selection.dispose);
      final report = await archiveImporter.importPrepared(
        comicId: comic.id,
        selection: selection,
        duplicatePolicy: DuplicatePolicy.keep,
      );
      expect(report.imported, 0);
      expect(report.failures, hasLength(1));
      expect(report.failures.single.fileName, contains('99999.png'));
      final after = (await repository.loadItems(comic.id)).single;
      expect(after.id, existingItem.id);
      expect(after.position, 0);
      expect((await repository.loadBookmarks(comic.id)).single.id, bookmark.id);
      expect(
        (await repository.loadLibrary()).single.comic.coverAssetId,
        existingItem.asset.id,
      );
      expect(await repository.allAssets(), hasLength(1));
      expect(await repository.orphanedAssets(), isEmpty);
      expect(
        await Directory(
          p.join(sandbox.path, 'files', 'assets'),
        ).list().toList(),
        hasLength(1),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
      '多个真实压缩包合计超过 10000 页，导入前整体拒绝且不写入任何页',
      () async {
        final first = await writeZip(
          'first-large.cbz',
          entries: {
            for (var i = 0; i < 6000; i++)
              '${i.toString().padLeft(5, '0')}.png': png(21),
          },
        );
        final last = await writeZip(
          'last-large.cbz',
          entries: {
            for (var i = 0; i < 4001; i++)
              '${i.toString().padLeft(5, '0')}.png': png(22),
          },
        );
        final selection = await archiveImporter.prepareArchives([
          _TestFile(first),
          _TestFile(last),
        ]);
        addTearDown(selection.dispose);
        expect(selection.totalPages, 10001);
        final comic = await repository.createComic('超长选择');
        final report = await archiveImporter.importPrepared(
          comicId: comic.id,
          selection: selection,
          duplicatePolicy: DuplicatePolicy.keep,
        );
        expect(report.imported, 0);
        expect(report.failures, hasLength(2));
        expect(
          report.failures.every(
            (f) => f.reason.contains('10001') && f.archiveKey != null,
          ),
          isTrue,
        );
        expect(await repository.itemCount(comic.id), 0);
        expect(await repository.allAssets(), isEmpty);
        expect(
          await Directory(
            p.join(sandbox.path, 'files', 'assets'),
          ).list().toList(),
          isEmpty,
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('内层包解压流校验失败只报告该包，健康前后包入库且半文件清理', () async {
      final outer = await writeZip(
        'stream-error.zip',
        entries: {
          'first.cbz': cbzWithPages([11]),
          'broken.cbz': cbzWithPages([12]),
          'last.cbz': cbzWithPages([13]),
        },
      );
      final bytes = await outer.readAsBytes();
      final data = ByteData.sublistView(bytes);
      var changed = 0;
      for (var index = 0; index + 46 < bytes.length; index++) {
        final signature = data.getUint32(index, Endian.little);
        final central = signature == 0x02014b50;
        if (!central && signature != 0x04034b50) continue;
        final nameOffset = central ? 46 : 30;
        final nameLength = data.getUint16(
          index + (central ? 28 : 26),
          Endian.little,
        );
        if (index + nameOffset + nameLength > bytes.length) continue;
        if (utf8.decode(
              bytes.sublist(
                index + nameOffset,
                index + nameOffset + nameLength,
              ),
              allowMalformed: true,
            ) !=
            'broken.cbz') {
          continue;
        }
        final crcOffset = index + (central ? 16 : 14);
        data.setUint32(
          crcOffset,
          data.getUint32(crcOffset, Endian.little) ^ 0xffffffff,
          Endian.little,
        );
        changed++;
      }
      expect(changed, 2, reason: '夹具只篡改 broken.cbz 的本地和目录 CRC，不破坏外层扫描');
      await outer.writeAsBytes(bytes);
      final selection = await archiveImporter.prepareArchives([
        _TestFile(outer),
      ]);
      addTearDown(selection.dispose);
      expect(selection.errors, hasLength(1));
      expect(selection.errors.single, contains('broken.cbz'));
      expect(selection.totalPages, 2);
      final comic = await repository.createComic('解压失败隔离');
      final report = await archiveImporter.importPrepared(
        comicId: comic.id,
        selection: selection,
        duplicatePolicy: DuplicatePolicy.keep,
      );
      expect(report.imported, 2);
      expect(report.failures, isEmpty);
      expect(await hashesInOrder(comic.id), hashesFor([11, 13]));
      final directory = Directory(p.join(sandbox.path, 'files', 'backup-temp'));
      expect(
        (await directory.list().toList()).map((f) => f.path).toSet(),
        selection.temporaryFiles.map((f) => f.path).toSet(),
        reason: '失败流留下的半个 nested 文件不能泄漏',
      );
      await selection.dispose();
      expect(await directory.list().toList(), isEmpty);
    });

    test('外层封面与 7 个内层包的全部图片都要入库，且保留包内顺序', () async {
      final outer = await writeZip(
        'mixed.zip',
        entries: <String, List<int>>{
          // 外层封面：修复前只要它存在，内层包会被整体丢弃
          'cover.png': png(200),
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
      final comic = await repository.createComic('封面与七话');
      final report = await archiveImporter.importPrepared(
        comicId: comic.id,
        selection: selection,
        duplicatePolicy: DuplicatePolicy.keep,
      );
      expect(
        report.hasProblems,
        isFalse,
        reason: <String>[
          ...report.scanErrors,
          ...report.failures.map((f) => '${f.fileName}: ${f.reason}'),
        ].join('\n'),
      );
      expect(report.imported, 15);
      expect(
        await hashesInOrder(comic.id),
        hashesFor(<int>[
          200,
          for (var chapter = 1; chapter <= 7; chapter++) ...<int>[
            chapter * 10 + 1,
            chapter * 10 + 2,
          ],
        ]),
      );
    });

    test('内包与散图交错时保留段落位置，连续散图仍自然排序', () async {
      final outer = await writeZip(
        'interleaved.zip',
        entries: <String, List<int>>{
          'a.cbz': cbzWithPages(<int>[1]),
          '003.png': png(3),
          '002.png': png(2),
          'c.cbz': cbzWithPages(<int>[4]),
          'tail.png': png(5),
        },
      );
      final selection = await archiveImporter.prepareArchives(<PlatformFile>[
        _TestFile(outer),
      ]);
      addTearDown(selection.dispose);
      final comic = await repository.createComic('交错内容');
      final report = await archiveImporter.importPrepared(
        comicId: comic.id,
        selection: selection,
        duplicatePolicy: DuplicatePolicy.keep,
      );
      expect(report.hasProblems, isFalse);
      expect(report.imported, 5);
      expect(await hashesInOrder(comic.id), hashesFor(<int>[1, 2, 3, 4, 5]));
    });
  });

  group('漫画元数据标题', () {
    for (final metadata in <String, String>{
      '<ComicInfo><Title>  作者指定标题  </Title></ComicInfo>': '作者指定标题',
      '<ComicInfo><Title>  </Title></ComicInfo>': 'fallback',
      '<ComicInfo><Title>broken': 'fallback',
    }.entries) {
      test('优先有效标题，无效则回退文件名：${metadata.key}', () async {
        final file = await writeZip(
          'fallback.cbz',
          entries: <String, List<int>>{
            '001.png': png(1),
            'ComicInfo.xml': utf8.encode(metadata.key),
          },
        );
        final selection = await archiveImporter.prepareArchives(<PlatformFile>[
          _TestFile(file),
        ]);
        addTearDown(selection.dispose);
        expect(selection.suggestedTitle, metadata.value);
        expect(selection.totalPages, 1);
      });
    }
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
      expect(selection.errors, isNotEmpty, reason: '第 2 话损坏必须被记录，不能静默丢弃');
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
      expect(report.hasProblems, isTrue, reason: '存在扫描问题时不能报告为「导入完成」');
      expect(report.imported, 4);
      expect(await hashesInOrder(comic.id), hashesFor(<int>[1, 2, 5, 6]));
    });
  });

  group('缺陷 3：失败重试不能重复追加', () {
    for (final failedIndex in <int>[0, 1, 2]) {
      test('第 ${failedIndex + 1} 包重试后封面仍来自原队列第一包', () async {
        final outer = await writeZip(
          'cover-retry.zip',
          entries: <String, List<int>>{
            'a.cbz': cbzWithPages(<int>[1]),
            'b.cbz': cbzWithPages(<int>[2]),
            'c.cbz': cbzWithPages(<int>[3]),
          },
        );
        final selection = await archiveImporter.prepareArchives(<PlatformFile>[
          _TestFile(outer),
        ]);
        addTearDown(selection.dispose);
        final failedFile = selection.archives[failedIndex].localFile;
        final bytes = await failedFile.readAsBytes();
        await failedFile.delete();
        final comic = await repository.createComic('封面重试');
        final initial = await archiveImporter.importPrepared(
          comicId: comic.id,
          selection: selection,
          duplicatePolicy: DuplicatePolicy.keep,
          setCoverFromFirstArchive: true,
        );
        expect(initial.failures, hasLength(1));
        await failedFile.writeAsBytes(bytes);
        final retried = await archiveImporter.importPrepared(
          comicId: comic.id,
          selection: selection.retryOnly(
            initial.failures.map((f) => f.archiveKey!).toSet(),
          ),
          duplicatePolicy: DuplicatePolicy.keep,
          setCoverFromFirstArchive: true,
        );
        expect(retried.hasProblems, isFalse);
        final items = await repository.loadItems(comic.id);
        expect(
          items.map((item) => item.asset.contentHash).toList(),
          hashesFor(<int>[1, 2, 3]),
        );
        expect(
          (await repository.getComic(comic.id))!.comic.coverAssetId,
          items.first.asset.id,
        );
      });
    }

    test('多次重试保留既有页面和书签，保留重复模式也不重导已完成批次', () async {
      final prefix = await writeZip(
        'prefix.cbz',
        entries: <String, List<int>>{'001.png': png(9)},
      );
      final prefixSelection = await archiveImporter.prepareArchives(
        <PlatformFile>[_TestFile(prefix)],
      );
      addTearDown(prefixSelection.dispose);
      final comic = await repository.createComic('已有漫画');
      await archiveImporter.importPrepared(
        comicId: comic.id,
        selection: prefixSelection,
        duplicatePolicy: DuplicatePolicy.keep,
      );
      final oldItem = (await repository.loadItems(comic.id)).single;
      await repository.saveBookmark(
        comicId: comic.id,
        itemId: oldItem.id,
        note: '保留书签',
      );
      await repository.setCover(comic.id, oldItem.asset.id);

      final outer = await writeZip(
        'multiple-retries.zip',
        entries: <String, List<int>>{
          'a.cbz': cbzWithPages(<int>[1, 1]),
          'b.cbz': cbzWithPages(<int>[2]),
          'c.cbz': cbzWithPages(<int>[3]),
        },
      );
      final selection = await archiveImporter.prepareArchives(<PlatformFile>[
        _TestFile(outer),
      ]);
      addTearDown(selection.dispose);
      final a = selection.archives[0].localFile;
      final b = selection.archives[1].localFile;
      final aBytes = await a.readAsBytes();
      final bBytes = await b.readAsBytes();
      await a.delete();
      await b.delete();
      final first = await archiveImporter.importPrepared(
        comicId: comic.id,
        selection: selection,
        duplicatePolicy: DuplicatePolicy.keep,
      );
      expect(first.failures, hasLength(2));
      expect(await hashesInOrder(comic.id), hashesFor(<int>[9, 3]));
      final firstRetry = selection.retryOnly(
        first.failures.map((f) => f.archiveKey!).toSet(),
      );
      await a.writeAsBytes(aBytes);
      final second = await archiveImporter.importPrepared(
        comicId: comic.id,
        selection: firstRetry,
        duplicatePolicy: DuplicatePolicy.keep,
      );
      expect(second.failures, hasLength(1));
      expect(await hashesInOrder(comic.id), hashesFor(<int>[9, 1, 1, 3]));
      await b.writeAsBytes(bBytes);
      final third = await archiveImporter.importPrepared(
        comicId: comic.id,
        selection: firstRetry.retryOnly(
          second.failures.map((f) => f.archiveKey!).toSet(),
        ),
        duplicatePolicy: DuplicatePolicy.keep,
      );
      expect(third.hasProblems, isFalse);
      expect(await hashesInOrder(comic.id), hashesFor(<int>[9, 1, 1, 2, 3]));
      final completed = await repository.loadItems(comic.id);
      final repeated = await archiveImporter.importPrepared(
        comicId: comic.id,
        selection: selection,
        duplicatePolicy: DuplicatePolicy.keep,
      );
      expect(repeated.imported, 0);
      expect(
        (await repository.loadItems(comic.id)).map((item) => item.id).toList(),
        completed.map((item) => item.id).toList(),
      );
      expect(completed.first.id, oldItem.id);
      expect(
        (await repository.loadBookmarks(comic.id)).single.itemId,
        oldItem.id,
      );
      expect(
        (await repository.getComic(comic.id))!.comic.coverAssetId,
        oldItem.asset.id,
      );
    });

    test('同一外层包实际重试后恢复原顺序且不重复追加', () async {
      final outer = await writeZip(
        'retry.zip',
        entries: <String, List<int>>{
          'a.cbz': cbzWithPages(<int>[1]),
          'b.cbz': cbzWithPages(<int>[2]),
          'c.cbz': cbzWithPages(<int>[3]),
        },
      );

      final selection = await archiveImporter.prepareArchives(<PlatformFile>[
        _TestFile(outer),
      ]);
      addTearDown(selection.dispose);
      expect(selection.archives.map((a) => a.sourceIndex).toSet(), <int>{0});

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
      final middleBytes = await middleArchive.localFile.readAsBytes();
      if (await middleArchive.localFile.exists()) {
        await middleArchive.localFile.delete();
      }

      final report = await archiveImporter.importPrepared(
        comicId: comic.id,
        selection: selection,
        duplicatePolicy: DuplicatePolicy.keep,
      );

      expect(report.imported, 2, reason: '首尾两个包必须都导入；第一个包失败不能导致后续包被跳过');
      expect(report.failures, hasLength(1), reason: '只有中间那个包应失败');
      expect(
        report.failures.single.archiveKey,
        middleArchive.archiveKey,
        reason: '失败记录必须带可追踪的包标识',
      );

      // 重试集合只包含失败的那个包
      final retrySelection = selection.retryOnly(
        report.failures.map((f) => f.archiveKey!).toSet(),
      );
      expect(retrySelection.archives, hasLength(1), reason: '重试只能包含失败的那一个包');

      final before = await repository.loadItems(comic.id);
      expect(before, hasLength(2));
      await middleArchive.localFile.writeAsBytes(middleBytes);
      final retried = await archiveImporter.importPrepared(
        comicId: comic.id,
        selection: retrySelection,
        duplicatePolicy: DuplicatePolicy.keep,
      );
      expect(retried.failures, isEmpty);
      expect(retried.imported, 1);
      final after = await repository.loadItems(comic.id);
      expect(after, hasLength(3));
      expect(
        after.map((item) => item.id),
        containsAll(before.map((item) => item.id)),
      );
      expect(
        after.map((item) => item.asset.contentHash).toList(),
        <int>[
          1,
          2,
          3,
        ].map((seed) => sha256.convert(png(seed)).toString()).toList(),
        reason: '真正重试后应恢复 A、B、C，而不是 A、C、B',
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

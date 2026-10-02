import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:private_manga_reader/data/app_database.dart';
import 'package:private_manga_reader/data/network_repository.dart';
import 'package:private_manga_reader/models/entities.dart';
import 'package:private_manga_reader/services/local_mount_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  for (final modified in <int>[0, 123]) {
    test('挂载刷新：修改时间 $modified 的同 URI 漫画索引保持正确', () async {
      final sandbox = await Directory.systemTemp.createTemp('mount-refresh-');
      final database = AppDatabase(
        factory: databaseFactoryFfi,
        overridePath: p.join(sandbox.path, 'library.db'),
      );
      try {
        final repository = NetworkRepository(database);
        final platform = _DocumentsProvider(modified);
        final service = LocalMountService(repository, platform: platform);
        final source = await repository.createSource(
          name: '手机书库',
          type: NetworkSourceType.local,
          endpoint: 'content://provider/tree/books',
          rootPath: '',
          username: '',
        );
        final first = (await service.discoverAndSave(source)).single;
        expect(await service.prepareBook(first), hasLength(1));
        await repository.saveProgress(first.id, 0, 47);
        platform.pageCount = 2;
        final refreshed = (await service.discoverAndSave(source)).single;
        expect(refreshed.id, first.id);
        expect(refreshed.lastReadOffset, 47);
        final pages = await service.prepareBook(refreshed);
        // 已知、未变化的修订保留索引；未知修订不能误认成永久不变。
        expect(pages, hasLength(modified == 0 ? 2 : 1));
        expect(platform.indexReads, modified == 0 ? 2 : 1);
      } finally {
        await database.close();
        await sandbox.delete(recursive: true);
      }
    });
  }
}

class _DocumentsProvider implements LocalMountPlatform {
  _DocumentsProvider(this.modified);

  final int modified;
  int pageCount = 1;
  int indexReads = 0;

  @override
  Future<MountedDirectorySelection?> pickDirectory() async => null;

  @override
  Future<List<LocalMountDocument>> scanTree(String uri) async => [
    LocalMountDocument(
      uri: 'content://provider/book.cbz',
      name: 'book.cbz',
      mimeType: 'application/zip',
      size: 128,
      lastModified: modified,
      parentUri: uri,
      relativeDir: '',
    ),
  ];

  @override
  Future<List<LocalArchiveEntry>> listZipEntries(String uri) async {
    indexReads++;
    return List.generate(
      pageCount,
      (index) => LocalArchiveEntry(
        name: '${index + 1}.png',
        size: 64,
        width: 8,
        height: 12,
      ),
    );
  }

  @override
  Future<List<LocalMountDocument>> listImages(String uri) async => [];

  @override
  Future<Uint8List> readPage(String uri, {String? archiveEntry}) async =>
      Uint8List(0);
}

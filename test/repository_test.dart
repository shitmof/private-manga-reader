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
import 'package:private_manga_reader/data/network_repository.dart';
import 'package:private_manga_reader/models/entities.dart';
import 'package:private_manga_reader/services/backup_service.dart';
import 'package:private_manga_reader/services/archive_import_service.dart';
import 'package:private_manga_reader/services/import_service.dart';
import 'package:private_manga_reader/services/network_credential_store.dart';
import 'package:private_manga_reader/services/network_library_service.dart';
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
    final network = NetworkRepository(database);
    final networkSource = await network.createSource(
      name: '备份网络书库',
      type: NetworkSourceType.opds,
      endpoint: 'https://example.test/opds',
      rootPath: '',
      username: 'reader',
    );
    await network
        .upsertDiscoveredBooks(networkSource.id, const <RemoteBookDiscovery>[
          RemoteBookDiscovery(
            title: '远程漫画',
            remoteUri: 'https://example.test/book.cbz',
            mediaType: 'application/vnd.comicbook+zip',
            etag: 'remote-v1',
            byteSize: 99,
          ),
        ]);
    final remoteBook = (await network.loadBooks(networkSource.id)).single;
    await network.saveProgress(remoteBook.id, 8, 6.5);
    final backupService = BackupService(repository, storage);
    final backup = await backupService.createBackup();

    await repository.renameComic(comic.id, '被修改');
    await repository.removeItem(item.id);
    await network.deleteSource(networkSource.id);
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
    final restoredSources = await network.loadSources();
    expect(restoredSources.single.name, '备份网络书库');
    final restoredRemote = (await network.loadBooks(
      restoredSources.single.id,
    )).single;
    expect(restoredRemote.lastReadPosition, 8);
    expect(restoredRemote.lastReadOffset, 6.5);
    expect(restoredRemote.pageCount, 0, reason: '网络缓存不应进入完整备份');
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

  test('CBZ、CBR、CB7 与 CBT 真实容器都能识别并读取漫画页', () async {
    final archiveImporter = ArchiveImportService(repository, storage, importer);
    final fixtures = <String, String>{
      'synthetic_comic.cbz': 'zip',
      'synthetic_comic.cbr': 'rar',
      'synthetic_comic.cb7': '7z',
      'synthetic_comic.cbt': 'tar',
    };
    for (final fixture in fixtures.entries) {
      final file = File(
        p.join(
          Directory.current.path,
          'test',
          'fixtures',
          'archives',
          fixture.key,
        ),
      );
      final selection = await archiveImporter.prepareArchives(<PlatformFile>[
        _TestPlatformFile(file),
      ]);
      try {
        expect(selection.archives.single.format, fixture.value);
        expect(selection.totalPages, 3);
      } finally {
        await selection.dispose();
      }
    }
  });

  test('v3 网络书库只保存索引、缓存状态与本地阅读进度', () async {
    final network = NetworkRepository(database);
    final source = await network.createSource(
      name: '家庭 NAS',
      type: NetworkSourceType.webdav,
      endpoint: 'https://dav.example.test',
      rootPath: '/manga',
      username: 'reader',
    );
    await network.upsertDiscoveredBooks(source.id, <RemoteBookDiscovery>[
      const RemoteBookDiscovery(
        title: '第一卷',
        remoteUri: 'https://dav.example.test/manga/vol-1.cbz',
        mediaType: 'application/vnd.comicbook+zip',
        etag: 'v1',
        byteSize: 1234,
      ),
    ]);
    final books = await network.loadBooks(source.id);
    expect(books, hasLength(1));
    expect(books.single.lastReadPosition, 0);

    await network.replaceCachedPages(
      books.single.id,
      cachedVersion: 'v1',
      pages: <RemotePage>[
        const RemotePage(
          id: 'page-1',
          bookId: '',
          position: 0,
          relativePath: 'network-cache/book/page-0001.png',
          originalName: '001.png',
          byteSize: 321,
          width: 10,
          height: 20,
        ),
      ],
    );
    await network.saveProgress(books.single.id, 0, 42.5);
    final cached = await network.getBook(books.single.id);
    expect(cached?.pageCount, 1);
    expect(cached?.lastReadOffset, 42.5);
    expect(
      (await network.loadPages(books.single.id)).single.originalName,
      '001.png',
    );

    await network.clearCachedPages(books.single.id);
    final cleared = await network.getBook(books.single.id);
    expect(cleared?.pageCount, 0);
    expect(cleared?.lastReadOffset, 42.5, reason: '清缓存不得清阅读记录');
    expect(await network.loadPages(books.single.id), isEmpty);

    await network.deleteSource(source.id);
    expect(await network.loadSources(), isEmpty);
    expect(await network.loadBooks(source.id), isEmpty);
  });

  test('WebDAV 挂载可扫描远程 CBZ、按需缓存并保持页面顺序', () async {
    final archiveFile = await _createZip(
      sandbox,
      'remote.cbz',
      <String, List<int>>{
        '10.png': _pngBytes(10),
        '2.png': _pngBytes(2),
        '1.png': _pngBytes(1),
      },
    );
    final archiveBytes = await archiveFile.readAsBytes();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      if (request.method == 'PROPFIND') {
        request.response.statusCode = HttpStatus.multiStatus;
        request.response.headers.contentType = ContentType(
          'application',
          'xml',
        );
        request.response.write('''<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/manga/</d:href><d:propstat><d:prop>
    <d:resourcetype><d:collection/></d:resourcetype>
  </d:prop></d:propstat></d:response>
  <d:response><d:href>/manga/remote.cbz</d:href><d:propstat><d:prop>
    <d:getcontentlength>${archiveBytes.length}</d:getcontentlength>
    <d:getetag>"remote-v1"</d:getetag><d:resourcetype/>
  </d:prop></d:propstat></d:response>
</d:multistatus>''');
      } else if (request.method == 'GET' &&
          request.uri.path == '/manga/remote.cbz') {
        request.response.headers.contentType = ContentType.binary;
        request.response.add(archiveBytes);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final network = NetworkRepository(database);
    final source = await network.createSource(
      name: '测试 WebDAV',
      type: NetworkSourceType.webdav,
      endpoint: 'http://127.0.0.1:${server.port}',
      rootPath: '/manga',
      username: '',
    );
    final archiveImporter = ArchiveImportService(repository, storage, importer);
    final service = NetworkLibraryService(
      network,
      storage,
      archiveImporter,
      MemoryNetworkCredentialStore(),
    );
    addTearDown(service.dispose);

    final discovered = await service.discoverAndSave(source);
    expect(discovered, hasLength(1));
    expect(discovered.single.title, 'remote');
    final cached = await service.cacheBook(discovered.single.id);
    expect(cached.pageCount, 3);
    final pages = await network.loadPages(cached.id);
    expect(pages.map((page) => page.originalName), <String>[
      '1.png',
      '2.png',
      '10.png',
    ]);
    for (final page in pages) {
      expect(await File(storage.resolve(page.relativePath)).exists(), isTrue);
    }
  });

  test('OPDS 目录可识别漫画获取链接并使用数字自然排序', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      request.response.headers.contentType = ContentType(
        'application',
        'atom+xml',
        charset: 'utf-8',
      );
      request.response.write('''<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Library</title>
  <entry><title>Volume 10</title><updated>2026-08-29T00:00:00Z</updated>
    <link rel="http://opds-spec.org/acquisition" type="application/vnd.comicbook+zip" href="/books/10.cbz"/>
  </entry>
  <entry><title>Volume 2</title><updated>2026-08-28T00:00:00Z</updated>
    <link rel="http://opds-spec.org/acquisition" type="application/vnd.comicbook-rar" href="/books/2.cbr"/>
  </entry>
</feed>''');
      await request.response.close();
    });
    final network = NetworkRepository(database);
    final source = await network.createSource(
      name: '测试 OPDS',
      type: NetworkSourceType.opds,
      endpoint: 'http://127.0.0.1:${server.port}',
      rootPath: '',
      username: '',
    );
    final service = NetworkLibraryService(
      network,
      storage,
      ArchiveImportService(repository, storage, importer),
      MemoryNetworkCredentialStore(),
    );
    addTearDown(service.dispose);

    final books = await service.discoverAndSave(source);
    expect(books.map((book) => book.title), <String>['Volume 2', 'Volume 10']);
    expect(books.last.mediaType, 'application/vnd.comicbook+zip');
  });

  test('跨来源 OPDS 下载不会把书库账号密码发送给第三方主机', () async {
    final archiveFile = await _createZip(
      sandbox,
      'external.cbz',
      <String, List<int>>{'001.png': _pngBytes(1)},
    );
    final archiveBytes = await archiveFile.readAsBytes();
    String? externalAuthorization;
    final assetServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(assetServer.close);
    assetServer.listen((request) async {
      externalAuthorization = request.headers.value(
        HttpHeaders.authorizationHeader,
      );
      request.response.add(archiveBytes);
      await request.response.close();
    });

    final expectedBasic =
        'Basic ${base64Encode(utf8.encode('reader:private-password'))}';
    final catalogServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(catalogServer.close);
    catalogServer.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        expectedBasic,
      );
      request.response.headers.contentType = ContentType(
        'application',
        'atom+xml',
        charset: 'utf-8',
      );
      request.response.write('''<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Library</title>
  <entry><title>External</title><updated>2026-08-29T00:00:00Z</updated>
    <link rel="http://opds-spec.org/acquisition" type="application/vnd.comicbook+zip"
      href="http://127.0.0.1:${assetServer.port}/external.cbz"/>
  </entry>
</feed>''');
      await request.response.close();
    });

    final network = NetworkRepository(database);
    final source = await network.createSource(
      name: '带认证 OPDS',
      type: NetworkSourceType.opds,
      endpoint: 'http://127.0.0.1:${catalogServer.port}',
      rootPath: '',
      username: 'reader',
    );
    final credentialStore = MemoryNetworkCredentialStore();
    final service = NetworkLibraryService(
      network,
      storage,
      ArchiveImportService(repository, storage, importer),
      credentialStore,
    );
    addTearDown(service.dispose);
    await service.saveCredentials(
      source.id,
      const NetworkCredentials(
        username: 'reader',
        password: 'private-password',
      ),
    );

    final books = await service.discoverAndSave(source);
    await service.cacheBook(books.single.id);
    expect(externalAuthorization, isNull);
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

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../data/library_repository.dart';
import '../data/network_repository.dart';
import '../models/entities.dart';
import '../services/backup_service.dart';
import '../services/comic_export_service.dart';
import '../services/archive_import_service.dart';
import '../services/import_service.dart';
import '../services/incoming_archive_service.dart';
import '../services/local_mount_service.dart';
import '../services/network_library_service.dart';
import '../services/privacy_service.dart';
import '../services/storage_service.dart';

class OperationProgress {
  const OperationProgress({
    required this.title,
    required this.completed,
    required this.total,
    required this.detail,
  });

  final String title;
  final int completed;
  final int total;
  final String detail;

  double? get fraction => total == 0 ? null : completed / total;
}

class AppController extends ChangeNotifier {
  AppController(
    this._repository,
    this.storage,
    this._importer,
    this._archiveImporter,
    this._backup,
    this._networkRepository,
    this._networkLibrary, {
    PrivacyAuthenticator? privacyAuthenticator,
    this.incomingArchiveService,
    this.localMountService,
  }) : _privacyAuthenticator =
           privacyAuthenticator ?? DevicePrivacyAuthenticator();

  final LibraryRepository _repository;
  final ImportService _importer;
  final ArchiveImportService _archiveImporter;
  final BackupService _backup;
  final NetworkRepository _networkRepository;
  final NetworkLibraryService _networkLibrary;
  final PrivacyAuthenticator _privacyAuthenticator;
  final IncomingArchiveService? incomingArchiveService;
  final LocalMountService? localMountService;
  final StorageService storage;

  List<ComicSummary> library = const <ComicSummary>[];
  List<ShelfFolder> folders = const <ShelfFolder>[];
  List<ShelfEntry> shelfEntries = const <ShelfEntry>[];
  List<ReadingList> readingLists = const <ReadingList>[];
  List<NetworkSource> networkSources = const <NetworkSource>[];
  Map<String, List<RemoteBook>> networkBooks =
      const <String, List<RemoteBook>>{};
  ReaderPreferences preferences = const ReaderPreferences();
  OperationProgress? operation;

  Future<void> initialize() async {
    await incomingArchiveService?.initialize();
    incomingArchiveService?.addListener(_handleIncomingArchive);
    preferences = await _repository.loadPreferences();
    await _refreshLocalLibrary();
    await refreshNetworkLibrary(notify: false);
  }

  bool get hasIncomingArchives => incomingArchiveService?.hasPending ?? false;

  List<PlatformFile> takeIncomingArchives() =>
      incomingArchiveService?.takePending() ?? const <PlatformFile>[];

  void _handleIncomingArchive() => notifyListeners();

  Future<void> refresh() async {
    await _refreshLocalLibrary();
    notifyListeners();
  }

  Future<void> _refreshLocalLibrary() async {
    library = await _repository.loadLibrary();
    folders = await _repository.loadFolders();
    shelfEntries = await _repository.loadShelfEntries();
    readingLists = await _repository.loadReadingLists();
  }

  Future<void> refreshNetworkLibrary({bool notify = true}) async {
    networkSources = await _networkRepository.loadSources();
    final books = <String, List<RemoteBook>>{};
    for (final source in networkSources) {
      books[source.id] = await _networkRepository.loadBooks(source.id);
    }
    networkBooks = books;
    if (notify) notifyListeners();
  }

  List<RemoteBook> booksForSource(String sourceId) =>
      networkBooks[sourceId] ?? const <RemoteBook>[];

  RemoteBook? remoteBookFor(String bookId) {
    for (final books in networkBooks.values) {
      for (final book in books) {
        if (book.id == bookId) return book;
      }
    }
    return null;
  }

  Future<NetworkSource> addNetworkSource({
    required String name,
    required NetworkSourceType type,
    required String endpoint,
    required String rootPath,
    required NetworkCredentials credentials,
  }) async {
    final now = DateTime.now().toUtc();
    final probe = NetworkSource(
      id: 'connection-probe',
      name: name,
      type: type,
      endpoint: endpoint,
      rootPath: rootPath,
      username: credentials.username,
      createdAt: now,
      updatedAt: now,
    );
    operation = const OperationProgress(
      title: '正在连接网络书库',
      completed: 0,
      total: 0,
      detail: '校验地址与账号',
    );
    notifyListeners();
    try {
      await _networkLibrary.testConnection(probe, credentials);
      final source = await _networkRepository.createSource(
        name: name,
        type: type,
        endpoint: endpoint,
        rootPath: rootPath,
        username: credentials.username,
      );
      await _networkLibrary.saveCredentials(source.id, credentials);
      try {
        await _networkLibrary.discoverAndSave(source);
        await _networkRepository.recordSourceSuccess(source.id, synced: true);
      } catch (error) {
        // The mount remains saved if the first full scan fails; the user can
        // retry without re-entering credentials.
        await _recordNetworkFailure(source.id, error);
      }
      await refreshNetworkLibrary(notify: false);
      return source;
    } finally {
      operation = null;
      notifyListeners();
    }
  }

  Future<NetworkSource?> mountLocalDirectory() async {
    final service = localMountService;
    if (service == null) throw UnsupportedError('当前平台不支持原地挂载');
    final selection = await service.pickDirectory();
    if (selection == null) return null;
    operation = const OperationProgress(
      title: '正在挂载本地漫画',
      completed: 0,
      total: 0,
      detail: '只建立索引，不复制原图',
    );
    notifyListeners();
    try {
      final source = await _networkRepository.createSource(
        name: selection.name,
        type: NetworkSourceType.local,
        endpoint: selection.uri,
        rootPath: selection.name,
        username: '',
      );
      try {
        await service.discoverAndSave(source);
        await _networkRepository.recordSourceSuccess(source.id, synced: true);
      } catch (error) {
        await _recordNetworkFailure(source.id, error);
      }
      await refreshNetworkLibrary(notify: false);
      return source;
    } finally {
      operation = null;
      notifyListeners();
    }
  }

  Future<void> scanNetworkSource(NetworkSource source) async {
    operation = const OperationProgress(
      title: '正在同步网络书库',
      completed: 0,
      total: 0,
      detail: '只读扫描远程目录',
    );
    notifyListeners();
    try {
      if (source.type == NetworkSourceType.local) {
        final service = localMountService;
        if (service == null) throw UnsupportedError('当前平台不支持原地挂载');
        await service.discoverAndSave(source);
      } else {
        await _networkLibrary.discoverAndSave(source);
      }
      await _networkRepository.recordSourceSuccess(source.id, synced: true);
      await refreshNetworkLibrary(notify: false);
    } catch (error) {
      await _recordNetworkFailure(source.id, error);
      await refreshNetworkLibrary(notify: false);
      rethrow;
    } finally {
      operation = null;
      notifyListeners();
    }
  }

  Future<void> reauthenticateNetworkSource(
    NetworkSource source,
    NetworkCredentials credentials,
  ) async {
    operation = const OperationProgress(
      title: '正在验证新凭据',
      completed: 0,
      total: 0,
      detail: '凭据只保存在系统安全存储',
    );
    notifyListeners();
    try {
      final updated = NetworkSource(
        id: source.id,
        name: source.name,
        type: source.type,
        endpoint: source.endpoint,
        rootPath: source.rootPath,
        username: credentials.username,
        createdAt: source.createdAt,
        updatedAt: DateTime.now().toUtc(),
        connectionState: source.connectionState,
        lastSuccessAt: source.lastSuccessAt,
        lastSyncAt: source.lastSyncAt,
        lastError: source.lastError,
      );
      await _networkLibrary.testConnection(updated, credentials);
      await _networkRepository.updateSource(updated);
      await _networkLibrary.saveCredentials(source.id, credentials);
      await _networkLibrary.discoverAndSave(updated);
      await _networkRepository.recordSourceSuccess(source.id, synced: true);
      await refreshNetworkLibrary(notify: false);
    } catch (error) {
      await _recordNetworkFailure(source.id, error);
      await refreshNetworkLibrary(notify: false);
      rethrow;
    } finally {
      operation = null;
      notifyListeners();
    }
  }

  Future<void> relinkLocalSource(NetworkSource source) async {
    final service = localMountService;
    if (service == null || source.type != NetworkSourceType.local) {
      throw UnsupportedError('当前条目不支持重新授权');
    }
    final selection = await service.pickDirectory();
    if (selection == null) return;
    operation = const OperationProgress(
      title: '正在重新关联本地目录',
      completed: 0,
      total: 0,
      detail: '保留原有阅读进度与书签',
    );
    notifyListeners();
    try {
      final updated = NetworkSource(
        id: source.id,
        name: selection.name,
        type: NetworkSourceType.local,
        endpoint: selection.uri,
        rootPath: selection.name,
        username: '',
        createdAt: source.createdAt,
        updatedAt: DateTime.now().toUtc(),
        connectionState: NetworkConnectionState.unknown,
      );
      await _networkRepository.updateSource(updated);
      await service.discoverAndSave(updated);
      await _networkRepository.recordSourceSuccess(source.id, synced: true);
      await refreshNetworkLibrary(notify: false);
    } catch (error) {
      await _recordNetworkFailure(source.id, error);
      await refreshNetworkLibrary(notify: false);
      rethrow;
    } finally {
      operation = null;
      notifyListeners();
    }
  }

  Future<List<RemotePage>> prepareRemoteBook(String bookId) async {
    final book = remoteBookFor(bookId);
    final sourceId = book?.sourceId;
    final source = sourceId == null
        ? null
        : networkSources.where((item) => item.id == sourceId).firstOrNull;
    operation = const OperationProgress(
      title: '正在准备网络漫画',
      completed: 0,
      total: 0,
      detail: '按需读取，原程保持只读',
    );
    notifyListeners();
    try {
      if (source?.type == NetworkSourceType.local) {
        final service = localMountService;
        if (service == null || book == null) {
          throw UnsupportedError('当前平台不支持原地挂载');
        }
        operation = const OperationProgress(
          title: '正在准备本地漫画',
          completed: 0,
          total: 0,
          detail: '读取页面索引，不解压到私有目录',
        );
        notifyListeners();
        await service.prepareBook(book);
      } else {
        await _networkLibrary.cacheBook(
          bookId,
          onProgress: (completed, total, detail) {
            operation = OperationProgress(
              title: '正在准备网络漫画',
              completed: completed,
              total: total,
              detail: detail,
            );
            notifyListeners();
          },
        );
      }
      if (sourceId != null) {
        await _networkRepository.recordSourceSuccess(sourceId, synced: false);
      }
      await refreshNetworkLibrary(notify: false);
      return _networkRepository.loadPages(bookId);
    } catch (error) {
      if (sourceId != null) {
        await _recordNetworkFailure(sourceId, error);
        await refreshNetworkLibrary(notify: false);
      }
      rethrow;
    } finally {
      operation = null;
      notifyListeners();
    }
  }

  Future<List<RemotePage>> loadRemotePages(String bookId) =>
      _networkRepository.loadPages(bookId);

  Future<Uint8List> loadExternalPage(RemotePage page) {
    final service = localMountService;
    if (service == null) throw UnsupportedError('当前平台不支持原地挂载');
    return service.readPage(page);
  }

  Future<void> saveRemoteProgress(
    String bookId,
    int position,
    double offset,
  ) async {
    if (!preferences.rememberProgress) return;
    await _networkRepository.saveProgress(bookId, position, offset);
    final current = remoteBookFor(bookId);
    if (current != null) {
      await refreshNetworkLibrary();
    }
  }

  Future<void> clearRemoteBookCache(String bookId) async {
    await _networkLibrary.clearBookCache(bookId);
    await refreshNetworkLibrary();
  }

  Future<void> removeNetworkSource(String sourceId) async {
    await _networkLibrary.removeSource(sourceId);
    await refreshNetworkLibrary();
  }

  Future<int> networkCacheBytes() => storage.networkCacheBytes();

  Future<void> _recordNetworkFailure(String sourceId, Object error) =>
      _networkRepository.recordSourceFailure(
        sourceId,
        state: _networkStateFor(error),
        error: _networkErrorMessage(error),
      );

  NetworkConnectionState _networkStateFor(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('401') ||
        message.contains('403') ||
        message.contains('auth') ||
        message.contains('凭据') ||
        message.contains('密码') ||
        message.contains('未授权')) {
      return NetworkConnectionState.needsAuthentication;
    }
    if (error is SocketException ||
        message.contains('offline') ||
        message.contains('网络不可用')) {
      return NetworkConnectionState.offline;
    }
    return NetworkConnectionState.unreachable;
  }

  String _networkErrorMessage(Object error) => error
      .toString()
      .replaceFirst('FormatException: ', '')
      .replaceFirst('Bad state: ', '')
      .replaceFirst('FileSystemException: ', '')
      .trim();

  ComicSummary? summaryFor(String comicId) {
    for (final summary in library) {
      if (summary.comic.id == comicId) return summary;
    }
    return null;
  }

  String filePath(String relativePath) => storage.resolve(relativePath);

  Future<Comic> createComic(String title) async {
    final comic = await _repository.createComic(title);
    await refresh();
    return comic;
  }

  Future<void> renameComic(String comicId, String title) async {
    await _repository.renameComic(comicId, title);
    await refresh();
  }

  Future<ShelfFolder> createFolder(String name) async {
    final folder = await _repository.createFolder(name);
    await refresh();
    return folder;
  }

  Future<ShelfFolder> createShelfGroupFromComics({
    required String sourceComicId,
    required String targetComicId,
    required String name,
  }) async {
    final folder = await _repository.createShelfGroupFromComics(
      sourceComicId: sourceComicId,
      targetComicId: targetComicId,
      name: name,
    );
    await refresh();
    return folder;
  }

  Future<void> renameFolder(String folderId, String name) async {
    await _repository.renameFolder(folderId, name);
    await refresh();
  }

  Future<void> deleteFolder(String folderId) async {
    await _repository.deleteFolder(folderId);
    await refresh();
  }

  Future<void> setFolderPrivate(String folderId, bool value) async {
    await _repository.setFolderPrivate(folderId, value);
    await refresh();
  }

  Future<void> moveComicsToFolder(
    Iterable<String> comicIds,
    String? folderId,
  ) async {
    await _repository.moveComicsToFolder(comicIds.toList(), folderId);
    await refresh();
  }

  Future<void> setComicsPrivate(Iterable<String> comicIds, bool value) async {
    for (final comicId in comicIds) {
      await _repository.setComicPrivate(comicId, value);
    }
    await refresh();
  }

  Future<bool> unlockPrivateShelf() =>
      _privacyAuthenticator.authenticate(reason: '验证身份以打开私密书架');

  Future<void> setComicsPinned(Iterable<String> comicIds, bool value) async {
    for (final comicId in comicIds) {
      await _repository.setComicPinned(comicId, value);
    }
    await refresh();
  }

  Future<ReadingList> createReadingList(String name) async {
    final list = await _repository.createReadingList(name);
    await refresh();
    return list;
  }

  Future<void> addComicsToReadingList(
    String listId,
    Iterable<String> comicIds,
  ) async {
    await _repository.addComicsToReadingList(listId, comicIds.toList());
    await refresh();
  }

  Future<List<String>> loadReadingListComicIds(String listId) =>
      _repository.loadReadingListComicIds(listId);

  Future<void> deleteReadingList(String listId) async {
    await _repository.deleteReadingList(listId);
    await refresh();
  }

  Future<List<PageBookmark>> loadBookmarks(String comicId) =>
      _repository.loadBookmarks(comicId);

  Future<PageBookmark> saveBookmark({
    required String comicId,
    required String itemId,
    String note = '',
  }) => _repository.saveBookmark(comicId: comicId, itemId: itemId, note: note);

  Future<void> deleteBookmark(String bookmarkId) =>
      _repository.deleteBookmark(bookmarkId);

  Future<void> deleteComic(String comicId) async {
    await _repository.deleteComic(comicId);
    await refresh();
  }

  Future<List<ComicSummary>> loadDeletedComics() =>
      _repository.loadDeletedComics();

  Future<void> restoreComic(String comicId) async {
    await _repository.restoreComic(comicId);
    await refresh();
  }

  Future<void> permanentlyDeleteComic(String comicId) async {
    await _repository.permanentlyDeleteComic(comicId);
    await deleteOrphanedAssets();
  }

  Future<List<ComicItemRecord>> loadItems(String comicId) =>
      _repository.loadItems(comicId);

  Future<List<PlatformFile>> pickImages({required bool fromGallery}) =>
      fromGallery ? _importer.pickFromGallery() : _importer.pickFromFiles();

  Future<int> estimateBytes(List<PlatformFile> files) =>
      _importer.estimateBytes(files);

  Future<List<PlatformFile>> pickArchives() => _archiveImporter.pickArchives();

  Future<PreparedArchiveSelection> prepareArchives(
    List<PlatformFile> files,
  ) async {
    operation = OperationProgress(
      title: '正在检查漫画压缩包',
      completed: 0,
      total: files.length,
      detail: '识别格式与页面顺序',
    );
    notifyListeners();
    try {
      return await _archiveImporter.prepareArchives(files);
    } finally {
      operation = null;
      notifyListeners();
    }
  }

  Future<ImportReport> importArchives({
    required String comicId,
    required PreparedArchiveSelection selection,
    required DuplicatePolicy duplicatePolicy,
    bool setCoverFromFirstArchive = false,
  }) async {
    operation = OperationProgress(
      title: '正在解压并导入',
      completed: 0,
      total: selection.totalPages,
      detail: '准备中',
    );
    notifyListeners();
    try {
      final report = await _archiveImporter.importPrepared(
        comicId: comicId,
        selection: selection,
        duplicatePolicy: duplicatePolicy,
        setCoverFromFirstArchive: setCoverFromFirstArchive,
        onProgress: (completed, total, name) {
          operation = OperationProgress(
            title: '正在解压并导入',
            completed: completed,
            total: total,
            detail: name,
          );
          notifyListeners();
        },
      );
      await refresh();
      return report;
    } finally {
      operation = null;
      notifyListeners();
    }
  }

  Future<int?> freeBytes() => storage.freeBytes();

  Future<ImportReport> importFiles({
    required String comicId,
    required List<PlatformFile> files,
    required DuplicatePolicy duplicatePolicy,
  }) async {
    operation = OperationProgress(
      title: '正在导入原图',
      completed: 0,
      total: files.length,
      detail: '准备中',
    );
    notifyListeners();
    try {
      final report = await _importer.importFiles(
        comicId: comicId,
        files: files,
        duplicatePolicy: duplicatePolicy,
        onProgress: (completed, total, name) {
          operation = OperationProgress(
            title: '正在导入原图',
            completed: completed,
            total: total,
            detail: name,
          );
          notifyListeners();
        },
      );
      await refresh();
      return report;
    } finally {
      operation = null;
      notifyListeners();
    }
  }

  Future<void> applyItemEdits({
    required String comicId,
    required List<String> orderedItemIds,
    required List<String> removedItemIds,
    String? coverAssetId,
  }) async {
    await _repository.applyItemEdits(
      comicId: comicId,
      orderedItemIds: orderedItemIds,
      removedItemIds: removedItemIds,
      coverAssetId: coverAssetId,
    );
    await refresh();
  }

  Future<void> reorderComics(int from, int to) async {
    final ids = library.map((entry) => entry.comic.id).toList();
    final item = ids.removeAt(from);
    ids.insert(to, item);
    await _repository.reorderComics(ids);
    await refresh();
  }

  Future<void> reorderShelfEntries(
    String scope,
    List<String> orderedKeys,
  ) async {
    await _repository.reorderShelfEntries(scope, orderedKeys);
    await refresh();
  }

  Future<void> saveProgress(String comicId, int position, double offset) async {
    if (!preferences.rememberProgress) return;
    await _repository.saveProgress(comicId, position, offset);
  }

  Future<void> updatePreferences(ReaderPreferences value) async {
    preferences = value;
    notifyListeners();
    await _repository.savePreferences(value);
  }

  Future<LibraryStats> loadStats() async =>
      _repository.loadStats(thumbnailBytes: await storage.thumbnailBytes());

  Future<void> clearThumbnails() async {
    operation = const OperationProgress(
      title: '正在清理缓存',
      completed: 0,
      total: 0,
      detail: '不会删除原图',
    );
    notifyListeners();
    try {
      await storage.clearThumbnails();
    } finally {
      operation = null;
      notifyListeners();
    }
  }

  Future<void> rebuildThumbnails() async {
    operation = const OperationProgress(
      title: '正在重建缩略图',
      completed: 0,
      total: 0,
      detail: '准备中',
    );
    notifyListeners();
    try {
      await _importer.rebuildThumbnails(
        onProgress: (completed, total, detail) {
          operation = OperationProgress(
            title: '正在重建缩略图',
            completed: completed,
            total: total,
            detail: detail,
          );
          notifyListeners();
        },
      );
      await refresh();
    } finally {
      operation = null;
      notifyListeners();
    }
  }

  Future<int> deleteOrphanedAssets() async {
    final assets = await _repository.orphanedAssets();
    for (final asset in assets) {
      final original = File(filePath(asset.storedPath));
      final thumbnail = File(filePath(asset.thumbnailPath));
      if (await original.exists()) await original.delete();
      if (await thumbnail.exists()) await thumbnail.delete();
    }
    await _repository.deleteOrphanRecords(
      assets.map((asset) => asset.id).toList(growable: false),
    );
    await refresh();
    return assets.length;
  }

  Future<(File, Uri?)> createAndExportBackup() async {
    operation = const OperationProgress(
      title: '正在创建完整备份',
      completed: 0,
      total: 0,
      detail: '原图保持原始字节',
    );
    notifyListeners();
    try {
      final file = await _backup.createBackup();
      operation = null;
      notifyListeners();
      final destination = await _backup.saveBackupExternally(file);
      return (file, destination);
    } finally {
      operation = null;
      notifyListeners();
    }
  }

  Future<PlatformFile?> pickBackup() => _backup.pickBackup();

  Future<File> restoreBackup(PlatformFile source) async {
    operation = const OperationProgress(
      title: '正在校验并恢复',
      completed: 0,
      total: 0,
      detail: '恢复前会自动建立安全备份',
    );
    notifyListeners();
    try {
      final safetyBackup = await _backup.restoreBackup(source);
      preferences = await _repository.loadPreferences();
      await refresh();
      return safetyBackup;
    } finally {
      operation = null;
      notifyListeners();
    }
  }

  Future<ComicExportResult> createComicExport(String comicId) async {
    operation = const OperationProgress(
      title: '正在生成 CBZ',
      completed: 0,
      total: 0,
      detail: '保留编辑后顺序和原图字节',
    );
    notifyListeners();
    try {
      return await ComicExportService(_repository, storage).createCbz(comicId);
    } finally {
      operation = null;
      notifyListeners();
    }
  }

  Future<Uri?> saveComicExport(ComicExportResult export) =>
      ComicExportService(_repository, storage).saveExternally(export);

  Future<void> shareComicExport(ComicExportResult export) =>
      ComicExportService(_repository, storage).share(export);
}

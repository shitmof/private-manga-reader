import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../data/library_repository.dart';
import '../models/entities.dart';
import '../services/backup_service.dart';
import '../services/import_service.dart';
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
    this._backup,
  );

  final LibraryRepository _repository;
  final ImportService _importer;
  final BackupService _backup;
  final StorageService storage;

  List<ComicSummary> library = const <ComicSummary>[];
  ReaderPreferences preferences = const ReaderPreferences();
  OperationProgress? operation;

  Future<void> initialize() async {
    preferences = await _repository.loadPreferences();
    library = await _repository.loadLibrary();
  }

  Future<void> refresh() async {
    library = await _repository.loadLibrary();
    notifyListeners();
  }

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
      fromGallery
          ? _importer.pickFromGallery()
          : _importer.pickFromFiles();

  Future<int> estimateBytes(List<PlatformFile> files) =>
      _importer.estimateBytes(files);

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

  Future<void> saveProgress(
    String comicId,
    int position,
    double offset,
  ) async {
    if (!preferences.rememberProgress) return;
    await _repository.saveProgress(comicId, position, offset);
  }

  Future<void> updatePreferences(ReaderPreferences value) async {
    preferences = value;
    notifyListeners();
    await _repository.savePreferences(value);
  }

  Future<LibraryStats> loadStats() async => _repository.loadStats(
        thumbnailBytes: await storage.thumbnailBytes(),
      );

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

  Future<File> createAndShareBackup() async {
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
      await _backup.shareBackup(file);
      return file;
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
}

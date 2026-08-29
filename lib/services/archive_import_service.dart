import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:koni_archive/io.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

import '../data/library_repository.dart';
import '../models/entities.dart';
import 'import_service.dart';
import 'storage_service.dart';

/// Reads common comic archives without changing their source files.
///
/// Selected archives are copied to the app's temporary directory first so
/// Android content URIs work exactly like ordinary files. Pages are then
/// decoded one at a time and handed to [ImportService], preserving its hash,
/// original-byte and duplicate guarantees.
class ArchiveImportService {
  ArchiveImportService(this._repository, this._storage, this._importer);

  static const supportedExtensions = <String>[
    'cbz',
    'zip',
    'cbr',
    'rar',
    'cb7',
    '7z',
    'cbt',
    'tar',
  ];
  static const _imageExtensions = <String>{
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
    'heic',
    'heif',
  };
  static const _maxEntries = 10000;
  static const _maxEntryBytes = 512 * 1024 * 1024;
  static const _maxContainerBytes = 2 * 1024 * 1024 * 1024;
  static const _maxTotalDecodedBytes = 20 * 1024 * 1024 * 1024;
  static const _maxComicInfoBytes = 2 * 1024 * 1024;
  static const _uuid = Uuid();

  final LibraryRepository _repository;
  final StorageService _storage;
  final ImportService _importer;

  Future<List<PlatformFile>> pickArchives() => FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: supportedExtensions,
    dialogTitle: '选择漫画压缩包',
  );

  Future<PreparedArchiveSelection> prepareArchives(
    List<PlatformFile> sources,
  ) async {
    if (sources.isEmpty) {
      return const PreparedArchiveSelection(<PreparedArchive>[]);
    }
    await _storage.temporaryDirectory.create(recursive: true);
    final prepared = <PreparedArchive>[];
    try {
      for (var index = 0; index < sources.length; index++) {
        final source = sources[index];
        final localFile = await _copyToTemporary(source);
        Archive? archive;
        try {
          archive = await _open(localFile.path);
          if (archive.entries.any((entry) => entry.pathEscapedRoot)) {
            throw const FormatException('压缩包包含越界路径，已拒绝导入');
          }
          final archiveImages = archive.entries
              .where((entry) => entry.isFile && _isImagePath(entry.path))
              .where((entry) => !_isIgnoredPath(entry.path))
              .toList(growable: false);
          if (archiveImages.isEmpty) {
            throw const FormatException('压缩包中没有可导入的图片');
          }
          if (archiveImages.any((entry) => entry.isEncrypted)) {
            throw const FormatException('压缩包已加密，请先解除密码后导入');
          }
          final decodedBytes = archiveImages.fold<int>(
            0,
            (total, entry) => total + entry.uncompressedSize,
          );
          if (decodedBytes > _maxTotalDecodedBytes) {
            throw const FormatException('解压后数据过大，已停止导入');
          }

          final metadata = await _readComicInfo(archive, archiveImages);
          final ordered = _orderImages(archiveImages, metadata.pageIndices);
          final coverPath = metadata.coverArchiveIndex == null
              ? null
              : archiveImages
                    .elementAtOrNull(metadata.coverArchiveIndex!)
                    ?.path;
          prepared.add(
            PreparedArchive(
              sourceIndex: index,
              displayName: source.name,
              localFile: localFile,
              format: archive.format.name,
              title: metadata.title ?? _titleFromName(source.name),
              pages: ordered
                  .map(
                    (entry) => PreparedArchivePage(
                      path: entry.path,
                      uncompressedBytes: entry.uncompressedSize,
                    ),
                  )
                  .toList(growable: false),
              coverPageIndex: coverPath == null
                  ? 0
                  : ordered.indexWhere((entry) => entry.path == coverPath),
              decodedBytes: decodedBytes,
            ),
          );
        } catch (error) {
          if (await localFile.exists()) await localFile.delete();
          throw FormatException(
            '${source.name}：${_friendlyArchiveError(error)}',
          );
        } finally {
          await archive?.close();
        }
      }
      return PreparedArchiveSelection(prepared);
    } catch (_) {
      for (final archive in prepared) {
        if (await archive.localFile.exists()) await archive.localFile.delete();
      }
      rethrow;
    }
  }

  Future<ImportReport> importPrepared({
    required String comicId,
    required PreparedArchiveSelection selection,
    required DuplicatePolicy duplicatePolicy,
    bool setCoverFromFirstArchive = false,
    ImportProgress? onProgress,
  }) async {
    var imported = 0;
    var skipped = 0;
    var completed = 0;
    final failures = <ImportFailure>[];
    final startingItemCount = await _repository.itemCount(comicId);
    var firstArchiveCompleted = false;

    for (
      var archiveIndex = 0;
      archiveIndex < selection.archives.length;
      archiveIndex++
    ) {
      final prepared = selection.archives[archiveIndex];
      final beforeItems = await _repository.loadItems(comicId);
      final beforeIds = beforeItems.map((item) => item.id).toSet();
      var importedThisArchive = 0;
      var skippedThisArchive = 0;
      Archive? archive;
      try {
        archive = await _open(prepared.localFile.path);
        for (final page in prepared.pages) {
          onProgress?.call(completed, selection.totalPages, page.path);
          final entry = archive.entry(page.path);
          if (entry == null || !entry.isFile) {
            throw _ArchivePageException(
              '${prepared.displayName}/${page.path}',
              '压缩包页面索引已变化',
            );
          }
          final extracted = await _extractPage(archive, entry);
          try {
            final report = await _importer.importFiles(
              comicId: comicId,
              files: <PlatformFile>[
                _DiskPlatformFile(extracted, p.posix.basename(page.path)),
              ],
              duplicatePolicy: duplicatePolicy,
            );
            imported += report.imported;
            skipped += report.skippedDuplicates;
            importedThisArchive += report.imported;
            skippedThisArchive += report.skippedDuplicates;
            completed++;
            if (report.failures.isNotEmpty) {
              throw _ArchivePageException(
                '${prepared.displayName}/${page.path}',
                report.failures.first.reason,
              );
            }
          } finally {
            if (await extracted.exists()) await extracted.delete();
          }
        }
        if (archiveIndex == 0) firstArchiveCompleted = true;
      } catch (error) {
        await _rollbackArchive(comicId, beforeIds);
        imported -= importedThisArchive;
        skipped -= skippedThisArchive;
        final pageError = error is _ArchivePageException ? error : null;
        failures.add(
          ImportFailure(
            pageError?.fileName ?? prepared.displayName,
            pageError?.reason ?? _friendlyArchiveError(error),
            prepared.sourceIndex,
          ),
        );
        break;
      } finally {
        await archive?.close();
      }
    }

    if (setCoverFromFirstArchive && firstArchiveCompleted && imported > 0) {
      final first = selection.archives.first;
      final coverIndex = first.coverPageIndex.clamp(0, first.pages.length - 1);
      final items = await _repository.loadItems(comicId);
      final itemIndex = startingItemCount + coverIndex;
      if (duplicatePolicy == DuplicatePolicy.keep && itemIndex < items.length) {
        await _repository.setCover(comicId, items[itemIndex].asset.id);
      }
    }
    onProgress?.call(completed, selection.totalPages, '完成');
    return ImportReport(
      imported: imported,
      skippedDuplicates: skipped,
      failures: failures,
    );
  }

  Future<List<ExtractedArchivePage>> extractPreparedToDirectory({
    required PreparedArchive archive,
    required Directory target,
    ImportProgress? onProgress,
  }) async {
    if (await target.exists()) {
      throw const FileSystemException('缓存目标目录已存在');
    }
    await target.create(recursive: true);
    Archive? opened;
    final extracted = <ExtractedArchivePage>[];
    try {
      opened = await _open(archive.localFile.path);
      for (var index = 0; index < archive.pages.length; index++) {
        final page = archive.pages[index];
        onProgress?.call(index, archive.pages.length, page.path);
        final entry = opened.entry(page.path);
        if (entry == null || !entry.isFile) {
          throw FormatException('压缩包页面索引已变化：${page.path}');
        }
        final extension = p.posix.extension(page.path).toLowerCase();
        final file = File(
          p.join(target.path, '${index.toString().padLeft(6, '0')}$extension'),
        );
        final sink = file.openWrite();
        try {
          await for (final chunk in opened.openRead(entry)) {
            sink.add(chunk);
          }
          await sink.close();
        } catch (_) {
          await sink.close();
          rethrow;
        }
        final decoded = await img.decodeImageFile(file.path);
        extracted.add(
          ExtractedArchivePage(
            file: file,
            originalName: p.posix.basename(page.path),
            byteSize: await file.length(),
            width: decoded?.width ?? 0,
            height: decoded?.height ?? 0,
          ),
        );
      }
      onProgress?.call(archive.pages.length, archive.pages.length, '完成');
      return extracted;
    } catch (_) {
      if (await target.exists()) await target.delete(recursive: true);
      rethrow;
    } finally {
      await opened?.close();
    }
  }

  Future<Archive> _open(String path) => openArchiveFile(
    path,
    options: const ArchiveReadOptions(
      maxEntryCount: _maxEntries,
      maxEntrySize: _maxEntryBytes,
      maxContainerDecodeSize: _maxContainerBytes,
    ),
  );

  Future<File> _copyToTemporary(PlatformFile source) async {
    final extension = p.extension(source.name).toLowerCase();
    final target = File(
      p.join(
        _storage.temporaryDirectory.path,
        'archive-${_uuid.v4()}${RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(extension) ? extension : '.bin'}',
      ),
    );
    final sink = target.openWrite();
    try {
      await for (final chunk in source.readAsByteStream()) {
        sink.add(chunk);
      }
      await sink.close();
      return target;
    } catch (_) {
      await sink.close();
      if (await target.exists()) await target.delete();
      rethrow;
    }
  }

  Future<File> _extractPage(Archive archive, ArchiveEntry entry) async {
    final extension = p.posix.extension(entry.path).toLowerCase();
    final target = File(
      p.join(_storage.temporaryDirectory.path, 'page-${_uuid.v4()}$extension'),
    );
    final sink = target.openWrite();
    try {
      await for (final chunk in archive.openRead(entry)) {
        sink.add(chunk);
      }
      await sink.close();
      return target;
    } catch (_) {
      await sink.close();
      if (await target.exists()) await target.delete();
      rethrow;
    }
  }

  Future<void> _rollbackArchive(
    String comicId,
    Set<String> beforeItemIds,
  ) async {
    final current = await _repository.loadItems(comicId);
    final added = current
        .where((item) => !beforeItemIds.contains(item.id))
        .toList(growable: false);
    final candidateAssetIds = added.map((item) => item.asset.id).toSet();
    for (final item in added) {
      await _repository.removeItem(item.id);
    }
    final newOrphans = (await _repository.orphanedAssets())
        .where((asset) => candidateAssetIds.contains(asset.id))
        .toList(growable: false);
    for (final asset in newOrphans) {
      final original = File(_storage.resolve(asset.storedPath));
      final thumbnail = File(_storage.resolve(asset.thumbnailPath));
      if (await original.exists()) await original.delete();
      if (await thumbnail.exists()) await thumbnail.delete();
    }
    await _repository.deleteOrphanRecords(
      newOrphans.map((asset) => asset.id).toList(growable: false),
    );
  }

  Future<_ComicInfo> _readComicInfo(
    Archive archive,
    List<ArchiveEntry> images,
  ) async {
    ArchiveEntry? metadataEntry;
    for (final entry in archive.entries) {
      if (entry.isFile &&
          p.posix.basename(entry.path).toLowerCase() == 'comicinfo.xml') {
        metadataEntry = entry;
        break;
      }
    }
    if (metadataEntry == null ||
        metadataEntry.uncompressedSize > _maxComicInfoBytes ||
        metadataEntry.isEncrypted) {
      return const _ComicInfo();
    }
    try {
      final bytes = await archive.readBytes(
        metadataEntry,
        maxSize: _maxComicInfoBytes,
      );
      final document = XmlDocument.parse(
        utf8.decode(bytes, allowMalformed: true),
      );
      final titleElement = document.findAllElements('Title').firstOrNull;
      final title = titleElement?.innerText.trim();
      final pages = document.findAllElements('Page').toList(growable: false);
      final indices = <int>[];
      int? coverArchiveIndex;
      for (final page in pages) {
        final index = int.tryParse(page.getAttribute('Image') ?? '');
        if (index == null || index < 0 || index >= images.length) continue;
        if (!indices.contains(index)) indices.add(index);
        final type = page.getAttribute('Type')?.toLowerCase();
        if (coverArchiveIndex == null && type == 'frontcover') {
          coverArchiveIndex = index;
        }
      }
      return _ComicInfo(
        title: title == null || title.isEmpty ? null : title,
        pageIndices: indices,
        coverArchiveIndex: coverArchiveIndex,
      );
    } catch (_) {
      // Broken optional metadata must never make otherwise valid pages unreadable.
      return const _ComicInfo();
    }
  }

  List<ArchiveEntry> _orderImages(
    List<ArchiveEntry> images,
    List<int> metadataOrder,
  ) {
    if (metadataOrder.isEmpty) {
      return images.toList()..sort((a, b) => _naturalCompare(a.path, b.path));
    }
    final used = metadataOrder.toSet();
    final ordered = <ArchiveEntry>[
      for (final index in metadataOrder) images[index],
    ];
    final remaining = <ArchiveEntry>[
      for (var index = 0; index < images.length; index++)
        if (!used.contains(index)) images[index],
    ]..sort((a, b) => _naturalCompare(a.path, b.path));
    return <ArchiveEntry>[...ordered, ...remaining];
  }

  static bool _isImagePath(String path) {
    final extension = p.posix
        .extension(path)
        .replaceFirst('.', '')
        .toLowerCase();
    return _imageExtensions.contains(extension);
  }

  static bool _isIgnoredPath(String path) {
    final segments = path.split('/');
    return segments.any((segment) => segment == '__MACOSX') ||
        segments.any((segment) => segment.startsWith('.')) ||
        p.posix.basename(path).toLowerCase() == 'thumbs.db';
  }

  static int _naturalCompare(String left, String right) {
    final leftParts = RegExp(
      r'\d+|\D+',
    ).allMatches(left.toLowerCase()).map((m) => m[0]!).toList();
    final rightParts = RegExp(
      r'\d+|\D+',
    ).allMatches(right.toLowerCase()).map((m) => m[0]!).toList();
    final length = leftParts.length < rightParts.length
        ? leftParts.length
        : rightParts.length;
    for (var index = 0; index < length; index++) {
      final a = leftParts[index];
      final b = rightParts[index];
      final aNumber = RegExp(r'^\d+$').hasMatch(a);
      final bNumber = RegExp(r'^\d+$').hasMatch(b);
      int comparison;
      if (aNumber && bNumber) {
        final normalizedA = a.replaceFirst(RegExp(r'^0+(?=\d)'), '');
        final normalizedB = b.replaceFirst(RegExp(r'^0+(?=\d)'), '');
        comparison = normalizedA.length.compareTo(normalizedB.length);
        if (comparison == 0) comparison = normalizedA.compareTo(normalizedB);
        if (comparison == 0) comparison = a.length.compareTo(b.length);
      } else {
        comparison = a.compareTo(b);
      }
      if (comparison != 0) return comparison;
    }
    return leftParts.length.compareTo(rightParts.length);
  }

  static String _titleFromName(String name) {
    final stem = p.basenameWithoutExtension(name).trim();
    return stem.isEmpty ? '未命名漫画' : stem;
  }

  static String _friendlyArchiveError(Object error) {
    if (error is FormatException) return error.message.toString();
    if (error is EncryptedArchiveException ||
        error is InvalidPasswordException) {
      return '压缩包已加密，请先解除密码后导入';
    }
    if (error is SizeLimitExceededException) {
      return '压缩包超出安全限制，已停止导入';
    }
    if (error is UnsupportedFormatException) return '不支持或文件已损坏';
    if (error is ArchiveException) return '压缩包损坏或采用了不支持的压缩方式';
    if (error is FileSystemException) return error.message;
    return '无法读取此漫画压缩包';
  }
}

class PreparedArchiveSelection {
  const PreparedArchiveSelection(this.archives);

  final List<PreparedArchive> archives;

  int get totalPages =>
      archives.fold(0, (total, item) => total + item.pages.length);

  int get decodedBytes =>
      archives.fold(0, (total, item) => total + item.decodedBytes);

  String get suggestedTitle =>
      archives.isEmpty ? '未命名漫画' : archives.first.title;

  Future<void> dispose() async {
    for (final archive in archives) {
      if (await archive.localFile.exists()) await archive.localFile.delete();
    }
  }
}

class PreparedArchive {
  const PreparedArchive({
    required this.sourceIndex,
    required this.displayName,
    required this.localFile,
    required this.format,
    required this.title,
    required this.pages,
    required this.coverPageIndex,
    required this.decodedBytes,
  });

  final int sourceIndex;
  final String displayName;
  final File localFile;
  final String format;
  final String title;
  final List<PreparedArchivePage> pages;
  final int coverPageIndex;
  final int decodedBytes;
}

class PreparedArchivePage {
  const PreparedArchivePage({
    required this.path,
    required this.uncompressedBytes,
  });

  final String path;
  final int uncompressedBytes;
}

class ExtractedArchivePage {
  const ExtractedArchivePage({
    required this.file,
    required this.originalName,
    required this.byteSize,
    required this.width,
    required this.height,
  });

  final File file;
  final String originalName;
  final int byteSize;
  final int width;
  final int height;
}

class _ComicInfo {
  const _ComicInfo({
    this.title,
    this.pageIndices = const <int>[],
    this.coverArchiveIndex,
  });

  final String? title;
  final List<int> pageIndices;
  final int? coverArchiveIndex;
}

class _ArchivePageException implements Exception {
  const _ArchivePageException(this.fileName, this.reason);

  final String fileName;
  final String reason;
}

final class _DiskPlatformFile extends PlatformFile {
  _DiskPlatformFile(this.file, this.displayName);

  final File file;
  final String displayName;

  @override
  String get name => displayName;

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

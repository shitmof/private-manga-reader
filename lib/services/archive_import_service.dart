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

  /// 内层压缩包扩展名。
  ///
  /// 用户常见做法是把多话漫画打成一个外层 zip，里面每话一个 cbz。
  /// 原先只扫描直接条目里的图片，遇到这种包会直接判定「没有可导入的图片」。
  static const _nestedArchiveExtensions = <String>{
    'cbz',
    'zip',
    'cbr',
    'rar',
    'cb7',
    '7z',
    'cbt',
    'tar',
  };

  /// 内层压缩包最多展开到第几层（顶层记为第 1 层）。
  ///
  /// 设上限是为了防止构造出的自引用或超深压缩包导致无限展开。
  static const _maxNestedDepth = 3;

  /// 单次导入允许展开的内层压缩包总数上限。
  static const _maxNestedArchives = 500;

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
    final errors = <String>[];
    final allTemporaryFiles = <String, File>{};
    try {
      for (var index = 0; index < sources.length; index++) {
        final source = sources[index];
        final localFile = await _copyToTemporary(source);
        Archive? archive;
        final ownedFiles = <File>[localFile];
        Object? failure;
        try {
          archive = await _open(localFile.path);
          final outcome = await _scanArchive(
            archive: archive,
            file: localFile,
            displayName: source.name,
            sourceIndex: index,
            depth: 1,
            ownedFiles: ownedFiles,
            overflowErrors: errors,
          );
          prepared.addAll(outcome.archives);
          // 统一登记本次产生的所有临时文件。
          //
          // 注意：不能把外层文件也挂到每本内层漫画的 ownedFiles 上。
          // 外层临时文件是所有内层包共用的 localFile，
          // 一旦某本漫画先完成导入并 dispose，就会把共用文件删掉，
          // 导致后续漫画打开时失败（实测报 “Cannot open file”）。
          // 因此清理只在 selection 层统一进行。
          for (final file in ownedFiles) {
            allTemporaryFiles.putIfAbsent(file.path, () => file);
          }
        } catch (error) {
          failure = error;
        } finally {
          await archive?.close();
        }
        if (failure != null) {
          // 必须等归档关闭后再删临时文件：Windows 上被占用的文件删不掉，
          // 在 catch 里直接删会抛 PathAccessException 并掩盖真正的失败原因。
          for (final file in ownedFiles) {
            try {
              if (await file.exists()) await file.delete();
            } on FileSystemException {
              // 清理失败不应掩盖导入失败本身。
            }
          }
          throw FormatException(
            '${source.name}：${_friendlyArchiveError(failure)}',
          );
        }
      }
      return PreparedArchiveSelection(
        prepared,
        errors: errors,
        temporaryFiles: allTemporaryFiles.values.toList(growable: false),
      );
    } catch (_) {
      for (final file in allTemporaryFiles.values) {
        try {
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          // 清理失败不应掩盖导入失败本身。
        }
      }
      rethrow;
    }
  }

  /// 判断某个条目是否是内层压缩包。
  static bool _isNestedArchivePath(String path) {
    final extension = p.posix
        .extension(path)
        .replaceFirst('.', '')
        .toLowerCase();
    return _nestedArchiveExtensions.contains(extension);
  }

  /// 扫描一个已打开的压缩包。
  ///
  /// 若它直接包含图片，就产出一本漫画；若只包含内层压缩包，
  /// 就把每个内层包解出来递归扫描（用户常见的「外层 zip 套多话 cbz」）。
  /// [ownedFiles] 收集本次扫描过程中产生的所有临时文件，供失败时统一清理。
  Future<_ScanOutcome> _scanArchive({
    required Archive archive,
    required File file,
    required String displayName,
    required int sourceIndex,
    required int depth,
    required List<File> ownedFiles,
    required List<String> overflowErrors,
  }) async {
    if (archive.entries.any((entry) => entry.pathEscapedRoot)) {
      throw const FormatException('压缩包包含越界路径，已拒绝导入');
    }

    final archiveImages = archive.entries
        .where((entry) => entry.isFile && _isImagePath(entry.path))
        .where((entry) => !_isIgnoredPath(entry.path))
        .toList(growable: false);

    if (archiveImages.isNotEmpty) {
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
      return _ScanOutcome(<PreparedArchive>[
        PreparedArchive(
          sourceIndex: sourceIndex,
          displayName: displayName,
          localFile: file,
          format: archive.format.name,
          title: metadata.title ?? _titleFromName(displayName),
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
      ]);
    }

    // 没有直接图片：尝试把内层压缩包解出来继续扫。
    final nested = archive.entries
        .where((entry) => entry.isFile && _isNestedArchivePath(entry.path))
        .where((entry) => !_isIgnoredPath(entry.path))
        .toList(growable: false);
    if (nested.isEmpty) {
      // 既没有图片也没有内层压缩包，才算真正的空包；
      // 不再像原先那样「只扫最外层就宣布整个压缩包无内容」。
      throw const FormatException('压缩包中没有可导入的图片，也没有内层压缩包');
    }
    if (depth >= _maxNestedDepth) {
      throw FormatException('内层压缩包嵌套超过 $_maxNestedDepth 层，已停止导入');
    }

    final results = <PreparedArchive>[];
    for (final entry in nested) {
      if (results.length >= _maxNestedArchives) {
        overflowErrors.add(
          '${p.posix.basename(entry.path)}：内层压缩包数量超过 $_maxNestedArchives，已跳过',
        );
        break;
      }
      final nestedFile = await _extractNestedArchive(archive, entry);
      ownedFiles.add(nestedFile);
      Archive? nestedArchive;
      try {
        nestedArchive = await _open(nestedFile.path);
        final outcome = await _scanArchive(
          archive: nestedArchive,
          file: nestedFile,
          displayName: p.posix.basename(entry.path),
          sourceIndex: sourceIndex,
          depth: depth + 1,
          ownedFiles: ownedFiles,
          overflowErrors: overflowErrors,
        );
        results.addAll(outcome.archives);
      } catch (error) {
        // 单个内层包失败不影响其余内层包，失败原因一并上报。
        overflowErrors.add(
          '${p.posix.basename(entry.path)}：${_friendlyArchiveError(error)}',
        );
      } finally {
        await nestedArchive?.close();
      }
    }
    if (results.isEmpty) {
      throw FormatException(
        overflowErrors.isEmpty ? '压缩包中没有可导入的图片' : overflowErrors.join('；'),
      );
    }
    return _ScanOutcome(results);
  }

  /// 把内层压缩包以流式方式解到临时文件。
  ///
  /// 刻意逐块写入而不是一次性读入内存：内层包可能有数百 MB，
  /// 而 KonI 打开压缩包需要可随机读取的文件源。
  Future<File> _extractNestedArchive(Archive archive, ArchiveEntry entry) async {
    final extension = p.posix.extension(entry.path).toLowerCase();
    final target = File(
      p.join(
        _storage.temporaryDirectory.path,
        'nested-${_uuid.v4()}${RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(extension) ? extension : '.bin'}',
      ),
    );
    final sink = target.openWrite();
    var written = 0;
    try {
      await for (final chunk in archive.openRead(entry)) {
        written += chunk.length;
        if (written > _maxEntryBytes) {
          throw const FormatException('内层压缩包过大，已停止导入');
        }
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return target;
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
  const PreparedArchiveSelection(
    this.archives, {
    this.errors = const <String>[],
    this.temporaryFiles = const <File>[],
  });

  final List<PreparedArchive> archives;

  /// 部分内层压缩包未能导入的原因，逐项上报而不是只显示「失败」。
  final List<String> errors;

  /// 本次准备过程产生的全部临时文件。
  ///
  /// 清理只在这里统一进行：内层包共用的外层临时文件不能挂在单本漫画上，
  /// 否则某本先完成导入就会把共用文件删掉，导致后续漫画打不开。
  final List<File> temporaryFiles;

  int get totalPages =>
      archives.fold(0, (total, item) => total + item.pages.length);

  int get decodedBytes =>
      archives.fold(0, (total, item) => total + item.decodedBytes);

  String get suggestedTitle =>
      archives.isEmpty ? '未命名漫画' : archives.first.title;

  Future<void> dispose() async {
    for (final file in temporaryFiles) {
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // 个别文件仍被占用时跳过，不影响其余清理。
      }
    }
  }
}

class PreparedArchive {
  PreparedArchive({
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

  /// 本漫画对应的压缩包文件。内层包情况下指向解出来的临时文件。
  final File localFile;
  final String format;
  final String title;
  final List<PreparedArchivePage> pages;
  final int coverPageIndex;
  final int decodedBytes;
}

/// 一次压缩包扫描的结果：要么产出一本漫画，要么产出多个内层包对应的漫画。
class _ScanOutcome {
  const _ScanOutcome(this.archives);

  final List<PreparedArchive> archives;
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

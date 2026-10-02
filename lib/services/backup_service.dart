import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../data/library_repository.dart';
import '../models/entities.dart';
import 'storage_service.dart';

class BackupService {
  BackupService(this._repository, this._storage);

  static const _uuid = Uuid();
  final LibraryRepository _repository;
  final StorageService _storage;
  static const MethodChannel _documentsChannel = MethodChannel(
    'private_manga_reader/documents',
  );

  Future<File> createBackup({String prefix = 'shihuage'}) async {
    final stamp = _timestamp(DateTime.now());
    final backup = File(
      p.join(
        _storage.backupsDirectory.path,
        '$prefix-$stamp-${_uuid.v4()}.mangabackup',
      ),
    );
    final partial = File('${backup.path}.partial');
    OutputFileStream? output;
    FileHandle? outputHandle;
    try {
      final manifest = await _repository.exportManifest();
      final manifestBytes = utf8.encode(_repository.encodeManifest(manifest));
      final assets = await _repository.allAssets();
      var originalBytes = 0;
      for (final asset in assets) {
        _validateAssetPaths(asset);
        final source = File(_storage.resolve(asset.storedPath));
        if (!await source.exists()) {
          throw FileSystemException('原图缺失，已停止备份', asset.originalFileName);
        }
        originalBytes += await source.length();
      }
      // 原图直接流入 ZIP，临时空间只需一份备份及目录开销。
      await _ensureSpace(
        originalBytes + manifestBytes.length + (assets.length + 1) * 1024,
      );
      final handle = FileHandle(partial.path, mode: FileAccess.write);
      outputHandle = handle;
      final writer = OutputFileStream.withFileHandle(handle);
      output = writer;
      final encoder = ZipFileEncoder()..createWithStream(writer);
      encoder.addArchiveFile(
        ArchiveFile('manifest.json', manifestBytes.length, manifestBytes)
          ..compression = CompressionType.none,
      );
      for (final asset in assets) {
        final source = File(_storage.resolve(asset.storedPath));
        final input = InputFileStream(source.path);
        try {
          final entry = ArchiveFile.stream(
            asset.storedPath.replaceAll('\\', '/'),
            input,
          )..compression = CompressionType.none;
          encoder.addArchiveFile(entry);
        } finally {
          await input.close();
        }
      }
      await encoder.close();
      await partial.rename(backup.path);
      return backup;
    } catch (error, stack) {
      // 只在完整 ZIP 关闭后发布文件名；失败残片不能成为可选的恢复点。
      try {
        await output?.close();
      } catch (_) {}
      // 磁盘写满时 close 的 flush 也可能失败，直接关底层句柄才能删残片。
      try {
        await outputHandle?.close();
      } catch (_) {}
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> shareBackup(File backup) async {
    await SharePlus.instance.share(
      ShareParams(
        title: '导出拾画阁备份',
        text: '拾画阁完整本地备份',
        files: <XFile>[XFile(backup.path, mimeType: 'application/zip')],
      ),
    );
  }

  /// 通过系统文档选择器写出，可选手机、SD 卡或云盘。
  /// 文件不再位于 App 私有目录，卸载后仍然保留。
  Future<Uri?> saveBackupExternally(File backup) async {
    final fileName = p.basename(backup.path);
    if (Platform.isAndroid) {
      final uri = await _documentsChannel.invokeMethod<String>(
        'saveFile',
        <String, Object?>{'sourcePath': backup.path, 'fileName': fileName},
      );
      return uri == null ? null : Uri.parse(uri);
    }
    return FilePicker.saveFile(
      fileName: fileName,
      bytes: await backup.readAsBytes(),
      mimeType: 'application/zip',
      dialogTitle: '保存完整备份',
      type: FileType.custom,
      allowedExtensions: const <String>['mangabackup'],
    );
  }

  Future<PlatformFile?> pickBackup() => FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: const <String>['mangabackup', 'zip'],
    dialogTitle: '选择拾画阁备份',
  );

  Future<File> restoreBackup(PlatformFile source) async {
    final restoreRoot = Directory(
      p.join(_storage.temporaryDirectory.path, 'restore-${_uuid.v4()}'),
    );
    await restoreRoot.create(recursive: true);
    final archiveFile = File(p.join(restoreRoot.path, 'source.mangabackup'));
    final extractedRoot = Directory(p.join(restoreRoot.path, 'contents'));
    final newlyInstalled = <File>[];
    final pendingCopies = <File>[];
    var manifestApplied = false;
    Object? restoreError;
    try {
      await _ensureSpace(await source.length());
      final output = archiveFile.openWrite();
      try {
        await output.addStream(source.readAsByteStream());
      } catch (error, stack) {
        // 读取或落盘失败后也必须关句柄；关闭异常不能盖掉原始错误。
        try {
          await output.close();
        } catch (_) {}
        Error.throwWithStackTrace(error, stack);
      }
      await output.close();
      final input = InputFileStream(archiveFile.path);
      final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input, verify: true);
        _validateArchiveEntries(archive);
        var extractedBytes = 0;
        for (final entry in archive) {
          if (entry.size < 0) throw const FormatException('备份文件尺寸无效');
          if (entry.isFile) extractedBytes += entry.size;
        }
        await _ensureSpace(extractedBytes);
        await extractArchiveToDisk(archive, extractedRoot.path);
      } finally {
        await input.close();
      }
      final manifestFile = File(p.join(extractedRoot.path, 'manifest.json'));
      if (!await manifestFile.exists()) {
        throw const FormatException('备份中缺少 manifest.json');
      }
      final decoded = jsonDecode(await manifestFile.readAsString());
      if (decoded is! Map) throw const FormatException('备份清单无效');
      final manifest = decoded.map<String, Object?>(
        (key, value) => MapEntry(key.toString(), value),
      );
      if (manifest['format'] != 'private-manga-reader-backup' ||
          (manifest['version'] != 1 &&
              manifest['version'] != 2 &&
              manifest['version'] != 3 &&
              manifest['version'] != 4)) {
        throw const FormatException('不支持的备份版本');
      }
      final assets = _assetRows(manifest['assets']);
      for (final asset in assets) {
        _validateAssetPaths(asset);
        final extracted = File(p.join(extractedRoot.path, asset.storedPath));
        if (!await extracted.exists()) {
          throw FormatException('备份原图缺失：${asset.originalFileName}');
        }
        final hash = (await sha256.bind(extracted.openRead()).first).toString();
        if (hash != asset.contentHash) {
          throw FormatException('备份原图校验失败：${asset.originalFileName}');
        }
        // 旧版会直接跳过同名文件，导致数据库恢复成功但实际仍读取损坏原图。
        // 在备份或更改任何现存数据前拒绝冲突，不静默覆盖用户文件。
        final existing = File(_storage.resolve(asset.storedPath));
        if (await existing.exists()) {
          final existingHash = (await sha256.bind(existing.openRead()).first)
              .toString();
          if (existingHash != asset.contentHash) {
            throw FormatException(
              '本地原图与备份存在内容冲突，已停止恢复且未覆盖数据：${asset.originalFileName}',
            );
          }
        }
      }

      var restoreWriteBytes = 0;
      for (final currentAsset in await _repository.allAssets()) {
        final current = File(_storage.resolve(currentAsset.storedPath));
        if (await current.exists()) restoreWriteBytes += await current.length();
      }
      for (final asset in assets) {
        if (!await File(_storage.resolve(asset.storedPath)).exists()) {
          restoreWriteBytes += await File(
            p.join(extractedRoot.path, asset.storedPath),
          ).length();
        }
      }
      // 在写安全备份前同时预留安全备份和新增原图，避免写到一半才发现不足。
      await _ensureSpace(restoreWriteBytes + (assets.length + 1) * 1024);
      final safetyBackup = await createBackup(prefix: 'recovery-pre-restore');
      for (final asset in assets) {
        final sourceFile = File(p.join(extractedRoot.path, asset.storedPath));
        final target = File(_storage.resolve(asset.storedPath));
        await target.parent.create(recursive: true);
        if (!await target.exists()) {
          final temporary = File('${target.path}.restore-${_uuid.v4()}');
          pendingCopies.add(temporary);
          await sourceFile.copy(temporary.path);
          await temporary.rename(target.path);
          newlyInstalled.add(target);
        }
      }
      await _repository.replaceFromManifest(manifest);
      manifestApplied = true;
      if (manifest['version'] == 2 || manifest['version'] == 3) {
        if (await _storage.networkCacheDirectory.exists()) {
          await _storage.networkCacheDirectory.delete(recursive: true);
        }
        await _storage.networkCacheDirectory.create(recursive: true);
      }
      return safetyBackup;
    } catch (error, stack) {
      restoreError = error;
      // 数据库事务拒绝清单或复制失败时，只回收本次新建的文件。
      // 已经成功替换书库后，清缓存失败也不能删除已恢复的原图。
      final failedFiles = <File>[
        ...pendingCopies,
        if (!manifestApplied) ...newlyInstalled,
      ];
      for (final file in failedFiles) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      try {
        if (await restoreRoot.exists()) {
          await restoreRoot.delete(recursive: true);
        }
      } catch (_) {
        if (restoreError == null) rethrow;
      }
    }
  }

  List<AssetRecord> _assetRows(Object? value) {
    if (value is! List) throw const FormatException('备份缺少原图清单');
    return value
        .map((row) {
          if (row is! Map) throw const FormatException('原图清单结构错误');
          return AssetRecord.fromMap(
            row.map((key, value) => MapEntry(key.toString(), value)),
          );
        })
        .toList(growable: false);
  }

  Future<void> _ensureSpace(int requiredBytes) async {
    const reserveBytes = 16 * 1024 * 1024;
    final available = await _storage.freeBytes();
    if (available != null && available < requiredBytes + reserveBytes) {
      throw const FileSystemException('手机存储空间不足，已停止操作且保留原有书库');
    }
  }

  void _validateAssetPaths(AssetRecord asset) {
    final original = _safeRelativePath(asset.storedPath);
    final thumbnail = _safeRelativePath(asset.thumbnailPath);
    if (!original.startsWith('assets/') ||
        !thumbnail.startsWith('thumbnails/')) {
      throw const FormatException('备份图片路径不在规定的存储目录内');
    }
  }

  void _validateArchiveEntries(Archive archive) {
    final paths = <String>{};
    for (final entry in archive) {
      if (entry.isSymbolicLink) {
        throw const FormatException('备份不允许包含符号链接');
      }
      final name = entry.isDirectory
          ? entry.name.replaceFirst(RegExp(r'[/\\]+$'), '')
          : entry.name;
      final path = _safeRelativePath(name);
      if (!paths.add(path.toLowerCase())) {
        throw const FormatException('备份包含重复的文件路径');
      }
    }
  }

  String _safeRelativePath(String value) {
    final normalized = value.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        normalized.contains(':') ||
        normalized.contains('\u0000') ||
        segments.any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        )) {
      throw const FormatException('备份包含不安全的文件路径');
    }
    return normalized;
  }

  String _timestamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}-'
        '${two(time.hour)}${two(time.minute)}${two(time.second)}';
  }
}

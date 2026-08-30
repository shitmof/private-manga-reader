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
    final staging = Directory(
      p.join(_storage.temporaryDirectory.path, 'backup-${_uuid.v4()}'),
    );
    await staging.create(recursive: true);
    try {
      final manifest = await _repository.exportManifest();
      final manifestFile = File(p.join(staging.path, 'manifest.json'));
      await manifestFile.writeAsString(
        _repository.encodeManifest(manifest),
        flush: true,
      );
      final assets = await _repository.allAssets();
      for (final asset in assets) {
        final source = File(_storage.resolve(asset.storedPath));
        if (!await source.exists()) {
          throw FileSystemException('原图缺失，已停止备份', asset.originalFileName);
        }
        final target = File(p.join(staging.path, asset.storedPath));
        await target.parent.create(recursive: true);
        await source.copy(target.path);
      }
      final backup = File(
        p.join(_storage.backupsDirectory.path, '$prefix-$stamp.mangabackup'),
      );
      await ZipFileEncoder().zipDirectory(
        staging,
        filename: backup.path,
        level: ZipFileEncoder.store,
      );
      return backup;
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
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
    try {
      final output = archiveFile.openWrite();
      await for (final chunk in source.readAsByteStream()) {
        output.add(chunk);
      }
      await output.close();
      final input = InputFileStream(archiveFile.path);
      final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input, verify: true);
        await extractArchiveToDisk(archive, restoreRoot.path);
      } finally {
        await input.close();
      }
      final manifestFile = File(p.join(restoreRoot.path, 'manifest.json'));
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
              manifest['version'] != 3)) {
        throw const FormatException('不支持的备份版本');
      }
      final assets = _assetRows(manifest['assets']);
      for (final asset in assets) {
        final extracted = File(p.join(restoreRoot.path, asset.storedPath));
        if (!await extracted.exists()) {
          throw FormatException('备份原图缺失：${asset.originalFileName}');
        }
        final hash = (await sha256.bind(extracted.openRead()).first).toString();
        if (hash != asset.contentHash) {
          throw FormatException('备份原图校验失败：${asset.originalFileName}');
        }
      }

      final safetyBackup = await createBackup(prefix: 'recovery-pre-restore');
      for (final asset in assets) {
        final sourceFile = File(p.join(restoreRoot.path, asset.storedPath));
        final target = File(_storage.resolve(asset.storedPath));
        await target.parent.create(recursive: true);
        if (!await target.exists()) {
          final temporary = File('${target.path}.restore-${_uuid.v4()}');
          await sourceFile.copy(temporary.path);
          await temporary.rename(target.path);
        }
      }
      await _repository.replaceFromManifest(manifest);
      if (manifest['version'] == 2 || manifest['version'] == 3) {
        if (await _storage.networkCacheDirectory.exists()) {
          await _storage.networkCacheDirectory.delete(recursive: true);
        }
        await _storage.networkCacheDirectory.create(recursive: true);
      }
      return safetyBackup;
    } finally {
      if (await restoreRoot.exists()) await restoreRoot.delete(recursive: true);
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

  String _timestamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}-'
        '${two(time.hour)}${two(time.minute)}${two(time.second)}';
  }
}

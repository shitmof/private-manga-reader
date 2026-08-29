import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../data/library_repository.dart';
import '../models/entities.dart';
import 'storage_service.dart';

typedef ImportProgress = void Function(int completed, int total, String name);

class ImportService {
  ImportService(this._repository, this._storage);

  static const _uuid = Uuid();
  static const _extensions = <String>[
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
    'heic',
    'heif',
  ];

  final LibraryRepository _repository;
  final StorageService _storage;

  Future<List<PlatformFile>> pickFromGallery() =>
      FilePicker.pickFiles(type: FileType.image, dialogTitle: '从相册选择图片');

  Future<List<PlatformFile>> pickFromFiles() => FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: _extensions,
    dialogTitle: '从文件选择图片',
  );

  Future<int> estimateBytes(List<PlatformFile> files) async {
    var total = 0;
    for (final file in files) {
      total += await file.length();
    }
    return total;
  }

  Future<ImportReport> importFiles({
    required String comicId,
    required List<PlatformFile> files,
    required DuplicatePolicy duplicatePolicy,
    ImportProgress? onProgress,
  }) async {
    var imported = 0;
    var skipped = 0;
    final failures = <ImportFailure>[];
    var remaining =
        LibraryRepository.maxItemsPerComic -
        await _repository.itemCount(comicId);

    for (var index = 0; index < files.length; index++) {
      final source = files[index];
      onProgress?.call(index, files.length, source.name);
      if (remaining <= 0) {
        failures.add(ImportFailure(source.name, '已达到单本 1000 张上限', index));
        continue;
      }
      File? temporary;
      var createdPhysicalAsset = false;
      AssetRecord? createdAsset;
      try {
        final copied = await _copyToTemporary(source);
        temporary = copied.file;
        final existing = await _repository.findAssetByHash(copied.hash);
        if (existing != null) {
          final alreadyUsed = await _repository.comicContainsAsset(
            comicId,
            existing.id,
          );
          if (alreadyUsed && duplicatePolicy == DuplicatePolicy.skip) {
            skipped++;
            await temporary.delete();
            continue;
          }
          final existingFile = File(_storage.resolve(existing.storedPath));
          if (!await existingFile.exists()) {
            await existingFile.parent.create(recursive: true);
            await temporary.rename(existingFile.path);
          } else {
            await temporary.delete();
          }
          await _repository.attachAsset(comicId: comicId, asset: existing);
          imported++;
          remaining--;
          continue;
        }

        final extension = _safeExtension(source.extension);
        final stored = File(
          p.join(_storage.assetsDirectory.path, '${copied.hash}.$extension'),
        );
        if (await stored.exists()) {
          await temporary.delete();
        } else {
          await temporary.rename(stored.path);
          createdPhysicalAsset = true;
        }
        final verifiedHash = await _hashFile(stored);
        if (verifiedHash != copied.hash) {
          throw const FileSystemException('复制后哈希校验失败');
        }
        final dimensions = await _createThumbnail(stored, copied.hash);
        final thumbnailPath = p.join('thumbnails', '${copied.hash}.jpg');
        createdAsset = AssetRecord(
          id: _uuid.v4(),
          contentHash: copied.hash,
          originalFileName: source.name,
          mimeType: lookupMimeType(source.name) ?? 'application/octet-stream',
          extension: extension,
          byteSize: await stored.length(),
          width: dimensions.$1,
          height: dimensions.$2,
          storedPath: _storage.relative(stored.path),
          thumbnailPath: thumbnailPath.replaceAll('\\', '/'),
          createdAt: DateTime.now().toUtc(),
        );
        await _repository.attachAsset(comicId: comicId, asset: createdAsset);
        imported++;
        remaining--;
      } catch (error) {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
        if (createdPhysicalAsset && createdAsset != null) {
          final original = File(_storage.resolve(createdAsset.storedPath));
          final thumbnail = File(_storage.resolve(createdAsset.thumbnailPath));
          if (await original.exists()) await original.delete();
          if (await thumbnail.exists()) await thumbnail.delete();
        }
        failures.add(ImportFailure(source.name, _friendlyError(error), index));
      }
    }
    onProgress?.call(files.length, files.length, '完成');
    return ImportReport(
      imported: imported,
      skippedDuplicates: skipped,
      failures: failures,
    );
  }

  Future<void> rebuildThumbnails({ImportProgress? onProgress}) async {
    final assets = await _repository.allAssets();
    for (var index = 0; index < assets.length; index++) {
      final asset = assets[index];
      onProgress?.call(index, assets.length, asset.originalFileName);
      final original = File(_storage.resolve(asset.storedPath));
      if (await original.exists()) {
        await _createThumbnail(original, asset.contentHash);
      }
    }
    onProgress?.call(assets.length, assets.length, '完成');
  }

  Future<_CopiedFile> _copyToTemporary(PlatformFile source) async {
    await _storage.temporaryDirectory.create(recursive: true);
    final temporary = File(
      p.join(_storage.temporaryDirectory.path, 'import-${_uuid.v4()}.part'),
    );
    final sink = temporary.openWrite();
    final digestSink = _DigestSink();
    final converter = sha256.startChunkedConversion(digestSink);
    try {
      await for (final Uint8List chunk in source.readAsByteStream()) {
        converter.add(chunk);
        sink.add(chunk);
      }
      converter.close();
      await sink.close();
    } catch (_) {
      converter.close();
      await sink.close();
      rethrow;
    }
    final digest = digestSink.value;
    if (digest == null) throw const FileSystemException('无法计算文件哈希');
    return _CopiedFile(temporary, digest.toString());
  }

  Future<String> _hashFile(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<(int, int)> _createThumbnail(File original, String hash) async {
    final decoded = await img.decodeImageFile(original.path);
    if (decoded == null) return (0, 0);
    final width = decoded.width;
    final height = decoded.height;
    final thumbnail = width > 512
        ? img.copyResize(
            decoded,
            width: 512,
            interpolation: img.Interpolation.average,
          )
        : decoded;
    final target = File(p.join(_storage.thumbnailsDirectory.path, '$hash.jpg'));
    await target.writeAsBytes(
      img.encodeJpg(thumbnail, quality: 82),
      flush: true,
    );
    return (width, height);
  }

  String _safeExtension(String? extension) {
    final normalized = (extension ?? 'img').toLowerCase();
    return RegExp(r'^[a-z0-9]{1,8}$').hasMatch(normalized) ? normalized : 'img';
  }

  String _friendlyError(Object error) {
    if (error is StateError) return error.message.toString();
    if (error is FileSystemException) return error.message;
    return '无法导入此文件';
  }
}

class _CopiedFile {
  const _CopiedFile(this.file, this.hash);
  final File file;
  final String hash;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

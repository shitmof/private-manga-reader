import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../data/library_repository.dart';
import 'storage_service.dart';

class ComicExportResult {
  const ComicExportResult({
    required this.file,
    required this.pageCount,
    required this.originalBytes,
    required this.sha256,
  });

  final File file;
  final int pageCount;
  final int originalBytes;
  final String sha256;
}

class ComicExportService {
  ComicExportService(this._repository, this._storage);

  static const _uuid = Uuid();
  static const MethodChannel _documentsChannel = MethodChannel(
    'private_manga_reader/documents',
  );

  final LibraryRepository _repository;
  final StorageService _storage;

  Future<ComicExportResult> createCbz(String comicId) async {
    final summary = (await _repository.loadLibrary())
        .where((item) => item.comic.id == comicId)
        .firstOrNull;
    if (summary == null) throw StateError('漫画不存在');
    final items = await _repository.loadItems(comicId);
    if (items.isEmpty) throw StateError('空漫画无法导出');

    final exportDirectory = Directory(
      p.join(_storage.temporaryDirectory.path, 'exports'),
    );
    await exportDirectory.create(recursive: true);
    final safeTitle = _safeFileName(summary.comic.title);
    final target = File(
      p.join(exportDirectory.path, '$safeTitle-${_uuid.v4()}.cbz'),
    );
    final encoder = ZipFileEncoder()
      ..create(target.path, level: ZipFileEncoder.store);
    try {
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        final source = File(_storage.resolve(item.asset.storedPath));
        if (!await source.exists()) {
          throw FileSystemException('原图缺失，已停止导出', source.path);
        }
        final extension = item.asset.extension.toLowerCase();
        final pageName = '${(index + 1).toString().padLeft(4, '0')}.$extension';
        await encoder.addFile(source, pageName, ZipFileEncoder.store);
      }
      final coverIndex = items.indexWhere(
        (item) => item.asset.id == summary.comic.coverAssetId,
      );
      encoder.addArchiveFile(
        ArchiveFile.string(
          'ComicInfo.xml',
          _comicInfoXml(
            title: summary.comic.title,
            pageCount: items.length,
            coverIndex: coverIndex < 0 ? 0 : coverIndex,
          ),
        ),
      );
    } finally {
      await encoder.close();
    }
    return ComicExportResult(
      file: target,
      pageCount: items.length,
      originalBytes: items.fold(
        0,
        (total, item) => total + item.asset.byteSize,
      ),
      sha256: (await sha256.bind(target.openRead()).first).toString(),
    );
  }

  Future<Uri?> saveExternally(ComicExportResult export) async {
    final fileName = '${_safeFileName(_baseTitle(export.file))}.cbz';
    if (Platform.isAndroid) {
      final uri = await _documentsChannel.invokeMethod<String>(
        'saveFile',
        <String, Object?>{'sourcePath': export.file.path, 'fileName': fileName},
      );
      return uri == null ? null : Uri.parse(uri);
    }
    return FilePicker.saveFile(
      fileName: fileName,
      bytes: await export.file.readAsBytes(),
      mimeType: 'application/vnd.comicbook+zip',
      dialogTitle: '导出漫画 CBZ',
      type: FileType.custom,
      allowedExtensions: const <String>['cbz'],
    );
  }

  Future<void> share(ComicExportResult export) => SharePlus.instance.share(
    ShareParams(
      title: '分享漫画 CBZ',
      files: <XFile>[
        XFile(export.file.path, mimeType: 'application/vnd.comicbook+zip'),
      ],
    ),
  );

  String _baseTitle(File file) {
    final name = p.basenameWithoutExtension(file.path);
    return name.replaceFirst(RegExp(r'-[0-9a-f-]{36}$'), '');
  }

  String _safeFileName(String value) {
    final result = value.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return result.isEmpty ? '未命名漫画' : result;
  }

  String _comicInfoXml({
    required String title,
    required int pageCount,
    required int coverIndex,
  }) =>
      '<?xml version="1.0" encoding="utf-8"?>\n'
      '<ComicInfo>\n'
      '  <Title>${_xmlEscape(title)}</Title>\n'
      '  <PageCount>$pageCount</PageCount>\n'
      '  <Pages><Page Image="$coverIndex" Type="FrontCover" /></Pages>\n'
      '</ComicInfo>\n';

  String _xmlEscape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

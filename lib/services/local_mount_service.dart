import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../data/network_repository.dart';
import '../models/entities.dart';

class MountedDirectorySelection {
  const MountedDirectorySelection({required this.uri, required this.name});

  final String uri;
  final String name;
}

class LocalMountDocument {
  const LocalMountDocument({
    required this.uri,
    required this.name,
    required this.mimeType,
    required this.size,
    required this.lastModified,
    required this.parentUri,
    required this.relativeDir,
    this.width = 0,
    this.height = 0,
  });

  final String uri;
  final String name;
  final String mimeType;
  final int size;
  final int lastModified;
  final String parentUri;
  final String relativeDir;
  final int width;
  final int height;

  factory LocalMountDocument.fromMap(Map<Object?, Object?> map) =>
      LocalMountDocument(
        uri: map['uri']! as String,
        name: map['name']! as String,
        mimeType: (map['mimeType'] as String?) ?? 'application/octet-stream',
        size: (map['size'] as num?)?.toInt() ?? 0,
        lastModified: (map['lastModified'] as num?)?.toInt() ?? 0,
        parentUri: map['parentUri']! as String,
        relativeDir: (map['relativeDir'] as String?) ?? '',
        width: (map['width'] as num?)?.toInt() ?? 0,
        height: (map['height'] as num?)?.toInt() ?? 0,
      );
}

class LocalArchiveEntry {
  const LocalArchiveEntry({
    required this.name,
    required this.size,
    required this.width,
    required this.height,
  });

  final String name;
  final int size;
  final int width;
  final int height;

  factory LocalArchiveEntry.fromMap(Map<Object?, Object?> map) =>
      LocalArchiveEntry(
        name: map['name']! as String,
        size: (map['size'] as num?)?.toInt() ?? 0,
        width: (map['width'] as num?)?.toInt() ?? 0,
        height: (map['height'] as num?)?.toInt() ?? 0,
      );
}

abstract interface class LocalMountPlatform {
  Future<MountedDirectorySelection?> pickDirectory();
  Future<List<LocalMountDocument>> scanTree(String uri);
  Future<List<LocalMountDocument>> listImages(String uri);
  Future<List<LocalArchiveEntry>> listZipEntries(String uri);
  Future<Uint8List> readPage(String uri, {String? archiveEntry});
}

class MethodChannelLocalMountPlatform implements LocalMountPlatform {
  static const _channel = MethodChannel('private_manga_reader/local_mount');

  @override
  Future<MountedDirectorySelection?> pickDirectory() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'pickDirectory',
    );
    if (result == null) return null;
    return MountedDirectorySelection(
      uri: result['uri']! as String,
      name: result['name']! as String,
    );
  }

  @override
  Future<List<LocalMountDocument>> scanTree(String uri) async =>
      _documents('scanTree', uri);

  @override
  Future<List<LocalMountDocument>> listImages(String uri) async =>
      _documents('listImages', uri);

  Future<List<LocalMountDocument>> _documents(String method, String uri) async {
    final rows = await _channel.invokeListMethod<Object?>(
      method,
      <String, Object?>{'uri': uri},
    );
    return (rows ?? const <Object?>[])
        .map((row) => LocalMountDocument.fromMap(row! as Map<Object?, Object?>))
        .toList(growable: false);
  }

  @override
  Future<List<LocalArchiveEntry>> listZipEntries(String uri) async {
    final rows = await _channel.invokeListMethod<Object?>(
      'listZipEntries',
      <String, Object?>{'uri': uri},
    );
    return (rows ?? const <Object?>[])
        .map((row) => LocalArchiveEntry.fromMap(row! as Map<Object?, Object?>))
        .toList(growable: false);
  }

  @override
  Future<Uint8List> readPage(String uri, {String? archiveEntry}) async {
    final bytes = await _channel.invokeMethod<Uint8List>(
      'readPage',
      <String, Object?>{'uri': uri, 'archiveEntry': archiveEntry},
    );
    if (bytes == null) throw StateError('本地漫画页读取失败');
    return bytes;
  }
}

class LocalMountService {
  LocalMountService(this._repository, {LocalMountPlatform? platform})
    : _platform = platform ?? MethodChannelLocalMountPlatform();

  static const folderMediaType = 'application/x-shihuage-image-folder';
  static const _uuid = Uuid();

  final NetworkRepository _repository;
  final LocalMountPlatform _platform;

  Future<MountedDirectorySelection?> pickDirectory() =>
      _platform.pickDirectory();

  Future<List<RemoteBook>> discoverAndSave(NetworkSource source) async {
    if (source.type != NetworkSourceType.local) {
      throw ArgumentError.value(source.type, 'source', '不是本地挂载源');
    }
    final documents = await _platform.scanTree(source.endpoint);
    final discoveries = <RemoteBookDiscovery>[];
    final imageGroups = <String, List<LocalMountDocument>>{};
    for (final document in documents) {
      final extension = p.extension(document.name).toLowerCase();
      if (extension == '.zip' || extension == '.cbz') {
        discoveries.add(
          RemoteBookDiscovery(
            title: p.basenameWithoutExtension(document.name),
            remoteUri: document.uri,
            mediaType: 'application/vnd.comicbook+zip',
            etag: '${document.size}:${document.lastModified}',
            byteSize: document.size,
          ),
        );
      } else if (_isImage(document.name)) {
        imageGroups.putIfAbsent(document.parentUri, () => []).add(document);
      }
    }
    for (final group in imageGroups.entries) {
      final pages = group.value
        ..sort((a, b) => _naturalCompare(a.name, b.name));
      final relativeDir = pages.first.relativeDir.trim();
      final title = relativeDir.isEmpty
          ? source.name
          : p.posix.basename(relativeDir);
      final signature = pages
          .map((page) => '${page.name}:${page.size}:${page.lastModified}')
          .join('|');
      discoveries.add(
        RemoteBookDiscovery(
          title: title,
          remoteUri: group.key,
          mediaType: folderMediaType,
          etag: sha1.convert(utf8.encode(signature)).toString(),
          byteSize: pages.fold(0, (total, page) => total + page.size),
        ),
      );
    }
    discoveries.sort((a, b) => _naturalCompare(a.title, b.title));
    await _repository.upsertDiscoveredBooks(source.id, discoveries);
    return _repository.loadBooks(source.id);
  }

  Future<List<RemotePage>> prepareBook(RemoteBook book) async {
    final existing = await _repository.loadPages(book.id);
    if (book.isExternalIndexed && existing.isNotEmpty) return existing;
    final pages = <RemotePage>[];
    if (book.mediaType == folderMediaType) {
      final documents = (await _platform.listImages(book.remoteUri)).toList()
        ..sort((a, b) => _naturalCompare(a.name, b.name));
      for (var index = 0; index < documents.length; index++) {
        final page = documents[index];
        pages.add(
          RemotePage(
            id: _uuid.v4(),
            bookId: book.id,
            position: index,
            relativePath: '',
            originalName: page.name,
            byteSize: page.size,
            width: page.width,
            height: page.height,
            sourceUri: page.uri,
          ),
        );
      }
    } else {
      final entries = (await _platform.listZipEntries(book.remoteUri)).toList()
        ..sort((a, b) => _naturalCompare(a.name, b.name));
      for (var index = 0; index < entries.length; index++) {
        final page = entries[index];
        pages.add(
          RemotePage(
            id: _uuid.v4(),
            bookId: book.id,
            position: index,
            relativePath: '',
            originalName: page.name,
            byteSize: page.size,
            width: page.width,
            height: page.height,
            sourceUri: book.remoteUri,
            archiveEntry: page.name,
          ),
        );
      }
    }
    if (pages.isEmpty) throw const FormatException('没有找到可阅读的图片');
    await _repository.replaceExternalPages(
      book.id,
      etag: book.etag,
      pages: pages,
    );
    return _repository.loadPages(book.id);
  }

  Future<Uint8List> readPage(RemotePage page) {
    final sourceUri = page.sourceUri;
    if (sourceUri == null) throw StateError('该页不是原地挂载资源');
    return _platform.readPage(sourceUri, archiveEntry: page.archiveEntry);
  }

  static bool _isImage(String name) => const <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
    '.bmp',
    '.avif',
  }.contains(p.extension(name).toLowerCase());

  static int _naturalCompare(String left, String right) {
    final matcher = RegExp(r'\d+|\D+');
    final a = matcher.allMatches(left.toLowerCase()).map((m) => m[0]!).toList();
    final b = matcher
        .allMatches(right.toLowerCase())
        .map((m) => m[0]!)
        .toList();
    for (var index = 0; index < a.length && index < b.length; index++) {
      final aNumber = int.tryParse(a[index]);
      final bNumber = int.tryParse(b[index]);
      final comparison = aNumber != null && bNumber != null
          ? aNumber.compareTo(bNumber)
          : a[index].compareTo(b[index]);
      if (comparison != 0) return comparison;
    }
    return a.length.compareTo(b.length);
  }
}

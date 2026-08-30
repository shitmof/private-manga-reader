import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:smb_connect/smb_connect.dart';
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

import '../data/network_repository.dart';
import '../models/entities.dart';
import 'archive_import_service.dart';
import 'import_service.dart';
import 'network_credential_store.dart';
import 'storage_service.dart';

class NetworkLibraryService {
  NetworkLibraryService(
    this._repository,
    this._storage,
    this._archiveImporter,
    this._credentials, {
    http.Client? client,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  static const _uuid = Uuid();
  static const _maxScanDepth = 8;
  static const _maxDiscoveredBooks = 5000;
  static const _archiveExtensions = <String>{
    'cbz',
    'zip',
    'cbr',
    'rar',
    'cb7',
    '7z',
    'cbt',
    'tar',
  };

  final NetworkRepository _repository;
  final StorageService _storage;
  final ArchiveImportService _archiveImporter;
  final NetworkCredentialStore _credentials;
  final http.Client _client;
  final bool _ownsClient;

  Future<void> dispose() async {
    if (_ownsClient) _client.close();
  }

  Future<void> saveCredentials(
    String sourceId,
    NetworkCredentials credentials,
  ) => _credentials.write(sourceId, credentials);

  Future<List<RemoteBook>> discoverAndSave(NetworkSource source) async {
    final credentials = await _credentials.read(source.id);
    final discoveries = switch (source.type) {
      NetworkSourceType.local => throw UnsupportedError('本地挂载由 SAF 服务处理'),
      NetworkSourceType.webdav => await _discoverWebDav(source, credentials),
      NetworkSourceType.opds => await _discoverOpds(source, credentials),
      NetworkSourceType.smb => await _discoverSmb(source, credentials),
    };
    discoveries.sort((a, b) => _naturalCompare(a.title, b.title));
    await _repository.upsertDiscoveredBooks(source.id, discoveries);
    return _repository.loadBooks(source.id);
  }

  Future<void> testConnection(
    NetworkSource source,
    NetworkCredentials credentials,
  ) async {
    switch (source.type) {
      case NetworkSourceType.local:
        throw UnsupportedError('本地挂载由 SAF 服务处理');
      case NetworkSourceType.webdav:
        final root = _sourceRootUri(source);
        await _listWebDav(root, credentials, credentialOrigin: root);
      case NetworkSourceType.opds:
        final response = await _sendHttp(
          'GET',
          _sourceRootUri(source),
          credentials,
          credentialOrigin: _sourceRootUri(source),
        );
        await _requireSuccess(response, '无法读取 OPDS 目录');
        await response.stream.drain<void>();
      case NetworkSourceType.smb:
        final connection = await _connectSmb(source, credentials);
        try {
          final root = await connection.file(_smbRootPath(source));
          await connection.listFiles(root);
        } finally {
          await connection.close();
        }
    }
  }

  Future<RemoteBook> cacheBook(
    String bookId, {
    ImportProgress? onProgress,
  }) async {
    final book = await _repository.getBook(bookId);
    if (book == null) throw StateError('网络漫画已不存在');
    final existingPages = await _repository.loadPages(bookId);
    final cacheIsComplete =
        book.isCached &&
        existingPages.isNotEmpty &&
        existingPages.every(
          (page) => File(_storage.resolve(page.relativePath)).existsSync(),
        );
    if (cacheIsComplete) return book;

    final source = await _repository.getSource(book.sourceId);
    if (source == null) throw StateError('网络书库已被移除');
    final credentials = await _credentials.read(source.id);
    final extension = p.extension(Uri.parse(book.remoteUri).path).toLowerCase();
    final downloaded = File(
      p.join(
        _storage.temporaryDirectory.path,
        'network-${_uuid.v4()}${extension.isEmpty ? '.bin' : extension}',
      ),
    );
    PreparedArchiveSelection? selection;
    Directory? staging;
    Directory? previous;
    var installedNewCache = false;
    try {
      onProgress?.call(0, 0, '正在从 ${source.name} 读取');
      await _download(source, credentials, book, downloaded);
      selection = await _archiveImporter.prepareArchives(<PlatformFile>[
        _LocalPlatformFile(downloaded, book.title + extension),
      ]);
      if (selection.archives.length != 1) {
        throw const FormatException('网络漫画压缩包无效');
      }

      final target = _storage.networkBookCacheDirectory(bookId);
      staging = Directory('${target.path}.staging-${_uuid.v4()}');
      final extracted = await _archiveImporter.extractPreparedToDirectory(
        archive: selection.archives.single,
        target: staging,
        onProgress: onProgress,
      );
      if (await target.exists()) {
        previous = Directory('${target.path}.previous-${_uuid.v4()}');
        await target.rename(previous.path);
      }
      await staging.rename(target.path);
      installedNewCache = true;

      final pages = <RemotePage>[
        for (var index = 0; index < extracted.length; index++)
          RemotePage(
            id: _uuid.v4(),
            bookId: bookId,
            position: index,
            relativePath: _storage.relative(
              p.join(target.path, p.basename(extracted[index].file.path)),
            ),
            originalName: extracted[index].originalName,
            byteSize: extracted[index].byteSize,
            width: extracted[index].width,
            height: extracted[index].height,
          ),
      ];
      await _repository.replaceCachedPages(
        bookId,
        cachedVersion: _cacheVersion(book),
        pages: pages,
      );
      if (previous != null && await previous.exists()) {
        await previous.delete(recursive: true);
      }
      onProgress?.call(pages.length, pages.length, '完成');
      return (await _repository.getBook(bookId))!;
    } catch (_) {
      final target = _storage.networkBookCacheDirectory(bookId);
      if (installedNewCache && await target.exists()) {
        await target.delete(recursive: true);
      }
      if (previous != null && await previous.exists()) {
        await previous.rename(target.path);
      }
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      rethrow;
    } finally {
      await selection?.dispose();
      if (await downloaded.exists()) await downloaded.delete();
    }
  }

  Future<void> clearBookCache(String bookId) async {
    final directory = _storage.networkBookCacheDirectory(bookId);
    if (await directory.exists()) await directory.delete(recursive: true);
    await _repository.clearCachedPages(bookId);
  }

  Future<void> removeSource(String sourceId) async {
    final books = await _repository.loadBooks(sourceId);
    for (final book in books) {
      final directory = _storage.networkBookCacheDirectory(book.id);
      if (await directory.exists()) await directory.delete(recursive: true);
    }
    await _repository.deleteSource(sourceId);
    await _credentials.delete(sourceId);
  }

  Future<List<RemoteBookDiscovery>> _discoverWebDav(
    NetworkSource source,
    NetworkCredentials credentials,
  ) async {
    final discoveries = <RemoteBookDiscovery>[];
    final root = _withTrailingSlash(_sourceRootUri(source));
    final rootPath = root.path;
    final queue = <(Uri, int)>[(root, 0)];
    final visited = <String>{};
    while (queue.isNotEmpty && discoveries.length < _maxDiscoveredBooks) {
      final (directory, depth) = queue.removeAt(0);
      final key = _trimTrailingSlash(directory.toString());
      if (!visited.add(key)) continue;
      final entries = await _listWebDav(
        directory,
        credentials,
        credentialOrigin: root,
      );
      for (final entry in entries) {
        final entryPath = p.url.normalize(entry.uri.path);
        if (!_sameOrigin(root, entry.uri) || !entryPath.startsWith(rootPath)) {
          continue;
        }
        if (entry.isDirectory) {
          if (depth < _maxScanDepth) queue.add((entry.uri, depth + 1));
          continue;
        }
        if (!_isArchiveUri(entry.uri)) continue;
        discoveries.add(
          RemoteBookDiscovery(
            title: _titleFromUri(entry.uri),
            remoteUri: entry.uri.toString(),
            mediaType: _mediaType(entry.uri),
            etag: entry.etag.isEmpty
                ? '${entry.byteSize}:${entry.modified}'
                : entry.etag,
            byteSize: entry.byteSize,
          ),
        );
        if (discoveries.length >= _maxDiscoveredBooks) break;
      }
    }
    return discoveries;
  }

  Future<List<_WebDavEntry>> _listWebDav(
    Uri directory,
    NetworkCredentials credentials, {
    Uri? credentialOrigin,
  }) async {
    final response = await _sendHttp(
      'PROPFIND',
      _withTrailingSlash(directory),
      credentials,
      credentialOrigin: credentialOrigin,
      headers: const <String, String>{
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      },
      body: '''<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/>
<d:getetag/><d:getlastmodified/></d:prop></d:propfind>''',
    );
    await _requireSuccess(response, '无法读取 WebDAV 目录');
    final body = await response.stream.bytesToString();
    final document = XmlDocument.parse(body);
    final rootPath = _trimTrailingSlash(directory.path);
    final result = <_WebDavEntry>[];
    for (final node in _elements(document, 'response')) {
      final href = _firstText(node, 'href');
      if (href == null || href.isEmpty) continue;
      final uri = directory.resolve(href);
      if (_trimTrailingSlash(uri.path) == rootPath) continue;
      final isDirectory = _elements(node, 'collection').isNotEmpty;
      result.add(
        _WebDavEntry(
          uri: isDirectory ? _withTrailingSlash(uri) : uri,
          isDirectory: isDirectory,
          byteSize:
              int.tryParse(_firstText(node, 'getcontentlength') ?? '') ?? 0,
          etag: (_firstText(node, 'getetag') ?? '').replaceAll('"', ''),
          modified: _firstText(node, 'getlastmodified') ?? '',
        ),
      );
    }
    return result;
  }

  Future<List<RemoteBookDiscovery>> _discoverOpds(
    NetworkSource source,
    NetworkCredentials credentials,
  ) async {
    final discoveries = <RemoteBookDiscovery>[];
    final credentialOrigin = _sourceRootUri(source);
    Uri? next = credentialOrigin;
    final visited = <String>{};
    for (
      var page = 0;
      next != null && page < 50 && discoveries.length < _maxDiscoveredBooks;
      page++
    ) {
      if (!visited.add(next.toString())) break;
      final response = await _sendHttp(
        'GET',
        next,
        credentials,
        credentialOrigin: credentialOrigin,
      );
      await _requireSuccess(response, '无法读取 OPDS 目录');
      final contentType = response.headers['content-type'] ?? '';
      final body = await response.stream.bytesToString();
      if (contentType.contains('json') || body.trimLeft().startsWith('{')) {
        discoveries.addAll(_parseOpdsJson(body, next));
        next = null;
      } else {
        final parsed = _parseOpdsXml(body, next);
        discoveries.addAll(parsed.$1);
        next = parsed.$2;
      }
    }
    if (discoveries.length > _maxDiscoveredBooks) {
      return discoveries.take(_maxDiscoveredBooks).toList(growable: false);
    }
    return discoveries;
  }

  (List<RemoteBookDiscovery>, Uri?) _parseOpdsXml(String body, Uri base) {
    final document = XmlDocument.parse(body);
    final result = <RemoteBookDiscovery>[];
    for (final entry in _elements(document, 'entry')) {
      final title = _firstText(entry, 'title')?.trim();
      XmlElement? acquisition;
      for (final link in _elements(entry, 'link')) {
        final href = link.getAttribute('href');
        final rel = link.getAttribute('rel') ?? '';
        if (href != null &&
            (rel.contains('acquisition') ||
                _isArchiveUri(base.resolve(href)))) {
          acquisition = link;
          break;
        }
      }
      final href = acquisition?.getAttribute('href');
      if (href == null) continue;
      final uri = base.resolve(href);
      if (!_isArchiveUri(uri)) continue;
      final updated = _firstText(entry, 'updated') ?? '';
      result.add(
        RemoteBookDiscovery(
          title: title == null || title.isEmpty ? _titleFromUri(uri) : title,
          remoteUri: uri.toString(),
          mediaType: acquisition?.getAttribute('type') ?? _mediaType(uri),
          etag: updated.isEmpty ? uri.toString() : updated,
          byteSize:
              int.tryParse(acquisition?.getAttribute('length') ?? '') ?? 0,
        ),
      );
    }
    Uri? next;
    for (final link in _elements(document, 'link')) {
      if (link.getAttribute('rel') == 'next') {
        final href = link.getAttribute('href');
        if (href != null) next = base.resolve(href);
        break;
      }
    }
    return (result, next);
  }

  List<RemoteBookDiscovery> _parseOpdsJson(String body, Uri base) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw const FormatException('OPDS 2.0 目录格式无效');
    final publications = decoded['publications'];
    if (publications is! List) return const <RemoteBookDiscovery>[];
    final result = <RemoteBookDiscovery>[];
    for (final publication in publications) {
      if (publication is! Map) continue;
      final links = publication['links'];
      if (links is! List) continue;
      Map? acquisition;
      for (final candidate in links.whereType<Map>()) {
        final href = candidate['href']?.toString();
        final rel = candidate['rel']?.toString() ?? '';
        if (href != null &&
            (rel.contains('acquisition') ||
                _isArchiveUri(base.resolve(href)))) {
          acquisition = candidate;
          break;
        }
      }
      final href = acquisition?['href']?.toString();
      if (href == null) continue;
      final uri = base.resolve(href);
      if (!_isArchiveUri(uri)) continue;
      final metadata = publication['metadata'];
      final title = metadata is Map ? metadata['title']?.toString() : null;
      final modified = metadata is Map
          ? metadata['modified']?.toString()
          : null;
      result.add(
        RemoteBookDiscovery(
          title: title == null || title.isEmpty ? _titleFromUri(uri) : title,
          remoteUri: uri.toString(),
          mediaType: acquisition?['type']?.toString() ?? _mediaType(uri),
          etag: modified == null || modified.isEmpty
              ? uri.toString()
              : modified,
          byteSize: int.tryParse(acquisition?['length']?.toString() ?? '') ?? 0,
        ),
      );
    }
    return result;
  }

  Future<List<RemoteBookDiscovery>> _discoverSmb(
    NetworkSource source,
    NetworkCredentials credentials,
  ) async {
    final connection = await _connectSmb(source, credentials);
    final result = <RemoteBookDiscovery>[];
    try {
      final root = await connection.file(_smbRootPath(source));
      final queue = <(SmbFile, int)>[(root, 0)];
      while (queue.isNotEmpty && result.length < _maxDiscoveredBooks) {
        final (directory, depth) = queue.removeAt(0);
        final children = await connection.listFiles(directory);
        for (final child in children) {
          if (child.isHidden() || child.isSystem()) continue;
          if (child.isDirectory()) {
            if (depth < _maxScanDepth) queue.add((child, depth + 1));
          } else if (_isArchivePath(child.path)) {
            final uri = Uri(
              scheme: 'smb',
              host: _smbHost(source),
              path: child.path,
            );
            result.add(
              RemoteBookDiscovery(
                title: p.basenameWithoutExtension(child.name),
                remoteUri: uri.toString(),
                mediaType: _mediaType(uri),
                etag: '${child.lastModified}:${child.size}',
                byteSize: child.size,
              ),
            );
          }
          if (result.length >= _maxDiscoveredBooks) break;
        }
      }
      return result;
    } finally {
      await connection.close();
    }
  }

  Future<void> _download(
    NetworkSource source,
    NetworkCredentials credentials,
    RemoteBook book,
    File target,
  ) async {
    await target.parent.create(recursive: true);
    final sink = target.openWrite();
    try {
      if (source.type == NetworkSourceType.smb) {
        final connection = await _connectSmb(source, credentials);
        try {
          final remote = await connection.file(Uri.parse(book.remoteUri).path);
          final stream = await connection.openRead(remote);
          await for (final chunk in stream) {
            sink.add(chunk);
          }
        } finally {
          await connection.close();
        }
      } else {
        final response = await _sendHttp(
          'GET',
          Uri.parse(book.remoteUri),
          credentials,
          credentialOrigin: _sourceRootUri(source),
        );
        await _requireSuccess(response, '无法读取远程漫画');
        await for (final chunk in response.stream) {
          sink.add(chunk);
        }
      }
      await sink.close();
    } catch (_) {
      await sink.close();
      if (await target.exists()) await target.delete();
      rethrow;
    }
  }

  Future<SmbConnect> _connectSmb(
    NetworkSource source,
    NetworkCredentials credentials,
  ) => SmbConnect.connectAuth(
    host: _smbHost(source),
    username: credentials.username,
    password: credentials.password,
    domain: credentials.domain,
  );

  Future<http.StreamedResponse> _sendHttp(
    String method,
    Uri uri,
    NetworkCredentials credentials, {
    Map<String, String> headers = const <String, String>{},
    String? body,
    Uri? credentialOrigin,
  }) async {
    Future<http.StreamedResponse> send(String? authorization) {
      final request = http.Request(method, uri)..headers.addAll(headers);
      if (authorization != null) {
        request.headers['Authorization'] = authorization;
      }
      if (body != null) request.body = body;
      return _client.send(request).timeout(const Duration(seconds: 30));
    }

    final effectiveCredentials =
        credentialOrigin != null && !_sameOrigin(credentialOrigin, uri)
        ? const NetworkCredentials()
        : credentials;
    final basic = effectiveCredentials.username.isEmpty
        ? null
        : 'Basic ${base64Encode(utf8.encode('${effectiveCredentials.username}:${effectiveCredentials.password}'))}';
    var response = await send(basic);
    final challenge = response.headers['www-authenticate'];
    if (response.statusCode == HttpStatus.unauthorized &&
        challenge != null &&
        challenge.toLowerCase().startsWith('digest ')) {
      await response.stream.drain<void>();
      final digest = _digestAuthorization(
        challenge,
        method,
        uri,
        effectiveCredentials,
      );
      response = await send(digest);
    }
    return response;
  }

  String _digestAuthorization(
    String challenge,
    String method,
    Uri uri,
    NetworkCredentials credentials,
  ) {
    final values = <String, String>{};
    final payload = challenge.substring(challenge.indexOf(' ') + 1);
    for (final match in RegExp(
      r'(\w+)=(?:"([^"]*)"|([^,\s]+))',
    ).allMatches(payload)) {
      values[match[1]!.toLowerCase()] = match[2] ?? match[3] ?? '';
    }
    final realm = values['realm'];
    final nonce = values['nonce'];
    final algorithm = (values['algorithm'] ?? 'MD5').toUpperCase();
    if (realm == null || nonce == null || algorithm != 'MD5') {
      throw const FormatException('服务器使用了不支持的 Digest 认证');
    }
    final requestTarget = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    final ha1 = _md5('${credentials.username}:$realm:${credentials.password}');
    final ha2 = _md5('$method:$requestTarget');
    final cnonce = _uuid.v4().replaceAll('-', '');
    const nc = '00000001';
    final qopOptions = (values['qop'] ?? '')
        .split(',')
        .map((value) => value.trim().toLowerCase())
        .toSet();
    final usesQop = qopOptions.contains('auth');
    final digest = usesQop
        ? _md5('$ha1:$nonce:$nc:$cnonce:auth:$ha2')
        : _md5('$ha1:$nonce:$ha2');
    final parts = <String>[
      'username="${credentials.username}"',
      'realm="$realm"',
      'nonce="$nonce"',
      'uri="$requestTarget"',
      'response="$digest"',
      'algorithm=MD5',
      if (values['opaque'] case final opaque?) 'opaque="$opaque"',
      if (usesQop) ...<String>['qop=auth', 'nc=$nc', 'cnonce="$cnonce"'],
    ];
    return 'Digest ${parts.join(', ')}';
  }

  String _md5(String value) => md5.convert(utf8.encode(value)).toString();

  Future<void> _requireSuccess(
    http.StreamedResponse response,
    String message,
  ) async {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    await response.stream.drain<void>();
    if (response.statusCode == HttpStatus.unauthorized ||
        response.statusCode == HttpStatus.forbidden) {
      throw const FormatException('账号、密码或权限不正确');
    }
    throw FormatException('$message（HTTP ${response.statusCode}）');
  }

  Uri _sourceRootUri(NetworkSource source) {
    final base = Uri.parse(source.endpoint.trim());
    final root = source.rootPath.trim().replaceFirst(RegExp(r'^/+'), '');
    if (root.isEmpty) return base;
    final basePath = base.path.endsWith('/') ? base.path : '${base.path}/';
    return base.replace(path: p.url.normalize('$basePath$root'));
  }

  String _smbHost(NetworkSource source) {
    final raw = source.endpoint.trim();
    final parsed = Uri.tryParse(raw.contains('://') ? raw : 'smb://$raw');
    final host = parsed?.host ?? '';
    if (host.isEmpty) throw const FormatException('SMB 主机地址无效');
    return host;
  }

  String _smbRootPath(NetworkSource source) {
    var root = source.rootPath.trim().replaceAll('\\', '/');
    if (!root.startsWith('/')) root = '/$root';
    if (root.split('/').where((part) => part.isNotEmpty).isEmpty) {
      throw const FormatException('SMB 根目录必须包含共享名');
    }
    return root;
  }

  String _cacheVersion(RemoteBook book) =>
      book.etag.isEmpty ? '${book.byteSize}:${book.remoteUri}' : book.etag;

  static bool _isArchiveUri(Uri uri) => _isArchivePath(uri.path);

  static bool _isArchivePath(String path) => _archiveExtensions.contains(
    p.extension(path).replaceFirst('.', '').toLowerCase(),
  );

  static String _mediaType(Uri uri) =>
      switch (p.extension(uri.path).replaceFirst('.', '').toLowerCase()) {
        'cbz' || 'zip' => 'application/vnd.comicbook+zip',
        'cbr' || 'rar' => 'application/vnd.comicbook-rar',
        'cb7' || '7z' => 'application/x-7z-compressed',
        'cbt' || 'tar' => 'application/x-tar',
        _ => 'application/octet-stream',
      };

  static String _titleFromUri(Uri uri) {
    final name = Uri.decodeComponent(p.posix.basename(uri.path));
    return p.basenameWithoutExtension(name);
  }

  static Uri _withTrailingSlash(Uri uri) =>
      uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');

  static String _trimTrailingSlash(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;

  static bool _sameOrigin(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  static Iterable<XmlElement> _elements(XmlNode node, String localName) => node
      .descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == localName);

  static String? _firstText(XmlNode node, String localName) =>
      _elements(node, localName).firstOrNull?.innerText;

  static int _naturalCompare(String left, String right) {
    final matcher = RegExp(r'\d+|\D+');
    final a = matcher
        .allMatches(left.toLowerCase())
        .map((match) => match[0]!)
        .toList();
    final b = matcher
        .allMatches(right.toLowerCase())
        .map((match) => match[0]!)
        .toList();
    final length = a.length < b.length ? a.length : b.length;
    for (var index = 0; index < length; index++) {
      final numberA = int.tryParse(a[index]);
      final numberB = int.tryParse(b[index]);
      final comparison = numberA != null && numberB != null
          ? numberA.compareTo(numberB)
          : a[index].compareTo(b[index]);
      if (comparison != 0) return comparison;
    }
    return a.length.compareTo(b.length);
  }
}

class _WebDavEntry {
  const _WebDavEntry({
    required this.uri,
    required this.isDirectory,
    required this.byteSize,
    required this.etag,
    required this.modified,
  });

  final Uri uri;
  final bool isDirectory;
  final int byteSize;
  final String etag;
  final String modified;
}

final class _LocalPlatformFile extends PlatformFile {
  _LocalPlatformFile(this.file, this.displayName);

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

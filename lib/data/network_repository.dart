import 'package:uuid/uuid.dart';

import '../models/entities.dart';
import 'app_database.dart';

class NetworkRepository {
  NetworkRepository(this._database);

  static const _uuid = Uuid();
  final AppDatabase _database;

  Future<NetworkSource> createSource({
    required String name,
    required NetworkSourceType type,
    required String endpoint,
    required String rootPath,
    required String username,
  }) async {
    final db = await _database.instance;
    final now = DateTime.now().toUtc();
    final source = NetworkSource(
      id: _uuid.v4(),
      name: name.trim(),
      type: type,
      endpoint: endpoint.trim(),
      rootPath: rootPath.trim(),
      username: username.trim(),
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('network_sources', _sourceMap(source));
    return source;
  }

  Future<void> updateSource(NetworkSource source) async {
    final db = await _database.instance;
    await db.update(
      'network_sources',
      _sourceMap(
        NetworkSource(
          id: source.id,
          name: source.name,
          type: source.type,
          endpoint: source.endpoint,
          rootPath: source.rootPath,
          username: source.username,
          createdAt: source.createdAt,
          updatedAt: DateTime.now().toUtc(),
        ),
      ),
      where: 'id = ?',
      whereArgs: <Object?>[source.id],
    );
  }

  Future<List<NetworkSource>> loadSources() async {
    final db = await _database.instance;
    final rows = await db.query('network_sources', orderBy: 'created_at');
    return rows.map(NetworkSource.fromMap).toList(growable: false);
  }

  Future<NetworkSource?> getSource(String id) async {
    final db = await _database.instance;
    final rows = await db.query(
      'network_sources',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : NetworkSource.fromMap(rows.first);
  }

  Future<void> deleteSource(String id) async {
    final db = await _database.instance;
    await db.delete(
      'network_sources',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> upsertDiscoveredBooks(
    String sourceId,
    List<RemoteBookDiscovery> discoveries,
  ) async {
    final db = await _database.instance;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      await txn.update(
        'remote_books',
        <String, Object?>{'is_available': 0},
        where: 'source_id = ?',
        whereArgs: <Object?>[sourceId],
      );
      for (var index = 0; index < discoveries.length; index++) {
        final discovery = discoveries[index];
        final rows = await txn.query(
          'remote_books',
          columns: <String>['id'],
          where: 'source_id = ? AND remote_uri = ?',
          whereArgs: <Object?>[sourceId, discovery.remoteUri],
          limit: 1,
        );
        final values = <String, Object?>{
          'title': discovery.title,
          'media_type': discovery.mediaType,
          'etag': discovery.etag,
          'byte_size': discovery.byteSize,
          'sort_index': index,
          'is_available': 1,
          'updated_at': now,
        };
        if (rows.isEmpty) {
          await txn.insert('remote_books', <String, Object?>{
            'id': _uuid.v4(),
            'source_id': sourceId,
            'remote_uri': discovery.remoteUri,
            ...values,
            'created_at': now,
          });
        } else {
          await txn.update(
            'remote_books',
            values,
            where: 'id = ?',
            whereArgs: <Object?>[rows.first['id']],
          );
        }
      }
    });
  }

  Future<List<RemoteBook>> loadBooks(String sourceId) async {
    final db = await _database.instance;
    final rows = await db.query(
      'remote_books',
      where: 'source_id = ?',
      whereArgs: <Object?>[sourceId],
      orderBy: 'sort_index, title',
    );
    return rows.map(RemoteBook.fromMap).toList(growable: false);
  }

  Future<RemoteBook?> getBook(String id) async {
    final db = await _database.instance;
    final rows = await db.query(
      'remote_books',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : RemoteBook.fromMap(rows.first);
  }

  Future<List<RemotePage>> loadPages(String bookId) async {
    final db = await _database.instance;
    final rows = await db.query(
      'remote_pages',
      where: 'book_id = ?',
      whereArgs: <Object?>[bookId],
      orderBy: 'position',
    );
    return rows.map(RemotePage.fromMap).toList(growable: false);
  }

  Future<void> replaceCachedPages(
    String bookId, {
    required String cachedVersion,
    required List<RemotePage> pages,
  }) async {
    final db = await _database.instance;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      await txn.delete(
        'remote_pages',
        where: 'book_id = ?',
        whereArgs: <Object?>[bookId],
      );
      for (var index = 0; index < pages.length; index++) {
        final page = pages[index];
        await txn.insert('remote_pages', <String, Object?>{
          'id': page.id,
          'book_id': bookId,
          'position': index,
          'relative_path': page.relativePath,
          'original_name': page.originalName,
          'byte_size': page.byteSize,
          'width': page.width,
          'height': page.height,
        });
      }
      await txn.update(
        'remote_books',
        <String, Object?>{
          'page_count': pages.length,
          'cover_relative_path': pages.isEmpty
              ? null
              : pages.first.relativePath,
          'cached_version': cachedVersion,
          'cached_at': now,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: <Object?>[bookId],
      );
    });
  }

  Future<void> clearCachedPages(String bookId) async {
    final db = await _database.instance;
    await db.transaction((txn) async {
      await txn.delete(
        'remote_pages',
        where: 'book_id = ?',
        whereArgs: <Object?>[bookId],
      );
      await txn.update(
        'remote_books',
        <String, Object?>{
          'page_count': 0,
          'cover_relative_path': null,
          'cached_version': null,
          'cached_at': null,
        },
        where: 'id = ?',
        whereArgs: <Object?>[bookId],
      );
    });
  }

  Future<void> saveProgress(String bookId, int position, double offset) async {
    final db = await _database.instance;
    await db.update(
      'remote_books',
      <String, Object?>{
        'last_read_position': position,
        'last_read_offset': offset,
      },
      where: 'id = ?',
      whereArgs: <Object?>[bookId],
    );
  }

  Map<String, Object?> _sourceMap(NetworkSource source) => <String, Object?>{
    'id': source.id,
    'name': source.name,
    'type': source.type.name,
    'endpoint': source.endpoint,
    'root_path': source.rootPath,
    'username': source.username,
    'created_at': source.createdAt.toIso8601String(),
    'updated_at': source.updatedAt.toIso8601String(),
  };
}

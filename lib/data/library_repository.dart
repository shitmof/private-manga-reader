import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/entities.dart';
import 'app_database.dart';

class LibraryRepository {
  LibraryRepository(this._database);

  static const maxItemsPerComic = 1000;
  static const _uuid = Uuid();
  final AppDatabase _database;

  Future<List<ComicSummary>> loadLibrary() => _loadLibrary(deleted: false);

  Future<List<ComicSummary>> loadDeletedComics() => _loadLibrary(deleted: true);

  Future<List<ComicSummary>> _loadLibrary({required bool deleted}) async {
    final db = await _database.instance;
    final rows = await db.rawQuery('''
      SELECT c.*,
        COUNT(ci.id) AS item_count,
        COALESCE(SUM(a.byte_size), 0) AS total_bytes,
        cover.stored_path AS cover_stored_path,
        cover.thumbnail_path AS cover_thumbnail_path
      FROM comics c
      LEFT JOIN comic_items ci ON ci.comic_id = c.id
      LEFT JOIN assets a ON a.id = ci.asset_id
      LEFT JOIN assets cover ON cover.id = COALESCE(
        c.cover_asset_id,
        (SELECT asset_id FROM comic_items WHERE comic_id = c.id ORDER BY position LIMIT 1)
      )
      WHERE c.deleted_at IS ${deleted ? 'NOT NULL' : 'NULL'}
      GROUP BY c.id
      ORDER BY ${deleted ? 'c.deleted_at DESC' : 'c.sort_index, c.created_at'}
    ''');
    return rows
        .map(
          (row) => ComicSummary(
            comic: Comic.fromMap(row),
            itemCount: row['item_count']! as int,
            totalBytes: row['total_bytes']! as int,
            coverStoredPath: row['cover_stored_path'] as String?,
            coverThumbnailPath: row['cover_thumbnail_path'] as String?,
          ),
        )
        .toList(growable: false);
  }

  Future<ComicSummary?> getComic(String id) async {
    final library = await loadLibrary();
    for (final summary in library) {
      if (summary.comic.id == id) return summary;
    }
    return null;
  }

  Future<Comic> createComic(String title) async {
    final db = await _database.instance;
    final now = DateTime.now().toUtc();
    final indexRows = await db.rawQuery(
      'SELECT COALESCE(MAX(sort_index), -1) + 1 AS next_index FROM comics',
    );
    final comic = Comic(
      id: _uuid.v4(),
      title: title.trim(),
      sortIndex: indexRows.first['next_index']! as int,
      createdAt: now,
      updatedAt: now,
      lastReadPosition: 0,
      lastReadOffset: 0,
    );
    await db.insert('comics', <String, Object?>{
      'id': comic.id,
      'title': comic.title,
      'cover_asset_id': null,
      'sort_index': comic.sortIndex,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
      'last_read_position': 0,
      'last_read_offset': 0.0,
      'deleted_at': null,
    });
    return comic;
  }

  Future<void> renameComic(String id, String title) async {
    final db = await _database.instance;
    await db.update(
      'comics',
      <String, Object?>{
        'title': title.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> deleteComic(String id) async {
    final db = await _database.instance;
    await db.update(
      'comics',
      <String, Object?>{'deleted_at': DateTime.now().toUtc().toIso8601String()},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> restoreComic(String id) async {
    final db = await _database.instance;
    await db.update(
      'comics',
      <String, Object?>{'deleted_at': null},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> permanentlyDeleteComic(String id) async {
    final db = await _database.instance;
    await db.delete(
      'comics',
      where: 'id = ? AND deleted_at IS NOT NULL',
      whereArgs: <Object?>[id],
    );
  }

  Future<List<ComicItemRecord>> loadItems(String comicId) async {
    final db = await _database.instance;
    final rows = await db.rawQuery(
      '''
      SELECT ci.id AS item_id, ci.comic_id, ci.position,
        ci.created_at AS item_created_at, a.*
      FROM comic_items ci
      JOIN assets a ON a.id = ci.asset_id
      WHERE ci.comic_id = ?
      ORDER BY ci.position, ci.created_at
    ''',
      <Object?>[comicId],
    );
    return rows
        .map(
          (row) => ComicItemRecord(
            id: row['item_id']! as String,
            comicId: row['comic_id']! as String,
            position: row['position']! as int,
            createdAt: DateTime.parse(row['item_created_at']! as String),
            asset: AssetRecord.fromMap(row),
          ),
        )
        .toList(growable: false);
  }

  Future<AssetRecord?> findAssetByHash(String hash) async {
    final db = await _database.instance;
    final rows = await db.query(
      'assets',
      where: 'content_hash = ?',
      whereArgs: <Object?>[hash],
      limit: 1,
    );
    return rows.isEmpty ? null : AssetRecord.fromMap(rows.first);
  }

  Future<bool> comicContainsAsset(String comicId, String assetId) async {
    final db = await _database.instance;
    final rows = await db.rawQuery(
      'SELECT 1 FROM comic_items WHERE comic_id = ? AND asset_id = ? LIMIT 1',
      <Object?>[comicId, assetId],
    );
    return rows.isNotEmpty;
  }

  Future<int> itemCount(String comicId) async {
    final db = await _database.instance;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM comic_items WHERE comic_id = ?',
      <Object?>[comicId],
    );
    return rows.first['count']! as int;
  }

  Future<void> attachAsset({
    required String comicId,
    required AssetRecord asset,
  }) async {
    final db = await _database.instance;
    await db.transaction((txn) async {
      final countRows = await txn.rawQuery(
        'SELECT COUNT(*) AS count FROM comic_items WHERE comic_id = ?',
        <Object?>[comicId],
      );
      final count = countRows.first['count']! as int;
      if (count >= maxItemsPerComic) {
        throw StateError('每本漫画最多可包含 $maxItemsPerComic 张图片');
      }
      await txn.insert(
        'assets',
        asset.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      final canonical = await txn.query(
        'assets',
        columns: <String>['id'],
        where: 'content_hash = ?',
        whereArgs: <Object?>[asset.contentHash],
        limit: 1,
      );
      await txn.insert('comic_items', <String, Object?>{
        'id': _uuid.v4(),
        'comic_id': comicId,
        'asset_id': canonical.first['id'],
        'position': count,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      await txn.update(
        'comics',
        <String, Object?>{
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: <Object?>[comicId],
      );
    });
  }

  Future<void> reorderItems(String comicId, List<String> itemIds) async {
    final db = await _database.instance;
    await db.transaction((txn) async {
      for (var index = 0; index < itemIds.length; index++) {
        await txn.update(
          'comic_items',
          <String, Object?>{'position': index},
          where: 'id = ? AND comic_id = ?',
          whereArgs: <Object?>[itemIds[index], comicId],
        );
      }
      await txn.update(
        'comics',
        <String, Object?>{
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: <Object?>[comicId],
      );
    });
  }

  Future<void> applyItemEdits({
    required String comicId,
    required List<String> orderedItemIds,
    required List<String> removedItemIds,
    String? coverAssetId,
  }) async {
    final db = await _database.instance;
    await db.transaction((txn) async {
      for (final id in removedItemIds) {
        await txn.delete(
          'comic_items',
          where: 'id = ? AND comic_id = ?',
          whereArgs: <Object?>[id, comicId],
        );
      }
      for (var index = 0; index < orderedItemIds.length; index++) {
        await txn.update(
          'comic_items',
          <String, Object?>{'position': index},
          where: 'id = ? AND comic_id = ?',
          whereArgs: <Object?>[orderedItemIds[index], comicId],
        );
      }
      if (coverAssetId != null) {
        final coverExists = await txn.rawQuery(
          'SELECT 1 FROM comic_items WHERE comic_id = ? AND asset_id = ? LIMIT 1',
          <Object?>[comicId, coverAssetId],
        );
        await txn.update(
          'comics',
          <String, Object?>{
            'cover_asset_id': coverExists.isEmpty ? null : coverAssetId,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: <Object?>[comicId],
        );
      }
    });
  }

  Future<void> removeItem(String itemId) async {
    final db = await _database.instance;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'comic_items',
        columns: <String>['comic_id'],
        where: 'id = ?',
        whereArgs: <Object?>[itemId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final comicId = rows.first['comic_id']! as String;
      await txn.delete(
        'comic_items',
        where: 'id = ?',
        whereArgs: <Object?>[itemId],
      );
      final remaining = await txn.query(
        'comic_items',
        columns: <String>['id'],
        where: 'comic_id = ?',
        whereArgs: <Object?>[comicId],
        orderBy: 'position, created_at',
      );
      for (var index = 0; index < remaining.length; index++) {
        await txn.update(
          'comic_items',
          <String, Object?>{'position': index},
          where: 'id = ?',
          whereArgs: <Object?>[remaining[index]['id']],
        );
      }
    });
  }

  Future<void> setCover(String comicId, String assetId) async {
    final db = await _database.instance;
    await db.update(
      'comics',
      <String, Object?>{
        'cover_asset_id': assetId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[comicId],
    );
  }

  Future<void> reorderComics(List<String> comicIds) async {
    final db = await _database.instance;
    await db.transaction((txn) async {
      for (var index = 0; index < comicIds.length; index++) {
        await txn.update(
          'comics',
          <String, Object?>{'sort_index': index},
          where: 'id = ?',
          whereArgs: <Object?>[comicIds[index]],
        );
      }
    });
  }

  Future<void> saveProgress(String comicId, int position, double offset) async {
    final db = await _database.instance;
    await db.update(
      'comics',
      <String, Object?>{
        'last_read_position': position,
        'last_read_offset': offset,
      },
      where: 'id = ?',
      whereArgs: <Object?>[comicId],
    );
  }

  Future<ReaderPreferences> loadPreferences() async {
    final db = await _database.instance;
    final rows = await db.query('settings');
    final values = <String, String>{
      for (final row in rows) row['key']! as String: row['value']! as String,
    };
    final themeName = values['theme'] ?? AppThemePreference.system.name;
    return ReaderPreferences(
      imageGap: double.tryParse(values['image_gap'] ?? '') ?? 10,
      showPageNumber: values['show_page_number'] != 'false',
      rememberProgress: values['remember_progress'] != 'false',
      theme: AppThemePreference.values.firstWhere(
        (value) => value.name == themeName,
        orElse: () => AppThemePreference.system,
      ),
    );
  }

  Future<void> savePreferences(ReaderPreferences preferences) async {
    final db = await _database.instance;
    final values = <String, String>{
      'image_gap': preferences.imageGap.toString(),
      'show_page_number': preferences.showPageNumber.toString(),
      'remember_progress': preferences.rememberProgress.toString(),
      'theme': preferences.theme.name,
    };
    await db.transaction((txn) async {
      for (final entry in values.entries) {
        await txn.insert('settings', <String, Object?>{
          'key': entry.key,
          'value': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<LibraryStats> loadStats({required int thumbnailBytes}) async {
    final db = await _database.instance;
    final rows = await db.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM comics) AS comic_count,
        (SELECT COUNT(*) FROM comic_items) AS reference_count,
        (SELECT COUNT(*) FROM assets) AS asset_count,
        (SELECT COALESCE(SUM(byte_size), 0) FROM assets) AS original_bytes,
        (SELECT COALESCE(SUM(a.byte_size), 0) FROM assets a
          WHERE NOT EXISTS (SELECT 1 FROM comic_items ci WHERE ci.asset_id = a.id)) AS orphan_bytes,
        (SELECT COUNT(*) FROM assets a
          WHERE NOT EXISTS (SELECT 1 FROM comic_items ci WHERE ci.asset_id = a.id)) AS orphan_count
    ''');
    final row = rows.first;
    return LibraryStats(
      comicCount: row['comic_count']! as int,
      referenceCount: row['reference_count']! as int,
      assetCount: row['asset_count']! as int,
      originalBytes: row['original_bytes']! as int,
      thumbnailBytes: thumbnailBytes,
      orphanBytes: row['orphan_bytes']! as int,
      orphanCount: row['orphan_count']! as int,
    );
  }

  Future<List<AssetRecord>> orphanedAssets() async {
    final db = await _database.instance;
    final rows = await db.rawQuery('''
      SELECT a.* FROM assets a
      WHERE NOT EXISTS (SELECT 1 FROM comic_items ci WHERE ci.asset_id = a.id)
    ''');
    return rows.map(AssetRecord.fromMap).toList(growable: false);
  }

  Future<List<AssetRecord>> allAssets() async {
    final db = await _database.instance;
    final rows = await db.query('assets', orderBy: 'created_at');
    return rows.map(AssetRecord.fromMap).toList(growable: false);
  }

  Future<void> deleteOrphanRecords(List<String> assetIds) async {
    if (assetIds.isEmpty) return;
    final db = await _database.instance;
    await db.transaction((txn) async {
      for (final id in assetIds) {
        await txn.delete('assets', where: 'id = ?', whereArgs: <Object?>[id]);
      }
    });
  }

  Future<Map<String, Object?>> exportManifest() async {
    final db = await _database.instance;
    return <String, Object?>{
      'format': 'private-manga-reader-backup',
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'comics': await db.query('comics', orderBy: 'sort_index'),
      'assets': await db.query('assets'),
      'comicItems': await db.query(
        'comic_items',
        orderBy: 'comic_id, position',
      ),
      'settings': await db.query('settings'),
    };
  }

  Future<void> replaceFromManifest(Map<String, Object?> manifest) async {
    if (manifest['format'] != 'private-manga-reader-backup' ||
        manifest['version'] != 1) {
      throw const FormatException('不支持的备份格式');
    }
    final db = await _database.instance;
    final assets = _rows(manifest['assets']);
    final comics = _rows(manifest['comics']);
    final items = _rows(manifest['comicItems']);
    final settings = _rows(manifest['settings']);
    await db.transaction((txn) async {
      await txn.delete('comic_items');
      await txn.delete('comics');
      await txn.delete('assets');
      await txn.delete('settings');
      for (final row in assets) {
        await txn.insert('assets', row);
      }
      for (final row in comics) {
        await txn.insert('comics', row);
      }
      for (final row in items) {
        await txn.insert('comic_items', row);
      }
      for (final row in settings) {
        await txn.insert('settings', row);
      }
    });
  }

  List<Map<String, Object?>> _rows(Object? value) {
    if (value is! List) throw const FormatException('备份清单缺少数据表');
    return value
        .map((row) {
          if (row is! Map) throw const FormatException('备份数据表结构错误');
          return row.map((key, value) => MapEntry(key.toString(), value));
        })
        .toList(growable: false);
  }

  String encodeManifest(Map<String, Object?> manifest) =>
      const JsonEncoder.withIndent('  ').convert(manifest);
}

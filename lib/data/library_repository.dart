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
      'folder_id': null,
      'is_private': 0,
      'is_pinned': 0,
      'read_status': ReadingStatus.unread.name,
      'last_read_at': null,
      'sort_index': comic.sortIndex,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
      'last_read_position': 0,
      'last_read_offset': 0.0,
      'deleted_at': null,
    });
    return comic;
  }

  Future<List<ShelfFolder>> loadFolders() async {
    final db = await _database.instance;
    final rows = await db.query(
      'shelf_folders',
      orderBy: 'sort_index, created_at',
    );
    return rows.map(ShelfFolder.fromMap).toList(growable: false);
  }

  Future<List<ShelfEntry>> loadShelfEntries() async {
    final db = await _database.instance;
    await db.transaction(_repairShelfEntries);
    final rows = await db.query(
      'shelf_entries',
      orderBy: 'scope, sort_index, created_at',
    );
    return rows.map(ShelfEntry.fromMap).toList(growable: false);
  }

  Future<void> _repairShelfEntries(Transaction txn) async {
    final folders = await txn.query(
      'shelf_folders',
      columns: <String>['id', 'is_private'],
      orderBy: 'sort_index, created_at',
    );
    final comics = await txn.query(
      'comics',
      columns: <String>['id', 'is_private'],
      where: 'folder_id IS NULL AND deleted_at IS NULL',
      orderBy: 'sort_index, created_at',
    );
    final desired = <String, Map<String, Object?>>{};
    for (final row in folders) {
      final id = row['id']! as String;
      desired['folder:$id'] = <String, Object?>{
        'entity_type': 'folder',
        'entity_id': id,
        'scope': ((row['is_private'] as int?) ?? 0) == 1 ? 'private' : 'root',
      };
    }
    for (final row in comics) {
      final id = row['id']! as String;
      desired['comic:$id'] = <String, Object?>{
        'entity_type': 'comic',
        'entity_id': id,
        'scope': ((row['is_private'] as int?) ?? 0) == 1 ? 'private' : 'root',
      };
    }

    final existing = await txn.query('shelf_entries');
    final existingByKey = <String, Map<String, Object?>>{
      for (final row in existing)
        '${row['entity_type']}:${row['entity_id']}': row,
    };
    for (final entry in existingByKey.entries) {
      if (!desired.containsKey(entry.key)) {
        await txn.delete(
          'shelf_entries',
          where: 'entity_type = ? AND entity_id = ?',
          whereArgs: <Object?>[
            entry.value['entity_type'],
            entry.value['entity_id'],
          ],
        );
      }
    }

    final nextByScope = <String, int>{'root': 0, 'private': 0};
    final maxima = await txn.rawQuery(
      'SELECT scope, COALESCE(MAX(sort_index), -1) + 1 AS next_index '
      'FROM shelf_entries GROUP BY scope',
    );
    for (final row in maxima) {
      nextByScope[row['scope']! as String] = row['next_index']! as int;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    for (final entry in desired.entries) {
      final row = entry.value;
      final scope = row['scope']! as String;
      final current = existingByKey[entry.key];
      if (current == null) {
        await txn.insert('shelf_entries', <String, Object?>{
          ...row,
          'sort_index': nextByScope[scope]!,
          'created_at': now,
          'updated_at': now,
        });
        nextByScope[scope] = nextByScope[scope]! + 1;
      } else if (current['scope'] != scope) {
        await txn.update(
          'shelf_entries',
          <String, Object?>{
            'scope': scope,
            'sort_index': nextByScope[scope]!,
            'updated_at': now,
          },
          where: 'entity_type = ? AND entity_id = ?',
          whereArgs: <Object?>[row['entity_type'], row['entity_id']],
        );
        nextByScope[scope] = nextByScope[scope]! + 1;
      }
    }
  }

  Future<void> reorderShelfEntries(
    String scope,
    List<String> orderedKeys,
  ) async {
    final db = await _database.instance;
    await db.transaction((txn) async {
      await _repairShelfEntries(txn);
      final rows = await txn.query(
        'shelf_entries',
        columns: <String>['entity_type', 'entity_id'],
        where: 'scope = ?',
        whereArgs: <Object?>[scope],
      );
      final currentKeys = rows
          .map((row) => '${row['entity_type']}:${row['entity_id']}')
          .toSet();
      if (currentKeys.length != orderedKeys.length ||
          !currentKeys.containsAll(orderedKeys)) {
        throw StateError('书架排序项与当前数据不一致');
      }
      final now = DateTime.now().toUtc().toIso8601String();
      for (var index = 0; index < orderedKeys.length; index++) {
        final parts = orderedKeys[index].split(':');
        if (parts.length != 2) throw const FormatException('书架排序键无效');
        await txn.update(
          'shelf_entries',
          <String, Object?>{'sort_index': index, 'updated_at': now},
          where: 'entity_type = ? AND entity_id = ? AND scope = ?',
          whereArgs: <Object?>[parts[0], parts[1], scope],
        );
      }
    });
  }

  Future<ShelfFolder> createFolder(String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(name, 'name', '文件夹名称不能为空');
    }
    final db = await _database.instance;
    final now = DateTime.now().toUtc();
    final indexRows = await db.rawQuery(
      'SELECT COALESCE(MAX(sort_index), -1) + 1 AS next_index FROM shelf_folders',
    );
    final folder = ShelfFolder(
      id: _uuid.v4(),
      name: normalized,
      sortIndex: indexRows.first['next_index']! as int,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('shelf_folders', <String, Object?>{
      'id': folder.id,
      'name': folder.name,
      'is_private': 0,
      'sort_index': folder.sortIndex,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    return folder;
  }

  Future<void> moveComicsToFolder(
    List<String> comicIds,
    String? folderId,
  ) async {
    if (comicIds.isEmpty) return;
    final db = await _database.instance;
    await db.transaction((txn) async {
      if (folderId != null) {
        final folder = await txn.query(
          'shelf_folders',
          columns: <String>['id', 'is_private'],
          where: 'id = ?',
          whereArgs: <Object?>[folderId],
          limit: 1,
        );
        if (folder.isEmpty) throw StateError('目标文件夹不存在');
      }
      final updatedAt = DateTime.now().toUtc().toIso8601String();
      for (final comicId in comicIds) {
        await txn.update(
          'comics',
          <String, Object?>{
            'folder_id': folderId,
            if (folderId != null) 'is_private': 0,
            'updated_at': updatedAt,
          },
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: <Object?>[comicId],
        );
      }
    });
  }

  Future<void> deleteFolder(String folderId) async {
    final db = await _database.instance;
    await db.transaction((txn) async {
      final folders = await txn.query(
        'shelf_folders',
        columns: <String>['is_private'],
        where: 'id = ?',
        whereArgs: <Object?>[folderId],
        limit: 1,
      );
      final wasPrivate =
          folders.isNotEmpty && (folders.first['is_private'] as int? ?? 0) == 1;
      await txn.update(
        'comics',
        <String, Object?>{'folder_id': null, if (wasPrivate) 'is_private': 1},
        where: 'folder_id = ?',
        whereArgs: <Object?>[folderId],
      );
      await txn.delete(
        'shelf_folders',
        where: 'id = ?',
        whereArgs: <Object?>[folderId],
      );
    });
  }

  Future<void> renameFolder(String folderId, String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(name, 'name', '文件夹名称不能为空');
    }
    final db = await _database.instance;
    await db.update(
      'shelf_folders',
      <String, Object?>{
        'name': normalized,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[folderId],
    );
  }

  Future<void> setFolderPrivate(String folderId, bool value) async {
    final db = await _database.instance;
    await db.update(
      'shelf_folders',
      <String, Object?>{
        'is_private': value ? 1 : 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[folderId],
    );
  }

  Future<void> setComicPrivate(String comicId, bool value) async {
    final db = await _database.instance;
    await db.update(
      'comics',
      <String, Object?>{
        'is_private': value ? 1 : 0,
        if (value) 'folder_id': null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[comicId],
    );
  }

  Future<void> setComicPinned(String comicId, bool value) async {
    final db = await _database.instance;
    await db.update(
      'comics',
      <String, Object?>{
        'is_pinned': value ? 1 : 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[comicId],
    );
  }

  Future<void> setReadingStatus(String comicId, ReadingStatus status) async {
    final db = await _database.instance;
    await db.update(
      'comics',
      <String, Object?>{
        'read_status': status.name,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[comicId],
    );
  }

  Future<PageBookmark> saveBookmark({
    required String comicId,
    required String itemId,
    String note = '',
  }) async {
    final db = await _database.instance;
    return db.transaction((txn) async {
      final page = await txn.query(
        'comic_items',
        columns: <String>['position'],
        where: 'id = ? AND comic_id = ?',
        whereArgs: <Object?>[itemId, comicId],
        limit: 1,
      );
      if (page.isEmpty) throw StateError('书签页面不存在');
      final existing = await txn.query(
        'page_bookmarks',
        where: 'item_id = ?',
        whereArgs: <Object?>[itemId],
        limit: 1,
      );
      final now = DateTime.now().toUtc();
      final id = existing.isEmpty
          ? _uuid.v4()
          : existing.first['id']! as String;
      final createdAt = existing.isEmpty
          ? now
          : DateTime.parse(existing.first['created_at']! as String);
      await txn.insert('page_bookmarks', <String, Object?>{
        'id': id,
        'comic_id': comicId,
        'item_id': itemId,
        'note': note.trim(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': now.toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return PageBookmark(
        id: id,
        comicId: comicId,
        itemId: itemId,
        position: page.first['position']! as int,
        note: note.trim(),
        createdAt: createdAt,
        updatedAt: now,
      );
    });
  }

  Future<List<PageBookmark>> loadBookmarks(String comicId) async {
    final db = await _database.instance;
    final rows = await db.rawQuery(
      '''
      SELECT b.*, ci.position
      FROM page_bookmarks b
      JOIN comic_items ci ON ci.id = b.item_id
      WHERE b.comic_id = ?
      ORDER BY ci.position, b.created_at
      ''',
      <Object?>[comicId],
    );
    return rows.map(PageBookmark.fromMap).toList(growable: false);
  }

  Future<void> deleteBookmark(String bookmarkId) async {
    final db = await _database.instance;
    await db.delete(
      'page_bookmarks',
      where: 'id = ?',
      whereArgs: <Object?>[bookmarkId],
    );
  }

  Future<List<ReadingList>> loadReadingLists() async {
    final db = await _database.instance;
    final rows = await db.query(
      'reading_lists',
      orderBy: 'sort_index, created_at',
    );
    return rows.map(ReadingList.fromMap).toList(growable: false);
  }

  Future<ReadingList> createReadingList(String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) throw ArgumentError.value(name, 'name', '书单名称不能为空');
    final db = await _database.instance;
    final now = DateTime.now().toUtc();
    final indexRows = await db.rawQuery(
      'SELECT COALESCE(MAX(sort_index), -1) + 1 AS next_index FROM reading_lists',
    );
    final list = ReadingList(
      id: _uuid.v4(),
      name: normalized,
      sortIndex: indexRows.first['next_index']! as int,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('reading_lists', <String, Object?>{
      'id': list.id,
      'name': list.name,
      'sort_index': list.sortIndex,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    return list;
  }

  Future<void> addComicsToReadingList(
    String listId,
    List<String> comicIds,
  ) async {
    if (comicIds.isEmpty) return;
    final db = await _database.instance;
    await db.transaction((txn) async {
      final list = await txn.query(
        'reading_lists',
        columns: <String>['id'],
        where: 'id = ?',
        whereArgs: <Object?>[listId],
        limit: 1,
      );
      if (list.isEmpty) throw StateError('目标书单不存在');
      final nextRows = await txn.rawQuery(
        'SELECT COALESCE(MAX(sort_index), -1) + 1 AS next_index '
        'FROM reading_list_items WHERE list_id = ?',
        <Object?>[listId],
      );
      var next = nextRows.first['next_index']! as int;
      final createdAt = DateTime.now().toUtc().toIso8601String();
      for (final comicId in comicIds) {
        final inserted = await txn
            .insert('reading_list_items', <String, Object?>{
              'list_id': listId,
              'comic_id': comicId,
              'sort_index': next,
              'created_at': createdAt,
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
        if (inserted != 0) next++;
      }
    });
  }

  Future<List<String>> loadReadingListComicIds(String listId) async {
    final db = await _database.instance;
    final rows = await db.query(
      'reading_list_items',
      columns: <String>['comic_id'],
      where: 'list_id = ?',
      whereArgs: <Object?>[listId],
      orderBy: 'sort_index, created_at',
    );
    return rows
        .map((row) => row['comic_id']! as String)
        .toList(growable: false);
  }

  Future<void> deleteReadingList(String listId) async {
    final db = await _database.instance;
    await db.delete(
      'reading_lists',
      where: 'id = ?',
      whereArgs: <Object?>[listId],
    );
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
      String? persistedCover;
      if (coverAssetId != null) {
        final coverExists = await txn.rawQuery(
          'SELECT 1 FROM comic_items WHERE comic_id = ? AND asset_id = ? LIMIT 1',
          <Object?>[comicId, coverAssetId],
        );
        persistedCover = coverExists.isEmpty ? null : coverAssetId;
      }
      await txn.update(
        'comics',
        <String, Object?>{
          'cover_asset_id': persistedCover,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: <Object?>[comicId],
      );
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
    final now = DateTime.now().toUtc().toIso8601String();
    await db.update(
      'comics',
      <String, Object?>{
        'last_read_position': position,
        'last_read_offset': offset,
        'last_read_at': now,
        'read_status': ReadingStatus.reading.name,
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
      readerBrightness:
          (double.tryParse(values['reader_brightness'] ?? '') ?? 0.72).clamp(
            0.05,
            1,
          ),
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
      'reader_brightness': preferences.readerBrightness.toString(),
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
    final remoteBooks =
        (await db.query('remote_books', orderBy: 'source_id, sort_index'))
            .map((row) {
              return <String, Object?>{
                ...row,
                'page_count': 0,
                'cover_relative_path': null,
                'cached_version': null,
                'cached_at': null,
              };
            })
            .toList(growable: false);
    return <String, Object?>{
      'format': 'private-manga-reader-backup',
      'version': 4,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'comics': await db.query('comics', orderBy: 'sort_index'),
      'assets': await db.query('assets'),
      'comicItems': await db.query(
        'comic_items',
        orderBy: 'comic_id, position',
      ),
      'settings': await db.query('settings'),
      'shelfFolders': await db.query(
        'shelf_folders',
        orderBy: 'sort_index, created_at',
      ),
      'shelfEntries': await db.query(
        'shelf_entries',
        orderBy: 'scope, sort_index, created_at',
      ),
      'pageBookmarks': await db.query(
        'page_bookmarks',
        orderBy: 'comic_id, created_at',
      ),
      'readingLists': await db.query(
        'reading_lists',
        orderBy: 'sort_index, created_at',
      ),
      'readingListItems': await db.query(
        'reading_list_items',
        orderBy: 'list_id, sort_index',
      ),
      'networkSources': await db.query(
        'network_sources',
        orderBy: 'created_at',
      ),
      'remoteBooks': remoteBooks,
      'remotePages': const <Map<String, Object?>>[],
    };
  }

  Future<void> replaceFromManifest(Map<String, Object?> manifest) async {
    final version = manifest['version'];
    if (manifest['format'] != 'private-manga-reader-backup' ||
        (version != 1 && version != 2 && version != 3 && version != 4)) {
      throw const FormatException('不支持的备份格式');
    }
    final db = await _database.instance;
    final assets = _rows(manifest['assets']);
    final comics = _rows(manifest['comics']);
    final items = _rows(manifest['comicItems']);
    final settings = _rows(manifest['settings']);
    final folders = version == 3 || version == 4
        ? _rows(manifest['shelfFolders'])
        : const <Map<String, Object?>>[];
    final shelfEntries = version == 4
        ? _rows(manifest['shelfEntries'])
        : const <Map<String, Object?>>[];
    final bookmarks = version == 3 || version == 4
        ? _rows(manifest['pageBookmarks'])
        : const <Map<String, Object?>>[];
    final readingLists = version == 3 || version == 4
        ? _rows(manifest['readingLists'])
        : const <Map<String, Object?>>[];
    final readingListItems = version == 3 || version == 4
        ? _rows(manifest['readingListItems'])
        : const <Map<String, Object?>>[];
    final networkSources = version == 2 || version == 3 || version == 4
        ? _rows(manifest['networkSources'])
        : const <Map<String, Object?>>[];
    final remoteBooks = version == 2 || version == 3 || version == 4
        ? _rows(manifest['remoteBooks'])
        : const <Map<String, Object?>>[];
    final remotePages = version == 2 || version == 3 || version == 4
        ? _rows(manifest['remotePages'])
        : const <Map<String, Object?>>[];
    await db.transaction((txn) async {
      await txn.delete('shelf_entries');
      await txn.delete('reading_list_items');
      await txn.delete('reading_lists');
      await txn.delete('page_bookmarks');
      if (version == 2 || version == 3 || version == 4) {
        await txn.delete('remote_pages');
        await txn.delete('remote_books');
        await txn.delete('network_sources');
      }
      await txn.delete('comic_items');
      await txn.delete('comics');
      await txn.delete('shelf_folders');
      await txn.delete('assets');
      await txn.delete('settings');
      for (final row in assets) {
        await txn.insert('assets', row);
      }
      for (final row in folders) {
        await txn.insert('shelf_folders', row);
      }
      for (final row in comics) {
        await txn.insert('comics', row);
      }
      for (final row in shelfEntries) {
        await txn.insert('shelf_entries', row);
      }
      for (final row in items) {
        await txn.insert('comic_items', row);
      }
      for (final row in bookmarks) {
        await txn.insert('page_bookmarks', row);
      }
      for (final row in readingLists) {
        await txn.insert('reading_lists', row);
      }
      for (final row in readingListItems) {
        await txn.insert('reading_list_items', row);
      }
      for (final row in settings) {
        await txn.insert('settings', row);
      }
      for (final row in networkSources) {
        await txn.insert('network_sources', row);
      }
      for (final row in remoteBooks) {
        await txn.insert('remote_books', row);
      }
      for (final row in remotePages) {
        await txn.insert('remote_pages', row);
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

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase({DatabaseFactory? factory, this.overridePath})
    : _factory = factory ?? databaseFactory;

  final DatabaseFactory _factory;
  final String? overridePath;
  Database? _database;
  static const schemaVersion = 5;

  Future<Database> get instance async {
    final existing = _database;
    if (existing != null && existing.isOpen) return existing;
    final path =
        overridePath ??
        p.join((await getApplicationSupportDirectory()).path, 'library.db');
    await _ensureMigrationSnapshot(path);
    _database = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
    return _database!;
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE assets (
        id TEXT PRIMARY KEY,
        content_hash TEXT NOT NULL UNIQUE,
        original_file_name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        extension TEXT NOT NULL,
        byte_size INTEGER NOT NULL,
        width INTEGER NOT NULL DEFAULT 0,
        height INTEGER NOT NULL DEFAULT 0,
        stored_path TEXT NOT NULL,
        thumbnail_path TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await _createShelfFolderSchema(db);
    await db.execute('''
      CREATE TABLE comics (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        cover_asset_id TEXT,
        folder_id TEXT,
        is_private INTEGER NOT NULL DEFAULT 0,
        is_pinned INTEGER NOT NULL DEFAULT 0,
        read_status TEXT NOT NULL DEFAULT 'unread',
        last_read_at TEXT,
        sort_index INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        last_read_position INTEGER NOT NULL DEFAULT 0,
        last_read_offset REAL NOT NULL DEFAULT 0,
        deleted_at TEXT,
        FOREIGN KEY(cover_asset_id) REFERENCES assets(id) ON DELETE SET NULL,
        FOREIGN KEY(folder_id) REFERENCES shelf_folders(id) ON DELETE SET NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_comics_folder ON comics(folder_id)');
    await db.execute('''
      CREATE TABLE comic_items (
        id TEXT PRIMARY KEY,
        comic_id TEXT NOT NULL,
        asset_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY(comic_id) REFERENCES comics(id) ON DELETE CASCADE,
        FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE RESTRICT
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_items_comic_position ON comic_items(comic_id, position)',
    );
    await db.execute('CREATE INDEX idx_items_asset ON comic_items(asset_id)');
    await _createBookmarkSchema(db);
    await _createReadingListSchema(db);
    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await _createNetworkSchema(db);
  }

  Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE comics ADD COLUMN deleted_at TEXT');
    }
    if (oldVersion < 3) {
      await _createNetworkSchema(db);
    }
    if (oldVersion < 4) {
      await _createShelfFolderSchema(db);
      await db.execute(
        'ALTER TABLE comics ADD COLUMN folder_id TEXT REFERENCES shelf_folders(id) ON DELETE SET NULL',
      );
      await db.execute(
        'ALTER TABLE comics ADD COLUMN is_private INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE comics ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        "ALTER TABLE comics ADD COLUMN read_status TEXT NOT NULL DEFAULT 'unread'",
      );
      await db.execute('ALTER TABLE comics ADD COLUMN last_read_at TEXT');
      await db.execute('CREATE INDEX idx_comics_folder ON comics(folder_id)');
      await _createBookmarkSchema(db);
      await _createReadingListSchema(db);
    }
    if (oldVersion >= 4 && oldVersion < 5) {
      await db.execute(
        'ALTER TABLE shelf_folders ADD COLUMN is_private INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion >= 3 && oldVersion < 5) {
      await db.execute(
        "ALTER TABLE network_sources ADD COLUMN connection_state TEXT NOT NULL DEFAULT 'unknown'",
      );
      await db.execute(
        'ALTER TABLE network_sources ADD COLUMN last_success_at TEXT',
      );
      await db.execute(
        'ALTER TABLE network_sources ADD COLUMN last_sync_at TEXT',
      );
      await db.execute(
        'ALTER TABLE network_sources ADD COLUMN last_error TEXT',
      );
    }
  }

  Future<void> _createShelfFolderSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS shelf_folders (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        is_private INTEGER NOT NULL DEFAULT 0,
        sort_index INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  Future<void> _createBookmarkSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS page_bookmarks (
        id TEXT PRIMARY KEY,
        comic_id TEXT NOT NULL,
        item_id TEXT NOT NULL UNIQUE,
        note TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(comic_id) REFERENCES comics(id) ON DELETE CASCADE,
        FOREIGN KEY(item_id) REFERENCES comic_items(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_bookmarks_comic ON page_bookmarks(comic_id, created_at)',
    );
  }

  Future<void> _createReadingListSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS reading_lists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        sort_index INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS reading_list_items (
        list_id TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        sort_index INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY(list_id, comic_id),
        FOREIGN KEY(list_id) REFERENCES reading_lists(id) ON DELETE CASCADE,
        FOREIGN KEY(comic_id) REFERENCES comics(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_reading_list_items_sort '
      'ON reading_list_items(list_id, sort_index)',
    );
  }

  Future<void> _createNetworkSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE network_sources (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        endpoint TEXT NOT NULL,
        root_path TEXT NOT NULL,
        username TEXT NOT NULL DEFAULT '',
        connection_state TEXT NOT NULL DEFAULT 'unknown',
        last_success_at TEXT,
        last_sync_at TEXT,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE remote_books (
        id TEXT PRIMARY KEY,
        source_id TEXT NOT NULL,
        title TEXT NOT NULL,
        remote_uri TEXT NOT NULL,
        media_type TEXT NOT NULL,
        etag TEXT NOT NULL DEFAULT '',
        byte_size INTEGER NOT NULL DEFAULT 0,
        sort_index INTEGER NOT NULL,
        page_count INTEGER NOT NULL DEFAULT 0,
        cover_relative_path TEXT,
        last_read_position INTEGER NOT NULL DEFAULT 0,
        last_read_offset REAL NOT NULL DEFAULT 0,
        cached_version TEXT,
        cached_at TEXT,
        is_available INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(source_id, remote_uri),
        FOREIGN KEY(source_id) REFERENCES network_sources(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_remote_books_source_sort '
      'ON remote_books(source_id, sort_index)',
    );
    await db.execute('''
      CREATE TABLE remote_pages (
        id TEXT PRIMARY KEY,
        book_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        relative_path TEXT NOT NULL,
        original_name TEXT NOT NULL,
        byte_size INTEGER NOT NULL,
        width INTEGER NOT NULL DEFAULT 0,
        height INTEGER NOT NULL DEFAULT 0,
        UNIQUE(book_id, position),
        FOREIGN KEY(book_id) REFERENCES remote_books(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_remote_pages_book_position '
      'ON remote_pages(book_id, position)',
    );
  }

  Future<void> _ensureMigrationSnapshot(String databasePath) async {
    final source = File(databasePath);
    if (!await source.exists()) return;
    final oldVersion = await _readUserVersion(source);
    if (oldVersion <= 0 || oldVersion >= schemaVersion) return;
    final snapshot = File('$databasePath.pre-v$schemaVersion');
    if (await snapshot.exists()) return;
    await snapshot.parent.create(recursive: true);
    await source.copy(snapshot.path);
    for (final suffix in const <String>['-wal', '-shm']) {
      final companion = File('$databasePath$suffix');
      if (await companion.exists()) {
        await companion.copy('${snapshot.path}$suffix');
      }
    }
  }

  Future<int> _readUserVersion(File database) async {
    final reader = await database.open();
    try {
      if (await reader.length() < 64) return 0;
      await reader.setPosition(60);
      final bytes = await reader.read(4);
      if (bytes.length != 4) return 0;
      return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    } finally {
      await reader.close();
    }
  }
}

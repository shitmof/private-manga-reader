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

  Future<Database> get instance async {
    final existing = _database;
    if (existing != null && existing.isOpen) return existing;
    final path = overridePath ??
        p.join((await getApplicationSupportDirectory()).path, 'library.db');
    await _ensureMigrationSnapshot(path);
    _database = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
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
    await db.execute('''
      CREATE TABLE comics (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        cover_asset_id TEXT,
        sort_index INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        last_read_position INTEGER NOT NULL DEFAULT 0,
        last_read_offset REAL NOT NULL DEFAULT 0,
        deleted_at TEXT,
        FOREIGN KEY(cover_asset_id) REFERENCES assets(id) ON DELETE SET NULL
      )
    ''');
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
    await db.execute(
      'CREATE INDEX idx_items_asset ON comic_items(asset_id)',
    );
    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE comics ADD COLUMN deleted_at TEXT');
    }
  }

  Future<void> _ensureMigrationSnapshot(String databasePath) async {
    final source = File(databasePath);
    final snapshot = File('$databasePath.pre-v2');
    if (!await source.exists() || await snapshot.exists()) return;
    await snapshot.parent.create(recursive: true);
    await source.copy(snapshot.path);
    for (final suffix in const <String>['-wal', '-shm']) {
      final companion = File('$databasePath$suffix');
      if (await companion.exists()) {
        await companion.copy('${snapshot.path}$suffix');
      }
    }
  }
}

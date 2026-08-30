enum AppThemePreference { system, light, dark }

enum ReadingStatus { unread, reading, completed, paused }

enum ShelfEntryKind { folder, comic }

class ShelfEntry {
  const ShelfEntry({
    required this.kind,
    required this.entityId,
    required this.scope,
    required this.sortIndex,
  });

  final ShelfEntryKind kind;
  final String entityId;
  final String scope;
  final int sortIndex;

  String get key => '${kind.name}:$entityId';

  factory ShelfEntry.fromMap(Map<String, Object?> map) => ShelfEntry(
    kind: ShelfEntryKind.values.byName(map['entity_type']! as String),
    entityId: map['entity_id']! as String,
    scope: map['scope']! as String,
    sortIndex: map['sort_index']! as int,
  );
}

class Comic {
  const Comic({
    required this.id,
    required this.title,
    required this.sortIndex,
    required this.createdAt,
    required this.updatedAt,
    required this.lastReadPosition,
    required this.lastReadOffset,
    this.coverAssetId,
    this.folderId,
    this.isPrivate = false,
    this.isPinned = false,
    this.readingStatus = ReadingStatus.unread,
    this.lastReadAt,
    this.deletedAt,
  });

  final String id;
  final String title;
  final String? coverAssetId;
  final String? folderId;
  final bool isPrivate;
  final bool isPinned;
  final ReadingStatus readingStatus;
  final DateTime? lastReadAt;
  final int sortIndex;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int lastReadPosition;
  final double lastReadOffset;
  final DateTime? deletedAt;

  factory Comic.fromMap(Map<String, Object?> map) => Comic(
    id: map['id']! as String,
    title: map['title']! as String,
    coverAssetId: map['cover_asset_id'] as String?,
    folderId: map['folder_id'] as String?,
    isPrivate: ((map['is_private'] as int?) ?? 0) == 1,
    isPinned: ((map['is_pinned'] as int?) ?? 0) == 1,
    readingStatus: ReadingStatus.values.firstWhere(
      (value) => value.name == (map['read_status'] as String? ?? 'unread'),
      orElse: () => ReadingStatus.unread,
    ),
    lastReadAt: map['last_read_at'] == null
        ? null
        : DateTime.parse(map['last_read_at']! as String),
    sortIndex: map['sort_index']! as int,
    createdAt: DateTime.parse(map['created_at']! as String),
    updatedAt: DateTime.parse(map['updated_at']! as String),
    lastReadPosition: map['last_read_position']! as int,
    lastReadOffset: (map['last_read_offset']! as num).toDouble(),
    deletedAt: map['deleted_at'] == null
        ? null
        : DateTime.parse(map['deleted_at']! as String),
  );
}

class ShelfFolder {
  const ShelfFolder({
    required this.id,
    required this.name,
    required this.sortIndex,
    required this.createdAt,
    required this.updatedAt,
    this.isPrivate = false,
  });

  final String id;
  final String name;
  final int sortIndex;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isPrivate;

  factory ShelfFolder.fromMap(Map<String, Object?> map) => ShelfFolder(
    id: map['id']! as String,
    name: map['name']! as String,
    sortIndex: map['sort_index']! as int,
    createdAt: DateTime.parse(map['created_at']! as String),
    updatedAt: DateTime.parse(map['updated_at']! as String),
    isPrivate: ((map['is_private'] as int?) ?? 0) == 1,
  );
}

class PageBookmark {
  const PageBookmark({
    required this.id,
    required this.comicId,
    required this.itemId,
    required this.position,
    required this.note,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String comicId;
  final String itemId;
  final int position;
  final String note;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory PageBookmark.fromMap(Map<String, Object?> map) => PageBookmark(
    id: map['id']! as String,
    comicId: map['comic_id']! as String,
    itemId: map['item_id']! as String,
    position: (map['position'] as int?) ?? 0,
    note: map['note']! as String,
    createdAt: DateTime.parse(map['created_at']! as String),
    updatedAt: DateTime.parse(map['updated_at']! as String),
  );
}

class ReadingList {
  const ReadingList({
    required this.id,
    required this.name,
    required this.sortIndex,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final int sortIndex;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ReadingList.fromMap(Map<String, Object?> map) => ReadingList(
    id: map['id']! as String,
    name: map['name']! as String,
    sortIndex: map['sort_index']! as int,
    createdAt: DateTime.parse(map['created_at']! as String),
    updatedAt: DateTime.parse(map['updated_at']! as String),
  );
}

class AssetRecord {
  const AssetRecord({
    required this.id,
    required this.contentHash,
    required this.originalFileName,
    required this.mimeType,
    required this.extension,
    required this.byteSize,
    required this.width,
    required this.height,
    required this.storedPath,
    required this.thumbnailPath,
    required this.createdAt,
  });

  final String id;
  final String contentHash;
  final String originalFileName;
  final String mimeType;
  final String extension;
  final int byteSize;
  final int width;
  final int height;
  final String storedPath;
  final String thumbnailPath;
  final DateTime createdAt;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'content_hash': contentHash,
    'original_file_name': originalFileName,
    'mime_type': mimeType,
    'extension': extension,
    'byte_size': byteSize,
    'width': width,
    'height': height,
    'stored_path': storedPath,
    'thumbnail_path': thumbnailPath,
    'created_at': createdAt.toIso8601String(),
  };

  factory AssetRecord.fromMap(Map<String, Object?> map) => AssetRecord(
    id: map['id']! as String,
    contentHash: map['content_hash']! as String,
    originalFileName: map['original_file_name']! as String,
    mimeType: map['mime_type']! as String,
    extension: map['extension']! as String,
    byteSize: map['byte_size']! as int,
    width: map['width']! as int,
    height: map['height']! as int,
    storedPath: map['stored_path']! as String,
    thumbnailPath: map['thumbnail_path']! as String,
    createdAt: DateTime.parse(map['created_at']! as String),
  );
}

class ComicItemRecord {
  const ComicItemRecord({
    required this.id,
    required this.comicId,
    required this.asset,
    required this.position,
    required this.createdAt,
  });

  final String id;
  final String comicId;
  final AssetRecord asset;
  final int position;
  final DateTime createdAt;
}

class ComicSummary {
  const ComicSummary({
    required this.comic,
    required this.itemCount,
    required this.totalBytes,
    this.coverStoredPath,
    this.coverThumbnailPath,
  });

  final Comic comic;
  final int itemCount;
  final int totalBytes;
  final String? coverStoredPath;
  final String? coverThumbnailPath;
}

class LibraryStats {
  const LibraryStats({
    required this.comicCount,
    required this.referenceCount,
    required this.assetCount,
    required this.originalBytes,
    required this.thumbnailBytes,
    required this.orphanBytes,
    required this.orphanCount,
  });

  final int comicCount;
  final int referenceCount;
  final int assetCount;
  final int originalBytes;
  final int thumbnailBytes;
  final int orphanBytes;
  final int orphanCount;
}

class ReaderPreferences {
  const ReaderPreferences({
    this.imageGap = 10,
    this.showPageNumber = true,
    this.rememberProgress = true,
    this.readerBrightness = 0.72,
    this.theme = AppThemePreference.system,
  });

  final double imageGap;
  final bool showPageNumber;
  final bool rememberProgress;
  final double readerBrightness;
  final AppThemePreference theme;

  ReaderPreferences copyWith({
    double? imageGap,
    bool? showPageNumber,
    bool? rememberProgress,
    double? readerBrightness,
    AppThemePreference? theme,
  }) => ReaderPreferences(
    imageGap: imageGap ?? this.imageGap,
    showPageNumber: showPageNumber ?? this.showPageNumber,
    rememberProgress: rememberProgress ?? this.rememberProgress,
    readerBrightness: readerBrightness ?? this.readerBrightness,
    theme: theme ?? this.theme,
  );
}

enum DuplicatePolicy { skip, keep }

enum NetworkSourceType { webdav, opds, smb }

enum NetworkConnectionState {
  unknown,
  connected,
  needsAuthentication,
  offline,
  unreachable,
}

class NetworkSource {
  const NetworkSource({
    required this.id,
    required this.name,
    required this.type,
    required this.endpoint,
    required this.rootPath,
    required this.username,
    required this.createdAt,
    required this.updatedAt,
    this.connectionState = NetworkConnectionState.unknown,
    this.lastSuccessAt,
    this.lastSyncAt,
    this.lastError,
  });

  final String id;
  final String name;
  final NetworkSourceType type;
  final String endpoint;
  final String rootPath;
  final String username;
  final DateTime createdAt;
  final DateTime updatedAt;
  final NetworkConnectionState connectionState;
  final DateTime? lastSuccessAt;
  final DateTime? lastSyncAt;
  final String? lastError;

  factory NetworkSource.fromMap(Map<String, Object?> map) => NetworkSource(
    id: map['id']! as String,
    name: map['name']! as String,
    type: NetworkSourceType.values.byName(map['type']! as String),
    endpoint: map['endpoint']! as String,
    rootPath: map['root_path']! as String,
    username: map['username']! as String,
    createdAt: DateTime.parse(map['created_at']! as String),
    updatedAt: DateTime.parse(map['updated_at']! as String),
    connectionState: NetworkConnectionState.values.firstWhere(
      (value) => value.name == map['connection_state'],
      orElse: () => NetworkConnectionState.unknown,
    ),
    lastSuccessAt: map['last_success_at'] == null
        ? null
        : DateTime.parse(map['last_success_at']! as String),
    lastSyncAt: map['last_sync_at'] == null
        ? null
        : DateTime.parse(map['last_sync_at']! as String),
    lastError: map['last_error'] as String?,
  );
}

class NetworkCredentials {
  const NetworkCredentials({
    this.username = '',
    this.password = '',
    this.domain = '',
  });

  final String username;
  final String password;
  final String domain;
}

class RemoteBookDiscovery {
  const RemoteBookDiscovery({
    required this.title,
    required this.remoteUri,
    required this.mediaType,
    required this.etag,
    required this.byteSize,
  });

  final String title;
  final String remoteUri;
  final String mediaType;
  final String etag;
  final int byteSize;
}

class RemoteBook {
  const RemoteBook({
    required this.id,
    required this.sourceId,
    required this.title,
    required this.remoteUri,
    required this.mediaType,
    required this.etag,
    required this.byteSize,
    required this.sortIndex,
    required this.pageCount,
    required this.lastReadPosition,
    required this.lastReadOffset,
    required this.isAvailable,
    required this.createdAt,
    required this.updatedAt,
    this.coverRelativePath,
    this.cachedVersion,
    this.cachedAt,
  });

  final String id;
  final String sourceId;
  final String title;
  final String remoteUri;
  final String mediaType;
  final String etag;
  final int byteSize;
  final int sortIndex;
  final int pageCount;
  final String? coverRelativePath;
  final int lastReadPosition;
  final double lastReadOffset;
  final String? cachedVersion;
  final DateTime? cachedAt;
  final bool isAvailable;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isCached => pageCount > 0 && cachedVersion == etag;

  factory RemoteBook.fromMap(Map<String, Object?> map) => RemoteBook(
    id: map['id']! as String,
    sourceId: map['source_id']! as String,
    title: map['title']! as String,
    remoteUri: map['remote_uri']! as String,
    mediaType: map['media_type']! as String,
    etag: map['etag']! as String,
    byteSize: map['byte_size']! as int,
    sortIndex: map['sort_index']! as int,
    pageCount: map['page_count']! as int,
    coverRelativePath: map['cover_relative_path'] as String?,
    lastReadPosition: map['last_read_position']! as int,
    lastReadOffset: (map['last_read_offset']! as num).toDouble(),
    cachedVersion: map['cached_version'] as String?,
    cachedAt: map['cached_at'] == null
        ? null
        : DateTime.parse(map['cached_at']! as String),
    isAvailable: (map['is_available']! as int) == 1,
    createdAt: DateTime.parse(map['created_at']! as String),
    updatedAt: DateTime.parse(map['updated_at']! as String),
  );
}

class RemotePage {
  const RemotePage({
    required this.id,
    required this.bookId,
    required this.position,
    required this.relativePath,
    required this.originalName,
    required this.byteSize,
    required this.width,
    required this.height,
  });

  final String id;
  final String bookId;
  final int position;
  final String relativePath;
  final String originalName;
  final int byteSize;
  final int width;
  final int height;

  factory RemotePage.fromMap(Map<String, Object?> map) => RemotePage(
    id: map['id']! as String,
    bookId: map['book_id']! as String,
    position: map['position']! as int,
    relativePath: map['relative_path']! as String,
    originalName: map['original_name']! as String,
    byteSize: map['byte_size']! as int,
    width: map['width']! as int,
    height: map['height']! as int,
  );
}

class ImportFailure {
  const ImportFailure(this.fileName, this.reason, this.sourceIndex);
  final String fileName;
  final String reason;
  final int sourceIndex;
}

class ImportReport {
  const ImportReport({
    required this.imported,
    required this.skippedDuplicates,
    required this.failures,
  });

  final int imported;
  final int skippedDuplicates;
  final List<ImportFailure> failures;
}

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class StorageService {
  StorageService({this.rootOverride});

  static const _channel = MethodChannel('private_manga_reader/storage');
  static const mountArchiveCacheBudgets = <int>[
    256 * 1024 * 1024,
    512 * 1024 * 1024,
    1024 * 1024 * 1024,
    2 * 1024 * 1024 * 1024,
    4 * 1024 * 1024 * 1024,
  ];
  final Directory? rootOverride;

  late final Directory root;
  late final Directory assetsDirectory;
  late final Directory thumbnailsDirectory;
  late final Directory temporaryDirectory;
  late final Directory backupsDirectory;
  late final Directory networkCacheDirectory;

  Future<void> initialize() async {
    final override = rootOverride;
    if (override != null) {
      root = override;
    } else {
      final documents = await getApplicationDocumentsDirectory();
      root = Directory(p.join(documents.path, 'private_shelf'));
    }
    assetsDirectory = Directory(p.join(root.path, 'assets'));
    thumbnailsDirectory = Directory(p.join(root.path, 'thumbnails'));
    temporaryDirectory = Directory(p.join(root.path, 'backup-temp'));
    backupsDirectory = Directory(p.join(root.path, 'backups'));
    networkCacheDirectory = Directory(p.join(root.path, 'network-cache'));
    for (final directory in <Directory>[
      root,
      assetsDirectory,
      thumbnailsDirectory,
      temporaryDirectory,
      backupsDirectory,
      networkCacheDirectory,
    ]) {
      await directory.create(recursive: true);
    }
  }

  String resolve(String relativePath) =>
      p.normalize(p.join(root.path, relativePath));

  String relative(String absolutePath) =>
      p.relative(absolutePath, from: root.path).replaceAll('\\', '/');

  Future<int?> freeBytes() async {
    try {
      return await _channel.invokeMethod<int>('getFreeSpace');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Dart 无法解码但手机可能支持的原图，只读取平台尺寸，不改变原图。
  Future<(int, int)?> probeImageDimensions(String absolutePath) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'getImageDimensions',
        {'path': absolutePath},
      );
      final width = result?['width'];
      final height = result?['height'];
      if (width is int && height is int && width > 0 && height > 0) {
        return (width, height);
      }
    } on MissingPluginException {
      // 没有平台解码器时由导入服务报告不可读取。
    } on PlatformException {
      // 无效图片不提供尺寸。
    }
    return null;
  }

  Future<int> directoryBytes(Directory directory) async {
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  Future<int> thumbnailBytes() => directoryBytes(thumbnailsDirectory);

  Future<int> networkCacheBytes() => directoryBytes(networkCacheDirectory);

  /// 文件空间，不含 APK / 数据库 / 系统插件缓存；未知的原生缓存不能算作 0。
  Future<LocalStorageUsage> localUsage() async {
    final sizes = await Future.wait([
      directoryBytes(assetsDirectory),
      thumbnailBytes(),
      directoryBytes(backupsDirectory),
      networkCacheBytes(),
      directoryBytes(temporaryDirectory),
    ]);
    int? mountBytes;
    int? budgetBytes;
    try {
      mountBytes = await _channel.invokeMethod<int>(
        'getMountArchiveCacheBytes',
      );
      budgetBytes = await _channel.invokeMethod<int>(
        'getMountArchiveCacheBudget',
      );
    } on MissingPluginException {
      // 非 Android 平台不提供 SAF 物化缓存。
    } on PlatformException {
      // 页面展示“暂不可用”，不伪装成没有占用。
    }
    return LocalStorageUsage(
      originalBytes: sizes[0],
      thumbnailBytes: sizes[1],
      backupBytes: sizes[2],
      networkBytes: sizes[3],
      temporaryBytes: sizes[4],
      mountArchiveBytes: mountBytes,
      mountArchiveBudgetBytes: budgetBytes,
    );
  }

  Future<void> clearMountArchiveCache() =>
      _channel.invokeMethod<void>('clearMountArchiveCache');

  Future<void> setMountArchiveCacheBudget(int bytes) async {
    if (!mountArchiveCacheBudgets.contains(bytes)) {
      throw ArgumentError.value(bytes, 'bytes', '不支持的挂载缓存预算');
    }
    await _channel.invokeMethod<void>('setMountArchiveCacheBudget', {
      'bytes': bytes,
    });
  }

  Directory networkBookCacheDirectory(String bookId) {
    if (!RegExp(r'^[a-zA-Z0-9-]{1,80}$').hasMatch(bookId)) {
      throw const FormatException('无效的网络漫画缓存标识');
    }
    return Directory(p.join(networkCacheDirectory.path, bookId));
  }

  Future<void> clearThumbnails() async {
    if (await thumbnailsDirectory.exists()) {
      await thumbnailsDirectory.delete(recursive: true);
    }
    await thumbnailsDirectory.create(recursive: true);
  }

  Future<void> cleanTemporaryFiles() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
    await temporaryDirectory.create(recursive: true);
  }
}

class LocalStorageUsage {
  const LocalStorageUsage({
    required this.originalBytes,
    required this.thumbnailBytes,
    required this.backupBytes,
    required this.networkBytes,
    required this.temporaryBytes,
    required this.mountArchiveBytes,
    this.mountArchiveBudgetBytes,
  });

  final int originalBytes;
  final int thumbnailBytes;
  final int backupBytes;
  final int networkBytes;
  final int temporaryBytes;
  final int? mountArchiveBytes;
  final int? mountArchiveBudgetBytes;

  int get knownBytes =>
      originalBytes +
      thumbnailBytes +
      backupBytes +
      networkBytes +
      temporaryBytes +
      (mountArchiveBytes ?? 0);
}

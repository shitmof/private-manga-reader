import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class StorageService {
  StorageService({this.rootOverride});

  static const _channel = MethodChannel('private_manga_reader/storage');
  final Directory? rootOverride;

  late final Directory root;
  late final Directory assetsDirectory;
  late final Directory thumbnailsDirectory;
  late final Directory temporaryDirectory;
  late final Directory backupsDirectory;

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
    for (final directory in <Directory>[
      root,
      assetsDirectory,
      thumbnailsDirectory,
      temporaryDirectory,
      backupsDirectory,
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

  Future<int> directoryBytes(Directory directory) async {
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  Future<int> thumbnailBytes() => directoryBytes(thumbnailsDirectory);

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

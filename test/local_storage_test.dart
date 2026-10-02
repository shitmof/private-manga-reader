import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_manga_reader/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('private_manga_reader/storage');

  test('平台图片校验只接受有效尺寸，无法校验时返回 null', () async {
    final storage = StorageService();
    Object? response = {'width': 800, 'height': 1200};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => response);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    expect(await storage.probeImageDimensions('/test/image.heic'), (800, 1200));
    response = {'width': 0, 'height': -1};
    expect(await storage.probeImageDimensions('/test/invalid.png'), isNull);
    response = null;
    expect(await storage.probeImageDimensions('/test/unknown.png'), isNull);
  });

  test('空间分类不混算，清理挂载缓存不删除原图、备份或阅读缓存', () async {
    final root = await Directory.systemTemp.createTemp('local-storage-');
    final storage = StorageService(rootOverride: root);
    await storage.initialize();
    addTearDown(() => root.delete(recursive: true));
    var mountBytes = 29;
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'getMountArchiveCacheBytes') return mountBytes;
          if (call.method == 'clearMountArchiveCache') {
            mountBytes = 0;
            return null;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    for (final (directory, size) in [
      (storage.assetsDirectory, 11),
      (storage.thumbnailsDirectory, 13),
      (storage.backupsDirectory, 17),
      (storage.networkCacheDirectory, 19),
      (storage.temporaryDirectory, 23),
    ]) {
      await File(
        '${directory.path}/fixture',
      ).writeAsBytes(List.filled(size, 1));
    }
    final before = await storage.localUsage();
    expect(before.originalBytes, 11);
    expect(before.thumbnailBytes, 13);
    expect(before.backupBytes, 17);
    expect(before.networkBytes, 19);
    expect(before.temporaryBytes, 23);
    expect(before.mountArchiveBytes, 29);
    expect(before.knownBytes, 112);
    await storage.clearMountArchiveCache();
    final after = await storage.localUsage();
    expect(after.knownBytes, 83);
    expect(after.originalBytes, before.originalBytes);
    expect(after.backupBytes, before.backupBytes);
    expect(after.networkBytes, before.networkBytes);
    expect(calls, contains('clearMountArchiveCache'));
  });
}

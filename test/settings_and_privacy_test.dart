import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:private_manga_reader/data/app_database.dart';
import 'package:private_manga_reader/data/library_repository.dart';
import 'package:private_manga_reader/data/network_repository.dart';
import 'package:private_manga_reader/screens/reader_screen.dart';
import 'package:private_manga_reader/screens/settings_screen.dart';
import 'package:private_manga_reader/services/archive_import_service.dart';
import 'package:private_manga_reader/services/backup_service.dart';
import 'package:private_manga_reader/services/import_service.dart';
import 'package:private_manga_reader/services/network_credential_store.dart';
import 'package:private_manga_reader/services/network_library_service.dart';
import 'package:private_manga_reader/services/privacy_service.dart';
import 'package:private_manga_reader/services/storage_service.dart';
import 'package:private_manga_reader/state/app_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 针对已确认的用户反馈补的回归测试：
///  1. 设置页开关点了以后同一页面不刷新，必须退出重进才看到新状态；
///  2. 连续修改两个开关会互相覆盖；
///  3. 退出普通（非私密）漫画阅读页会错误解除全局截屏保护。
///
/// 原有 57 个测试未覆盖设置页与阅读页的这些交互，因此缺陷逃逸。
void main() {
  sqfliteFfiInit();

  const privacyChannel = MethodChannel('private_manga_reader/privacy');

  Future<(AppController, Directory, NetworkLibraryService)> buildController(
    WidgetTester tester, {
    required String prefix,
  }) async {
    final sandbox = (await tester.runAsync(
      () => Directory.systemTemp.createTemp(prefix),
    ))!;
    final database = AppDatabase(
      factory: databaseFactoryFfi,
      overridePath: p.join(sandbox.path, 'library.db'),
    );
    final repository = LibraryRepository(database);
    final storage = StorageService(
      rootOverride: Directory(p.join(sandbox.path, 'files')),
    );
    await tester.runAsync(storage.initialize);
    final importer = ImportService(repository, storage);
    final archiveImporter = ArchiveImportService(repository, storage, importer);
    final networkRepository = NetworkRepository(database);
    final networkLibrary = NetworkLibraryService(
      networkRepository,
      storage,
      archiveImporter,
      MemoryNetworkCredentialStore(),
    );
    final controller = AppController(
      repository,
      storage,
      importer,
      archiveImporter,
      BackupService(repository, storage),
      networkRepository,
      networkLibrary,
      privacyAuthenticator: const AllowPrivacyAuthenticator(),
    );
    await tester.runAsync(controller.initialize);
    addTearDown(() async {
      await networkLibrary.dispose();
      await database.close();
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });
    return (controller, sandbox, networkLibrary);
  }

  /// 读取某个开关当前显示的开启状态。
  ///
  /// 设置页用的是自绘的 [ShelfSwitchTile]，其开关是 `Semantics(toggled: ...)`
  /// 包的自绘控件，不是 Material 的 `SwitchListTile`。
  bool switchValue(WidgetTester tester, String title) {
    final tile = find.ancestor(
      of: find.text(title),
      matching: find.byType(ListTile),
    );
    expect(tile, findsOneWidget, reason: '应能找到「$title」所在设置行');
    final semantics = find.descendant(
      of: tile,
      matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.toggled != null,
      ),
    );
    expect(semantics, findsOneWidget, reason: '「$title」应有开关语义');
    final widget = tester.widget<Semantics>(semantics);
    return widget.properties.toggled!;
  }

  Future<void> useTallPhone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// 点击某个开关并等待落盘完成。
  ///
  /// 必须用 [WidgetTester.runAsync] 包住：`updatePreferences` 会真正写 SQLite，
  /// 在 widget 测试默认的 fake-async 区里这个 Future 永远不会完成，
  /// 既会让断言看不到新状态，也会让 tearDown 挂住。
  Future<void> tapSwitch(WidgetTester tester, String title) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(title));
      await tester.pump();
      // 给落盘和 setState 一点真实时间。
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pump();
  }

  testWidgets('设置页：开关在同一页面内立即反映新状态', (tester) async {
    await useTallPhone(tester);
    final (controller, _, _) = await buildController(
      tester,
      prefix: 'settings-toggle-',
    );

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(switchValue(tester, '记住阅读位置'), isTrue);

    await tapSwitch(tester, '记住阅读位置');

    // 关键断言：不退出页面就应该看到关闭态，且内存偏好已更新。
    expect(
      switchValue(tester, '记住阅读位置'),
      isFalse,
      reason: '开关必须在同一页面内立即刷新，而不是退出重进后才变',
    );
    expect(controller.preferences.rememberProgress, isFalse);
  });

  testWidgets('设置页：连续修改两个开关不会互相覆盖', (tester) async {
    await useTallPhone(tester);
    final (controller, _, _) = await buildController(
      tester,
      prefix: 'settings-consecutive-',
    );

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    // 旧实现里第二次修改会用「进入页面时」的快照覆盖第一次的结果。
    await tapSwitch(tester, '跟随手机亮度');
    await tapSwitch(tester, '阅读器快速定位条');

    expect(
      controller.preferences.followSystemBrightness,
      isTrue,
      reason: '第一次修改不能被第二次覆盖',
    );
    expect(controller.preferences.readerScrubber, isFalse);
    expect(switchValue(tester, '跟随手机亮度'), isTrue);
    expect(switchValue(tester, '阅读器快速定位条'), isFalse);
  });

  testWidgets('阅读普通（非私密）漫画退出时不得解除全局截屏保护', (tester) async {
    await useTallPhone(tester);

    final secureCalls = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(privacyChannel, (call) async {
          if (call.method == 'setScreenSecure') {
            secureCalls.add(call.arguments as bool);
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(privacyChannel, null);
      PrivateScreenGuard.resetForTesting();
    });

    final (controller, _, _) = await buildController(
      tester,
      prefix: 'reader-guard-',
    );

    // 模拟「无痕模式已开启」：持有一层全局截屏保护。
    PrivateScreenGuard.resetForTesting();
    await PrivateScreenGuard.acquireSecure();
    expect(secureCalls, <bool>[true]);

    final comicId = await tester.runAsync(() async {
      final comic = await controller.createComic('普通漫画');
      return comic.id;
    });
    expect(comicId, isNotNull);
    expect(controller.summaryFor(comicId!)?.comic.isPrivate, isFalse);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(controller: controller, comicId: comicId),
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    // 阅读页对非私密漫画不申请保护，因此不应有任何新的下发。
    expect(secureCalls, <bool>[true]);

    // 退出阅读页。
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    expect(secureCalls, <bool>[true], reason: '退出普通漫画阅读页不得解除无痕模式的截屏保护');
  });
}

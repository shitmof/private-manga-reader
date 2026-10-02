import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_manga_reader/screens/local_storage_screen.dart';
import 'package:private_manga_reader/services/storage_service.dart';
import 'package:private_manga_reader/theme.dart';
import 'package:private_manga_reader/widgets/formatters.dart';

class _DisplayStorage extends StorageService {
  _DisplayStorage() {
    root = Directory('local-test-library');
  }
  int cleared = 0;
  int? budget = 1024 * 1024 * 1024;
  final budgetChanges = <int>[];
  int availableBytes = 5 * 1024 * 1024 * 1024;
  bool failBudgetWrite = false;
  @override
  Future<LocalStorageUsage> localUsage() async => LocalStorageUsage(
    originalBytes: 3200000000,
    thumbnailBytes: 24000000,
    backupBytes: 400000000,
    networkBytes: 50000000,
    temporaryBytes: 0,
    mountArchiveBytes: cleared == 0 ? 800000000 : 0,
    mountArchiveBudgetBytes: budget,
  );
  @override
  Future<int?> freeBytes() async => availableBytes;

  @override
  Future<void> setMountArchiveCacheBudget(int bytes) async {
    budgetChanges.add(bytes);
    budget = bytes;
    if (failBudgetWrite) throw StateError('缓存裁剪中断');
  }

  @override
  Future<void> clearMountArchiveCache() async {
    cleared++;
  }
}

void main() {
  testWidgets('挂载缓存预算：降低需确认，取消不改，保存刷新当前上限', (tester) async {
    final storage = _DisplayStorage();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShelfTheme(Brightness.light),
        home: LocalStorageScreen(storage: storage),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('挂载缓存上限'), 250);
    await tester.ensureVisible(find.text('挂载缓存上限'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('挂载缓存上限'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(formatBytes(StorageService.mountArchiveCacheBudgets.first)),
    );
    await tester.pumpAndSettle();
    expect(find.text('降低缓存上限？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(storage.budgetChanges, isEmpty);
    expect(storage.budget, 1024 * 1024 * 1024);

    await tester.tap(find.text('挂载缓存上限'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(formatBytes(StorageService.mountArchiveCacheBudgets.first)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('降低并清理旧缓存'));
    await tester.pumpAndSettle();
    expect(storage.budgetChanges, [
      StorageService.mountArchiveCacheBudgets.first,
    ]);
    expect(find.text('当前 ${formatBytes(storage.budget)}'), findsOneWidget);
    expect(storage.cleared, 0, reason: '预算 API 负责裁剪，UI 不额外全清缓存');
    expect(tester.takeException(), isNull);
  });

  testWidgets('不支持原生缓存预算时不显示设置入口', (tester) async {
    final storage = _DisplayStorage()..budget = null;
    await tester.pumpWidget(
      MaterialApp(home: LocalStorageScreen(storage: storage)),
    );
    await tester.pumpAndSettle();
    expect(find.text('挂载缓存上限'), findsNothing);
  });

  testWidgets('提高缓存预算前检查可用空间，不足时保留旧上限', (tester) async {
    final storage = _DisplayStorage()..availableBytes = 0;
    await tester.pumpWidget(
      MaterialApp(home: LocalStorageScreen(storage: storage)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('挂载缓存上限'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('挂载缓存上限'));
    await tester.pumpAndSettle();
    final choice = find.text(formatBytes(2 * 1024 * 1024 * 1024));
    await tester.ensureVisible(choice);
    await tester.pumpAndSettle();
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(storage.budgetChanges, isEmpty);
    expect(storage.budget, 1024 * 1024 * 1024);
    expect(find.text('当前可用空间不足以容纳该缓存上限，请先释放手机空间。'), findsOneWidget);
  });

  testWidgets('调整缓存部分失败后重新读取实际上限，界面不保留错误旧值', (tester) async {
    final storage = _DisplayStorage()..failBudgetWrite = true;
    await tester.pumpWidget(
      MaterialApp(home: LocalStorageScreen(storage: storage)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('挂载缓存上限'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('挂载缓存上限'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(formatBytes(StorageService.mountArchiveCacheBudgets.first)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('降低并清理旧缓存'));
    await tester.pumpAndSettle();
    expect(storage.budgetChanges, [
      StorageService.mountArchiveCacheBudgets.first,
    ]);
    expect(find.text('当前 ${formatBytes(storage.budget)}'), findsOneWidget);
    expect(find.textContaining('缓存上限未能完成调整'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (width, scale, dark) in [
    (360.0, 1.0, false),
    (320.0, 1.4, false),
    (360.0, 1.0, true),
  ]) {
    testWidgets('本地空间：${width.toInt()} dp / 字号 $scale / 深色 $dark，无溢出且清理需确认', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = _DisplayStorage();
      final boundaryKey = GlobalKey();
      // 可选的人工视觉验收；默认 CI 不读取本机字体或写截图。
      final fontPath = Platform.environment['SHIHUAGE_CAPTURE_FONT'];
      if (fontPath != null) {
        final bytes = await tester.runAsync(() => File(fontPath).readAsBytes());
        await (FontLoader(
          'Noto Sans CJK SC',
        )..addFont(Future.value(ByteData.sublistView(bytes!)))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      }
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildShelfTheme(dark ? Brightness.dark : Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: LocalStorageScreen(storage: storage),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('资料留在本机'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final captureDirectory = Platform.environment['SHIHUAGE_CAPTURE_DIR'];
      if (captureDirectory != null) {
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(captureDirectory).create(recursive: true);
          await File(
            '$captureDirectory/storage-${width.toInt()}-$scale-$dark.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.scrollUntilVisible(find.text('仅清理挂载缓存'), 250);
      await tester.ensureVisible(find.text('仅清理挂载缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仅清理挂载缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(storage.cleared, 0);
      await tester.tap(find.text('仅清理挂载缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清理缓存'));
      await tester.pumpAndSettle();
      expect(storage.cleared, 1);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('升级保留 · 卸载前先备份'), 220);
      expect(tester.takeException(), isNull);
    });
  }
}

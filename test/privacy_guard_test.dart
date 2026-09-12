import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_manga_reader/models/entities.dart';
import 'package:private_manga_reader/services/privacy_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('private_manga_reader/privacy');
  late List<bool> secureCalls;

  setUp(() {
    secureCalls = <bool>[];
    PrivateScreenGuard.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'setScreenSecure') {
            secureCalls.add(call.arguments as bool);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('PrivateScreenGuard 引用计数', () {
    test('单个持有者申请与释放会真正开关截屏保护', () async {
      await PrivateScreenGuard.acquireSecure();
      expect(secureCalls, <bool>[true]);

      await PrivateScreenGuard.releaseSecure();
      expect(secureCalls, <bool>[true, false]);
    });

    test('无痕模式与私密漫画同时持有，先退出的一方不得关闭保护', () async {
      // 模拟：无痕模式先申请，随后进入私密漫画阅读再申请。
      await PrivateScreenGuard.acquireSecure();
      await PrivateScreenGuard.acquireSecure();
      // 第二次申请应被合并，不重复下发。
      expect(secureCalls, <bool>[true]);

      // 私密漫画退出：保护必须保持。
      await PrivateScreenGuard.releaseSecure();
      expect(secureCalls, <bool>[true]);

      // 无痕模式关闭：此刻才真正解除。
      await PrivateScreenGuard.releaseSecure();
      expect(secureCalls, <bool>[true, false]);
    });

    test('多余的释放不会误关他人保护', () async {
      await PrivateScreenGuard.acquireSecure();
      await PrivateScreenGuard.releaseSecure();
      await PrivateScreenGuard.releaseSecure(); // 冗余释放
      expect(secureCalls, <bool>[true, false]);
    });

    test('setSecure(true) 后再 setSecure(true) 不重复下发', () async {
      await PrivateScreenGuard.setSecure(true);
      await PrivateScreenGuard.setSecure(true);
      expect(secureCalls, <bool>[true]);
    });

    test('平台缺少该能力时静默降级，不抛异常', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw MissingPluginException('no implementation');
          });
      await expectLater(PrivateScreenGuard.acquireSecure(), completes);
      await expectLater(PrivateScreenGuard.releaseSecure(), completes);
    });
  });

  group('ReaderPreferences 新增字段', () {
    test('默认值：无痕关闭、跟随系统亮度关闭、定位条开启', () {
      const preferences = ReaderPreferences();
      expect(preferences.incognito, isFalse);
      expect(preferences.followSystemBrightness, isFalse);
      expect(preferences.readerScrubber, isTrue);
    });

    test('copyWith 可以独立切换三个新字段', () {
      const preferences = ReaderPreferences();
      final updated = preferences.copyWith(
        incognito: true,
        followSystemBrightness: true,
        readerScrubber: false,
      );
      expect(updated.incognito, isTrue);
      expect(updated.followSystemBrightness, isTrue);
      expect(updated.readerScrubber, isFalse);
      // 未指定的字段保持原值。
      expect(updated.readerBrightness, preferences.readerBrightness);
      expect(updated.surfaceMode, preferences.surfaceMode);
    });

    test('copyWith 显式传 false 能覆盖 true', () {
      const preferences = ReaderPreferences(incognito: true);
      expect(preferences.copyWith(incognito: false).incognito, isFalse);
    });
  });
}

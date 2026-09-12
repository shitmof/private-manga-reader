import 'package:local_auth/local_auth.dart';
import 'package:flutter/services.dart';

abstract interface class PrivacyAuthenticator {
  Future<bool> authenticate({required String reason});
}

class DevicePrivacyAuthenticator implements PrivacyAuthenticator {
  DevicePrivacyAuthenticator({LocalAuthentication? authentication})
    : _authentication = authentication ?? LocalAuthentication();

  final LocalAuthentication _authentication;

  @override
  Future<bool> authenticate({required String reason}) async {
    try {
      if (!await _authentication.isDeviceSupported()) return false;
      return await _authentication.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException {
      return false;
    }
  }
}

class AllowPrivacyAuthenticator implements PrivacyAuthenticator {
  const AllowPrivacyAuthenticator();

  @override
  Future<bool> authenticate({required String reason}) async => true;
}

class PrivateScreenGuard {
  static const MethodChannel _channel = MethodChannel(
    'private_manga_reader/privacy',
  );

  /// 当前有多少个来源同时要求禁止截屏（无痕模式、私密漫画阅读等）。
  ///
  /// 必须计数而不是直接置位：无痕模式与私密漫画阅读会同时申请保护，
  /// 任何一方退出时都不得把另一方的保护一并关掉。
  static int _holders = 0;
  static bool _applied = false;

  /// 申请禁止截屏；调用方必须成对调用 [releaseSecure]。
  static Future<void> acquireSecure() async {
    _holders += 1;
    if (_applied) return;
    _applied = true;
    await _push(true);
  }

  /// 释放一次禁止截屏申请；仍有其他持有者时保持保护。
  static Future<void> releaseSecure() async {
    if (_holders == 0) return;
    _holders -= 1;
    if (_holders > 0) return;
    _applied = false;
    await _push(false);
  }

  /// 按绝对状态设置保护，供无痕模式这类"总开关"使用。
  static Future<void> setSecure(bool value) async {
    if (value) {
      await acquireSecure();
    } else {
      await releaseSecure();
    }
  }

  static Future<void> _push(bool value) async {
    try {
      await _channel.invokeMethod<void>('setScreenSecure', value);
    } on MissingPluginException {
      // Widget 测试或非 Android 环境不执行截屏保护。
    } on PlatformException {
      // 个别 ROM 缺少该窗口能力时静默降级，不影响阅读。
    }
  }

  /// 仅供测试重置内部计数。
  static void resetForTesting() {
    _holders = 0;
    _applied = false;
  }
}

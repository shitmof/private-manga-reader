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

  static Future<void> setSecure(bool value) async {
    try {
      await _channel.invokeMethod<void>('setScreenSecure', value);
    } on MissingPluginException {
      // Widget 测试或非 Android 环境不执行截屏保护。
    }
  }
}

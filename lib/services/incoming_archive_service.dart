import 'dart:io';
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 接收用户在 Android 文件管理器中点击的漫画压缩包。
class IncomingArchiveService extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel(
    'private_manga_reader/documents',
  );

  final List<PlatformFile> _pending = <PlatformFile>[];

  bool get hasPending => _pending.isNotEmpty;

  Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'archiveOpened' && call.arguments is Map) {
        final file = await _decode(call.arguments as Map);
        if (file != null) {
          _pending.add(file);
          notifyListeners();
        }
      }
    });
    final initial = await _channel.invokeListMethod<Object?>(
      'getPendingArchives',
    );
    for (final item in initial ?? const <Object?>[]) {
      if (item is Map) {
        final file = await _decode(item);
        if (file != null) _pending.add(file);
      }
    }
  }

  List<PlatformFile> takePending() {
    final result = List<PlatformFile>.unmodifiable(_pending);
    _pending.clear();
    return result;
  }

  Future<PlatformFile?> _decode(Map value) async {
    final path = value['path']?.toString();
    final name = value['name']?.toString();
    if (path == null || name == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return _IncomingPlatformFile(file, name);
  }
}

final class _IncomingPlatformFile extends PlatformFile {
  _IncomingPlatformFile(this.file, this.displayName);

  final File file;
  final String displayName;

  @override
  String get name => displayName;

  @override
  Uri get uri => file.uri;

  @override
  XFile get xFile => XFile(file.path, name: displayName);

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() async* {
    await for (final chunk in file.openRead()) {
      yield Uint8List.fromList(chunk);
    }
  }
}

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/entities.dart';

abstract interface class NetworkCredentialStore {
  Future<void> write(String sourceId, NetworkCredentials credentials);

  Future<NetworkCredentials> read(String sourceId);

  Future<void> delete(String sourceId);
}

class SecureNetworkCredentialStore implements NetworkCredentialStore {
  SecureNetworkCredentialStore({FlutterSecureStorage? storage})
    : _storage =
          storage ?? const FlutterSecureStorage(aOptions: AndroidOptions());

  static const _prefix = 'network-source-credentials:';
  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String sourceId, NetworkCredentials credentials) =>
      _storage.write(
        key: '$_prefix$sourceId',
        value: jsonEncode(<String, String>{
          'username': credentials.username,
          'password': credentials.password,
          'domain': credentials.domain,
        }),
      );

  @override
  Future<NetworkCredentials> read(String sourceId) async {
    final raw = await _storage.read(key: '$_prefix$sourceId');
    if (raw == null || raw.isEmpty) return const NetworkCredentials();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const NetworkCredentials();
      return NetworkCredentials(
        username: decoded['username']?.toString() ?? '',
        password: decoded['password']?.toString() ?? '',
        domain: decoded['domain']?.toString() ?? '',
      );
    } catch (_) {
      return const NetworkCredentials();
    }
  }

  @override
  Future<void> delete(String sourceId) =>
      _storage.delete(key: '$_prefix$sourceId');
}

class MemoryNetworkCredentialStore implements NetworkCredentialStore {
  final Map<String, NetworkCredentials> _values =
      <String, NetworkCredentials>{};

  @override
  Future<void> write(String sourceId, NetworkCredentials credentials) async {
    _values[sourceId] = credentials;
  }

  @override
  Future<NetworkCredentials> read(String sourceId) async =>
      _values[sourceId] ?? const NetworkCredentials();

  @override
  Future<void> delete(String sourceId) async {
    _values.remove(sourceId);
  }
}

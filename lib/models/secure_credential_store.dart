import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'user_manager.dart';

/// Manages secure storage of user credentials using platform keychain/keystore.
///
/// On first launch after migration, transparently moves any plaintext
/// credentials previously stored in SharedPreferences into secure storage
/// and deletes the old entries.
///
/// In test environments, call [setInstance] with an in-memory override
/// before running any code that accesses this store.
class SecureCredentialStore {
  static SecureCredentialStore _instance = SecureCredentialStore._();
  factory SecureCredentialStore() => _instance;

  /// Replace the singleton with a custom instance (e.g. for tests).
  static void setInstance(SecureCredentialStore store) => _instance = store;

  /// Reset to the default platform-backed instance.
  static void resetInstance() => _instance = SecureCredentialStore._();

  SecureCredentialStore._();

  // ── Keys ───────────────────────────────────────────────────────────

  static const _keyUsername = 'saved_username';
  static const _keyToken = 'user_token';
  static const _keyPassword = 'saved_password';
  static const _keyCredentials = 'saved_credentials';
  static const _keyMigrated = 'credentials_migrated_to_secure';
  static const _keyWebDavCredentials = 'backup_webdav_credentials_v1';
  static const _keyBackupPassword = 'backup_password_v1';
  static const _keyBackupRollbackKey = 'backup_rollback_key_v1';
  static const _keyCopyAccount = 'copy_account_v1';

  // ── Read ───────────────────────────────────────────────────────────

  /// widget 测试里没有平台通道，`FlutterSecureStorage` 的 Future 既不完成也不
  /// 抛错，会让 await 它的启动流程永久挂起。测试统一改注入
  /// [InMemorySecureCredentialStore]；这里再兜一层，避免个别用例漏配后
  /// 整个测试文件 10 分钟超时。
  static final bool _platformAvailable =
      Platform.environment['FLUTTER_TEST'] != 'true';

  @protected
  Future<String?> doRead(String key) async {
    if (!_platformAvailable) return null;
    try {
      return await const FlutterSecureStorage().read(key: key);
    } on MissingPluginException {
      return null;
    }
  }

  @protected
  Future<void> doWrite(String key, String value) async {
    if (!_platformAvailable) return;
    try {
      await const FlutterSecureStorage().write(key: key, value: value);
    } on MissingPluginException {
      // 平台通道缺失时写不进去，保持旧行为，不把异常抛给调用方。
    }
  }

  @protected
  Future<void> doDelete(String key) async {
    if (!_platformAvailable) return;
    try {
      await const FlutterSecureStorage().delete(key: key);
    } on MissingPluginException {
      // 同上。
    }
  }

  Future<String?> readUsername() => doRead(_keyUsername);
  // Empty is a logout tombstone, distinct from an unmigrated missing record.
  Future<String?> readToken() => doRead(_keyToken);
  Future<void> writeToken(String? value) => doWrite(_keyToken, value ?? '');

  Future<String?> readPassword() => doRead(_keyPassword);

  Future<bool> credentialsMigrated() async =>
      await doRead(_keyMigrated) == 'true';

  Future<String?> readWebDavCredentials() => doRead(_keyWebDavCredentials);
  Future<String?> readBackupPassword() => doRead(_keyBackupPassword);
  Future<String?> readBackupRollbackKey() => doRead(_keyBackupRollbackKey);
  Future<String?> readCopyAccountRecord() => doRead(_keyCopyAccount);

  /// A null session must be encoded in the record, not deleted: it is the
  /// durable marker that prevents legacy primary COPY logins being reimported.
  Future<void> writeCopyAccountRecord(String value) =>
      doWrite(_keyCopyAccount, value);

  Future<void> writeWebDavCredentials(String? value) =>
      _writeOptional(_keyWebDavCredentials, value);
  Future<void> writeBackupPassword(String? value) =>
      _writeOptional(_keyBackupPassword, value);
  Future<void> writeBackupRollbackKey(String? value) =>
      _writeOptional(_keyBackupRollbackKey, value);

  Future<void> _writeOptional(String key, String? value) =>
      value == null ? doDelete(key) : doWrite(key, value);

  Future<List<SavedCredential>> readCredentials() async {
    final raw = await doRead(_keyCredentials);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => SavedCredential.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.hasAccountKey)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── Write ──────────────────────────────────────────────────────────

  Future<void> writeUsername(String? value) async {
    if (value == null || value.isEmpty) {
      await doDelete(_keyUsername);
    } else {
      await doWrite(_keyUsername, value);
    }
  }

  Future<void> writePassword(String? value) async {
    if (value == null || value.isEmpty) {
      await doDelete(_keyPassword);
    } else {
      await doWrite(_keyPassword, value);
    }
  }

  Future<void> writeCredentials(List<SavedCredential> credentials) async {
    if (credentials.isEmpty) {
      await doDelete(_keyCredentials);
    } else {
      await doWrite(
        _keyCredentials,
        jsonEncode(credentials.map((e) => e.toJson()).toList()),
      );
    }
  }

  // ── Delete ─────────────────────────────────────────────────────────

  Future<void> deleteAll() async {
    await doDelete(_keyToken);
    await doDelete(_keyUsername);
    await doDelete(_keyPassword);
    await doDelete(_keyCredentials);
    await doDelete(_keyWebDavCredentials);
    await doDelete(_keyBackupPassword);
    await doDelete(_keyBackupRollbackKey);
    await doDelete(_keyCopyAccount);
  }

  // ── Migration ──────────────────────────────────────────────────────

  Future<void> migrateFromSharedPreferences(
    Map<String, Object?> prefsMap,
    Future<void> Function(String key) removePref,
  ) async {
    final alreadyMigrated = await doRead(_keyMigrated) == 'true';
    if (alreadyMigrated) return;

    final oldUsername = prefsMap[_keyUsername] as String?;
    final oldPassword = prefsMap[_keyPassword] as String?;
    final oldCredentialsRaw = prefsMap[_keyCredentials] as String?;

    if (oldUsername != null && oldUsername.isNotEmpty) {
      await doWrite(_keyUsername, oldUsername);
    }
    if (oldPassword != null && oldPassword.isNotEmpty) {
      await doWrite(_keyPassword, oldPassword);
    }
    if (oldCredentialsRaw != null && oldCredentialsRaw.isNotEmpty) {
      await doWrite(_keyCredentials, oldCredentialsRaw);
    }

    await removePref(_keyUsername);
    await removePref(_keyPassword);
    await removePref(_keyCredentials);

    await doWrite(_keyMigrated, 'true');
  }
}

/// In-memory implementation for unit tests where platform channels
/// are unavailable.
class InMemorySecureCredentialStore extends SecureCredentialStore {
  final _map = <String, String>{};

  InMemorySecureCredentialStore() : super._();

  @override
  Future<String?> doRead(String key) async => _map[key];

  @override
  Future<void> doWrite(String key, String value) async => _map[key] = value;

  @override
  Future<void> doDelete(String key) async => _map.remove(key);
}

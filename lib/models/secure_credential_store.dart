import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/app_logger.dart';
import '../utils/app_storage.dart';
import 'user_manager.dart';

/// Manages secure storage of user credentials using platform keychain/keystore.
///
/// On first launch after migration, transparently moves any plaintext
/// credentials previously stored in SharedPreferences into secure storage
/// and deletes the old entries.
///
/// Every entry is additionally mirrored into SharedPreferences under a
/// `secure_mirror_` prefix (see [_mirrorPrefix]). Some Android devices lose
/// secure-storage data or throw on reads (keystore invalidation, vendor
/// cleanup, cloned-app spaces…); since v1.7 the session token lives only
/// here, so a read failure used to log the user out on every restart. Reads
/// prefer secure storage and fall back to the mirror, restoring secure
/// storage best-effort when the mirror wins. The trade-off is plaintext
/// credentials in prefs, accepted deliberately for availability: backup
/// export is allowlist-based (mirrors never leave the device) and the cache
/// management page masks the prefix as sensitive.
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

  /// Prefix of the SharedPreferences mirror keys. Kept distinct from the
  /// legacy plaintext keys so the migration's removePref calls and
  /// UserManager's own prefs cleanup never clobber the fallback copies.
  static const _mirrorPrefix = 'secure_mirror_';

  String _mirrorKey(String key) => '$_mirrorPrefix$key';

  // ── Read ───────────────────────────────────────────────────────────

  /// widget 测试里没有平台通道，`FlutterSecureStorage` 的 Future 既不完成也不
  /// 抛错，会让 await 它的启动流程永久挂起。测试统一改注入
  /// [InMemorySecureCredentialStore]；这里再兜一层，避免个别用例漏配后
  /// 整个测试文件 10 分钟超时。
  static final bool _platformAvailable =
      Platform.environment['FLUTTER_TEST'] != 'true';

  /// Whether the prefs mirror layer is active. False in widget tests, where
  /// [InMemorySecureCredentialStore] stands in for the platform store and
  /// SharedPreferences must stay untouched.
  @protected
  bool get mirrorEnabled => _platformAvailable;

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

  /// Reads [key] from secure storage, falling back to the prefs mirror when
  /// secure storage throws or misses. A mirror hit restores secure storage
  /// best-effort, so a wiped keystore heals instead of staying empty.
  @protected
  Future<String?> readWithFallback(String key) async {
    String? value;
    try {
      value = await doRead(key);
    } catch (error, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          StateError('Secure storage read failed for $key'),
          stackTrace: stack,
          source: 'secure_credential_store.fallback',
        ),
      );
      value = null;
    }
    if (value != null) {
      // Keep the mirror fresh so it can serve after a later secure outage.
      final mirrored = await _mirrorRead(key);
      if (mirrored != value) await _mirrorWrite(key, value);
      return value;
    }
    final mirrored = await _mirrorRead(key);
    if (mirrored == null) return null;
    try {
      await doWrite(key, mirrored);
    } catch (error, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          StateError('Secure storage mirror restore failed for $key'),
          stackTrace: stack,
          source: 'secure_credential_store.fallback',
        ),
      );
    }
    return mirrored;
  }

  /// Writes [key] to secure storage and refreshes the prefs mirror. Secure
  /// write failures still propagate — login commits and rollback depend on
  /// them; the mirror is best-effort resilience only.
  @protected
  Future<void> writeWithMirror(String key, String value) async {
    await doWrite(key, value);
    await _mirrorWrite(key, value);
  }

  @protected
  Future<void> deleteWithMirror(String key) async {
    await doDelete(key);
    await _mirrorDelete(key);
  }

  Future<void> _mirrorWrite(String key, String value) async {
    if (!mirrorEnabled) return;
    try {
      final prefs = await AppStorage.sharedPreferences();
      await prefs.setString(_mirrorKey(key), value);
    } catch (error, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          error,
          stackTrace: stack,
          source: 'secure_credential_store.mirror_write',
        ),
      );
    }
  }

  Future<String?> _mirrorRead(String key) async {
    if (!mirrorEnabled) return null;
    try {
      final prefs = await AppStorage.sharedPreferences();
      return prefs.getString(_mirrorKey(key));
    } catch (error, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          error,
          stackTrace: stack,
          source: 'secure_credential_store.mirror_read',
        ),
      );
      return null;
    }
  }

  Future<void> _mirrorDelete(String key) async {
    if (!mirrorEnabled) return;
    try {
      final prefs = await AppStorage.sharedPreferences();
      await prefs.remove(_mirrorKey(key));
    } catch (error, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          error,
          stackTrace: stack,
          source: 'secure_credential_store.mirror_delete',
        ),
      );
    }
  }

  Future<String?> readUsername() => readWithFallback(_keyUsername);
  // Empty is a logout tombstone, distinct from an unmigrated missing record.
  Future<String?> readToken() => readWithFallback(_keyToken);
  Future<void> writeToken(String? value) =>
      writeWithMirror(_keyToken, value ?? '');

  Future<String?> readPassword() => readWithFallback(_keyPassword);

  Future<bool> credentialsMigrated() async =>
      await readWithFallback(_keyMigrated) == 'true';

  Future<String?> readWebDavCredentials() =>
      readWithFallback(_keyWebDavCredentials);
  Future<String?> readBackupPassword() => readWithFallback(_keyBackupPassword);
  Future<String?> readBackupRollbackKey() =>
      readWithFallback(_keyBackupRollbackKey);
  Future<String?> readCopyAccountRecord() => readWithFallback(_keyCopyAccount);

  /// A null session must be encoded in the record, not deleted: it is the
  /// durable marker that prevents legacy primary COPY logins being reimported.
  Future<void> writeCopyAccountRecord(String value) =>
      writeWithMirror(_keyCopyAccount, value);

  Future<void> writeWebDavCredentials(String? value) =>
      _writeOptional(_keyWebDavCredentials, value);
  Future<void> writeBackupPassword(String? value) =>
      _writeOptional(_keyBackupPassword, value);
  Future<void> writeBackupRollbackKey(String? value) =>
      _writeOptional(_keyBackupRollbackKey, value);

  Future<void> _writeOptional(String key, String? value) =>
      value == null ? deleteWithMirror(key) : writeWithMirror(key, value);

  Future<List<SavedCredential>> readCredentials() async {
    final raw = await readWithFallback(_keyCredentials);
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
      await deleteWithMirror(_keyUsername);
    } else {
      await writeWithMirror(_keyUsername, value);
    }
  }

  Future<void> writePassword(String? value) async {
    if (value == null || value.isEmpty) {
      await deleteWithMirror(_keyPassword);
    } else {
      await writeWithMirror(_keyPassword, value);
    }
  }

  Future<void> writeCredentials(List<SavedCredential> credentials) async {
    if (credentials.isEmpty) {
      await deleteWithMirror(_keyCredentials);
    } else {
      await writeWithMirror(
        _keyCredentials,
        jsonEncode(credentials.map((e) => e.toJson()).toList()),
      );
    }
  }

  // ── Delete ─────────────────────────────────────────────────────────

  Future<void> deleteAll() async {
    await deleteWithMirror(_keyToken);
    await deleteWithMirror(_keyUsername);
    await deleteWithMirror(_keyPassword);
    await deleteWithMirror(_keyCredentials);
    await deleteWithMirror(_keyWebDavCredentials);
    await deleteWithMirror(_keyBackupPassword);
    await deleteWithMirror(_keyBackupRollbackKey);
    await deleteWithMirror(_keyCopyAccount);
  }

  // ── Migration ──────────────────────────────────────────────────────

  Future<void> migrateFromSharedPreferences(
    Map<String, Object?> prefsMap,
    Future<void> Function(String key) removePref,
  ) async {
    final alreadyMigrated = await readWithFallback(_keyMigrated) == 'true';
    if (alreadyMigrated) return;

    final oldUsername = prefsMap[_keyUsername] as String?;
    final oldPassword = prefsMap[_keyPassword] as String?;
    final oldCredentialsRaw = prefsMap[_keyCredentials] as String?;

    if (oldUsername != null && oldUsername.isNotEmpty) {
      await writeWithMirror(_keyUsername, oldUsername);
    }
    if (oldPassword != null && oldPassword.isNotEmpty) {
      await writeWithMirror(_keyPassword, oldPassword);
    }
    if (oldCredentialsRaw != null && oldCredentialsRaw.isNotEmpty) {
      await writeWithMirror(_keyCredentials, oldCredentialsRaw);
    }

    await removePref(_keyUsername);
    await removePref(_keyPassword);
    await removePref(_keyCredentials);

    await writeWithMirror(_keyMigrated, 'true');
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

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/secure_credential_store.dart';
import '../models/user_manager.dart';
import 'backup_error.dart';

abstract interface class BackupPreferences {
  Future<Map<String, Object>> readAll();
  Future<void> write(String key, Object value);
  Future<void> remove(String key);
}

/// Exposes the original portable account keys over their current storage
/// backends. COPY sessions and other device-local secure records stay private.
class SharedBackupPreferences implements BackupPreferences {
  static const secureAccountKeys = {
    'user_token',
    'saved_username',
    'saved_password',
    'saved_credentials',
  };

  final SecureCredentialStore _secure;

  SharedBackupPreferences({SecureCredentialStore? secure})
    : _secure = secure ?? SecureCredentialStore();

  @override
  Future<Map<String, Object>> readAll() =>
      UserManager().readAccountStorage(() async {
        final prefs = await SharedPreferences.getInstance();
        final keys = prefs.getKeys().toList()..sort();
        final snapshot = <String, Object>{};
        for (final key in keys) {
          final value = prefs.get(key);
          if (value != null) {
            snapshot[key] = value is List<String>
                ? List<String>.of(value)
                : value;
          }
        }

        // Missing secure tokens may still be unmigrated. Empty tokens are
        // deliberate logout tombstones and must override stale legacy tokens.
        final token = await _secure.readToken();
        if (token != null) snapshot['user_token'] = token;
        final migrated = await _secure.credentialsMigrated();
        for (final entry in {
          'saved_username': await _secure.readUsername(),
          'saved_password': await _secure.readPassword(),
        }.entries) {
          if (migrated || entry.value != null) snapshot.remove(entry.key);
          final value = entry.value;
          if (value != null) snapshot[entry.key] = value;
        }
        final credentials = await _secure.readCredentials();
        if (migrated || credentials.isNotEmpty) {
          snapshot.remove('saved_credentials');
          if (credentials.isNotEmpty) {
            snapshot['saved_credentials'] = jsonEncode(
              credentials.map((credential) => credential.toJson()).toList(),
            );
          }
        }
        return snapshot;
      });

  @override
  Future<void> write(String key, Object value) async {
    final prefs = await SharedPreferences.getInstance();
    if (secureAccountKeys.contains(key)) {
      if (value is! String) {
        throw const SettingsBackupException(
          SettingsBackupErrorCode.unsupportedFieldType,
        );
      }
      switch (key) {
        case 'user_token':
          await _secure.writeToken(value);
        case 'saved_username':
          await _secure.writeUsername(value);
        case 'saved_password':
          await _secure.writePassword(value);
        case 'saved_credentials':
          final Object? decoded = jsonDecode(value);
          if (decoded is! List ||
              decoded.any((item) => item is! Map<String, dynamic>)) {
            throw const SettingsBackupException(
              SettingsBackupErrorCode.invalidFieldFormat,
            );
          }
          await _secure.writeCredentials(
            decoded
                .whereType<Map<String, dynamic>>()
                .map(SavedCredential.fromJson)
                .toList(),
          );
      }
      await _checkWrite(prefs.remove(key));
      return;
    }
    await _checkWrite(switch (value) {
      String() => prefs.setString(key, value),
      bool() => prefs.setBool(key, value),
      int() => prefs.setInt(key, value),
      double() => prefs.setDouble(key, value),
      List<String>() => prefs.setStringList(key, value),
      _ => throw const SettingsBackupException(
        SettingsBackupErrorCode.unsupportedFieldType,
      ),
    });
  }

  @override
  Future<void> remove(String key) async {
    switch (key) {
      case 'user_token':
        await _secure.writeToken(null);
      case 'saved_username':
        await _secure.writeUsername(null);
      case 'saved_password':
        await _secure.writePassword(null);
      case 'saved_credentials':
        await _secure.writeCredentials([]);
    }
    final prefs = await SharedPreferences.getInstance();
    await _checkWrite(prefs.remove(key));
  }

  Future<void> _checkWrite(Future<bool> write) async {
    if (!await write) {
      throw const SettingsBackupException(SettingsBackupErrorCode.writeFailed);
    }
  }
}

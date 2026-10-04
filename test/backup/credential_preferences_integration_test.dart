import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/backup/backup_preferences.dart';
import 'package:kira/backup/backup_runtime.dart';
import 'package:kira/models/copy_account_store.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/utils/settings_backup.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account_storage_test_support.dart';
import 'backup_test_support.dart';

const _prefix = SecureCredentialStore.preferencePrefix;
const _original = SavedCredential(
  username: 'original-user',
  password: 'original-password',
  token: 'original-token',
  userId: 'original-id',
  loginSource: 'hotmanga',
);
const _replacement = SavedCredential(
  username: 'replacement-user',
  password: 'replacement-password',
  token: 'replacement-token',
  userId: 'replacement-id',
  loginSource: 'hotmanga',
);
const _localKeys = {
  'copy_account_v1',
  'backup_webdav_credentials_v1',
  'backup_password_v1',
  'backup_rollback_key_v1',
};

Map<String, Object> _accountValues(SavedCredential account) => {
  'user_token': account.token!,
  'user_username': account.username,
  'user_id': account.userId!,
  'login_source': account.source,
  'saved_username': account.username,
  'saved_password': account.password,
  'saved_credentials': jsonEncode([account.toJson()]),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final user = UserManager();
  late AccountPreferencesPlatform platform;
  late SharedBackupPreferences backend;
  late MemoryBackupJournal journal;
  late SettingsBackupService service;
  late Map<String, Object?> localRecords;

  Map<String, Object?> deviceRecords(SharedPreferences prefs) => {
    for (final key in _localKeys) ...{
      key: prefs.get(key),
      '$_prefix$key': prefs.get('$_prefix$key'),
    },
  };

  setUp(() async {
    platform = AccountPreferencesPlatform()..install();
    SecureCredentialStore.resetInstance();
    user.resumeAccountMutationsAfterRestore();
    backend = SharedBackupPreferences();
    journal = MemoryBackupJournal();
    service = SettingsBackupService(
      preferences: backend,
      journal: journal,
      runtime: SettingsBackupRuntime(),
    );
    for (final entry in _accountValues(_original).entries) {
      await backend.write(entry.key, entry.value);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('banner_visible', true);
    await user.init();
    await user.copyAccount.saveSession(
      const CopyAccountSession(
        token: 'independent-copy-token',
        userId: 'copy-id',
      ),
    );
    final credentials = SecureCredentialStore();
    await credentials.writeWebDavCredentials('device-webdav-secret');
    await credentials.writeBackupPassword('device-backup-password');
    await credentials.writeBackupRollbackKey('device-rollback-key');
    // These aliases must not be removed by a settings/account-only restore.
    for (final key in _localKeys) {
      await prefs.setString(key, 'stale-$key');
    }
    localRecords = deviceRecords(prefs);
  });

  tearDown(() async {
    platform.failKey = null;
    await service.recoverPendingRestore();
    SettingsBackupRuntime().resume();
    SecureCredentialStore.resetInstance();
    platform.dispose();
  });

  Future<void> restartAndExpect(SavedCredential account) async {
    SharedPreferences.resetStatic();
    SecureCredentialStore.resetInstance();
    await user.init();
    expect(user.token, account.token);
    expect(user.userId, account.userId);
    expect(user.savedPassword, account.password);
    expect(user.copyToken, 'independent-copy-token');
    expect(
      await SecureCredentialStore().readWebDavCredentials(),
      'device-webdav-secret',
    );
    expect(
      await SecureCredentialStore().readBackupPassword(),
      'device-backup-password',
    );
    expect(
      await SecureCredentialStore().readBackupRollbackKey(),
      'device-rollback-key',
    );
  }

  for (final version in [1, 2]) {
    test(
      'legacy two-field account backup v$version restores its saved account',
      () async {
        final document = BackupDocument(
          sourceVersion: version,
          categories: {BackupCategory.account},
          preferences: {
            'saved_username': BackupPreference.fromValue('legacy-user'),
            'saved_password': BackupPreference.fromValue('legacy-password'),
          },
        );
        await service.restore(document, {BackupCategory.account});
        expect(user.isLoggedIn, isFalse);
        expect(user.savedCredentials.single.username, 'legacy-user');
        expect(user.savedCredentials.single.password, 'legacy-password');
        final prefs = await SharedPreferences.getInstance();
        expect(deviceRecords(prefs), localRecords);
        SharedPreferences.resetStatic();
        SecureCredentialStore.resetInstance();
        await user.init();
        expect(user.savedCredentials.single.username, 'legacy-user');
      },
    );
  }

  test(
    'legacy remembered credentials survive exporting and restoring',
    () async {
      await backend.write('user_token', '');
      await backend.write('saved_username', 'legacy-user');
      await backend.write('saved_password', 'legacy-password');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('${_prefix}saved_credentials');
      await user.init(persistMigrations: false);
      expect(user.savedCredentials.single.username, 'legacy-user');
      final backup = (await service.capture()).select({BackupCategory.account});
      expect(backup.preferences.containsKey('saved_credentials'), isFalse);
      await service.restore(backup, {BackupCategory.account});
      expect(user.savedCredentials.single.username, 'legacy-user');
      expect(user.savedCredentials.single.password, 'legacy-password');
    },
  );

  test(
    'explicit empty account lists remain empty through backup round trips',
    () async {
      await backend.write('user_token', '');
      await backend.write('saved_username', 'remembered-user');
      await backend.write('saved_password', 'remembered-password');
      await backend.write('saved_credentials', '[]');
      final backup = (await service.capture()).select({BackupCategory.account});
      expect(backup.preferences['saved_credentials']?.value, '[]');
      await service.restore(backup, {BackupCategory.account});
      expect(user.isLoggedIn, isFalse);
      expect(user.savedCredentials, isEmpty);
      SharedPreferences.resetStatic();
      SecureCredentialStore.resetInstance();
      await user.init();
      expect(user.savedCredentials, isEmpty);
    },
  );

  test(
    'prefs-backed export uses logical whitelist and never exports raw records',
    () async {
      final before = Map.of(platform.values);
      final captured = await service.capture();
      expect(captured.preferences['user_token']?.value, _original.token);
      expect(captured.preferences['saved_password']?.value, _original.password);
      expect(
        captured.preferences.keys.where((key) => key.startsWith(_prefix)),
        isEmpty,
      );
      expect(
        captured.preferences.keys.toSet().intersection(_localKeys),
        isEmpty,
      );
      final ordinary = await service.exportPlainText();
      final sensitive = await service.exportPlainText(
        options: const SettingsBackupOptions(includeSensitive: true),
      );
      expect(ordinary, isNot(contains(_original.token)));
      expect(sensitive, contains(_original.token));
      for (final raw in [ordinary, sensitive]) {
        expect(raw, isNot(contains(_prefix)));
        expect(raw, isNot(contains('independent-copy-token')));
        expect(raw, isNot(contains('device-webdav-secret')));
        expect(raw, isNot(contains('device-backup-password')));
        expect(raw, isNot(contains('device-rollback-key')));
      }
      expect(
        platform.values,
        before,
        reason: 'capture must not migrate credentials',
      );
    },
  );

  test(
    'empty current credentials override stale aliases even without migration marker',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('${_prefix}credentials_migrated_to_secure');
      await prefs.setString('${_prefix}user_token', '');
      await prefs.setString('${_prefix}saved_username', '');
      await prefs.setString('${_prefix}saved_password', '');
      await prefs.setString('${_prefix}saved_credentials', '[]');
      for (final entry in _accountValues(_replacement).entries) {
        if (entry.value is String) {
          await prefs.setString(entry.key, '${entry.value}');
        }
      }
      final before = Map.of(platform.values);
      final account = (await service.capture()).select({
        BackupCategory.account,
      });
      expect(account.preferences['user_token']?.value, '');
      expect(account.preferences['saved_username']?.value, '');
      expect(account.preferences['saved_password']?.value, '');
      expect(account.preferences['saved_credentials']?.value, '[]');
      expect(
        jsonEncode(account.toJson()),
        isNot(contains(_replacement.password)),
      );
      expect(platform.values, before);
    },
  );

  for (final category in [BackupCategory.settings, BackupCategory.account]) {
    test(
      '$category restore preserves local records and survives repeated cold starts',
      () async {
        final replacement = category == BackupCategory.settings
            ? backupDocument({'banner_visible': false})
            : backupDocument(_accountValues(_replacement));
        await service.restore(replacement, {category});
        final prefs = await SharedPreferences.getInstance();
        expect(deviceRecords(prefs), localRecords);
        expect(journal.pending, isNull);
        final expected = category == BackupCategory.settings
            ? _original
            : _replacement;
        await restartAndExpect(expected);
        await restartAndExpect(expected);
      },
    );
  }

  for (final throwsOnWrite in [false, true]) {
    test(
      'prefs credential write ${throwsOnWrite ? 'throw' : 'false'} rolls back without touching local records',
      () async {
        platform.failKey = '${_prefix}saved_password';
        platform.failValue = _replacement.password;
        platform.throwOnFailure = throwsOnWrite;
        await expectLater(
          service.restore(backupDocument(_accountValues(_replacement)), {
            BackupCategory.account,
          }),
          throwsA(
            isA<SettingsBackupException>().having(
              (error) => error.code,
              'code',
              SettingsBackupErrorCode.writeFailed,
            ),
          ),
        );
        expect(journal.pending, isNull);
        expect(
          deviceRecords(await SharedPreferences.getInstance()),
          localRecords,
        );
        expect(user.token, _original.token);
        await restartAndExpect(_original);
      },
    );
  }

  test(
    'settings rollback preserves both logins and every local credential',
    () async {
      final failingRuntime = TestBackupRuntime(
        delegate: SettingsBackupRuntime(),
      )..failReloads = 1;
      final failingService = SettingsBackupService(
        preferences: backend,
        journal: journal,
        runtime: failingRuntime,
      );
      await expectLater(
        failingService.restore(backupDocument({'banner_visible': false}), {
          BackupCategory.settings,
        }),
        throwsA(
          isA<SettingsBackupException>().having(
            (error) => error.code,
            'code',
            SettingsBackupErrorCode.writeFailed,
          ),
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('banner_visible'), isTrue);
      expect(deviceRecords(prefs), localRecords);
      await restartAndExpect(_original);
    },
  );

  test(
    'full reset removes current credentials and all legacy aliases',
    () async {
      await service.clearAllPreferences();
      SharedPreferences.resetStatic();
      SecureCredentialStore.resetInstance();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty);
      final credentials = SecureCredentialStore();
      expect(await credentials.readToken(), isNull);
      expect(await credentials.readCredentials(), isEmpty);
      expect(await credentials.readCopyAccountRecord(), isNull);
      expect(await credentials.readWebDavCredentials(), isNull);
      expect(await credentials.readBackupPassword(), isNull);
      expect(await credentials.readBackupRollbackKey(), isNull);
      await user.init();
      expect(user.isLoggedIn, isFalse);
      expect(user.copyAccount.isLoggedIn, isFalse);
    },
  );
}

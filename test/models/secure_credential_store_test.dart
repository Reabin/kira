import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/models/user_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _reservedPrefixes = [
  'VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu',
  'VGhpcyBpcyB0aGUgcHJlZml4IGZvciBCaWdJbnRlZ2Vy',
  'VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu',
];

class _PreferencesPlatform {
  static const channel = MethodChannel('plugins.flutter.io/shared_preferences');
  final values = <String, Object>{};
  String? failWriteKey;
  String? failDeleteKey;
  bool throwOnFailure = false;
  bool cacheFailedMutations = false;
  bool rejectReservedStrings = false;
  Map<String, Object>? nativeCache;
  final removals = <String>[];
  Future<void> Function(String key)? beforeRemove;

  void seed(Map<String, Object> entries) {
    for (final entry in entries.entries) {
      values['flutter.${entry.key}'] = entry.value;
    }
  }

  Object? value(String key) => values['flutter.$key'];

  void install() {
    SharedPreferences.resetStatic();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getAll') return Map.of(nativeCache ?? values);
          final arguments = call.arguments;
          if (arguments is! Map) throw StateError('Missing arguments');
          final key = arguments['key'];
          if (key is! String) throw StateError('Missing preference key');
          if (call.method == 'remove') {
            removals.add(key);
            await beforeRemove?.call(key);
            if (key == 'flutter.$failDeleteKey') {
              failDeleteKey = null;
              if (cacheFailedMutations) {
                (nativeCache ??= Map.of(values)).remove(key);
              }
              if (throwOnFailure) throw PlatformException(code: 'injected');
              return false;
            }
            (nativeCache ?? values).remove(key);
            if (nativeCache != null) {
              values
                ..clear()
                ..addAll(nativeCache!);
            }
            return true;
          }
          if (call.method.startsWith('set')) {
            final value = arguments['value'];
            if (rejectReservedStrings &&
                call.method == 'setString' &&
                value is String &&
                _reservedPrefixes.any(value.startsWith)) {
              throw PlatformException(code: 'reserved_string_prefix');
            }
            if (key == 'flutter.$failWriteKey') {
              failWriteKey = null;
              if (cacheFailedMutations && value != null) {
                (nativeCache ??= Map.of(values))[key] = value;
              }
              if (throwOnFailure) throw PlatformException(code: 'injected');
              return false;
            }
            if (value != null) (nativeCache ?? values)[key] = value;
            if (nativeCache != null) {
              values
                ..clear()
                ..addAll(nativeCache!);
            }
            return true;
          }
          throw StateError('Unexpected preferences method');
        });
  }

  void dispose() {
    SharedPreferences.resetStatic();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

Future<void> _migrate(SecureCredentialStore store) async {
  final prefs = await SharedPreferences.getInstance();
  await store.migrateFromSharedPreferences(
    {for (final key in prefs.getKeys()) key: prefs.get(key)},
    (key) async {
      if (!await prefs.remove(key)) throw StateError('Legacy removal failed');
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _PreferencesPlatform platform;
  late SecureCredentialStore store;

  setUp(() {
    platform = _PreferencesPlatform()..install();
    SecureCredentialStore.resetInstance();
    store = SecureCredentialStore();
  });

  tearDown(() {
    SecureCredentialStore.resetInstance();
    platform.dispose();
  });

  group('private preferences persistence', () {
    for (final prefix in _reservedPrefixes) {
      test(
        'Android-reserved prefix $prefix round trips without loss',
        () async {
          platform.rejectReservedStrings = true;
          final value = '$prefix secret 空格 🔑';
          await store.writeToken(value);
          await store.writePassword(value);
          await store.writeBackupPassword(value);
          SharedPreferences.resetStatic();
          SecureCredentialStore.resetInstance();
          final restored = SecureCredentialStore();
          expect(await restored.readToken(), value);
          expect(await restored.readPassword(), value);
          expect(await restored.readBackupPassword(), value);
          expect(platform.value('secure_mirror_saved_password'), [value]);
        },
      );
    }
    test(
      'all credential types survive recreated stores and prefs caches',
      () async {
        await store.writeToken('token-1');
        await store.writeUsername('alice');
        await store.writePassword(' secret with spaces ');
        await store.writeCredentials([
          const SavedCredential(
            username: 'alice',
            password: 'pw',
            token: 'tok',
          ),
        ]);
        await store.writeCopyAccountRecord('{"migrationHandled":true}');
        await store.writeWebDavCredentials('{"password":"dav-password"}');
        await store.writeBackupPassword(' backup password ');
        await store.writeBackupRollbackKey('rollback-key');

        for (var restart = 0; restart < 3; restart++) {
          SharedPreferences.resetStatic();
          SecureCredentialStore.resetInstance();
          final restored = SecureCredentialStore();
          expect(await restored.readToken(), 'token-1');
          expect(await restored.readUsername(), 'alice');
          expect(await restored.readPassword(), ' secret with spaces ');
          expect((await restored.readCredentials()).single.token, 'tok');
          expect(
            await restored.readCopyAccountRecord(),
            '{"migrationHandled":true}',
          );
          expect(
            await restored.readWebDavCredentials(),
            '{"password":"dav-password"}',
          );
          expect(await restored.readBackupPassword(), ' backup password ');
          expect(await restored.readBackupRollbackKey(), 'rollback-key');
        }
        expect(platform.value('secure_mirror_user_token'), 'token-1');
        expect(platform.value('user_token'), isNull);
      },
    );

    test('does not call the former secure storage platform channel', () async {
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls++;
            throw StateError('Secure storage must not be used');
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      expect(await store.readToken(), isNull);
      await store.writeToken('new-login');
      await store.writePassword('password');
      await _migrate(store);
      SharedPreferences.resetStatic();
      SecureCredentialStore.resetInstance();
      expect(await SecureCredentialStore().readToken(), 'new-login');
      await SecureCredentialStore().deleteAll();
      expect(calls, 0);
    });

    test(
      'old mirrors are directly readable without writes or migration',
      () async {
        platform.seed({
          'secure_mirror_user_token': 'mirror-token',
          'secure_mirror_saved_username': 'alice',
          'secure_mirror_saved_password': 'pw',
          'secure_mirror_saved_credentials':
              '[{"username":"alice","password":"pw"}]',
          'secure_mirror_copy_account_v1': '{"accounts":[],"cleared":true}',
          'secure_mirror_backup_webdav_credentials_v1': 'dav-record',
          'secure_mirror_backup_password_v1': 'backup-pw',
          'secure_mirror_backup_rollback_key_v1': 'rollback-key',
        });
        final before = Map.of(platform.values);

        expect(await store.readToken(), 'mirror-token');
        expect(await store.readUsername(), 'alice');
        expect(await store.readPassword(), 'pw');
        expect((await store.readCredentials()).single.username, 'alice');
        expect(
          await store.readCopyAccountRecord(),
          '{"accounts":[],"cleared":true}',
        );
        expect(await store.readWebDavCredentials(), 'dav-record');
        expect(await store.readBackupPassword(), 'backup-pw');
        expect(await store.readBackupRollbackKey(), 'rollback-key');
        expect(platform.values, before);
      },
    );

    test(
      'legacy reads are side-effect free before account initialization',
      () async {
        platform.seed({
          'user_token': 'legacy-token',
          'saved_username': 'legacy-user',
          'saved_password': 'legacy-password',
          'saved_credentials': '[{"username":"legacy-user","password":"pw"}]',
          'backup_rollback_key_v1': 'legacy-key',
        });
        final before = Map.of(platform.values);
        expect(await store.readBackupRollbackKey(), 'legacy-key');
        expect(await store.readToken(), 'legacy-token');
        expect(await store.readUsername(), 'legacy-user');
        expect(await store.readPassword(), 'legacy-password');
        expect((await store.readCredentials()).single.username, 'legacy-user');
        expect(platform.values, before);
      },
    );

    test('explicit empty records take precedence over legacy values', () async {
      platform.seed({
        'secure_mirror_user_token': '',
        'user_token': 'obsolete-token',
        'secure_mirror_saved_credentials': '[]',
        'saved_credentials': '[{"username":"obsolete","password":"pw"}]',
        'secure_mirror_copy_account_v1': '{"accounts":[],"cleared":true}',
        'copy_account_v1': '{"session":{"token":"obsolete"}}',
      });
      expect(await store.readToken(), '');
      expect(await store.readCredentials(), isEmpty);
      expect(
        await store.readCopyAccountRecord(),
        '{"accounts":[],"cleared":true}',
      );
      await _migrate(store);
      SharedPreferences.resetStatic();
      SecureCredentialStore.resetInstance();
      expect(await SecureCredentialStore().readToken(), '');
      expect(await SecureCredentialStore().readCredentials(), isEmpty);
    });

    test(
      'malformed primary data is not silently replaced by a stale alias',
      () async {
        platform.seed({
          'secure_mirror_user_token': false,
          'user_token': 'obsolete-token',
        });
        await expectLater(store.readToken(), throwsFormatException);
        await expectLater(_migrate(store), throwsFormatException);
        expect(platform.value('secure_mirror_user_token'), isFalse);
        expect(platform.value('user_token'), 'obsolete-token');
      },
    );

    for (final markerKey in [
      'secure_mirror_credentials_migrated_to_secure',
      'credentials_migrated_to_secure',
    ]) {
      test(
        'old marker $markerKey suppresses cleared saved fields, not token',
        () async {
          platform.seed({
            markerKey: 'true',
            'user_token': 'legacy-token',
            'saved_username': 'obsolete',
            'saved_password': 'obsolete-password',
            'saved_credentials': '[{"username":"obsolete","password":"pw"}]',
          });
          expect(await store.readToken(), 'legacy-token');
          expect(await store.readUsername(), isNull);
          expect(await store.readPassword(), isNull);
          expect(await store.readCredentials(), isEmpty);
          await _migrate(store);
          expect(await store.readToken(), 'legacy-token');
          expect(await store.readPassword(), isNull);
          expect(platform.value('saved_password'), isNull);
        },
      );
    }
  });

  group('legacy migration', () {
    test(
      'copies every supported legacy credential before removing aliases',
      () async {
        const rawCredentials =
            ' [ {"username":"alice", "password":"pw", "futureField":42} ] ';
        final legacy = <String, Object>{
          'user_token': 'legacy-token',
          'saved_username': 'alice',
          'saved_password': ' password ',
          'saved_credentials': rawCredentials,
          'copy_account_v1':
              '{"migrationHandled":true,"session":{"token":"copy"}}',
          'backup_webdav_credentials_v1': 'dav-record',
          'backup_password_v1': 'backup-password',
          'backup_rollback_key_v1': 'rollback-key',
        };
        platform.seed(legacy);
        await _migrate(store);
        for (final entry in legacy.entries) {
          expect(platform.value(entry.key), isNull);
          expect(platform.value('secure_mirror_${entry.key}'), entry.value);
        }
        expect(
          platform.value('secure_mirror_saved_credentials'),
          rawCredentials,
        );
        expect(await store.credentialsMigrated(), isTrue);
        final after = Map.of(platform.values);
        await _migrate(store);
        expect(platform.values, after);
      },
    );

    test(
      'does not overwrite newer records when the migration marker is absent',
      () async {
        platform.seed({
          'user_token': 'old-token',
          'saved_username': 'old-user',
          'saved_password': 'old-password',
          'saved_credentials': '[{"username":"old-user","password":"old"}]',
          'secure_mirror_user_token': 'new-token',
          'secure_mirror_saved_username': 'new-user',
          'secure_mirror_saved_password': 'new-password',
          'secure_mirror_saved_credentials':
              '[{"username":"new-user","password":"new"}]',
        });
        await _migrate(store);
        expect(await store.readToken(), 'new-token');
        expect(await store.readUsername(), 'new-user');
        expect(await store.readPassword(), 'new-password');
        expect((await store.readCredentials()).single.username, 'new-user');
        expect(platform.value('user_token'), isNull);
      },
    );

    test(
      'a failed migration write preserves all legacy sources for retry',
      () async {
        platform.seed({
          'user_token': 'legacy-token',
          'saved_username': 'alice',
          'saved_password': 'pw',
        });
        platform.failWriteKey = 'secure_mirror_saved_password';
        await expectLater(_migrate(store), throwsStateError);
        expect(platform.value('user_token'), 'legacy-token');
        expect(platform.value('saved_username'), 'alice');
        expect(platform.value('saved_password'), 'pw');
        expect(platform.value('secure_mirror_saved_password'), isNull);
        expect(await store.readPassword(), 'pw');

        await _migrate(store);
        expect(platform.value('saved_password'), isNull);
        expect(await store.readToken(), 'legacy-token');
        expect(await store.readPassword(), 'pw');
      },
    );

    test(
      'a failed migration marker does not delete the original data',
      () async {
        platform.seed({'saved_password': 'pw'});
        platform.failWriteKey = 'secure_mirror_credentials_migrated_to_secure';
        await expectLater(_migrate(store), throwsStateError);
        expect(platform.value('saved_password'), 'pw');
        expect(await store.credentialsMigrated(), isFalse);
        await _migrate(store);
        expect(platform.value('saved_password'), isNull);
        expect(await store.readPassword(), 'pw');
      },
    );

    test(
      'a queued migration cannot resurrect a concurrently deleted password',
      () async {
        platform.seed({
          'saved_password': 'old-password',
          'secure_mirror_saved_password': 'current-password',
        });
        final prefs = await SharedPreferences.getInstance();
        final snapshot = {
          for (final key in prefs.getKeys()) key: prefs.get(key),
        };
        final deleting = Completer<void>();
        final release = Completer<void>();
        platform.beforeRemove = (key) async {
          if (key == 'flutter.saved_password') {
            deleting.complete();
            await release.future;
          }
        };
        final deletion = store.writePassword(null);
        await deleting.future;
        final migration = store.migrateFromSharedPreferences(snapshot, (
          key,
        ) async {
          await prefs.remove(key);
        });
        release.complete();
        await deletion;
        await migration;
        expect(await store.readPassword(), isNull);
        expect(platform.value('saved_password'), isNull);
        expect(platform.value('secure_mirror_saved_password'), isNull);
      },
    );
  });

  group('deletion and persistence failures', () {
    test(
      'failed native writes restore the value rather than reloading dirty cache',
      () async {
        await store.writeToken('persisted-token');
        platform.cacheFailedMutations = true;
        platform.failWriteKey = 'secure_mirror_user_token';
        await expectLater(store.writeToken('failed-token'), throwsStateError);
        expect(await store.readToken(), 'persisted-token');
        expect(platform.value('secure_mirror_user_token'), 'persisted-token');
        await store.writeToken('retry-token');
        platform.nativeCache = null;
        SharedPreferences.resetStatic();
        SecureCredentialStore.resetInstance();
        expect(await SecureCredentialStore().readToken(), 'retry-token');
      },
    );

    test(
      'failed native deletes retain the prior value and can be retried',
      () async {
        await store.writePassword('persisted-password');
        platform.cacheFailedMutations = true;
        platform.failDeleteKey = 'secure_mirror_saved_password';
        await expectLater(store.writePassword(null), throwsStateError);
        expect(await store.readPassword(), 'persisted-password');
        await store.writePassword(null);
        platform.nativeCache = null;
        SharedPreferences.resetStatic();
        SecureCredentialStore.resetInstance();
        expect(await SecureCredentialStore().readPassword(), isNull);
      },
    );

    test('cache absence never skips the physical delete', () async {
      platform.seed({'secure_mirror_saved_password': 'still-on-disk'});
      platform.nativeCache = {};
      await store.writePassword(null);
      expect(
        platform.removals,
        contains('flutter.secure_mirror_saved_password'),
      );
      platform.nativeCache = null;
      SharedPreferences.resetStatic();
      SecureCredentialStore.resetInstance();
      expect(await SecureCredentialStore().readPassword(), isNull);
    });
    test(
      'an explicitly cleared list remains distinguishable from missing data',
      () async {
        expect(await store.hasCredentialsRecord(), isFalse);
        await store.writeUsername('old-user');
        await store.writePassword('old-password');
        await store.writeCredentials([]);
        SharedPreferences.resetStatic();
        SecureCredentialStore.resetInstance();
        final restored = SecureCredentialStore();
        expect(await restored.hasCredentialsRecord(), isTrue);
        expect(await restored.readCredentials(), isEmpty);
        expect(platform.value('secure_mirror_saved_credentials'), '[]');
      },
    );
    test(
      'logout stays logged out after repeated restarts with a stale alias',
      () async {
        platform.seed({'user_token': 'obsolete-token'});
        await store.writeToken('current-token');
        await store.writeToken(null);
        for (var restart = 0; restart < 3; restart++) {
          SharedPreferences.resetStatic();
          SecureCredentialStore.resetInstance();
          expect(await SecureCredentialStore().readToken(), '');
        }
      },
    );

    test(
      'optional deletions clear both primary records and legacy aliases',
      () async {
        platform.seed({
          'saved_username': 'old-user',
          'saved_password': 'old-password',
          'saved_credentials': '[{"username":"old","password":"pw"}]',
          'backup_webdav_credentials_v1': 'old-dav',
          'backup_password_v1': 'old-backup',
          'backup_rollback_key_v1': 'old-key',
        });
        await store.writeUsername('new-user');
        await store.writePassword('new-password');
        await store.writeCredentials([
          const SavedCredential(username: 'new', password: 'pw'),
        ]);
        await store.writeWebDavCredentials('new-dav');
        await store.writeBackupPassword('new-backup');
        await store.writeBackupRollbackKey('new-key');
        await store.writeUsername('');
        await store.writePassword(null);
        await store.writeCredentials([]);
        await store.writeWebDavCredentials(null);
        await store.writeBackupPassword(null);
        await store.writeBackupRollbackKey(null);
        SharedPreferences.resetStatic();
        SecureCredentialStore.resetInstance();
        final restored = SecureCredentialStore();
        expect(await restored.readUsername(), isNull);
        expect(await restored.readPassword(), isNull);
        expect(await restored.readCredentials(), isEmpty);
        expect(await restored.readWebDavCredentials(), isNull);
        expect(await restored.readBackupPassword(), isNull);
        expect(await restored.readBackupRollbackKey(), isNull);
      },
    );

    for (final throwOnFailure in [false, true]) {
      test(
        'failed write ($throwOnFailure) reloads cache and permits retry',
        () async {
          await store.writeToken('persisted-token');
          platform.failWriteKey = 'secure_mirror_user_token';
          platform.throwOnFailure = throwOnFailure;
          await expectLater(
            store.writeToken('failed-token'),
            throwsA(anything),
          );
          expect(await store.readToken(), 'persisted-token');
          expect(platform.value('secure_mirror_user_token'), 'persisted-token');
          await store.writeToken('retry-token');
          SharedPreferences.resetStatic();
          SecureCredentialStore.resetInstance();
          expect(await SecureCredentialStore().readToken(), 'retry-token');
        },
      );
    }

    test(
      'failed alias deletion leaves the primary record authoritative',
      () async {
        platform.seed({
          'saved_password': 'obsolete-password',
          'secure_mirror_saved_password': 'current-password',
        });
        platform.failDeleteKey = 'saved_password';
        await expectLater(store.writePassword(null), throwsStateError);
        expect(await store.readPassword(), 'current-password');
        expect(platform.value('saved_password'), 'obsolete-password');
        expect(
          platform.value('secure_mirror_saved_password'),
          'current-password',
        );
        await store.writePassword(null);
        expect(await store.readPassword(), isNull);
      },
    );

    test(
      'failed primary deletion refreshes the optimistic prefs cache',
      () async {
        platform.seed({
          'saved_password': 'obsolete-password',
          'secure_mirror_saved_password': 'current-password',
        });
        platform.failDeleteKey = 'secure_mirror_saved_password';
        await expectLater(store.writePassword(null), throwsStateError);
        expect(await store.readPassword(), 'current-password');
        expect(platform.value('saved_password'), isNull);
        await store.writePassword(null);
        expect(await store.readPassword(), isNull);
      },
    );

    test(
      'deleteAll clears credential aliases without deleting settings or cache',
      () async {
        platform.seed({
          'user_token': 'legacy-token',
          'saved_password': 'legacy-password',
          'copy_account_v1': 'legacy-copy',
          'backup_rollback_key_v1': 'legacy-key',
          'theme_mode': 'dark',
          'cache_test': 'cached-data',
        });
        await store.writeToken('token');
        await store.writeUsername('alice');
        await store.writePassword('pw');
        await store.writeCredentials([
          const SavedCredential(username: 'alice', password: 'pw'),
        ]);
        await store.writeCopyAccountRecord('copy');
        await store.writeWebDavCredentials('dav');
        await store.writeBackupPassword('backup');
        await store.writeBackupRollbackKey('key');
        await store.deleteAll();
        SharedPreferences.resetStatic();
        SecureCredentialStore.resetInstance();
        expect(await SecureCredentialStore().readToken(), isNull);
        expect(await SecureCredentialStore().readPassword(), isNull);
        expect(await SecureCredentialStore().readCopyAccountRecord(), isNull);
        expect(await SecureCredentialStore().readBackupRollbackKey(), isNull);
        expect(platform.values, {
          'flutter.theme_mode': 'dark',
          'flutter.cache_test': 'cached-data',
        });
      },
    );
  });

  group('write queue across test zones', () {
    late InMemorySecureCredentialStore memory;

    setUp(() async {
      memory = InMemorySecureCredentialStore();
      await memory.writeToken('before-widget-zone');
    });

    testWidgets('completed writes do not retain a previous Zone', (
      tester,
    ) async {
      await memory.writeToken('inside-widget-zone');
      expect(await memory.readToken(), 'inside-widget-zone');
    });
  });

  group('in-memory test implementation', () {
    late InMemorySecureCredentialStore memory;

    setUp(() {
      memory = InMemorySecureCredentialStore();
      SecureCredentialStore.setInstance(memory);
    });

    test(
      'supports round trips, optional deletion and independent storage',
      () async {
        platform.seed({
          'user_token': 'real-legacy-token',
          'saved_password': 'real-password',
        });
        final before = Map.of(platform.values);
        expect(await memory.readToken(), isNull);
        expect(await memory.readPassword(), isNull);
        await memory.writeToken('memory-token');
        await memory.writeUsername('alice');
        await memory.writePassword('pw');
        await memory.writeCredentials([
          const SavedCredential(username: 'alice', password: 'pw'),
          const SavedCredential(
            username: 'bob',
            password: 'pw',
            token: 'token',
          ),
        ]);
        expect(await memory.readToken(), 'memory-token');
        expect(await memory.readUsername(), 'alice');
        expect((await memory.readCredentials()).length, 2);
        await memory.writeUsername(null);
        await memory.writePassword('');
        expect(await memory.readUsername(), isNull);
        expect(await memory.readPassword(), isNull);
        await memory.deleteAll();
        expect(await memory.readCredentials(), isEmpty);
        expect(platform.values, before);
      },
    );

    test('preserves raw credential JSON during migration', () async {
      const raw = '[{"username":"alice","password":"pw","futureField":42}]';
      final legacy = <String, Object?>{'saved_credentials': raw};
      await memory.migrateFromSharedPreferences(legacy, (key) async {
        legacy.remove(key);
      });
      expect(await memory.doRead('saved_credentials'), raw);
      expect(await memory.credentialsMigrated(), isTrue);
      expect(legacy, isEmpty);
      expect(platform.values, isEmpty);
    });

    test('invalid credential JSON does not crash account loading', () async {
      await memory.doWrite('saved_credentials', '{{invalid json');
      expect(await memory.readCredentials(), isEmpty);
    });

    test('filters records without account identity', () async {
      await memory.writeCredentials([
        const SavedCredential(username: '', password: 'pw'),
        const SavedCredential(username: 'valid', password: 'pw'),
      ]);
      expect((await memory.readCredentials()).single.username, 'valid');
    });
  });

  test('credential key recognition excludes unrelated preferences', () {
    for (final key in [
      'user_token',
      'saved_credentials',
      'copy_account_v1',
      'backup_webdav_credentials_v1',
      'backup_password_v1',
      'backup_rollback_key_v1',
      'credentials_migrated_to_secure',
    ]) {
      expect(SecureCredentialStore.logicalKeyForPreference(key), key);
      expect(
        SecureCredentialStore.logicalKeyForPreference('secure_mirror_$key'),
        key,
      );
    }
    expect(SecureCredentialStore.logicalKeyForPreference('theme_mode'), isNull);
    expect(
      SecureCredentialStore.logicalKeyForPreference('secure_mirror_unknown'),
      isNull,
    );
  });
}

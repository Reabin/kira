import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/models/user_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Secure layer backed by a controllable map: reads can be made to throw to
/// simulate a broken keystore, and the mirror layer stays enabled so the
/// prefs fallback can be exercised.
class _MirrorableStore extends InMemorySecureCredentialStore {
  final secure = <String, String?>{};
  bool failSecureReads = false;

  @override
  bool get mirrorEnabled => true;

  @override
  Future<String?> doRead(String key) async {
    if (failSecureReads) {
      throw StateError('Injected secure read failure');
    }
    return secure[key];
  }

  @override
  Future<void> doWrite(String key, String value) async {
    secure[key] = value;
  }

  @override
  Future<void> doDelete(String key) async {
    secure.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemorySecureCredentialStore store;

  setUp(() {
    store = InMemorySecureCredentialStore();
    SecureCredentialStore.setInstance(store);
  });

  tearDown(() {
    SecureCredentialStore.resetInstance();
  });

  // ── Username round-trip ──────────────────────────────────────────────

  group('writeUsername / readUsername', () {
    test('round-trip for non-empty value', () async {
      await store.writeUsername('alice');
      expect(await store.readUsername(), 'alice');
    });

    test('null value deletes the key', () async {
      await store.writeUsername('alice');
      await store.writeUsername(null);
      expect(await store.readUsername(), isNull);
    });

    test('empty string deletes the key', () async {
      await store.writeUsername('alice');
      await store.writeUsername('');
      expect(await store.readUsername(), isNull);
    });
  });

  // ── Password round-trip ──────────────────────────────────────────────

  group('writePassword / readPassword', () {
    test('round-trip for non-empty value', () async {
      await store.writePassword('secret123');
      expect(await store.readPassword(), 'secret123');
    });

    test('null value deletes the key', () async {
      await store.writePassword('secret123');
      await store.writePassword(null);
      expect(await store.readPassword(), isNull);
    });

    test('empty string deletes the key', () async {
      await store.writePassword('secret123');
      await store.writePassword('');
      expect(await store.readPassword(), isNull);
    });
  });

  // ── Credentials round-trip ───────────────────────────────────────────

  group('writeCredentials / readCredentials', () {
    test('round-trip with 2 SavedCredential items', () async {
      final creds = [
        const SavedCredential(username: 'user1', password: 'pass1'),
        const SavedCredential(
          username: 'user2',
          password: 'pass2',
          token: 'tok',
          loginSource: 'hotmanga',
        ),
      ];
      await store.writeCredentials(creds);
      final result = await store.readCredentials();
      expect(result.length, 2);
      expect(result[0].username, 'user1');
      expect(result[0].password, 'pass1');
      expect(result[1].username, 'user2');
      expect(result[1].password, 'pass2');
      expect(result[1].token, 'tok');
      expect(result[1].loginSource, 'hotmanga');
    });

    test('returns empty list when nothing stored', () async {
      expect(await store.readCredentials(), <SavedCredential>[]);
    });

    test('empty list deletes the key', () async {
      await store.writeCredentials([
        const SavedCredential(username: 'u', password: 'p'),
      ]);
      await store.writeCredentials([]);
      expect(await store.readCredentials(), <SavedCredential>[]);
    });

    test('handles corrupted JSON gracefully', () async {
      // Write raw corrupted data directly
      await store.doWrite('saved_credentials', '{{invalid json');
      expect(await store.readCredentials(), <SavedCredential>[]);
    });

    test('filters out entries with empty username', () async {
      final creds = [
        const SavedCredential(username: '', password: 'p'),
        const SavedCredential(username: 'valid', password: 'p'),
      ];
      await store.writeCredentials(creds);
      final result = await store.readCredentials();
      expect(result.length, 1);
      expect(result.first.username, 'valid');
    });
  });

  // ── deleteAll ────────────────────────────────────────────────────────

  group('deleteAll', () {
    test('clears all stored keys', () async {
      await store.writeUsername('alice');
      await store.writePassword('secret');
      await store.writeCredentials([
        const SavedCredential(username: 'u', password: 'p'),
      ]);

      await store.deleteAll();

      expect(await store.readUsername(), isNull);
      expect(await store.readPassword(), isNull);
      expect(await store.readCredentials(), <SavedCredential>[]);
    });
  });

  // ── Migration ─────────────────────────────────────────────────────────

  group('migrateFromSharedPreferences', () {
    test('moves old values and calls removePref for each key', () async {
      final removedKeys = <String>[];
      final prefsMap = <String, Object?>{
        'saved_username': 'old_user',
        'saved_password': 'old_pass',
        'saved_credentials': jsonEncode([
          {'username': 'cred_user', 'password': 'cred_pass'},
        ]),
      };

      await store.migrateFromSharedPreferences(
        prefsMap,
        (key) async => removedKeys.add(key),
      );

      expect(await store.readUsername(), 'old_user');
      expect(await store.readPassword(), 'old_pass');
      expect(removedKeys, [
        'saved_username',
        'saved_password',
        'saved_credentials',
      ]);

      // Migrated flag should be set
      expect(await store.doRead('credentials_migrated_to_secure'), 'true');
    });

    test('is idempotent — second call does nothing', () async {
      final removedKeys = <String>[];
      final prefsMap = <String, Object?>{
        'saved_username': 'old_user',
        'saved_password': 'old_pass',
      };

      await store.migrateFromSharedPreferences(
        prefsMap,
        (key) async => removedKeys.add(key),
      );
      final firstRemoveCount = removedKeys.length;

      // Second call — should skip because migrated flag is set
      await store.migrateFromSharedPreferences(
        prefsMap,
        (key) async => removedKeys.add(key),
      );

      expect(removedKeys.length, firstRemoveCount);
    });

    test('skips empty values in prefs map', () async {
      final removedKeys = <String>[];
      final prefsMap = <String, Object?>{
        'saved_username': '',
        'saved_password': '',
      };

      await store.migrateFromSharedPreferences(
        prefsMap,
        (key) async => removedKeys.add(key),
      );

      // Empty strings should not be written to secure storage
      expect(await store.readUsername(), isNull);
      expect(await store.readPassword(), isNull);
      // But removePref should still be called for cleanup
      expect(removedKeys, [
        'saved_username',
        'saved_password',
        'saved_credentials',
      ]);
    });
  });

  // ── Prefs mirror (dual-write fallback) ───────────────────────────────

  group('prefs mirror', () {
    late _MirrorableStore mirrorStore;
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      mirrorStore = _MirrorableStore();
    });

    test('writes are mirrored into prefs', () async {
      await mirrorStore.writeToken('token-1');
      await mirrorStore.writeUsername('alice');

      expect(prefs.getString('secure_mirror_user_token'), 'token-1');
      expect(prefs.getString('secure_mirror_saved_username'), 'alice');
      expect(await mirrorStore.readToken(), 'token-1');
      expect(await mirrorStore.readUsername(), 'alice');
    });

    test(
      'read falls back to the mirror and heals secure storage after a wipe',
      () async {
        await mirrorStore.writeToken('token-1');
        await mirrorStore.writePassword('pw');
        mirrorStore.secure.clear();

        expect(await mirrorStore.readToken(), 'token-1');
        expect(await mirrorStore.readPassword(), 'pw');
        // The mirror hit is written back so the primary layer recovers.
        expect(mirrorStore.secure['user_token'], 'token-1');
        expect(mirrorStore.secure['saved_password'], 'pw');
      },
    );

    test('read falls back when secure storage throws', () async {
      await mirrorStore.writeCredentials([
        const SavedCredential(username: 'u', password: 'p'),
      ]);
      mirrorStore.failSecureReads = true;

      final creds = await mirrorStore.readCredentials();
      expect(creds.single.username, 'u');
      expect(creds.single.password, 'p');
    });

    test(
      'logout tombstone survives a secure wipe without resurrecting',
      () async {
        await mirrorStore.writeToken('token-1');
        await mirrorStore.writeToken(null);
        mirrorStore.secure.clear();

        // The mirrored empty string is the logout marker: an empty secure
        // layer must not bring the old token back.
        expect(await mirrorStore.readToken(), '');
      },
    );

    test('deletes clear the mirror', () async {
      await mirrorStore.writePassword('pw');
      await mirrorStore.writePassword(null);
      mirrorStore.secure.clear();

      expect(prefs.getString('secure_mirror_saved_password'), isNull);
      expect(await mirrorStore.readPassword(), isNull);
    });

    test('deleteAll clears mirrors too', () async {
      await mirrorStore.writeToken('token-1');
      await mirrorStore.writeUsername('alice');
      await mirrorStore.writePassword('pw');

      await mirrorStore.deleteAll();
      mirrorStore.secure.clear();

      expect(await mirrorStore.readToken(), isNull);
      expect(await mirrorStore.readUsername(), isNull);
      expect(await mirrorStore.readPassword(), isNull);
      expect(
        prefs.getKeys().where((key) => key.startsWith('secure_mirror_')),
        isEmpty,
      );
    });

    test('migration seeds the mirrors', () async {
      await mirrorStore.migrateFromSharedPreferences({
        'saved_username': 'old_user',
        'saved_password': 'old_pass',
      }, (key) async {});

      expect(prefs.getString('secure_mirror_saved_username'), 'old_user');
      expect(prefs.getString('secure_mirror_saved_password'), 'old_pass');
    });

    test('mirror stays disabled for the in-memory store', () async {
      await store.writeUsername('alice');

      expect(
        prefs.getKeys().where((key) => key.startsWith('secure_mirror_')),
        isEmpty,
      );
    });
  });
}

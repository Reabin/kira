import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/copy_account_store.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/models/user_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final secureCalls = <MethodCall>[];
  setUp(() {
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({});
    secureCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          secureCalls.add(call);
          throw PlatformException(code: 'unexpected_secure_storage_call');
        });
  });
  tearDown(() {
    teardownSecureCredentialStoreForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
    expect(secureCalls, isEmpty, reason: 'Credentials must only use prefs');
  });

  test(
    'comment display settings are shared through facade and sub-store',
    () async {
      final user = UserManager();
      await user.init();
      await user.setCommentShowAvatar(false);
      await user.setCommentShowUserName(false);
      await user.setCommentShowTime(false);
      expect(user.comment.showAvatar, isFalse);
      expect(user.comment.showUserName, isFalse);
      expect(user.comment.showTime, isFalse);
      await user.comment.setShowAvatar(true);
      await user.comment.setShowUserName(true);
      await user.comment.setShowTime(true);
      expect(user.commentShowAvatar, isTrue);
      expect(user.commentShowUserName, isTrue);
      expect(user.commentShowTime, isTrue);
      await user.init();
      expect(user.commentShowAvatar, isTrue);
      expect(user.commentShowUserName, isTrue);
      expect(user.commentShowTime, isTrue);
    },
  );

  test('image viewer auto-rotate settings persist', () async {
    final user = UserManager();
    await user.init();

    expect(user.imageViewerAutoRotateLandscape, isFalse);
    expect(user.imageViewerLandscapeRotation, 1);

    await user.setImageViewerAutoRotateLandscape(true);
    await user.setImageViewerLandscapeRotation(-1);
    await user.init();

    expect(user.imageViewerAutoRotateLandscape, isTrue);
    expect(user.imageViewerLandscapeRotation, -1);
  });

  test('image viewer rotation normalizes to left or right', () async {
    final user = UserManager();
    await user.init();

    await user.setImageViewerLandscapeRotation(0);
    expect(user.imageViewerLandscapeRotation, 1);

    await user.setImageViewerLandscapeRotation(-90);
    expect(user.imageViewerLandscapeRotation, -1);
  });

  test('network selection mode and fixed node persist', () async {
    final user = UserManager();
    await user.init();

    expect(user.networkSelectionMode, NetworkSelectionMode.route);

    await user.setFixedNodeHost('mapi.hotmangasd.com');
    await user.setNetworkSelectionMode(NetworkSelectionMode.fixedNode);
    await user.init();

    expect(user.networkSelectionMode, NetworkSelectionMode.fixedNode);
    expect(user.fixedNodeHost, 'mapi.hotmangasd.com');
  });

  test(
    'a persisted legacy automatic(==2) selection mode falls back to route on init',
    () async {
      // 历史版本曾持久化索引 2(automatic),该模式已删除,init 后应回落 route。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'network_selection_mode': 2,
      });
      UserManager().network.resetPrefsCache();
      var user = UserManager();
      await user.init();
      expect(user.networkSelectionMode, NetworkSelectionMode.route);

      // 模拟重启:回落后的 route 索引应被持久化,再次 init 仍是 route。
      UserManager().network.resetPrefsCache();
      user = UserManager();
      await user.init();
      expect(user.networkSelectionMode, NetworkSelectionMode.route);
    },
  );

  test('last nav key defaults to comic and persists', () async {
    final user = UserManager();
    await user.init();

    expect(user.lastNavKey, UserManager.defaultNavKey);

    await user.setLastNavKey('search');
    await user.init();

    expect(user.lastNavKey, 'search');
  });

  test('last nav key falls back to comic when saved key is invalid', () async {
    SharedPreferences.setMockInitialValues({'last_nav_key': 'missing'});

    final user = UserManager();
    await user.init();

    expect(user.lastNavKey, UserManager.defaultNavKey);
  });

  test('dark mode cover brightness defaults and persists', () async {
    final user = UserManager();
    await user.init();

    expect(
      user.darkModeCoverBrightness,
      UserManager.defaultDarkModeCoverBrightness,
    );

    await user.setDarkModeCoverBrightness(0.7);
    await user.init();

    expect(user.darkModeCoverBrightness, 0.7);
  });

  test('dark mode cover brightness allows 10 percent minimum', () async {
    final user = UserManager();
    await user.init();

    await user.setDarkModeCoverBrightness(0.1);
    expect(user.darkModeCoverBrightness, 0.1);

    await user.setDarkModeCoverBrightness(0.05);
    expect(
      user.darkModeCoverBrightness,
      UserManager.minDarkModeCoverBrightness,
    );
  });

  test('display mode refresh rate defaults to auto and persists', () async {
    final user = UserManager();
    await user.init();

    expect(
      user.displayModeRefreshRate,
      UserManager.defaultDisplayModeRefreshRate,
    );

    for (final rate in [120, 165, 0]) {
      await user.setDisplayModeRefreshRate(rate);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('pref_display_mode_refresh_rate'), rate);
      await user.init();
      expect(user.displayModeRefreshRate, rate);
    }
  });

  test('display mode refresh rate falls back to auto when invalid', () async {
    SharedPreferences.setMockInitialValues({
      'pref_display_mode_refresh_rate': -1,
    });

    final user = UserManager();
    await user.init();

    expect(
      user.displayModeRefreshRate,
      UserManager.defaultDisplayModeRefreshRate,
    );
  });

  test('update mirror prefix defaults to gh.zwy.one and persists', () async {
    final user = UserManager();
    await user.init();

    expect(UserManager.defaultUpdateMirrorPrefix, 'https://gh.zwy.one/');
    expect(UserManager.updateMirrorPrefixOptions, [
      'https://gh.zwy.one/',
      'https://ghproxy.net/',
    ]);

    // 空值回落默认，合法地址补全尾斜杠。
    expect(
      UserManager.normalizeUpdateMirrorPrefix(''),
      UserManager.defaultUpdateMirrorPrefix,
    );
    expect(
      UserManager.normalizeUpdateMirrorPrefix('https://gh.zwy.one'),
      'https://gh.zwy.one/',
    );

    await user.setUpdateMirrorPrefix('https://ghproxy.net');
    expect(user.updateMirrorPrefix, 'https://ghproxy.net/');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('update_mirror_prefix'), 'https://ghproxy.net/');
  });

  for (final storedToken in ['current-token', '']) {
    test(
      'migration failure still honors stored token ${storedToken.isEmpty ? 'tombstone' : 'value'}',
      () async {
        final store = _FailingMigrationStore();
        await store.writeToken(storedToken);
        SecureCredentialStore.setInstance(store);
        SharedPreferences.setMockInitialValues({
          'user_token': 'obsolete-token',
          'saved_username': 'legacy-name',
          'saved_password': 'legacy-password',
        });

        final user = UserManager();
        await user.init();

        expect(user.token, storedToken.isEmpty ? null : storedToken);
        expect(user.isLoggedIn, storedToken.isNotEmpty);
        expect(await store.readToken(), storedToken);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('saved_username'), 'legacy-name');
        expect(prefs.getString('saved_password'), 'legacy-password');
      },
    );
  }

  for (final source in ['hotmanga', 'copy']) {
    test(
      'a fresh $source login survives three cold starts without Keystore',
      () async {
        // An encrypted-only installation has no recoverable token here. One
        // explicit login is enough; no later startup may require another one.
        SharedPreferences.setMockInitialValues({
          'login_source': source,
          'user_username': 'old-profile-without-credentials',
        });
        SecureCredentialStore.resetInstance();
        final user = UserManager();
        await user.init();
        expect(user.isLoggedIn, isFalse);
        expect(user.savedCredentials, isEmpty);
        expect(
          await user.authenticateAndLogin(
            source: source,
            password: 'new-password',
            authenticate: () async => {
              'token': '$source-token',
              'user_id': '$source-id',
              'username': '$source-user',
              'nickname': 'nickname',
              'avatar': 'avatar',
            },
          ),
          isTrue,
        );
        if (source == 'hotmanga') {
          await user.copyAccount.saveSession(
            const CopyAccountSession(
              token: 'independent-copy-token',
              userId: 'independent-copy-id',
            ),
          );
        }
        final copyId = user.copyAccount.activeId;
        final copyToken = user.copyToken;
        for (var boot = 0; boot < 3; boot++) {
          await _coldStartUser();
          expect(user.isLoggedIn, isTrue);
          expect(user.token, '$source-token');
          expect(user.username, '$source-user');
          expect(user.userId, '$source-id');
          expect(user.savedPassword, 'new-password');
          expect(user.savedCredentials, hasLength(1));
          expect(user.copyToken, copyToken);
          expect(user.copyAccount.activeId, copyId);
        }
      },
    );
  }

  for (final origin in ['legacy', 'mirror', 'conflict']) {
    for (final persistMigrations in [false, true]) {
      test(
        '$origin credentials use one selection rule, persist=$persistMigrations',
        () async {
          final legacy = _loginPreferences(prefix: '', token: 'legacy-token');
          final current = _loginPreferences(
            prefix: SecureCredentialStore.preferencePrefix,
            token: 'current-token',
          );
          final initial = <String, Object>{
            'login_source': 'hotmanga',
            'user_username': 'primary-user',
            'user_id': 'primary-id',
            if (origin != 'mirror') ...legacy,
            if (origin != 'legacy') ...current,
          };
          SharedPreferences.setMockInitialValues(initial);
          SecureCredentialStore.resetInstance();
          final user = UserManager();
          await user.init(persistMigrations: persistMigrations);

          final expectedToken = origin == 'legacy'
              ? 'legacy-token'
              : 'current-token';
          expect(user.token, expectedToken);
          expect(user.savedUsername, 'saved-$expectedToken');
          expect(user.savedPassword, 'password-$expectedToken');
          expect(
            user.savedCredentials
                .singleWhere((item) => item.username == 'saved-$expectedToken')
                .token,
            expectedToken,
          );
          expect(user.copyToken, 'copy-$expectedToken');
          final prefs = await SharedPreferences.getInstance();
          if (!persistMigrations) {
            expect(_preferencesSnapshot(prefs), initial);
          } else {
            expect(prefs.getString('secure_mirror_user_token'), expectedToken);
            expect(prefs.containsKey('user_token'), isFalse);
            expect(
              prefs.getString('secure_mirror_saved_credentials'),
              (origin == 'legacy'
                  ? legacy
                  : current)['${origin == 'legacy' ? '' : SecureCredentialStore.preferencePrefix}saved_credentials'],
            );
            for (var boot = 0; boot < 3; boot++) {
              await _coldStartUser();
              expect(user.token, expectedToken);
              expect(user.copyToken, 'copy-$expectedToken');
            }
          }
        },
      );
    }
  }

  for (final persistMigrations in [false, true]) {
    test('an explicit empty account list does not rebuild remembered accounts, '
        'persist=$persistMigrations', () async {
      SharedPreferences.setMockInitialValues({
        'secure_mirror_user_token': '',
        'secure_mirror_saved_username': 'remembered-user',
        'secure_mirror_saved_password': 'remembered-password',
        'secure_mirror_saved_credentials': '[]',
      });
      SecureCredentialStore.resetInstance();
      final user = UserManager();
      await user.init(persistMigrations: persistMigrations);
      expect(user.isLoggedIn, isFalse);
      expect(user.savedCredentials, isEmpty);
      await _coldStartUser();
      expect(user.savedCredentials, isEmpty);
    });

    test(
      'current empty records defeat stale aliases, persist=$persistMigrations',
      () async {
        final initial = <String, Object>{
          ..._loginPreferences(prefix: '', token: 'stale-token'),
          'secure_mirror_user_token': '',
          'secure_mirror_saved_username': '',
          'secure_mirror_saved_password': '',
          'secure_mirror_saved_credentials': '[]',
          'secure_mirror_copy_account_v1': jsonEncode({
            'migrationHandled': true,
            'cleared': true,
            'accounts': <Object?>[],
          }),
        };
        SharedPreferences.setMockInitialValues(initial);
        SecureCredentialStore.resetInstance();
        final user = UserManager();
        await user.init(persistMigrations: persistMigrations);
        expect(user.token, isNull);
        expect(user.savedCredentials, isEmpty);
        expect(user.copyAccount.accounts, isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('secure_mirror_user_token'), '');
        expect(prefs.getString('secure_mirror_saved_credentials'), '[]');
        if (!persistMigrations) expect(_preferencesSnapshot(prefs), initial);
        await _coldStartUser();
        expect(user.isLoggedIn, isFalse);
        expect(user.savedCredentials, isEmpty);
        expect(user.copyAccount.accounts, isEmpty);
      },
    );
  }

  test(
    'migration marker suppresses cleared saved fields but not legacy token',
    () async {
      SharedPreferences.setMockInitialValues({
        ..._loginPreferences(prefix: '', token: 'legacy-token'),
        'secure_mirror_credentials_migrated_to_secure': 'true',
      });
      SecureCredentialStore.resetInstance();
      final user = UserManager();
      await user.init(persistMigrations: false);
      expect(user.token, 'legacy-token');
      expect(user.savedUsername, isNull);
      expect(user.savedPassword, isNull);
      expect(
        user.savedCredentials.where(
          (item) => item.username == 'saved-legacy-token',
        ),
        isEmpty,
      );
    },
  );

  test(
    'raw saved credentials survive migration without normalization loss',
    () async {
      final raw = jsonEncode([
        {
          'username': 'older-user',
          'password': 'older-password',
          'future_field': {'preserve': true},
        },
        {'future_only_account': true},
      ]);
      SharedPreferences.setMockInitialValues({
        'saved_credentials': raw,
        'saved_username': 'older-user',
        'saved_password': 'older-password',
        'login_source': 'copy',
      });
      SecureCredentialStore.resetInstance();
      final user = UserManager();
      await user.init();
      expect(user.savedCredentials.single.source, 'copy');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('secure_mirror_saved_credentials'), raw);
      expect(prefs.containsKey('saved_credentials'), isFalse);
      await _coldStartUser();
      expect(
        (await SharedPreferences.getInstance()).getString(
          'secure_mirror_saved_credentials',
        ),
        raw,
      );
    },
  );

  test(
    'read-only initialization does not bypass an isolated memory store',
    () async {
      SharedPreferences.setMockInitialValues(
        _loginPreferences(prefix: '', token: 'unrelated-token'),
      );
      final user = UserManager();
      await user.init(persistMigrations: false);
      expect(user.token, isNull);
      expect(user.savedUsername, isNull);
      expect(user.savedCredentials, isEmpty);
      expect(user.copyToken, isNull);
    },
  );
}

Map<String, Object> _loginPreferences({
  required String prefix,
  required String token,
}) => {
  '${prefix}user_token': token,
  '${prefix}saved_username': 'saved-$token',
  '${prefix}saved_password': 'password-$token',
  '${prefix}saved_credentials': jsonEncode([
    {
      'username': 'saved-$token',
      'password': 'password-$token',
      'token': token,
      'future_field': 'keep-exact-json',
    },
  ]),
  '${prefix}copy_account_v1': jsonEncode({
    'migrationHandled': true,
    'session': CopyAccountSession(
      token: 'copy-$token',
      userId: 'novel-id',
    ).toJson(),
  }),
};

Map<String, Object> _preferencesSnapshot(SharedPreferences prefs) => {
  for (final key in prefs.getKeys()) key: prefs.get(key)!,
};

Future<void> _coldStartUser() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final disk = _preferencesSnapshot(prefs);
  // UserManager is a singleton. Empty read-only initialization clears its
  // memory first, so stale in-memory sessions cannot make a restart test pass.
  SharedPreferences.setMockInitialValues({});
  SecureCredentialStore.resetInstance();
  await UserManager().init(persistMigrations: false);
  expect(UserManager().isLoggedIn, isFalse);
  expect(UserManager().isCopyLoggedIn, isFalse);
  SharedPreferences.setMockInitialValues(disk);
  SecureCredentialStore.resetInstance();
  await UserManager().init();
}

class _FailingMigrationStore extends InMemorySecureCredentialStore {
  @override
  bool get legacyPreferencesEnabled => true;

  @override
  Future<void> migrateFromSharedPreferences(
    Map<String, Object?> prefsMap,
    Future<void> Function(String key) removePref,
  ) async {
    throw StateError('legacy credential migration unavailable');
  }
}

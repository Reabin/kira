import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/copy_account_store.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/models/user_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_storage_test_support.dart';
import 'test_helpers.dart';

const _account = SavedCredential(
  username: 'fictional-reader',
  password: 'fictional-password',
  token: 'fictional-token-a',
  loginSource: 'copy',
  userId: 'fictional-user',
  nickname: '原昵称',
  avatar: 'fictional/avatar.png',
  accountId: 'local:a',
);
const _newToken = 'fictional-new-token';

CopyAccountSession _session(SavedCredential account) => CopyAccountSession(
  token: account.token!,
  username: account.username,
  userId: account.userId!,
  nickname: account.nickname!,
  avatar: account.avatar!,
  accountId: account.accountId,
);

Map<String, Object?> _state(UserManager user) => {
  'current': user.currentCredential?.toJson(),
  'savedUsername': user.savedUsername,
  'savedPassword': user.savedPassword,
  'credentials': user.savedCredentials.map((item) => item.toJson()).toList(),
  'activeId': user.copyAccount.activeId,
  'accounts': user.copyAccount.accounts.map((item) => item.toJson()).toList(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final user = UserManager();
  late AccountPreferencesPlatform platform;

  // 单独文件使用默认平台通道。setMockInitialValues 会替换平台实现，
  // 即使 resetStatic 也不会还原，不能与本文件的写失败注入混用。
  setUp(() async {
    setupSecureCredentialStoreForTest();
    platform = AccountPreferencesPlatform()..install();
    SecureCredentialStore.resetInstance();
    user.resumeAccountMutationsAfterRestore();
    final duplicate = _account.copyWith(
      accountId: 'local:b',
      token: 'fictional-token-b',
    );
    final fixture = <String, Object>{
      'login_source': 'copy',
      'user_id': _account.userId!,
      'user_username': _account.username,
      'user_nickname': _account.nickname!,
      'user_avatar': _account.avatar!,
      'user_account_id': _account.accountId!,
      'secure_mirror_user_token': _account.token!,
      'secure_mirror_saved_username': _account.username,
      'secure_mirror_saved_password': _account.password,
      'secure_mirror_saved_credentials': jsonEncode([
        _account.toJson(),
        duplicate.toJson(),
      ]),
      'secure_mirror_credentials_migrated_to_secure': 'true',
      'secure_mirror_copy_account_v1': jsonEncode({
        'migrationHandled': true,
        'activeId': duplicate.accountId,
        'accounts': [_session(_account).toJson(), _session(duplicate).toJson()],
      }),
    };
    platform.values.addAll({
      for (final entry in fixture.entries) 'flutter.${entry.key}': entry.value,
    });
    await user.init(persistMigrations: false);
    expect(user.token, _account.token);
    expect(user.copyToken, duplicate.token);
  });

  tearDown(() {
    user.resumeAccountMutationsAfterRestore();
    platform.dispose();
    teardownSecureCredentialStoreForTest();
  });

  test('HOT login leaves read-only restored COPY tokens independent', () async {
    final copyRecord = await SecureCredentialStore().readCopyAccountRecord();
    final primary = user.currentCredential?.toJson();
    expect(
      await user.authenticateAndLogin(
        source: 'hotmanga',
        authenticate: () async => {
          'token': 'fictional-hot-token',
          'username': 'fictional-hot-reader',
          'user_id': 'fictional-hot-id',
        },
      ),
      isTrue,
    );
    expect(user.currentCredential?.toJson(), primary);
    expect(user.token, _account.token);
    expect(user.copyToken, 'fictional-token-b');
    expect(
      user.savedCredentials.singleWhere((item) => item.source == 'copy').token,
      _account.token,
    );
    expect(await SecureCredentialStore().readToken(), _account.token);
    expect(await SecureCredentialStore().readCopyAccountRecord(), copyRecord);
  });

  test(
    'cancelled login still forwards an independent novel selection',
    () async {
      const other = CopyAccountSession(
        token: 'fictional-other-token',
        username: 'fictional-other-reader',
        userId: 'fictional-other-user',
        accountId: 'local:other',
      );
      await user.copyAccount.saveSession(other, select: false);
      final started = Completer<void>();
      final release = Completer<void>();
      platform.beforeWrite = (key, value) async {
        if (key == 'flutter.user_nickname' && value == '更新昵称') {
          started.complete();
          await release.future;
        }
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final observed = <Map<String, Object?>>[];
      void changed() => observed.add(_state(user));
      user.addListener(changed);
      addTearDown(() => user.removeListener(changed));
      final login = user.authenticateAndLogin(
        source: 'copy',
        authenticate: () async => {
          'token': _newToken,
          'username': _account.username,
          'user_id': _account.userId,
          'nickname': '更新昵称',
        },
      );
      await started.future.timeout(const Duration(seconds: 2));
      expect(await user.copyAccount.selectAccount(other.id), isTrue);
      expect(user.copyAccount.activeId, other.id);
      release.complete();
      expect(await login, isFalse);
      expect(user.token, _account.token);
      expect(user.copyToken, other.token);
      expect(observed, hasLength(1));
      expect(observed.single, _state(user));
    },
  );

  for (final failedKey in ['secure_mirror_user_token', 'user_nickname']) {
    for (final throwOnFailure in [false, true]) {
      test(
        'duplicate login rolls back $failedKey failure throws=$throwOnFailure',
        () async {
          final beforeDisk = Map.of(platform.values);
          final beforeState = _state(user);
          var notifications = 0;
          void changed() => notifications++;
          user.addListener(changed);
          addTearDown(() => user.removeListener(changed));
          platform.failKey = failedKey;
          platform.failValue = failedKey == 'user_nickname'
              ? '更新昵称'
              : _newToken;
          platform.throwOnFailure = throwOnFailure;
          await expectLater(
            user.authenticateAndLogin(
              source: 'copy',
              authenticate: () async => {
                'token': _newToken,
                'username': _account.username,
                'user_id': _account.userId,
                'nickname': '更新昵称',
              },
            ),
            throwsA(isA<CopyAccountStorageException>()),
          );
          expect(platform.failKey, isNull, reason: '必须实际经过平台写失败注入点');
          expect(notifications, 0);
          expect(_state(user), beforeState);
          expect(platform.values, beforeDisk);
          SharedPreferences.resetStatic();
          SecureCredentialStore.resetInstance();
          await user.init(persistMigrations: false);
          expect(_state(user), beforeState);
          expect(platform.values, beforeDisk);
        },
      );
    }
  }
}

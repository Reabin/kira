import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/api_client.dart';
import 'package:kira/api/user/user_api.dart';
import 'package:kira/models/copy_account_store.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/models/user_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_storage_test_support.dart';
import 'test_helpers.dart';

// 全部为虚构凭据；相同 userId 刻意不代表相同的非空登录名。
const _uid = 'fictional-shared-user-id';
const _alice = CopyAccountSession(
  username: 'alice',
  userId: _uid,
  token: 'fictional-token-a',
  accountId: 'local:a',
);
const _bob = CopyAccountSession(
  username: 'bob',
  userId: _uid,
  token: 'fictional-token-b',
  accountId: 'local:b',
);
const _anonymous = CopyAccountSession(
  userId: _uid,
  token: 'fictional-token-n',
  accountId: 'local:n',
);
const _bridge = CopyAccountSession(
  userId: _uid,
  token: 'fictional-token-b',
  accountId: 'local:c',
);
const _hot = SavedCredential(
  username: 'fictional-hot-reader',
  password: 'fictional-hot-password',
  token: 'fictional-hot-token',
  loginSource: 'hotmanga',
  userId: 'fictional-hot-id',
  nickname: '虚构 HOT 账号',
  avatar: '',
);
const _orders = [
  [0, 1, 2],
  [0, 2, 1],
  [1, 0, 2],
  [1, 2, 0],
  [2, 0, 1],
  [2, 1, 0],
];

SavedCredential _credential(CopyAccountSession account) => SavedCredential(
  username: account.username,
  password: '',
  token: account.token,
  loginSource: 'copy',
  userId: account.userId,
  nickname: account.nickname,
  avatar: account.avatar,
  accountId: account.id,
);

String _record(List<CopyAccountSession> accounts, String? activeId) =>
    jsonEncode({
      'migrationHandled': true,
      'activeId': activeId,
      'accounts': accounts.map((account) => account.toJson()).toList(),
    });

Map<String, Object> _fixture({
  required List<CopyAccountSession> accounts,
  required String activeId,
  List<SavedCredential>? credentials,
  bool loggedOut = false,
}) => {
  'login_source': 'hotmanga',
  if (!loggedOut) ...{
    'user_id': _hot.userId!,
    'user_username': _hot.username,
    'user_nickname': _hot.nickname!,
    'user_avatar': _hot.avatar!,
  },
  'secure_mirror_user_token': loggedOut ? '' : _hot.token!,
  'secure_mirror_saved_username': _hot.username,
  'secure_mirror_saved_password': _hot.password,
  'secure_mirror_saved_credentials': jsonEncode(
    (credentials ?? [_hot, _credential(_alice), _credential(_bob)])
        .map((item) => item.toJson())
        .toList(),
  ),
  'secure_mirror_credentials_migrated_to_secure': 'true',
  'secure_mirror_copy_account_v1': _record(accounts, activeId),
  'copy_api_host': 'fictional-copy.invalid',
};

void _expectHot(UserManager user, {bool loggedOut = false}) {
  expect(user.loginSource, 'hotmanga');
  expect(user.token, loggedOut ? isNull : _hot.token);
  expect(user.savedUsername, _hot.username);
  expect(user.savedPassword, _hot.password);
  expect(
    user.currentCredential?.toJson(),
    loggedOut ? isNull : _hot.copyWith(password: '').toJson(),
  );
}

void _expectNamedCredentials(Iterable<SavedCredential> credentials) {
  for (final expected in [_alice, _bob]) {
    final matches = credentials.where(
      (item) => item.source == 'copy' && item.username == expected.username,
    );
    expect(matches, hasLength(1));
    expect(matches.single.token, expected.token);
    expect(matches.single.accountId, expected.id);
    expect(matches.single.userId, expected.userId);
  }
}

CopyAccountSession _expectAnonymousLogin(UserManager user, {String? stableId}) {
  _expectHot(user);
  _expectNamedCredentials(user.savedCredentials);
  final saved = user.savedCredentials.where((item) => item.source == 'copy');
  final accounts = user.copyAccount.accounts;
  expect(saved, hasLength(3));
  expect(accounts, hasLength(3));
  expect(saved.map((item) => item.accountId).toSet(), hasLength(3));
  expect(accounts.map((item) => item.id).toSet(), hasLength(3));
  for (final named in [_alice, _bob]) {
    final account = user.copyAccount.byId(named.id);
    expect(account?.username, named.username);
    expect(account?.token, named.token);
    expect(user.copyAccount.resolveAccountId(named.id), named.id);
  }
  final anonymous = accounts.singleWhere(
    (item) => item.token == _anonymous.token,
  );
  expect(anonymous.username, isEmpty, reason: '仅相同 uid 不能认领任一已知登录名');
  expect(anonymous.userId, _uid);
  expect(anonymous.id, isNotNull);
  expect({_alice.id, _bob.id}, isNot(contains(anonymous.id)));
  if (stableId != null) expect(anonymous.id, stableId);
  final credential = saved.singleWhere(
    (item) => item.token == _anonymous.token,
  );
  expect(credential.username, isEmpty);
  expect(credential.userId, _uid);
  expect(credential.accountId, anonymous.id);
  expect(user.copyAccount.activeId, _alice.id);
  expect(user.copyToken, _alice.token);
  return anonymous;
}

String _expectBridge(
  CopyAccountStore store,
  List<CopyAccountSession> originals, {
  String? stableId,
}) {
  expect(store.accounts, hasLength(1));
  final canonical = store.accounts.single;
  expect(originals.map((item) => item.id), contains(canonical.id));
  if (stableId != null) expect(canonical.id, stableId);
  expect(canonical.username, _alice.username);
  expect(canonical.userId, _uid);
  expect(originals.map((item) => item.token), contains(canonical.token));
  expect(store.activeId, canonical.id);
  expect(store.session?.id, canonical.id);
  for (final original in originals) {
    expect(store.resolveAccountId(original.id), canonical.id);
  }
  return canonical.id!;
}

Map<String, String?> _expectConflictingNames(CopyAccountStore store) {
  final named = store.accounts.where((item) => item.username.isNotEmpty);
  expect(named.map((item) => item.username), unorderedEquals(['alice', 'bob']));
  final alice = named.singleWhere((item) => item.username == 'alice');
  final bob = named.singleWhere((item) => item.username == 'bob');
  expect(alice.id, isNot(bob.id));
  expect(alice.token, _alice.token);
  expect(bob.token, _bob.token);
  expect(store.resolveAccountId(_alice.id), alice.id);
  expect(store.resolveAccountId(_bob.id), bob.id);
  expect(store.resolveAccountId(_bridge.id), isNotNull);
  expect(store.byId(store.activeId), isNotNull);
  return {'alice': alice.id, 'bob': bob.id};
}

// 资料补全只返回 uid；任何未声明的 API 调用直接失败，不创建网络客户端。
class _UidOnlyApi implements UserApi {
  final profileTokens = <String>[];

  @override
  Future<Map<String, dynamic>> getCopyCredentialInfo(String token) async {
    profileTokens.add(token);
    return {'user_id': _uid};
  }

  @override
  void clearAuthState() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected API call: ${invocation.memberName}');
}

class _OfflineApiClient implements ApiClient {
  @override
  final UserApi user;

  _OfflineApiClient(this.user);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected API call: ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final user = UserManager();
  final originalApi = ApiClient();
  late CopyAccountStore store;
  late _UidOnlyApi api;

  setUp(() {
    setupSecureCredentialStoreForTest();
    // 仅使用 mock prefs，不安装 MethodChannel 后端；凭据默认走真实 prefs 实现。
    SharedPreferences.setMockInitialValues({});
    SecureCredentialStore.resetInstance();
    user.resumeAccountMutationsAfterRestore();
    store = CopyAccountStore();
    api = _UidOnlyApi();
    ApiClient.setTestInstance(_OfflineApiClient(api));
  });

  tearDown(() {
    store.dispose();
    ApiClient.setTestInstance(originalApi);
    user.resumeAccountMutationsAfterRestore();
    teardownSecureCredentialStoreForTest();
  });

  Future<void> restartStore() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final disk = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
    store.dispose();
    SharedPreferences.setMockInitialValues(disk);
    SecureCredentialStore.resetInstance();
    store = CopyAccountStore();
    await store.init();
  }

  Future<void> restartUser() async {
    await restartStore();
    // facade 无 reset API；重建持久化 store 后重新加载主账号。
    await user.init();
    expect(
      store.accounts.map((item) => item.toJson()),
      unorderedEquals(user.copyAccount.accounts.map((item) => item.toJson())),
    );
    expect(store.activeId, user.copyAccount.activeId);
  }

  for (final loggedOut in [false, true]) {
    test(
      'ambiguous COPY projection preserves both primary identities: loggedOut=$loggedOut',
      () async {
        SharedPreferences.setMockInitialValues(
          _fixture(
            accounts: [_anonymous],
            activeId: _anonymous.id!,
            loggedOut: loggedOut,
          ),
        );
        await user.init();
        for (var boot = 0; boot < 3; boot++) {
          if (boot > 0) await restartUser();
          _expectHot(user, loggedOut: loggedOut);
          _expectNamedCredentials(user.savedCredentials);
          expect(
            user.savedCredentials.where((item) => item.source == 'copy'),
            hasLength(2),
          );
          expect(user.copyAccount.accounts, hasLength(1));
          expect(user.copyAccount.session?.toJson(), _anonymous.toJson());
          expect(user.copyAccount.activeId, _anonymous.id);
          expect(user.copyToken, _anonymous.token);
          _expectNamedCredentials(
            await SecureCredentialStore().readCredentials(),
          );
        }
      },
    );
  }

  for (final reverse in [false, true]) {
    for (final uidFromProfile in [false, true]) {
      test(
        'ambiguous uid retains the new token: reverse=$reverse profile=$uidFromProfile',
        () async {
          final accounts = reverse ? [_bob, _alice] : [_alice, _bob];
          SharedPreferences.setMockInitialValues(
            _fixture(
              accounts: accounts,
              activeId: _alice.id!,
              credentials: [_hot, ...accounts.map(_credential)],
            ),
          );
          await user.init();
          expect(
            await user.authenticateAndLogin(
              source: 'copy',
              authenticate: () async => {
                'username': '',
                'token': _anonymous.token,
                if (!uidFromProfile) 'user_id': _uid,
              },
            ),
            isTrue,
          );
          final candidates = user.copyAccount.accounts.where(
            (item) => item.token == _anonymous.token,
          );
          expect(candidates, hasLength(1), reason: '认证成功的新 token 不能被旧候选吞掉');
          final candidate = candidates.single;
          expect(candidate.username, isEmpty);
          if (uidFromProfile) {
            expect(candidate.hasIdentity, isFalse);
            expect(
              await user.refreshCopyCredential(candidate, api: api),
              isTrue,
            );
            expect(api.profileTokens, [_anonymous.token]);
          }
          final added = _expectAnonymousLogin(user, stableId: candidate.id);
          for (var boot = 0; boot < 2; boot++) {
            await restartUser();
            _expectAnonymousLogin(user, stableId: added.id);
            final saved = await SecureCredentialStore().readCredentials();
            _expectNamedCredentials(saved);
            expect(
              saved
                  .singleWhere((item) => item.token == _anonymous.token)
                  .username,
              isEmpty,
            );
          }
        },
      );
    }
  }

  for (final removeAlice in [false, true]) {
    test(
      'derived uid collision keeps both handles selectable and removable: removeAlice=$removeAlice',
      () async {
        await store.init();
        // 必须从空库保存，不能预置 local: ID 绕过派生 u:<uid> 的碰撞。
        expect(
          await store.saveSession(
            const CopyAccountSession(
              username: 'alice',
              userId: _uid,
              token: 'fictional-token-a',
            ),
          ),
          isTrue,
        );
        final aliceId = store.accounts.single.id!;
        expect(
          await store.saveSession(
            const CopyAccountSession(
              username: 'bob',
              userId: _uid,
              token: 'fictional-token-b',
            ),
          ),
          isTrue,
        );
        expect(store.accounts, hasLength(2));
        final bobId = store.accounts
            .singleWhere((item) => item.username == 'bob')
            .id!;
        expect(bobId, isNot(aliceId));
        final ids = {'alice': aliceId, 'bob': bobId};
        for (var boot = 0; boot < 3; boot++) {
          if (boot > 0) await restartStore();
          expect(store.accounts, hasLength(2));
          for (final account in [_alice, _bob]) {
            final id = ids[account.username]!;
            expect(store.byId(id)?.username, account.username);
            expect(store.resolveAccountId(id), id);
            expect(await store.selectAccount(id), isTrue);
            expect(store.activeId, id);
            expect(store.token, account.token);
          }
        }
        final removedId = removeAlice ? aliceId : bobId;
        final survivorId = removeAlice ? bobId : aliceId;
        final survivor = removeAlice ? _bob : _alice;
        expect(await store.selectAccount(removedId), isTrue);
        await store.removeAccount(removedId);
        for (var boot = 0; boot < 2; boot++) {
          if (boot > 0) await restartStore();
          expect(store.accounts, hasLength(1));
          expect(store.accounts.single.id, survivorId);
          expect(store.session?.username, survivor.username);
          expect(store.token, survivor.token);
          expect(store.resolveAccountId(removedId), isNull);
          expect(await store.selectAccount(removedId), isFalse);
        }
      },
    );
  }

  for (final order in _orders) {
    test(
      'nonconflicting token and uid bridge converges: order=${order.join()}',
      () async {
        final originals = [
          _alice,
          _bob.copyWith(username: '', userId: ''),
          _bridge,
        ];
        await SecureCredentialStore().writeCopyAccountRecord(
          _record([
            for (final index in order) originals[index],
          ], originals[1].id),
        );
        await store.init();
        final canonicalId = _expectBridge(store, originals);
        for (var boot = 0; boot < 2; boot++) {
          await restartStore();
          _expectBridge(store, originals, stableId: canonicalId);
        }
      },
    );

    test(
      'anonymous bridge never joins conflicting names: order=${order.join()}',
      () async {
        const originals = [_alice, _bob, _bridge];
        await SecureCredentialStore().writeCopyAccountRecord(
          _record([for (final index in order) originals[index]], _bob.id),
        );
        await store.init();
        final handles = _expectConflictingNames(store);
        for (var boot = 0; boot < 2; boot++) {
          await restartStore();
          expect(_expectConflictingNames(store), handles);
        }
      },
    );
  }

  test(
    'init retains readable COPY snapshot when writes and rollback keep failing',
    () async {
      // 先清掉 facade 的前例内存，防止误把残留会话当成恢复成功。
      await user.init();
      expect(user.copyAccount.accounts, isEmpty);
      final duplicate = _alice.copyWith(
        token: 'fictional-duplicate-token',
        accountId: 'local:duplicate',
      );
      final originals = [_alice, duplicate];
      final credentials = [_hot, ...originals.map(_credential)];
      final raw = _record(originals, duplicate.id);
      SharedPreferences.setMockInitialValues(
        _fixture(
          accounts: originals,
          activeId: duplicate.id!,
          credentials: credentials,
        ),
      );
      final secure = FailingAccountSecureStore();
      SecureCredentialStore.setInstance(secure);
      await secure.writeToken(_hot.token);
      await secure.writeUsername(_hot.username);
      await secure.writePassword(_hot.password);
      await secure.writeCredentials(credentials);
      await secure.writeCopyAccountRecord(raw);
      final attempts = <String>[];
      secure.beforeWrite = (key, _) async => attempts.add(key);
      secure.failAllWrites = true;

      for (var boot = 0; boot < 2; boot++) {
        attempts.clear();
        await user.init();
        expect(
          attempts.where((key) => key == 'saved_credentials').length,
          greaterThanOrEqualTo(2),
          reason: '主凭据必须实际尝试去重写入，且补偿写入也持续失败',
        );
        _expectHot(user);
        expect(user.copyAccount.isLoggedIn, isTrue);
        expect(
          user.copyAccount.accounts.map((item) => item.toJson()).toList(),
          originals.map((item) => item.toJson()).toList(),
          reason: '失败后保留读到的原快照，不发布半归并结果或退回游客',
        );
        expect(user.copyAccount.activeId, duplicate.id);
        expect(user.copyToken, duplicate.token);
        for (final original in originals) {
          expect(user.copyAccount.resolveAccountId(original.id), original.id);
        }
        expect(await secure.readCopyAccountRecord(), raw);
        expect(
          (await secure.readCredentials())
              .map((item) => item.toJson())
              .toList(),
          credentials.map((item) => item.toJson()).toList(),
        );
      }
    },
  );
}

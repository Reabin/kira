import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/api_client.dart';
import 'package:kira/api/api_transport.dart';
import 'package:kira/api/user/user_api.dart';
import 'package:kira/models/copy_account_store.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/utils/copy_web_login.dart';
import 'package:kira/utils/data_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_storage_test_support.dart';
import 'test_helpers.dart';

// 全部是虚构凭据。两个历史句柄指向同一身份，资料刻意分散在不同记录中。
const _copyA = CopyAccountSession(
  token: 'fictional-copy-token-a',
  accountId: 'local:a',
  userId: 'fictional-copy-user-id',
  username: 'fictional-reader',
  nickname: '历史昵称',
);
const _copyB = CopyAccountSession(
  token: 'fictional-copy-token-b',
  accountId: 'local:b',
  userId: 'fictional-copy-user-id',
  username: 'fictional-reader',
  avatar: 'fictional/avatar.png',
  label: '小说主号备注',
);
const _copyPassword = 'fictional-copy-password';
const _newToken = 'fictional-verified-new-token';
const _hot = SavedCredential(
  // 跨源同名不得被 COPY 去重吞掉。
  username: 'fictional-reader',
  password: 'fictional-hot-password',
  token: 'fictional-hot-token',
  loginSource: 'hotmanga',
  userId: 'fictional-hot-user-id',
  nickname: '热辣当前账号',
  avatar: 'fictional/hot-avatar.png',
);

CopyAccountSession get _completeCopyA =>
    _copyA.copyWith(avatar: _copyB.avatar, label: _copyB.label);

SavedCredential _credential(
  CopyAccountSession account, {
  String password = '',
}) => SavedCredential(
  username: account.username,
  password: password,
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
  String primarySource = 'hotmanga',
  List<CopyAccountSession> accounts = const [_copyA, _copyB],
  String? activeId = 'local:b',
  bool reverse = false,
}) {
  final primary = primarySource == 'copy'
      ? _credential(accounts.first, password: _copyPassword)
      : _hot;
  final credentials = [
    for (var i = 0; i < accounts.length; i++)
      _credential(accounts[i], password: i == 0 ? _copyPassword : ''),
  ];
  return {
    'login_source': primary.source,
    'user_id': primary.userId ?? '',
    'user_username': primary.username,
    'user_nickname': primary.nickname ?? '',
    'user_avatar': primary.avatar ?? '',
    if (primary.accountId != null) 'user_account_id': primary.accountId!,
    'secure_mirror_user_token': primary.token!,
    'secure_mirror_saved_username': primary.username,
    'secure_mirror_saved_password': primary.password,
    'secure_mirror_saved_credentials': jsonEncode([
      _hot.toJson(),
      for (final credential in reverse ? credentials.reversed : credentials)
        credential.toJson(),
    ]),
    'secure_mirror_credentials_migrated_to_secure': 'true',
    'secure_mirror_copy_account_v1': _record(
      reverse ? accounts.reversed.toList() : accounts,
      activeId,
    ),
    'copy_api_host': 'fictional-copy.invalid',
  };
}

Map<String, Object?> _state(UserManager user) => {
  'current': user.currentCredential?.toJson(),
  'savedUsername': user.savedUsername,
  'savedPassword': user.savedPassword,
  'credentials': user.savedCredentials.map((item) => item.toJson()).toList(),
  'activeId': user.copyAccount.activeId,
  'accounts': user.copyAccount.accounts.map((item) => item.toJson()).toList(),
};

Future<Map<String, Object>> _disk() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return {for (final key in prefs.getKeys()) key: prefs.get(key)!};
}

Future<void> _coldReload(UserManager user) async {
  final disk = await _disk();
  SharedPreferences.setMockInitialValues(disk);
  SecureCredentialStore.resetInstance();
  // UserManager 本身没有 reset API；重新创建可重建的存储，再重载 facade。
  final recreated = CopyAccountStore();
  try {
    await recreated.init();
    expect(recreated.accounts, hasLength(1));
    expect(recreated.byId(recreated.activeId), isNotNull);
  } finally {
    recreated.dispose();
  }
  await user.init();
}

Future<void> _expectPersistedCanonical(UserManager user) async {
  final secure = SecureCredentialStore();
  final credentials = (await secure.readCredentials())
      .where((item) => item.source == 'copy')
      .toList();
  final account = user.copyAccount.accounts.single;
  expect(credentials, hasLength(1), reason: '主凭据必须实际落盘去重，而非仅隐藏卡片');
  expect(credentials.single.accountId, account.id);
  expect(credentials.single.token, account.token);
  expect(credentials.single.password, _copyPassword);
  final raw = await secure.readCopyAccountRecord();
  expect(raw, isNotNull);
  final decoded = jsonDecode(raw!);
  if (decoded is! Map) throw StateError('Expected COPY record');
  expect(decoded['accounts'], [account.toJson()]);
  expect(decoded['activeId'], account.id);
  if (user.loginSource == 'copy') {
    expect(await secure.readToken(), account.token);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('user_account_id'), account.id);
  } else {
    expect(await secure.readToken(), _hot.token);
  }
}

CopyAccountSession _expectCanonical(
  UserManager user, {
  required String primarySource,
  Set<String> existingIds = const {'local:a', 'local:b'},
  String? token,
  String? savedCopyToken,
  String nickname = '历史昵称',
}) {
  expect(user.copyAccount.accounts, hasLength(1));
  final account = user.copyAccount.accounts.single;
  expect(existingIds, contains(account.id), reason: '合并保留已有稳定句柄');
  expect(account.username, _copyA.username);
  expect(account.userId, _copyA.userId);
  expect(account.nickname, nickname);
  expect(account.avatar, _copyB.avatar);
  expect(account.label, _copyB.label);
  if (token != null) expect(account.token, token);
  expect(user.copyAccount.activeId, account.id);
  expect(user.copyToken, account.token);
  expect(
    user.copyAccount.byId(user.copyAccount.activeId)?.username,
    _copyA.username,
  );
  final saved = user.savedCredentials.where((item) => item.source == 'copy');
  expect(saved, hasLength(1));
  expect(saved.single.accountId, account.id);
  expect(saved.single.token, savedCopyToken ?? account.token);
  expect(saved.single.password, _copyPassword);
  expect(saved.single.nickname, nickname);
  expect(saved.single.avatar, _copyB.avatar);
  expect(
    user.savedCredentials.where((item) => item.source == 'hotmanga'),
    hasLength(1),
  );
  expect(
    user.savedCredentials
        .singleWhere((item) => item.source == 'hotmanga')
        .toJson(),
    _hot.toJson(),
  );
  expect(user.loginSource, primarySource);
  if (primarySource == 'hotmanga') {
    expect(
      user.currentCredential?.toJson(),
      _hot.copyWith(password: '').toJson(),
    );
    expect(user.savedPassword, _hot.password);
  } else {
    expect(user.currentCredential?.accountId, account.id);
    expect(user.username, _copyA.username);
    expect(user.token, savedCopyToken ?? account.token);
    expect(user.savedPassword, _copyPassword);
  }
  return account;
}

class _OfflineAdapter implements HttpClientAdapter {
  FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];

  _OfflineAdapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

class _OfflineApiClient implements ApiClient {
  @override
  final UserApi user;

  _OfflineApiClient(this.user);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected API call: ${invocation.memberName}');
}

ResponseBody _response(Map<String, dynamic> results) => ResponseBody.fromString(
  jsonEncode({'code': 200, 'results': results}),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

Map<String, dynamic> _profile({String nickname = '刷新后的昵称'}) => {
  'user_id': _copyA.userId,
  'username': _copyA.username,
  'nickname': nickname,
  // 空字段不能抹掉另一个历史副本保留的头像。
  'avatar': '',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final user = UserManager();
  final originalApi = ApiClient();
  late UserApi api;
  late Dio primaryDio;
  late Dio commentDio;
  late _OfflineAdapter primaryAdapter;
  late _OfflineAdapter validationAdapter;
  late _OfflineAdapter profileAdapter;

  setUp(() {
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({});
    // 本文件以默认 prefs 后端为主，绝不接触真实凭据存储。
    SecureCredentialStore.resetInstance();
    user.resumeAccountMutationsAfterRestore();
    primaryAdapter = _OfflineAdapter(
      (_) => throw StateError('Unexpected primary HTTP request'),
    );
    validationAdapter = _OfflineAdapter((_) => _response({'list': <Object>[]}));
    profileAdapter = _OfflineAdapter((_) => _response({}));
    primaryDio = Dio()..httpClientAdapter = primaryAdapter;
    commentDio = Dio()..httpClientAdapter = primaryAdapter;
    api = UserApi(
      ApiTransport(
        dio: primaryDio,
        commentDio: commentDio,
        user: user,
        cache: DataCache(),
      ),
      copyDioFactory: (options) =>
          Dio(options)..httpClientAdapter = validationAdapter,
      profileDioFactory: (options) =>
          Dio(options)..httpClientAdapter = primaryAdapter,
      copyProfileDioFactory: (options) =>
          Dio(options)..httpClientAdapter = profileAdapter,
    );
    ApiClient.setTestInstance(_OfflineApiClient(api));
  });

  tearDown(() {
    expect(primaryAdapter.requests, isEmpty);
    primaryDio.close();
    commentDio.close();
    ApiClient.setTestInstance(originalApi);
    user.resumeAccountMutationsAfterRestore();
    teardownSecureCredentialStoreForTest();
  });

  Future<void> load({
    String source = 'hotmanga',
    bool duplicates = true,
    bool persistMigrations = true,
    bool reverse = false,
  }) async {
    SharedPreferences.setMockInitialValues(
      _fixture(
        primarySource: source,
        accounts: duplicates ? [_copyA, _copyB] : [_completeCopyA],
        activeId: duplicates ? _copyB.id : _copyA.id,
        reverse: reverse,
      ),
    );
    SecureCredentialStore.resetInstance();
    await user.init(persistMigrations: persistMigrations);
  }

  Future<bool> tokenLogin(String token) => user.authenticateAndLogin(
    source: 'copy',
    authenticate: () async => (await api.validateCopyToken(token)).toJson(),
  );

  for (final source in ['hotmanga', 'copy']) {
    for (final reverse in [false, true]) {
      test(
        'history deduplicates both stores across cold starts: primary=$source reverse=$reverse',
        () async {
          await load(source: source, reverse: reverse);
          final canonical = _expectCanonical(
            user,
            primarySource: source,
            // HOT 当前时，小说已选 B 是唯一有效选择，不能按列表顺序挑 A。
            token: source == 'hotmanga' ? _copyB.token : null,
          );
          expect({_copyA.token, _copyB.token}, contains(canonical.token));
          await _expectPersistedCanonical(user);
          for (var boot = 0; boot < 2; boot++) {
            await _coldReload(user);
            _expectCanonical(
              user,
              primarySource: source,
              existingIds: {canonical.id!},
              token: canonical.token,
            );
            await _expectPersistedCanonical(user);
          }
        },
      );
    }

    test(
      'read-only duplicate reload never writes preferences: primary=$source',
      () async {
        final initial = _fixture(primarySource: source);
        SharedPreferences.setMockInitialValues(initial);
        await user.init(persistMigrations: false);
        expect(await _disk(), initial);
        _expectCanonical(
          user,
          primarySource: source,
          token: _copyB.token,
          // 只读恢复分别整理两库，不用小说令牌覆盖恢复的主凭据。
          savedCopyToken: _copyA.token,
        );
        final recreated = CopyAccountStore();
        try {
          await recreated.init(persistMigrations: false);
          expect(recreated.accounts, hasLength(1));
          expect(recreated.byId(recreated.activeId)?.username, _copyA.username);
          expect(await _disk(), initial);
        } finally {
          recreated.dispose();
        }
        // 随后的正常启动仍能完成持久化，不能把只读加载当作已落盘。
        await user.init();
        await _expectPersistedCanonical(user);
      },
    );

    test(
      'HTTP profile joins a new token to the selected identity: primary=$source',
      () async {
        await load(source: source, duplicates: false);
        final oldId = user.copyAccount.activeId!;
        final started = Completer<void>();
        final response = Completer<ResponseBody>();
        profileAdapter.respond = (_) {
          started.complete();
          return response.future;
        };
        expect(await tokenLogin(_newToken), isTrue);
        final candidate = user.copyAccount.accounts.singleWhere(
          (item) => item.token == _newToken,
        );
        expect(candidate.hasIdentity, isFalse, reason: '验证新 token 不借用当前账号身份');
        expect(user.copyAccount.accounts, hasLength(2));
        expect(user.copyAccount.activeId, oldId);
        final refresh = user.refreshCopyCredential(candidate, api: api);
        await started.future;
        expect(user.copyToken, _copyA.token);
        response.complete(_response(_profile()));
        expect(await refresh, isTrue);
        final canonical = _expectCanonical(
          user,
          primarySource: source,
          existingIds: {oldId, candidate.id!},
          token: _newToken,
          nickname: '刷新后的昵称',
        );
        expect(
          profileAdapter.requests.single.headers['Authorization'],
          'Token $_newToken',
        );
        await _expectPersistedCanonical(user);
        await _coldReload(user);
        _expectCanonical(
          user,
          primarySource: source,
          existingIds: {canonical.id!},
          token: _newToken,
          nickname: '刷新后的昵称',
        );
      },
    );
  }

  test(
    'web token login succeeds before optional profile dedup completes',
    () async {
      await load(duplicates: false);
      final started = Completer<void>();
      final response = Completer<ResponseBody>();
      profileAdapter.respond = (_) {
        started.complete();
        return response.future;
      };
      final profiled = Completer<void>();
      void onProfile() {
        if (!profiled.isCompleted &&
            user.copyAccount.accounts.any(
              (item) => item.nickname == '刷新后的昵称',
            )) {
          profiled.complete();
        }
      }

      user.addListener(onProfile);
      addTearDown(() async {
        user.removeListener(onProfile);
        if (!response.isCompleted) response.complete(_response({}));
        await user.readAccountStorage(() async {});
      });
      expect(
        await completeCopyWebLogin(
          user: user,
          api: api,
          // 独立 cookie 携带旧身份，不能提前用来给新 token 去重。
          credentials: parseCopyWebCookies({
            'token': _newToken,
            'user_id': _copyA.userId,
            'username': _copyA.username,
          })!,
        ).timeout(const Duration(seconds: 2)),
        isTrue,
      );
      await started.future;
      expect(response.isCompleted, isFalse);
      expect(user.copyAccount.accounts, hasLength(2));
      expect(
        user.copyAccount.accounts
            .singleWhere((item) => item.token == _newToken)
            .hasIdentity,
        isFalse,
      );
      final existingIds = user.copyAccount.accounts
          .map((item) => item.id)
          .whereType<String>()
          .toSet();
      response.complete(_response(_profile()));
      await profiled.future.timeout(const Duration(seconds: 2));
      await user.readAccountStorage(() async {});
      _expectCanonical(
        user,
        primarySource: 'hotmanga',
        existingIds: existingIds,
        token: _newToken,
        nickname: '刷新后的昵称',
      );
      await _expectPersistedCanonical(user);
    },
  );

  test(
    'web form persistence precedes the only background profile request',
    () async {
      await load(duplicates: false);
      var formSaved = false;
      final started = Completer<void>();
      final response = Completer<ResponseBody>();
      final profiled = Completer<void>();
      profileAdapter.respond = (_) {
        expect(formSaved, isTrue);
        started.complete();
        return response.future;
      };
      void onProfile() {
        if (!profiled.isCompleted &&
            user.copyAccount.accounts.any(
              (item) => item.nickname == '刷新后的昵称',
            )) {
          profiled.complete();
        }
      }

      user.addListener(onProfile);
      addTearDown(() async {
        user.removeListener(onProfile);
        if (!response.isCompleted) response.complete(_response({}));
        await user.readAccountStorage(() async {});
      });
      expect(
        await completeCopyWebLogin(
          user: user,
          api: api,
          credentials: parseCopyWebCookies({'token': _newToken})!,
          persistLoginFormPasswords: () async {
            final revision = user.copyAccount.revision;
            await user.saveLoginFormPasswords({
              _copyA.username: _copyPassword,
            }, anchorToken: _newToken);
            expect(user.copyAccount.revision, greaterThan(revision));
            formSaved = true;
          },
        ),
        isTrue,
      );
      await started.future.timeout(const Duration(seconds: 2));
      expect(response.isCompleted, isFalse);
      response.complete(_response(_profile()));
      await profiled.future.timeout(const Duration(seconds: 2));
      await user.readAccountStorage(() async {});
      _expectCanonical(
        user,
        primarySource: 'hotmanga',
        existingIds: {_copyA.id!},
        token: _newToken,
        nickname: '刷新后的昵称',
      );
      expect(profileAdapter.requests, hasLength(1));
      await _expectPersistedCanonical(user);
    },
  );

  for (final refreshOnly in [false, true]) {
    test(
      'existing duplicates are persisted as one after ${refreshOnly ? 'direct profile refresh' : 'verified re-login'}',
      () async {
        await load(persistMigrations: false);
        final storedBefore = await SecureCredentialStore()
            .readCopyAccountRecord();
        expect(storedBefore, contains(_copyA.token));
        expect(storedBefore, contains(_copyB.token));
        final observed = <Map<String, Object?>>[];
        void changed() => observed.add(_state(user));
        user.addListener(changed);
        addTearDown(() => user.removeListener(changed));
        final token = refreshOnly ? user.copyAccount.session!.token : _newToken;
        if (refreshOnly) {
          profileAdapter.respond = (_) => _response(_profile());
          expect(
            await user.refreshCopyCredential(
              user.copyAccount.session!,
              api: api,
            ),
            isTrue,
          );
        } else {
          expect(
            await user.authenticateAndLogin(
              source: 'copy',
              authenticate: () async => {
                'token': _newToken,
                'user_id': _copyA.userId,
                'username': _copyA.username,
                'nickname': '刷新后的昵称',
              },
            ),
            isTrue,
          );
        }
        _expectCanonical(
          user,
          primarySource: 'hotmanga',
          token: token,
          nickname: '刷新后的昵称',
        );
        expect(observed, hasLength(1), reason: '双库归并只发布一次一致状态');
        expect(observed.single, _state(user));
        await _expectPersistedCanonical(user);
      },
    );
  }

  test('same login name merges history even when server ids differ', () async {
    SharedPreferences.setMockInitialValues(
      _fixture(
        accounts: [
          _copyA,
          _copyB.copyWith(userId: 'fictional-reissued-id'),
        ],
      ),
    );
    await user.init();
    expect(user.copyAccount.accounts, hasLength(1));
    expect(
      user.savedCredentials.where((item) => item.source == 'copy'),
      hasLength(1),
    );
    expect(user.copyToken, _copyB.token);
    expect(user.copyAccount.session?.username, _copyA.username);
    await _expectPersistedCanonical(user);
  });

  for (final fallback in ['user-id', 'same-token']) {
    test(
      'missing login names deduplicate using $fallback without new handles',
      () async {
        final first = _copyA.copyWith(
          username: '',
          userId: fallback == 'user-id' ? _copyA.userId : '',
        );
        final second = _copyB.copyWith(
          username: '',
          userId: fallback == 'user-id' ? _copyA.userId : '',
          token: fallback == 'same-token' ? first.token : _copyB.token,
        );
        SharedPreferences.setMockInitialValues(
          _fixture(accounts: [first, second]),
        );
        await user.init();
        expect(user.copyAccount.accounts, hasLength(1));
        expect({first.id, second.id}, contains(user.copyAccount.activeId));
        expect(user.copyToken, second.token);
        expect(user.copyAccount.session?.username, isEmpty);
        expect(user.copyAccount.session?.hasIdentity, fallback == 'user-id');
        await _expectPersistedCanonical(user);
      },
    );
  }

  test(
    'different nonempty login names never merge by shared user id or display fields',
    () async {
      await load(duplicates: false);
      const secondName = 'fictional-other-reader';
      expect(
        await user.authenticateAndLogin(
          source: 'copy',
          authenticate: () async => {
            'token': 'fictional-other-token',
            'username': secondName,
            // 非空登录名优先，不能被 userId 或显示资料的碰撞绕过。
            'user_id': _copyA.userId,
            'nickname': _copyA.nickname,
            'avatar': _copyB.avatar,
          },
        ),
        isTrue,
      );
      expect(user.copyAccount.accounts, hasLength(2));
      expect(
        user.copyAccount.accounts.map((item) => item.username),
        unorderedEquals([_copyA.username, secondName]),
      );
      expect(
        user.savedCredentials.where((item) => item.source == 'copy'),
        hasLength(2),
      );
      expect(user.copyToken, _copyA.token);
      expect(user.token, _hot.token);
      await user.init();
      expect(user.copyAccount.accounts, hasLength(2));
      expect(
        user.savedCredentials
            .where((item) => item.source == 'hotmanga')
            .single
            .token,
        _hot.token,
      );
    },
  );

  test(
    'unknown different tokens remain separate despite identical display profiles',
    () async {
      await load(duplicates: false);
      for (final token in ['fictional-unknown-a', 'fictional-unknown-b']) {
        expect(
          await user.authenticateAndLogin(
            source: 'copy',
            authenticate: () async => {
              'token': token,
              'nickname': _copyA.nickname,
              'avatar': _copyB.avatar,
            },
          ),
          isTrue,
        );
      }
      expect(user.copyAccount.accounts, hasLength(3));
      final unknown = user.copyAccount.accounts
          .where((item) => !item.hasIdentity)
          .toList();
      expect(unknown, hasLength(2));
      expect(unknown.first.id, isNot(unknown.last.id));
      expect(
        user.savedCredentials.where((item) => item.source == 'copy'),
        hasLength(3),
      );
      expect(user.copyToken, _copyA.token);
      await user.init();
      expect(user.copyAccount.accounts, hasLength(3));
      expect(
        user.savedCredentials.where((item) => item.source == 'copy'),
        hasLength(3),
      );
    },
  );

  test(
    'profile merge rolls back both stores when COPY record write fails',
    () async {
      final secure = FailingAccountSecureStore();
      SharedPreferences.setMockInitialValues(
        _fixture(accounts: [_completeCopyA], activeId: _copyA.id),
      );
      SecureCredentialStore.setInstance(secure);
      await secure.writeToken(_hot.token);
      await secure.writeUsername(_hot.username);
      await secure.writePassword(_hot.password);
      await secure.writeCredentials([
        _hot,
        _credential(_completeCopyA, password: _copyPassword),
      ]);
      await secure.writeCopyAccountRecord(_record([_completeCopyA], _copyA.id));
      await user.init();
      expect(await tokenLogin(_newToken), isTrue);
      final candidate = user.copyAccount.accounts.singleWhere(
        (item) => item.token == _newToken,
      );
      final before = _state(user);
      final beforeRecord = await secure.readCopyAccountRecord();
      final beforeCredentials = jsonEncode(
        (await secure.readCredentials()).map((item) => item.toJson()).toList(),
      );
      var failed = false;
      secure.beforeWrite = (key, _) async {
        if (key == 'copy_account_v1' && !failed) {
          failed = true;
          throw StateError('Injected COPY record failure');
        }
      };
      profileAdapter.respond = (_) => _response(_profile());
      var notifications = 0;
      void changed() => notifications++;
      user.addListener(changed);
      addTearDown(() => user.removeListener(changed));
      await expectLater(
        user.refreshCopyCredential(candidate, api: api),
        throwsA(isA<CopyAccountStorageException>()),
      );
      expect(failed, isTrue);
      expect(notifications, 0);
      expect(_state(user), before);
      expect(await secure.readCopyAccountRecord(), beforeRecord);
      expect(
        jsonEncode(
          (await secure.readCredentials())
              .map((item) => item.toJson())
              .toList(),
        ),
        beforeCredentials,
      );
      expect(
        user.copyAccount.accounts.any(
          (item) => item.token == _newToken && !item.hasIdentity,
        ),
        isTrue,
        reason: '资料补全失败不撤销已成功的 token-only 登录',
      );
    },
  );

  for (final change in [
    'comic-selection',
    'novel-selection',
    'logout',
    'clear-copy',
  ]) {
    test(
      'late identity profile cannot undo $change or merge stale credentials',
      () async {
        await load(source: 'copy', duplicates: false);
        expect(await tokenLogin(_newToken), isTrue);
        const other = CopyAccountSession(
          token: 'fictional-other-selected-token',
          accountId: 'local:other',
          username: 'fictional-other-selected-user',
          userId: 'fictional-other-selected-id',
        );
        await user.copyAccount.saveSession(other, select: false);
        final candidate = user.copyAccount.accounts.singleWhere(
          (item) => item.token == _newToken,
        );
        final started = Completer<void>();
        final response = Completer<ResponseBody>();
        profileAdapter.respond = (_) {
          started.complete();
          return response.future;
        };
        final refreshing = user.refreshCopyCredential(candidate, api: api);
        await started.future;
        switch (change) {
          case 'comic-selection':
            expect(await user.switchToCredential(_hot), isTrue);
          case 'novel-selection':
            expect(await user.copyAccount.selectAccount(other.id), isTrue);
          case 'logout':
            await user.logout();
          case 'clear-copy':
            await user.copyAccount.clear();
        }
        final before = _state(user);
        final beforeDisk = await _disk();
        response.complete(_response(_profile()));
        expect(await refreshing, isFalse);
        expect(_state(user), before);
        expect(await _disk(), beforeDisk);
        if (change == 'logout') {
          await user.init();
          expect(user.token, isNull, reason: '退出标记不能被迟到资料复活');
        } else if (change == 'clear-copy') {
          await user.init();
          expect(user.copyAccount.accounts, isEmpty);
          expect(user.copyToken, isNull);
        }
      },
    );
  }
}

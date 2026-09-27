import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kira/api/api_client.dart';
import 'package:kira/api/api_transport.dart';
import 'package:kira/api/user/user_api.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/copy_account_store.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/login_page.dart';
import 'package:kira/pages/profile_page.dart';
import 'package:kira/utils/copy_web_login.dart';
import 'package:kira/utils/data_cache.dart';
import 'package:kira/widgets/login_node_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];

  _FakeAdapter(this.respond);

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

class _TestSecureStore extends InMemorySecureCredentialStore {
  bool failCopyWrite = false;

  @override
  Future<void> writeCopyAccountRecord(String value) {
    if (failCopyWrite) throw StateError('Storage unavailable');
    return super.writeCopyAccountRecord(value);
  }
}

class _FakeApiClient implements ApiClient {
  @override
  final UserApi user;

  _FakeApiClient(this.user);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected API access in offline test: ${invocation.memberName}',
  );
}

ResponseBody _jsonResponse(Object data, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

const _oldSession = CopyAccountSession(
  token: 'old-copy',
  userId: 'old-copy-id',
  username: 'old-copy-user',
);

Map<String, Object?> _mainSnapshot(UserManager user) => {
  'token': user.token,
  'source': user.loginSource,
  'username': user.username,
  'id': user.userId,
  'nickname': user.nickname,
  'avatar': user.avatar,
  'savedUsername': user.savedUsername,
  'savedPassword': user.savedPassword,
  'saved': jsonEncode(user.savedCredentials.map((e) => e.toJson()).toList()),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final user = UserManager();
  final originalApi = ApiClient();
  late UserApi api;
  late _FakeAdapter copyAdapter;
  late _FakeAdapter mainAdapter;
  late Dio primaryDio;
  late Dio commentDio;
  late ApiTransport transport;
  late _TestSecureStore secure;
  late FutureOr<ResponseBody> Function(RequestOptions) response;
  late FutureOr<ResponseBody> Function(RequestOptions) primaryResponse;
  var expectedPrimaryRequests = 0;
  var expectedReLogins = 0;
  var probes = 0;
  var reLogins = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'login_source': 'hotmanga',
      'user_token': 'hot-token',
      'user_id': 'hot-id',
      'user_username': 'same-username',
      'user_nickname': 'HOT name',
      'user_avatar': '',
      'saved_username': 'same-username',
      'saved_password': 'hot-password',
      'saved_credentials': jsonEncode([
        {
          'username': 'same-username',
          'password': 'hot-password',
          'login_source': 'hotmanga',
          'token': 'hot-token',
        },
      ]),
    });
    secure = _TestSecureStore();
    SecureCredentialStore.setInstance(secure);
    await user.init();
    probes = 0;
    reLogins = 0;
    expectedPrimaryRequests = 0;
    expectedReLogins = 0;
    LoginNodeStatusCard.probeOverride = (hosts, {onHostResult}) async {
      probes++;
      for (final host in hosts) {
        onHostResult?.call(host, 1);
      }
      return {for (final host in hosts) host: 1};
    };
    LoginNodeStatusCard.hotHostOverride = () => 'mapi.hotmangasg.com';
    response = (_) => _jsonResponse({
      'code': 200,
      'results': {'list': <Object>[], 'total': 0},
    });
    copyAdapter = _FakeAdapter((request) => response(request));
    primaryResponse = (_) => throw StateError('Unexpected primary request');
    mainAdapter = _FakeAdapter((request) => primaryResponse(request));
    primaryDio = Dio()..httpClientAdapter = mainAdapter;
    commentDio = Dio()..httpClientAdapter = mainAdapter;
    transport = ApiTransport(
      dio: primaryDio,
      commentDio: commentDio,
      user: user,
      cache: DataCache(),
    );
    transport.loginHandler = (_, _) async {
      reLogins++;
      throw StateError('Unexpected HOT auto-login');
    };
    transport.copyLoginHandler = (_, _) async {
      reLogins++;
      throw StateError('Unexpected primary COPY auto-login');
    };
    api = UserApi(
      transport,
      copyDioFactory: (options) =>
          Dio(options)..httpClientAdapter = copyAdapter,
      profileDioFactory: (options) =>
          Dio(options)..httpClientAdapter = mainAdapter,
    );
    // Any accidental refresh/logout through the global facade must hit a fake,
    // never the singleton's platform HttpClientAdapter.
    ApiClient.setTestInstance(_FakeApiClient(api));
  });

  tearDown(() {
    expect(mainAdapter.requests, hasLength(expectedPrimaryRequests));
    expect(reLogins, expectedReLogins);
    primaryDio.close();
    commentDio.close();
    LoginNodeStatusCard.probeOverride = null;
    LoginNodeStatusCard.hotHostOverride = null;
    ApiClient.setTestInstance(originalApi);
    SecureCredentialStore.resetInstance();
  });

  Future<void> pumpLogin(
    WidgetTester tester, {
    bool profile = false,
    bool copyOnly = true,
  }) async {
    final router = GoRouter(
      initialLocation: profile ? '/' : '/login',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => profile
              ? const ProfilePage()
              : const Scaffold(body: Text('test-home')),
          routes: [
            GoRoute(
              name: 'login',
              path: 'login',
              builder: (_, state) => LoginPage(
                copyOnly: profile
                    ? state.uri.queryParameters['copyOnly'] == 'true'
                    : copyOnly,
                userApi: api,
              ),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> submitPassword(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).at(0), 'same-username');
    await tester.enterText(find.byType(TextField).at(1), 'copy-password');
    await tester.ensureVisible(find.widgetWithText(FilledButton, '登录'));
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
  }

  Future<void> submitToken(
    WidgetTester tester, {
    String token = 'candidate-copy',
  }) async {
    await tester.tap(find.byIcon(Icons.key).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, token);
    final button = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, '登录'),
    );
    await tester.runAsync(() async {
      await tester.tap(button);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
  }

  test(
    'token validation uses only the explicit candidate and dynamic COPY headers',
    () async {
      await user.copyAccount.saveSession(_oldSession);
      final before = _mainSnapshot(user);
      final result = await api.validateCopyToken('  candidate-copy  ');
      expect(result.token, 'candidate-copy');
      expect(user.copyToken, 'old-copy');
      expect(_mainSnapshot(user), before);
      // Collection validation never invents a profile lookup.
      final validation = copyAdapter.requests.single;
      expect(result.username, isEmpty);
      final request = validation;
      expect(request.uri.host, user.copyApiHost);
      expect(request.method, 'GET');
      expect(request.path, endsWith('/api/v3/member/collect/books'));
      expect(request.headers['Authorization'], 'Token candidate-copy');
      expect(request.headers['User-Agent'], 'COPY/${user.copyAppVersion}');
      expect(request.headers['source'], 'copyApp');
      expect(request.headers['platform'], '3');
      expect(request.headers['version'], user.copyAppVersion);
      expect(request.headers['webp'], '1');
      expect(request.followRedirects, isFalse);
      expect(request.uri.queryParameters, {
        'limit': '1',
        'offset': '0',
        'free_type': '1',
        'ordering': '-datetime_modifier',
        'platform': '3',
      });
      await user.setCopyApiHost('copy-test.invalid');
      await user.setCopyAppVersion('9.8.7');
      await api.validateCopyToken('second-copy');
      final changed = copyAdapter.requests
          .where((r) => r.path.endsWith('/member/collect/books'))
          .last;
      expect(changed.uri.host, 'copy-test.invalid');
      expect(changed.headers['User-Agent'], 'COPY/9.8.7');
      expect(changed.headers['Authorization'], 'Token second-copy');
    },
  );

  test('validated known token reuses only its exact stored identity', () async {
    await user.copyAccount.saveSession(_oldSession);
    final before = _mainSnapshot(user);
    final result = await api.validateCopyToken(_oldSession.token);
    expect(result.userId, _oldSession.userId);
    expect(result.username, _oldSession.username);
    expect(user.copyToken, _oldSession.token);
    expect(_mainSnapshot(user), before);
    expect(copyAdapter.requests, hasLength(1));
  });

  test(
    'unknown valid token remains identity-less without guessing APIs',
    () async {
      await user.copyAccount.saveSession(_oldSession);
      final result = await api.validateCopyToken('candidate-copy');
      expect(result.token, 'candidate-copy');
      expect(result.id, isNull);
      expect(copyAdapter.requests, hasLength(1));
      expect(
        copyAdapter.requests.single.path,
        endsWith('/member/collect/books'),
      );
    },
  );

  test(
    'HTTP/business 401, redirects and malformed successes never affect either account',
    () async {
      await user.copyAccount.saveSession(_oldSession);
      final before = _mainSnapshot(user);
      for (final scenario in [
        (status: 401, data: <String, Object>{'code': 401}),
        (status: 200, data: <String, Object>{'code': 401}),
        (
          status: 302,
          data: <String, Object>{
            'code': 200,
            'results': {'list': []},
          },
        ),
        (status: 200, data: <String, Object>{'code': 200, 'results': {}}),
      ]) {
        response = (_) => _jsonResponse(scenario.data, scenario.status);
        await expectLater(
          user.copyAccount.login(() => api.validateCopyToken('bad-copy')),
          throwsA(isA<DioException>()),
        );
        expect(user.copyToken, 'old-copy');
        expect(_mainSnapshot(user), before);
      }
    },
  );

  test(
    'COPY password API returns a session without any UserManager side effect',
    () async {
      final before = _mainSnapshot(user);
      response = (_) => _jsonResponse({
        'code': 200,
        'results': {
          'token': 'password-copy',
          'username': 'same-username',
          'user_id': 'copy-id',
        },
      });
      final result = await api.copyLogin('same-username', 'copy-password');
      expect(result['token'], 'password-copy');
      expect(user.copyToken, isNull);
      expect(_mainSnapshot(user), before);
      expect(copyAdapter.requests.single.uri.path, '/api/kb/web/login');
      expect(
        copyAdapter.requests.single.headers.containsKey('Authorization'),
        isFalse,
      );
    },
  );

  for (final switchAccount in [false, true]) {
    test(
      'late primary COPY 401 relogin cannot ${switchAccount ? 'overwrite switched COPY' : 'revive logged-out COPY'}',
      () async {
        await user.setLoginSource('copy');
        await user.setAutoLogin(true);
        await user.copyAccount.saveSession(_oldSession);
        final started = Completer<void>();
        final relogin = Completer<Map<String, dynamic>>();
        expectedPrimaryRequests = 2;
        expectedReLogins = 1;
        transport.copyLoginHandler = (_, _) {
          reLogins++;
          started.complete();
          return relogin.future;
        };
        primaryResponse = (_) => mainAdapter.requests.length == 1
            ? _jsonResponse({'code': 401}, 401)
            : _jsonResponse({'code': 200, 'results': <String, Object>{}});
        final request = primaryDio.get<dynamic>(
          'https://primary.test/needs-auth',
        );
        await started.future;
        if (switchAccount) {
          await user.copyAccount.saveSession(
            const CopyAccountSession(
              token: 'manually-switched-copy',
              userId: 'switched-id',
            ),
          );
        } else {
          await user.copyAccount.logout();
        }
        final beforeRecord = await secure.readCopyAccountRecord();
        final beforeRevision = user.copyAccount.revision;
        relogin.complete({
          'token': 'late-primary-copy',
          'user_id': 'copy-id',
          'username': 'copy-main',
          'nickname': 'COPY main',
          'avatar': '',
        });
        await request;
        expect(user.token, 'late-primary-copy');
        expect(user.copyToken, switchAccount ? 'manually-switched-copy' : null);
        expect(user.copyAccount.revision, beforeRevision);
        expect(await secure.readCopyAccountRecord(), beforeRecord);
        await user.init();
        expect(user.copyToken, switchAccount ? 'manually-switched-copy' : null);
      },
    );
  }

  testWidgets(
    'ordinary COPY token selection rejects a HOT-valid candidate without touching accounts',
    (tester) async {
      await tester.runAsync(() async {
        await user.setLoginSource('copy');
        await user.copyAccount.saveSession(_oldSession);
      });
      final before = _mainSnapshot(user);
      // This candidate is valid only on HOT. The selected COPY validator must
      // reject it instead of silently using HOT member/info and marking COPY.
      primaryResponse = (_) => _jsonResponse({
        'code': 200,
        'results': {'user_id': 'hot-new', 'username': 'hot-new'},
      });
      response = (_) => _jsonResponse({'code': 401}, 401);
      await pumpLogin(tester, copyOnly: false);
      await submitToken(tester, token: 'valid-hot-only');
      expect(_mainSnapshot(user), before);
      expect(user.copyToken, 'old-copy');
      expect(
        copyAdapter.requests.single.headers['Authorization'],
        'Token valid-hot-only',
      );
      expect(find.byType(AlertDialog), findsOneWidget);
    },
  );

  testWidgets(
    'explicit HOT token selection persists HOT provenance and cannot migrate as COPY',
    (tester) async {
      await tester.runAsync(() async {
        await user.setLoginSource('copy');
        await user.copyAccount.saveSession(_oldSession);
      });
      expectedPrimaryRequests = 1;
      primaryResponse = (_) => _jsonResponse({
        'code': 200,
        'results': {'user_id': 'hot-new', 'username': 'hot-new'},
      });
      await pumpLogin(tester, copyOnly: false);
      await tester.tap(find.text('热辣漫画'));
      await tester.pumpAndSettle();
      await submitToken(tester, token: 'valid-hot-only');
      expect(user.token, 'valid-hot-only');
      expect(user.loginSource, 'hotmanga');
      expect(user.copyToken, 'old-copy');
      expect(copyAdapter.requests, isEmpty);
      await tester.runAsync(() async {
        // A missing record also models startup when secure migration could
        // not run before this login. Persisted HOT provenance must stay safe.
        await secure.deleteAll();
        await user.init();
      });
      expect(user.copyToken, isNull);
      expect(jsonDecode((await secure.readCopyAccountRecord())!), {
        'migrationHandled': true,
        'activeId': null,
        'accounts': <Object?>[],
      });
    },
  );

  testWidgets(
    'ordinary COPY token validation explicitly synchronizes the independent account',
    (tester) async {
      await tester.runAsync(() => user.setLoginSource('copy'));
      await tester.runAsync(
        () => user.copyAccount.saveSession(
          const CopyAccountSession(
            token: 'validated-copy',
            userId: 'validated-id',
            username: 'validated-user',
          ),
        ),
      );
      await pumpLogin(tester, copyOnly: false);
      await submitToken(tester, token: 'validated-copy');
      expect(user.token, 'validated-copy');
      expect(user.loginSource, 'copy');
      expect(user.copyToken, 'validated-copy');
      expect(user.copyAccount.activeId, 'u:validated-id');
      expect(
        copyAdapter.requests.first.uri.path,
        '/api/v3/member/collect/books',
      );
      expect(find.text('test-home'), findsOneWidget);
    },
  );

  testWidgets(
    'ordinary COPY password login explicitly synchronizes after COPY authentication',
    (tester) async {
      await tester.runAsync(() => user.setLoginSource('copy'));
      response = (_) => _jsonResponse({
        'code': 200,
        'results': {
          'token': 'authenticated-copy',
          'user_id': 'copy-id',
          'username': 'copy-main',
          'nickname': 'COPY main',
        },
      });
      primaryResponse = (_) => _jsonResponse({
        'code': 200,
        'results': {'user_id': 'copy-id', 'username': 'copy-main'},
      });
      await pumpLogin(tester, copyOnly: false);
      await submitPassword(tester);
      expect(user.token, 'authenticated-copy');
      expect(user.loginSource, 'copy');
      expect(user.copyToken, 'authenticated-copy');
      expect(copyAdapter.requests.single.uri.path, '/api/kb/web/login');
    },
  );

  testWidgets(
    'COPY-only mode hides HOT switch and saved credentials but keeps official login',
    (tester) async {
      await pumpLogin(tester);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.text('热辣漫画'), findsNothing);
      expect(find.text('same-username'), findsNothing);
      // 官网登录保持可用：COPY-only 入口必须能走 WebView，否则只能手抄令牌。
      expect(find.text('官网登录'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('official-register-copy')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.key), findsOneWidget);
      expect(
        tester
            .widget<LoginNodeStatusCard>(find.byType(LoginNodeStatusCard))
            .useCopyLogin,
        isTrue,
      );
      expect(probes, 1);
      expect(copyAdapter.requests, isEmpty);
    },
  );

  testWidgets(
    'ordinary login retains the source switch and saved primary credential',
    (tester) async {
      await pumpLogin(tester, copyOnly: false);
      expect(find.byType(SegmentedButton<bool>), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsOneWidget);
      // 已保存账号卡列表已移除，仅表单预填主账号。
      expect(find.text('same-username'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('official-register-hotmanga')),
        findsOneWidget,
      );
      expect(copyAdapter.requests, isEmpty);
    },
  );

  testWidgets(
    'COPY-only password login selects COPY for comics and novels without losing HOT',
    (tester) async {
      response = (_) => _jsonResponse({
        'code': 200,
        'results': {
          'token': 'password-copy',
          'username': 'same-username',
          'user_id': 'copy-id',
          'nickname': 'COPY name',
        },
      });
      await pumpLogin(tester);
      await submitPassword(tester);
      expect(user.copyToken, 'password-copy');
      expect(user.token, 'password-copy');
      expect(user.loginSource, 'copy');
      expect(
        user.savedCredentials.where((item) => item.username == 'same-username'),
        hasLength(2),
      );
      expect(
        user.savedCredentials
            .singleWhere((item) => item.source == 'hotmanga')
            .token,
        'hot-token',
      );
      expect(find.text('test-home'), findsOneWidget);
      expect(copyAdapter.requests, hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('user_token'), isNull);
      expect(await secure.readToken(), 'password-copy');
      expect(
        prefs.getKeys().any((key) => key.startsWith('copy_account')),
        isFalse,
      );
      expect(await secure.readCopyAccountRecord(), contains('password-copy'));
    },
  );

  testWidgets(
    'COPY-only password failure preserves primary and existing COPY',
    (tester) async {
      await tester.runAsync(() => user.copyAccount.saveSession(_oldSession));
      final before = _mainSnapshot(user);
      response = (_) => _jsonResponse({'code': 401, 'message': 'invalid'}, 401);
      await pumpLogin(tester);
      await submitPassword(tester);
      expect(user.copyToken, 'old-copy');
      expect(_mainSnapshot(user), before);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'COPY-only token login validates before persisting and never refreshes main profile',
    (tester) async {
      await tester.runAsync(
        () => user.copyAccount.saveSession(
          const CopyAccountSession(
            token: 'candidate-copy',
            userId: 'candidate-id',
            username: 'candidate-user',
          ),
        ),
      );
      await pumpLogin(tester);
      await submitToken(tester);
      expect(user.copyToken, 'candidate-copy');
      expect(user.copyAccount.activeId, 'u:candidate-id');
      expect(user.token, 'candidate-copy');
      expect(user.loginSource, 'copy');
      expect(
        copyAdapter.requests.first.headers['Authorization'],
        'Token candidate-copy',
      );
      expect(find.text('test-home'), findsOneWidget);
    },
  );

  testWidgets(
    'COPY-only token failure does not clear either existing account',
    (tester) async {
      await tester.runAsync(() => user.copyAccount.saveSession(_oldSession));
      final before = _mainSnapshot(user);
      response = (_) => _jsonResponse({'code': 401}, 401);
      await pumpLogin(tester);
      await submitToken(tester);
      expect(user.copyToken, 'old-copy');
      expect(_mainSnapshot(user), before);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('profile no longer shows a standalone COPY account card', (
    tester,
  ) async {
    await tester.runAsync(() => user.copyAccount.saveSession(_oldSession));
    await pumpLogin(tester, profile: true);
    // 轻小说的拷贝账号统一走「我的」里已有的登录入口，
    // 不再单独放一张账号卡片。
    expect(find.byKey(const ValueKey('copy-account-card')), findsNothing);
    expect(find.byKey(const ValueKey('copy-account-login')), findsNothing);
    expect(find.byKey(const ValueKey('copy-account-logout')), findsNothing);
    expect(find.text('old-copy'), findsNothing);
    expect(user.copyToken, 'old-copy');
    expect(copyAdapter.requests, isEmpty);
  });

  testWidgets(
    'COPY password response without profile still binds both using the authenticated login name',
    (tester) async {
      response = (_) => _jsonResponse({
        'code': 200,
        'results': {'token': 'minimal-copy'},
      });
      await pumpLogin(tester);
      await submitPassword(tester);
      expect(user.token, 'minimal-copy');
      expect(user.copyToken, 'minimal-copy');
      expect(user.copyAccount.session?.username, 'same-username');
      expect(user.copyAccount.activeId, isNotNull);
      expect(find.text('test-home'), findsOneWidget);
    },
  );

  testWidgets('HOT password login changes comics but keeps the novel account', (
    tester,
  ) async {
    await tester.runAsync(() => user.copyAccount.saveSession(_oldSession));
    expectedPrimaryRequests = 1;
    primaryResponse = (_) => _jsonResponse({
      'code': 200,
      'results': {
        'token': 'new-hot',
        'user_id': 'new-hot-id',
        'username': 'same-username',
      },
    });
    await pumpLogin(tester, copyOnly: false);
    await submitPassword(tester);
    expect(user.token, 'new-hot');
    expect(user.loginSource, 'hotmanga');
    expect(user.copyToken, _oldSession.token);
    expect(copyAdapter.requests, isEmpty);
  });

  for (final copyOnly in [false, true]) {
    testWidgets(
      'unknown COPY token in copyOnly=$copyOnly never pretends to be a bound account',
      (tester) async {
        await tester.runAsync(() async {
          if (!copyOnly) await user.setLoginSource('copy');
          await user.copyAccount.saveSession(_oldSession);
        });
        final before = _mainSnapshot(user);
        await pumpLogin(tester, copyOnly: copyOnly);
        await submitToken(tester, token: 'unknown-valid-token');
        expect(_mainSnapshot(user), before);
        expect(user.copyToken, _oldSession.token);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(copyAdapter.requests, hasLength(1));
        expect(
          copyAdapter.requests.single.path,
          endsWith('/member/collect/books'),
        );
      },
    );
  }

  test(
    'COPY secure write failure rolls back primary login rather than reporting success',
    () async {
      await user.copyAccount.saveSession(_oldSession);
      final before = _mainSnapshot(user);
      final beforeCredentials = await secure.readCredentials();
      secure.failCopyWrite = true;
      await expectLater(
        user.authenticateAndLogin(
          source: 'copy',
          authenticate: () async => {
            'token': 'failed-copy',
            'username': 'copy-user',
            'user_id': 'copy-id',
          },
        ),
        throwsA(isA<CopyAccountStorageException>()),
      );
      expect(_mainSnapshot(user), before);
      expect(user.copyToken, _oldSession.token);
      expect(await secure.readToken(), before['token']);
      // 回滚把内存发布态写回 secure：同一账号的资料字段（id/昵称/头像）
      // 可能在 init 时已合并进内存版本，所以按账号有效字段比较而非字节。
      final afterCredentials = await secure.readCredentials();
      expect(afterCredentials.length, beforeCredentials.length);
      for (var i = 0; i < afterCredentials.length; i++) {
        expect(afterCredentials[i].username, beforeCredentials[i].username);
        expect(afterCredentials[i].password, beforeCredentials[i].password);
        expect(afterCredentials[i].token, beforeCredentials[i].token);
        expect(
          afterCredentials[i].loginSource,
          beforeCredentials[i].loginSource,
        );
      }
    },
  );

  test(
    'late COPY login cannot overwrite a manual novel selection or primary logout',
    () async {
      await user.copyAccount.saveSession(_oldSession);
      for (final logout in [false, true]) {
        final pending = Completer<Map<String, dynamic>>();
        final signingIn = user.authenticateAndLogin(
          source: 'copy',
          authenticate: () => pending.future,
        );
        if (logout) {
          await user.logout();
        } else {
          await user.copyAccount.selectAccount(_oldSession.id);
        }
        final before = _mainSnapshot(user);
        pending.complete({
          'token': 'late-copy',
          'username': 'late-user',
          'user_id': 'late-id',
        });
        expect(await signingIn, isFalse);
        expect(_mainSnapshot(user), before);
        expect(user.copyToken, _oldSession.token);
      }
    },
  );

  test('COPY login listeners observe both selections together', () async {
    final observations = <({String? comic, String? novel})>[];
    void listener() =>
        observations.add((comic: user.token, novel: user.copyToken));
    user.addListener(listener);
    try {
      expect(
        await user.authenticateAndLogin(
          source: 'copy',
          authenticate: () async => {
            'token': 'new-copy',
            'username': 'new-copy-user',
            'user_id': 'new-copy-id',
          },
        ),
        isTrue,
      );
    } finally {
      user.removeListener(listener);
    }
    expect(observations, isNotEmpty);
    expect(
      observations.every(
        (item) => item.comic == 'new-copy' && item.novel == 'new-copy',
      ),
      isTrue,
    );
  });

  test(
    'WebView official login validates then selects COPY in both domains',
    () async {
      await user.copyAccount.saveSession(_oldSession);
      final saved = await completeCopyWebLogin(
        user: user,
        api: api,
        credentials: const CopyWebCredentials(
          token: 'web-copy-token',
          userId: 'web-id',
          nickname: 'web-copy',
          avatar: '',
        ),
      );
      expect(saved, isTrue);
      expect(user.copyToken, 'web-copy-token');
      expect(user.token, 'web-copy-token');
      expect(user.loginSource, 'copy');
      expect(user.copyAccount.activeId, 'u:web-id');
      expect(
        user.savedCredentials.any((item) => item.token == 'hot-token'),
        isTrue,
      );
      await user.init();
      expect(user.token, 'web-copy-token');
      expect(user.copyToken, 'web-copy-token');
      expect(
        user.savedCredentials.any((item) => item.userId == 'web-id'),
        isTrue,
      );
    },
  );
}

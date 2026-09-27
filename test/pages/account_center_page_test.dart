import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kira/api/api_client.dart';
import 'package:kira/api/user/user_api.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/copy_account_store.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/account_center_page.dart';
import 'package:kira/widgets/account_avatar.dart';
import 'package:kira/widgets/select_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

class _ProfileApi implements UserApi {
  Future<Map<String, dynamic>> Function(String, String)? respond;
  final requests = <({String token, String source})>[];

  @override
  Future<Map<String, dynamic>> getCredentialInfo({
    required String token,
    required String source,
  }) async {
    requests.add((token: token, source: source));
    if (source == 'copy') throw const CopyProfileUnavailableException();
    return respond!(token, source);
  }

  @override
  void clearAuthState() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected API call');
}

class _FailingSecureStore extends InMemorySecureCredentialStore {
  @override
  Future<void> doWrite(String key, String value) async {
    throw StateError('Secure storage unavailable');
  }
}

class _FakeClient implements ApiClient {
  @override
  final UserApi user;
  _FakeClient(this.user);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected API call');
}

const _copyA = CopyAccountSession(
  token: 'copy-a-token',
  userId: 'copy-a',
  username: 'copy-a-user',
  nickname: '拷贝甲',
  label: '旧备注不得展示',
);
const _copyB = CopyAccountSession(
  token: 'copy-b-token',
  userId: 'copy-b',
  username: 'copy-b-user',
);
const _second = SavedCredential(
  username: 'second-hot-user',
  password: '',
  token: 'second-token',
  userId: 'second-id',
  nickname: '第二个主号',
  loginSource: 'hotmanga',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final user = UserManager();
  final originalApi = ApiClient();
  late _ProfileApi api;
  String? clipboard;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'user_token': 'hot-token',
      'user_user_id': 'hot-id',
      'user_username': 'hot-user',
      'user_nickname': '热辣主号',
      'user_avatar': '',
      'login_source': 'hotmanga',
      'saved_username': 'hot-user',
      'saved_password': 'hot-pass',
      'saved_credentials': jsonEncode([
        {
          'username': 'hot-user',
          'password': 'hot-pass',
          'token': 'hot-token',
          'login_source': 'hotmanga',
          'user_id': 'hot-id',
          'nickname': '热辣主号',
        },
        _second.toJson(),
      ]),
    });
    setupSecureCredentialStoreForTest();
    api = _ProfileApi();
    ApiClient.setTestInstance(_FakeClient(api));
    await user.init();
    await user.copyAccount.clear();
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments;
            if (args is Map) clipboard = args['text']?.toString();
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    ApiClient.setTestInstance(originalApi);
    teardownSecureCredentialStoreForTest();
  });

  Future<void> pump(WidgetTester tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const AccountCenterPage()),
        GoRoute(
          path: '/login',
          name: 'login',
          builder: (_, state) => Scaffold(
            body: Text(
              state.uri.queryParameters['copyOnly'] == 'true'
                  ? 'copy-only-login'
                  : 'hot-and-copy-login',
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> action(WidgetTester tester, String key, String label) async {
    final menu = find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byWidgetPredicate((widget) => widget is PopupMenuButton),
    );
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('lists all HOT/COPY identities using usernames without notes', (
    tester,
  ) async {
    await user.copyAccount.saveSession(_copyA);
    await user.copyAccount.saveSession(_copyB);
    await pump(tester);
    expect(find.text('hot-user'), findsNWidgets(2));
    expect(find.text('second-hot-user'), findsOneWidget);
    expect(find.text('copy-a-user'), findsOneWidget);
    expect(find.text('copy-b-user'), findsNWidgets(2));
    expect(find.text('旧备注不得展示'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.text('添加账号'), findsOneWidget);
    expect(find.text('添加拷贝账号'), findsNothing);
    expect(find.byType(AccountAvatar), findsNWidgets(4));
  });

  testWidgets('global add allows both providers without a naming dialog', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('add-account')));
    await tester.pumpAndSettle();
    expect(find.text('hot-and-copy-login'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('novel-only add remains COPY-only', (tester) async {
    await pump(tester);
    // 轻小说选择区下方有「仅支持拷贝账号」提示。
    expect(
      find.byKey(const ValueKey('novel-account-copy-only-hint')),
      findsOneWidget,
    );
    expect(find.text('轻小说仅支持使用拷贝账号'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('novel-account-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加账号').last);
    await tester.pumpAndSettle();
    expect(find.text('copy-only-login'), findsOneWidget);
  });

  testWidgets(
    'account menu has no switch action; selection belongs to the top',
    (tester) async {
      await pump(tester);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('primary-hotmanga-hot-user')),
          matching: find.byWidgetPredicate(
            (widget) => widget is PopupMenuButton,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('切换账号'), findsNothing);
      for (final label in ['刷新用户', '复制令牌', '退出登录']) {
        expect(find.text(label), findsOneWidget);
      }
    },
  );

  testWidgets('copy uses the clicked inactive HOT/COPY token exactly', (
    tester,
  ) async {
    await user.copyAccount.saveSession(_copyA);
    await user.copyAccount.saveSession(_copyB);
    await pump(tester);
    await action(tester, 'primary-hotmanga-second-hot-user', '复制令牌');
    expect(clipboard, _second.token);
    await action(tester, 'copy-${_copyA.id}', '复制令牌');
    expect(clipboard, _copyA.token);
    expect(user.token, 'hot-token');
    expect(user.copyAccount.token, _copyB.token);
    expect(find.text(_copyA.token), findsNothing);
    expect(find.text(_second.token!), findsNothing);
  });

  testWidgets('refresh inactive HOT changes only its stored profile', (
    tester,
  ) async {
    api.respond = (token, source) async => {
      'user_id': 'second-id',
      'username': 'second-hot-user',
      'nickname': '更新昵称',
      'avatar': '',
    };
    await user.copyAccount.saveSession(_copyA);
    await pump(tester);
    await action(tester, 'primary-hotmanga-second-hot-user', '刷新用户');
    expect(api.requests.single, (token: 'second-token', source: 'hotmanga'));
    expect(
      user.savedCredentials
          .firstWhere((item) => item.username == _second.username)
          .nickname,
      '更新昵称',
    );
    expect(user.token, 'hot-token');
    expect(user.nickname, '热辣主号');
    expect(user.copyAccount.token, _copyA.token);
    expect(find.text('用户信息已刷新'), findsOneWidget);
  });

  testWidgets(
    'COPY refresh reports unavailable without requests or selection changes',
    (tester) async {
      await user.copyAccount.saveSession(_copyA);
      await user.copyAccount.saveSession(_copyB);
      await pump(tester);
      await action(tester, 'copy-${_copyA.id}', '刷新用户');
      expect(api.requests, isEmpty);
      expect(find.text('用户信息已刷新'), findsNothing);
      expect(user.copyAccount.token, _copyB.token);
      expect(user.token, 'hot-token');
    },
  );

  testWidgets('switching saved HOT does not select a novel identity', (
    tester,
  ) async {
    await user.copyAccount.saveSession(_copyA);
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('comic-account-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('second-hot-user').last);
    await tester.pumpAndSettle();
    expect(user.token, _second.token);
    expect(user.copyAccount.token, _copyA.token);
    expect(api.requests, isEmpty);
  });

  testWidgets('top dropdowns select domains independently without a sheet', (
    tester,
  ) async {
    await user.copyAccount.saveSession(_copyA);
    await user.copyAccount.saveSession(_copyB);
    await pump(tester);
    final novel = tester.widget<SelectTile<String>>(
      find.byKey(const ValueKey('novel-account-select')),
    );
    expect(
      novel.items.any((item) => item.value.startsWith('primary-')),
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('comic-account-select')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    // 下拉菜单项在页面内容之后叠加，取 last 命中菜单里的那一项。
    await tester.tap(find.text('copy-a-user').last);
    await tester.pumpAndSettle();
    expect(user.token, _copyA.token);
    expect(user.copyToken, _copyB.token);
    await tester.tap(find.byKey(const ValueKey('novel-account-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('copy-a-user').last);
    await tester.pumpAndSettle();
    expect(user.token, _copyA.token);
    expect(user.copyToken, _copyA.token);
  });

  testWidgets('logout removes only the clicked saved HOT', (tester) async {
    await user.copyAccount.saveSession(_copyA);
    await pump(tester);
    await action(tester, 'primary-hotmanga-second-hot-user', '退出登录');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(
      user.savedCredentials.any((item) => item.sameAccount(_second)),
      isFalse,
    );
    expect(user.token, 'hot-token');
    expect(user.copyAccount.token, _copyA.token);
  });

  test('late refresh cannot resurrect a removed credential', () async {
    final pending = Completer<Map<String, dynamic>>();
    api.respond = (_, _) => pending.future;
    final refreshing = user.refreshCredential(_second);
    await user.removeSavedCredential(_second.username, loginSource: 'hotmanga');
    pending.complete({'user_id': 'second-id', 'username': _second.username});
    expect(await refreshing, isFalse);
    expect(
      user.savedCredentials.any((item) => item.sameAccount(_second)),
      isFalse,
    );
    expect(user.token, 'hot-token');
  });

  test('late refresh cannot overwrite a newly selected primary', () async {
    final pending = Completer<Map<String, dynamic>>();
    api.respond = (_, _) => pending.future;
    final refreshing = user.refreshCredential(user.currentCredential!);
    await user.switchToCredential(_second);
    pending.complete({
      'user_id': 'hot-id',
      'username': 'hot-user',
      'nickname': '旧响应',
    });
    expect(await refreshing, isFalse);
    expect(user.token, _second.token);
    expect(user.nickname, _second.nickname);
  });

  test(
    'migration failure retains legacy secrets and the loaded account',
    () async {
      final legacyCredentials = jsonEncode([_second.toJson()]);
      SharedPreferences.setMockInitialValues({
        'user_token': 'legacy-token',
        'user_username': 'legacy-user',
        'saved_credentials': legacyCredentials,
        'saved_username': 'legacy-user',
        'saved_password': 'legacy-password',
      });
      SecureCredentialStore.setInstance(_FailingSecureStore());
      await user.init();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('user_token'), 'legacy-token');
      expect(prefs.getString('saved_credentials'), legacyCredentials);
      expect(prefs.getString('saved_password'), 'legacy-password');
      expect(user.token, 'legacy-token');
    },
  );

  test(
    'logout tombstone prevents stale legacy credentials from returning',
    () async {
      await user.logout();
      await user.removeSavedCredential('hot-user', loginSource: 'hotmanga');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_token', 'stale-token');
      await prefs.setString(
        'saved_credentials',
        jsonEncode([
          {
            'username': 'removed-user',
            'password': '',
            'token': 'removed-token',
          },
        ]),
      );
      await user.init();
      expect(user.token, isNull);
      expect(
        user.savedCredentials.any((item) => item.username == 'removed-user'),
        isFalse,
      );
    },
  );

  test(
    'same username from both providers survives secure persistence and removal',
    () async {
      await user.setLoginSource('copy');
      await user.saveCredentials('hot-user', 'copy-password');
      await user.saveLogin(
        token: 'same-name-copy-token',
        userId: 'copy-id',
        username: 'hot-user',
        nickname: 'COPY',
        avatar: '',
        syncCopyAccount: true,
      );
      final saved = await SecureCredentialStore().readCredentials();
      expect(saved.where((item) => item.username == 'hot-user'), hasLength(2));
      final prefs = await SharedPreferences.getInstance();
      for (final key in [
        'user_token',
        'saved_credentials',
        'saved_password',
        'saved_username',
      ]) {
        expect(prefs.containsKey(key), isFalse);
      }
      await user.init();
      expect(
        user.savedCredentials.where((item) => item.username == 'hot-user'),
        hasLength(2),
      );
      await user.removeSavedCredential('hot-user', loginSource: 'copy');
      expect(
        user.savedCredentials
            .singleWhere((item) => item.username == 'hot-user')
            .token,
        'hot-token',
      );
    },
  );
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/login_page.dart';
import 'package:kira/widgets/login_node_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 登录页内置节点状态卡，测试中必须替换探测函数避免真实网络请求。
  setUp(() {
    setupSecureCredentialStoreForTest();
    LoginNodeStatusCard.probeOverride = (hosts, {onHostResult}) async {
      final results = <String, int?>{for (final host in hosts) host: 120};
      for (final entry in results.entries) {
        onHostResult?.call(entry.key, entry.value);
      }
      return results;
    };
    LoginNodeStatusCard.hotHostOverride = () => 'hot-login.test';
  });

  tearDown(() {
    LoginNodeStatusCard.probeOverride = null;
    LoginNodeStatusCard.hotHostOverride = null;
    teardownSecureCredentialStoreForTest();
  });

  Future<void> pumpLogin(WidgetTester tester) async {
    await tester.pumpWidget(
      wrapWithApp(const LoginPage(), wrapInScaffold: false),
    );
    await tester.pumpAndSettle();
  }

  void expectHotCredentials(
    WidgetTester tester, {
    String username = 'hot_user',
    String password = 'hot_password',
    bool remembered = true,
  }) {
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields, hasLength(2));
    expect(fields[0].controller!.text, username);
    expect(fields[1].controller!.text, password);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      remembered,
    );
  }

  void expectCopyEntryOnly() {
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text('hot_user'), findsNothing);
    expect(find.text('copy_user'), findsNothing);
    expect(find.text('官网登录'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '登录'), findsNothing);
    expect(find.byIcon(Icons.key), findsOneWidget);
    expect(
      find.byKey(const ValueKey('official-register-hotmanga')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('official-register-copy')), findsNothing);
  }

  testWidgets('switching to COPY removes the password form and restores HOT', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'login_source': 'hotmanga',
      'saved_username': 'hot_user',
      'saved_password': 'hot_password',
      'saved_credentials': jsonEncode([
        {
          'username': 'hot_user',
          'password': 'hot_password',
          'login_source': 'hotmanga',
        },
        {
          'username': 'copy_user',
          'password': 'copy_password',
          'login_source': 'copy',
        },
      ]),
    });
    await UserManager().init();
    await pumpLogin(tester);

    expectHotCredentials(tester);
    expect(find.text('copy_user'), findsNothing);
    expect(
      find.byKey(const ValueKey('official-register-hotmanga')),
      findsOneWidget,
    );
    expect(find.text('官网登录'), findsNothing);

    await tester.tap(find.text('拷贝漫画'));
    await tester.pumpAndSettle();

    expect(find.byType(SegmentedButton<bool>), findsOneWidget);
    expectCopyEntryOnly();

    await tester.tap(find.text('热辣漫画'));
    await tester.pumpAndSettle();

    expectHotCredentials(tester);
    expect(find.text('copy_user'), findsNothing);
    expect(
      find.byKey(const ValueKey('official-register-hotmanga')),
      findsOneWidget,
    );
    expect(find.text('官网登录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final hasSavedHot in [false, true]) {
    testWidgets(
      'legacy COPY credentials never prefill HOT with saved HOT=$hasSavedHot',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'login_source': 'copy',
          'saved_username': 'copy_user',
          'saved_password': 'copy_password',
          'saved_credentials': jsonEncode([
            // Legacy entries have no explicit source; init must attribute
            // this active saved name to COPY rather than exposing it on HOT.
            {'username': 'copy_user', 'password': 'copy_password'},
            if (hasSavedHot)
              {
                'username': 'hot_user',
                'password': 'hot_password',
                'login_source': 'hotmanga',
              },
          ]),
        });
        await UserManager().init();
        await pumpLogin(tester);

        expectCopyEntryOnly();
        await tester.tap(find.text('热辣漫画'));
        await tester.pumpAndSettle();

        expectHotCredentials(
          tester,
          username: hasSavedHot ? 'hot_user' : '',
          password: hasSavedHot ? 'hot_password' : '',
          remembered: hasSavedHot,
        );
        expect(find.text('copy_user'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('HOT initialization ignores an explicitly saved COPY password', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'login_source': 'hotmanga',
      'saved_username': 'copy_user',
      'saved_password': 'copy_password',
      'saved_credentials': jsonEncode([
        {
          'username': 'copy_user',
          'password': 'copy_password',
          'login_source': 'copy',
        },
        {
          'username': 'hot_user',
          'password': 'hot_password',
          'login_source': 'hotmanga',
        },
      ]),
    });
    await UserManager().init();
    await pumpLogin(tester);

    expectHotCredentials(tester);
    expect(find.text('copy_user'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('token login opens from the top-right action', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await UserManager().init();
    await pumpLogin(tester);

    expect(find.text('令牌 (Token)'), findsNothing);

    await tester.tap(find.byIcon(Icons.key));
    await tester.pumpAndSettle();

    expect(find.text('令牌登录'), findsOneWidget);
    expect(find.text('令牌 (Token)'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('令牌 (Token)'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

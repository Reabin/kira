import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/login_page.dart';
import 'package:kira/utils/copy_signature.dart';
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

  /// 拷贝模式的公共形态：账号密码表单 + 登录按钮，没有「记住账号」，
  /// 也不显示热辣的注册入口。签名密钥未配置时只有网页登录，通道选择器不展示。
  /// 已保存的拷贝账号会回填进表单并出现在下方列表里，热辣账号不出现。
  void expectCopyForm(WidgetTester tester, {String username = 'copy_user'}) {
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text('hot_user'), findsNothing);
    expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
    expect(find.byIcon(Icons.key), findsOneWidget);
    expect(find.text('接口登录'), findsNothing);
    expect(
      find.byKey(const ValueKey('official-register-hotmanga')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('official-register-copy')), findsNothing);
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields[0].controller!.text, username);
  }

  testWidgets('switching to COPY swaps the form and restores HOT', (
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

    await tester.tap(find.text('拷贝漫画'));
    await tester.pumpAndSettle();

    expect(find.byType(SegmentedButton<bool>), findsOneWidget);
    expectCopyForm(tester);

    await tester.tap(find.text('热辣漫画'));
    await tester.pumpAndSettle();

    expectHotCredentials(tester);
    expect(find.text('copy_user'), findsNothing);
    expect(
      find.byKey(const ValueKey('official-register-hotmanga')),
      findsOneWidget,
    );
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

        expectCopyForm(tester);
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

  group('COPY 接口登录入口', () {
    setUp(() {
      // 测试用固定串,与真实协议常量无关:只为验证「即便密钥就绪,入口仍因
      // 功能开关关闭而不展示」。
      CopySignature.debugKeyOverride =
          '00000000000000000000000000000000';
    });

    tearDown(() => CopySignature.debugKeyOverride = null);

    testWidgets('接口登录暂时隐藏:即使配置了签名密钥也不展示通道入口', (tester) async {
      SharedPreferences.setMockInitialValues({'login_source': 'copy'});
      await UserManager().init();
      await pumpLogin(tester);

      expect(find.text('网页登录'), findsNothing);
      expect(find.text('接口登录'), findsNothing);
      // 入口隐藏后仍走网页登录,节点卡固定展示官网域名。
      final card = tester.widget<LoginNodeStatusCard>(
        find.byType(LoginNodeStatusCard),
      );
      expect(card.copyChannel, CopyLoginChannel.web);
      expect(tester.takeException(), isNull);
    });
  });
}

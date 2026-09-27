import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/copy_account_store.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/about_page.dart' show AboutPage;
import 'package:kira/pages/profile_page.dart';
import 'package:kira/utils/app_update.dart';
import 'package:kira/utils/remote_notice_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

Widget _buildTestApp(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  Future<void> pumpProfilePage(WidgetTester tester) async {
    RemoteNoticeService.unreadActiveCount.value = 0;
    SharedPreferences.setMockInitialValues({
      'user_token': 'current-token',
      'user_user_id': '1',
      'user_username': 'alice',
      'user_nickname': 'Alice',
      'user_avatar': '',
      'saved_username': 'alice',
      'saved_password': 'alice-pass',
      'saved_credentials': jsonEncode([
        {
          'username': 'alice',
          'password': 'alice-pass',
          'token': 'current-token',
          'user_id': '1',
          'nickname': 'Alice',
          'avatar': '',
        },
        {
          'username': 'bob',
          'password': 'bob-pass',
          'token': 'bob-token',
          'user_id': '2',
          'nickname': 'Bob',
          'avatar': '',
        },
      ]),
    });
    await UserManager().init();

    await tester.pumpWidget(_buildTestApp(const ProfilePage()));
    await tester.pumpAndSettle();
  }

  testWidgets('account entry keeps its settings icon and current username', (
    tester,
  ) async {
    await pumpProfilePage(tester);
    final tile = tester.widget<ListTile>(
      find.byKey(const ValueKey('profile-account-entry')),
    );
    expect(find.byIcon(Icons.manage_accounts_rounded), findsOneWidget);
    expect(find.byType(CircleAvatar), findsNothing);
    expect(tile.subtitle, isNull);
    expect(tile.trailing, isNull);
    expect(tile.onTap, isNotNull);
    expect(find.text('账号中心'), findsNothing);
    expect(find.text('Alice'), findsNothing);
    expect(find.text('alice'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('alice')).dy,
      lessThan(tester.getTopLeft(find.text('通用')).dy),
    );
  });

  testWidgets('manual novel selection does not replace the profile identity', (
    tester,
  ) async {
    await pumpProfilePage(tester);
    await UserManager().copyAccount.saveSession(
      const CopyAccountSession(
        token: 'independent-copy-token',
        userId: 'copy-id',
        username: 'copy-user',
        avatar: 'user/cover/copy.png',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.manage_accounts_rounded), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('copy-user'), findsNothing);
    await UserManager().logout();
    await tester.pumpAndSettle();
    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('copy-user'), findsNothing);
  });

  testWidgets('profile page shows general settings entry', (tester) async {
    await pumpProfilePage(tester);

    expect(find.text('通用'), findsOneWidget);
  });

  testWidgets('notice center follows AI configuration and keeps its red dot', (
    tester,
  ) async {
    // 单列分组：通用/网络 → 下载 → AI/通知/关于。
    // 显式使用600逻辑宽，避免默认800宽触发双列布局。
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(600 * 3, 1000 * 3);
    addTearDown(tester.view.reset);

    await pumpProfilePage(tester);

    expect(
      MediaQuery.sizeOf(tester.element(find.byType(ProfilePage))).width,
      600,
    );
    final networkTop = tester.getTopLeft(find.byIcon(Icons.dns_rounded)).dy;
    final aiTop = tester.getTopLeft(find.text('AI配置')).dy;
    final noticeTop = tester.getTopLeft(find.text('通知中心')).dy;
    final downloadTop = tester.getTopLeft(find.text('下载中心')).dy;

    expect(downloadTop, greaterThan(networkTop));
    expect(downloadTop, lessThan(aiTop));
    expect(noticeTop, greaterThan(aiTop));
    expect(noticeTop, lessThan(tester.getTopLeft(find.text('关于')).dy));
  });

  testWidgets('notice red dot uses notice icon color', (tester) async {
    await pumpProfilePage(tester);

    RemoteNoticeService.unreadActiveCount.value = 1;
    await tester.pump();

    expect(
      find.byWidgetPredicate((widget) {
        final decoration = widget is Container ? widget.decoration : null;
        return widget is Container &&
            decoration is BoxDecoration &&
            decoration.color == const Color(0xFFEB6F92);
      }),
      findsOneWidget,
    );
  });

  testWidgets('about page shows error log entry', (tester) async {
    SharedPreferences.setMockInitialValues({'app_logging_enabled': true});
    PackageInfo.setMockInitialValues(
      appName: 'Kira',
      packageName: 'com.example.kira',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    await UserManager().init();
    // This test only checks the log entry. Suppress AboutPage's automatic
    // network update check without running a real HTTP client.
    final previousUpdateState = AppUpdateService.state.value;
    AppUpdateService.state.value = const AppUpdateState.checking();
    addTearDown(() => AppUpdateService.state.value = previousUpdateState);

    await tester.pumpWidget(_buildTestApp(const AboutPage()));
    // AboutPage 的更新检查指示器常驻动画会让 pumpAndSettle 永不结束，
    // 用固定 pump 等首帧与异步初始化完成。
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('日志'), findsOneWidget);
    expect(find.byIcon(Icons.bug_report_outlined), findsOneWidget);
  });
}

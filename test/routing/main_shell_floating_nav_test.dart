import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_nav_bar/google_nav_bar.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/routing/main_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

/// 悬浮底栏与页面内容/悬浮按钮的关系。
///
/// 页面自己的 Scaffold 用 `viewPadding` 定位 FAB，而 `Scaffold.extendBody`
/// 只把底栏高度写进 `MediaQuery.padding`（只影响可滚动内容）。因此 shell 必须
/// 把底栏高度同时补进 `viewPadding`，否则首页右下角的源切换按钮会被底栏压住。
/// 同时底栏两侧必须是页面内容（真悬浮），不能是 Scaffold 背景色。
Future<GoRouter> _pumpShell(
  WidgetTester tester, {
  required bool floating,
}) async {
  SharedPreferences.setMockInitialValues({
    'disclaimer_accepted': true,
    'auto_check_update': false,
    'remote_notice_enabled': false,
    'app_logging_enabled': false,
    'nav_floating_enabled': floating,
    'bottom_nav_label_mode': 'selectedOnly',
  });
  setupSecureCredentialStoreForTest();
  addTearDown(teardownSecureCredentialStoreForTest);
  await UserManager().init();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 900);
  addTearDown(tester.view.reset);

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      StatefulShellRoute(
        navigatorContainerBuilder: buildMainShellNavigatorContainer,
        builder: (_, _, shell) => MainShell(navigationShell: shell),
        branches: [
          StatefulShellBranch(
            preload: true,
            routes: [
              GoRoute(
                path: '/',
                builder: (_, _) => Scaffold(
                  // 模拟首页：右下角有一个源切换悬浮按钮。
                  floatingActionButton: const FloatingActionButton(
                    onPressed: null,
                    child: Icon(Icons.swap_horiz),
                  ),
                  body: ListView(
                    children: [
                      for (var i = 0; i < 40; i++)
                        SizedBox(height: 60, child: Text('行 $i')),
                    ],
                  ),
                ),
              ),
            ],
          ),
          for (final path in ['/b', '/c', '/d'])
            StatefulShellBranch(
              preload: true,
              routes: [
                GoRoute(
                  path: path,
                  builder: (_, _) =>
                      const Scaffold(body: Center(child: Text('x'))),
                ),
              ],
            ),
        ],
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await tester.pump(const Duration(seconds: 2));
  });

  await tester.pumpWidget(
    MaterialApp.router(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return router;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('悬浮底栏不遮挡页面右下角的悬浮按钮', (tester) async {
    await _pumpShell(tester, floating: true);
    final fab = tester.getRect(find.byType(FloatingActionButton));
    final bar = tester.getRect(find.byType(GNav));
    expect(fab.overlaps(bar), isFalse, reason: 'FAB=$fab 与底栏 $bar 重叠');
    expect(bar.top - fab.bottom, greaterThan(0));
  });

  testWidgets('悬浮模式让页面内容延伸到栏下（extendBody），固定模式不让位', (tester) async {
    await _pumpShell(tester, floating: true);
    // 不开 extendBody 时底栏四周露出 Scaffold 背景色，悬浮观感变成「矩形套胶囊」。
    final shellScaffold = tester.widget<Scaffold>(
      find
          .ancestor(of: find.byType(GNav), matching: find.byType(Scaffold))
          .last,
    );
    expect(shellScaffold.extendBody, isTrue);
  });

  testWidgets('固定底栏同样不遮挡页面悬浮按钮', (tester) async {
    await _pumpShell(tester, floating: false);
    final fab = tester.getRect(find.byType(FloatingActionButton));
    final bar = tester.getRect(find.byType(GNav));
    expect(fab.overlaps(bar), isFalse);
  });

  testWidgets('非悬浮经典底栏开启悬浮后即时切回胶囊', (tester) async {
    await _pumpShell(tester, floating: false);
    final user = UserManager();
    await user.setBottomNavLabelMode(BottomNavLabelMode.always);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(GNav), findsNothing);

    await user.theme.setFloatingNavEnabled(true);
    await tester.pumpAndSettle();
    expect(user.bottomNavLabelMode, BottomNavLabelMode.selectedOnly);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(GNav), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('悬浮底栏始终可见：滚动不改变 FAB 位置', (tester) async {
    await _pumpShell(tester, floating: true);
    final screenHeight = tester.view.physicalSize.height;
    final fab = tester.getRect(find.byType(FloatingActionButton));
    expect(
      screenHeight - fab.bottom,
      greaterThan(40),
      reason: 'FAB 应始终被抬到底栏上方',
    );

    await tester.timedDrag(
      find.byType(ListView),
      const Offset(0, -260),
      const Duration(milliseconds: 300),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(GNav).hitTestable(), findsOneWidget, reason: '底栏始终可见');
    expect(
      tester.getRect(find.byType(FloatingActionButton)).bottom,
      closeTo(fab.bottom, 1),
      reason: '滚动不改变 FAB 位置',
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_nav_bar/google_nav_bar.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/profile_page.dart';
import 'package:kira/routing/main_shell.dart';
import 'package:kira/utils/remote_notice_service.dart';
import 'package:kira/widgets/branch_bottom_slack.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

/// 分支页末尾的 [BranchBottomSlack] 要正好让开悬浮底栏。
///
/// 悬浮模式外层 Scaffold 开着 `extendBody`，底栏浮在内容之上；而
/// `CustomScrollView` 不会像 `ListView` 那样自动消费 `MediaQuery.padding.bottom`，
/// 页面各自的硬编码留白（72/88 之类）只够让开右下角的悬浮按钮，底栏一浮起来
/// 就盖住列表末尾。这里验证补上底栏高度后，最后一项能完整滚到底栏上方。
class _SliverPage extends StatelessWidget {
  const _SliverPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 1200)),
          SliverToBoxAdapter(
            child: Container(
              key: const Key('last-item'),
              height: 60,
              color: Colors.green,
              child: const Center(child: Text('最后一项')),
            ),
          ),
          // 各分支页原有的硬编码留白（这里以 72 为代表）。
          const SliverToBoxAdapter(child: BranchBottomSlack(extra: 72)),
        ],
      ),
    );
  }
}

class _BlankPage extends StatelessWidget {
  const _BlankPage();

  @override
  Widget build(BuildContext context) => const Scaffold();
}

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
              GoRoute(path: '/', builder: (_, _) => const _SliverPage()),
            ],
          ),
          for (final path in ['/b', '/c', '/d', '/e'])
            StatefulShellBranch(
              preload: true,
              routes: [
                GoRoute(path: path, builder: (_, _) => const _BlankPage()),
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

Future<void> _scrollToBottom(WidgetTester tester) async {
  final scrollable = find.descendant(
    of: find.byType(_SliverPage),
    matching: find.byType(Scrollable),
  );
  final state = tester.state<ScrollableState>(scrollable.first);
  state.position.jumpTo(state.position.maxScrollExtent);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _profileRegression();

  testWidgets('悬浮底栏：滚到底部后最后一项完整露在底栏上方', (tester) async {
    await _pumpShell(tester, floating: true);
    await _scrollToBottom(tester);

    final item = tester.getRect(find.byKey(const Key('last-item')));
    final bar = tester.getRect(find.byType(GNav));
    expect(
      bar.top - item.bottom,
      greaterThanOrEqualTo(0),
      reason: '最后一项 $item 被底栏 $bar 遮挡',
    );
  });

  testWidgets('固定底栏：内容不额外补底栏高度，也不被遮挡', (tester) async {
    await _pumpShell(tester, floating: false);
    await _scrollToBottom(tester);

    final item = tester.getRect(find.byKey(const Key('last-item')));
    final bar = tester.getRect(find.byType(GNav));
    expect(
      bar.top - item.bottom,
      greaterThanOrEqualTo(0),
      reason: '最后一项 $item 被底栏 $bar 遮挡',
    );
  });

  testWidgets('悬浮底栏：滚到底后留白正好是底栏高度，不多不少', (tester) async {
    await _pumpShell(tester, floating: true);
    await _scrollToBottom(tester);

    final item = tester.getRect(find.byKey(const Key('last-item')));
    final bar = tester.getRect(find.byType(GNav));
    // 留白 = 底栏高度 + extra(72)：最后一项与底栏之间的空隙只该由 extra 提供。
    expect(bar.top - item.bottom, lessThan(140));
  });
}

/// 真实「我的」页在矮屏上的回归：最底下的「关于」曾整体被悬浮底栏盖住。
void _profileRegression() {
  setUp(() async {
    RemoteNoticeService.unreadActiveCount.value = 0;
    SharedPreferences.setMockInitialValues({
      'disclaimer_accepted': true,
      'auto_check_update': false,
      'remote_notice_enabled': false,
      'app_logging_enabled': false,
      'nav_floating_enabled': true,
      'bottom_nav_label_mode': 'selectedOnly',
      'user_token': 'current-token',
      'user_user_id': '1',
      'user_username': 'alice',
      'user_nickname': 'Alice',
      'user_avatar': '',
      'saved_credentials': '[]',
    });
    setupSecureCredentialStoreForTest();
    await UserManager().init();
  });

  tearDown(teardownSecureCredentialStoreForTest);

  testWidgets('矮屏滚到底部：「关于」卡片完整露在悬浮底栏上方', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 560);
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/profile',
      routes: [
        StatefulShellRoute(
          navigatorContainerBuilder: buildMainShellNavigatorContainer,
          builder: (_, _, shell) => MainShell(navigationShell: shell),
          branches: [
            for (final path in ['/', '/search', '/bookshelf', '/novels'])
              StatefulShellBranch(
                preload: true,
                routes: [
                  GoRoute(path: path, builder: (_, _) => const _BlankPage()),
                ],
              ),
            StatefulShellBranch(
              preload: true,
              routes: [
                GoRoute(
                  path: '/profile',
                  builder: (_, _) => const ProfilePage(),
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
    await tester.pumpAndSettle();
    // 推完分支预热链路，避免测试结束时留下待处理的定时器。
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    final scrollable = find.descendant(
      of: find.byType(ProfilePage),
      matching: find.byType(Scrollable),
    );
    final state = tester.state<ScrollableState>(scrollable.first);
    state.position.jumpTo(state.position.maxScrollExtent);
    await tester.pumpAndSettle();

    final tile = tester.getRect(find.text('关于'));
    final bar = tester.getRect(find.byType(GNav));
    expect(
      bar.top - tile.bottom,
      greaterThanOrEqualTo(0),
      reason: '「关于」$tile 被底栏 $bar 遮挡',
    );
  });
}

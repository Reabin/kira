import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_nav_bar/google_nav_bar.dart';
import 'package:kira/api/novel/novel_api.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/novel_home_page.dart';
import 'package:kira/pages/search_page.dart';
import 'package:kira/providers/novel_providers.dart';
import 'package:kira/routing/dismiss_keyboard_observer.dart';
import 'package:kira/routing/main_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pages/search_page_test_support.dart';
import '../test_helpers.dart';

const _comicMarker = '主导航-漫画';
const _bookshelfMarker = '主导航-书架';
const _profileMarker = '主导航-我的';
const _detailMarker = '根层占位详情';

enum _SearchEntry {
  comic('漫画搜索', '/search', 1, SearchPage, Icons.search),
  novel('轻小说搜索', '/novels', 4, NovelHomePage, Icons.auto_stories);

  const _SearchEntry(
    this.label,
    this.path,
    this.branch,
    this.pageType,
    this.icon,
  );

  final String label;
  final String path;
  final int branch;
  final Type pageType;
  final IconData icon;
}

/// 不构造 NovelApi/ApiClient 的真实 transport，也不访问图片或业务网络。
class _MemoryNovelApi extends Fake implements NovelApi {
  final searches = <String>[];

  @override
  Future<List<NovelTag>> getThemes() async => const [
    NovelTag(name: '奇幻', pathWord: 'fantasy'),
  ];

  @override
  Future<NovelPage<NovelBook>> getBooks({
    String theme = '',
    String author = '',
    String ordering = '-popular',
    int limit = 18,
    int offset = 0,
  }) async => NovelPage(
    list: const [NovelBook(pathWord: 'focus-book', name: '隔离小说')],
    total: 1,
    limit: limit,
    offset: offset,
  );

  @override
  Future<NovelPage<NovelBook>> searchBooks({
    required String keyword,
    int limit = 18,
    int offset = 0,
  }) async {
    searches.add(keyword);
    return NovelPage(list: const [], total: 0, limit: limit, offset: offset);
  }
}

class _FocusHarness {
  _FocusHarness(this.entry);

  final _SearchEntry entry;
  final search = SearchTestRig();
  final novel = _MemoryNovelApi();

  // 不调用 main/createAppRouter，避免引入启动服务和真实 API 单例。
  late final router = GoRouter(
    initialLocation: entry.path,
    observers: [DismissKeyboardObserver()],
    routes: [
      StatefulShellRoute(
        navigatorContainerBuilder: buildMainShellNavigatorContainer,
        builder: (_, _, shell) => MainShell(navigationShell: shell),
        // 分支编号与生产一致；可见顺序则是漫画、小说、搜索、书架、我的。
        branches: [
          StatefulShellBranch(
            preload: true,
            routes: [
              GoRoute(
                path: '/',
                builder: (_, _) =>
                    const Scaffold(body: Center(child: Text(_comicMarker))),
              ),
            ],
          ),
          StatefulShellBranch(
            preload: true,
            routes: [GoRoute(path: '/search', builder: (_, _) => search.page)],
          ),
          StatefulShellBranch(
            preload: true,
            routes: [
              GoRoute(
                path: '/bookshelf',
                builder: (_, _) =>
                    const Scaffold(body: Center(child: Text(_bookshelfMarker))),
              ),
            ],
          ),
          StatefulShellBranch(
            preload: true,
            routes: [
              GoRoute(
                path: '/profile',
                builder: (_, _) =>
                    const Scaffold(body: Center(child: Text(_profileMarker))),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/novels',
                builder: (_, _) => const NovelHomePage(),
              ),
            ],
          ),
        ],
      ),
      // Shell 的同级路由：覆盖整个底栏，而非只压入某个分支 Navigator。
      GoRoute(
        path: '/focus-detail',
        builder: (_, _) =>
            const Scaffold(body: Center(child: Text(_detailMarker))),
      ),
    ],
  );
}

Future<_FocusHarness> _pumpShell(
  WidgetTester tester,
  _SearchEntry entry,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 900);
  addTearDown(tester.view.reset);
  final harness = _FocusHarness(entry);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    harness.router.dispose();
    // 即使用例中途失败，也让 MainShell 延迟预热的 mounted 检查结束。
    await tester.pump(const Duration(seconds: 2));
    await pumpSearchFrames(tester);
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [novelApiProvider.overrideWithValue(harness.novel)],
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: harness.router,
      ),
    ),
  );
  await pumpSearchFrames(tester, count: 32);
  expect(find.byType(GNav), findsOneWidget);
  expect(find.byType(NavigationRail), findsNothing);
  expect(
    tester
        .widget<MainShell>(find.byType(MainShell))
        .navigationShell
        .currentIndex,
    entry.branch,
  );
  return harness;
}

Finder _inputFinder(_SearchEntry entry) => find.descendant(
  of: find.byType(entry.pageType),
  matching: find.byType(SearchBar),
);

SearchBar _input(WidgetTester tester, _SearchEntry entry) =>
    tester.widget<SearchBar>(_inputFinder(entry));

/// 必须通过真实点按聚焦；tester.enterText 会主动 showKeyboard，掩盖不可聚焦。
Future<void> _tapAndType(
  WidgetTester tester,
  _SearchEntry entry,
  String text,
) async {
  await tester.tap(
    find.descendant(of: _inputFinder(entry), matching: find.byType(TextField)),
  );
  await pumpSearchFrames(tester, count: 2);
  expect(_input(tester, entry).focusNode!.hasPrimaryFocus, isTrue);
  expect(tester.testTextInput.isVisible, isTrue);
  tester.testTextInput.enterText(text);
  await pumpSearchFrames(tester, count: 2);
  expect(_input(tester, entry).controller!.text, text);
}

void _expectDismissed(
  WidgetTester tester,
  SearchBar input,
  String draft, {
  bool? canRequestFocus,
}) {
  // 不只检查可见树：原输入框必须仍保活，不能通过销毁页面来回避抢焦点。
  expect(
    find.byWidgetPredicate(
      (widget) =>
          widget is SearchBar && identical(widget.focusNode, input.focusNode),
      skipOffstage: false,
    ),
    findsOneWidget,
  );
  expect(input.focusNode!.hasFocus, isFalse);
  expect(tester.testTextInput.isVisible, isFalse);
  expect(input.controller!.text, draft);
  if (canRequestFocus != null) {
    expect(input.focusNode!.canRequestFocus, canRequestFocus);
  }
}

void _expectNoKeyboardShow(WidgetTester tester) {
  // 最终 isVisible=false 不够：往返中也不能短暂重新弹出键盘。
  expect(
    tester.testTextInput.log.where((call) => call.method == 'TextInput.show'),
    isEmpty,
  );
}

void _expectReturned(
  WidgetTester tester,
  _SearchEntry entry,
  SearchBar original,
  String draft,
) {
  expect(_input(tester, entry).focusNode, same(original.focusNode));
  expect(_input(tester, entry).controller, same(original.controller));
  _expectDismissed(tester, original, draft, canRequestFocus: true);
}

Future<void> _rootDetailRoundTrip(
  WidgetTester tester,
  GoRouter router,
  SearchBar input,
  String draft,
) async {
  tester.testTextInput.log.clear();
  // 不点卡片/按钮，不提交搜索、不主动 unfocus：隔离验证根路由观察器，
  // 避免 SearchBar.onTapOutside 或 onSubmitted 提前清除焦点导致假阳性。
  final popped = router.push<void>('/focus-detail');
  await pumpSearchFrames(tester, count: 16);
  expect(find.text(_detailMarker), findsOneWidget);
  expect(find.byType(GNav), findsNothing);
  _expectDismissed(tester, input, draft);

  router.pop();
  await pumpSearchFrames(tester, count: 16);
  await popped;
  expect(find.text(_detailMarker), findsNothing);
  expect(find.byType(GNav), findsOneWidget);
  _expectDismissed(tester, input, draft);
  _expectNoKeyboardShow(tester);
}

Future<void> _tapNav(WidgetTester tester, IconData icon) async {
  tester.testTextInput.log.clear();
  await tester.tap(
    find.descendant(
      of: find.byType(GNav),
      matching: find.byWidgetPredicate(
        (widget) => widget is GButton && widget.icon == icon,
      ),
    ),
  );
  await pumpSearchFrames(tester);
  _expectNoKeyboardShow(tester);
}

Future<void> _swipe(WidgetTester tester, Finder content, Offset offset) async {
  tester.testTextInput.log.clear();
  await tester.timedDrag(content, offset, const Duration(milliseconds: 300));
  await pumpSearchFrames(tester);
  _expectNoKeyboardShow(tester);
}

void _expectNoSubmissions(_FocusHarness harness) {
  expect(harness.search.manga.searches, isEmpty);
  expect(harness.novel.searches, isEmpty);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(installSearchImageCache);
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'disclaimer_accepted': true,
      'auto_check_update': false,
      'remote_notice_enabled': false,
      'app_logging_enabled': false,
      'nav_swipe_enabled': true,
      'search_tab_index': 0,
      'bottom_nav_label_mode': 'selectedOnly',
      'nav_show_novel': true,
      'discover_source': 'hot',
    });
    setupSecureCredentialStoreForTest();
    await UserManager().init();
  });
  tearDown(teardownSecureCredentialStoreForTest);

  for (final entry in _SearchEntry.values) {
    testWidgets('${entry.label}清空后仍能直接继续输入', (tester) async {
      final harness = await _pumpShell(tester, entry);
      await _tapAndType(tester, entry, '待清空关键词');
      await tester.tap(
        find.descendant(
          of: _inputFinder(entry),
          matching: find.byIcon(Icons.clear),
        ),
      );
      await pumpSearchFrames(tester);
      expect(_input(tester, entry).controller!.text, isEmpty);
      expect(_input(tester, entry).focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      tester.testTextInput.enterText('继续输入');
      await pumpSearchFrames(tester, count: 2);
      expect(_input(tester, entry).controller!.text, '继续输入');
      _expectNoSubmissions(harness);
    });

    testWidgets('${entry.label}经外部路由切分支后不恢复隐藏输入焦点', (tester) async {
      final harness = await _pumpShell(tester, entry);
      final original = _input(tester, entry);
      const draft = '外部切页草稿';
      await _tapAndType(tester, entry, draft);
      tester.testTextInput.log.clear();
      harness.router.go('/profile');
      await pumpSearchFrames(tester, count: 16);
      _expectDismissed(tester, original, draft, canRequestFocus: false);
      harness.router.go(entry.path);
      await pumpSearchFrames(tester, count: 16);
      _expectReturned(tester, entry, original, draft);
      _expectNoKeyboardShow(tester);
      await _rootDetailRoundTrip(tester, harness.router, original, draft);
      await _tapAndType(tester, entry, '$draft继续输入');
      _expectNoSubmissions(harness);
    });

    testWidgets('${entry.label}未提交时根层详情往返不恢复键盘，重点击仍可输入', (tester) async {
      final harness = await _pumpShell(tester, entry);
      final original = _input(tester, entry);
      final draft = '${entry.label}未提交草稿';
      await _tapAndType(tester, entry, draft);

      await _rootDetailRoundTrip(tester, harness.router, original, draft);
      _expectReturned(tester, entry, original, draft);
      await _tapAndType(tester, entry, '$draft继续输入');
      _expectNoSubmissions(harness);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${entry.label}经 GNav 或横滑隐藏后详情往返不抢焦点，切回保留草稿', (tester) async {
      final harness = await _pumpShell(tester, entry);
      final original = _input(tester, entry);
      final draft = '${entry.label}底栏草稿';
      await _tapAndType(tester, entry, draft);

      await _tapNav(tester, Icons.person);
      expect(find.text(_profileMarker), findsOneWidget);
      _expectDismissed(tester, original, draft, canRequestFocus: false);
      await _rootDetailRoundTrip(tester, harness.router, original, draft);
      expect(find.text(_profileMarker), findsOneWidget);
      _expectDismissed(tester, original, draft, canRequestFocus: false);
      await _tapNav(tester, entry.icon);
      _expectReturned(tester, entry, original, draft);

      final swipeDraft = '$draft横滑前再输入';
      await _tapAndType(tester, entry, swipeDraft);
      // 使用普通内容区，不能用 TabBar/筛选横向滚动行代替主导航手势。
      // 默认可见序：搜索向左到书架；小说向右到漫画。
      final offset = entry == _SearchEntry.comic
          ? const Offset(-280, 0)
          : const Offset(280, 0);
      final destination = entry == _SearchEntry.comic
          ? _bookshelfMarker
          : _comicMarker;
      await _swipe(
        tester,
        find.descendant(
          of: find.byType(entry.pageType),
          matching: find.byType(CustomScrollView),
        ),
        offset,
      );
      expect(find.text(destination), findsOneWidget);
      _expectDismissed(tester, original, swipeDraft, canRequestFocus: false);
      await _rootDetailRoundTrip(tester, harness.router, original, swipeDraft);
      expect(find.text(destination), findsOneWidget);
      _expectDismissed(tester, original, swipeDraft, canRequestFocus: false);
      await _swipe(tester, find.text(destination), -offset);
      _expectReturned(tester, entry, original, swipeDraft);
      await _tapAndType(tester, entry, '$swipeDraft继续输入');
      _expectNoSubmissions(harness);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('漫画搜索切发现并往返根层详情后不恢复焦点，切回搜索可手动继续输入', (tester) async {
    const entry = _SearchEntry.comic;
    final harness = await _pumpShell(tester, entry);
    final original = _input(tester, entry);
    const draft = '漫画内部标签草稿';
    await _tapAndType(tester, entry, draft);

    tester.testTextInput.log.clear();
    await tapSearchTab(tester, '发现');
    expect(harness.search.manga.listings, hasLength(1));
    harness.search.manga.listings.single.succeed(['隔离发现漫画']);
    await pumpSearchFrames(tester);
    expect(UserManager().searchTabIndex, 1);
    expect(find.text('隔离发现漫画'), findsOneWidget);
    _expectDismissed(tester, original, draft, canRequestFocus: false);
    _expectNoKeyboardShow(tester);

    await _rootDetailRoundTrip(tester, harness.router, original, draft);
    expect(find.text('隔离发现漫画'), findsOneWidget);
    tester.testTextInput.log.clear();
    await tapSearchTab(tester, '搜索');
    expect(UserManager().searchTabIndex, 0);
    _expectReturned(tester, entry, original, draft);
    _expectNoKeyboardShow(tester);
    await _tapAndType(tester, entry, '$draft继续输入');
    _expectNoSubmissions(harness);
    expect(tester.takeException(), isNull);
  });
}

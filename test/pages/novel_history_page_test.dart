import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kira/api/novel/novel_api.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/models/novel_reading_progress.dart';
import 'package:kira/models/theme_settings.dart';
import 'package:kira/pages/browse_history_page.dart';
import 'package:kira/pages/novel_history_page.dart';
import 'package:kira/providers/app_providers.dart';
import 'package:kira/providers/novel_providers.dart';
import 'package:kira/providers/settings_providers.dart';
import 'package:kira/routing/app_router.dart';
import 'package:kira/theme/app_icon_sizes.dart';
import 'package:kira/utils/novel_reading_store.dart';
import 'package:kira/utils/reading_history.dart';
import 'package:kira/utils/time_format.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../novel_api_test.dart' show NovelTestUser;
import '../test_helpers.dart';

class _User extends NovelTestUser {
  @override
  bool get isCopyLoggedIn => copyToken?.isNotEmpty == true;
}

NovelBrowseEntry _onlineEntry(String name, {String chapter = '远端第一卷'}) =>
    NovelBrowseEntry(
      book: NovelBook(
        pathWord: name,
        name: name,
        lastChapterId: 'latest',
        lastChapterName: '最新一卷',
      ),
      lastChapterId: 'remote-volume',
      lastChapterName: chapter,
    );

NovelPage<NovelBrowseEntry> _page(
  List<NovelBrowseEntry> items, {
  int offset = 0,
  int? total,
}) => NovelPage(
  list: items,
  offset: offset,
  total: total ?? offset + items.length,
  limit: 18,
);

class _Api implements NovelApi {
  _Api(this.user);
  final _User user;
  final calls = <(String, int)>[];
  int clearCalls = 0;
  Future<NovelPage<NovelBrowseEntry>> Function(String scope, int offset)?
  respond;
  Object? clearError;

  @override
  String get cacheScope => '${user.copyApiHost}:${user.copyToken ?? 'guest'}';

  @override
  Future<NovelPage<NovelBrowseEntry>> getBrowseHistory({
    int limit = 18,
    int offset = 0,
  }) {
    calls.add((cacheScope, offset));
    return respond?.call(cacheScope, offset) ??
        Future.value(_page([_onlineEntry('线上小说')]));
  }

  @override
  Future<void> clearBrowseHistory() async {
    ++clearCalls;
    final error = clearError;
    if (error != null) throw error;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected API call: $invocation');
}

NovelReadingProgress _position({
  String pathWord = 'book',
  String name = '本机小说',
  String volume = 'volume-1',
  String chapter = '本机章节',
  int entry = 1,
}) => NovelReadingProgress(
  pathWord: pathWord,
  name: name,
  cover: '',
  volumeId: volume,
  volumeName: '本机第一卷',
  chapterName: chapter,
  entryIndex: entry,
  paragraphIndex: 12,
  paragraphAlignment: -0.3,
  progress: 0.25,
  updatedAt: DateTime.utc(2026, 10, 23),
);

class _Store extends NovelReadingStore {
  List<NovelReadingProgress> items = [_position()];
  final recentLimits = <int?>[];
  int removeCalls = 0;
  int clearCalls = 0;
  Object? removeError;
  Completer<void>? recentGate;

  @override
  Future<List<NovelReadingProgress>> readRecent({int? limit = 30}) async {
    recentLimits.add(limit);
    await recentGate?.future;
    return (limit == null ? items : items.take(limit)).toList();
  }

  @override
  Future<NovelReadingProgress?> readProgress(String pathWord) async =>
      items.where((item) => item.pathWord == pathWord).firstOrNull;

  @override
  Future<void> removeProgress(String pathWord) async {
    ++removeCalls;
    final error = removeError;
    if (error != null) throw error;
    items.removeWhere((item) => item.pathWord == pathWord);
    NovelReadingStore.notifyChanged();
  }

  @override
  Future<void> clear() async {
    ++clearCalls;
    final error = removeError;
    if (error != null) throw error;
    items.clear();
    NovelReadingStore.notifyChanged();
  }
}

class _Harness {
  _Harness() {
    addTearDown(user.dispose);
  }
  final user = _User()..copyToken = 'account-a';
  late final api = _Api(user);
  final store = _Store();
  GoRouter? router;

  Future<void> mount(
    WidgetTester tester, {
    bool combined = true,
    bool novelTab = true,
    bool settle = true,
    bool dark = false,
  }) async {
    final nextRouter = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => combined
              ? BrowseHistoryPage(loginPageBuilder: (_) => const SizedBox())
              : const NovelHistoryPage(),
        ),
        GoRoute(
          path: '/novel-reader/:pathWord/:volumeId',
          name: AppRoutes.novelReader,
          builder: (_, state) {
            final extra = state.extra;
            return Scaffold(
              body: Text(
                'novel-reader:${state.pathParameters['volumeId']}:'
                '${extra is NovelReaderExtra ? extra.entryIndex : -1}:'
                '${extra is NovelReaderExtra && extra.resume}',
              ),
            );
          },
        ),
        GoRoute(
          path: '/comic-reader/:pathWord/:chapterUuid',
          name: AppRoutes.reader,
          builder: (_, state) {
            final extra = state.extra;
            return Scaffold(
              body: Text(
                'comic-reader:${state.pathParameters['chapterUuid']}:'
                '${extra is ReaderExtra ? extra.initialPage : -1}:'
                '${extra is ReaderExtra ? extra.group : null}',
              ),
            );
          },
        ),
        GoRoute(
          path: '/novel-details/:pathWord',
          name: AppRoutes.novelDetail,
          builder: (_, state) => Scaffold(
            body: Text('novel-details:${state.pathParameters['pathWord']}'),
          ),
        ),
        GoRoute(
          path: '/comic-details/:pathWord',
          name: AppRoutes.comicDetail,
          builder: (_, state) => Scaffold(
            body: Text('comic-details:${state.pathParameters['pathWord']}'),
          ),
        ),
        GoRoute(
          path: '/login',
          name: AppRoutes.login,
          builder: (_, state) => Scaffold(
            body: Text('login:${state.uri.queryParameters['copyOnly']}'),
          ),
        ),
      ],
    );
    router = nextRouter;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      nextRouter.dispose();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userManagerProvider.overrideWithValue(user),
          themeSettingsProvider.overrideWithValue(ThemeSettings()),
          novelApiProvider.overrideWithValue(api),
          novelReadingStoreProvider.overrideWithValue(store),
        ],
        child: MaterialApp.router(
          routerConfig: nextRouter,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            useMaterial3: true,
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
        ),
      ),
    );
    if (settle) await _settle(tester);
    if (combined && novelTab) {
      await tester.tap(find.text('轻小说'));
      if (settle) {
        await _settle(tester);
      } else {
        await tester.pump(const Duration(milliseconds: 350));
      }
    }
  }
}

Future<void> _settle(WidgetTester tester) async {
  // SharedPreferences 的 Future 可能来自 setUp 的真实 async zone。
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pumpAndSettle();
}

Future<void> _localMode(bool value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('nav_browse_history_local', value);
  await ThemeSettings().initFromPrefs(prefs, persistMigrations: false);
}

Future<void> _menu(WidgetTester tester, String key, String label) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await _settle(tester);
  await tester.tap(find.text(label));
  await _settle(tester);
}

Future<void> _confirm(WidgetTester tester, bool accept) async {
  expect(find.byType(AlertDialog), findsOneWidget);
  if (accept) {
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      ),
    );
  } else {
    await tester.tap(find.text('取消'));
  }
  await _settle(tester);
}

Future<void> _seedComic({
  String pathWord = 'comic',
  String name = '本机漫画',
  String chapter = 'chapter-old',
  String? group,
  int page = 2,
  int day = 22,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final key =
      'reading_history_$pathWord'
      '${group == null ? '' : '_group_${Uri.encodeComponent(group)}'}';
  await prefs.setString(
    key,
    jsonEncode({
      'comicName': name,
      'chapterUuid': chapter,
      'chapterName': '漫画第一话',
      'page': page,
      'totalPage': 20,
      'updatedAt': DateTime.utc(2026, 10, day).toIso8601String(),
      'group': ?group,
      'readChapterUuids': [chapter],
    }),
  );
}

void _expectTitleAndSeen(
  WidgetTester tester, {
  required String title,
  required String location,
}) {
  final titleWidget = tester.widget<Text>(find.text(title));
  expect(titleWidget.maxLines, 1);
  expect(titleWidget.overflow, TextOverflow.ellipsis);
  final seen = tester.widget<Text>(
    find.byWidgetPredicate(
      (widget) =>
          widget is Text && widget.textSpan?.toPlainText() == '看到 $location',
    ),
  );
  expect(seen.maxLines, 2);
  expect(seen.overflow, TextOverflow.ellipsis);
  final span = seen.textSpan;
  expect(span, isA<TextSpan>());
  if (span is TextSpan) {
    final parts = span.children!.whereType<TextSpan>().toList();
    expect(parts.first.text, '看到 ');
    expect(parts.first.style?.fontSize, 12);
    expect(
      parts.last.style?.fontSize,
      greaterThan(parts.first.style!.fontSize!),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await ThemeSettings().initFromPrefs(prefs, persistMigrations: false);
  });
  tearDown(() async {
    await ReadingHistory.flush();
    teardownSecureCredentialStoreForTest();
  });

  for (final combined in [false, true]) {
    testWidgets(
      'online novel history ($combined) uses API, not local progress',
      (tester) async {
        final harness = _Harness();
        await harness.mount(tester, combined: combined);
        expect(find.text('线上小说'), findsOneWidget);
        expect(find.text('本机小说'), findsNothing);
        expect(harness.api.calls, hasLength(1));
        expect(harness.store.recentLimits, isEmpty);
        await tester.tap(find.text('线上小说'));
        await _settle(tester);
        expect(find.text('novel-details:线上小说'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('mode persists and restores the last source after recreation', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    await tester.tap(find.byKey(const ValueKey('history_mode_toggle')));
    await _settle(tester);
    expect(find.text('本地阅读记录'), findsOneWidget);
    expect(find.text('本机小说'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('nav_browse_history_local'), isTrue);
    final callsBefore = harness.api.calls.length;
    await tester.tap(find.byKey(const ValueKey('history_mode_toggle')));
    await _settle(tester);
    expect(find.text('线上小说'), findsOneWidget);
    expect(
      harness.api.calls.length,
      callsBefore,
      reason: '返回已访问的在线列表应保活，不重发首屏请求',
    );
    await tester.tap(find.byKey(const ValueKey('history_mode_toggle')));
    await _settle(tester);
    expect(prefs.getBool('nav_browse_history_local'), isTrue);
    await tester.pumpWidget(const SizedBox());
    await ThemeSettings().initFromPrefs(prefs, persistMigrations: false);
    await harness.mount(tester);
    expect(find.text('本地阅读记录'), findsOneWidget);
    expect(find.text('本机小说'), findsOneWidget);
    expect(harness.api.calls.length, callsBefore);
    await tester.tap(find.byKey(const ValueKey('history_mode_toggle')));
    await _settle(tester);
    expect(prefs.getBool('nav_browse_history_local'), isFalse);
    expect(find.text('线上小说'), findsOneWidget);
  });

  testWidgets(
    'online paging advances server offsets and displays real failures',
    (tester) async {
      final harness = _Harness();
      harness.api.respond = (_, offset) async {
        if (offset == 0) return _page([_onlineEntry('线上 A')], total: 4);
        if (offset == 1) {
          return _page(
            [_onlineEntry('线上 A'), _onlineEntry('线上 B')],
            offset: 1,
            total: 4,
          );
        }
        throw StateError('服务端分页失败');
      };
      await harness.mount(tester, combined: false);
      await tester.tap(find.textContaining('1/4'));
      await _settle(tester);
      expect(find.text('线上 A'), findsOneWidget);
      expect(find.text('线上 B'), findsOneWidget);
      await tester.tap(find.textContaining('3/4'));
      await _settle(tester);
      expect(harness.api.calls.map((call) => call.$2), [0, 1, 3]);
      expect(find.textContaining('服务端分页失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('online clear confirms and never removes local records', (
    tester,
  ) async {
    final harness = _Harness();
    await _seedComic();
    await harness.mount(tester, combined: false);
    await tester.tap(find.byTooltip('清空浏览记录'));
    await _settle(tester);
    await _confirm(tester, false);
    expect(harness.api.clearCalls, 0);
    expect(find.text('线上小说'), findsOneWidget);
    await tester.tap(find.byTooltip('清空浏览记录'));
    await _settle(tester);
    await _confirm(tester, true);
    expect(harness.api.clearCalls, 1);
    expect(find.text('线上小说'), findsNothing);
    expect(harness.store.items, hasLength(1));
    expect(
      (await SharedPreferences.getInstance()).containsKey(
        'reading_history_comic',
      ),
      isTrue,
    );
  });

  testWidgets(
    'account changes retire stale reads and cannot clear a new account',
    (tester) async {
      final harness = _Harness();
      final oldPage = Completer<NovelPage<NovelBrowseEntry>>();
      harness.api.respond = (scope, _) {
        if (scope.endsWith('account-a')) return oldPage.future;
        return Future.value(_page([_onlineEntry('新账号小说')]));
      };
      await harness.mount(tester, combined: false, settle: false);
      await tester.pump();
      harness.user.copyToken = 'account-b';
      await _settle(tester);
      oldPage.complete(_page([_onlineEntry('旧账号小说')]));
      await _settle(tester);
      expect(find.text('旧账号小说'), findsNothing);
      expect(find.text('新账号小说'), findsOneWidget);
      await tester.tap(find.byTooltip('清空浏览记录'));
      await _settle(tester);
      harness.user.copyToken = 'account-c';
      await tester.pump();
      await _confirm(tester, true);
      expect(harness.api.clearCalls, 0);
      expect(find.text('新账号小说'), findsOneWidget);
    },
  );

  testWidgets('local search covers all novels, names only and separate types', (
    tester,
  ) async {
    await _localMode(true);
    await _seedComic(name: '目标漫画');
    final harness = _Harness();
    harness.store.items = [
      for (var index = 0; index < 42; index++)
        _position(
          pathWord: 'book-$index',
          name: index == 41 ? '目标小说' : '小说 $index',
          chapter: '章节关键字',
        ),
    ];
    await harness.mount(tester);
    expect(harness.api.calls, isEmpty);
    expect(harness.store.recentLimits, contains(null));
    final novelSearch = find.byKey(
      const ValueKey('local_history_search_novel'),
    );
    await tester.enterText(novelSearch, '目标');
    await _settle(tester);
    expect(find.text('目标小说'), findsOneWidget);
    expect(find.text('目标漫画'), findsNothing);
    await tester.enterText(novelSearch, '章节关键字');
    await _settle(tester);
    expect(find.text('没有匹配的作品'), findsOneWidget);
    await tester.tap(find.text('漫画'));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('local_history_search_comic')),
      '目标',
    );
    await _settle(tester);
    expect(find.text('目标漫画'), findsOneWidget);
    expect(find.text('目标小说'), findsNothing);
  });

  testWidgets(
    'local novel rereads newest progress and skips removed positions',
    (tester) async {
      await _localMode(true);
      final harness = _Harness();
      await harness.mount(tester);
      final gate = Completer<void>();
      harness.store.items = [_position(volume: 'volume-2', entry: 8)];
      harness.store.recentGate = gate;
      NovelReadingStore.notifyChanged();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('novel_history_book')));
      await _settle(tester);
      expect(find.text('novel-reader:volume-2:8:true'), findsOneWidget);
      gate.complete();
      harness.store.recentGate = null;
      harness.router!.pop();
      await _settle(tester);
      harness.store.items.clear();
      await tester.tap(find.byKey(const ValueKey('novel_history_book')));
      await _settle(tester);
      expect(find.textContaining('novel-reader:'), findsNothing);
      expect(find.text('开始阅读后，进度会保存在这里'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local removal confirms cancel, failure, success and type clear',
    (tester) async {
      await _localMode(true);
      await _seedComic();
      final harness = _Harness();
      await harness.mount(tester);
      await _menu(tester, 'novel_history_actions_book', '移除阅读记录');
      await _confirm(tester, false);
      expect(harness.store.removeCalls, 0);
      harness.store.removeError = StateError('本机写入失败');
      await _menu(tester, 'novel_history_actions_book', '移除阅读记录');
      await _confirm(tester, true);
      expect(harness.store.items, hasLength(1));
      expect(find.textContaining('本机写入失败'), findsOneWidget);
      harness.store.removeError = null;
      await _menu(tester, 'novel_history_actions_book', '移除阅读记录');
      await _confirm(tester, true);
      expect(harness.store.items, isEmpty);
      harness.store.items = [_position()];
      NovelReadingStore.notifyChanged();
      await _settle(tester);
      await tester.tap(find.byTooltip('清空阅读记录'));
      await _settle(tester);
      await _confirm(tester, false);
      expect(harness.store.clearCalls, 0);
      await tester.tap(find.byTooltip('清空阅读记录'));
      await _settle(tester);
      await _confirm(tester, true);
      expect(harness.store.clearCalls, 1);
      expect(harness.store.items, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          'reading_history_comic',
        ),
        isTrue,
      );
      expect(harness.api.clearCalls, 0);
    },
  );

  testWidgets(
    'local comics deduplicate groups, resume newest pages and delete groups',
    (tester) async {
      await _localMode(true);
      await _seedComic();
      await _seedComic(group: 'default');
      await _seedComic(group: '番外', chapter: 'chapter-new', page: 7, day: 23);
      final harness = _Harness();
      await harness.mount(tester, novelTab: false);
      expect(find.text('本机漫画'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('comic_history_comic')));
      await _settle(tester);
      expect(find.text('comic-reader:chapter-new:7:番外'), findsOneWidget);
      harness.router!.pop();
      await _settle(tester);
      await _menu(tester, 'comic_history_actions_comic', '移除阅读记录');
      await _confirm(tester, false);
      expect(await ReadingHistory.latestForComic('comic'), isNotNull);
      await _menu(tester, 'comic_history_actions_comic', '移除阅读记录');
      await _confirm(tester, true);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().where((key) => key.startsWith('reading_history_comic')),
        isEmpty,
      );
      expect(harness.store.items, hasLength(1));
      expect(harness.api.clearCalls, 0);
    },
  );

  testWidgets('local comic clear under search only clears comics', (
    tester,
  ) async {
    await _localMode(true);
    await _seedComic(pathWord: 'alpha', name: 'Alpha 漫画');
    await _seedComic(pathWord: 'beta', name: 'Beta 漫画');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('download_queue_state_v1', 'download state');
    final harness = _Harness();
    await harness.mount(tester, novelTab: false);
    await tester.enterText(
      find.byKey(const ValueKey('local_history_search_comic')),
      'Alpha',
    );
    await _settle(tester);
    expect(find.text('Alpha 漫画'), findsOneWidget);
    expect(find.text('Beta 漫画'), findsNothing);
    await tester.tap(find.byTooltip('清空阅读记录'));
    await _settle(tester);
    await _confirm(tester, true);
    expect(await ReadingHistory.latestForComic('alpha'), isNull);
    expect(await ReadingHistory.latestForComic('beta'), isNull);
    expect(harness.store.items, hasLength(1));
    expect(prefs.getString('download_queue_state_v1'), 'download state');
    expect(prefs.getBool('nav_browse_history_local'), isTrue);
  });

  testWidgets('online clear failure keeps the record and displays its cause', (
    tester,
  ) async {
    final harness = _Harness();
    harness.api.clearError = StateError('服务端清空失败');
    await harness.mount(tester, combined: false);
    await tester.tap(find.byTooltip('清空浏览记录'));
    await _settle(tester);
    await _confirm(tester, true);
    expect(harness.api.clearCalls, 1);
    expect(find.text('线上小说'), findsOneWidget);
    expect(find.textContaining('服务端清空失败'), findsOneWidget);
    expect(harness.store.items, hasLength(1));
  });

  testWidgets('disabled novel setting hides the local novel tab', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('nav_browse_history_local', true);
    await prefs.setBool('nav_show_novel', false);
    await ThemeSettings().initFromPrefs(prefs, persistMigrations: false);
    final harness = _Harness();
    await harness.mount(tester, novelTab: false);
    expect(find.text('轻小说'), findsNothing);
    expect(
      find.byKey(const ValueKey('local_history_search_novel')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('local_history_search_comic')),
      findsOneWidget,
    );
    expect(harness.api.calls, isEmpty);
    expect(harness.store.recentLimits, isEmpty);
  });

  for (final width in [320.0, 800.0]) {
    for (final dark in [false, true]) {
      testWidgets('online metadata is subdued at $width, dark=$dark', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const updatedAt = '2026-08-01T10:00:00';
        final harness = _Harness();
        harness.api.respond = (_, _) async => _page([
          const NovelBrowseEntry(
            book: NovelBook(
              pathWord: 'metadata-book',
              name: '元信息测试',
              popular: 12345,
              datetimeUpdated: updatedAt,
              lastChapterName: '最新一卷',
            ),
            lastChapterName: '远端第一卷',
          ),
        ]);
        await harness.mount(tester, combined: false, dark: dark);
        final updated = find.byWidgetPredicate(
          (widget) =>
              widget is Text && (widget.data?.startsWith('更新于 ') ?? false),
        );
        expect(updated, findsOneWidget);
        final context = tester.element(updated);
        final l10n = AppLocalizations.of(context)!;
        final cs = Theme.of(context).colorScheme;
        final text = tester.widget<Text>(updated);
        expect(
          text.data,
          l10n.browseHistoryUpdatedAt(TimeFormat.relativeOf(updatedAt, l10n)),
        );
        expect(text.style?.fontSize, 12);
        expect(text.style?.color, cs.onSurfaceVariant);
        expect(text.maxLines, 1);
        expect(text.overflow, TextOverflow.ellipsis);
        for (final iconData in [Icons.local_fire_department, Icons.schedule]) {
          final icon = tester.widget<Icon>(find.byIcon(iconData));
          expect(icon.color, cs.onSurfaceVariant);
          expect(icon.size, AppIconSize.sm);
        }
        // 检查元信息到 Wrap 之间没有胶囊底色，不受外层卡片样式影响。
        var decorated = false;
        context.visitAncestorElements((element) {
          final widget = element.widget;
          if (widget is Wrap) return false;
          if ((widget is Container && widget.decoration != null) ||
              widget is DecoratedBox) {
            decorated = true;
          }
          return true;
        });
        expect(decorated, isFalse);
        _expectTitleAndSeen(tester, title: '元信息测试', location: '远端第一卷');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'titles stay one line and seen labels are smaller than chapters',
    (tester) async {
      const title = '很长的小说标题很长的小说标题很长的小说标题很长的小说标题';
      const chapter = '很长的章节名称很长的章节名称很长的章节名称很长的章节名称';
      final harness = _Harness();
      harness.api.respond = (_, _) async =>
          _page([_onlineEntry(title, chapter: chapter)]);
      await harness.mount(tester, combined: false);
      _expectTitleAndSeen(tester, title: title, location: chapter);
      await tester.pumpWidget(const SizedBox());
      await _localMode(true);
      const comicTitle = '很长的漫画标题很长的漫画标题很长的漫画标题很长的漫画标题';
      await _seedComic(name: comicTitle);
      harness.store.items = [_position(name: title, chapter: chapter)];
      await harness.mount(tester);
      _expectTitleAndSeen(tester, title: title, location: '本机第一卷 · $chapter');
      await tester.tap(find.text('漫画'));
      await _settle(tester);
      _expectTitleAndSeen(tester, title: comicTitle, location: '漫画第一话');
      expect(find.textContaining('上次看到'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

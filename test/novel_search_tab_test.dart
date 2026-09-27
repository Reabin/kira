import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/novel/novel_api.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/pages/novel_search_tab.dart';
import 'package:kira/providers/novel_providers.dart';
import 'package:kira/utils/app_storage.dart';
import 'package:kira/utils/search_history.dart';
import 'package:kira/widgets/filter_chip_row.dart';
import 'package:kira/widgets/load_more_footer.dart';
import 'package:kira/widgets/shimmer_skeleton.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _book = NovelBook(pathWord: 'book', name: '浏览小说');
const _hit = NovelBook(pathWord: 'hit', name: '搜索命中');

NovelPage<NovelBook> _page(
  List<NovelBook> list, {
  int? total,
  int offset = 0,
}) => NovelPage(
  list: list,
  total: total ?? list.length,
  limit: 18,
  offset: offset,
);

class _Api implements NovelApi {
  Future<NovelPage<NovelBook>> Function(
    String theme,
    String ordering,
    int offset,
  )?
  books;
  Future<NovelPage<NovelBook>> Function(String keyword, int offset)? search;
  final bookRequests = <(String, String, int)>[];
  final searchRequests = <(String, int)>[];

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
  }) {
    bookRequests.add((theme, ordering, offset));
    return books?.call(theme, ordering, offset) ?? Future.value(_page([_book]));
  }

  @override
  Future<NovelPage<NovelBook>> searchBooks({
    required String keyword,
    int limit = 18,
    int offset = 0,
  }) {
    searchRequests.add((keyword, offset));
    return search?.call(keyword, offset) ?? Future.value(_page([_hit]));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected API call: ${invocation.memberName}');
}

Future<void> _pump(
  WidgetTester tester,
  _Api api, {
  bool tabs = false,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [novelApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: tabs
            ? DefaultTabController(
                length: 2,
                child: Scaffold(
                  appBar: AppBar(
                    bottom: const TabBar(
                      tabs: [
                        Tab(text: '小说'),
                        Tab(text: '其他'),
                      ],
                    ),
                  ),
                  body: const TabBarView(
                    children: [NovelSearchTab(), Text('其他标签内容')],
                  ),
                ),
              )
            : const Scaffold(body: NovelSearchTab()),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _search(WidgetTester tester, String keyword) async {
  await tester.enterText(find.byType(TextField), keyword);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => SharedPreferences.setMockInitialValues({}));
  setUp(() async {
    await SearchHistory.flush();
    await (await AppStorage.sharedPreferences()).clear();
  });

  for (final searching in [false, true]) {
    testWidgets('${searching ? '搜索' : '浏览'}分页失败后实际点击重试，保留原始offset', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = _Api();
      var failed = false;
      Future<NovelPage<NovelBook>> load(int offset) async {
        if (offset == 0) return _page([_book, _book], total: 3);
        if (!failed) {
          failed = true;
          throw const NovelApiException('offline');
        }
        return _page([_hit], total: 3, offset: offset);
      }

      api.books = (_, _, offset) => load(offset);
      api.search = (_, offset) => load(offset);
      await _pump(tester, api);
      await tester.pumpAndSettle();
      if (searching) await _search(tester, '关键词');
      final l10n = AppLocalizations.of(
        tester.element(find.byType(NovelSearchTab)),
      )!;
      await tester.tap(find.text(l10n.novelLoadMore));
      await tester.pumpAndSettle();
      expect(find.text(_book.name), findsOneWidget);
      expect(find.text(l10n.novelLoadMoreFailed), findsOneWidget);
      final requestCount = api.bookRequests.length + api.searchRequests.length;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(api.bookRequests.length + api.searchRequests.length, requestCount);
      await tester.tap(find.text(l10n.novelLoadMoreFailed));
      await tester.pumpAndSettle();
      expect(find.text(_hit.name), findsOneWidget);
      expect(find.text(_book.name), findsOneWidget);
      expect(find.byType(LoadMoreFooter), findsNothing);
      expect(
        searching
            ? api.searchRequests.map((request) => request.$2)
            : api.bookRequests.map((request) => request.$3),
        [0, 2, 2],
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('历史只在未搜索时显示，点历史搜索及清空均保留浏览结果', (tester) async {
    await AppStorage.preferences.setStringList(SearchHistory.storageKey, [
      '历史词',
    ]);
    final api = _Api();
    await _pump(tester, api);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, '历史词'), findsOneWidget);
    await tester.tap(find.widgetWithText(InputChip, '历史词'));
    await tester.pumpAndSettle();
    expect(find.text(_hit.name), findsOneWidget);
    expect(find.byType(InputChip), findsNothing);
    expect(api.searchRequests, [('历史词', 0)]);
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    expect(find.text(_book.name), findsOneWidget);
    expect(find.widgetWithText(InputChip, '历史词'), findsOneWidget);
    expect(api.bookRequests, hasLength(1));
  });

  for (final size in [const Size(320, 800), const Size(1000, 800)]) {
    testWidgets('宽度${size.width}大字号骨架与真实小说网格一致', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = _Api();
      final loading = Completer<NovelPage<NovelBook>>();
      api.books = (_, _, _) => loading.future;
      await _pump(tester, api, textScale: 1.7);
      expect(find.byType(ComicCoverSkeletonGrid), findsOneWidget);
      final skeleton = tester
          .widget<SliverGrid>(find.byType(SliverGrid))
          .gridDelegate;
      loading.complete(_page([_book]));
      await tester.pumpAndSettle();
      final actual = tester
          .widget<SliverGrid>(find.byType(SliverGrid))
          .gridDelegate;
      expect(actual.shouldRelayout(skeleton), isFalse);
      expect(find.byType(ComicCoverSkeletonGrid), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final searching in [false, true]) {
    testWidgets('${searching ? '搜索' : '浏览'}下拉刷新保留旧结果，内联失败重试从零替换', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = _Api();
      final refreshing = Completer<NovelPage<NovelBook>>();
      var calls = 0;
      Future<NovelPage<NovelBook>> load(int offset) {
        expect(offset, 0);
        calls++;
        if (calls == 1) return Future.value(_page([_book], total: 3));
        if (calls == 2) return refreshing.future;
        return Future.value(_page([_hit]));
      }

      if (searching) {
        api.search = (_, offset) => load(offset);
      } else {
        api.books = (_, _, offset) => load(offset);
      }
      await _pump(tester, api);
      await tester.pumpAndSettle();
      if (searching) await _search(tester, '关键词');
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 450));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 2);
      expect(find.text(_book.name), findsOneWidget);
      expect(find.byType(ComicCoverSkeletonGrid), findsNothing);
      refreshing.completeError(const NovelApiException('refresh offline'));
      await tester.pumpAndSettle();
      expect(find.text(_book.name), findsOneWidget);
      expect(find.byType(InlineRetryNotice), findsOneWidget);
      expect(find.byType(LoadMoreFooter), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byType(InlineRetryNotice),
          matching: find.text('重试'),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 3);
      expect(find.text(_hit.name), findsOneWidget);
      expect(find.text(_book.name), findsNothing);
      expect(find.byType(InlineRetryNotice), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('切换标签保留搜索与滚动，清空搜索仍使用独立浏览分页', (tester) async {
    final api = _Api();
    api.books = (_, _, offset) async => offset == 0
        ? _page([_book], total: 2)
        : _page(
            [const NovelBook(pathWord: 'browse-next', name: '浏览下一页')],
            total: 2,
            offset: offset,
          );
    api.search = (_, _) async => _page([
      for (var i = 0; i < 50; i++)
        NovelBook(pathWord: 'hit-$i', name: '搜索结果$i'),
    ]);
    await _pump(tester, api, tabs: true);
    await tester.pumpAndSettle();
    await _search(tester, '保存关键词');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    final offset = scroll.offset;
    expect(offset, greaterThan(0));
    await tester.tap(find.text('其他'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小说'));
    await tester.pumpAndSettle();
    expect(scroll.offset, offset);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '保存关键词',
    );
    expect(api.searchRequests, [('保存关键词', 0)]);
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    expect(find.text(_book.name), findsOneWidget);
    final footer = find.byType(LoadMoreFooter);
    if (footer.evaluate().isNotEmpty) {
      await tester.ensureVisible(footer);
      await tester.tap(
        find.descendant(of: footer, matching: find.byType(OutlinedButton)),
      );
      await tester.pumpAndSettle();
    }
    expect(api.bookRequests.map((request) => request.$3), [0, 1]);
    expect(find.text('浏览下一页'), findsOneWidget);
  });
}

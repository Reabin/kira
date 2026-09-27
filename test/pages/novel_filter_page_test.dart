import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kira/api/novel/novel_api.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/models/novel_reading_progress.dart';
import 'package:kira/pages/novel_detail_page.dart';
import 'package:kira/pages/novel_filter_page.dart';
import 'package:kira/pages/novel_home_page.dart';
import 'package:kira/providers/app_providers.dart';
import 'package:kira/providers/novel_providers.dart';
import 'package:kira/repositories/novel_repository.dart';
import 'package:kira/routing/app_router.dart';
import 'package:kira/utils/app_storage.dart';
import 'package:kira/utils/novel_download_manager.dart';
import 'package:kira/utils/novel_reading_store.dart';
import 'package:kira/utils/search_history.dart';
import 'package:kira/widgets/comic_info_chips.dart';
import 'package:kira/widgets/error_retry_view.dart';
import 'package:kira/widgets/filter_chip_row.dart';
import 'package:kira/widgets/load_more_footer.dart';
import 'package:kira/widgets/novel_widgets.dart';
import 'package:kira/widgets/shimmer_skeleton.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../novel_api_test.dart'
    show NovelTestAdapter, NovelTestUser, novelJsonResponse;

const _author = NovelTag(name: '雨森焚火', pathWord: ' yusentakibi ');
const _theme = NovelTag(name: '爱情', pathWord: 'aiqing');
const _book = NovelBook(
  pathWord: 'book',
  name: '标签来源小说',
  uuid: 'book-uuid',
  authors: [
    _author,
    NovelTag(name: '第二作者', pathWord: 'second-author'),
    NovelTag(name: '未知作者', pathWord: ' '),
  ],
  themes: [
    _theme,
    NovelTag(name: '奇幻', pathWord: 'fantasy'),
    NovelTag(name: '未知主题', pathWord: ''),
  ],
);
const _first = NovelBook(pathWord: 'first', name: '筛选作品一');
const _next = NovelBook(pathWord: 'next', name: '筛选作品二');

ResponseBody _booksResponse(
  List<NovelBook> books, {
  int? total,
  int offset = 0,
}) => novelJsonResponse({
  'list': books.map((book) => book.toJson()).toList(),
  'total': total ?? books.length,
  'offset': offset,
  'limit': 18,
});

class _User extends NovelTestUser {
  @override
  bool get isCopyLoggedIn => copyToken?.isNotEmpty == true;
}

class _Repository implements NovelRepository {
  int detailCalls = 0;

  @override
  Future<NovelDetail> loadDetail(
    String pathWord, {
    bool refresh = false,
  }) async {
    detailCalls++;
    return const NovelDetail(book: _book);
  }

  @override
  Future<List<NovelVolume>> loadVolumes(
    String pathWord, {
    bool refresh = false,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository call: ${invocation.memberName}');
}

class _Store implements NovelReadingStore {
  @override
  Future<NovelReadingProgress?> readProgress(String pathWord) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected storage call: ${invocation.memberName}');
}

class _Downloads extends ChangeNotifier implements NovelDownloadManager {
  @override
  final List<NovelDownloadTask> tasks = [];

  @override
  Set<String> localVolumeIds(String pathWord) => {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected download call: ${invocation.memberName}');
}

/// Uses the real API and production detail/filter route builders, but only
/// fake Dio adapters and in-memory repositories; never creates a socket.
class _Harness {
  final user = _User();
  final repository = _Repository();
  final downloads = _Downloads();
  FutureOr<ResponseBody> Function(RequestOptions)? books;
  FutureOr<ResponseBody> Function(RequestOptions)? search;
  late final NovelTestAdapter adapter = NovelTestAdapter((request, _) {
    switch (request.uri.path) {
      case '/api/v3/books':
        return books?.call(request) ?? _booksResponse([_first]);
      case '/api/v3/search/books':
        return search?.call(request) ?? _booksResponse([_first]);
      case '/api/v3/theme/book/count':
        return novelJsonResponse({
          'list': [const NovelTag(name: '奇幻', pathWord: 'fantasy').toJson()],
          'total': 1,
          'offset': 0,
          'limit': 500,
        });
      default:
        if (request.uri.path.endsWith('/query')) {
          return novelJsonResponse(const NovelQuery().toJson());
        }
        throw StateError('Unexpected HTTP request: ${request.uri.path}');
    }
  });
  final contentAdapter = NovelTestAdapter((request, _) {
    throw StateError('Unexpected content request: ${request.uri}');
  });
  late final api = NovelApi.withDio(
    user: user,
    dio: Dio()..httpClientAdapter = adapter,
    contentDio: Dio()..httpClientAdapter = contentAdapter,
  );
  late GoRouter router;

  List<RequestOptions> get bookRequests => adapter.requests
      .where((request) => request.uri.path == '/api/v3/books')
      .toList();

  Future<void> pump(WidgetTester tester, {bool fromHome = false}) async {
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final productionRouter = createAppRouter();
    final routes = productionRouter.configuration.routes
        .whereType<GoRoute>()
        .where(
          (route) =>
              route.name == AppRoutes.novelDetail ||
              route.name == AppRoutes.novelFilter,
        )
        .toList();
    productionRouter.dispose();
    router = GoRouter(
      initialLocation: fromHome ? '/' : '/novel/book',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const NovelHomePage()),
        ...routes,
      ],
    );
    addTearDown(router.dispose);
    addTearDown(user.dispose);
    addTearDown(downloads.dispose);
    addTearDown(api.close);
    addTearDown(() => expect(contentAdapter.requests, isEmpty));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          novelApiProvider.overrideWithValue(api),
          novelRepositoryProvider.overrideWithValue(repository),
          novelReadingStoreProvider.overrideWithValue(_Store()),
          novelDownloadManagerProvider.overrideWithValue(downloads),
          userManagerProvider.overrideWithValue(user),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> _tapTag(WidgetTester tester, NovelTag tag) async {
  final chip = find.widgetWithText(InfoChip, tag.name);
  await tester.ensureVisible(chip);
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

void _expectQuery(
  RequestOptions request,
  NovelFilterKind kind,
  NovelTag tag,
  int offset,
) {
  expect(request.queryParameters, {
    kind.name: tag.pathWord.trim(),
    'ordering': '-popular',
    'limit': 18,
    'offset': offset,
    'platform': 3,
  });
}

void main() {
  setUpAll(() => SharedPreferences.setMockInitialValues({}));
  setUp(() async {
    await SearchHistory.flush();
    await (await AppStorage.sharedPreferences()).clear();
  });

  for (final (kind, tag) in [
    (NovelFilterKind.author, _author),
    (NovelFilterKind.author, _book.authors[1]),
    (NovelFilterKind.theme, _theme),
    (NovelFilterKind.theme, _book.themes[1]),
  ]) {
    testWidgets('实际点击${tag.name}，使用pathWord筛选并返回原详情', (tester) async {
      final harness = _Harness();
      await harness.pump(tester);
      final detailState = tester.state(find.byType(NovelDetailPage));
      await _tapTag(tester, tag);
      final page = tester.widget<NovelFilterPage>(find.byType(NovelFilterPage));
      expect(page.kind, kind);
      expect(page.pathWord, tag.pathWord.trim());
      expect(page.name, tag.name);
      final title = kind == NovelFilterKind.author ? '作者作品' : '主题作品';
      expect(
        find.widgetWithText(AppBar, '$title · ${tag.name}'),
        findsOneWidget,
      );
      expect(find.text('最近更新'), findsOneWidget);
      expect(find.byType(NovelBookCard), findsOneWidget);
      _expectQuery(harness.bookRequests.single, kind, tag, 0);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(NovelDetailPage)), same(detailState));
      expect(harness.repository.detailCalls, 1);
      expect(harness.bookRequests, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('空作者或主题标识保持静态，不跳转不请求列表', (tester) async {
    final harness = _Harness();
    await harness.pump(tester);
    for (final name in ['未知作者', '未知主题']) {
      final chip = find.widgetWithText(InfoChip, name);
      expect(tester.widget<InfoChip>(chip).onTap, isNull);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.byType(NovelDetailPage), findsOneWidget);
      expect(find.byType(NovelFilterPage), findsNothing);
    }
    expect(harness.bookRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final (kind, tag) in [
    (NovelFilterKind.author, _author),
    (NovelFilterKind.theme, _theme),
  ]) {
    testWidgets('${kind.name}加载更多失败实际重试，保留筛选及原始offset', (tester) async {
      final harness = _Harness();
      var attempts = 0;
      harness.books = (request) {
        if (request.queryParameters['offset'] == 0) {
          return _booksResponse([_first, _first], total: 3);
        }
        if (++attempts == 1) return novelJsonResponse(null, code: 500);
        return _booksResponse([_next], total: 3, offset: 2);
      };
      await harness.pump(tester);
      await _tapTag(tester, tag);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(NovelFilterPage)),
      )!;
      await tester.tap(find.text(l10n.novelLoadMore));
      await tester.pumpAndSettle();
      expect(find.text(_first.name), findsOneWidget);
      expect(find.text(l10n.novelLoadMoreFailed), findsOneWidget);
      final requestCount = harness.bookRequests.length;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(harness.bookRequests, hasLength(requestCount));
      await tester.tap(find.text(l10n.novelLoadMoreFailed));
      await tester.pumpAndSettle();
      expect(find.text(_next.name), findsOneWidget);
      expect(find.text(_first.name), findsOneWidget);
      expect(find.byType(LoadMoreFooter), findsNothing);
      expect(harness.bookRequests, hasLength(3));
      for (var i = 0; i < harness.bookRequests.length; i++) {
        _expectQuery(harness.bookRequests[i], kind, tag, i == 0 ? 0 : 2);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('${kind.name}首屏失败重试保留标签，空结果显示对应空态', (tester) async {
      final harness = _Harness();
      var calls = 0;
      harness.books = (_) => ++calls == 1
          ? novelJsonResponse(null, code: 500)
          : _booksResponse([]);
      await harness.pump(tester);
      await _tapTag(tester, tag);
      expect(find.byType(ErrorRetryView), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(
        find.text(kind == NovelFilterKind.author ? '暂无作者作品' : '暂无主题作品'),
        findsOneWidget,
      );
      expect(harness.bookRequests, hasLength(2));
      for (final request in harness.bookRequests) {
        _expectQuery(request, kind, tag, 0);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('${kind.name}下拉刷新保留旧结果，失败重试仍使用相同标签', (tester) async {
      final harness = _Harness();
      final refreshing = Completer<ResponseBody>();
      var calls = 0;
      harness.books = (_) => switch (++calls) {
        1 => _booksResponse([_first], total: 3),
        2 => refreshing.future,
        _ => _booksResponse([_next]),
      };
      await harness.pump(tester);
      await _tapTag(tester, tag);
      final gesture = await tester.startGesture(
        tester.getTopLeft(find.byType(CustomScrollView)) + const Offset(80, 80),
      );
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 400));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      // 刷新动画结束后，Dio 的异步拦截器还需推进事件轮；不能对待完成请求 settle。
      for (var frame = 0; frame < 10 && calls < 2; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(calls, 2);
      expect(find.text(_first.name), findsOneWidget);
      expect(find.byType(ComicCoverSkeletonGrid), findsNothing);
      refreshing.complete(novelJsonResponse(null, code: 500));
      await tester.pumpAndSettle();
      expect(find.text(_first.name), findsOneWidget);
      expect(find.byType(InlineRetryNotice), findsOneWidget);
      expect(find.byType(LoadMoreFooter), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byType(InlineRetryNotice),
          matching: find.text('重试'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(_first.name), findsNothing);
      expect(find.text(_next.name), findsOneWidget);
      expect(harness.bookRequests, hasLength(3));
      for (final request in harness.bookRequests) {
        _expectQuery(request, kind, tag, 0);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('打开筛选结果中的小说再返回，保留列表及滚动位置', (tester) async {
    final harness = _Harness();
    harness.books = (_) => _booksResponse([
      for (var i = 0; i < 30; i++)
        NovelBook(pathWord: 'result-$i', name: '作品$i'),
    ]);
    await harness.pump(tester);
    await _tapTag(tester, _author);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    expect(scroll.offset, greaterThan(0));
    final card = find.byType(NovelBookCard).hitTestable().first;
    final expectedBook = tester.widget<NovelBookCard>(card).book;
    final offset = scroll.offset;
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(
      tester.widget<NovelDetailPage>(find.byType(NovelDetailPage)).pathWord,
      expectedBook.pathWord,
    );
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(NovelFilterPage), findsOneWidget);
    expect(scroll.offset, offset);
    expect(harness.bookRequests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页经详情打开标签后返回，恢复搜索、题材及滚动位置', (tester) async {
    final harness = _Harness();
    final manyBooks = [
      for (var i = 0; i < 30; i++)
        NovelBook(pathWord: 'result-$i', name: '作品$i'),
    ];
    harness.books = (_) => _booksResponse(manyBooks);
    harness.search = (_) => _booksResponse(manyBooks);
    await harness.pump(tester, fromHome: true);
    await tester.tap(find.text('奇幻'));
    await tester.pumpAndSettle();
    expect(harness.bookRequests.last.queryParameters['theme'], 'fantasy');
    await tester.enterText(find.byType(TextField), '保留关键词');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    final offset = scroll.offset;
    expect(offset, greaterThan(0));
    await tester.tap(find.byType(NovelBookCard).hitTestable().first);
    await tester.pumpAndSettle();
    await _tapTag(tester, _author);
    _expectQuery(harness.bookRequests.last, NovelFilterKind.author, _author, 0);
    final requestCount = harness.adapter.requests.length;
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(NovelHomePage), findsOneWidget);
    expect(scroll.offset, offset);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '保留关键词',
    );
    expect(harness.adapter.requests, hasLength(requestCount));
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!
        .jumpTo(0);
    await tester.pumpAndSettle();
    final selectedTheme = tester
        .widget<FilterChipRow>(find.byType(FilterChipRow).last)
        .options
        .singleWhere((option) => option.value == 'fantasy');
    expect(selectedTheme.selected, isTrue);
    expect(harness.adapter.requests, hasLength(requestCount));
    expect(tester.takeException(), isNull);
  });
}

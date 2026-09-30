import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kira/api/novel/novel_api.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/comment_settings.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/models/novel_reading_progress.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/comic_detail_page.dart' show ChapterCard;
import 'package:kira/pages/novel_bookshelf_page.dart';
import 'package:kira/pages/novel_detail_page.dart';
import 'package:kira/pages/novel_history_page.dart';
import 'package:kira/pages/novel_home_page.dart';
import 'package:kira/providers/app_providers.dart';
import 'package:kira/providers/novel_providers.dart';
import 'package:kira/providers/settings_providers.dart';
import 'package:kira/repositories/novel_repository.dart';
import 'package:kira/routing/app_router.dart';
import 'package:kira/utils/novel_download_manager.dart';
import 'package:kira/utils/novel_reading_store.dart';
import 'package:kira/widgets/comment_skeleton.dart';
import 'package:kira/widgets/novel_comments_sheet.dart';
import 'package:kira/widgets/novel_paged_controller.dart';
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';
import 'package:shared_preferences/shared_preferences.dart';

NovelPage<T> _page<T>(List<T> list, {int? total, int offset = 0}) =>
    NovelPage<T>(
      list: list,
      total: total ?? list.length,
      limit: 18,
      offset: offset,
    );

const _book = NovelBook(pathWord: 'book', name: '测试小说', uuid: 'book-uuid');
const _first = NovelVolume(id: 'first', name: '第一卷');
const _second = NovelVolume(id: 'second', name: '第二卷');
const _third = NovelVolume(id: 'third', name: '第三卷');
const _remote = NovelBrowse(
  bookId: 'book-uuid',
  pathWord: 'book',
  chapterId: 'remote',
  chapterName: '远端卷',
);

// No real API clients, images, platform storage or business/CDN connections
// are constructed anywhere in this suite. Unexpected calls fail immediately.
class _Api implements NovelApi {
  Future<NovelPage<NovelBook>> Function(
    String theme,
    String ordering,
    int offset,
  )?
  books;
  Future<NovelPage<NovelBook>> Function(String keyword, int offset)? search;
  final List<String> searchKeywords = [];
  Future<NovelPage<NovelShelfEntry>> Function(int offset)? shelf;
  Future<NovelQuery> Function()? query;
  Future<NovelPage<NovelComment>> Function(String? replyId, int offset)?
  comments;
  Future<void> Function(String content)? post;
  List<NovelTag> themes = const [NovelTag(name: '奇幻', pathWord: 'fantasy')];
  int bookCalls = 0;
  int shelfCalls = 0;
  int queryCalls = 0;
  int commentCalls = 0;
  int postCalls = 0;
  final List<(String, bool)> collections = [];
  String Function()? scopeOf;

  @override
  String get cacheScope => scopeOf?.call() ?? 'scope:guest';

  @override
  Future<NovelPage<NovelBook>> getBooks({
    String theme = '',
    String author = '',
    String ordering = '-popular',
    int limit = 18,
    int offset = 0,
  }) {
    bookCalls++;
    return books?.call(theme, ordering, offset) ??
        Future.value(_page<NovelBook>([]));
  }

  @override
  Future<NovelPage<NovelBook>> searchBooks({
    required String keyword,
    int limit = 18,
    int offset = 0,
  }) {
    searchKeywords.add(keyword);
    return search?.call(keyword, offset) ?? Future.value(_page<NovelBook>([]));
  }

  @override
  Future<List<NovelTag>> getThemes() async => themes;

  @override
  Future<NovelPage<NovelShelfEntry>> getBookshelf({
    int limit = 18,
    int offset = 0,
    int freeType = 1,
    String ordering = '-datetime_modifier',
  }) {
    shelfCalls++;
    return shelf?.call(offset) ?? Future.value(_page<NovelShelfEntry>([]));
  }

  @override
  Future<NovelQuery> getQuery(String pathWord) {
    queryCalls++;
    return query?.call() ?? Future.value(const NovelQuery());
  }

  @override
  Future<void> setCollected({
    required String bookUuid,
    required bool collected,
  }) async {
    collections.add((bookUuid, collected));
  }

  @override
  Future<NovelPage<NovelComment>> getComments({
    required String bookUuid,
    String? replyId,
    int limit = 10,
    int offset = 0,
  }) {
    expect(bookUuid, 'book-uuid');
    commentCalls++;
    return comments?.call(replyId, offset) ??
        Future.value(_page<NovelComment>([]));
  }

  @override
  Future<void> postComment({
    required String bookUuid,
    required String content,
    String? replyId,
  }) async {
    expect(bookUuid, 'book-uuid');
    postCalls++;
    await post?.call(content);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected API call: ${invocation.memberName}');
}

class _Repository implements NovelRepository {
  Future<NovelDetail> Function()? detail;
  List<NovelVolume> volumes = const [_first];
  int detailCalls = 0;

  @override
  Future<NovelDetail> loadDetail(String pathWord, {bool refresh = false}) {
    detailCalls++;
    return detail?.call() ?? Future.value(const NovelDetail(book: _book));
  }

  @override
  Future<NovelDetail?> loadDetailFromCache(String pathWord) async => null;

  @override
  Future<List<NovelVolume>> loadVolumes(
    String pathWord, {
    bool refresh = false,
  }) async => volumes;

  @override
  Future<List<NovelVolume>?> loadVolumesFromCache(String pathWord) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository call: ${invocation.memberName}');
}

class _Progress extends NovelReadingProgress {
  _Progress({
    super.chapterName = '本地章节',
    super.volumeName = '本地卷',
    super.progress = 0.42,
  }) : super(
         pathWord: 'book',
         name: '本地小说',
         cover: '',
         volumeId: 'local-volume',
         entryIndex: 7,
         updatedAt: DateTime(2026, 9, 26),
       );
}

class _Store implements NovelReadingStore {
  List<NovelReadingProgress> items = [];

  @override
  Future<List<NovelReadingProgress>> readRecent({int limit = 30}) async =>
      items.take(limit).toList();

  @override
  Future<NovelReadingProgress?> readProgress(String pathWord) async {
    for (final item in items) {
      if (item.pathWord == pathWord) return item;
    }
    return null;
  }

  @override
  Future<void> removeProgress(String pathWord) async =>
      items.removeWhere((item) => item.pathWord == pathWord);

  @override
  Future<void> clear() async => items.clear();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected storage call: ${invocation.memberName}');
}

class _User extends ChangeNotifier implements UserManager {
  @override
  String? copyToken;
  @override
  String copyApiHost = 'copy.invalid';
  bool hotLoggedIn = false;

  // 屏蔽配置：评论区构建时会读取，默认全部关闭即不过滤。
  @override
  List<String> get commentBlockedUsers => const [];
  @override
  List<String> get commentBlockwords => const [];
  @override
  bool get commentBlockGroupSpam => false;
  @override
  bool get commentBlockNoRemind => false;

  @override
  bool get isCopyLoggedIn => copyToken?.isNotEmpty == true;
  @override
  bool get isLoggedIn => hotLoggedIn || isCopyLoggedIn;

  void switchAccount(String? token) {
    copyToken = token;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected account field: ${invocation.memberName}');
}

class _Downloads extends ChangeNotifier implements NovelDownloadManager {
  @override
  final List<NovelDownloadTask> tasks = [];
  final localStatuses = <String, Map<String, NovelDownloadStatus>>{};
  final enqueueCalls =
      <
        ({
          NovelBook book,
          List<NovelVolume> volumes,
          List<NovelVolume> selected,
        })
      >[];
  Future<void> Function()? enqueue;

  void saveLocal(
    NovelVolume volume, {
    String pathWord = 'book',
    NovelDownloadStatus status = NovelDownloadStatus.completed,
  }) {
    localStatuses.putIfAbsent(pathWord, () => {})[volume.id] = status;
    notifyListeners();
  }

  void queue(
    NovelVolume volume, {
    NovelBook book = _book,
    NovelDownloadStatus status = NovelDownloadStatus.queued,
  }) {
    tasks.add(
      NovelDownloadTask(
        book: book,
        volume: volume,
        volumes: [volume],
        source: const NovelDownloadIdentity(host: 'copy.invalid'),
        status: status,
      ),
    );
    notifyListeners();
  }

  @override
  Set<String> localVolumeIds(String pathWord) =>
      localStatuses[pathWord]?.keys.toSet() ?? const {};

  @override
  bool isVolumeDownloaded(String pathWord, String volumeId) =>
      localStatuses[pathWord]?[volumeId] == NovelDownloadStatus.completed;

  @override
  NovelDownloadTask? taskFor(String pathWord, String volumeId) => tasks
      .where((task) => task.pathWord == pathWord && task.volumeId == volumeId)
      .firstOrNull;

  @override
  bool isVolumeQueued(String pathWord, String volumeId) =>
      switch (taskFor(pathWord, volumeId)?.status) {
        NovelDownloadStatus.queued ||
        NovelDownloadStatus.downloading ||
        NovelDownloadStatus.paused => true,
        _ => false,
      };

  @override
  Future<void> enqueueVolumes({
    required NovelBook book,
    required List<NovelVolume> volumes,
    required Iterable<NovelVolume> selected,
  }) async {
    // 先原样记录调用，不在 fake 中过滤或去重，以暴露页面的误入队。
    final requested = selected.toList();
    enqueueCalls.add((
      book: book,
      volumes: List.of(volumes),
      selected: requested,
    ));
    await enqueue?.call();
    for (final volume in requested) {
      tasks.add(
        NovelDownloadTask(
          book: book,
          volume: volume,
          volumes: List.of(volumes),
          source: const NovelDownloadIdentity(host: 'copy.invalid'),
        ),
      );
    }
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected download call: ${invocation.memberName}');
}

class _Harness {
  final api = _Api();
  final repository = _Repository();
  final downloads = _Downloads();
  final store = _Store();
  final user = _User();
  late GoRouter router;
  NovelReaderExtra? readerExtra;
  String? readerVolume;
  String? loginCopyOnly;
  String? downloadTab;

  Future<void> pump(
    WidgetTester tester,
    Widget page, {
    double textScale = 1,
    bool dark = false,
    bool pushPage = false,
  }) async {
    api.scopeOf = () =>
        'scope:${user.copyApiHost}:${user.copyToken ?? 'guest'}';
    final shelfRepository = NovelBookshelfRepository(api: api);
    addTearDown(shelfRepository.dispose);
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) =>
              pushPage ? const Scaffold(body: Text('返回目标')) : page,
        ),
        GoRoute(path: '/test-page', builder: (_, _) => page),
        GoRoute(
          path: '/downloads',
          name: AppRoutes.downloadCenter,
          builder: (_, state) {
            downloadTab = state.uri.queryParameters['tab'];
            return const Scaffold(body: Text('下载中心目标'));
          },
        ),
        GoRoute(
          path: '/reader/:pathWord/:volumeId',
          name: AppRoutes.novelReader,
          builder: (context, state) {
            readerVolume = state.pathParameters['volumeId'];
            final extra = state.extra;
            if (extra is NovelReaderExtra) readerExtra = extra;
            return const Scaffold(body: Text('阅读器目标'));
          },
        ),
        GoRoute(
          path: '/detail/:pathWord',
          name: AppRoutes.novelDetail,
          builder: (_, _) => const Scaffold(body: Text('详情目标')),
        ),
        GoRoute(
          path: '/shelf',
          name: AppRoutes.novelBookshelf,
          builder: (_, _) => const NovelBookshelfPage(),
        ),
        GoRoute(
          path: '/history',
          name: AppRoutes.novelHistory,
          builder: (_, _) => const NovelHistoryPage(),
        ),
        GoRoute(
          path: '/login',
          name: AppRoutes.login,
          builder: (_, state) {
            loginCopyOnly = state.uri.queryParameters['copyOnly'];
            return const Scaffold(body: Text('拷贝登录目标'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    addTearDown(user.dispose);
    addTearDown(downloads.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          novelApiProvider.overrideWithValue(api),
          novelRepositoryProvider.overrideWithValue(repository),
          novelDownloadManagerProvider.overrideWithValue(downloads),
          novelShelfRepoProvider.overrideWithValue(shelfRepository),
          novelReadingStoreProvider.overrideWithValue(store),
          userManagerProvider.overrideWithValue(user),
          commentSettingsProvider.overrideWithValue(CommentSettings()),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pump();
    if (pushPage) {
      unawaited(router.push<void>('/test-page'));
      await tester.pump();
    }
  }
}

Future<void> _tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('首页排序竞态：旧页响应不能覆盖新排序', (tester) async {
    final h = _Harness();
    final old = Completer<NovelPage<NovelBook>>();
    final latest = Completer<NovelPage<NovelBook>>();
    h.api.books = (_, ordering, _) =>
        ordering == '-popular' ? old.future : latest.future;
    await h.pump(tester, const NovelHomePage());
    await tester.tap(find.text('更新'));
    await tester.pump();
    latest.complete(_page([const NovelBook(pathWord: 'new', name: '新的结果')]));
    await tester.pumpAndSettle();
    old.complete(_page([const NovelBook(pathWord: 'old', name: '旧的结果')]));
    await tester.pumpAndSettle();
    expect(find.text('新的结果'), findsOneWidget);
    expect(find.text('旧的结果'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('轻小说入口：题材失败重试后显示空态', (tester) async {
    final h = _Harness();
    h.api.books = (_, _, _) async => throw const NovelApiException('offline');
    await h.pump(tester, const NovelHomePage());
    await tester.pumpAndSettle();
    expect(find.text('书籍加载失败'), findsOneWidget);
    h.api.books = (_, _, _) async => _page<NovelBook>([]);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('暂无书籍，试试其他题材'), findsOneWidget);
  });

  testWidgets('轻小说入口：关键字搜索用 COPY 关键词接口并展示结果', (tester) async {
    final h = _Harness();
    h.api.books = (_, _, _) async => _page([_book]);
    h.api.search = (_, _) async =>
        _page([const NovelBook(pathWord: 'hit', name: '搜索命中')]);
    await h.pump(tester, const NovelHomePage());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '败犬');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('搜索命中'), findsOneWidget);
    expect(h.api.searchKeywords, ['败犬']);
    expect(h.repository.detailCalls, 0);
    expect(h.api.queryCalls, 0);
  });

  testWidgets('轻小说入口：清空关键词后回到题材浏览列表', (tester) async {
    final h = _Harness();
    h.api.books = (_, _, _) async => _page([_book]);
    h.api.search = (_, _) async =>
        _page([const NovelBook(pathWord: 'hit', name: '搜索命中')]);
    await h.pump(tester, const NovelHomePage());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '败犬');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('搜索命中'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.clear).first);
    await tester.pumpAndSettle();
    expect(find.text('测试小说'), findsOneWidget);
    expect(find.text('搜索命中'), findsNothing);
  });

  testWidgets('详情继续阅读优先本地卷而非远端或首卷', (tester) async {
    final h = _Harness();
    h.store.items = [_Progress()];
    h.api.query = () async => const NovelQuery(browse: _remote);
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(h.readerVolume, 'local-volume');
    expect(h.readerExtra?.entryIndex, 7);
    expect(h.readerExtra?.resume, isTrue);
  });

  testWidgets('详情只保留分卷卡片，续读按钮只显示卷名与本卷百分比', (tester) async {
    final h = _Harness();
    h.store.items = [_Progress(chapterName: '第一卷 特典')];
    h.repository.detail = () async =>
        const NovelDetail(book: _book, isLocked: true);
    h.api.query = () async => const NovelQuery(isLocked: true, browse: _remote);
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();

    expect(find.textContaining('当前内容受限'), findsNothing);
    expect(find.textContaining('阅读权限由拷贝账户决定'), findsNothing);
    expect(find.text('分卷目录'), findsNothing);
    expect(find.text('本地小说'), findsNothing);
    final card = find.widgetWithText(ChapterCard, '第一卷');
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.byType(Text)),
      findsOneWidget,
    );
    final fab = find.byType(FloatingActionButton);
    // 按钮不显示「继续阅读」与章节名，单行显示「卷名 · 百分比」（无「本卷」前缀）。
    expect(find.descendant(of: fab, matching: find.text('继续阅读')), findsNothing);
    expect(
      find.descendant(of: fab, matching: find.text('第一卷 特典')),
      findsNothing,
    );
    expect(
      find.descendant(of: fab, matching: find.text('本地卷 · 42.00%')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: fab, matching: find.textContaining('本卷')),
      findsNothing,
    );
    // label 是单个 Text，即单行布局。
    expect(
      find.descendant(of: fab, matching: find.byType(Text)),
      findsOneWidget,
    );
    // 图标与漫画详情页续读按钮一致。
    expect(
      find.descendant(of: fab, matching: find.byIcon(Icons.play_arrow)),
      findsOneWidget,
    );
    expect(h.repository.detailCalls, 1);
    expect(h.api.queryCalls, 1);
  });

  testWidgets('续读不把包含插图的目录索引当章节编号，旧进度缺百分比不虚报', (tester) async {
    final h = _Harness();
    h.store.items = [_Progress(chapterName: '', progress: 0)];
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();
    final fab = find.byType(FloatingActionButton);
    expect(
      find.descendant(of: fab, matching: find.text('本地卷')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: fab, matching: find.textContaining('%')),
      findsNothing,
    );
    expect(find.textContaining('第8章'), findsNothing);
  });

  for (final value in [0.999, 1.0]) {
    testWidgets('本卷进度 $value 不提前显示读完', (tester) async {
      final h = _Harness();
      h.store.items = [_Progress(progress: value)];
      await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
      await tester.pumpAndSettle();
      final progress = find.descendant(
        of: find.byType(FloatingActionButton),
        matching: find.textContaining(value == 1 ? '· 100.00%' : '· 99.9'),
      );
      expect(progress, findsOneWidget);
    });
  }

  testWidgets('仅有远端续读时显示远端卷名、不伪造百分比', (tester) async {
    final h = _Harness();
    h.api.query = () async => const NovelQuery(browse: _remote);
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();
    final fab = find.byType(FloatingActionButton);
    expect(
      find.descendant(of: fab, matching: find.text('远端卷')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: fab, matching: find.textContaining('%')),
      findsNothing,
    );
  });

  testWidgets('阅读器返回后续读卷名和百分比更新', (tester) async {
    final h = _Harness();
    h.store.items = [_Progress()];
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    h.store.items = [_Progress(volumeName: '第四卷', progress: 0.75)];
    h.router.pop();
    await tester.pumpAndSettle();
    final fab = find.byType(FloatingActionButton);
    expect(
      find.descendant(of: fab, matching: find.text('第四卷 · 75.00%')),
      findsOneWidget,
    );
  });

  testWidgets('详情长章节在窄屏大字体仍显示百分比且无溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = _Harness();
    h.store.items = [_Progress(chapterName: '第三章 ${'很长的章节名称' * 15}')];
    await h.pump(
      tester,
      const NovelDetailPage(pathWord: 'book'),
      textScale: 2,
      dark: true,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final fab = find.byType(FloatingActionButton);
    final percent = find.descendant(
      of: fab,
      matching: find.textContaining('42.00%'),
    );
    expect(percent, findsOneWidget);
    expect(tester.getRect(fab).left, greaterThanOrEqualTo(0));
    expect(tester.getRect(fab).right, lessThanOrEqualTo(320));
    expect(
      tester.getRect(percent).right,
      lessThanOrEqualTo(tester.getRect(fab).right),
    );
    expect(tester.getRect(fab).bottom, lessThanOrEqualTo(720));
  });

  testWidgets('横屏长章节续读按钮不遮挡左栏操作', (tester) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = _Harness();
    h.store.items = [_Progress(chapterName: '第三章 ${'很长的章节名称' * 15}')];
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();
    final fab = tester.getRect(find.byType(FloatingActionButton));
    expect(fab.left, greaterThanOrEqualTo(317));
    expect(fab.right, lessThanOrEqualTo(624));
    final left = find.byType(CustomScrollView).first;
    await tester.drag(left, const Offset(0, -1200));
    await tester.pumpAndSettle();
    final comments = find.widgetWithText(FilledButton, '评论');
    expect(comments.hitTestable(), findsOneWidget);
    expect(tester.getRect(comments).overlaps(fab), isFalse);
    await tester.tap(comments);
    await tester.pumpAndSettle();
    expect(find.byType(NovelCommentsSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手动选卷从卷首开始，不沿用其他卷进度', (tester) async {
    final h = _Harness();
    h.store.items = [_Progress()];
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(ChapterCard, '第一卷'));
    await tester.tap(find.widgetWithText(ChapterCard, '第一卷'));
    await tester.pumpAndSettle();
    expect(h.readerVolume, 'first');
    expect(h.readerExtra?.entryIndex, 0);
    expect(h.readerExtra?.resume, isFalse);
  });

  testWidgets('详情卷卡长按进入多选，可全选后取消部分卷', (tester) async {
    final h = _Harness();
    h.repository.volumes = const [_first, _second];
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();

    final firstCard = find.widgetWithText(ChapterCard, '第一卷');
    await tester.ensureVisible(firstCard);
    await tester.longPress(firstCard);
    await tester.pumpAndSettle();
    expect(find.text('已选 1 卷'), findsOneWidget);

    await tester.ensureVisible(find.text('全选'));
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 卷'), findsOneWidget);
    expect(
      tester
          .widgetList<ChapterCard>(find.byType(ChapterCard))
          .where((card) => card.isSelected)
          .map((card) => card.name),
      unorderedEquals(['第一卷', '第二卷']),
    );

    await tester.ensureVisible(firstCard);
    await tester.tap(firstCard);
    await tester.pumpAndSettle();
    expect(find.text('已选 1 卷'), findsOneWidget);
    expect(
      tester
          .widgetList<ChapterCard>(find.byType(ChapterCard))
          .where((card) => card.isSelected)
          .map((card) => card.name),
      ['第二卷'],
    );

    await tester.ensureVisible(find.byTooltip('取消'));
    await tester.tap(find.byTooltip('取消'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 卷'), findsNothing);
    expect(h.downloads.enqueueCalls, isEmpty);
    expect(h.readerVolume, isNull);
  });

  testWidgets('下载入口仅进入空选择，确认只提交手动选中的卷', (tester) async {
    final h = _Harness();
    h.repository.volumes = const [_first, _second, _third];
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();

    final download = find.widgetWithText(FilledButton, '下载');
    await _tapAndSettle(tester, download);
    expect(h.downloads.enqueueCalls, isEmpty);
    expect(find.text('已选 0 卷'), findsOneWidget);
    expect(tester.widget<FilledButton>(download).onPressed, isNull);
    expect(
      tester
          .widgetList<ChapterCard>(find.byType(ChapterCard))
          .where((card) => card.isSelected),
      isEmpty,
    );

    await _tapAndSettle(tester, find.widgetWithText(ChapterCard, '第二卷'));
    expect(find.text('已选 1 卷'), findsOneWidget);
    expect(h.downloads.enqueueCalls, isEmpty);
    expect(h.readerVolume, isNull);
    await _tapAndSettle(tester, download);

    expect(h.downloads.enqueueCalls, hasLength(1));
    final call = h.downloads.enqueueCalls.single;
    expect(call.book, _book);
    expect(call.volumes, [_first, _second, _third]);
    expect(call.selected, [_second]);
    expect(h.downloads.tasks.map((task) => task.volumeId), ['second']);
    expect(find.text('已选 1 卷'), findsNothing);
    expect(find.widgetWithText(FilledButton, '取消'), findsNothing);
    expect(
      tester
          .widgetList<ChapterCard>(find.byType(ChapterCard))
          .where((card) => card.isSelected),
      isEmpty,
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('手动清空或再次全选后保持零选择，确认禁用且不下载', (tester) async {
    final h = _Harness();
    h.repository.volumes = const [_first, _second];
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();
    final download = find.widgetWithText(FilledButton, '下载');
    final first = find.widgetWithText(ChapterCard, '第一卷');
    await _tapAndSettle(tester, download);
    await _tapAndSettle(tester, download);
    expect(h.downloads.enqueueCalls, isEmpty);

    await _tapAndSettle(tester, first);
    await _tapAndSettle(tester, first);
    expect(find.text('已选 0 卷'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '取消'), findsOneWidget);
    expect(tester.widget<FilledButton>(download).onPressed, isNull);
    await _tapAndSettle(tester, download);

    await _tapAndSettle(tester, find.text('全选'));
    expect(find.text('已选 2 卷'), findsOneWidget);
    await _tapAndSettle(tester, find.text('全选'));
    expect(find.text('已选 0 卷'), findsOneWidget);
    expect(tester.widget<FilledButton>(download).onPressed, isNull);
    await _tapAndSettle(tester, download);
    expect(h.downloads.enqueueCalls, isEmpty);
    expect(h.readerVolume, isNull);
  });

  for (final toolbarCancel in [false, true]) {
    testWidgets('${toolbarCancel ? '工具条' : '主按钮'}取消清空选择且不入队', (tester) async {
      final h = _Harness();
      await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
      await tester.pumpAndSettle();
      final download = find.widgetWithText(FilledButton, '下载');
      await _tapAndSettle(tester, download);
      await _tapAndSettle(tester, find.widgetWithText(ChapterCard, '第一卷'));
      expect(find.text('已选 1 卷'), findsOneWidget);

      await _tapAndSettle(
        tester,
        toolbarCancel
            ? find.byTooltip('取消')
            : find.widgetWithText(FilledButton, '取消'),
      );
      expect(find.text('已选 1 卷'), findsNothing);
      expect(
        tester.widget<ChapterCard>(find.byType(ChapterCard)).isSelected,
        isFalse,
      );
      await _tapAndSettle(tester, download);
      expect(find.text('已选 0 卷'), findsOneWidget);
      expect(h.downloads.enqueueCalls, isEmpty);
      expect(h.readerVolume, isNull);
    });
  }

  for (final systemBack in [false, true]) {
    testWidgets('未确认时${systemBack ? '系统返回' : '顶部返回'}不触发下载', (tester) async {
      final h = _Harness();
      await h.pump(
        tester,
        const NovelDetailPage(pathWord: 'book'),
        pushPage: true,
      );
      await tester.pumpAndSettle();
      await _tapAndSettle(tester, find.widgetWithText(FilledButton, '下载'));
      await _tapAndSettle(tester, find.widgetWithText(ChapterCard, '第一卷'));
      expect(find.text('已选 1 卷'), findsOneWidget);
      if (systemBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.byType(BackButton));
      }
      await tester.pumpAndSettle();
      expect(find.text('返回目标'), findsOneWidget);
      expect(find.byType(NovelDetailPage), findsNothing);
      expect(h.downloads.enqueueCalls, isEmpty);
      expect(h.readerVolume, isNull);
    });
  }

  testWidgets('下载确认防重入，入队等待期间禁用确认与选卷', (tester) async {
    final h = _Harness();
    h.repository.volumes = const [_first, _second];
    final pending = Completer<void>();
    h.downloads.enqueue = () => pending.future;
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();
    final download = find.widgetWithText(FilledButton, '下载');
    await _tapAndSettle(tester, download);
    await _tapAndSettle(tester, find.widgetWithText(ChapterCard, '第一卷'));
    await tester.ensureVisible(download);
    // 故意不 pump：第二次点击仍命中上一帧的可用按钮，验证方法内的防重入。
    await tester.tap(download);
    await tester.tap(download);
    await tester.pumpAndSettle();
    expect(h.downloads.enqueueCalls, hasLength(1));
    expect(tester.widget<FilledButton>(download).onPressed, isNull);
    for (final card in tester.widgetList<ChapterCard>(
      find.byType(ChapterCard),
    )) {
      expect(card.onTap, isNull);
      expect(card.onLongPress, isNull);
    }
    await _tapAndSettle(tester, download);
    expect(h.downloads.enqueueCalls, hasLength(1));
    pending.complete();
    await tester.pumpAndSettle();
    expect(h.downloads.enqueueCalls.single.selected, [_first]);
    expect(h.downloads.tasks.map((task) => task.volumeId), ['first']);
    expect(find.widgetWithText(FilledButton, '取消'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  for (final status in [
    NovelDownloadStatus.queued,
    NovelDownloadStatus.downloading,
    NovelDownloadStatus.paused,
  ]) {
    testWidgets('已下载与${status.name}卷不可选，全选只提交剩余卷', (tester) async {
      final h = _Harness();
      h.repository.volumes = const [_first, _second, _third];
      h.downloads.saveLocal(_first);
      h.downloads.queue(_second, status: status);
      await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
      await tester.pumpAndSettle();
      final download = find.widgetWithText(FilledButton, '下载');
      await _tapAndSettle(tester, download);
      for (final name in ['第一卷', '第二卷']) {
        final finder = find.widgetWithText(ChapterCard, name);
        final card = tester.widget<ChapterCard>(finder);
        expect(card.isSelected, isFalse);
        expect(card.onTap, isNull);
        expect(card.onLongPress, isNull);
        await _tapAndSettle(tester, finder);
      }
      expect(find.text('已选 0 卷'), findsOneWidget);
      expect(h.readerVolume, isNull);
      expect(h.downloads.enqueueCalls, isEmpty);
      await _tapAndSettle(tester, find.text('全选'));
      expect(find.text('已选 1 卷'), findsOneWidget);
      expect(
        tester
            .widgetList<ChapterCard>(find.byType(ChapterCard))
            .where((card) => card.isSelected)
            .map((card) => card.name),
        ['第三卷'],
      );
      await _tapAndSettle(tester, download);
      expect(h.downloads.enqueueCalls, hasLength(1));
      expect(h.downloads.enqueueCalls.single.selected, [_third]);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('目录刷新移除已选卷时同步清空计数并禁用确认', (tester) async {
    final h = _Harness();
    h.repository.volumes = const [_first, _second];
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();
    final download = find.widgetWithText(FilledButton, '下载');
    await _tapAndSettle(tester, download);
    await _tapAndSettle(tester, find.widgetWithText(ChapterCard, '第一卷'));
    expect(find.text('已选 1 卷'), findsOneWidget);

    h.repository.volumes = const [_second];
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator).first)
        .onRefresh();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChapterCard, '第一卷'), findsNothing);
    expect(find.text('已选 0 卷'), findsOneWidget);
    expect(tester.widget<FilledButton>(download).onPressed, isNull);
    await _tapAndSettle(tester, download);
    expect(h.downloads.enqueueCalls, isEmpty);
  });

  testWidgets('选中卷变为排队或已下载时移除勾选，零选择仍可取消', (tester) async {
    final h = _Harness();
    h.repository.volumes = const [_first, _second];
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();
    final download = find.widgetWithText(FilledButton, '下载');
    await _tapAndSettle(tester, download);
    await _tapAndSettle(tester, find.text('全选'));
    expect(find.text('已选 2 卷'), findsOneWidget);
    h.downloads.queue(_first);
    await tester.pumpAndSettle();
    expect(find.text('已选 1 卷'), findsOneWidget);
    h.downloads.saveLocal(_second);
    await tester.pumpAndSettle();
    expect(find.text('已选 0 卷'), findsOneWidget);
    expect(tester.widget<FilledButton>(download).onPressed, isNull);
    expect(
      tester
          .widgetList<ChapterCard>(find.byType(ChapterCard))
          .where((card) => card.isSelected),
      isEmpty,
    );
    await _tapAndSettle(tester, find.widgetWithText(FilledButton, '取消'));
    expect(find.text('已选 0 卷'), findsNothing);
    expect(tester.widget<FilledButton>(download).onPressed, isNull);
    expect(h.downloads.enqueueCalls, isEmpty);
  });

  for (final status in [
    NovelDownloadStatus.completed,
    NovelDownloadStatus.needsRepair,
  ]) {
    testWidgets('本地${status.name}卷无任务仍显示下载中心，位于续读上方并跳转轻小说页签', (tester) async {
      final h = _Harness();
      h.downloads.saveLocal(_first, status: status);
      await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
      await tester.pumpAndSettle();
      expect(h.downloads.tasks, isEmpty);
      final center = find.widgetWithIcon(
        FloatingActionButton,
        Icons.download_for_offline,
      );
      final read = find.widgetWithIcon(FloatingActionButton, Icons.play_arrow);
      expect(center, findsOneWidget);
      expect(find.byTooltip('下载中心'), findsOneWidget);
      expect(tester.getRect(center).right, tester.getRect(read).right);
      expect(
        tester.getRect(center).bottom,
        lessThanOrEqualTo(tester.getRect(read).top - 12),
      );
      await _tapAndSettle(tester, center);
      expect(find.text('下载中心目标'), findsOneWidget);
      expect(h.downloadTab, '1');
      expect(h.downloads.enqueueCalls, isEmpty);
      // 下载中心删除本地卷后返回，入口同步消失。
      h.downloads.localStatuses.remove('book');
      h.router.pop();
      await tester.pumpAndSettle();
      expect(center, findsNothing);
    });
  }

  testWidgets('无本书本地卷或任务时隐藏入口，仅本书任务也可打开队列页签', (tester) async {
    final h = _Harness();
    h.downloads.saveLocal(_first, pathWord: 'other');
    h.downloads.queue(
      _second,
      book: const NovelBook(pathWord: 'other', name: '其他小说'),
    );
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();
    final center = find.byTooltip('下载中心');
    expect(center, findsNothing);
    // 即使不是活跃任务，只要本书还有任务就需要管理入口。
    h.downloads.queue(_first, status: NovelDownloadStatus.failed);
    await tester.pumpAndSettle();
    expect(h.downloads.localVolumeIds('book'), isEmpty);
    expect(center, findsOneWidget);
    await _tapAndSettle(tester, center);
    expect(find.text('下载中心目标'), findsOneWidget);
    expect(h.downloadTab, '2');
    expect(h.downloads.enqueueCalls, isEmpty);
  });

  for (final remote in [true, false]) {
    testWidgets('无本地记录时${remote ? '使用远端卷ID' : '回退首卷'}', (tester) async {
      final h = _Harness();
      h.api.query = () async => NovelQuery(browse: remote ? _remote : null);
      await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(h.readerVolume, remote ? 'remote' : 'first');
      expect(h.readerExtra?.entryIndex, 0);
    });
  }

  testWidgets('详情失败仍可通过本地记录续读', (tester) async {
    final h = _Harness();
    h.store.items = [_Progress()];
    h.repository.detail = () async => throw const NovelApiException('offline');
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();
    expect(find.text('书籍加载失败'), findsOneWidget);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(h.readerVolume, 'local-volume');
  });

  testWidgets('收藏状态未知时点收藏只重试查询，不伪断言也不发收藏请求', (tester) async {
    final h = _Harness();
    h.user.switchAccount('copy-a');
    h.api.query = () async => throw const NovelApiException('offline');
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();
    // 与漫画详情页同一套文案：只有「收藏 / 已收藏」两态，
    // 状态未知既不能说已收藏，也不该暴露第三方文案。
    expect(find.text('已收藏'), findsNothing);
    expect(find.text('收藏'), findsOneWidget);

    // 状态未知时点击只重试查询，不发收藏请求。
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(h.api.collections, isEmpty);

    h.api.query = () async => const NovelQuery(isLoggedIn: true, collect: 9876);
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(find.text('已收藏'), findsOneWidget);
    expect(h.api.collections, isEmpty);

    // 状态已知后才真正发取消收藏请求。
    await tester.tap(find.text('已收藏'));
    await tester.pumpAndSettle();
    expect(h.api.collections, [('book-uuid', false)]);
    expect(find.text('收藏'), findsOneWidget);
  });

  testWidgets('仅热辣登录不请求拷贝书架，入口指定copyOnly', (tester) async {
    final h = _Harness();
    h.user.hotLoggedIn = true;
    await h.pump(tester, const NovelBookshelfPage());
    await tester.pumpAndSettle();
    expect(h.api.shelfCalls, 0);
    await tester.tap(find.text('登录拷贝账户'));
    await tester.pumpAndSettle();
    expect(h.loginCopyOnly, 'true');
  });

  testWidgets('切换拷贝账户丢弃旧书架响应，登出立即清空', (tester) async {
    final h = _Harness();
    final old = Completer<NovelPage<NovelShelfEntry>>();
    final next = Completer<NovelPage<NovelShelfEntry>>();
    h.user.switchAccount('copy-a');
    h.api.shelf = (_) =>
        h.user.copyToken == 'copy-a' ? old.future : next.future;
    await h.pump(tester, const NovelBookshelfPage());
    h.user.switchAccount('copy-b');
    await tester.pump();
    next.complete(
      _page([
        const NovelShelfEntry(
          uuid: 2,
          book: NovelBook(pathWord: 'new', name: '乙的书架'),
        ),
      ]),
    );
    old.complete(
      _page([
        const NovelShelfEntry(
          uuid: 1,
          book: NovelBook(pathWord: 'old', name: '甲的书架'),
        ),
      ]),
    );
    // 骨架 shimmer 是无限动画，数据未就绪时 pumpAndSettle 不会结束。
    for (
      var frame = 0;
      frame < 40 && find.text('乙的书架').evaluate().isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('乙的书架'), findsOneWidget);
    expect(find.text('甲的书架'), findsNothing);
    h.user.switchAccount(null);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('乙的书架'), findsNothing);
    expect(find.text('登录拷贝账户'), findsOneWidget);
  });

  testWidgets('阅读记录直接续读并支持移除，无API调用', (tester) async {
    final h = _Harness();
    h.store.items = [_Progress()];
    await h.pump(tester, const NovelHistoryPage());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('novel_history_book')));
    await tester.pumpAndSettle();
    expect(h.readerVolume, 'local-volume');
    expect(h.readerExtra?.entryIndex, 7);
    h.router.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('novel_history_actions_book')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除阅读记录'));
    await tester.pumpAndSettle();
    expect(find.text('开始阅读后，进度会保存在这里'), findsOneWidget);
    expect(h.api.bookCalls + h.api.queryCalls + h.api.shelfCalls, 0);
  });

  for (final status in NovelDownloadStatus.values) {
    testWidgets('卷卡仅下载中显示进度，$status 不误用完成记录', (tester) async {
      final h = _Harness();
      h.downloads.queue(_first, status: status);
      final task = h.downloads.tasks.single
        ..completed = 2
        ..total = 3;
      if (status == NovelDownloadStatus.completed) {
        task.completed = 3;
        h.downloads.saveLocal(_first);
      }
      await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
      await tester.pumpAndSettle();
      final cardFinder = find.widgetWithText(ChapterCard, '第一卷');
      final card = tester.widget<ChapterCard>(cardFinder);
      final downloading = status == NovelDownloadStatus.downloading;
      expect(card.progressRatio, downloading ? closeTo(2 / 3, 0.001) : isNull);
      expect(card.subtitle, downloading ? '2/3' : isNull);
      expect(
        find.descendant(
          of: cardFinder,
          matching: find.byType(LinearProgressIndicator),
        ),
        downloading ? findsOneWidget : findsNothing,
      );
      expect(card.isDownloaded, status == NovelDownloadStatus.completed);
    });
  }

  testWidgets('完成自动离队后卷卡保留已下载标记且无进度条', (tester) async {
    final h = _Harness();
    h.downloads.queue(_first, status: NovelDownloadStatus.downloading);
    h.downloads.tasks.single
      ..completed = 1
      ..total = 3;
    await h.pump(tester, const NovelDetailPage(pathWord: 'book'));
    await tester.pumpAndSettle();
    final cardFinder = find.widgetWithText(ChapterCard, '第一卷');
    expect(tester.widget<ChapterCard>(cardFinder).progressRatio, isNotNull);
    h.downloads.tasks.clear();
    h.downloads.saveLocal(_first);
    await tester.pumpAndSettle();
    final card = tester.widget<ChapterCard>(cardFinder);
    expect(card.isDownloaded, isTrue);
    expect(card.progressRatio, isNull);
    expect(card.subtitle, isNull);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byTooltip('下载中心'), findsOneWidget);
  });

  for (final longName in [false, true]) {
    testWidgets('评论时间位于作者行最右侧，长昵称=$longName', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.reset);
      final h = _Harness();
      final name = longName ? '这是一段很长很长的评论者昵称不能挤走时间' : '读者';
      h.api.comments = (_, _) async => _page([
        NovelComment(
          id: 'position',
          userName: name,
          comment: '时间右对齐',
          createAt: '2999-01-01 00:00:00',
        ),
      ]);
      await h.pump(
        tester,
        const Scaffold(
          body: NovelCommentsSheet(bookUuid: 'book-uuid', bookName: '测试小说'),
        ),
        textScale: longName ? 2 : 1,
      );
      await tester.pumpAndSettle();
      final time = find.text('刚刚');
      final row = find.ancestor(of: time, matching: find.byType(Row)).first;
      final timeRect = tester.getRect(time);
      expect(timeRect.right, closeTo(tester.getRect(row).right, 0.01));
      expect(timeRect.top, lessThan(tester.getRect(find.text('时间右对齐')).top));
      expect(tester.widget<Text>(find.text(name)).maxLines, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('评论首屏加载复用漫画六张详细骨架而非整块占位', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 1100);
    addTearDown(tester.view.reset);
    final h = _Harness();
    final response = Completer<NovelPage<NovelComment>>();
    h.api.comments = (_, _) => response.future;
    await h.pump(
      tester,
      const Scaffold(
        body: NovelCommentsSheet(bookUuid: 'book-uuid', bookName: '测试小说'),
      ),
    );
    await tester.pump();
    expect(find.byType(CommentSkeleton), findsNWidgets(6));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    response.complete(
      _page([const NovelComment(id: 'loaded', comment: '已加载')]),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CommentSkeleton), findsNothing);
    expect(find.text('已加载'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首次展开回复复用漫画回复骨架，成功后显示回复', (tester) async {
    final h = _Harness();
    final replies = Completer<NovelPage<NovelComment>>();
    h.api.comments = (replyId, _) => replyId == null
        ? Future.value(
            _page([const NovelComment(id: 'parent', comment: '楼主', count: 3)]),
          )
        : replies.future;
    await h.pump(
      tester,
      const Scaffold(
        body: NovelCommentsSheet(bookUuid: 'book-uuid', bookName: '测试小说'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('novel-comment-parent')),
        matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
      ),
    );
    await tester.pump();
    expect(find.byType(CommentReplySkeleton), findsNWidgets(3));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    replies.complete(
      _page([
        for (var i = 0; i < 3; i++)
          NovelComment(id: 'reply-$i', comment: '回复 $i'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CommentReplySkeleton), findsNothing);
    expect(find.text('回复 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('评论加载更多沿用漫画动态加载指示器并保留已有评论', (tester) async {
    final h = _Harness();
    final more = Completer<NovelPage<NovelComment>>();
    h.api.comments = (_, offset) => offset == 0
        ? Future.value(
            _page([
              for (var i = 0; i < 10; i++)
                NovelComment(id: 'c-$i', comment: '原评论 $i'),
            ], total: 11),
          )
        : more.future;
    await h.pump(
      tester,
      const Scaffold(
        body: NovelCommentsSheet(bookUuid: 'book-uuid', bookName: '测试小说'),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.api.commentCalls, 2);
    await tester.scrollUntilVisible(
      find.byType(ExpressiveLoadingIndicator),
      200,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 8,
    );
    expect(find.byType(ExpressiveLoadingIndicator), findsOneWidget);
    expect(find.byType(CommentSkeleton), findsNothing);
    expect(find.text('原评论 9'), findsOneWidget);
    more.complete(
      _page(
        [const NovelComment(id: 'last', comment: '新评论')],
        total: 11,
        offset: 10,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ExpressiveLoadingIndicator), findsNothing);
    expect(find.text('新评论'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final hotOnly in [false, true]) {
    testWidgets('${hotOnly ? '仅热辣登录' : '游客'}可看评论，只有发表需要拷贝登录', (tester) async {
      final h = _Harness();
      h.user.hotLoggedIn = hotOnly;
      h.api.comments = (_, _) async =>
          _page([const NovelComment(id: 'public', comment: '公开评论')]);
      await h.pump(
        tester,
        const Scaffold(
          body: NovelCommentsSheet(bookUuid: 'book-uuid', bookName: '测试小说'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('公开评论'), findsOneWidget);
      expect(h.api.commentCalls, 1);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('请先登录后再发表评论'), findsNothing);
      await tester.tap(find.byIcon(Icons.comment_outlined));
      await tester.pumpAndSettle();
      expect(h.loginCopyOnly, 'true');
      expect(h.api.postCalls, 0);
    });
  }

  testWidgets('游客评论加载失败可重试，不跳登录也不当作空评论', (tester) async {
    final h = _Harness();
    h.api.comments = (_, _) async => throw const NovelApiException('offline');
    await h.pump(
      tester,
      const Scaffold(
        body: NovelCommentsSheet(bookUuid: 'book-uuid', bookName: '测试小说'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('评论加载失败'), findsOneWidget);
    expect(find.text('暂无评论'), findsNothing);
    h.api.comments = (_, _) async =>
        _page([const NovelComment(id: 'public', comment: '恢复后的评论')]);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('恢复后的评论'), findsOneWidget);
    expect(h.loginCopyOnly, isNull);
  });

  testWidgets('退出账号仍加载游客评论，旧账号的迟到列表不能覆盖', (tester) async {
    final h = _Harness();
    final old = Completer<NovelPage<NovelComment>>();
    h.user.switchAccount('copy-a');
    h.api.comments = (_, _) => h.user.isCopyLoggedIn
        ? old.future
        : Future.value(
            _page([const NovelComment(id: 'public', comment: '游客列表')]),
          );
    await h.pump(
      tester,
      const Scaffold(
        body: NovelCommentsSheet(bookUuid: 'book-uuid', bookName: '测试小说'),
      ),
    );
    await tester.tap(find.byIcon(Icons.comment_outlined));
    // 首屏仍在加载，不能等待无限循环的骨架动画。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), '旧账号草稿');
    h.user.switchAccount(null);
    await tester.pumpAndSettle();
    expect(find.text('游客列表'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    old.complete(_page([const NovelComment(id: 'private', comment: '过期列表')]));
    await tester.pumpAndSettle();
    expect(find.text('过期列表'), findsNothing);
    expect(find.text('游客列表'), findsOneWidget);
    h.api.comments = (_, _) async => _page<NovelComment>([]);
    h.user.switchAccount('copy-b');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.comment_outlined));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
    expect(h.api.postCalls, 0);
  });

  testWidgets('游客仍可查看已关闭评论书籍的历史评论', (tester) async {
    final h = _Harness();
    h.api.comments = (_, _) async =>
        _page([const NovelComment(id: 'public', comment: '历史评论')]);
    await h.pump(
      tester,
      const Scaffold(
        body: NovelCommentsSheet(
          bookUuid: 'book-uuid',
          bookName: '测试小说',
          allowPosting: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('历史评论'), findsOneWidget);
    final commentButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.byIcon(Icons.comment_outlined),
        matching: find.byType(FilledButton),
      ),
    );
    expect(commentButton.onPressed, isNull);
    expect(find.text('请先登录后再发表评论'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(h.api.postCalls, 0);
  });

  testWidgets('评论发送失败保留草稿，重试成功并刷新', (tester) async {
    final h = _Harness();
    h.user.switchAccount('copy-a');
    var attempts = 0;
    h.api.post = (content) async {
      expect(content, '离线评论');
      if (++attempts == 1) throw const NovelApiException('offline');
    };
    await h.pump(
      tester,
      const Scaffold(
        body: NovelCommentsSheet(bookUuid: 'book-uuid', bookName: '测试小说'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byIcon(Icons.comment_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '离线评论');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('novel-comment-submit')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '离线评论',
    );
    expect(h.api.commentCalls, 1);
    await tester.tap(find.byKey(const ValueKey('novel-comment-submit')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(attempts, 2);
    expect(h.api.commentCalls, 2);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('分页去重仍按原始条目数量推进offset', (tester) async {
    final offsets = <int>[];
    final controller = NovelPagedController<NovelBook>(
      keyOf: (book) => book.pathWord,
      loadPage: (offset) async {
        offsets.add(offset);
        return offset == 0
            ? _page([_book, _book], total: 3)
            : _page(
                [const NovelBook(pathWord: 'next', name: '下一页')],
                total: 3,
                offset: offset,
              );
      },
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: controller,
          builder: (_, _) => Text('${controller.items.length}'),
        ),
      ),
    );
    unawaited(controller.refresh());
    await tester.pump();
    expect(controller.items.length, 1);
    unawaited(controller.loadMore());
    await tester.pump();
    expect(offsets, [0, 2]);
    expect(controller.items.length, 2);
    expect(controller.hasMore, isFalse);
  });

  testWidgets('刷新后忽略旧的加载更多失败，不污染当前页', (tester) async {
    final old = Completer<NovelPage<NovelBook>>();
    var fresh = false;
    final controller = NovelPagedController<NovelBook>(
      keyOf: (book) => book.pathWord,
      loadPage: (offset) async {
        if (offset > 0) return old.future;
        return fresh
            ? _page([const NovelBook(pathWord: 'fresh', name: '新结果')])
            : _page([_book], total: 2);
      },
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: controller,
          builder: (_, _) => Text('${controller.items.length}'),
        ),
      ),
    );
    unawaited(controller.refresh());
    await tester.pump();
    unawaited(controller.loadMore());
    fresh = true;
    unawaited(controller.refresh());
    await tester.pump();
    old.completeError(const NovelApiException('old offline failure'));
    await tester.pumpAndSettle();
    expect(controller.items.single.pathWord, 'fresh');
    expect(controller.error, isNull);
    expect(controller.loading, isFalse);
  });

  for (final loggedIn in [false, true]) {
    testWidgets('${loggedIn ? '已登录' : '游客'}评论分页和回复使用真实父评论ID', (tester) async {
      final h = _Harness();
      if (loggedIn) h.user.switchAccount('copy-a');
      final requests = <(String?, int)>[];
      h.api.comments = (replyId, offset) async {
        requests.add((replyId, offset));
        if (replyId != null) {
          return _page([const NovelComment(id: 'reply', comment: '回复内容')]);
        }
        return offset == 0
            ? _page([
                const NovelComment(id: 'parent', comment: '首条评论', count: 1),
              ], total: 2)
            : _page(
                [const NovelComment(id: 'second', comment: '下一页评论')],
                total: 2,
                offset: offset,
              );
      };
      await h.pump(
        tester,
        const Scaffold(
          body: NovelCommentsSheet(bookUuid: 'book-uuid', bookName: '测试小说'),
        ),
      );
      await tester.pumpAndSettle();
      // 首屏不足一屏会自动分页，回复保留在原卡片内展开。
      expect(find.text('下一页评论'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
      await tester.tap(find.text('展开 1 条回复'));
      await tester.pumpAndSettle();
      expect(find.text('回复内容'), findsOneWidget);
      expect(requests, [(null, 0), (null, 1), ('parent', 0)]);
    });
  }

  testWidgets('清空记录需确认，取消不改变进度', (tester) async {
    final h = _Harness();
    h.store.items = [_Progress()];
    await h.pump(tester, const NovelHistoryPage());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('清空阅读记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(h.store.items, hasLength(1));
    await tester.tap(find.byTooltip('清空阅读记录'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(h.store.items, isEmpty);
    expect(find.text('开始阅读后，进度会保存在这里'), findsOneWidget);
  });

  testWidgets('窄屏深色大字号卡片与入口无溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = _Harness();
    h.store.items = [_Progress()];
    h.api.books = (_, _, _) async => _page([_book]);
    await h.pump(tester, const NovelHomePage(), textScale: 1.7, dark: true);
    await tester.pumpAndSettle();
    // 大字号下筛选行 + 卡片网格仍能排版，不出现溢出异常。
    expect(find.text('测试小说'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

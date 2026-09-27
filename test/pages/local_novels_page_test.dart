import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/models/novel_reading_progress.dart';
import 'package:kira/models/novel_volume_snapshot.dart';
import 'package:kira/pages/comic_detail_page.dart' show ChapterCard;
import 'package:kira/pages/local_novels_page.dart';
import 'package:kira/providers/novel_providers.dart';
import 'package:kira/routing/app_router.dart';
import 'package:kira/utils/novel_download_manager.dart';
import 'package:kira/utils/novel_download_store.dart';
import 'package:kira/utils/novel_reading_store.dart';
import 'package:kira/widgets/local_content_list_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/novel_download_store_test.dart'
    show downloadBook, downloadVolume;

const _secondVolume = NovelVolume(id: 'v2', name: '第二卷', bookPathWord: 'book');

/// 两卷都已完整下载，另有第三卷从未下载（不应出现在本地详情页）。
const _allVolumes = [
  downloadVolume,
  _secondVolume,
  NovelVolume(id: 'v3', name: '第三卷', bookPathWord: 'book'),
];

class _Fixture {
  _Fixture(this.root);

  final Directory root;
  late final NovelDownloadStore store = NovelDownloadStore.forTesting(
    rootDirectory: root,
  );
  late final NovelDownloadManager manager = NovelDownloadManager.forTesting(
    store: store,
    snapshotLoader: (path, id, {required cancelToken}) async =>
        throw StateError('unexpected network load'),
    imageLoader: (url, {required cancelToken}) async =>
        throw StateError('unexpected image load'),
    identityProvider: () => const NovelDownloadIdentity(host: 'copy.invalid'),
    protectedRoots: () async => [],
    defaultRoot: () async => root.path,
  );

  /// 真实文件 IO 要在 tester.runAsync 里跑：testWidgets 的 fake async 时钟
  /// 不会推进 dart:io 的完成回调，直接 await 会一直挂起。
  Future<void> seed(
    WidgetTester tester, {
    bool withCover = false,
    bool reverseDownloads = false,
  }) async {
    await tester.runAsync(
      () =>
          _seedInner(withCover: withCover, reverseDownloads: reverseDownloads),
    );
  }

  Future<void> _seedInner({
    required bool withCover,
    required bool reverseDownloads,
  }) async {
    await store.init();
    final downloaded = _allVolumes.take(2).toList();
    for (final volume in reverseDownloads ? downloaded.reversed : downloaded) {
      await store.saveSnapshot(
        book: downloadBook,
        volumes: _allVolumes,
        snapshot: NovelVolumeSnapshot(
          detail: NovelVolumeDetail(
            book: downloadBook,
            volume: NovelVolume(
              id: volume.id,
              name: volume.name,
              bookPathWord: volume.bookPathWord,
              // hasText 要求正文字段存在，否则快照会被判为无效。
              txtAddr: 'https://cdn.invalid/${volume.id}.txt',
              txtEncoding: 'utf-8',
              // 正文条目声明了行号区间，快照文本必须覆盖该区间。
              contents: const [
                NovelContentEntry(name: '正文', contentType: 1, endLines: 4),
              ],
            ),
          ),
          text: '\r\n${volume.name}正文\r\n\r\n结尾\r\n',
        ),
      );
    }
    if (withCover) {
      await store.saveCover('book', [1, 2, 3]);
    }
    // 管理器沿用同一个 store 实例，避免重复扫描磁盘。
    await manager.init();
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  required NovelDownloadManager manager,
  required Directory root,
  NovelReadingStore? readingStore,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => page),
      GoRoute(
        path: '/local-novel-detail/:pathWord',
        name: AppRoutes.localNovelDetail,
        builder: (_, state) =>
            LocalNovelDetailPage(pathWord: state.pathParameters['pathWord']!),
      ),
      GoRoute(
        path: '/reader/:pathWord/:volumeId',
        name: AppRoutes.novelReader,
        builder: (_, state) =>
            Scaffold(body: Text('阅读 ${state.pathParameters['volumeId']}')),
      ),
      GoRoute(
        path: '/novel/:pathWord',
        name: AppRoutes.novelDetail,
        builder: (_, _) => const Scaffold(body: Text('在线详情')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        novelDownloadManagerProvider.overrideWithValue(manager),
        novelDownloadStoreProvider.overrideWithValue(
          NovelDownloadStore.forTesting(rootDirectory: root),
        ),
        novelReadingStoreProvider.overrideWithValue(
          readingStore ?? NovelReadingStore(),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  // 加载中与骨架屏都是无限动画，pumpAndSettle 不会结束；推进固定帧数即可。
  await settleFrames(tester);
}

/// 推进若干帧直到界面稳定，避开无限动画导致的 pumpAndSettle 超时。
Future<void> settleFrames(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 让界面触发的真实磁盘写入跑完，再推进帧等 UI 更新。
/// testWidgets 的 fake async 不会交付 dart:io 完成事件，必须借 runAsync。
/// [until] 用于等到磁盘状态真正落地，避免固定轮数不够时断言过早。
Future<void> settleIo(
  WidgetTester tester, {
  bool Function()? until,
  int rounds = 12,
  bool pumpFirst = true,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (until != null && until()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    if (pumpFirst || i > 0) await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('local_novels_page');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  testWidgets('本地列表展示作者与已下载卷数', (tester) async {
    final fixture = _Fixture(root);
    await fixture.seed(tester, withCover: true);
    await _pump(
      tester,
      const LocalNovelsPage(),
      manager: fixture.manager,
      root: root,
    );

    expect(find.text('测试小说'), findsOneWidget);
    // 卡片显示已下载卷数，未下载的第三卷不计入。
    expect(find.text('已下载 2 卷'), findsOneWidget);
    expect(find.byType(LocalContentListPage), findsOneWidget);
  });

  testWidgets('空列表显示轻小说的空态而不是漫画文案', (tester) async {
    final fixture = _Fixture(root);
    await tester.runAsync(() => fixture.manager.init());
    await _pump(
      tester,
      const LocalNovelsPage(),
      manager: fixture.manager,
      root: root,
    );

    expect(find.text('还没有本地轻小说'), findsOneWidget);
    expect(find.textContaining('本地漫画'), findsNothing);
  });

  testWidgets('详情页只列可读分卷并可从卷卡继续阅读', (tester) async {
    final fixture = _Fixture(root);
    await fixture.seed(tester);
    await _pump(
      tester,
      const LocalNovelDetailPage(pathWord: 'book'),
      manager: fixture.manager,
      root: root,
    );

    final cards = tester.widgetList<ChapterCard>(find.byType(ChapterCard));
    expect(cards.map((card) => card.name), containsAll(['第一卷', '第二卷']));
    // 目录里存在但未下载的卷不出现在本地详情。
    expect(cards.map((card) => card.name), isNot(contains('第三卷')));

    await tester.tap(find.widgetWithText(ChapterCard, '第一卷'));
    await settleFrames(tester);
    expect(find.text('阅读 v1'), findsOneWidget);
  });

  testWidgets('分批逆序下载后默认按目录正序显示，仍可切换逆序', (tester) async {
    final fixture = _Fixture(root);
    await fixture.seed(tester, reverseDownloads: true);
    await _pump(
      tester,
      const LocalNovelDetailPage(pathWord: 'book'),
      manager: fixture.manager,
      root: root,
    );

    List<String> displayedNames() => tester
        .widgetList<ChapterCard>(find.byType(ChapterCard))
        .map((card) => card.name)
        .toList();

    expect(fixture.manager.localInfo('book')!.downloaded.keys, ['v2', 'v1']);
    expect(displayedNames(), ['第一卷', '第二卷']);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await settleFrames(tester);
    expect(displayedNames(), ['第二卷', '第一卷']);
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await settleFrames(tester);
    expect(displayedNames(), ['第一卷', '第二卷']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多选删除只移除所选分卷，取消不改变本地内容', (tester) async {
    final fixture = _Fixture(root);
    await fixture.seed(tester);
    await _pump(
      tester,
      const LocalNovelDetailPage(pathWord: 'book'),
      manager: fixture.manager,
      root: root,
    );

    await tester.tap(find.byTooltip('管理分卷'));
    await settleFrames(tester);
    await tester.tap(find.widgetWithText(ChapterCard, '第一卷'));
    await settleFrames(tester);
    expect(find.text('已选 1 卷'), findsOneWidget);

    await tester.tap(find.byTooltip('删除'));
    await settleFrames(tester);
    expect(find.textContaining('确定删除选中的 1 卷吗'), findsOneWidget);

    // 取消：内容保持不变。
    await tester.tap(find.text('取消'));
    await settleFrames(tester);
    expect(fixture.manager.localVolumeIds('book'), containsAll(['v1', 'v2']));

    await tester.tap(find.byTooltip('删除'));
    await settleFrames(tester);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    // 删除要落盘，且续接代码在真实 IO 之后：必须先把 IO 放完再推帧。
    await settleIo(tester, pumpFirst: false);

    // 删除的真实 IO 完成后，管理器与页面都只剩第二卷。
    // （提示条由删除续接代码弹出，其投递依赖 fake async 的收尾顺序，不作为断言。）
    await settleFrames(tester);
    expect(fixture.manager.localVolumeIds('book'), {'v2'});
    expect(find.widgetWithText(ChapterCard, '第一卷'), findsNothing);
    expect(find.widgetWithText(ChapterCard, '第二卷'), findsOneWidget);
  });

  testWidgets('删掉最后一卷后自动退出本地详情', (tester) async {
    final fixture = _Fixture(root);
    await fixture.seed(tester);
    await _pump(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => context.pushNamed(
                AppRoutes.localNovelDetail,
                pathParameters: {'pathWord': 'book'},
              ),
              child: const Text('打开详情'),
            ),
          ),
        ),
      ),
      manager: fixture.manager,
      root: root,
    );

    await tester.tap(find.text('打开详情'));
    await settleFrames(tester);
    expect(find.byType(LocalNovelDetailPage), findsOneWidget);

    await tester.runAsync(() => fixture.manager.deleteNovel('book'));
    await settleIo(
      tester,
      until: () => find.byType(LocalNovelDetailPage).evaluate().isEmpty,
    );

    expect(find.byType(LocalNovelDetailPage), findsNothing);
    expect(find.text('打开详情'), findsOneWidget);
  });

  testWidgets('本地阅读进度决定续读按钮指向的卷', (tester) async {
    final fixture = _Fixture(root);
    await fixture.seed(tester);
    final readingStore = NovelReadingStore();
    await readingStore.saveProgress(
      NovelReadingProgress(
        pathWord: 'book',
        name: '测试小说',
        cover: '',
        volumeId: 'v2',
        volumeName: '第二卷',
        chapterName: '第一章',
        updatedAt: DateTime.utc(2026, 9, 27),
        progress: 0.5,
      ),
    );
    await _pump(
      tester,
      const LocalNovelDetailPage(pathWord: 'book'),
      manager: fixture.manager,
      root: root,
      readingStore: readingStore,
    );

    final fab = find.byType(FloatingActionButton);
    expect(
      find.descendant(of: fab, matching: find.text('第二卷 · 50.00%')),
      findsOneWidget,
    );
    await tester.tap(fab);
    await settleFrames(tester);
    expect(find.text('阅读 v2'), findsOneWidget);
  });
}

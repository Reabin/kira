import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/download_center_page.dart';
import 'package:kira/pages/local_comics_page.dart';
import 'package:kira/pages/local_novels_page.dart';
import 'package:kira/providers/novel_providers.dart';
import 'package:kira/utils/download_manager.dart';
import 'package:kira/utils/novel_download_manager.dart';
import 'package:kira/widgets/select_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 只保存内存状态，不创建真实管理器、不读写磁盘或发起下载。
class _FakeComicDownloads extends ChangeNotifier implements DownloadManager {
  _FakeComicDownloads({
    List<ComicDownloadTaskInfo> tasks = const [],
    bool paused = false,
  }) : _tasks = [...tasks],
       _paused = paused;

  final List<ComicDownloadTaskInfo> _tasks;
  bool _paused;
  int pauseCalls = 0;
  int resumeCalls = 0;
  final deleted = <String>[];

  @override
  List<ComicDownloadTaskInfo> get tasks => [
    for (final task in _tasks)
      if (_paused)
        ComicDownloadTaskInfo(
          pathWord: task.pathWord,
          chapterUuid: task.chapterUuid,
          chapterName: task.chapterName,
          comicName: task.comicName,
          status: ComicDownloadTaskStatus.paused,
          progress: task.progress,
        )
      else
        task,
  ];

  @override
  bool get paused => _paused;

  @override
  DownloadBatchSummary? get lastBatchSummary => null;

  @override
  void pauseDownloads() {
    pauseCalls++;
    _paused = true;
    notifyListeners();
  }

  @override
  void resumeDownloads() {
    resumeCalls++;
    _paused = false;
    notifyListeners();
  }

  @override
  Future<void> deleteQueuedChapters(
    Iterable<({String pathWord, String chapterUuid})> keys, {
    void Function(int completed, int total)? onProgress,
  }) async {
    final entries = keys.toList();
    for (final (index, key) in entries.indexed) {
      deleted.add(key.chapterUuid);
      _tasks.removeWhere(
        (task) =>
            task.pathWord == key.pathWord &&
            task.chapterUuid == key.chapterUuid,
      );
      onProgress?.call(index + 1, entries.length);
    }
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected comic manager call: ${invocation.memberName}',
  );
}

class _FakeNovelDownloads extends ChangeNotifier
    implements NovelDownloadManager {
  _FakeNovelDownloads({
    List<NovelDownloadTask> tasks = const [],
    bool paused = false,
  }) : _tasks = [...tasks],
       _paused = paused {
    if (paused) {
      for (final task in _tasks) {
        task.status = NovelDownloadStatus.paused;
      }
    }
  }

  final List<NovelDownloadTask> _tasks;
  bool _paused;
  int pauseCalls = 0;
  int resumeCalls = 0;
  final deleted = <String>[];

  @override
  List<NovelDownloadTask> get tasks => List.unmodifiable(_tasks);

  @override
  bool get paused => _paused;

  @override
  List<LocalNovelInfo> get localNovels => const [];

  @override
  Future<void> init() async {}

  @override
  Future<void> pauseDownloads() async {
    pauseCalls++;
    _paused = true;
    for (final task in _tasks) {
      task.status = NovelDownloadStatus.paused;
    }
    notifyListeners();
  }

  @override
  Future<void> resumeDownloads() async {
    resumeCalls++;
    _paused = false;
    for (final task in _tasks) {
      if (task.status == NovelDownloadStatus.paused) {
        task.status = NovelDownloadStatus.queued;
      }
    }
    notifyListeners();
  }

  @override
  Future<void> deleteVolume(String pathWord, String volumeId) async {
    deleted.add(volumeId);
    _tasks.removeWhere(
      (task) => task.pathWord == pathWord && task.volumeId == volumeId,
    );
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected novel manager call: ${invocation.memberName}',
  );
}

ComicDownloadTaskInfo _comicTask(String id, ComicDownloadTaskStatus status) =>
    ComicDownloadTaskInfo(
      pathWord: 'comic-book',
      chapterUuid: id,
      chapterName: '漫画-$id',
      comicName: '测试漫画',
      status: status,
    );

NovelDownloadTask _novelTask(String id, NovelDownloadStatus status) {
  final volume = NovelVolume(
    id: id,
    name: '小说-$id',
    bookPathWord: 'novel-book',
  );
  return NovelDownloadTask(
    book: const NovelBook(pathWord: 'novel-book', name: '测试小说'),
    volume: volume,
    volumes: [volume],
    source: const NovelDownloadIdentity(host: 'copy.invalid'),
    status: status,
  );
}

_FakeComicDownloads _mixedComics() => _FakeComicDownloads(
  tasks: [
    _comicTask('active', ComicDownloadTaskStatus.downloading),
    _comicTask('waiting', ComicDownloadTaskStatus.pending),
    _comicTask('paused', ComicDownloadTaskStatus.paused),
  ],
);

_FakeNovelDownloads _mixedNovels() => _FakeNovelDownloads(
  tasks: [
    _novelTask('active', NovelDownloadStatus.downloading),
    _novelTask('waiting', NovelDownloadStatus.queued),
    _novelTask('paused', NovelDownloadStatus.paused),
  ],
);

Finder get _filter => find.byKey(const ValueKey('download_queue_filter'));
Finder get _pause => find.byKey(const ValueKey('download_queue_pause'));
Finder get _selectAll =>
    find.byKey(const ValueKey('download_queue_select_all'));

// 下载中的漫画卡有无限进度动画，不使用 pumpAndSettle。
Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required _FakeComicDownloads comics,
  required _FakeNovelDownloads novels,
  int initialTab = 2,
  double width = 400,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1200);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    comics.dispose();
    novels.dispose();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [novelDownloadManagerProvider.overrideWithValue(novels)],
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
        home: DownloadCenterPage(
          initialTab: initialTab,
          comicDownloads: comics,
          novelDownloads: novels,
        ),
      ),
    ),
  );
  await _pumpFrames(tester);
}

Future<void> _chooseFilter(WidgetTester tester, String label) async {
  await tester.tap(_filter);
  await _pumpFrames(tester);
  // 当前项也显示在胶囊中，最后一个同名文本才是弹出的菜单项。
  await tester.tap(find.text(label).last);
  await _pumpFrames(tester);
}

void _expectToolbarInOneRow(WidgetTester tester) {
  final filterCenter = tester.getCenter(_filter);
  final pauseCenter = tester.getCenter(_pause);
  final selectCenter = tester.getCenter(_selectAll);
  expect(filterCenter.dy, closeTo(pauseCenter.dy, 1));
  expect(pauseCenter.dy, closeTo(selectCenter.dy, 1));
  expect(filterCenter.dx, lessThan(pauseCenter.dx));
  expect(pauseCenter.dx, lessThan(selectCenter.dx));
}

void main() {
  testWidgets('窄屏中筛选、暂停、全选同行，AppBar 不再显示暂停按钮', (tester) async {
    await _pumpPage(
      tester,
      comics: _mixedComics(),
      novels: _mixedNovels(),
      width: 320,
    );

    final tabs = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabs.controller!.index, 2);
    expect(tabs.tabs.whereType<Tab>().map((tab) => tab.text), [
      '漫画',
      '轻小说',
      '队列',
    ]);
    final pages = tester.widget<TabBarView>(find.byType(TabBarView));
    expect(pages.children, hasLength(3));
    expect(pages.children[0], isA<LocalComicsPage>());
    expect(pages.children[1], isA<LocalNovelsPage>());
    expect(pages.controller, same(tabs.controller));
    expect(
      find.descendant(of: find.byType(Tab).at(2), matching: find.text('6')),
      findsOneWidget,
    );
    expect(tester.widget(_filter), isA<SelectTile<Object?>>());
    expect(find.text('全部 6'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.pause_rounded),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.play_arrow_rounded),
      ),
      findsNothing,
    );
    _expectToolbarInOneRow(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('下拉列表保留混合队列的三种筛选及计数', (tester) async {
    await _pumpPage(tester, comics: _mixedComics(), novels: _mixedNovels());

    await tester.tap(_filter);
    await _pumpFrames(tester);
    expect(find.text('全部 6'), findsNWidgets(2));
    expect(find.text('下载中 2'), findsOneWidget);
    expect(find.text('已暂停 2'), findsOneWidget);
    await tester.tap(find.text('下载中 2'));
    await _pumpFrames(tester);

    expect(find.text('漫画-active'), findsOneWidget);
    expect(find.text('小说-active'), findsOneWidget);
    expect(find.text('漫画-paused'), findsNothing);
    expect(find.text('小说-paused'), findsNothing);
    expect(find.text('漫画-waiting'), findsNothing);
    expect(find.text('小说-waiting'), findsNothing);

    await _chooseFilter(tester, '已暂停 2');
    expect(find.text('漫画-paused'), findsOneWidget);
    expect(find.text('小说-paused'), findsOneWidget);
    expect(find.text('漫画-active'), findsNothing);
    expect(find.text('小说-active'), findsNothing);

    await _chooseFilter(tester, '全部 6');
    expect(find.byType(Card), findsNWidgets(6));
    expect(find.text('漫画-waiting'), findsOneWidget);
    expect(find.text('小说-waiting'), findsOneWidget);
  });

  testWidgets('全选可取消，切换筛选清空两类任务的选择', (tester) async {
    await _pumpPage(tester, comics: _mixedComics(), novels: _mixedNovels());
    await _chooseFilter(tester, '下载中 2');

    await tester.tap(_selectAll);
    await _pumpFrames(tester);
    expect(find.text('多选: 2'), findsOneWidget);
    expect(find.text('取消全选'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
    _expectToolbarInOneRow(tester);

    await tester.tap(_selectAll);
    await _pumpFrames(tester);
    expect(find.text('多选: 2'), findsNothing);
    expect(find.text('全选'), findsOneWidget);

    await tester.tap(_selectAll);
    await _pumpFrames(tester);
    await _chooseFilter(tester, '已暂停 2');
    expect(find.text('多选: 2'), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.text('全选'), findsOneWidget);
  });

  testWidgets('全选仅删除可见的漫画与小说任务，删除前必须确认', (tester) async {
    final comics = _mixedComics();
    final novels = _mixedNovels();
    await _pumpPage(tester, comics: comics, novels: novels);
    await _chooseFilter(tester, '已暂停 2');
    await tester.tap(_selectAll);
    await _pumpFrames(tester);

    await tester.tap(find.byTooltip('删除所选'));
    await _pumpFrames(tester);
    expect(find.text('删除 2 个下载任务'), findsOneWidget);
    expect(comics.deleted, isEmpty);
    expect(novels.deleted, isEmpty);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await _pumpFrames(tester);
    expect(comics.deleted, isEmpty);
    expect(novels.deleted, isEmpty);
    expect(find.text('多选: 2'), findsOneWidget);

    await tester.tap(find.byTooltip('删除所选'));
    await _pumpFrames(tester);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await _pumpFrames(tester);

    expect(comics.deleted, ['paused']);
    expect(novels.deleted, ['paused']);
    expect(comics.tasks.map((task) => task.chapterUuid), ['active', 'waiting']);
    expect(novels.tasks.map((task) => task.volumeId), ['active', 'waiting']);
    expect(find.text('已暂停 0'), findsOneWidget);
    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.text('多选: 2'), findsNothing);
    expect(tester.widget<TextButton>(_selectAll).onPressed, isNull);
    expect(tester.widget<TextButton>(_pause).onPressed, isNotNull);
  });

  testWidgets('同行按钮同时暂停及继续两类下载管理器', (tester) async {
    final comics = _mixedComics();
    final novels = _mixedNovels();
    await _pumpPage(tester, comics: comics, novels: novels);
    expect(find.widgetWithText(TextButton, '暂停'), findsOneWidget);

    await tester.tap(_pause);
    await _pumpFrames(tester);
    expect(comics.pauseCalls, 1);
    expect(novels.pauseCalls, 1);
    expect(comics.paused, isTrue);
    expect(novels.paused, isTrue);
    expect(find.widgetWithText(TextButton, '继续'), findsOneWidget);

    await tester.tap(_pause);
    await _pumpFrames(tester);
    expect(comics.resumeCalls, 1);
    expect(novels.resumeCalls, 1);
    expect(comics.paused, isFalse);
    expect(novels.paused, isFalse);
    expect(find.widgetWithText(TextButton, '暂停'), findsOneWidget);
  });

  for (final comicPaused in [true, false]) {
    testWidgets('${comicPaused ? '漫画' : '小说'}单侧全局暂停时仍能暂停另一侧', (tester) async {
      final comics = _FakeComicDownloads(
        tasks: [_comicTask('active', ComicDownloadTaskStatus.downloading)],
        paused: comicPaused,
      );
      final novels = _FakeNovelDownloads(
        tasks: [_novelTask('active', NovelDownloadStatus.downloading)],
        paused: !comicPaused,
      );
      await _pumpPage(tester, comics: comics, novels: novels);
      expect(find.widgetWithText(TextButton, '暂停'), findsOneWidget);

      await tester.tap(_pause);
      await _pumpFrames(tester);
      expect(comics.paused, isTrue);
      expect(novels.paused, isTrue);
      expect(comics.pauseCalls, 1);
      expect(novels.pauseCalls, 1);
      expect(find.widgetWithText(TextButton, '继续'), findsOneWidget);
    });
  }

  for (final novelOnly in [true, false]) {
    testWidgets('仅有${novelOnly ? '小说' : '漫画'}任务时按有任务一侧的状态继续下载', (tester) async {
      final comics = _FakeComicDownloads(
        tasks: [
          if (!novelOnly) _comicTask('paused', ComicDownloadTaskStatus.paused),
        ],
        paused: !novelOnly,
      );
      final novels = _FakeNovelDownloads(
        tasks: [
          if (novelOnly) _novelTask('paused', NovelDownloadStatus.paused),
        ],
        paused: novelOnly,
      );
      await _pumpPage(tester, comics: comics, novels: novels);
      expect(find.widgetWithText(TextButton, '继续'), findsOneWidget);

      await tester.tap(_pause);
      await _pumpFrames(tester);
      expect(comics.resumeCalls, 1);
      expect(novels.resumeCalls, 1);
      expect(comics.paused, isFalse);
      expect(novels.paused, isFalse);
    });
  }

  testWidgets('空队列保留工具栏并禁用暂停和全选', (tester) async {
    await _pumpPage(
      tester,
      comics: _FakeComicDownloads(),
      novels: _FakeNovelDownloads(),
    );

    expect(find.text('下载队列为空'), findsOneWidget);
    expect(find.text('全部 0'), findsOneWidget);
    expect(tester.widget<TextButton>(_pause).onPressed, isNull);
    expect(tester.widget<TextButton>(_selectAll).onPressed, isNull);
    _expectToolbarInOneRow(tester);
  });

  testWidgets('大字体和取消全选长文案下工具栏仍同行且不溢出', (tester) async {
    await _pumpPage(
      tester,
      comics: _mixedComics(),
      novels: _mixedNovels(),
      width: 320,
      textScale: 1.5,
    );
    await _chooseFilter(tester, '已暂停 2');
    await tester.tap(_selectAll);
    await _pumpFrames(tester);

    expect(find.text('取消全选'), findsOneWidget);
    for (final (tooltip, icon) in [
      ('暂停下载', Icons.pause_rounded),
      ('继续下载', Icons.play_arrow_rounded),
      ('删除所选', Icons.delete_outline),
      ('取消', Icons.close),
    ]) {
      expect(
        find.descendant(
          of: find.byTooltip(tooltip),
          matching: find.byIcon(icon),
        ),
        findsOneWidget,
      );
    }
    _expectToolbarInOneRow(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('initialTab=1 直接打开小说页，点选与滑切均按新顺序切换', (tester) async {
    await _pumpPage(
      tester,
      comics: _FakeComicDownloads(),
      novels: _FakeNovelDownloads(),
      initialTab: 1,
    );

    final tabs = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabs.tabs, hasLength(3));
    expect(tabs.controller!.index, 1);
    expect(find.byType(LocalNovelsPage), findsOneWidget);
    expect(find.text('还没有本地轻小说'), findsOneWidget);
    expect(_filter, findsNothing);

    await tester.tap(find.widgetWithText(Tab, '队列'));
    await tester.pumpAndSettle();
    expect(tabs.controller!.index, 2);
    expect(find.text('下载队列为空'), findsOneWidget);
    expect(_filter, findsOneWidget);

    await tester.drag(find.byType(TabBarView), const Offset(350, 0));
    await tester.pumpAndSettle();
    expect(tabs.controller!.index, 1);
    expect(find.text('还没有本地轻小说'), findsOneWidget);
    expect(_filter, findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('默认页签仍为漫画', () {
    expect(const DownloadCenterPage().initialTab, 0);
  });

  testWidgets('超过最大索引时打开最后的队列页', (tester) async {
    await _pumpPage(
      tester,
      comics: _FakeComicDownloads(),
      novels: _FakeNovelDownloads(),
      initialTab: 99,
    );

    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 2);
    expect(find.text('下载队列为空'), findsOneWidget);
    expect(_filter, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('轻小说开关关闭后只剩漫画与队列两个页签', (tester) async {
    SharedPreferences.setMockInitialValues({'nav_show_novel': true});
    await UserManager().theme.setShowNovel(false);
    addTearDown(() => UserManager().theme.setShowNovel(true));

    await _pumpPage(
      tester,
      comics: _FakeComicDownloads(),
      novels: _FakeNovelDownloads(),
      initialTab: 1,
    );

    final tabs = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabs.tabs, hasLength(2));
    // 旧语义 tab=1（轻小说页）落到漫画页。
    expect(tabs.controller!.index, 0);
    expect(find.byType(LocalComicsPage), findsOneWidget);
    expect(find.text('下载队列为空'), findsNothing);

    await tester.tap(find.widgetWithText(Tab, '队列'));
    await tester.pumpAndSettle();
    expect(tabs.controller!.index, 1);
    expect(find.text('下载队列为空'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

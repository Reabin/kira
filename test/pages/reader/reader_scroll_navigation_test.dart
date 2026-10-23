import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/api_client.dart';
import 'package:kira/api/manga/manga_api.dart';
import 'package:kira/models/chapter.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/reader_page.dart';
import 'package:kira/utils/bookmark_store.dart';
import 'package:kira/utils/reading_history.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers.dart';

class _ReaderApi extends Fake implements ApiClient {
  _ReaderApi(this.manga);

  @override
  final MangaApi manga;
}

class _ReaderMangaApi extends Fake implements MangaApi {
  _ReaderMangaApi(this.chapters);

  final Map<String, ChapterDetail> chapters;
  final requestedChapters = <String>[];

  @override
  Future<ChapterDetail> getChapterDetail(
    String pathWord,
    String chapterUuid, {
    bool forceRefresh = false,
  }) async {
    requestedChapters.add(chapterUuid);
    return chapters[chapterUuid]!;
  }
}

ChapterDetail _chapter(
  String uuid, {
  String? prev,
  String? next,
  int pages = 1,
}) {
  return ChapterDetail(
    uuid: uuid,
    index: 0,
    name: uuid,
    prev: prev,
    next: next,
    contents: List.filled(pages, File('assets/ic_launcher.png').absolute.path),
    isDownloaded: true,
  );
}

ScrollablePositionedList _scrollList(WidgetTester tester) {
  return tester.widget<ScrollablePositionedList>(
    find.byType(ScrollablePositionedList),
  );
}

Future<void> _openReader(
  WidgetTester tester, {
  String chapterUuid = 'last',
  int direction = 0,
  bool continuousReading = true,
  bool pageMode = false,
}) async {
  final user = UserManager();
  await user.setReaderMode(pageMode ? 1 : 0);
  await user.setReaderScrollDirection(direction);
  await user.setReaderContinuousReading(continuousReading);

  await tester.pumpWidget(
    wrapWithApp(
      Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ReaderPage(
                pathWord: 'reader-scroll-test',
                comicName: '测试漫画',
                group: 'default',
                chapterUuid: chapterUuid,
                chapterName: chapterUuid,
              ),
            ),
          ),
          child: const Text('打开阅读器'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开阅读器'));
  for (var attempt = 0; attempt < 10; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    if (find.byType(ScrollablePositionedList).evaluate().isNotEmpty ||
        find.byType(PageView).evaluate().isNotEmpty) {
      break;
    }
  }
  expect(find.byType(ReaderPage), findsOneWidget);
  expect(
    pageMode ? find.byType(PageView) : find.byType(ScrollablePositionedList),
    findsOneWidget,
    reason: tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .join('; '),
  );
  if (!pageMode) {
    expect(
      _scrollList(tester).scrollDirection,
      direction == 2 ? Axis.vertical : Axis.horizontal,
    );
    expect(_scrollList(tester).reverse, direction == 1);
  }
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

Future<void> _showTail(WidgetTester tester, {double alignment = 0}) async {
  final list = _scrollList(tester);
  list.itemScrollController!.jumpTo(
    index: list.itemCount - 1,
    alignment: alignment,
  );
  await tester.pumpAndSettle();
  final tail = list.itemPositionsNotifier!.itemPositions.value.singleWhere(
    (position) => position.index == list.itemCount - 1,
  );
  expect(tail.itemLeadingEdge, greaterThanOrEqualTo(-0.05));
  if (list.scrollDirection == Axis.horizontal) {
    expect(tail.itemTrailingEdge, lessThanOrEqualTo(1.05));
  }
}

void _sendScroll(
  WidgetTester tester, {
  double delta = 20,
  bool overscroll = false,
  bool dragging = false,
}) {
  final list = _scrollList(tester);
  final context = tester.element(find.byType(ScrollablePositionedList));
  final metrics = FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: 1000,
    pixels: 1000,
    viewportDimension: 800,
    axisDirection: list.scrollDirection == Axis.vertical
        ? AxisDirection.down
        : (list.reverse ? AxisDirection.left : AxisDirection.right),
    devicePixelRatio: 1,
  );
  final notification = overscroll
      ? OverscrollNotification(
          metrics: metrics,
          context: context,
          overscroll: delta,
          dragDetails: dragging
              ? DragUpdateDetails(globalPosition: Offset.zero)
              : null,
        )
      : ScrollUpdateNotification(
          metrics: metrics,
          context: context,
          scrollDelta: delta,
          dragDetails: dragging
              ? DragUpdateDetails(globalPosition: Offset.zero)
              : null,
        );
  notification.dispatch(context);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ApiClient originalApi;
  late Directory tempDirectory;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'kira-reader-scroll-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProvider,
          (_) async => tempDirectory.path,
        );
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await tempDirectory.delete(recursive: true);
  });

  setUp(() async {
    await ReadingHistory.flush();
    SharedPreferences.setMockInitialValues({});
    setupSecureCredentialStoreForTest();
    BookmarkStore().debugReset();
    originalApi = ApiClient();
    ApiClient.setTestInstance(
      _ReaderApi(_ReaderMangaApi({'last': _chapter('last', prev: 'previous')})),
    );
    UserManager().reader.resetPrefsCache();
    await UserManager().reader.initFromPrefs(
      await SharedPreferences.getInstance(),
    );
  });

  tearDown(() async {
    await ReadingHistory.flush();
    BookmarkStore().debugReset();
    ApiClient.setTestInstance(originalApi);
    teardownSecureCredentialStoreForTest();
  });

  testWidgets('子 store 改变滚动方向会即时更新阅读器', (tester) async {
    final user = UserManager();
    await user.init();
    await _openReader(tester, continuousReading: false);
    expect(_scrollList(tester).scrollDirection, Axis.horizontal);
    expect(_scrollList(tester).reverse, isFalse);

    await user.reader.setScrollDirection(1);
    await tester.pumpAndSettle();
    expect(user.readerScrollDirection, 1);
    expect(_scrollList(tester).scrollDirection, Axis.horizontal);
    expect(_scrollList(tester).reverse, isTrue);

    await user.setReaderScrollDirection(2);
    await tester.pumpAndSettle();
    expect(user.reader.scrollDirection, 2);
    expect(_scrollList(tester).scrollDirection, Axis.vertical);
    expect(_scrollList(tester).reverse, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final direction in [0, 1]) {
    for (final continuousReading in [false, true]) {
      testWidgets('horizontal last chapter stays open after scrolling '
          '(direction=$direction, continuous=$continuousReading)', (
        tester,
      ) async {
        await _openReader(
          tester,
          direction: direction,
          continuousReading: continuousReading,
        );
        await _showTail(tester);
        expect(find.text('当前已无下一话'), findsOneWidget);

        _sendScroll(tester, dragging: true);
        await tester.pumpAndSettle();
        expect(find.byType(ReaderPage), findsOneWidget);

        _sendScroll(tester);
        await tester.pumpAndSettle();
        expect(find.byType(ReaderPage), findsOneWidget);

        _sendScroll(tester, overscroll: true, dragging: true);
        await tester.pumpAndSettle();
        expect(find.byType(ReaderPage), findsOneWidget);

        _sendScroll(tester, overscroll: true);
        await tester.pumpAndSettle();
        expect(find.byType(ReaderPage), findsOneWidget);

        final drag = direction == 1
            ? const Offset(300, 0)
            : const Offset(-300, 0);
        await tester.fling(find.byType(ScrollablePositionedList), drag, 1800);
        await tester.pumpAndSettle();
        expect(find.byType(ReaderPage), findsOneWidget);

        await tester.tap(find.widgetWithText(OutlinedButton, '目录').last);
        await tester.pumpAndSettle();
        expect(find.byType(ReaderPage), findsNothing);
        expect(find.text('打开阅读器'), findsOneWidget);
      });

      testWidgets('horizontal scrolling still enters the next chapter '
          '(direction=$direction, continuous=$continuousReading)', (
        tester,
      ) async {
        final manga = _ReaderMangaApi({
          'middle': _chapter('middle', next: 'last', pages: 3),
          'last': _chapter('last', prev: 'middle', pages: 3),
        });
        ApiClient.setTestInstance(_ReaderApi(manga));
        await _openReader(
          tester,
          chapterUuid: 'middle',
          direction: direction,
          continuousReading: continuousReading,
        );
        await _showTail(tester);
        _sendScroll(tester, dragging: true);
        await tester.pumpAndSettle();

        expect(manga.requestedChapters, contains('last'));
        expect(find.byType(ReaderPage), findsOneWidget);
        await _showTail(tester);
        final lastImageIndex = _scrollList(tester).itemCount - 2;
        _scrollList(tester).itemScrollController!.jumpTo(index: lastImageIndex);
        await tester.pumpAndSettle();
        expect(find.text('last'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets(
      'non-continuous first chapter still exits on backward scrolling '
      '(direction=$direction)',
      (tester) async {
        ApiClient.setTestInstance(
          _ReaderApi(
            _ReaderMangaApi({
              'first': _chapter('first', next: 'next', pages: 3),
            }),
          ),
        );
        await _openReader(
          tester,
          chapterUuid: 'first',
          direction: direction,
          continuousReading: false,
        );
        _scrollList(tester).itemScrollController!.jumpTo(index: 0);
        await tester.pumpAndSettle();
        _sendScroll(tester, delta: -20, dragging: true);
        await tester.pumpAndSettle();
        expect(find.byType(ReaderPage), findsNothing);
      },
    );

    testWidgets(
      'page mode still exits at the last blank page (direction=$direction)',
      (tester) async {
        await _openReader(tester, direction: direction, pageMode: true);
        final pageView = tester.widget<PageView>(find.byType(PageView));
        pageView.controller!.jumpToPage(1);
        await tester.pumpAndSettle();
        expect(find.byType(ReaderPage), findsNothing);
      },
    );
  }

  for (final continuousReading in [false, true]) {
    testWidgets('vertical scrolling still exits at the last chapter '
        '(continuous=$continuousReading)', (tester) async {
      await _openReader(
        tester,
        direction: 2,
        continuousReading: continuousReading,
      );
      await _showTail(tester, alignment: 0.3);
      _sendScroll(tester, dragging: true);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPage), findsOneWidget);

      await tester.drag(
        find.byType(ScrollablePositionedList),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      _sendScroll(tester, dragging: true);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPage), findsNothing);
    });
  }
}

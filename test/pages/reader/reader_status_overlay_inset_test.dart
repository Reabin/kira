import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/api_client.dart';
import 'package:kira/api/manga/manga_api.dart';
import 'package:kira/models/chapter.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/reader_page.dart';
import 'package:kira/theme/app_typography.dart';
import 'package:kira/utils/bookmark_store.dart';
import 'package:kira/utils/reading_history.dart';
import 'package:kira/widgets/reader_status_overlay.dart';
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

  @override
  Future<ChapterDetail> getChapterDetail(
    String pathWord,
    String chapterUuid, {
    bool forceRefresh = false,
  }) async => chapters[chapterUuid]!;
}

ChapterDetail _chapter(String uuid, {String? prev, int imageCount = 1}) {
  return ChapterDetail(
    uuid: uuid,
    index: 0,
    name: uuid,
    prev: prev,
    contents: List.filled(
      imageCount,
      File('assets/ic_launcher.png').absolute.path,
    ),
    isDownloaded: true,
  );
}

Future<void> _pumpReader(
  WidgetTester tester, {
  required Map<String, ChapterDetail> chapters,
  TextScaler textScaler = TextScaler.noScaling,
  int initialPage = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 600);
  addTearDown(tester.view.reset);
  ApiClient.setTestInstance(_ReaderApi(_ReaderMangaApi(chapters)));

  await tester.pumpWidget(
    wrapWithApp(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: ReaderPage(
            pathWord: 'reader-status-inset-test',
            comicName: '测试漫画',
            group: 'default',
            chapterUuid: 'last',
            chapterName: 'last',
            initialPage: initialPage,
          ),
        ),
      ),
      wrapInScaffold: false,
    ),
  );

  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    if (find.byType(ScrollablePositionedList).evaluate().isNotEmpty) break;
  }
  expect(find.byType(ScrollablePositionedList), findsOneWidget);
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ApiClient originalApi;
  late Directory tempDirectory;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    tempDirectory = await Directory.systemTemp.createTemp('kira-reader-inset-');
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
    UserManager().reader.resetPrefsCache();
    await UserManager().reader.initFromPrefs(
      await SharedPreferences.getInstance(),
    );
    await UserManager().init();
    final reader = UserManager().reader;
    await reader.setStatusOverlay(true);
    await reader.setStatusOverlayPosition(2);
    await reader.setStatusOverlayPage(true);
  });

  tearDown(() async {
    await ReadingHistory.flush();
    BookmarkStore().debugReset();
    ApiClient.setTestInstance(originalApi);
    teardownSecureCredentialStoreForTest();
  });

  for (final (label, scaler) in <(String, TextScaler)>[
    ('1x', TextScaler.noScaling),
    ('platform 2x', const TextScaler.linear(2)),
    (
      'theme font 26/14',
      AppTypography.composeTextScaler(TextScaler.noScaling, 26 / 14),
    ),
  ]) {
    testWidgets('竖滚首图避让状态条且不缩小视口（$label）', (tester) async {
      await _pumpReader(
        tester,
        chapters: {'last': _chapter('last')},
        textScaler: scaler,
      );

      final overlay = find.byType(ReaderStatusOverlay);
      final overlayHeight = tester.getSize(overlay).height;
      expect(tester.getTopLeft(overlay).dy, 0);
      final list = find.byType(ScrollablePositionedList);
      expect(
        tester.widget<ScrollablePositionedList>(list).scrollDirection,
        Axis.vertical,
      );
      expect(tester.getTopLeft(list).dy, 0);
      final image = find.byKey(const ValueKey('reader-image-last-0'));
      expect(tester.getTopLeft(image).dy, closeTo(overlayHeight, 0.5));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('有上一话时首图同样避让', (tester) async {
    await _pumpReader(
      tester,
      chapters: {'last': _chapter('last', prev: 'previous')},
    );
    final overlayHeight = tester
        .getSize(find.byType(ReaderStatusOverlay))
        .height;
    final imageTop = tester
        .getTopLeft(find.byKey(const ValueKey('reader-image-last-0')))
        .dy;
    expect(imageTop, closeTo(overlayHeight, 0.5));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('首图留白随内容滚走，不变成常驻顶栏', (tester) async {
    await _pumpReader(tester, chapters: {'last': _chapter('last')});
    final list = find.byType(ScrollablePositionedList);
    await tester.drag(list, const Offset(0, -100));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(list).dy, 0);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('reader-image-last-0'))).dy,
      lessThan(0),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('进入非首图时不新增顶部留白', (tester) async {
    await _pumpReader(
      tester,
      chapters: {'last': _chapter('last', imageCount: 2)},
      initialPage: 2,
    );
    final image = find.byKey(const ValueKey('reader-image-last-1'));
    expect(tester.getTopLeft(image).dy, closeTo(0, 0.5));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('回到链首触发区后首图仍在状态条下方', (tester) async {
    await _pumpReader(tester, chapters: {'last': _chapter('last')});
    final list = tester.widget<ScrollablePositionedList>(
      find.byType(ScrollablePositionedList),
    );
    list.itemScrollController!.jumpTo(index: 0);
    await tester.pumpAndSettle();
    final overlayHeight = tester
        .getSize(find.byType(ReaderStatusOverlay))
        .height;
    final imageTop = tester
        .getTopLeft(find.byKey(const ValueKey('reader-image-last-0')))
        .dy;
    expect(imageTop, greaterThan(overlayHeight));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('置底或关闭状态条后撤除首图留白', (tester) async {
    await _pumpReader(tester, chapters: {'last': _chapter('last')});
    final reader = UserManager().reader;
    final image = find.byKey(const ValueKey('reader-image-last-0'));
    expect(tester.getTopLeft(image).dy, greaterThan(0));

    await reader.setStatusOverlayPosition(3);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(image).dy, closeTo(0, 0.5));
    await reader.setStatusOverlayPosition(2);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(image).dy, greaterThan(0));
    await reader.setStatusOverlay(false);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(image).dy, closeTo(0, 0.5));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

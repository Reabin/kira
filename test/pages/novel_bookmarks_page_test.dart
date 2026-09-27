import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/novel_reading_progress.dart';
import 'package:kira/pages/bookmarks_page.dart';
import 'package:kira/providers/novel_providers.dart';
import 'package:kira/routing/app_router.dart';
import 'package:kira/utils/bookmark_store.dart';
import 'package:kira/utils/novel_bookmark_store.dart';
import 'package:kira/utils/novel_reading_store.dart';
import 'package:kira/widgets/novel_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NovelBookmarkStore novelStore;
  late SharedPreferences prefs;

  // 必须在 testWidgets 的 FakeAsync zone 内创建注入的 Future。
  // setUp 中创建的 Future 会把后续 await 排到真实 zone，pumpAndSettle
  // 并不等待它，导致删除后的断言偶发早于持久化完成。
  Future<void> seedBookmarks() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    novelStore = NovelBookmarkStore.forTesting(prefs: Future.value(prefs));
    BookmarkStore().debugReset();
    await BookmarkStore().toggle(
      pathWord: 'comic-a',
      comicName: '漫画 A',
      chapterUuid: 'chapter-1',
      chapterName: '第一话',
      page: 7,
    );
    await novelStore.toggle(progress: _position());
  }

  tearDown(() async {
    await novelStore.flush();
    novelStore.dispose();
    await BookmarkStore().flush();
    BookmarkStore().debugReset();
  });

  testWidgets(
    'tabs preserve comics and show novel groups, chapters and percent',
    (tester) async {
      await seedBookmarks();
      await _pump(tester, novelStore);
      expect(find.text('漫画 A'), findsOneWidget);
      expect(find.text('第一话'), findsOneWidget);
      await _showNovels(tester);
      expect(find.text('小说 A'), findsOneWidget);
      // 卷名前缀去重：章节名「第一卷 第二章」显示为「第一卷 · 第二章」。
      expect(find.text('第一卷 · 第二章'), findsOneWidget);
      expect(find.text('第一卷 · 第一卷 第二章'), findsNothing);
      expect(find.textContaining('本卷 42.00%'), findsOneWidget);
      expect(find.text('1 条书签'), findsOneWidget);
      await tester.tap(find.text('漫画'));
      await tester.pumpAndSettle();
      expect(find.text('漫画 A'), findsOneWidget);
      expect(BookmarkStore().bookmarks, hasLength(1));
    },
  );

  testWidgets(
    'bookmark jumps to its exact volume/entry/paragraph, not history',
    (tester) async {
      await seedBookmarks();
      final history = NovelReadingStore(prefs: Future.value(prefs));
      final lastRead = _position().copyWith(
        volumeId: 'last-read-volume',
        entryIndex: 99,
        paragraphIndex: 88,
        paragraphAlignment: -0.9,
      );
      await history.saveProgress(lastRead);
      final historyBefore = prefs.getString(
        '${NovelReadingStore.prefix}novel-a',
      );
      final saved = novelStore.bookmarks.single;
      await _pump(tester, novelStore);
      await _showNovels(tester);
      await tester.tap(find.byKey(ValueKey('novel_bookmark_open_${saved.id}')));
      await tester.pumpAndSettle();
      expect(
        find.text('reader:novel-a:volume-1:8:12:-0.35:false'),
        findsOneWidget,
      );
      expect(
        prefs.getString('${NovelReadingStore.prefix}novel-a'),
        historyBefore,
      );
    },
  );

  testWidgets('novel group header opens details', (tester) async {
    await seedBookmarks();
    await _pump(tester, novelStore);
    await _showNovels(tester);
    await tester.tap(
      find.byKey(const ValueKey('novel_bookmark_details_novel-a')),
    );
    await tester.pumpAndSettle();
    expect(find.text('novel-detail:novel-a'), findsOneWidget);
  });

  testWidgets('single deletion and undo preserve exact anchors and comics', (
    tester,
  ) async {
    await seedBookmarks();
    final saved = novelStore.bookmarks.single;
    await _pump(tester, novelStore);
    await _showNovels(tester);
    await tester.tap(find.byKey(ValueKey('novel_bookmark_remove_${saved.id}')));
    await _settleBookmarks(tester, novelStore);
    expect(novelStore.bookmarks, isEmpty);
    expect(BookmarkStore().bookmarks, hasLength(1));
    expect(find.textContaining('阅读轻小说时'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await _settleBookmarks(tester, novelStore);
    expect(novelStore.bookmarks.single.id, saved.id);
    expect(novelStore.bookmarks.single.paragraphAlignment, -0.35);
    expect(tester.takeException(), isNull);
  });

  testWidgets('swiping one novel bookmark does not remove its sibling', (
    tester,
  ) async {
    await seedBookmarks();
    final saved = novelStore.bookmarks.single;
    await novelStore.toggle(progress: _position().copyWith(paragraphIndex: 44));
    await _pump(tester, novelStore);
    await _showNovels(tester);
    await tester.drag(
      find.byKey(ValueKey('novel_bookmark_${saved.id}')),
      const Offset(-550, 0),
    );
    await _settleBookmarks(tester, novelStore);
    expect(novelStore.bookmarks, hasLength(1));
    expect(novelStore.bookmarks.single.paragraphIndex, 44);
    await tester.tap(find.text('撤销'));
    await _settleBookmarks(tester, novelStore);
    expect(novelStore.bookmarks, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('group clear and undo affect only that novel', (tester) async {
    await seedBookmarks();
    await novelStore.toggle(progress: _position().copyWith(paragraphIndex: 44));
    await novelStore.toggle(
      progress: _position().copyWith(pathWord: 'novel-b', name: '小说 B'),
    );
    await _pump(tester, novelStore);
    await _showNovels(tester);
    await tester.tap(
      find.byKey(const ValueKey('novel_bookmark_clear_novel-a')),
    );
    await _settleBookmarks(tester, novelStore);
    expect(novelStore.bookmarks.single.pathWord, 'novel-b');
    await tester.tap(find.text('撤销'));
    await _settleBookmarks(tester, novelStore);
    expect(novelStore.bookmarks, hasLength(3));
    expect(BookmarkStore().bookmarks, hasLength(1));
  });

  testWidgets('clear current type confirms novels only and supports undo', (
    tester,
  ) async {
    await seedBookmarks();
    await _pump(tester, novelStore);
    await _showNovels(tester);
    await tester.tap(
      find.byKey(const ValueKey('bookmarks_clear_current_type')),
    );
    await tester.pumpAndSettle();
    expect(find.text('确定清空所有轻小说书签？'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      ),
    );
    await _settleBookmarks(tester, novelStore);
    expect(novelStore.bookmarks, isEmpty);
    expect(BookmarkStore().bookmarks, hasLength(1));
    await tester.tap(find.text('撤销'));
    await _settleBookmarks(tester, novelStore);
    expect(novelStore.bookmarks, hasLength(1));
  });

  testWidgets('clearing comics never touches novel bookmarks', (tester) async {
    await seedBookmarks();
    await _pump(tester, novelStore);
    await tester.tap(
      find.byKey(const ValueKey('bookmarks_clear_current_type')),
    );
    await tester.pumpAndSettle();
    expect(find.text('确定清空所有漫画书签？'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(BookmarkStore().bookmarks, isEmpty);
    expect(novelStore.bookmarks, hasLength(1));
    await _showNovels(tester);
    expect(find.text('小说 A'), findsOneWidget);
    expect(find.text('撤销'), findsNothing);
  });

  testWidgets('small novel covers stay flat inside elevated bookmark groups', (
    tester,
  ) async {
    await seedBookmarks();
    await _pump(tester, novelStore);
    await _showNovels(tester);
    final coverMaterials = tester.widgetList<Material>(
      find.descendant(
        of: find.byType(NovelCover),
        matching: find.byType(Material),
      ),
    );
    expect(coverMaterials.where((material) => material.elevation > 0), isEmpty);
    final title = tester.widget<Text>(find.text('小说 A'));
    expect(title.style?.fontWeight, FontWeight.bold);
  });

  testWidgets(
    'swipe waits for persistence and failed deletion keeps the bookmark without undo',
    (tester) async {
      await seedBookmarks();
      final controlled = _ControlledPreferences(prefs);
      await novelStore.flush();
      novelStore.dispose();
      novelStore = NovelBookmarkStore.forTesting(
        prefs: Future.value(controlled),
      );
      await _pump(tester, novelStore);
      await _showNovels(tester);
      final saved = novelStore.bookmarks.single;
      final gate = Completer<void>();
      controlled.writeGate = gate;
      controlled.failWrite = true;
      await tester.drag(
        find.byKey(ValueKey('novel_bookmark_${saved.id}')),
        const Offset(-550, 0),
      );
      await tester.pumpAndSettle();
      expect(novelStore.bookmarks, hasLength(1));
      expect(
        find.byKey(ValueKey('novel_bookmark_open_${saved.id}')),
        findsOneWidget,
      );
      expect(find.text('撤销'), findsNothing);
      gate.complete();
      await _settleBookmarks(tester, novelStore);
      expect(novelStore.bookmarks, hasLength(1));
      expect(
        find.byKey(ValueKey('novel_bookmark_open_${saved.id}')),
        findsOneWidget,
      );
      expect(find.text('撤销'), findsNothing);
      expect(tester.takeException(), isNull);

      controlled.failWrite = false;
      await tester.tap(
        find.byKey(ValueKey('novel_bookmark_remove_${saved.id}')),
      );
      await _settleBookmarks(tester, novelStore);
      expect(novelStore.bookmarks, isEmpty);
      expect(find.text('还没有书签'), findsOneWidget);
      expect(find.text('撤销'), findsOneWidget);
    },
  );

  testWidgets('returning from reader reflects bookmark changes', (
    tester,
  ) async {
    await seedBookmarks();
    final saved = novelStore.bookmarks.single;
    final router = await _pump(tester, novelStore);
    await _showNovels(tester);
    await tester.tap(find.byKey(ValueKey('novel_bookmark_open_${saved.id}')));
    await tester.pumpAndSettle();
    await novelStore.remove(saved.id);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.textContaining('阅读轻小说时'), findsOneWidget);
    expect(find.text('小说 A'), findsNothing);
  });
}

Future<void> _settleBookmarks(
  WidgetTester tester,
  NovelBookmarkStore store,
) async {
  // 先完成手势/滑动动画，再等待业务写队列，最后绘制通知产生的新帧。
  await tester.pumpAndSettle();
  await store.flush();
  await tester.pumpAndSettle();
}

Future<void> _showNovels(WidgetTester tester) async {
  await tester.tap(find.text('轻小说'));
  await tester.pumpAndSettle();
}

Future<GoRouter> _pump(WidgetTester tester, NovelBookmarkStore store) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const BookmarksPage()),
      GoRoute(
        path: '/novel/:pathWord',
        name: AppRoutes.novelDetail,
        builder: (_, state) => Scaffold(
          body: Text('novel-detail:${state.pathParameters['pathWord']}'),
        ),
      ),
      GoRoute(
        path: '/novel-reader/:pathWord/:volumeId',
        name: AppRoutes.novelReader,
        builder: (_, state) {
          final extra = state.extra;
          if (extra is! NovelReaderExtra) {
            return const Scaffold(body: Text('missing-reader-extra'));
          }
          return Scaffold(
            body: Text(
              'reader:${state.pathParameters['pathWord']}:'
              '${state.pathParameters['volumeId']}:'
              '${extra.entryIndex}:${extra.initialParagraphIndex}:'
              '${extra.initialParagraphAlignment}:${extra.resume}',
            ),
          );
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [novelBookmarkStoreProvider.overrideWithValue(store)],
      child: MaterialApp.router(
        theme: ThemeData(cardTheme: const CardThemeData(elevation: 8)),
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

class _ControlledPreferences implements SharedPreferences {
  _ControlledPreferences(this.delegate);

  final SharedPreferences delegate;
  Completer<void>? writeGate;
  bool failWrite = false;

  @override
  Object? get(String key) => delegate.get(key);

  @override
  Future<bool> setString(String key, String value) async {
    final gate = writeGate;
    writeGate = null;
    await gate?.future;
    return failWrite ? false : delegate.setString(key, value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

NovelReadingProgress _position() => NovelReadingProgress(
  pathWord: 'novel-a',
  name: '小说 A',
  cover: '',
  volumeId: 'volume-1',
  volumeName: '第一卷',
  chapterName: '第一卷 第二章',
  entryIndex: 8,
  paragraphIndex: 12,
  paragraphAlignment: -0.35,
  progress: 0.42,
  updatedAt: DateTime.utc(2026, 9, 25),
);

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/novel_reading_progress.dart';
import 'package:kira/pages/browse_history_page.dart';
import 'package:kira/pages/novel_history_page.dart';
import 'package:kira/providers/novel_providers.dart';
import 'package:kira/routing/app_router.dart';
import 'package:kira/utils/novel_reading_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _HistoryStore extends NovelReadingStore {
  List<NovelReadingProgress> items = [_position()];
  bool failRemove = false;
  Completer<void>? recentGate;

  @override
  Future<List<NovelReadingProgress>> readRecent({int limit = 30}) async {
    await recentGate?.future;
    return items.take(limit).toList();
  }

  @override
  Future<NovelReadingProgress?> readProgress(String pathWord) async =>
      items.where((item) => item.pathWord == pathWord).firstOrNull;

  @override
  Future<void> removeProgress(String pathWord) async {
    if (failRemove) throw StateError('test write failure');
    items.removeWhere((item) => item.pathWord == pathWord);
    NovelReadingStore.notifyChanged();
  }

  @override
  Future<void> clear() async {
    if (failRemove) throw StateError('test write failure');
    items.clear();
    NovelReadingStore.notifyChanged();
  }
}

NovelReadingProgress _position({String volume = 'volume-1', int entry = 1}) =>
    NovelReadingProgress(
      pathWord: 'book',
      name: '小说历史',
      cover: '',
      volumeId: volume,
      volumeName: volume,
      chapterName: '章节 $entry',
      entryIndex: entry,
      paragraphIndex: 12,
      paragraphAlignment: -0.3,
      progress: 0.25,
      updatedAt: DateTime.utc(2026, 9, 26),
    );

Future<GoRouter> _pump(
  WidgetTester tester,
  _HistoryStore store, {
  bool combined = false,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => combined
            ? BrowseHistoryPage(loginPageBuilder: (_) => const SizedBox())
            : const NovelHistoryPage(),
      ),
      GoRoute(
        path: '/reader/:pathWord/:volumeId',
        name: AppRoutes.novelReader,
        builder: (_, state) {
          final extra = state.extra;
          return Scaffold(
            body: Text(
              'reader:${state.pathParameters['volumeId']}:'
              '${extra is NovelReaderExtra ? extra.entryIndex : -1}:'
              '${extra is NovelReaderExtra && extra.resume}',
            ),
          );
        },
      ),
      GoRoute(
        path: '/details/:pathWord',
        name: AppRoutes.novelDetail,
        builder: (_, state) =>
            Scaffold(body: Text('details:${state.pathParameters['pathWord']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [novelReadingStoreProvider.overrideWithValue(store)],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (combined) {
    await tester.tap(find.text('轻小说'));
    await tester.pumpAndSettle();
  }
  return router;
}

Future<void> _action(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const ValueKey('novel_history_actions_book')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final combined in [false, true]) {
    testWidgets(
      'history entry ($combined) reuses the body and resumes the newest volume',
      (tester) async {
        final store = _HistoryStore();
        final router = await _pump(tester, store, combined: combined);
        expect(find.byType(NovelHistoryBody), findsOneWidget);

        // 通知触发的列表读取尚未完成，屏幕上仍是旧卡片。
        store.items = [_position(volume: 'volume-2', entry: 8)];
        store.recentGate = Completer<void>();
        NovelReadingStore.notifyChanged();
        await tester.pump();
        expect(find.textContaining('volume-1'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('novel_history_book')));
        await tester.pumpAndSettle();
        expect(find.text('reader:volume-2:8:true'), findsOneWidget);

        store.recentGate!.complete();
        store.recentGate = null;
        // 模拟阅读器又切了一卷，但返回前的通知没有到达列表。
        store.items = [_position(volume: 'volume-3', entry: 11)];
        router.pop();
        await tester.pumpAndSettle();
        expect(find.textContaining('volume-3'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('novel_history_book')));
        await tester.pumpAndSettle();
        expect(find.text('reader:volume-3:11:true'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'progress notifications refresh visible cards and removed progress never opens stale volume',
    (tester) async {
      final store = _HistoryStore();
      await _pump(tester, store);
      store.items = [_position(volume: 'volume-new')];
      NovelReadingStore.notifyChanged();
      await tester.pumpAndSettle();
      expect(find.textContaining('volume-new'), findsOneWidget);
      store.items.clear();
      await tester.tap(find.byKey(const ValueKey('novel_history_book')));
      await tester.pumpAndSettle();
      expect(find.textContaining('reader:'), findsNothing);
      expect(find.text('开始阅读后，进度会保存在这里'), findsOneWidget);
    },
  );

  testWidgets(
    'details, failed deletion, successful deletion and clear confirmation stay available',
    (tester) async {
      final store = _HistoryStore();
      final router = await _pump(tester, store);
      await _action(tester, '查看详情');
      expect(find.text('details:book'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      store.failRemove = true;
      await _action(tester, '移除阅读记录');
      expect(find.byKey(const ValueKey('novel_history_book')), findsOneWidget);
      expect(store.items, hasLength(1));
      store.failRemove = false;
      await _action(tester, '移除阅读记录');
      expect(store.items, isEmpty);
      expect(find.text('开始阅读后，进度会保存在这里'), findsOneWidget);

      store.items = [_position()];
      NovelReadingStore.notifyChanged();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('清空阅读记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.items, hasLength(1));
      await tester.tap(find.byTooltip('清空阅读记录'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(store.items, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

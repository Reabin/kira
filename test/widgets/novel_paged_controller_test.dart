import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/novel/novel_api.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/widgets/novel_paged_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

NovelPage<String> _page(List<String> items, {int? total, int offset = 0}) =>
    NovelPage(
      list: items,
      total: total ?? items.length,
      limit: 18,
      offset: offset,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('保留结果刷新失败使用独立错误，重试首屏替换并重置分页offset', () async {
    final requests = <int>[];
    final refreshing = Completer<NovelPage<String>>();
    final controller = NovelPagedController<String>(
      keyOf: (item) => item,
      loadPage: (offset) {
        requests.add(offset);
        return switch (requests.length) {
          1 => Future.value(_page(['old', 'old'], total: 3)),
          2 => refreshing.future,
          3 => Future.value(_page(['new'], total: 2)),
          _ => Future.value(_page(['next'], total: 2, offset: offset)),
        };
      },
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    final refresh = controller.refresh(keepItems: true);
    expect(controller.items, ['old']);
    expect(controller.loading, isTrue);
    expect(controller.refreshing, isTrue);
    refreshing.completeError(const NovelApiException('offline'));
    await refresh;
    expect(controller.items, ['old']);
    expect(controller.error, isNull);
    expect(controller.refreshError, isA<NovelApiException>());
    expect(controller.loading, isFalse);
    expect(controller.refreshing, isFalse);
    await controller.loadMore();
    expect(requests, [0, 0]);
    await controller.refresh(keepItems: true);
    expect(controller.items, ['new']);
    expect(controller.refreshError, isNull);
    await controller.loadMore();
    expect(requests, [0, 0, 0, 1]);
    expect(controller.items, ['new', 'next']);
    expect(controller.hasMore, isFalse);
  });

  for (final fail in [false, true]) {
    test('保留结果刷新使旧分页${fail ? '错误' : '结果'}失效', () async {
      final pending = Completer<NovelPage<String>>();
      var refreshed = false;
      final controller = NovelPagedController<String>(
        keyOf: (item) => item,
        loadPage: (offset) async {
          if (offset > 0) return pending.future;
          return refreshed ? _page(['new']) : _page(['old'], total: 2);
        },
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      final old = controller.loadMore();
      refreshed = true;
      await controller.refresh(keepItems: true);
      if (fail) {
        pending.completeError(const NovelApiException('stale failure'));
      } else {
        pending.complete(_page(['stale'], total: 2, offset: 1));
      }
      await old;
      expect(controller.items, ['new']);
      expect(controller.hasMore, isFalse);
      expect(controller.error, isNull);
      expect(controller.refreshError, isNull);
    });
  }

  test('新查询默认清空旧结果并丢弃在途保留刷新', () async {
    final pending = Completer<NovelPage<String>>();
    var requests = 0;
    final controller = NovelPagedController<String>(
      keyOf: (item) => item,
      loadPage: (_) => switch (++requests) {
        1 => Future.value(_page(['old'])),
        2 => pending.future,
        _ => Future.value(_page(['new query'])),
      },
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    final staleRefresh = controller.refresh(keepItems: true);
    final newQuery = controller.refresh();
    expect(controller.items, isEmpty);
    await newQuery;
    pending.complete(_page(['stale refresh']));
    await staleRefresh;
    expect(controller.items, ['new query']);
    expect(controller.refreshError, isNull);
  });
}

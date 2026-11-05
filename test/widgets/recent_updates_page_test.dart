import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/manga/manga_api.dart';
import 'package:kira/models/api_ordering.dart';
import 'package:kira/models/comic.dart' hide Theme;
import 'package:kira/models/recent_updates_settings.dart';
import 'package:kira/pages/recent_updates_page.dart';
import 'package:kira/providers/app_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test_helpers.dart';

class _Manga extends Fake implements MangaApi {
  final offsets = <int>[];
  @override
  Future<({List<Comic> list, int total})> getCopyComicList({
    String ordering = ApiOrdering.popular,
    int limit = 21,
    int offset = 0,
    String? theme,
    String? top,
  }) async {
    expect(ordering, ApiOrdering.datetimeUpdated);
    offsets.add(offset);
    return (
      list: List.generate(
        offset == 0 ? 12 : 2,
        (i) => Comic.fromJson({
          'name': 'comic${offset + i}',
          'path_word': 'comic${offset + i}',
          'cover': '',
        }),
      ),
      total: 14,
    );
  }
}

void main() {
  testWidgets(
    'More page continues from filtered cursor and refreshes first page',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        RecentUpdatesSettings.preferenceKey: ['0', '1', '2'],
      });
      final api = _Manga();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [mangaApiProvider.overrideWithValue(api)],
          child: wrapWithApp(
            const RecentUpdatesPage(isCopy: true),
            wrapInScaffold: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.offsets, [0]);
      expect(
        tester
            .widget<SliverGrid>(find.byType(SliverGrid))
            .delegate
            .estimatedChildCount,
        12,
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2200));
      await tester.pumpAndSettle();
      expect(api.offsets, [0, 12]);
      expect(
        tester
            .widget<SliverGrid>(find.byType(SliverGrid))
            .delegate
            .estimatedChildCount,
        14,
      );
      final refresh = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator),
      );
      await tester.runAsync(refresh.onRefresh);
      await tester.pumpAndSettle();
      expect(api.offsets.last, 0);
    },
  );
}

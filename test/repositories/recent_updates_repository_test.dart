import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/comic.dart';
import 'package:kira/models/recent_updates_settings.dart';
import 'package:kira/repositories/recent_updates_repository.dart';
import 'package:kira/utils/app_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

Comic comic(String id, [String? region]) => Comic.fromJson({
  'name': id,
  'path_word': id,
  'cover': '',
  if (region != null) 'region': {'name': region},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'Workers refill without batch barriers and emit only update-ordered results',
    () async {
      final pending = List.generate(6, (_) => Completer<Comic>());
      final started = <int>[];
      final previews = <List<String>>[];
      final repo = RecentUpdatesRepository(
        isCopy: true,
        regions: {0},
        fetchPage: (_) async =>
            (list: List.generate(6, (i) => comic('$i')), total: 6),
        fetchDetail: (id) {
          final i = int.parse(id);
          started.add(i);
          return pending[i].future;
        },
        onProgress: (items) =>
            previews.add(items.map((c) => c.pathWord).toList()),
      );
      final loading = repo.load();
      Future<void> drain() async {
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      await drain();
      expect(started, [0, 1, 2, 3]);
      pending[1].complete(comic('1', '日本'));
      await drain();
      expect(started, [0, 1, 2, 3, 4]);
      expect(previews, isEmpty);
      pending[0].complete(comic('0', '日本'));
      await drain();
      expect(started, [0, 1, 2, 3, 4, 5]);
      expect(previews.first, ['0', '1']);
      for (var i = 2; i < 6; i++) {
        pending[i].complete(comic('$i', '日本'));
      }
      expect((await loading).comics.map((c) => c.pathWord), [
        '0',
        '1',
        '2',
        '3',
        '4',
        '5',
      ]);
    },
  );

  test(
    'Reuses a previously opened comic detail without fetching region again',
    () async {
      await AppStorage.cache.put('comic_detail_jp', {
        'comic': comic('jp', '日本').toJson(),
      });
      final repo = RecentUpdatesRepository(
        isCopy: true,
        regions: {0},
        fetchPage: (_) async => (list: [comic('jp')], total: 1),
        fetchDetail: (_) async => throw StateError('Detail already cached'),
      );
      expect((await repo.load()).comics.single.pathWord, 'jp');
      await repo.invalidateCache();
      expect(await repo.loadFromCache(), isNull);
      expect((await repo.loadPreviewFromCache())?.comics.single.pathWord, 'jp');
    },
  );

  test(
    'Multi-region results keep every item before the next pagination cursor',
    () async {
      final repo = RecentUpdatesRepository(
        isCopy: true,
        regions: {0, 1},
        fetchPage: (offset) async => (
          list: List.generate(
            21,
            (i) => comic('item${offset + i}', i.isEven ? '日本' : '韩国'),
          ),
          total: 42,
        ),
      );
      final first = await repo.load();
      expect(first.comics, hasLength(21));
      expect(first.nextOffset, 21);
      expect(first.hasMore, isTrue);
      final restored = RecentUpdatesData.fromJson(first.toJson());
      expect(restored.nextOffset, 21);
      final second = await RecentUpdatesRepository(
        isCopy: true,
        regions: {1, 0},
        offset: first.nextOffset,
        fetchPage: (offset) async =>
            (list: [comic('item$offset', '韩国'), comic('us', '美国')], total: 23),
      ).load();
      expect(second.comics.map((c) => c.pathWord), ['item21']);
      expect(second.hasMore, isFalse);
    },
  );

  test(
    'Migrates previous all/Japanese choices and rejects empty selection',
    () async {
      SharedPreferences.setMockInitialValues({
        RecentUpdatesSettings.legacyKey: false,
      });
      final settings = RecentUpdatesSettings();
      await settings.load();
      expect(settings.regions, {0, 1, 2});
      await expectLater(settings.setRegions({}), throwsArgumentError);
      expect(settings.regions, {0, 1, 2});
      settings.dispose();
    },
  );

  test(
    'Recognizes the live detail API display field without treating absent regions as Japan',
    () {
      expect(
        RecentUpdatesRepository.isJapanese(
          Comic.fromJson({
            'name': 'Japanese',
            'path_word': 'jp',
            'cover': '',
            'region': {'value': 0, 'display': '日本'},
          }),
        ),
        isTrue,
      );
      expect(
        RecentUpdatesRepository.isJapanese(
          Comic.fromJson({
            'name': 'Korean',
            'path_word': 'kr',
            'cover': '',
            'region': {'value': 1, 'display': '韩国'},
          }),
        ),
        isFalse,
      );
      expect(RecentUpdatesRepository.isJapanese(comic('unknown')), isFalse);
    },
  );

  test(
    'Japanese filter paginates, deduplicates and preserves update order',
    () async {
      final offsets = <int>[];
      final repo = RecentUpdatesRepository(
        isCopy: true,
        regions: const {0},
        fetchPage: (offset) async {
          offsets.add(offset);
          return (
            list: offset == 0
                ? [comic('jp1', '日本'), comic('kr', '韩国')]
                : [comic('jp1', '日本'), comic('jp2', '日漫')],
            total: 4,
          );
        },
        fetchDetail: (_) async =>
            throw StateError('Known regions need no detail'),
      );
      expect((await repo.load()).comics.map((c) => c.pathWord), ['jp1', 'jp2']);
      expect(offsets, [0, 2]);
    },
  );

  test(
    'Missing regions are verified and cached per source; unknowns excluded',
    () async {
      var details = 0;
      RecentUpdatesRepository repository(bool isCopy) =>
          RecentUpdatesRepository(
            isCopy: isCopy,
            regions: const {0},
            fetchPage: (_) async =>
                (list: [comic('jp'), comic('unknown')], total: 2),
            fetchDetail: (id) async {
              details++;
              return comic(id, id == 'jp' ? '日本' : null);
            },
          );
      final first = repository(true);
      expect((await first.load()).comics.map((c) => c.pathWord), ['jp']);
      expect(details, 2);
      await first.invalidateCache();
      await repository(true).load();
      expect(details, 3); // Only the unknown region needs another lookup.
      await repository(false).load();
      expect(details, 5); // COPY metadata is never reused for HOT.
    },
  );

  test(
    'All mode includes unknown regions without detail requests or Japanese cache',
    () async {
      Future<RecentComicPage> page(int _) async => (
        list: [comic('jp', '日本'), comic('kr', '韩国'), comic('unknown')],
        total: 3,
      );
      await RecentUpdatesRepository(
        isCopy: true,
        regions: const {0},
        fetchPage: page,
        fetchDetail: (id) async => comic(id),
      ).load();
      final all = RecentUpdatesRepository(
        isCopy: true,
        regions: const {0, 1, 2},
        fetchPage: page,
        fetchDetail: (_) async => throw StateError('No detail'),
      );
      expect((await all.load()).comics.map((c) => c.pathWord), [
        'jp',
        'kr',
        'unknown',
      ]);
    },
  );

  test('Home preview stops scanning after five pages', () async {
    var pages = 0;
    final repo = RecentUpdatesRepository(
      isCopy: false,
      regions: const {0},
      fetchPage: (offset) async {
        pages++;
        return (list: [comic('kr$offset', '韩国')], total: 1000);
      },
    );
    expect((await repo.load()).comics, isEmpty);
    expect(pages, 5);
  });

  test(
    'Saved selection survives store recreation and clearing caches',
    () async {
      final settings = RecentUpdatesSettings();
      await settings.load();
      expect(settings.regions, {0});
      await settings.setRegions({0, 1});
      settings.dispose();
      await AppStorage.cache.removeByPrefix('');
      final restored = RecentUpdatesSettings();
      await restored.load();
      expect(restored.regions, {0, 1});
      restored.dispose();
    },
  );
}

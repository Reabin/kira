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
        japaneseOnly: true,
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
            japaneseOnly: true,
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
        japaneseOnly: true,
        fetchPage: page,
        fetchDetail: (id) async => comic(id),
      ).load();
      final all = RecentUpdatesRepository(
        isCopy: true,
        japaneseOnly: false,
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
      japaneseOnly: true,
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
      expect(settings.japaneseOnly, isTrue);
      await settings.setJapaneseOnly(false);
      settings.dispose();
      await AppStorage.cache.removeByPrefix('');
      final restored = RecentUpdatesSettings();
      await restored.load();
      expect(restored.japaneseOnly, isFalse);
      restored.dispose();
    },
  );
}

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/novel/novel_api.dart';
import 'package:kira/models/api_ordering.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/repositories/novel_bookshelf_repository.dart';
import 'package:kira/utils/app_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'novel_api_test.dart'
    show NovelTestAdapter, NovelTestUser, novelJsonResponse;

NovelShelfEntry _entry(String id) => NovelShelfEntry(
  uuid: id.hashCode,
  book: NovelBook(uuid: id, pathWord: id, name: id),
);

NovelPage<NovelShelfEntry> _page(String id, {int offset = 0, int total = 1}) =>
    NovelPage(list: [_entry(id)], total: total, limit: 18, offset: offset);

class _Api implements NovelApi {
  @override
  String cacheScope = 'fingerprint-a';
  final calls = <(String, String, int)>[];
  Future<NovelPage<NovelShelfEntry>> Function(String, String, int)? respond;
  Future<void> Function()? mutate;

  @override
  Future<NovelPage<NovelShelfEntry>> getBookshelf({
    int limit = 18,
    int offset = 0,
    int freeType = 1,
    String ordering = ApiOrdering.datetimeModifier,
  }) {
    calls.add((cacheScope, ordering, offset));
    return respond?.call(cacheScope, ordering, offset) ??
        Future.value(_page(cacheScope));
  }

  @override
  Future<void> setCollected({
    required String bookUuid,
    required bool collected,
  }) async {
    await mutate?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('$invocation');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => SharedPreferences.setMockInitialValues({}));
  setUp(() async => (await AppStorage.sharedPreferences()).clear());

  test(
    'three comic-compatible orderings reach existing novel endpoint and persist no token',
    () async {
      final user = NovelTestUser()
        ..copyToken = 'SECRET_COPY_TOKEN_NOT_FOR_PREFS';
      final adapter = NovelTestAdapter(
        (options, _) => novelJsonResponse({
          'list': [],
          'total': 0,
          'limit': 18,
          'offset': 0,
        }),
      );
      final api = NovelApi.withDio(
        user: user,
        dio: Dio()..httpClientAdapter = adapter,
        contentDio: Dio()
          ..httpClientAdapter = NovelTestAdapter(
            (_, _) => throw StateError('No content requests'),
          ),
      );
      final repo = NovelBookshelfRepository(api: api);
      addTearDown(repo.dispose);
      addTearDown(api.close);
      addTearDown(user.dispose);
      expect(
        NovelBookshelfRepository.orderings,
        contains(ApiOrdering.datetimeBrowse),
      );
      for (final ordering in NovelBookshelfRepository.orderings) {
        final data = await repo.load(ordering: ordering);
        expect(data.scope, api.cacheScope);
        expect(data.ordering, ordering);
        expect((await repo.load(ordering: ordering)).items, isEmpty);
      }
      expect(adapter.requests.length, 3);
      expect(adapter.requests.map((r) => r.uri.path).toSet(), {
        '/api/v3/member/collect/books',
      });
      expect(
        adapter.requests.map((r) => r.queryParameters['ordering']),
        NovelBookshelfRepository.orderings,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().length, 3);
      for (final key in prefs.getKeys()) {
        expect(key, contains(api.cacheScope));
        expect('$key ${prefs.get(key)}', isNot(contains(user.copyToken!)));
      }
    },
  );

  test(
    'legacy migration removes plaintext envelope only and is idempotent',
    () async {
      final initial = await AppStorage.sharedPreferences();
      await initial.setString(
        'cache_bookshelf_novel',
        '{"scope":"host|RAW_TOKEN"}',
      );
      await initial.setString('cache_bookshelf_comic', 'keep');
      await initial.setString('reader_novel_settings_v1', 'keep');
      await NovelBookshelfRepository.migrateLegacyCache();
      await NovelBookshelfRepository.migrateLegacyCache();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('cache_bookshelf_novel'), isFalse);
      expect(prefs.getKeys(), {
        'cache_bookshelf_comic',
        'reader_novel_settings_v1',
      });
    },
  );

  test(
    'fresh caches partition account, host and ordering, including empty results',
    () async {
      final api = _Api();
      final repo = NovelBookshelfRepository(api: api);
      addTearDown(repo.dispose);
      for (final scope in [
        'account-a-host-a',
        'account-b-host-a',
        'account-b-host-b',
      ]) {
        api.cacheScope = scope;
        for (final ordering in NovelBookshelfRepository.orderings) {
          await repo.load(ordering: ordering);
        }
      }
      expect(api.calls.length, 9);
      api.cacheScope = 'account-a-host-a';
      expect((await repo.load()).items.single.book.name, 'account-a-host-a');
      expect(api.calls.length, 9);
    },
  );

  test(
    'pending old identity neither blocks new cached identity nor writes late response',
    () async {
      final api = _Api()..cacheScope = 'fingerprint-b';
      final repo = NovelBookshelfRepository(api: api);
      addTearDown(repo.dispose);
      await repo.load();
      final old = Completer<NovelPage<NovelShelfEntry>>();
      api.cacheScope = 'fingerprint-a';
      api.respond = (_, _, _) => old.future;
      final oldResult = expectLater(
        repo.load(),
        throwsA(isA<NovelIdentityChangedException>()),
      );
      await Future<void>.delayed(Duration.zero);
      api.cacheScope = 'fingerprint-b';
      expect((await repo.load()).items.single.book.name, 'fingerprint-b');
      old.complete(_page('old'));
      await oldResult;
      api.cacheScope = 'fingerprint-a';
      expect(await repo.loadFromCache(), isNull);
    },
  );

  test(
    'same first-page and forced refresh calls coalesce; another ordering is independent',
    () async {
      final api = _Api();
      final repo = NovelBookshelfRepository(api: api);
      addTearDown(repo.dispose);
      final old = Completer<NovelPage<NovelShelfEntry>>();
      api.respond = (_, ordering, _) => ordering == ApiOrdering.datetimeModifier
          ? old.future
          : Future.value(_page('browse'));
      final first = repo.load();
      final second = repo.load();
      await Future<void>.delayed(Duration.zero);
      expect(api.calls.length, 1);
      expect(
        (await repo.load(
          ordering: ApiOrdering.datetimeBrowse,
        )).items.single.book.name,
        'browse',
      );
      final refresh1 = repo.forceRefreshApi();
      final refresh2 = repo.forceRefreshApi();
      old.complete(_page('initial'));
      await Future.wait([first, second, refresh1, refresh2]);
      expect(
        api.calls
            .where((call) => call.$2 == ApiOrdering.datetimeModifier)
            .length,
        2,
      );
    },
  );

  test(
    'collection invalidates all own sort caches, not another account, and notifies once',
    () async {
      final api = _Api();
      final repo = NovelBookshelfRepository(api: api);
      addTearDown(repo.dispose);
      for (final ordering in NovelBookshelfRepository.orderings) {
        await repo.load(ordering: ordering);
      }
      api.cacheScope = 'fingerprint-b';
      await repo.load();
      api.cacheScope = 'fingerprint-a';
      var notifications = 0;
      repo.addListener(() => notifications++);
      await repo.setCollected(bookUuid: 'book', collected: false);
      expect(notifications, 1);
      expect(repo.invalidatedScope, 'fingerprint-a');
      for (final ordering in NovelBookshelfRepository.orderings) {
        expect(await repo.loadFromCache(ordering: ordering), isNull);
      }
      api.cacheScope = 'fingerprint-b';
      expect(await repo.loadFromCache(), isNotNull);
      await repo.setCollected(bookUuid: 'book', collected: true);
      expect(notifications, 2);
    },
  );

  test(
    'deletion retires late first page and pagination; reconstruction cannot revive it',
    () async {
      final api = _Api();
      final repo = NovelBookshelfRepository(api: api);
      addTearDown(repo.dispose);
      await repo.load();
      final late = Completer<NovelPage<NovelShelfEntry>>();
      api.respond = (_, _, _) => late.future;
      final oldFirst = expectLater(
        repo.forceRefreshApi(),
        throwsA(isA<NovelIdentityChangedException>()),
      );
      final oldPage = expectLater(
        repo.loadPage(offset: 18),
        throwsA(isA<NovelIdentityChangedException>()),
      );
      await repo.setCollected(bookUuid: 'book', collected: false);
      late.complete(_page('deleted-book'));
      await Future.wait([oldFirst, oldPage]);
      final rebuilt = NovelBookshelfRepository(api: api);
      addTearDown(rebuilt.dispose);
      expect(await rebuilt.loadFromCache(), isNull);
      api.respond = (_, _, _) => Future.value(
        const NovelPage(list: [], total: 0, limit: 18, offset: 0),
      );
      expect((await rebuilt.load()).items, isEmpty);
      expect((await rebuilt.load()).items, isEmpty);
    },
  );

  test(
    'failed collection preserves cache and emits no successful-change notice',
    () async {
      final api = _Api();
      final repo = NovelBookshelfRepository(api: api);
      addTearDown(repo.dispose);
      await repo.load();
      var notifications = 0;
      repo.addListener(() => notifications++);
      api.mutate = () async => throw const NovelApiException('failure');
      await expectLater(
        repo.setCollected(bookUuid: 'book', collected: false),
        throwsA(isA<NovelApiException>()),
      );
      expect(await repo.loadFromCache(), isNotNull);
      expect(notifications, 0);
    },
  );

  test(
    'pagination deduplicates same scope ordering offset but not other orderings',
    () async {
      final api = _Api();
      final repo = NovelBookshelfRepository(api: api);
      addTearDown(repo.dispose);
      final pending = Completer<NovelPage<NovelShelfEntry>>();
      api.respond = (_, _, _) => pending.future;
      final a = repo.loadPage(offset: 18);
      final b = repo.loadPage(offset: 18);
      final c = repo.loadPage(offset: 18, ordering: ApiOrdering.datetimeBrowse);
      expect(identical(a, b), isTrue);
      expect(api.calls.length, 2);
      pending.complete(_page('next', offset: 18));
      await Future.wait([a, b, c]);
    },
  );

  test(
    'new first-page generation never shares an older pending pagination',
    () async {
      final api = _Api();
      final repo = NovelBookshelfRepository(api: api);
      addTearDown(repo.dispose);
      await repo.load();
      final old = Completer<NovelPage<NovelShelfEntry>>();
      api.respond = (_, _, offset) =>
          offset > 0 ? old.future : Future.value(_page('fresh'));
      final oldPage = repo.loadPage(offset: 18);
      await repo.forceRefreshApi();
      api.respond = (_, _, offset) async => _page('fresh-page', offset: offset);
      final newPage = await repo.loadPage(offset: 18);
      expect(newPage.list.single.book.name, 'fresh-page');
      old.complete(_page('old-page', offset: 18));
      await oldPage;
      expect(api.calls.where((call) => call.$3 == 18).length, 2);
    },
  );

  test('expired cache and corrupt JSON safely fall back to API', () async {
    final api = _Api();
    final repo = NovelBookshelfRepository(api: api);
    addTearDown(repo.dispose);
    await repo.load();
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getKeys().single;
    await AppStorage.cache.put(
      key,
      NovelShelfCache(
        items: [_entry('stale')],
        total: 1,
        scope: api.cacheScope,
        cacheTime: DateTime.now().subtract(const Duration(minutes: 31)),
      ).toJson(),
      ttl: const Duration(hours: 1),
    );
    expect((await repo.load()).items.single.book.name, api.cacheScope);
    await prefs.setString(key, 'invalid json');
    expect((await repo.load()).items.single.book.name, api.cacheScope);
    expect(api.calls.length, 3);
    final malformed = NovelShelfCache.fromJson({
      'items': [1, null],
      'total': 'bad',
      'cache_time': '999999999999999999',
    });
    expect(malformed.items, isEmpty);
    expect(malformed.cacheTime, isNull);
  });
}

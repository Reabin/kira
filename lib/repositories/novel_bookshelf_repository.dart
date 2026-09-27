import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/novel/novel_api.dart';
import '../models/api_ordering.dart';
import '../models/cached_repository.dart';
import '../models/novel.dart';
import '../utils/app_logger.dart';
import '../utils/app_storage.dart';
import '../utils/json_helpers.dart';

/// First-page cache. Scope is exclusively NovelApi's credential fingerprint.
class NovelShelfCache {
  final List<NovelShelfEntry> items;
  final int total;
  final String scope;
  final String ordering;
  final int? _nextOffset;
  int get nextOffset => _nextOffset ?? items.length;
  final DateTime? cacheTime;

  const NovelShelfCache({
    required this.items,
    required this.total,
    required this.scope,
    this.ordering = ApiOrdering.datetimeModifier,
    int? nextOffset,
    this.cacheTime,
  }) : _nextOffset = nextOffset;

  factory NovelShelfCache.fromJson(Map<String, dynamic> json) {
    final items = [
      for (final value in jsonList(json, 'items'))
        if (jsonMap({'value': value}, 'value') case final entry?)
          NovelShelfEntry.fromJson(entry),
    ];
    final milliseconds = jsonInt(json, 'cache_time');
    return NovelShelfCache(
      items: items,
      total: jsonInt(json, 'total'),
      scope: jsonString(json, 'scope'),
      ordering: jsonString(json, 'ordering'),
      nextOffset: jsonInt(json, 'next_offset', fallback: items.length),
      cacheTime: milliseconds > 0 && milliseconds <= 8640000000000000
          ? DateTime.fromMillisecondsSinceEpoch(milliseconds)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'items': items.map((e) => e.toJson()).toList(),
    'total': total,
    'scope': scope,
    'ordering': ordering,
    'next_offset': nextOffset,
    'cache_time': cacheTime?.millisecondsSinceEpoch,
  };
}

/// Owns independent TTL-gated repositories for each account/host + ordering.
/// Invalidations also retire in-flight reads before notifying resident pages.
class NovelBookshelfRepository extends ChangeNotifier {
  NovelBookshelfRepository({required NovelApi api}) : _api = api;

  static const cacheTtl = Duration(minutes: 30);
  static const orderings = [
    ApiOrdering.datetimeUpdated,
    ApiOrdering.datetimeModifier,
    ApiOrdering.datetimeBrowse,
  ];

  final NovelApi _api;
  final _partitions = <(String, String), _ShelfPartition>{};
  final _revisions = <String, int>{};
  final _pages =
      <(_ShelfPartition, int, int), Future<NovelPage<NovelShelfEntry>>>{};
  Future<void> _writes = Future.value();
  bool _disposed = false;
  String ordering = ApiOrdering.datetimeModifier;
  String? invalidatedScope;

  /// Remove the legacy envelope, which could contain a plaintext COPY token.
  static Future<void> migrateLegacyCache() =>
      AppStorage.cache.remove('bookshelf_novel');

  static String _prefix(String scope) => 'bookshelf_novel_v2_${scope}_';

  _ShelfPartition _partition(String? ordering) {
    final selected = ordering ?? this.ordering;
    if (!orderings.contains(selected)) {
      throw ArgumentError.value(selected, 'ordering');
    }
    final scope = _api.cacheScope;
    final revision = _revisions[scope] ?? 0;
    return _partitions.putIfAbsent(
      (scope, selected),
      () => _ShelfPartition(
        api: _api,
        scope: scope,
        ordering: selected,
        cacheKey: '${_prefix(scope)}$selected',
        isCurrent: () =>
            !_disposed &&
            (_revisions[scope] ?? 0) == revision &&
            _api.cacheScope == scope,
        write: _write,
      ),
    );
  }

  Future<void> _write(Future<void> Function() operation) {
    final result = _writes.then((_) => operation());
    _writes = result.catchError((Object error, StackTrace stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          error,
          stackTrace: stack,
          source: 'novel_bookshelf.cache',
        ),
      );
    });
    return result;
  }

  Future<NovelShelfCache?> loadFromCache({String? ordering}) =>
      _partition(ordering).loadFromCache();

  Future<NovelShelfCache> load({String? ordering}) {
    final partition = _partition(ordering);
    _retirePages(partition);
    return partition.load();
  }

  Future<NovelShelfCache> forceRefreshApi({String? ordering}) {
    final partition = _partition(ordering);
    _retirePages(partition);
    return partition.forceRefreshApi();
  }

  void _retirePages(_ShelfPartition partition) {
    // A new first page starts a new list generation. Do not let its later
    // pagination callers join a request made against the previous snapshot.
    _pages.removeWhere((key, _) => identical(key.$1, partition));
  }

  Future<NovelPage<NovelShelfEntry>> loadPage({
    required int offset,
    int limit = 18,
    String? ordering,
  }) {
    final partition = _partition(ordering);
    final key = (partition, offset, limit);
    final existing = _pages[key];
    if (existing != null) return existing;
    late final Future<NovelPage<NovelShelfEntry>> pending;
    pending = partition.fetchPage(offset: offset, limit: limit).whenComplete(
      () {
        if (identical(_pages[key], pending)) _pages.remove(key);
      },
    );
    _pages[key] = pending;
    return pending;
  }

  Future<void> invalidateCache() => _invalidateScope(_api.cacheScope);

  Future<void> _invalidateScope(String scope) async {
    _revisions[scope] = (_revisions[scope] ?? 0) + 1;
    _partitions.removeWhere((key, _) => key.$1 == scope);
    // Serialized with saves: a response already writing cannot resurrect a
    // deleted collection. New requests queue their saves after this removal.
    await _write(() => AppStorage.cache.removeByPrefix(_prefix(scope)));
    if (_disposed) return;
    invalidatedScope = scope;
    notifyListeners();
  }

  Future<void> setCollected({
    required String bookUuid,
    required bool collected,
  }) async {
    final scope = _api.cacheScope;
    try {
      await _api.setCollected(bookUuid: bookUuid, collected: collected);
    } on NovelIdentityChangedException {
      // The mutation may already have reached the old account on the server.
      await _invalidateScope(scope);
      rethrow;
    }
    await _invalidateScope(scope);
  }

  @override
  void dispose() {
    _disposed = true;
    _partitions.clear();
    super.dispose();
  }
}

class _ShelfPartition extends CachedRepository<NovelShelfCache> {
  _ShelfPartition({
    required NovelApi api,
    required this.scope,
    required this.ordering,
    required super.cacheKey,
    required this.isCurrent,
    required this.write,
  }) : _api = api,
       super(
         ttl: NovelBookshelfRepository.cacheTtl,
         skipApiIfCacheFresh: true,
         deserialize: NovelShelfCache.fromJson,
         serialize: (data) => data.toJson(),
       );

  final NovelApi _api;
  final String scope;
  final String ordering;
  final bool Function() isCurrent;
  final Future<void> Function(Future<void> Function()) write;

  void _checkCurrent() {
    if (!isCurrent()) throw const NovelIdentityChangedException();
  }

  @override
  Future<NovelShelfCache?> loadFromCache() async {
    _checkCurrent();
    NovelShelfCache? cached;
    try {
      cached = await super.loadFromCache();
    } catch (error, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          error,
          stackTrace: stack,
          source: 'novel_bookshelf.read_cache',
        ),
      );
    }
    _checkCurrent();
    if (cached == null ||
        cached.scope != scope ||
        cached.ordering != ordering ||
        cached.cacheTime == null ||
        DateTime.now().difference(cached.cacheTime!) >=
            NovelBookshelfRepository.cacheTtl) {
      return null;
    }
    return cached;
  }

  Future<NovelPage<NovelShelfEntry>> fetchPage({
    int offset = 0,
    int limit = 18,
  }) async {
    _checkCurrent();
    final page = await _api.getBookshelf(
      ordering: ordering,
      offset: offset,
      limit: limit,
    );
    _checkCurrent();
    return page;
  }

  @override
  Future<NovelShelfCache> fetchFromApi() async {
    final page = await fetchPage();
    return NovelShelfCache(
      items: page.list,
      total: page.total,
      nextOffset: page.offset + page.list.length,
      scope: scope,
      ordering: ordering,
      cacheTime: DateTime.now(),
    );
  }

  @override
  Future<void> saveToCache(NovelShelfCache data) => write(() async {
    _checkCurrent();
    await super.saveToCache(data);
    _checkCurrent();
  });
}

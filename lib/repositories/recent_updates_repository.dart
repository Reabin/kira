import '../api/api_client.dart';
import '../models/api_ordering.dart';
import '../models/cached_repository.dart';
import '../models/comic.dart' hide Theme;
import '../models/recent_updates_settings.dart';
import '../utils/app_storage.dart';
import '../utils/json_helpers.dart';

typedef RecentComicPage = ({List<Comic> list, int total});

class RecentUpdatesData {
  const RecentUpdatesData(
    this.comics, {
    this.nextOffset = 0,
    this.hasMore = false,
  });
  final int nextOffset;
  final bool hasMore;
  final List<Comic> comics;

  factory RecentUpdatesData.fromJson(Map<String, dynamic> json) =>
      RecentUpdatesData(
        [
          for (final item in jsonList(json, 'comics').whereType<Map>())
            Comic.fromJson(Map<String, dynamic>.from(item)),
        ],
        nextOffset: jsonInt(json, 'next_offset'),
        hasMore: jsonBool(json, 'has_more'),
      );

  Map<String, dynamic> toJson() => {
    'comics': comics.map((comic) => comic.toJson()).toList(),
    'next_offset': nextOffset,
    'has_more': hasMore,
  };
}

class RecentUpdatesRepository extends CachedRepository<RecentUpdatesData> {
  RecentUpdatesRepository({
    required this.isCopy,
    required Set<int> regions,
    this.offset = 0,
    this.onProgress,
    Future<RecentComicPage> Function(int offset)? fetchPage,
    Future<Comic> Function(String pathWord)? fetchDetail,
  }) : regions = Set.unmodifiable(regions),
       _fetchPage = fetchPage,
       _fetchDetail = fetchDetail,
       super(
         cacheKey:
             'recent_updates_v2_${isCopy ? 'copy' : 'hot'}_${(regions.toList()..sort()).join('-')}_$offset',
         ttl: const Duration(minutes: 5),
         skipApiIfCacheFresh: true,
         deserialize: RecentUpdatesData.fromJson,
         serialize: (data) => data.toJson(),
       );

  final bool isCopy;
  final Set<int> regions;
  final int offset;
  final void Function(List<Comic>)? onProgress;
  bool get allRegions => regions.containsAll(RecentUpdatesSettings.allRegions);
  final Future<RecentComicPage> Function(int offset)? _fetchPage;
  final Future<Comic> Function(String pathWord)? _fetchDetail;

  String get _previewKey => 'recent_preview_$cacheKey';

  Future<RecentUpdatesData?> loadPreviewFromCache() async {
    final fresh = await loadFromCache();
    if (fresh != null) return fresh;
    final cached = await AppStorage.cache.get(_previewKey);
    return cached is Map
        ? RecentUpdatesData.fromJson(Map<String, dynamic>.from(cached))
        : null;
  }

  @override
  Future<void> saveToCache(RecentUpdatesData data) async {
    await super.saveToCache(data);
    if (offset == 0) {
      await AppStorage.cache.put(
        _previewKey,
        data.toJson(),
        ttl: const Duration(hours: 1),
      );
    }
  }

  @override
  Future<void> invalidateCache() => AppStorage.cache.removeByPrefix(
    cacheKey.substring(0, cacheKey.lastIndexOf('_') + 1),
  );

  static int? regionOf(Comic comic) {
    final display = jsonString(comic.region, 'display');
    final name =
        (display.isNotEmpty ? display : jsonString(comic.region, 'name'))
            .trim()
            .toLowerCase();
    if (const {
      '日本',
      '日漫',
      '日本漫画',
      '日本漫畫',
      'japan',
      'japanese',
    }.contains(name)) {
      return 0;
    }
    if (const {'韩国', '韓國', '韩漫', '韓漫', 'korea', 'korean'}.contains(name)) {
      return 1;
    }
    if (const {
      '欧美',
      '歐美',
      '美漫',
      '美国',
      '美國',
      'western',
      'america',
      'american',
    }.contains(name)) {
      return 2;
    }
    final value = comic.region?['value'];
    return value is int && RecentUpdatesSettings.allRegions.contains(value)
        ? value
        : null;
  }

  static bool isJapanese(Comic comic) => regionOf(comic) == 0;

  Future<Comic> _withRegion(Comic comic) async {
    bool hasRegion(Comic value) =>
        jsonString(value.region, 'name').isNotEmpty ||
        jsonString(value.region, 'display').isNotEmpty;
    if (hasRegion(comic)) return comic;
    final key = 'recent_region_v1_${isCopy ? 'copy' : 'hot'}_${comic.pathWord}';
    final cached = await AppStorage.cache.get(key);
    if (cached is Map) {
      return comic.copyWith(region: Map<String, dynamic>.from(cached));
    }
    // Opening a comic may already have cached its region in the detail repository.
    final detailCache = await AppStorage.cache.get(
      'comic_detail_${comic.pathWord}',
    );
    if (detailCache is Map) {
      final cachedComic = jsonMap(
        Map<String, dynamic>.from(detailCache),
        'comic',
      );
      final region = cachedComic == null
          ? null
          : jsonMap(cachedComic, 'region');
      if (region != null) {
        final resolved = comic.copyWith(region: region);
        if (hasRegion(resolved)) return resolved;
      }
    }
    final detail =
        await (_fetchDetail?.call(comic.pathWord) ??
            // Use the app's working detail route, also used when opening COPY cards.
            ApiClient().manga.getComicDetail(comic.pathWord));
    if (detail.region != null && hasRegion(detail)) {
      await AppStorage.cache.put(
        key,
        detail.region,
        ttl: const Duration(days: 30),
      );
    }
    return comic.copyWith(region: detail.region);
  }

  @override
  Future<RecentUpdatesData> fetchFromApi() async {
    final result = <Comic>[];
    final seen = <String>{};
    var nextOffset = offset;
    var hasMore = true;
    // Bound the work on a home preview; never fetch the entire catalogue.
    for (var page = 0; page < 5 && result.length < 12; page++) {
      final api = ApiClient().manga;
      final batch =
          await (_fetchPage?.call(nextOffset) ??
              (isCopy
                  ? api.getCopyComicList(
                      ordering: ApiOrdering.datetimeUpdated,
                      offset: nextOffset,
                    )
                  : api.getComicList(
                      ordering: ApiOrdering.datetimeUpdated,
                      offset: nextOffset,
                    )));
      if (batch.list.isEmpty) {
        hasMore = false;
        break;
      }
      final unique = batch.list
          .where(
            (comic) => comic.pathWord.isNotEmpty && seen.add(comic.pathWord),
          )
          .toList();
      if (allRegions) {
        result.addAll(unique);
        onProgress?.call(List.unmodifiable(result));
      } else {
        final resolved = List<Comic?>.filled(unique.length, null);
        var next = 0;
        var emitted = 0;
        Future<void> worker() async {
          while (next < unique.length) {
            final index = next++;
            resolved[index] = await _withRegion(unique[index]);
            // Emit only a contiguous prefix so update ordering never changes.
            final before = result.length;
            while (emitted < resolved.length && resolved[emitted] != null) {
              final comic = resolved[emitted++]!;
              if (regions.contains(regionOf(comic))) result.add(comic);
            }
            if (result.length != before) {
              onProgress?.call(List.unmodifiable(result));
            }
          }
        }

        await Future.wait(
          List.generate(unique.length < 4 ? unique.length : 4, (_) => worker()),
        );
      }
      nextOffset += batch.list.length;
      hasMore = nextOffset < batch.total;
      if (!hasMore) break;
    }
    return RecentUpdatesData(result, nextOffset: nextOffset, hasMore: hasMore);
  }
}

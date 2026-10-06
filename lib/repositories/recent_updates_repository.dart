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
  bool get allRegions => regions.containsAll(RecentUpdatesSettings.allRegions);
  final Future<RecentComicPage> Function(int offset)? _fetchPage;
  final Future<Comic> Function(String pathWord)? _fetchDetail;

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
      for (var start = 0; start < unique.length; start += 4) {
        final chunk = unique.skip(start).take(4);
        final comics = !allRegions
            ? await Future.wait(chunk.map(_withRegion))
            : chunk.toList();
        result.addAll(
          comics.where(
            (comic) => allRegions || regions.contains(regionOf(comic)),
          ),
        );
      }
      nextOffset += batch.list.length;
      hasMore = nextOffset < batch.total;
      if (!hasMore) break;
    }
    return RecentUpdatesData(result, nextOffset: nextOffset, hasMore: hasMore);
  }
}

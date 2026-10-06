import '../api/api_client.dart';
import '../models/api_ordering.dart';
import '../models/cached_repository.dart';
import '../models/comic.dart' hide Theme;
import '../utils/app_storage.dart';
import '../utils/json_helpers.dart';

typedef RecentComicPage = ({List<Comic> list, int total});

class RecentUpdatesData {
  const RecentUpdatesData(this.comics);
  final List<Comic> comics;

  factory RecentUpdatesData.fromJson(Map<String, dynamic> json) =>
      RecentUpdatesData([
        for (final item in jsonList(json, 'comics').whereType<Map>())
          Comic.fromJson(Map<String, dynamic>.from(item)),
      ]);

  Map<String, dynamic> toJson() => {
    'comics': comics.map((comic) => comic.toJson()).toList(),
  };
}

class RecentUpdatesRepository extends CachedRepository<RecentUpdatesData> {
  RecentUpdatesRepository({
    required this.isCopy,
    required this.japaneseOnly,
    Future<RecentComicPage> Function(int offset)? fetchPage,
    Future<Comic> Function(String pathWord)? fetchDetail,
  }) : _fetchPage = fetchPage,
       _fetchDetail = fetchDetail,
       super(
         cacheKey:
             'recent_updates_v1_${isCopy ? 'copy' : 'hot'}_${japaneseOnly ? 'jp' : 'all'}',
         ttl: const Duration(minutes: 5),
         skipApiIfCacheFresh: true,
         deserialize: RecentUpdatesData.fromJson,
         serialize: (data) => data.toJson(),
       );

  final bool isCopy;
  final bool japaneseOnly;
  final Future<RecentComicPage> Function(int offset)? _fetchPage;
  final Future<Comic> Function(String pathWord)? _fetchDetail;

  static bool isJapanese(Comic comic) {
    // The detail API uses {value: 0, display: 日本}; some lists use name.
    final display = jsonString(comic.region, 'display');
    final name =
        (display.isNotEmpty ? display : jsonString(comic.region, 'name'))
            .trim()
            .toLowerCase();
    return const {
      '日本',
      '日漫',
      '日本漫画',
      '日本漫畫',
      'japan',
      'japanese',
    }.contains(name);
  }

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
    var offset = 0;
    // Bound the work on a home preview; never fetch the entire catalogue.
    for (var page = 0; page < 5 && result.length < 12; page++) {
      final api = ApiClient().manga;
      final batch =
          await (_fetchPage?.call(offset) ??
              (isCopy
                  ? api.getCopyComicList(
                      ordering: ApiOrdering.datetimeUpdated,
                      offset: offset,
                    )
                  : api.getComicList(
                      ordering: ApiOrdering.datetimeUpdated,
                      offset: offset,
                    )));
      if (batch.list.isEmpty) break;
      final unique = batch.list
          .where(
            (comic) => comic.pathWord.isNotEmpty && seen.add(comic.pathWord),
          )
          .toList();
      for (
        var start = 0;
        start < unique.length && result.length < 12;
        start += 4
      ) {
        final chunk = unique.skip(start).take(4);
        final comics = japaneseOnly
            ? await Future.wait(chunk.map(_withRegion))
            : chunk.toList();
        result.addAll(
          comics.where((comic) => !japaneseOnly || isJapanese(comic)),
        );
      }
      offset += batch.list.length;
      if (offset >= batch.total) break;
    }
    return RecentUpdatesData(result.take(12).toList());
  }
}

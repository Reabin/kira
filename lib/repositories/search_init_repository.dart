import '../api/api_client.dart';
import '../models/cached_repository.dart';
import '../models/comic.dart' as m;
import '../utils/json_helpers.dart';

/// Simple data holder for search init (hot keywords + tags).
class SearchInitData {
  final List<String> keywords;
  final List<m.Theme> tags;

  const SearchInitData({required this.keywords, required this.tags});

  factory SearchInitData.fromJson(Map<String, dynamic> json) => SearchInitData(
    keywords: List<String>.from(json['keywords'] ?? []),
    tags:
        (json['tags'] as List?)?.map((t) => m.Theme.fromJson(t)).toList() ?? [],
  );

  Map<String, dynamic> toJson() => {
    'keywords': keywords,
    'tags': tags.map((t) => t.toJson()).toList(),
  };
}

/// Cached repository for search init data (hot keywords + tags).
///
/// 数据源感知：COPY 源没有热门搜索词接口（请求返回 HTML），因此它的
/// init 数据只含标签，[SearchInitData.keywords] 为空。
/// 两个源使用各自的缓存条目，避免互相覆盖。
///
/// 题材/热搜都很少变化，启用 [skipApiIfCacheFresh]：TTL 内直接读缓存、
/// 不发请求。下拉刷新走 [forceRefreshApi] 绕过缓存。
class SearchInitRepository extends CachedRepository<SearchInitData> {
  SearchInitRepository({this.source = 'hot', ApiClient? api})
    : _api = api ?? ApiClient(),
      super(
        cacheKey: 'search_init_v3_$source',
        ttl: const Duration(days: 3),
        skipApiIfCacheFresh: true,
        deserialize: SearchInitData.fromJson,
        serialize: (d) => d.toJson(),
      );

  /// 'hot'（默认）或 'copy'，决定请求哪个源、读写哪条缓存。
  final String source;

  final ApiClient _api;

  @override
  Future<SearchInitData> fetchFromApi() async {
    if (source == 'copy') {
      final tags = await _api.manga.getCopyComicTags();
      return SearchInitData(keywords: const [], tags: tags);
    }
    // 用记录版 wait 并行：任一请求失败时另一个的错误也会被消费，
    // 否则先失败的那个会让另一个变成未捕获的异步错误。
    final (keywords, tags) = await (
      _api.manga.getHotKeywords(),
      _api.manga.getComicTags(),
    ).wait;
    return SearchInitData(keywords: keywords, tags: tags);
  }
}

/// Cached repository for COPY 源的大分类筛选项（全部/日漫/韓漫/美漫/已完結）。
///
/// 这些分类是服务端固定枚举，几乎不变，TTL 内直接读缓存不发请求。
class CopyFilterRepository extends CachedRepository<m.CopyFilterOptions> {
  CopyFilterRepository({ApiClient? api})
    : _api = api ?? ApiClient(),
      super(
        cacheKey: 'copy_filter_options_v1',
        ttl: const Duration(days: 3),
        skipApiIfCacheFresh: true,
        deserialize: m.CopyFilterOptions.fromJson,
        serialize: (d) => d.toJson(),
      );

  final ApiClient _api;

  @override
  Future<m.CopyFilterOptions> fetchFromApi() =>
      _api.manga.getCopyFilterOptions();
}

/// 发现页默认条件首屏（全部题材 + 热度排序 + offset 0）的列表数据。
class DiscoverComicPageData {
  final List<m.Comic> list;
  final int total;

  const DiscoverComicPageData({required this.list, required this.total});

  factory DiscoverComicPageData.fromJson(Map<String, dynamic> json) =>
      DiscoverComicPageData(
        list: jsonList(json, 'list')
            .whereType<Map>()
            .map((e) => m.Comic.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        total: jsonInt(json, 'total'),
      );

  Map<String, dynamic> toJson() => {
    'list': list.map((c) => c.toJson()).toList(),
    'total': total,
  };
}

/// Cached repository for 发现页默认条件的首屏列表（热度榜）。
///
/// 热度榜变化很小：仅缓存默认条件（popular + theme/top 全空）的 offset 0
/// 首屏，hot/copy 各一条缓存，TTL 内直接读缓存不发请求。调用方只在分支
/// 首次激活的初始化时经过本仓库；切源/重置/筛选/下拉刷新等操作一律直连
/// API，不经过这里。
class DiscoverPopularListRepository
    extends CachedRepository<DiscoverComicPageData> {
  DiscoverPopularListRepository({this.source = 'hot', ApiClient? api})
    : _api = api ?? ApiClient(),
      super(
        cacheKey: 'discover_popular_list_v1_$source',
        ttl: const Duration(days: 1),
        skipApiIfCacheFresh: true,
        deserialize: DiscoverComicPageData.fromJson,
        serialize: (d) => d.toJson(),
      );

  /// 'hot'（默认）或 'copy'，决定请求哪个源、读写哪条缓存。
  final String source;

  final ApiClient _api;

  @override
  Future<DiscoverComicPageData> fetchFromApi() async {
    final result = source == 'copy'
        ? await _api.manga.getCopyComicList()
        : await _api.manga.getComicList();
    return DiscoverComicPageData(list: result.list, total: result.total);
  }
}

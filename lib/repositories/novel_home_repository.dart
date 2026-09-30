import '../api/novel/novel_api.dart';
import '../models/cached_repository.dart';
import '../models/novel.dart';
import '../utils/json_helpers.dart';

/// 轻小说题材（/api/v3/theme/book/count 聚合结果）的可序列化包装。
class NovelThemesData {
  final List<NovelTag> themes;

  const NovelThemesData({required this.themes});

  factory NovelThemesData.fromJson(Map<String, dynamic> json) =>
      NovelThemesData(
        themes: jsonList(json, 'themes')
            .whereType<Map>()
            .map((e) => NovelTag.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
    'themes': themes.map((t) => t.toJson()).toList(),
  };
}

/// Cached repository for 轻小说题材列表。
///
/// 题材是服务端固定枚举，几乎不变：TTL 内直接读缓存不发请求。
/// 调用方只在分支首次激活的初始化时经过本仓库，下拉刷新等操作直连 API。
class NovelThemesRepository extends CachedRepository<NovelThemesData> {
  NovelThemesRepository({required NovelApi api})
    : _api = api,
      super(
        cacheKey: 'novel_themes_v1',
        ttl: const Duration(days: 3),
        skipApiIfCacheFresh: true,
        deserialize: NovelThemesData.fromJson,
        serialize: (d) => d.toJson(),
      );

  final NovelApi _api;

  @override
  Future<NovelThemesData> fetchFromApi() async =>
      NovelThemesData(themes: await _api.getThemes());
}

/// 轻小说默认条件首屏（全部题材 + 热度排序 + offset 0）的列表数据。
class NovelPopularPageData {
  final List<NovelBook> list;
  final int total;

  const NovelPopularPageData({required this.list, required this.total});

  factory NovelPopularPageData.fromJson(Map<String, dynamic> json) =>
      NovelPopularPageData(
        list: jsonList(json, 'list')
            .whereType<Map>()
            .map((e) => NovelBook.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        total: jsonInt(json, 'total'),
      );

  Map<String, dynamic> toJson() => {
    'list': list.map((b) => b.toJson()).toList(),
    'total': total,
  };
}

/// Cached repository for 轻小说热度榜首屏。
///
/// 热度榜变化很小：仅缓存默认条件（theme 空 + popular 排序）的 offset 0
/// 首屏，TTL 内直接读缓存不发请求。调用方只在分支首次激活的初始化时经过
/// 本仓库；切题材/排序/重置/下拉刷新/加载更多一律直连 API，不经过这里。
class NovelPopularListRepository
    extends CachedRepository<NovelPopularPageData> {
  NovelPopularListRepository({required NovelApi api})
    : _api = api,
      super(
        cacheKey: 'novel_popular_list_v1',
        ttl: const Duration(days: 1),
        skipApiIfCacheFresh: true,
        deserialize: NovelPopularPageData.fromJson,
        serialize: (d) => d.toJson(),
      );

  final NovelApi _api;

  @override
  Future<NovelPopularPageData> fetchFromApi() async {
    final page = await _api.getBooks();
    return NovelPopularPageData(list: page.list, total: page.total);
  }
}

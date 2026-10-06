import '../api/api_client.dart';
import '../models/cached_repository.dart';
import '../models/comic.dart' hide Theme;
import '../utils/json_helpers.dart';

/// 分页形式的 COPY 专题列表缓存数据。
class CopyTopicPageData {
  final List<MangaTopic> list;
  final int total;

  const CopyTopicPageData({required this.list, required this.total});

  factory CopyTopicPageData.fromJson(Map<String, dynamic> json) =>
      CopyTopicPageData(
        list: jsonList(json, 'list')
            .whereType<Map>()
            .map(
              (entry) => MangaTopic.fromJson(Map<String, dynamic>.from(entry)),
            )
            .where((topic) => topic.type == 1)
            .toList(),
        total: jsonInt(json, 'total'),
      );

  Map<String, dynamic> toJson() => {
    'list': list.map((topic) => topic.toJson()).toList(),
    'total': total,
  };
}

/// 分页形式的 COPY 专题漫画列表缓存数据。
class CopyTopicComicPageData {
  final List<Comic> list;
  final int total;

  const CopyTopicComicPageData({required this.list, required this.total});

  factory CopyTopicComicPageData.fromJson(Map<String, dynamic> json) =>
      CopyTopicComicPageData(
        list: jsonList(json, 'list')
            .whereType<Map>()
            .where((entry) {
              final rawType = entry['type'];
              return rawType is num ? rawType == 1 : rawType?.toString() == '1';
            })
            .map((entry) => Comic.fromJson(Map<String, dynamic>.from(entry)))
            .toList(),
        total: jsonInt(json, 'total'),
      );

  Map<String, dynamic> toJson() => {
    'list': list.map((comic) => {...comic.toJson(), 'type': 1}).toList(),
    'total': total,
  };
}

/// COPY 专题相关缓存入口。
///
/// 专题列表、专题介绍和专题漫画分页使用独立缓存键，分别缓存 1 天、
/// 7 天和 3 天。列表页下拉刷新通过 [forceRefresh] 绕过仍在 TTL 内的缓存。
class CopyTopicRepository {
  static const topicListTtl = Duration(days: 1);
  static const topicInfoTtl = Duration(days: 7);
  static const topicComicsTtl = Duration(days: 3);

  CopyTopicRepository({ApiClient? api}) : _api = api ?? ApiClient();

  final ApiClient _api;

  Future<CopyTopicPageData> loadTopics({
    int limit = 18,
    int offset = 0,
    bool forceRefresh = false,
  }) {
    final repository = _CopyTopicListPageRepository(
      _api,
      limit: limit,
      offset: offset,
    );
    return forceRefresh ? repository.forceRefreshApi() : repository.load();
  }

  Future<MangaTopic> loadTopic(String pathWord, {bool forceRefresh = false}) {
    final repository = _CopyTopicInfoRepository(_api, pathWord);
    return forceRefresh ? repository.forceRefreshApi() : repository.load();
  }

  Future<CopyTopicComicPageData> loadTopicComics(
    String pathWord, {
    int limit = 20,
    int offset = 0,
    bool forceRefresh = false,
  }) {
    final repository = _CopyTopicComicPageRepository(
      _api,
      pathWord: pathWord,
      limit: limit,
      offset: offset,
    );
    return forceRefresh ? repository.forceRefreshApi() : repository.load();
  }
}

class _CopyTopicListPageRepository extends CachedRepository<CopyTopicPageData> {
  _CopyTopicListPageRepository(
    this._api, {
    required this.limit,
    required this.offset,
  }) : super(
         cacheKey: 'copy_topics_v1_${limit}_$offset',
         ttl: CopyTopicRepository.topicListTtl,
         skipApiIfCacheFresh: true,
         deserialize: CopyTopicPageData.fromJson,
         serialize: (data) => data.toJson(),
       );

  final ApiClient _api;
  final int limit;
  final int offset;

  @override
  Future<CopyTopicPageData> fetchFromApi() async {
    final result = await _api.manga.getCopyTopics(limit: limit, offset: offset);
    return CopyTopicPageData(list: result.list, total: result.total);
  }
}

class _CopyTopicInfoRepository extends CachedRepository<MangaTopic> {
  _CopyTopicInfoRepository(this._api, this.pathWord)
    : super(
        cacheKey: 'copy_topic_info_v1_${Uri.encodeComponent(pathWord)}',
        ttl: CopyTopicRepository.topicInfoTtl,
        skipApiIfCacheFresh: true,
        deserialize: MangaTopic.fromJson,
        serialize: (topic) => topic.toJson(),
      );

  final ApiClient _api;
  final String pathWord;

  @override
  Future<MangaTopic> fetchFromApi() => _api.manga.getCopyTopic(pathWord);
}

class _CopyTopicComicPageRepository
    extends CachedRepository<CopyTopicComicPageData> {
  _CopyTopicComicPageRepository(
    this._api, {
    required this.pathWord,
    required this.limit,
    required this.offset,
  }) : super(
         cacheKey:
             'copy_topic_comics_v1_${Uri.encodeComponent(pathWord)}_${limit}_$offset',
         ttl: CopyTopicRepository.topicComicsTtl,
         skipApiIfCacheFresh: true,
         deserialize: CopyTopicComicPageData.fromJson,
         serialize: (data) => data.toJson(),
       );

  final ApiClient _api;
  final String pathWord;
  final int limit;
  final int offset;

  @override
  Future<CopyTopicComicPageData> fetchFromApi() async {
    final result = await _api.manga.getCopyTopicComics(
      pathWord,
      limit: limit,
      offset: offset,
    );
    return CopyTopicComicPageData(list: result.list, total: result.total);
  }
}

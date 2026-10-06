import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/api_client.dart';
import 'package:kira/api/manga/manga_api.dart';
import 'package:kira/models/comic.dart' hide Theme;
import 'package:kira/repositories/copy_topic_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeMangaApi extends Fake implements MangaApi {
  int topicListCalls = 0;
  int topicInfoCalls = 0;
  int topicComicsCalls = 0;

  final topic = const MangaTopic(
    title: '漫画专题',
    cover: '',
    period: '第 1 期',
    pathWord: 'topic-1',
    brief: '',
    type: 1,
  );

  @override
  Future<({List<MangaTopic> list, int total})> getCopyTopics({
    int limit = 18,
    int offset = 0,
  }) async {
    topicListCalls++;
    return (list: [topic], total: 1);
  }

  @override
  Future<MangaTopic> getCopyTopic(String pathWord) async {
    topicInfoCalls++;
    return topic;
  }

  @override
  Future<({List<Comic> list, int total})> getCopyTopicComics(
    String pathWord, {
    int limit = 20,
    int offset = 0,
  }) async {
    topicComicsCalls++;
    return (
      list: [Comic(name: '专题漫画', pathWord: 'comic-1', cover: '')],
      total: 1,
    );
  }
}

class _FakeApiClient extends Fake implements ApiClient {
  _FakeApiClient(this.manga);

  @override
  final MangaApi manga;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('专题各类缓存使用指定 TTL，并在有效期内复用缓存', () async {
    expect(CopyTopicRepository.topicListTtl, const Duration(days: 1));
    expect(CopyTopicRepository.topicInfoTtl, const Duration(days: 7));
    expect(CopyTopicRepository.topicComicsTtl, const Duration(days: 3));

    final manga = _FakeMangaApi();
    final repository = CopyTopicRepository(api: _FakeApiClient(manga));

    final firstList = await repository.loadTopics();
    final secondList = await repository.loadTopics();
    final firstInfo = await repository.loadTopic('topic-1');
    final secondInfo = await repository.loadTopic('topic-1');
    final firstComics = await repository.loadTopicComics('topic-1');
    final secondComics = await repository.loadTopicComics('topic-1');

    expect(firstList.list.single.title, '漫画专题');
    expect(secondList.list.single.pathWord, 'topic-1');
    expect(firstInfo.title, '漫画专题');
    expect(secondInfo.pathWord, 'topic-1');
    expect(firstComics.list.single.name, '专题漫画');
    expect(secondComics.list.single.pathWord, 'comic-1');
    expect(manga.topicListCalls, 1);
    expect(manga.topicInfoCalls, 1);
    expect(manga.topicComicsCalls, 1);
  });

  test('下拉刷新绕过专题列表缓存', () async {
    final manga = _FakeMangaApi();
    final repository = CopyTopicRepository(api: _FakeApiClient(manga));

    await repository.loadTopics();
    await repository.loadTopics(forceRefresh: true);

    expect(manga.topicListCalls, 2);
  });

  test('缓存反序列化仍过滤非漫画专题内容', () {
    final topics = CopyTopicPageData.fromJson({
      'total': 2,
      'list': [
        {
          'title': '漫画',
          'cover': '',
          'period': '',
          'path_word': 'comic-topic',
          'brief': '',
          'type': 1,
        },
        {
          'title': '写真',
          'cover': '',
          'period': '',
          'path_word': 'photo-topic',
          'brief': '',
          'type': 4,
        },
      ],
    });
    final comics = CopyTopicComicPageData.fromJson({
      'total': 2,
      'list': [
        {'name': '漫画', 'path_word': 'comic', 'cover': '', 'type': 1},
        {'name': '写真', 'path_word': 'photo', 'cover': '', 'type': 4},
      ],
    });

    expect(topics.list.map((topic) => topic.pathWord), ['comic-topic']);
    expect(comics.list.map((comic) => comic.pathWord), ['comic']);
  });
}

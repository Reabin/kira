import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/novel/novel_api.dart';
import 'package:kira/models/copy_account_store.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/models/user_manager.dart';

/// Keeps every request in memory; no sockets, DNS or real APIs.
class _BrowseTestAdapter implements HttpClientAdapter {
  _BrowseTestAdapter(this.respond);

  final FutureOr<ResponseBody> Function(RequestOptions, String) respond;
  final requests = <RequestOptions>[];
  final bodies = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = requestStream == null
        ? ''
        : utf8.decode(await requestStream.expand((chunk) => chunk).toList());
    bodies.add(body);
    return respond(options, body);
  }

  @override
  void close({bool force = false}) {}
}

class _BrowseTestUser extends ChangeNotifier implements UserManager {
  String _copyApiHost = 'copy.invalid';
  final String _copyAppVersion = '3.0.9';
  String? _copyToken;

  @override
  String get copyLoginHost => 'copy4000.com';

  @override
  String get copyApiHost => _copyApiHost;
  set copyApiHost(String value) {
    _copyApiHost = value;
    notifyListeners();
  }

  @override
  String get copyAppVersion => _copyAppVersion;

  @override
  String? get copyToken => _copyToken;
  set copyToken(String? value) {
    _copyToken = value;
    notifyListeners();
  }

  @override
  final CopyAccountStore copyAccount = CopyAccountStore(
    secureStore: InMemorySecureCredentialStore(),
  );

  @override
  String? token;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ResponseBody _jsonResponse(
  Object? results, {
  int code = 200,
  int status = 200,
  String message = '测试响应',
}) => ResponseBody.fromString(
  jsonEncode({'code': code, 'message': message, 'results': results}),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

Map<String, dynamic> _browseResults({int total = 6}) => {
  'list': [
    {
      'last_chapter_id': '4060',
      'last_chapter_name': '第01卷',
      'book': {
        'uuid': 'eae40b06-7c86-11ed-bf69-024352452ce0',
        'path_word': 'qingchunzhutou',
        'name': '青春豬頭少年',
        'last_chapter_id': '15109',
        'last_chapter_name': '第16卷',
      },
    },
  ],
  'total': total,
  'limit': 2,
  'offset': 4,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _BrowseTestUser user;
  late _BrowseTestAdapter adapter;
  late NovelApi api;

  setUp(() {
    user = _BrowseTestUser();
    adapter = _BrowseTestAdapter(
      (request, body) => _jsonResponse(_browseResults()),
    );
    api = NovelApi.withDio(
      user: user,
      dio: Dio()..httpClientAdapter = adapter,
      contentDio: Dio()
        ..httpClientAdapter = _BrowseTestAdapter(
          (request, body) => ResponseBody.fromString('', 200),
        ),
    );
  });

  tearDown(() => api.close());

  test(
    'GET browse history uses member route, paging and app headers',
    () async {
      final page = await api.getBrowseHistory(limit: 2, offset: 4);

      final request = adapter.requests.single;
      expect(request.method, 'GET');
      expect(request.uri.path, '/api/v3/member/browse/books');
      expect(request.queryParameters, {'limit': 2, 'offset': 4, 'platform': 3});
      expect(request.headers['User-Agent'], 'COPY/3.0.9');
      expect(request.headers['source'], 'copyApp');
      expect(request.headers['platform'], '3');
      expect(request.headers['Referer'], 'com.copymanga.app-3.0.9');
      expect(request.followRedirects, isFalse);

      expect(page.list, hasLength(1));
      expect(page.total, 6);
      expect(page.limit, 2);
      expect(page.offset, 4);
      expect(page.hasMore, isTrue);
      final entry = page.list.single;
      expect(entry.lastChapterId, '4060');
      expect(entry.lastChapterName, '第01卷');
      expect(entry.book.lastChapterId, '15109');
      expect(entry.book.lastChapterName, '第16卷');
      expect(entry.hasUpdate, isTrue);
    },
  );

  test(
    'DELETE clears history with no business body and accepts null results',
    () async {
      user.copyToken = 'COPY_TEST';
      adapter = _BrowseTestAdapter(
        (request, body) => _jsonResponse(null, message: '修改成功'),
      );
      final client = NovelApi.withDio(
        user: user,
        dio: Dio()..httpClientAdapter = adapter,
        contentDio: Dio()
          ..httpClientAdapter = _BrowseTestAdapter(
            (request, body) => ResponseBody.fromString('', 200),
          ),
      );
      addTearDown(client.close);

      await client.clearBrowseHistory();

      final request = adapter.requests.single;
      expect(request.method, 'DELETE');
      expect(request.uri.path, '/api/v3/member/browse/books');
      expect(request.queryParameters, {'platform': 3});
      expect(adapter.bodies.single, isEmpty);
      expect(adapter.bodies.single, isNot(contains('book_id')));
      // DELETE keeps the App profile; only POST switches to the browser profile.
      expect(request.headers['User-Agent'], 'COPY/3.0.9');
      expect(request.headers['source'], 'copyApp');
      expect(request.headers['Referer'], 'com.copymanga.app-3.0.9');
      expect(request.headers['Authorization'], 'Token COPY_TEST');
      expect(request.headers.containsKey('origin'), isFalse);
      expect(request.headers.containsKey('sec-fetch-site'), isFalse);
    },
  );

  test(
    'real failures surface the upstream message and keep the method',
    () async {
      adapter = _BrowseTestAdapter(
        (request, body) => _jsonResponse(null, code: 403, message: '无权限'),
      );
      final client = NovelApi.withDio(
        user: user,
        dio: Dio()..httpClientAdapter = adapter,
        contentDio: Dio()
          ..httpClientAdapter = _BrowseTestAdapter(
            (request, body) => ResponseBody.fromString('', 200),
          ),
      );
      addTearDown(client.close);

      await expectLater(
        client.clearBrowseHistory(),
        throwsA(
          isA<NovelApiException>()
              .having((error) => error.code, 'code', 403)
              .having((error) => error.message, 'message', '小说请求失败：无权限'),
        ),
      );
      expect(adapter.requests.single.method, 'DELETE');
      expect(adapter.requests.single.uri.path, '/api/v3/member/browse/books');

      adapter = _BrowseTestAdapter(
        (request, body) =>
            _jsonResponse(null, code: 401, status: 401, message: '登录已过期'),
      );
      final expiredClient = NovelApi.withDio(
        user: user,
        dio: Dio()..httpClientAdapter = adapter,
        contentDio: Dio()
          ..httpClientAdapter = _BrowseTestAdapter(
            (request, body) => ResponseBody.fromString('', 200),
          ),
      );
      addTearDown(expiredClient.close);

      await expectLater(
        expiredClient.getBrowseHistory(),
        throwsA(
          isA<NovelApiException>()
              .having((error) => error.statusCode, 'status', 401)
              .having((error) => error.message, 'message', '小说请求失败：登录已过期'),
        ),
      );
      expect(adapter.requests.single.method, 'GET');
    },
  );

  test('account changes expire a pending browse-history read', () async {
    user.copyToken = 'COPY_A';
    final started = Completer<void>();
    final release = Completer<ResponseBody>();
    adapter = _BrowseTestAdapter((request, body) {
      started.complete();
      return release.future;
    });
    final client = NovelApi.withDio(
      user: user,
      dio: Dio()..httpClientAdapter = adapter,
      contentDio: Dio()
        ..httpClientAdapter = _BrowseTestAdapter(
          (request, body) => ResponseBody.fromString('', 200),
        ),
    );
    addTearDown(client.close);

    final assertion = expectLater(
      client.getBrowseHistory(),
      throwsA(isA<NovelIdentityChangedException>()),
    );
    await started.future;
    expect(adapter.requests.single.headers['Authorization'], 'Token COPY_A');
    user.copyToken = 'COPY_B';
    release.complete(_jsonResponse(_browseResults()));
    await assertion;
  });

  test('account changes expire a pending history clear', () async {
    final started = Completer<void>();
    final release = Completer<ResponseBody>();
    adapter = _BrowseTestAdapter((request, body) {
      started.complete();
      return release.future;
    });
    final client = NovelApi.withDio(
      user: user,
      dio: Dio()..httpClientAdapter = adapter,
      contentDio: Dio()
        ..httpClientAdapter = _BrowseTestAdapter(
          (request, body) => ResponseBody.fromString('', 200),
        ),
    );
    addTearDown(client.close);

    final assertion = expectLater(
      client.clearBrowseHistory(),
      throwsA(isA<NovelIdentityChangedException>()),
    );
    await started.future;
    expect(adapter.requests.single.method, 'DELETE');
    user.copyAccount.beginLogin();
    release.complete(_jsonResponse(null, message: '修改成功'));
    await assertion;
  });

  test('invalid browse-history paging fails before the adapter', () async {
    await expectLater(api.getBrowseHistory(limit: 0), throwsArgumentError);
    await expectLater(api.getBrowseHistory(offset: -1), throwsArgumentError);
    expect(adapter.requests, isEmpty);
  });
}

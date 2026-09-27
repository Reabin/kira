import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/novel/novel_api.dart';
import 'package:kira/models/copy_account_store.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/models/user_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every request stays in this adapter; no sockets, DNS or real APIs.
class NovelTestAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions, String) respond;
  final requests = <RequestOptions>[];
  final bodies = <String>[];

  NovelTestAdapter(this.respond);

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

class NovelTestUser extends ChangeNotifier implements UserManager {
  String _copyApiHost = 'copy.invalid';
  final String _copyLoginHost = 'copy4000.com';
  String _copyAppVersion = '3.0.9';
  String? _copyToken;

  @override
  String get copyLoginHost => _copyLoginHost;

  @override
  String get copyApiHost => _copyApiHost;
  set copyApiHost(String value) {
    _copyApiHost = value;
    notifyListeners();
  }

  @override
  String get copyAppVersion => _copyAppVersion;
  set copyAppVersion(String value) {
    _copyAppVersion = value;
    notifyListeners();
  }

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

ResponseBody novelJsonResponse(
  Object? results, {
  int code = 200,
  int status = 200,
}) => ResponseBody.fromString(
  jsonEncode({'code': code, 'message': '测试响应', 'results': results}),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

NovelVolumeDetail novelFixtureDetail({
  bool locked = false,
  String encoding = 'UTF-8',
}) => NovelVolumeDetail(
  book: const NovelBook(pathWord: 'book', name: '书名', uuid: 'book-uuid'),
  isLoggedIn: true,
  isLocked: locked,
  volume: NovelVolume(
    id: '7',
    name: '第七卷',
    bookPathWord: 'book',
    txtAddr: 'https://cdn.invalid/exact-file.txt',
    txtEncoding: encoding,
    contents: const [
      NovelContentEntry(name: '第一章', contentType: 1, endLines: 2),
      NovelContentEntry(
        name: '插图',
        contentType: 2,
        content: 'https://cdn.invalid/image.png',
      ),
    ],
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NovelTestUser user;
  late NovelTestAdapter apiAdapter;
  late NovelTestAdapter contentAdapter;
  late NovelApi api;

  setUp(() {
    user = NovelTestUser();
    apiAdapter = NovelTestAdapter(
      (options, body) =>
          novelJsonResponse({'list': [], 'total': 0, 'limit': 18, 'offset': 0}),
    );
    contentAdapter = NovelTestAdapter(
      (options, body) => ResponseBody.fromString('正文\n', 200),
    );
    api = NovelApi.withDio(
      user: user,
      dio: Dio()..httpClientAdapter = apiAdapter,
      contentDio: Dio()..httpClientAdapter = contentAdapter,
    );
  });

  tearDown(() => api.close());

  test(
    'HOT token is never used; COPY token, host and app version update live',
    () async {
      user.token = 'HOT_ONLY_TEST';
      await api.getBooks();
      expect(apiAdapter.requests.single.headers['Authorization'], '');
      expect(apiAdapter.requests.single.uri.host, 'copy.invalid');
      user.copyToken = 'COPY_TEST';
      user.copyApiHost = 'second-copy.invalid';
      user.copyAppVersion = '3.1.0';
      await api.getBooks(theme: 'love', offset: 18);
      final request = apiAdapter.requests.last;
      expect(request.uri.host, 'second-copy.invalid');
      expect(request.headers['Authorization'], 'Token COPY_TEST');
      expect(request.headers['User-Agent'], 'COPY/3.1.0');
      expect(request.headers['version'], '3.1.0');
      expect(request.headers['source'], 'copyApp');
      expect(request.headers['platform'], '3');
      expect(request.queryParameters, {
        'theme': 'love',
        'ordering': '-popular',
        'limit': 18,
        'offset': 18,
        'platform': 3,
      });
      expect(request.followRedirects, isFalse);
      expect(request.headers.toString(), isNot(contains('HOT_ONLY_TEST')));
    },
  );

  test('book list uses author/theme path words, not keyword search', () async {
    await api.getBooks(
      author: ' yusentakibi ',
      ordering: '-datetime_updated',
      offset: 18,
    );
    final author = apiAdapter.requests.last;
    expect(author.uri.path, '/api/v3/books');
    expect(author.queryParameters, {
      'author': 'yusentakibi',
      'ordering': '-datetime_updated',
      'limit': 18,
      'offset': 18,
      'platform': 3,
    });

    await api.getBooks(theme: ' aiqing ', ordering: '-datetime_updated');
    final theme = apiAdapter.requests.last;
    expect(theme.uri.path, '/api/v3/books');
    expect(theme.queryParameters, {
      'theme': 'aiqing',
      'ordering': '-datetime_updated',
      'limit': 18,
      'offset': 0,
      'platform': 3,
    });

    await api.getBooks(author: 'yusentakibi', theme: 'aiqing');
    expect(apiAdapter.requests.last.queryParameters['author'], 'yusentakibi');
    expect(apiAdapter.requests.last.queryParameters['theme'], 'aiqing');
    expect(contentAdapter.requests, isEmpty);
  });

  test(
    'empty book filters are omitted rather than sent as empty values',
    () async {
      await api.getBooks();
      await api.getBooks(author: '  ', theme: '\t');
      for (final request in apiAdapter.requests) {
        expect(request.queryParameters, {
          'ordering': '-popular',
          'limit': 18,
          'offset': 0,
          'platform': 3,
        });
      }
    },
  );

  test(
    'real UserManager keeps supplemental COPY session separate from HOT',
    () async {
      SharedPreferences.setMockInitialValues({
        'user_token': 'HOT_ONLY_TEST',
        'login_source': 'hot',
        'copy_api_host': 'copy.invalid',
      });
      SecureCredentialStore.setInstance(InMemorySecureCredentialStore());
      addTearDown(SecureCredentialStore.resetInstance);
      final realUser = UserManager();
      await realUser.init();
      final realApi = NovelApi.withDio(
        user: realUser,
        dio: Dio()..httpClientAdapter = apiAdapter,
        contentDio: Dio()..httpClientAdapter = contentAdapter,
      );
      addTearDown(realApi.close);
      await realApi.getBooks();
      expect(realUser.token, 'HOT_ONLY_TEST');
      expect(apiAdapter.requests.last.headers['Authorization'], '');
      await realUser.copyAccount.saveSession(
        const CopyAccountSession(
          token: 'SUPPLEMENTAL_COPY_TEST',
          userId: 'supplemental-id',
        ),
      );
      await realApi.getBooks();
      expect(realUser.token, 'HOT_ONLY_TEST');
      expect(
        apiAdapter.requests.last.headers['Authorization'],
        'Token SUPPLEMENTAL_COPY_TEST',
      );
      await realUser.copyAccount.logout();
    },
  );

  test(
    'upstream messages never expose token or password through exceptions',
    () async {
      final adapter = NovelTestAdapter(
        (request, body) => ResponseBody.fromString(
          jsonEncode({
            'code': 403,
            'message': {
              'token': 'UPSTREAM_TOKEN_SECRET',
              'password': 'UPSTREAM_PASSWORD_SECRET',
            },
            'results': null,
          }),
          200,
        ),
      );
      final client = NovelApi.withDio(
        user: user,
        dio: Dio()..httpClientAdapter = adapter,
        contentDio: Dio()..httpClientAdapter = contentAdapter,
      );
      addTearDown(client.close);
      await expectLater(
        client.getBooks(),
        throwsA(
          isA<NovelApiException>()
              .having((error) => error.code, 'code', 403)
              .having((error) => error.statusCode, 'HTTP status', 200)
              .having((error) => error.toString(), 'safe error', '小说请求失败'),
        ),
      );
    },
  );

  test(
    'API response rejects account ABA even when final token matches',
    () async {
      user.copyToken = 'COPY_A';
      final started = Completer<void>();
      final release = Completer<ResponseBody>();
      final adapter = NovelTestAdapter((request, body) {
        started.complete();
        return release.future;
      });
      final client = NovelApi.withDio(
        user: user,
        dio: Dio()..httpClientAdapter = adapter,
        contentDio: Dio()..httpClientAdapter = contentAdapter,
      );
      addTearDown(client.close);
      final assertion = expectLater(
        client.getBooks(),
        throwsA(isA<NovelIdentityChangedException>()),
      );
      await started.future;
      expect(adapter.requests.single.headers['Authorization'], 'Token COPY_A');
      user.copyToken = 'COPY_B';
      user.copyToken = 'COPY_A';
      release.complete(novelJsonResponse({'list': [], 'total': 0}));
      await assertion;
    },
  );

  test('queued request never combines an old host with a new token', () async {
    user.copyToken = 'COPY_A';
    final dio = Dio()..httpClientAdapter = apiAdapter;
    final client = NovelApi.withDio(
      user: user,
      dio: dio,
      contentDio: Dio()..httpClientAdapter = contentAdapter,
    );
    addTearDown(client.close);
    final started = Completer<void>();
    final release = Completer<void>();
    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          started.complete();
          await release.future;
          handler.next(options);
        },
      ),
    );
    final assertion = expectLater(
      client.getBooks(),
      throwsA(isA<NovelIdentityChangedException>()),
    );
    await started.future;
    user.copyApiHost = 'different-copy.invalid';
    user.copyToken = 'COPY_B';
    release.complete();
    await assertion;
    expect(apiAdapter.requests, isEmpty);
  });

  test(
    'account revision invalidates a response before notification is sent',
    () async {
      final started = Completer<void>();
      final release = Completer<ResponseBody>();
      final adapter = NovelTestAdapter((request, body) {
        started.complete();
        return release.future;
      });
      final client = NovelApi.withDio(
        user: user,
        dio: Dio()..httpClientAdapter = adapter,
        contentDio: Dio()..httpClientAdapter = contentAdapter,
      );
      addTearDown(client.close);
      final assertion = expectLater(
        client.getBooks(),
        throwsA(isA<NovelIdentityChangedException>()),
      );
      await started.future;
      user.copyAccount.beginLogin();
      release.complete(novelJsonResponse({'list': [], 'total': 0}));
      await assertion;
    },
  );

  test('unrelated user notification does not invalidate a request', () async {
    final identity = api.requestIdentity;
    user.notifyListeners();
    api.ensureIdentity(identity);
    await api.getBooks();
    expect(apiAdapter.requests.length, 1);
  });

  test(
    'all documented list/detail/query/volume/category routes and pagination',
    () async {
      final adapter = NovelTestAdapter((request, body) {
        if (request.path.contains('/volume/')) {
          return novelJsonResponse(novelFixtureDetail().toJson());
        }
        if (request.path.endsWith('/volumes')) {
          return novelJsonResponse({
            'list': [novelFixtureDetail().volume.toJson()],
            'total': 1,
          });
        }
        if (request.path.endsWith('/query')) {
          return novelJsonResponse({
            'is_lock': true,
            'is_login': false,
            'collect': null,
          });
        }
        if (request.path.endsWith('/book/book')) {
          return novelJsonResponse({
            'book': novelFixtureDetail().book.toJson(),
          });
        }
        return novelJsonResponse({
          'list': [],
          'total': 0,
          'limit': 18,
          'offset': 0,
        });
      });
      final client = NovelApi.withDio(
        user: user,
        dio: Dio()..httpClientAdapter = adapter,
        contentDio: Dio()..httpClientAdapter = contentAdapter,
      );
      addTearDown(client.close);
      await client.getHome();
      expect(
        adapter.requests.take(2).map((e) => e.queryParameters['ordering']),
        ['-popular', '-datetime_updated'],
      );
      await client.getDetail('book');
      expect(adapter.requests.last.queryParameters['in_mainland'], true);
      expect(adapter.requests.last.queryParameters['request_id'], isNotEmpty);
      expect((await client.getQuery('book')).isLocked, isTrue);
      final volumes = await client.getVolumes('book');
      expect(volumes.single.id, '7');
      expect(adapter.requests.last.queryParameters, {'platform': 3});
      expect(
        (await client.getVolumeDetail('book', '7')).volume.txtAddr,
        'https://cdn.invalid/exact-file.txt',
      );
      await client.getThemes();
      expect(adapter.requests.last.uri.path, '/api/v3/theme/book/count');
      expect(adapter.requests.last.queryParameters, {
        'free_type': 1,
        'limit': 500,
        'offset': 0,
        'platform': 3,
      });
      await client.getBookshelf(offset: 18);
      expect(adapter.requests.last.queryParameters, {
        'free_type': 1,
        'ordering': '-datetime_modifier',
        'limit': 18,
        'offset': 18,
        'platform': 3,
      });
      await client.getComments(
        bookUuid: 'uuid',
        replyId: '9',
        limit: 3,
        offset: 3,
      );
      expect(adapter.requests.last.queryParameters, {
        'book_id': 'uuid',
        'reply_id': '9',
        'limit': 3,
        'offset': 3,
        'platform': 3,
      });
    },
  );

  test('guest comments and replies never borrow the HOT token', () async {
    user.token = 'HOT_ONLY_TEST';
    await api.getComments(bookUuid: 'book-uuid');
    await api.getComments(
      bookUuid: 'book-uuid',
      replyId: 'parent-id',
      offset: 10,
    );
    expect(apiAdapter.requests, hasLength(2));
    for (final request in apiAdapter.requests) {
      expect(request.method, 'GET');
      expect(request.uri.path, '/api/v3/bookcomments');
      expect(request.headers['Authorization'], '');
      expect(request.headers.containsKey('Cookie'), isFalse);
      expect(request.headers.toString(), isNot(contains('HOT_ONLY_TEST')));
    }
    expect(apiAdapter.requests.first.queryParameters['reply_id'], '');
    expect(apiAdapter.requests.last.queryParameters['reply_id'], 'parent-id');
    expect(apiAdapter.requests.last.queryParameters['offset'], 10);
    expect(contentAdapter.requests, isEmpty);
  });

  test(
    'member actions use form body with UUID and accept null results',
    () async {
      final adapter = NovelTestAdapter(
        (request, body) => novelJsonResponse(null),
      );
      final client = NovelApi.withDio(
        user: user,
        dio: Dio()..httpClientAdapter = adapter,
        contentDio: Dio()..httpClientAdapter = contentAdapter,
      );
      addTearDown(client.close);
      await client.setCollected(bookUuid: 'book-uuid', collected: true);
      expect(adapter.requests.last.uri.path, '/api/v3/member/collect/book');
      expect(adapter.requests.last.method, 'POST');
      expect(Uri.splitQueryString(adapter.bodies.last), {
        'book_id': 'book-uuid',
        'is_collect': '1',
      });
      await client.setCollected(bookUuid: 'book-uuid', collected: false);
      expect(Uri.splitQueryString(adapter.bodies.last)['is_collect'], '0');
      user.copyToken = 'COPY_TEST';
      await client.postComment(
        bookUuid: 'book-uuid',
        content: '正文 & 回复',
        replyId: '9',
      );
      expect(adapter.requests.last.uri.path, '/api/v3/member/bookcomment');
      expect(Uri.splitQueryString(adapter.bodies.last), {
        'book_id': 'book-uuid',
        'comment': '正文 & 回复',
        'reply_id': '9',
      });
      expect(adapter.requests.last.queryParameters, {'platform': 3});
      expect(adapter.requests.last.headers['Host'], 'copy.invalid');
      expect(adapter.requests.last.headers['origin'], 'https://copy4000.com');
      expect(adapter.requests.last.headers['referer'], 'https://copy4000.com/');
      expect(adapter.requests.last.headers['sec-fetch-site'], 'same-site');
      expect(adapter.requests.last.headers['Authorization'], 'Token COPY_TEST');
    },
  );

  test(
    'business errors and HTTP401 are preserved without retry or host rotation',
    () async {
      for (final pair in [(403, 200), (401, 401), (200, 302)]) {
        final adapter = NovelTestAdapter(
          (request, body) =>
              novelJsonResponse(null, code: pair.$1, status: pair.$2),
        );
        final client = NovelApi.withDio(
          user: user,
          dio: Dio()..httpClientAdapter = adapter,
          contentDio: Dio()..httpClientAdapter = contentAdapter,
        );
        await expectLater(
          client.getBooks(),
          throwsA(
            isA<NovelApiException>()
                .having((e) => e.code, 'code', pair.$1)
                .having((e) => e.statusCode, 'status', pair.$2),
          ),
        );
        expect(adapter.requests.length, 1);
        expect(adapter.requests.single.uri.host, 'copy.invalid');
        client.close();
      }
    },
  );

  test('code 210 preserves the exact response body for diagnostics', () async {
    const payload = {
      'code': 210,
      'message': '服务暂时不可用，请稍后再试.',
      'results': {'detail': '服务暂时不可用，请稍后再试.'},
    };
    final responseText = jsonEncode(payload);
    final adapter = NovelTestAdapter(
      (request, body) => ResponseBody.fromString(
        responseText,
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );
    final client = NovelApi.withDio(
      user: user,
      dio: Dio()..httpClientAdapter = adapter,
      contentDio: Dio()..httpClientAdapter = contentAdapter,
    );
    addTearDown(client.close);

    await expectLater(
      client.getBooks(),
      throwsA(
        isA<NovelApiException>()
            .having((error) => error.code, 'code', 210)
            .having((error) => error.toString(), 'body', responseText),
      ),
    );
  });
  test(
    'malformed response is explicit, never treated as an empty success',
    () async {
      final adapter = NovelTestAdapter(
        (request, body) =>
            ResponseBody.fromString('<html>upstream</html>', 200),
      );
      final client = NovelApi.withDio(
        user: user,
        dio: Dio()..httpClientAdapter = adapter,
        contentDio: Dio()..httpClientAdapter = contentAdapter,
      );
      addTearDown(client.close);
      await expectLater(client.getBooks(), throwsA(isA<NovelApiException>()));
    },
  );

  test(
    'CDN raw bytes use metadata GBK and never receive authorization or redirects',
    () async {
      user.copyToken = 'COPY_TEST';
      final adapter = NovelTestAdapter(
        (request, body) => ResponseBody.fromBytes(
          [0xd6, 0xd0, 0xce, 0xc4, 13, 10],
          200,
          headers: {
            Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
          },
        ),
      );
      final contentDio = Dio(
        BaseOptions(
          headers: {
            'Authorization': 'LEAK',
            'Cookie': 'session=LEAK',
            'x-auth-signature': 'LEAK',
          },
        ),
      )..httpClientAdapter = adapter;
      contentDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            request.headers['Authorization'] = 'LEAK_FROM_INTERCEPTOR';
            handler.next(request);
          },
        ),
      );
      final client = NovelApi.withDio(
        user: user,
        dio: Dio()..httpClientAdapter = apiAdapter,
        contentDio: contentDio,
      );
      addTearDown(client.close);
      final content = await client.getVolumeContent(
        novelFixtureDetail(encoding: 'GBK'),
      );
      expect(content.entries.first.paragraphs, ['中文', '']);
      expect(
        adapter.requests.single.uri.toString(),
        'https://cdn.invalid/exact-file.txt',
      );
      expect(adapter.requests.single.responseType, ResponseType.bytes);
      await client.getContentBytes('https://cdn.invalid/image.png');
      for (final request in adapter.requests) {
        expect(
          request.headers.keys.map((e) => e.toLowerCase()),
          isNot(contains('authorization')),
        );
        expect(
          request.headers.keys.map((e) => e.toLowerCase()),
          isNot(contains('cookie')),
        );
        expect(request.headers.toString(), isNot(contains('COPY_TEST')));
        expect(request.headers.toString(), isNot(contains('LEAK')));
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 0);
      }
    },
  );

  test(
    'CDN redirect rejected and locked volume never initiates CDN request',
    () async {
      final adapter = NovelTestAdapter(
        (request, body) => ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['https://elsewhere.invalid/'],
          },
        ),
      );
      final client = NovelApi.withDio(
        user: user,
        dio: Dio()..httpClientAdapter = apiAdapter,
        contentDio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(client.close);
      await expectLater(
        client.getVolumeText(novelFixtureDetail(locked: true)),
        throwsA(
          isA<NovelAccessException>().having(
            (e) => e.detail.isLocked,
            'lock',
            true,
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
      await expectLater(
        client.getVolumeText(novelFixtureDetail()),
        throwsA(
          isA<NovelApiException>().having((e) => e.statusCode, 'status', 302),
        ),
      );
      expect(adapter.requests.length, 1);
    },
  );

  test(
    'invalid pagination and credential-bearing CDN URLs fail before adapter',
    () async {
      await expectLater(api.getBooks(limit: 0), throwsArgumentError);
      await expectLater(
        api.getComments(bookUuid: 'uuid', offset: -1),
        throwsArgumentError,
      );
      await expectLater(
        api.getContentBytes('https://user:password@cdn.invalid/file'),
        throwsA(isA<NovelApiException>()),
      );
      expect(apiAdapter.requests, isEmpty);
      expect(contentAdapter.requests, isEmpty);
    },
  );
}

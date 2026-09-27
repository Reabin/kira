import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../models/novel.dart';
import '../../models/user_manager.dart';
import '../../utils/app_dio.dart';
import '../../utils/comment_text.dart';
import '../../utils/json_helpers.dart';
import '../../utils/network_proxy.dart';
import '../api_transport.dart';
import 'novel_text.dart';

class NovelApiException implements Exception {
  final int? code;
  final int? statusCode;
  final String message;

  const NovelApiException(this.message, {this.code, this.statusCode});

  bool get isUnauthorized => code == 401 || statusCode == 401;

  /// Code 210 is an upstream diagnostic response. Preserve the full body so
  /// the UI can show exactly what the server returned while troubleshooting.
  bool get isDiagnosticResponse => code == 210 || statusCode == 210;

  @override
  String toString() => message;
}

class NovelIdentityChangedException extends NovelApiException {
  const NovelIdentityChangedException() : super('拷贝账号或线路已变更，请重新加载');
}

/// An in-memory request snapshot. Credentials are private and never serialized.
class NovelRequestIdentity {
  final NovelApi _owner;
  final int generation;
  final int _accountRevision;
  final String _host;
  final String _version;
  final String? _token;

  const NovelRequestIdentity._(
    this._owner,
    this.generation,
    this._accountRevision,
    this._host,
    this._version,
    this._token,
  );

  String get cacheScope =>
      sha256.convert(utf8.encode('$_host\n${_token ?? ''}')).toString();
}

/// Preserve the access response for the reader's login/locked/empty UI.
class NovelAccessException extends NovelApiException {
  final NovelVolumeDetail detail;

  NovelAccessException(this.detail)
    : super(detail.isLocked ? '该卷暂不可访问' : '该卷尚未提供正文或目录');
}

/// COPY-only book client. Never uses ApiTransport's HOT Dio, retry or hosts.
///
/// API coverage is limited to the locally documented endpoints. Home is an
/// aggregation of two book-list orderings; no search/rank endpoint is assumed.
class NovelApi {
  final UserManager _user;
  final Dio _dio;
  final Dio _contentDio;
  final Random _random = Random.secure();
  final Object _identityZoneKey = Object();
  final Object _cancellationZoneKey = Object();

  /// Task-owned requests only. A caller must not wrap a shared reader fetch.
  Future<T> withCancellation<T>(
    CancelToken token,
    Future<T> Function() action,
  ) => runZoned(action, zoneValues: {_cancellationZoneKey: token});

  CancelToken? get _cancelToken {
    final value = Zone.current[_cancellationZoneKey];
    return value is CancelToken ? value : null;
  }

  static const _identityExtraKey = 'novel_request_identity';
  static const _browserCommentExtraKey = 'novel_browser_comment';
  late (String, String?, int, String) _identityStamp;
  int _generation = 0;
  bool _closed = false;

  NovelApi(ApiTransport transport)
    : this.withDio(
        user: transport.user,
        dio: _createDio('novel_copy_api'),
        contentDio: _createDio('novel_content'),
      );

  /// Inject dedicated clients with fake HttpClientAdapters in offline tests.
  /// Clients may not be shared with HOT or other authenticated services.
  NovelApi.withDio({
    required Dio dio,
    required Dio contentDio,
    UserManager? user,
  }) : _user = user ?? UserManager(),
       _dio = dio,
       _contentDio = contentDio {
    if (identical(dio, contentDio)) {
      throw ArgumentError('小说API与正文必须使用独立client');
    }
    _identityStamp = _readIdentityStamp();
    _user.addListener(_onUserChanged);
    // Do not inherit any HOT interceptors from an injected client.
    _dio.interceptors.clear();
    _contentDio.interceptors.clear();
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) =>
            _prepareRequest(options, handler, content: false),
      ),
    );
    _contentDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) =>
            _prepareRequest(options, handler, content: true),
      ),
    );
  }

  static Dio _createDio(String source) {
    final dio = AppDio.create(
      source: source,
      enableErrorLog: false,
      options: BaseOptions(followRedirects: false, validateStatus: (_) => true),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => NetworkProxy.createHttpClient(
        connectionTimeout: AppDio.defaultConnectTimeout,
      ),
    );
    return dio;
  }

  (String, String?, int, String) _readIdentityStamp() => (
    _user.copyApiHost,
    _user.copyToken,
    _user.copyAccount.revision,
    _user.copyAppVersion,
  );

  void _onUserChanged() {
    final next = _readIdentityStamp();
    if (next != _identityStamp) {
      _identityStamp = next;
      _generation++;
    }
  }

  /// Nested calls in one load share a frozen identity, including async Dio work.
  NovelRequestIdentity get requestIdentity {
    final scoped = Zone.current[_identityZoneKey];
    if (scoped is NovelRequestIdentity) {
      ensureIdentity(scoped);
      return scoped;
    }
    _onUserChanged();
    return NovelRequestIdentity._(
      this,
      _generation,
      _identityStamp.$3,
      _identityStamp.$1,
      _identityStamp.$4,
      _identityStamp.$2,
    );
  }

  void ensureIdentity(NovelRequestIdentity identity) {
    // Also catches beginLogin/logout revisions before their async notification.
    _onUserChanged();
    if (_closed ||
        !identical(identity._owner, this) ||
        identity.generation != _generation ||
        identity._accountRevision != _identityStamp.$3) {
      throw const NovelIdentityChangedException();
    }
  }

  Future<T> withIdentity<T>(Future<T> Function() action) {
    final identity = requestIdentity;
    return runZoned(() async {
      ensureIdentity(identity);
      final result = await action();
      ensureIdentity(identity);
      return result;
    }, zoneValues: {_identityZoneKey: identity});
  }

  void _prepareRequest(
    RequestOptions options,
    RequestInterceptorHandler handler, {
    required bool content,
  }) {
    final identity = options.extra[_identityExtraKey];
    try {
      if (identity is! NovelRequestIdentity) {
        throw const NovelIdentityChangedException();
      }
      ensureIdentity(identity);
      final version = identity._version;
      final token = identity._token;
      // Whitelist every header. CDN never receives credentials or signatures.
      options.headers.clear();
      if (!content && options.method.toUpperCase() == 'POST') {
        // Write operations must use the plain browser profile. POSTs carrying
        // the COPY app fingerprint (COPY UA + source/version/webp) are treated
        // as app traffic and rejected with 210 unless the full app TLS/HTTP2
        // fingerprint matches, which Dart cannot reproduce. The manga comment
        // API passes with exactly this minimal browser header set. GETs keep
        // the app profile without issue.
        options.headers.addAll({
          'Host': identity._host,
          'origin': 'https://${_user.copyLoginHost}',
          'referer': 'https://${_user.copyLoginHost}/',
          'sec-fetch-site': 'same-site',
          'Authorization': token == null || token.isEmpty ? '' : 'Token $token',
          'Content-Type': Headers.formUrlEncodedContentType,
        });
      } else {
        options.headers.addAll({
          'User-Agent': 'COPY/$version',
          'Accept': content ? '*/*' : 'application/json',
          'Accept-Encoding': 'gzip',
          if (!content) ...{
            'Host': identity._host,
            'source': 'copyApp',
            'platform': '3',
            'version': version,
            if (options.extra[_browserCommentExtraKey] == true) ...{
              'origin': 'https://${_user.copyLoginHost}',
              'referer': 'https://${_user.copyLoginHost}/',
              'sec-fetch-site': 'same-site',
            } else
              'Referer': 'com.copymanga.app-$version',
            'Connection': 'keep-alive',
            'webp': '1',
            'Authorization': token == null || token.isEmpty
                ? ''
                : 'Token $token',
            'Content-Type': Headers.formUrlEncodedContentType,
          },
        });
      }
      options.followRedirects = false;
      options.maxRedirects = 0;
      handler.next(options);
    } on NovelIdentityChangedException catch (error) {
      handler.reject(DioException(requestOptions: options, error: error));
    }
  }

  bool get hasCopyToken => _user.copyToken?.isNotEmpty ?? false;

  /// Permanent cache scope intentionally excludes the in-flight generation.
  String get cacheScope => requestIdentity.cacheScope;

  void close() {
    _closed = true;
    _user.removeListener(_onUserChanged);
    _dio.close();
    _contentDio.close();
  }

  String _path(String pathWord) =>
      '/api/v3/book/${Uri.encodeComponent(pathWord)}';

  Map<String, dynamic> _detailParams() => {
    'in_mainland': true,
    'request_id': List.generate(
      10,
      (_) => _random.nextInt(36).toRadixString(36),
    ).join(),
  };

  void _validatePage(int limit, int offset) {
    if (limit <= 0 || offset < 0) {
      throw ArgumentError('limit必须大于0，offset不能为负数');
    }
  }

  Future<NovelPage<NovelBook>> getBooks({
    String theme = '',
    String author = '',
    String ordering = '-popular',
    int limit = 18,
    int offset = 0,
  }) => withIdentity(() async {
    _validatePage(limit, offset);
    return NovelPage.fromJson(
      await _get('/api/v3/books', {
        if (theme.trim().isNotEmpty) 'theme': theme.trim(),
        if (author.trim().isNotEmpty) 'author': author.trim(),
        'ordering': ordering,
        'limit': limit,
        'offset': offset,
      }),
      NovelBook.fromJson,
    );
  });

  Future<NovelHome> getHome() => withIdentity(() async {
    final pages = await Future.wait([
      getBooks(),
      getBooks(ordering: '-datetime_updated'),
    ]);
    return NovelHome(popular: pages[0].list, latest: pages[1].list);
  });

  /// 关键字搜索书籍。`q_type` 恒为空串：本地只有该取值的抓包记录，
  /// 不猜测其它筛选模式。
  Future<NovelPage<NovelBook>> searchBooks({
    required String keyword,
    int limit = 18,
    int offset = 0,
  }) => withIdentity(() async {
    _validatePage(limit, offset);
    final query = keyword.trim();
    if (query.isEmpty) {
      throw ArgumentError('搜索关键词不能为空');
    }
    return NovelPage.fromJson(
      await _get('/api/v3/search/books', {
        'q': query,
        'q_type': '',
        'limit': limit,
        'offset': offset,
      }),
      NovelBook.fromJson,
    );
  });

  Future<NovelDetail> getDetail(String pathWord) => withIdentity(
    () async =>
        NovelDetail.fromJson(await _get(_path(pathWord), _detailParams())),
  );

  Future<NovelQuery> getQuery(String pathWord) => withIdentity(
    () async => NovelQuery.fromJson(await _get('${_path(pathWord)}/query')),
  );

  Future<List<NovelVolume>> getVolumes(String pathWord) =>
      withIdentity(() async {
        final json = await _get('${_path(pathWord)}/volumes');
        // This endpoint returns the full catalogue; it takes no limit/offset.
        return NovelPage.fromJson(json, NovelVolume.fromJson).list;
      });

  Future<NovelVolumeDetail> getVolumeDetail(String pathWord, String volumeId) =>
      withIdentity(
        () async => NovelVolumeDetail.fromJson(
          await _get(
            '${_path(pathWord)}/volume/${Uri.encodeComponent(volumeId)}',
            _detailParams(),
          ),
        ),
      );

  /// The exact server-provided URL is used, never a guessed filename.
  Future<String> getVolumeText(NovelVolumeDetail detail) =>
      withIdentity(() async {
        if (detail.isLocked || !detail.hasText) {
          throw NovelAccessException(detail);
        }
        final bytes = await getContentBytes(detail.volume.txtAddr);
        return NovelText.decode(bytes, detail.volume.txtEncoding);
      });

  Future<NovelVolumeContent> getVolumeContent(NovelVolumeDetail detail) =>
      withIdentity(
        () async => NovelText.parse(detail, await getVolumeText(detail)),
      );

  /// Also usable for illustrations/covers. No credentials or redirects.
  Future<List<int>> getContentBytes(String url) => withIdentity(() async {
    final identity = requestIdentity;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.userInfo.isNotEmpty) {
      throw const NovelApiException('正文或插图地址无效');
    }
    try {
      final response = await _contentDio.get<List<int>>(
        uri.toString(),
        cancelToken: _cancelToken,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (_) => true,
          extra: {_identityExtraKey: identity},
        ),
      );
      ensureIdentity(identity);
      if (response.statusCode != 200 || response.data == null) {
        throw NovelApiException('正文或插图获取失败', statusCode: response.statusCode);
      }
      return response.data!;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      ensureIdentity(identity);
      throw NovelApiException(
        '正文或插图网络请求失败',
        statusCode: error.response?.statusCode,
      );
    }
  });

  Future<List<NovelTag>> getThemes() => withIdentity(() async {
    final result = <NovelTag>[];
    var offset = 0;
    while (true) {
      final page = NovelPage.fromJson(
        await _get('/api/v3/theme/book/count', {
          'free_type': 1,
          'limit': 500,
          'offset': offset,
        }),
        NovelTag.fromJson,
      );
      result.addAll(page.list);
      if (!page.hasMore) return result;
      final next = page.offset + page.list.length;
      if (next <= offset) throw const NovelApiException('题材分页未前进');
      offset = next;
    }
  });

  Future<NovelPage<NovelShelfEntry>> getBookshelf({
    int limit = 18,
    int offset = 0,
    int freeType = 1,
    String ordering = '-datetime_modifier',
  }) => withIdentity(() async {
    _validatePage(limit, offset);
    return NovelPage.fromJson(
      await _get('/api/v3/member/collect/books', {
        'free_type': freeType,
        'ordering': ordering,
        'limit': limit,
        'offset': offset,
      }),
      NovelShelfEntry.fromJson,
    );
  });

  Future<void> setCollected({
    required String bookUuid,
    required bool collected,
  }) => withIdentity(() async {
    await _request(
      '/api/v3/member/collect/book',
      data: {'book_id': bookUuid, 'is_collect': collected ? 1 : 0},
    );
  });

  Future<NovelPage<NovelComment>> getComments({
    required String bookUuid,
    String? replyId,
    int limit = 10,
    int offset = 0,
  }) => withIdentity(() async {
    _validatePage(limit, offset);
    return NovelPage.fromJson(
      await _getBrowserComment('/api/v3/bookcomments', {
        'book_id': bookUuid,
        'reply_id': replyId ?? '',
        'limit': limit,
        'offset': offset,
      }),
      NovelComment.fromJson,
    );
  });

  Future<void> postComment({
    required String bookUuid,
    required String content,
    String? replyId,
  }) => withIdentity(() async {
    final trimmed = content.trim();
    if (!CommentText.isValid(trimmed)) {
      throw ArgumentError(
        'comment length must be '
        '${CommentText.minLength}-${CommentText.maxLength} characters',
      );
    }
    await _request(
      '/api/v3/member/bookcomment',
      data: {
        'book_id': bookUuid,
        'comment': trimmed,
        'reply_id': replyId ?? '',
      },
      browserComment: true,
    );
  });

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, dynamic>? params,
  ]) async {
    final envelope = await _request(path, params: params);
    final results = jsonMap(envelope, 'results');
    if (results == null) throw const NovelApiException('小说接口返回数据格式异常');
    return results;
  }

  Future<Map<String, dynamic>> _getBrowserComment(
    String path,
    Map<String, dynamic> params,
  ) async {
    final envelope = await _request(path, params: params, browserComment: true);
    final results = jsonMap(envelope, 'results');
    if (results == null) throw const NovelApiException('小说接口返回数据格式异常');
    return results;
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    Map<String, dynamic>? params,
    Map<String, dynamic>? data,
    bool browserComment = false,
  }) async {
    final identity = requestIdentity;
    try {
      final response = await _dio.request<Object?>(
        'https://${identity._host}$path',
        cancelToken: _cancelToken,
        queryParameters: {...?params, 'platform': 3},
        data: data,
        options: Options(
          method: data == null ? 'GET' : 'POST',
          responseType: ResponseType.plain,
          contentType: Headers.formUrlEncodedContentType,
          followRedirects: false,
          validateStatus: (_) => true,
          extra: {
            _identityExtraKey: identity,
            if (browserComment) _browserCommentExtraKey: true,
          },
        ),
      );
      ensureIdentity(identity);
      final responseBody = response.data;
      final rawResponseText = responseBody is String ? responseBody : null;
      Object? body = responseBody;
      if (body is String) {
        try {
          body = jsonDecode(body);
        } on FormatException {
          // Only echo a body for the explicitly requested 210 diagnostic case;
          // other malformed upstream responses stay sanitized.
          throw NovelApiException(
            response.statusCode == 210 ? rawResponseText ?? '' : '小说接口返回数据格式异常',
            statusCode: response.statusCode,
          );
        }
      }
      final envelope = jsonMap({'body': body}, 'body');
      final code = int.tryParse(jsonString(envelope, 'code'));
      if (response.statusCode != 200 || code != 200 || envelope == null) {
        final diagnosticResponse = response.statusCode == 210 || code == 210;
        throw NovelApiException(
          diagnosticResponse
              ? rawResponseText ?? jsonEncode(envelope ?? body)
              : '小说请求失败',
          code: code,
          statusCode: response.statusCode,
        );
      }
      return envelope;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      ensureIdentity(identity);
      throw NovelApiException(
        '小说网络请求失败',
        statusCode: error.response?.statusCode,
      );
    }
  }
}

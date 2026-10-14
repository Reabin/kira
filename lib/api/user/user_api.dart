import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../models/comic.dart';
import '../../models/copy_account_store.dart';
import '../../utils/app_dio.dart';
import '../../utils/copy_app_headers.dart';
import '../../utils/network_error.dart';
import '../../utils/network_proxy.dart';
import '../api_transport.dart';

/// 官网登录页在浏览器里的 UA 与客户端提示头。抓包取自官网真实请求，改版本号
/// 时三个头要一起改（UA 的 `Chrome/x`、`Edg/x` 与 `sec-ch-ua` 的版本必须一致，
/// 否则服务端一眼能看出是伪造头）。
const _copyWebUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36 Edg/155.0.0.0';
const _copyWebSecChUa =
    '"Microsoft Edge";v="155", "Chromium";v="155", "Not(A:Brand";v="24"';
const _copyWebAcceptLanguage =
    'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7,en-GB;q=0.6,ru;q=0.5,ja;q=0.4,'
    'zh-TW;q=0.3';

/// 拷贝漫画在 IP 被风控时返回的固定服务端文案关键词。
/// 该错误并非密码错误，而是当前出口 IP 被服务端封禁，需换网络/开代理后重试。
const _ipBlockedKeywords = <String>[
  '請到官網更新最新APP',
  '請到官网更新最新APP',
  '下載過破解版本',
  '下载过破解版本',
  '限制會自動解除',
  '限制会自动解除',
];

/// 判断登录错误是否为 IP 风控封禁（拷贝官方对破解 IP 的拦截文案）。
bool isIpBlockedLoginError(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    final candidate = <String>[
      if (error.message != null) error.message!,
      NetworkError.message(error),
      if (data is Map) ...[
        if (data['message'] is String) data['message'] as String,
        if (data['detail'] is String) data['detail'] as String,
        if (data['results'] is Map) ...[
          if ((data['results'] as Map)['detail'] is String)
            (data['results'] as Map)['detail'] as String,
          if ((data['results'] as Map)['message'] is String)
            (data['results'] as Map)['message'] as String,
        ],
      ],
    ];
    for (final text in candidate) {
      if (text.isEmpty) continue;
      for (final keyword in _ipBlockedKeywords) {
        if (text.contains(keyword)) return true;
      }
    }
  }
  return false;
}

class UserApi {
  final ApiTransport _t;
  final Dio Function(BaseOptions options)? copyDioFactory;
  final Dio Function(BaseOptions options)? profileDioFactory;
  final Dio Function(BaseOptions options)? copyProfileDioFactory;
  final Dio Function(BaseOptions options)? copyAppDioFactory;

  UserApi(
    this._t, {
    this.copyDioFactory,
    this.profileDioFactory,
    this.copyProfileDioFactory,
    this.copyAppDioFactory,
  });

  /// 按 [useProxy] 覆盖 Dio 的传输层。
  ///
  /// `AppDio` 建出来的 Dio 走 `HttpOverrides.global`（见
  /// [NetworkProxy.init]），因此默认就遵循应用的代理设置；接口登录要「先直连、
  /// 失败再用代理重试」，直连那一趟必须换掉传输层，只靠 BaseOptions 表达不了。
  ///
  /// [factory] 是调用方注入的测试替身；非 null 时原样返回它的产物 —— 换掉
  /// fake adapter 会让测试真的发网络请求。
  Dio _createLoginDio(
    Dio Function(BaseOptions options)? factory,
    BaseOptions options, {
    required String source,
    required bool useProxy,
    bool enableErrorLog = true,
  }) {
    if (factory != null) return factory(options);
    final dio = AppDio.create(
      source: source,
      options: options,
      enableErrorLog: enableErrorLog,
    );
    if (useProxy) return dio;
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => NetworkProxy.createHttpClient(
        connectionTimeout: AppDio.defaultConnectTimeout,
        useProxy: false,
      ),
    );
    return dio;
  }

  // ── 用户相关 ──

  /// 登录，返回用户信息
  Future<Map<String, dynamic>> login(String username, String password) async {
    final salt = Random().nextInt(9000) + 1000;
    final encoded = base64Encode(utf8.encode('$password-$salt'));
    final resp = await _t.dio.post(
      _t.url('/api/v3/login'),
      data:
          'username=$username&password=$encoded&salt=$salt&source=Official&version=2.2.0&platform=3',
      options: Options(
        contentType: 'application/x-www-form-urlencoded;charset=utf-8',
      ),
    );
    return resp.data['results'];
  }

  /// 拷贝 App 通道账号密码登录（`POST {copyApiHost}/api/v3/login`）。
  ///
  /// 与官网网页通道（[copyLogin]）的区别：这里走的是官方 App 的接口与请求头，
  /// 域名是高级设置里的 `COPY API URL`，登录成功直接返回 token，不需要
  /// WebView。密码的变换是 `base64(密码 + "-" + salt)`，salt 为本地随机数。
  ///
  /// 失败语义：服务端 IP 风控返回 `code 210` 且文案固定（见
  /// [isIpBlockedLoginError]），其余失败按 [NetworkError.throwBadResponse] 抛出。
  ///
  /// [useProxy] 为 false 时本次请求强制直连（见 [_applyProxyPreference]），
  /// 登录页据此先直连、失败再用代理重试一次。
  Future<Map<String, dynamic>> loginViaApp(
    String username,
    String password, {
    bool useProxy = true,
  }) async {
    // 官方 App 的 salt 是 [0,9998]，与官网网页通道用的 6 位区间不同。
    final salt = Random().nextInt(9999);
    final encoded = base64Encode(utf8.encode('$password-$salt'));
    final headers = await CopyAppHeaders.build(user: _t.user);
    final options = BaseOptions(
      followRedirects: false,
      validateStatus: (_) => true,
      headers: headers,
    );
    final dio = _createLoginDio(
      copyAppDioFactory,
      options,
      source: 'copy_app_login',
      useProxy: useProxy,
      enableErrorLog: false,
    );
    try {
      final resp = await dio.post(
        'https://${_t.user.copyApiHost}/api/v3/login',
        data: {
          'username': username,
          'password': encoded,
          'salt': salt.toString(),
        },
      );
      final data = resp.data;
      if (data is Map && data['code'] == 200) {
        final results = data['results'];
        if (results is Map) return Map<String, dynamic>.from(results);
      }
      final message = data is Map
          ? (data['message']?.toString() ??
                (data['results'] is Map
                    ? (data['results'] as Map)['detail']?.toString()
                    : null) ??
                'COPY app login failed')
          : 'COPY app login failed';
      NetworkError.throwBadResponse(
        response: resp,
        message: message,
        source: 'copy_app_login',
      );
    } finally {
      dio.close();
    }
  }

  /// 拷贝官网网页接口登录（`POST {copyLoginHost}/api/kb/web/login`）。
  ///
  /// 这是官网桌面站登录表单打的那个接口，也是网页通道（WebView 自动填表）
  /// 最终提交的同一个地址，区别只是这里由客户端直接发出请求、省掉 WebView。
  /// 域名取 `copyLoginHost`（不是 App 通道的 `copyApiHost`），密码是
  /// `base64(密码-salt)`，salt 为 6 位随机数（官网桌面站的实际区间）。
  ///
  /// 请求头按抓包 1:1 复刻：头名、头值、出现顺序都与浏览器一致。Dio 自己
  /// 计算 `content-length` 并接管 `host`/`accept-encoding`，这里不重复声明；
  /// 抓包里的 `_ga` 两个 cookie 是站点统计用的，与本请求无关，故意不带。
  ///
  /// [useProxy] 为 false 时本次请求强制直连（见 [_applyProxyPreference]）。
  Future<Map<String, dynamic>> copyLogin(
    String username,
    String password, {
    bool useProxy = true,
  }) async {
    final hostCopy = _t.user.copyLoginHost;
    final salt = Random().nextInt(900000) + 100000;
    final encoded = base64Encode(utf8.encode('$password-$salt'));
    final dio = _createLoginDio(
      copyDioFactory,
      BaseOptions(
        validateStatus: (_) => true,
        followRedirects: false,
        headers: {
          'sec-ch-ua-platform': '"Windows"',
          'user-agent': _copyWebUserAgent,
          'accept': 'application/json, text/plain, */*',
          'sec-ch-ua': _copyWebSecChUa,
          'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'sec-ch-ua-mobile': '?0',
          'platform': '2',
          'origin': 'https://$hostCopy',
          'sec-fetch-site': 'same-origin',
          'sec-fetch-mode': 'cors',
          'sec-fetch-dest': 'empty',
          'referer':
              'https://$hostCopy/web/login/loginByAccount?url=person%2Fhome',
          'accept-language': _copyWebAcceptLanguage,
          'cookie': 'webp=1',
          'priority': 'u=1, i',
        },
      ),
      source: 'copy_login',
      useProxy: useProxy,
    );

    try {
      final resp = await dio.post(
        'https://$hostCopy/api/kb/web/login',
        data: Uri(
          queryParameters: {
            'username': username,
            'password': encoded,
            'salt': salt.toString(),
            'platform': '2',
            'version': '2025.12.10',
            'source': 'freeSite',
          },
        ).query,
      );

      final data = resp.data;
      if (resp.statusCode == 200 && data is Map && data['code'] == 200) {
        final results = data['results'];
        if (results is Map) {
          final login = Map<String, dynamic>.from(results);
          // The form's login name is known even when the web endpoint omits
          // profile fields. Without it the independent store rejects a valid
          // login as identity-less, leaving novels apparently logged out.
          if (login['username']?.toString().trim().isNotEmpty != true) {
            login['username'] = username.trim();
          }
          return login;
        }
      }

      String? serverMessage;
      if (data is Map) {
        final raw = (data['message'] ?? data['detail'])?.toString().trim();
        if (raw != null && raw.isNotEmpty) serverMessage = raw;
      }
      final message =
          serverMessage ??
          (data is Map
              ? 'Login failed (code: ${data['code'] ?? resp.statusCode ?? 'unknown'})'
              : 'Login failed (HTTP ${resp.statusCode ?? 'unknown'})');
      NetworkError.throwBadResponse(
        response: resp,
        message: message,
        source: 'copy_login',
      );
    } finally {
      dio.close();
    }
  }

  /// Fetch one account profile without shared token/cookie injection or the
  /// primary transport's 401 auto-login interceptor.
  Future<Map<String, dynamic>> getCredentialInfo({
    required String token,
    required String source,
  }) async {
    if (source == 'copy') return getCopyCredentialInfo(token);
    final options = BaseOptions(
      followRedirects: false,
      validateStatus: (_) => true,
      headers: {
        'Accept': 'application/json',
        'platform': '3',
        'version': '2024.04.28',
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 15; 23113RKC6C Build/AQ3A.240812.002; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/131.0.6778.200 Mobile Safari/537.36',
        'X-Requested-With': 'com.manga2020.app',
        'webp': '1',
        'Authorization': 'Token $token',
      },
    );
    final dio =
        profileDioFactory?.call(options) ??
        AppDio.create(
          source: 'account_profile',
          options: options,
          enableErrorLog: false,
        );
    try {
      final response = await dio.get(_t.url('/api/v3/member/info'));
      final data = response.data;
      if (response.statusCode == 200 && data is Map && data['code'] == 200) {
        final results = data['results'];
        if (results is Map) return Map<String, dynamic>.from(results);
      }
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        message: 'Account profile request failed',
      );
    } finally {
      dio.close();
    }
  }

  /// Fetch a COPY profile with its own token and a COPY-app header set
  /// (`ref/用户/拷贝个人信息.txt`): `COPY/<version>` UA, `Referer`
  /// `com.copymanga.app-<version>` and form-urlencoded content type, not the
  /// HOT browser-style profile headers. The capture's signed headers
  /// (`x-auth-signature`, `x-auth-timestamp`, `dt`, `deviceinfo`, `pseudoid`,
  /// `umstring`) have no known generation rule and are deliberately omitted;
  /// request-capture cookies are omitted as well. Never use the shared HOT
  /// transport for this COPY host.
  Future<Map<String, dynamic>> getCopyCredentialInfo(String token) async {
    final candidate = token.trim();
    if (candidate.isEmpty) throw const FormatException('Empty COPY token');
    final version = _t.user.copyAppVersion;
    final options = BaseOptions(
      followRedirects: false,
      validateStatus: (_) => true,
      headers: {
        'User-Agent': 'COPY/$version',
        'Accept': 'application/json',
        'source': 'copyApp',
        'platform': '3',
        'version': version,
        'webp': '1',
        'Referer': 'com.copymanga.app-$version',
        'Content-Type': Headers.formUrlEncodedContentType,
        'Authorization': 'Token $candidate',
      },
    );
    final dio =
        copyProfileDioFactory?.call(options) ??
        AppDio.create(
          source: 'copy_account_profile',
          options: options,
          enableErrorLog: false,
        );
    try {
      final response = await dio.get(
        'https://${_t.user.copyApiHost}/api/v3/member/info',
        queryParameters: {'platform': 3},
      );
      final data = response.data;
      if (response.statusCode == 200 && data is Map && data['code'] == 200) {
        final results = data['results'];
        if (results is Map) return Map<String, dynamic>.from(results);
      }
      // Avoid logging the response body: it contains personal account data.
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        message: 'COPY profile request failed',
      );
    } finally {
      dio.close();
    }
  }

  /// Validate a candidate COPY token without changing either stored account.
  /// The collection endpoint is used only for validation, not profile lookup;
  /// COPY profile refresh is not currently wired into this client.
  Future<CopyAccountSession> validateCopyToken(String candidate) async {
    final token = candidate.trim();
    if (token.isEmpty) throw const FormatException('Empty COPY token');
    final version = _t.user.copyAppVersion;
    final options = BaseOptions(
      validateStatus: (_) => true,
      followRedirects: false,
      headers: {
        'User-Agent': 'COPY/$version',
        'Accept': 'application/json',
        'source': 'copyApp',
        'platform': '3',
        'version': version,
        'Connection': 'keep-alive',
        'Accept-Encoding': 'gzip',
        'webp': '1',
        'Authorization': 'Token $token',
      },
    );
    // Never reuse _t.dio: its 401 handler may re-login the primary HOT account.
    final dio =
        copyDioFactory?.call(options) ??
        AppDio.create(
          source: 'copy_token_validation',
          options: options,
          enableErrorLog: false,
        );
    try {
      final response = await dio.get(
        'https://${_t.user.copyApiHost}/api/v3/member/collect/books',
        queryParameters: {
          'limit': 1,
          'offset': 0,
          'free_type': 1,
          'ordering': '-datetime_modifier',
          'platform': 3,
        },
      );
      final data = response.data;
      if (response.statusCode == 200 && data is Map && data['code'] == 200) {
        final results = data['results'];
        if (results is Map && results['list'] is List) {
          // This endpoint validates a token, not a profile. Only reuse identity
          // already associated with this exact token; never guess a profile URL
          // or borrow the currently selected account's name.
          for (final account in _t.user.copyAccount.accounts) {
            if (account.token == token) return account;
          }
          for (final account in [
            ?_t.user.currentCredential,
            ..._t.user.savedCredentials,
          ]) {
            if (account.source == 'copy' &&
                account.token == token &&
                account.hasAccountKey) {
              return CopyAccountSession(
                token: token,
                accountId: account.accountId,
                userId: account.userId ?? '',
                username: account.username,
                nickname: account.nickname ?? '',
                avatar: account.avatar ?? '',
              );
            }
          }
          return CopyAccountSession(token: token);
        }
      }
      // No response-body logging: servers may echo the submitted credential.
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        message: 'COPY token validation failed',
      );
    } finally {
      dio.close();
    }
  }

  /// 获取个人信息
  Future<Map<String, dynamic>> getUserInfo() async {
    return _t.get('/api/v3/member/info');
  }

  Future<void> logout() async {
    await _t.dio.post(
      _t.url('/api/v3/logout'),
      options: Options(contentType: 'application/x-www-form-urlencoded'),
    );
  }

  void clearAuthState() {
    _t.clearCookies();
  }

  /// 获取浏览记录
  Future<({List<BrowseHistoryItem> list, int total})> getBrowseHistory({
    int limit = 20,
    int offset = 0,
  }) async {
    final data = await _t.get(
      '/api/v3/member/browse/comics',
      params: {
        'free_type': 1,
        'offset': offset,
        'limit': limit,
        '_update': true,
      },
    );
    final list = (data['list'] as List).map((e) {
      final item = Map<String, dynamic>.from(e);
      return BrowseHistoryItem(
        id: item['id'] as int? ?? 0,
        lastBrowseId: item['last_chapter_id']?.toString(),
        lastBrowseName: item['last_chapter_name']?.toString(),
        comic: Comic.fromJson(Map<String, dynamic>.from(item['comic'])),
      );
    }).toList();
    return (list: list, total: data['total'] as int? ?? list.length);
  }

  Future<void> clearBrowseHistory() async {
    if (_t.user.loginSource == 'copy') {
      final dio = AppDio.create(
        source: 'copy_api',
        options: BaseOptions(
          validateStatus: (_) => true,
          headers: {
            'User-Agent': 'COPY/${_t.user.copyAppVersion}',
            'Accept': 'application/json',
            'source': 'copyApp',
            'platform': '3',
            'version': _t.user.copyAppVersion,
            'Connection': 'keep-alive',
            'Accept-Encoding': 'gzip',
            'webp': '1',
            'Authorization': 'Token ${_t.user.token}',
          },
        ),
      );
      try {
        final resp = await dio.delete(
          'https://${_t.user.copyApiHost}/api/v3/member/browse/comics',
          queryParameters: {'platform': 3},
          options: Options(contentType: 'application/x-www-form-urlencoded'),
        );
        final data = resp.data;
        if (data is Map && data['code'] == 200) return;
        final message = data is Map
            ? (data['message']?.toString() ?? 'Failed to clear browse history')
            : 'Failed to clear browse history';
        NetworkError.throwBadResponse(
          response: resp,
          message: message,
          source: 'copy_api',
        );
      } finally {
        dio.close();
      }
    } else {
      await _t.dio.delete(
        _t.url('/api/v3/member/browse/comics'),
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );
    }
  }
}

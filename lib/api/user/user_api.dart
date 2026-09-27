import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../../models/comic.dart';
import '../../models/copy_account_store.dart';
import '../../utils/app_dio.dart';
import '../../utils/network_error.dart';
import '../api_transport.dart';

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

class CopyProfileUnavailableException implements Exception {
  const CopyProfileUnavailableException();

  @override
  String toString() => 'COPY profile refresh unavailable';
}

class UserApi {
  final ApiTransport _t;
  final Dio Function(BaseOptions options)? copyDioFactory;
  final Dio Function(BaseOptions options)? profileDioFactory;

  UserApi(this._t, {this.copyDioFactory, this.profileDioFactory});

  Dio _createCopyLoginDio(BaseOptions options) =>
      copyDioFactory?.call(options) ??
      AppDio.create(source: 'copy_login', options: options);

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

  /// 拷贝登录（域名可在高级设置中切换）
  Future<Map<String, dynamic>> copyLogin(
    String username,
    String password,
  ) async {
    final hostCopy = _t.user.copyLoginHost;
    final salt = Random().nextInt(900000) + 100000;
    final encoded = base64Encode(utf8.encode('$password-$salt'));
    final dio = _createCopyLoginDio(
      BaseOptions(
        validateStatus: (_) => true,
        followRedirects: false,
        // 头顺序对齐官方浏览器请求（ref/用户/拷贝登录-最新.txt）
        headers: {
          'sec-ch-ua-platform': '"Windows"',
          'user-agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36 Edg/150.0.0.0',
          'accept': 'application/json, text/plain, */*',
          'sec-ch-ua':
              '"Not;A=Brand";v="8", "Chromium";v="150", "Microsoft Edge";v="150"',
          'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'sec-ch-ua-mobile': '?0',
          'platform': '2',
          'origin': 'https://$hostCopy',
          'sec-fetch-site': 'same-origin',
          'sec-fetch-mode': 'cors',
          'sec-fetch-dest': 'empty',
          'referer':
              'https://$hostCopy/web/login/loginByAccount?url=person%2Fhome',
          'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6',
          'cookie': 'webp=1',
          'priority': 'u=1, i',
        },
      ),
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

  /// Fetch one HOT profile without the shared token/cookie injection or 401
  /// auto-login interceptor. A saved account must never borrow current auth.
  Future<Map<String, dynamic>> getCredentialInfo({
    required String token,
    required String source,
  }) async {
    if (source == 'copy') throw const CopyProfileUnavailableException();
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
      throw StateError('Account profile request failed');
    } finally {
      dio.close();
    }
  }

  /// Validate a candidate COPY token without changing either stored account.
  /// The confirmed light-novel collection endpoint requires authentication;
  /// COPY does not expose the primary transport's member/info endpoint.
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
                account.hasIdentity) {
              return CopyAccountSession(
                token: token,
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

  Future<List<String>> getSecurityQuestions() async {
    final resp = await _t.dio.get(
      _t.url('/api/v3/member/securityquestionall/'),
    );
    final results = resp.data['results'] as List? ?? const [];
    return results
        .map((e) => e['code']?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    required String question,
    required String answer,
  }) async {
    const hostWeb = 'www.manga2026.xyz';

    Map<String, dynamic> parseResponse(dynamic raw) {
      if (raw is Map) return Map<String, dynamic>.from(raw);
      if (raw is String && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) return Map<String, dynamic>.from(decoded);
        } catch (_) {
          return {'message': raw};
        }
      }
      return {};
    }

    String resolveMessage(Map<String, dynamic> data, Response<dynamic>? resp) {
      final results = data['results'];
      return data['message']?.toString() ??
          data['detail']?.toString() ??
          (results is Map ? results['detail']?.toString() : null) ??
          resp?.statusMessage ??
          'Registration failed';
    }

    final dio = AppDio.create(
      source: 'register',
      options: BaseOptions(
        validateStatus: (_) => true,
        headers: {
          'accept': 'application/json, text/plain, */*',
          'accept-language':
              'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7,en-GB;q=0.6,ru;q=0.5,ja;q=0.4,zh-TW;q=0.3',
          'cache-control': 'no-cache',
          'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'platform': '2',
          'pragma': 'no-cache',
          'origin': 'https://$hostWeb',
          'referer': 'https://$hostWeb/web/login/loginByAccount',
          'priority': 'u=1, i',
          'sec-ch-ua':
              '"Not:A-Brand";v="99", "Microsoft Edge";v="145", "Chromium";v="145"',
          'sec-ch-ua-mobile': '?0',
          'sec-ch-ua-platform': '"Windows"',
          'sec-fetch-dest': 'empty',
          'sec-fetch-mode': 'cors',
          'sec-fetch-site': 'same-origin',
          'user-agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36 Edg/145.0.0.0',
          'Cookie': _t.buildRegisterCookie(),
        },
      ),
    );

    try {
      final resp = await dio.post(
        'https://$hostWeb/api/v2/register',
        data: Uri(
          queryParameters: {
            'username': username,
            'password': password,
            'source': '',
            'platform': '2',
            'code': '',
            'invite_code': '',
            'version': '2025.12.10',
            'question': question,
            'answer': answer,
          },
        ).query,
      );

      final data = parseResponse(resp.data);
      if (resp.statusCode == 200 && data['code'] == 200) {
        final results = data['results'];
        return results is Map ? Map<String, dynamic>.from(results) : {};
      }

      final message = resolveMessage(data, resp);
      NetworkError.throwBadResponse(
        response: resp,
        message: message,
        source: 'register',
      );
    } finally {
      dio.close();
    }
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

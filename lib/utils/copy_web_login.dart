import 'dart:async';
import 'dart:convert';

import '../api/user/user_api.dart';
import '../models/copy_account_store.dart';
import '../models/user_manager.dart';
import 'app_logger.dart';

/// 从拷贝官网 cookie 中提取的登录凭证。
class CopyWebCredentials {
  final String token;
  final String userId;
  final String username;
  final String nickname;
  final String avatar;

  const CopyWebCredentials({
    required this.token,
    required this.userId,
    this.username = '',
    required this.nickname,
    required this.avatar,
  });
}

/// Validate the extracted candidate and use the same dual-domain commit as
/// password/token login. Kept outside the platform widget for offline tests.
Future<bool> completeCopyWebLogin({
  required UserManager user,
  required UserApi api,
  required CopyWebCredentials credentials,
}) => user.authenticateAndLogin(
  source: 'copy',
  authenticate: () async {
    final validated = await api.validateCopyToken(credentials.token);
    final session = CopyAccountSession(
      token: validated.token,
      userId: validated.userId.isNotEmpty
          ? validated.userId
          : credentials.userId,
      username: validated.username.isNotEmpty
          ? validated.username
          : credentials.username,
      nickname: credentials.nickname.isNotEmpty
          ? credentials.nickname
          : validated.nickname,
      avatar: credentials.avatar.isNotEmpty
          ? credentials.avatar
          : validated.avatar,
    );
    if (session.id == null) throw const CopyProfileUnavailableException();
    return session.toJson();
  },
);

/// 去掉 cookie 值两端的引号（拷贝官网会给部分值加引号）。
String _unquote(String value) {
  var v = value.trim();
  if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
    v = v.substring(1, v.length - 1);
  }
  return v;
}

/// 从拷贝官网（copyLoginHost）的 cookie 表中解析登录凭证。
///
/// 登录成功后官网会写入 `token`、`user_id`、`name`（URL 编码的昵称）、
/// `avatar` 等 cookie。解析失败（未登录）时返回 null。
CopyWebCredentials? parseCopyWebCookies(Map<String, String> cookies) {
  final token = _unquote(cookies['token'] ?? '');
  if (token.isEmpty) return null;

  String nickname = '';
  try {
    nickname = Uri.decodeComponent(_unquote(cookies['name'] ?? ''));
  } catch (_, st) {
    unawaited(
      AppLogger.instance.recordWarning(
        'Invalid COPY nickname encoding',
        stackTrace: st,
        source: 'copy_web_login.parse',
      ),
    );
  }

  return CopyWebCredentials(
    token: token,
    userId: _unquote(cookies['user_id'] ?? ''),
    username: _unquote(cookies['username'] ?? ''),
    nickname: nickname,
    avatar: _unquote(cookies['avatar'] ?? ''),
  );
}

/// Read profile fields from the same official-site storage snapshot as the
/// candidate token. Arbitrary hex strings are not tokens; no profile request is
/// invented and no storage contents are logged.
CopyWebCredentials? parseCopyWebStorage(Object? snapshot) {
  final scopes = snapshot is Map
      ? [snapshot['ls'], snapshot['ss']]
      : <Object?>[];
  for (final scope in scopes) {
    final maps = _storageMaps(scope, 0).toList();
    for (final tokenMap in maps) {
      final tokenValue = tokenMap['token'];
      if (tokenValue is! String) continue;
      final token = _unquote(tokenValue);
      if (token.isEmpty) continue;
      var profile = tokenMap;
      if (_profileField(profile, 'user_id').isEmpty &&
          _profileField(profile, 'username').isEmpty) {
        for (final map in _storageMaps(scope, 0, matchingToken: token)) {
          if (_profileField(map, 'user_id').isNotEmpty ||
              _profileField(map, 'username').isNotEmpty) {
            profile = map;
            break;
          }
        }
      }
      return CopyWebCredentials(
        token: token,
        userId: _profileField(profile, 'user_id'),
        username: _profileField(profile, 'username'),
        nickname: _profileField(profile, 'nickname'),
        avatar: _profileField(profile, 'avatar'),
      );
    }
  }
  return null;
}

String _profileField(Map<dynamic, dynamic> map, String key) =>
    map[key]?.toString().trim() ?? '';

Iterable<Map<dynamic, dynamic>> _storageMaps(
  Object? node,
  int depth, {
  String? matchingToken,
}) sync* {
  if (depth > 8) return;
  if (node is Map) {
    final token = node['token'];
    // Skip the whole conflicting account subtree, including token-less
    // profile children. A successful token probe cannot prove their identity.
    if (matchingToken != null &&
        token is String &&
        _unquote(token).isNotEmpty &&
        _unquote(token) != matchingToken) {
      return;
    }
    yield node;
    for (final value in node.values) {
      yield* _storageMaps(value, depth + 1, matchingToken: matchingToken);
    }
  } else if (node is List) {
    for (final value in node) {
      yield* _storageMaps(value, depth + 1, matchingToken: matchingToken);
    }
  } else if (node is String &&
      (node.trimLeft().startsWith('{') || node.trimLeft().startsWith('['))) {
    try {
      yield* _storageMaps(
        jsonDecode(node),
        depth + 1,
        matchingToken: matchingToken,
      );
    } catch (_) {
      unawaited(
        AppLogger.instance.recordWarning(
          'Invalid COPY WebView storage JSON',
          source: 'copy_web_login.storage',
        ),
      );
    }
  }
}

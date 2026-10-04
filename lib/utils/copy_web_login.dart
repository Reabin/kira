import 'dart:async';
import 'dart:convert';

import '../api/user/user_api.dart';
import '../models/user_manager.dart';
import 'app_logger.dart';

/// 从拷贝官网 cookie 或 storage 中提取的候选登录凭证。
class CopyWebCredentials {
  final String token;
  final String userId;
  final String username;
  final String nickname;
  final String avatar;

  /// Only a profile in the same stored authentication object as the token is
  /// associated with it. Independent cookies/storage keys may be stale.
  final bool profileBoundToToken;

  const CopyWebCredentials({
    required this.token,
    required this.userId,
    this.username = '',
    required this.nickname,
    required this.avatar,
    this.profileBoundToToken = false,
  });

  /// 该凭证是否与本机已保存的某个拷贝账号是同一个。
  ///
  /// WebView 里的登录态是持久的，官网登录页一打开就可能带着旧账号的
  /// cookie/storage。用于区分「本机认识的账号」（停提示条确认）与
  /// 「本次新登录的账号」。
  bool matchesSavedAccount(UserManager user) {
    final candidate = token.trim();
    if (candidate.isEmpty) return false;
    for (final account in user.copyAccount.accounts) {
      if (account.token == candidate) return true;
      if (userId.isNotEmpty && account.userId == userId) return true;
      if (username.isNotEmpty && account.username == username) return true;
    }
    for (final account in [?user.currentCredential, ...user.savedCredentials]) {
      if (account.source != 'copy') continue;
      if (account.token == candidate) return true;
      if (userId.isNotEmpty && account.userId == userId) return true;
      if (username.isNotEmpty && account.username == username) return true;
    }
    return false;
  }
}

/// WebView 提取到登录态后的处置动作。
enum WebLoginDisposition {
  /// 直接完成登录。
  complete,

  /// 停在提示条上让用户确认（已保存的账号）。
  knownAccount,

  /// 静默不动，把页面留给用户去登录别的账号。
  ignore,
}

/// 决定 WebView 里提取到的登录态如何处置。
///
/// 只有 [submittedLogin]（本次会话里钩到了一次真实的官网登录提交）才证明
/// 这份登录态是用户刚刚登录的结果；没有它，提取到的只能是进入页面前残留
/// 的旧会话。旧会话一律不自动完成——尤其该账号刚被登出/删除时，自动完成
/// 会在用户输入新账号前把它抢登回来：已保存的停在提示条上让用户确认，
/// 未保存的静默。用户点「我已完成登录」时走 [manual]，是明确意图，照常完成。
WebLoginDisposition disposeWebLoginCredentials({
  required CopyWebCredentials credentials,
  required UserManager user,
  required bool submittedLogin,
  bool manual = false,
}) {
  if (manual) return WebLoginDisposition.complete;
  final known = credentials.matchesSavedAccount(user);
  if (known) return WebLoginDisposition.knownAccount;
  return submittedLogin
      ? WebLoginDisposition.complete
      : WebLoginDisposition.ignore;
}

/// 官网登录页表单里抓到的账号密码。
///
/// 官网登录时密码直接由网页 POST 给服务器，客户端只接收 URL、拿不到表单体，
/// 所以只能靠在登录页注入脚本读取，供「自动重登」在令牌失效后使用。
class CopyWebLoginForm {
  final String username;
  final String password;

  const CopyWebLoginForm({required this.username, required this.password});
}

/// 表单内容能否并回某个账号。
///
/// 拷贝官网的 cookie 把登录名放在 `name` 里（本机存成昵称），所以用户名和
/// 昵称任一与表单一致就算同一个账号。两者都对不上时一律不写，避免把 A 的
/// 密码存到 B 账号上。
bool canApplyLoginForm({
  required String accountUsername,
  required String accountNickname,
  required String formUsername,
  required String password,
}) {
  final form = formUsername.trim();
  if (form.isEmpty || password.isEmpty) return false;
  return accountUsername.trim() == form || accountNickname.trim() == form;
}

/// Validate the extracted candidate and use the same dual-domain commit as
/// password/token login. Kept outside the platform widget for offline tests.
Future<bool> completeCopyWebLogin({
  required UserManager user,
  required UserApi api,
  required CopyWebCredentials credentials,
}) async {
  final saved = await user.authenticateAndLogin(
    source: 'copy',
    authenticate: () async {
      final validated = await api.validateCopyToken(credentials.token);
      // Validation may reuse a profile for this exact token. Cookie fields alone
      // cannot prove an association, so missing profile data never blocks login.
      if (!credentials.profileBoundToToken ||
          (validated.userId.isNotEmpty &&
              credentials.userId.isNotEmpty &&
              validated.userId != credentials.userId) ||
          (validated.username.isNotEmpty &&
              credentials.username.isNotEmpty &&
              validated.username != credentials.username)) {
        return validated.toJson();
      }
      return {
        ...validated.toJson(),
        'user_id': validated.userId.isNotEmpty
            ? validated.userId
            : credentials.userId,
        'username': validated.username.isNotEmpty
            ? validated.username
            : credentials.username,
        'nickname': credentials.nickname.isNotEmpty
            ? credentials.nickname
            : validated.nickname,
        'avatar': credentials.avatar.isNotEmpty
            ? credentials.avatar
            : validated.avatar,
      };
    },
  );
  if (saved) {
    final session = user.copyAccount.accounts
        .where((account) => account.token == credentials.token.trim())
        .firstOrNull;
    if (session != null) {
      user.refreshCopyCredentialInBackground(session, api: api);
    }
  }
  return saved;
}

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

/// Storage keys are independent writes. Only profiles inside a JSON object
/// carrying the same token may participate in account identity; a bare token
/// plus a separate userInfo entry is still a valid token-only candidate.
CopyWebCredentials? parseCopyWebStorage(
  Object? snapshot, {
  String? matchingToken,
}) {
  final scopes = snapshot is Map
      ? [snapshot['ls'], snapshot['ss']]
      : <Object?>[];
  for (final scope in scopes) {
    if (scope is! Map) continue;
    final rootToken = _storageToken(scope);
    if (matchingToken != null &&
        rootToken != null &&
        rootToken != matchingToken) {
      continue;
    }
    // Do not include the raw storage-key map as an authentication object.
    final maps = [
      for (final value in scope.values)
        ..._storageMaps(value, 0, matchingToken: matchingToken),
    ];
    final token =
        rootToken ??
        maps
            .map(_storageToken)
            .whereType<String>()
            .where((value) => matchingToken == null || value == matchingToken)
            .firstOrNull;
    if (token == null) continue;
    final profile = _boundProfile(scope, token);
    return CopyWebCredentials(
      token: token,
      userId: profile == null ? '' : _profileField(profile, 'user_id'),
      username: profile == null ? '' : _profileField(profile, 'username'),
      nickname: profile == null ? '' : _profileField(profile, 'nickname'),
      avatar: profile == null ? '' : _profileField(profile, 'avatar'),
      profileBoundToToken: profile != null,
    );
  }
  return null;
}

Map<dynamic, dynamic>? _boundProfile(
  Map<dynamic, dynamic> scope,
  String token,
) {
  Map<dynamic, dynamic>? displayOnly;
  for (final value in scope.values) {
    for (final tokenMap in _storageMaps(value, 0, matchingToken: token)) {
      if (_storageToken(tokenMap) != token) continue;
      for (final map in _storageMaps(tokenMap, 0, matchingToken: token)) {
        if (_profileField(map, 'user_id').isNotEmpty ||
            _profileField(map, 'username').isNotEmpty) {
          return map;
        }
        if (_profileField(map, 'nickname').isNotEmpty ||
            _profileField(map, 'avatar').isNotEmpty) {
          displayOnly ??= map;
        }
      }
    }
  }
  return displayOnly;
}

String? _storageToken(Map<dynamic, dynamic> map) {
  final value = map['token'];
  if (value is! String) return null;
  final token = _unquote(value);
  return token.isEmpty ? null : token;
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

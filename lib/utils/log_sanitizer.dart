import 'dart:collection';

/// 日志脱敏与截断的唯一入口。
///
/// 写入、读取历史记录、导出与复制都经过这里，保证同一套规则，且可以重复
/// 执行（对已经脱敏的文本再跑一次结果不变）。只对明确支持的字段与结构作
/// 保证，不承诺识别任意自由文本里的秘密。
class LogSanitizer {
  const LogSanitizer._();

  static const redacted = '[REDACTED]';
  static const maxMessageLength = 4000;
  static const maxStackTraceLength = 12000;
  static const maxContextValueLength = 2000;
  static const maxContextKeyLength = 200;

  /// 嵌套结构展开的最大层数，超过后退化成 toString 再清洗。
  static const _maxDepth = 5;

  /// 归一化后的敏感键（小写、去掉分隔符），覆盖项目里实际出现的命名。
  static const _sensitiveKeys = <String>{
    'authorization',
    'proxyauthorization',
    'xapikey',
    'xauthtoken',
    'token',
    'accesstoken',
    'refreshtoken',
    'idtoken',
    'authtoken',
    'usertoken',
    'sessiontoken',
    'apikey',
    'secret',
    'clientsecret',
    'appsecret',
    'password',
    'passwd',
    'pwd',
    'savedpassword',
    'newpassword',
    'oldpassword',
    'cookie',
    'setcookie',
    'session',
    'sessionid',
    'jsessionid',
    'phpsessid',
    'credential',
    'credentials',
  };

  /// 授权/Cookie 这类字段的值可以带空格和分号（`Cookie: a=1; b=2`），
  /// 因此整段吃到行尾或结构分隔符，宁可多遮也不漏。
  static final RegExp _headerValuePattern = RegExp(
    r'''(["']?)(authorization|proxy-authorization|x-api-key|cookie|set-cookie)(["']?)(\s*[:=]\s*)(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\n,}&]*)''',
    caseSensitive: false,
  );

  /// 普通标量字段：值到空白或分隔符为止；带引号的值（含 JSON 里的
  /// `"token":"..."`）走引号分支整段替换。
  static final RegExp _scalarValuePattern = RegExp(
    r'''(["']?)(access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|user[_-]?token|session[_-]?token|api[_-]?key|client[_-]?secret|app[_-]?secret|saved[_-]?password|new[_-]?password|old[_-]?password|password|passwd|pwd|token|secret|credentials?|sessionid|session)(["']?)(\s*[:=]\s*)(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s,;&}"']+)''',
    caseSensitive: false,
  );

  /// URL 里的 `user:password@host`。
  static final RegExp _uriUserInfoPattern = RegExp(
    r'([a-zA-Z][a-zA-Z0-9+.\-]*://)[^/\s@]*@',
  );

  /// 键名是否属于敏感字段（大小写、下划线、连字符都不影响判断）。
  static bool isSensitiveKey(Object? key) {
    final normalized = _normalizeKey(key?.toString() ?? '');
    return normalized.isNotEmpty && _sensitiveKeys.contains(normalized);
  }

  /// 清洗自由文本（消息、来源、堆栈、异常字符串），先脱敏再截断。
  static String text(String value, {int maxLength = maxMessageLength}) {
    if (value.isEmpty) return value;
    // 先遮头部字段（贪婪到行尾），再遮普通标量，避免 Cookie 里的
    // `sid=...` 先被标量规则按分号截断。
    final cleaned = value
        .replaceAllMapped(_headerValuePattern, _replaceHeaderValue)
        .replaceAllMapped(_scalarValuePattern, _replaceScalarValue);
    final withoutUserInfo = cleaned.replaceAllMapped(
      _uriUserInfoPattern,
      (match) => '${match.group(1)}$redacted@',
    );
    return _truncate(withoutUserInfo, maxLength);
  }

  /// 清洗 context：敏感键整值替换，其余递归展开后按文本规则再过一遍。
  static Map<String, String> context(Map<String, Object?>? context) {
    if (context == null || context.isEmpty) return const {};

    final sanitized = <String, String>{};
    for (final entry in context.entries) {
      final key = text(entry.key, maxLength: maxContextKeyLength);
      if (key.isEmpty) continue;
      final value = isSensitiveKey(entry.key)
          ? redacted
          : describe(entry.value);
      if (value.isEmpty) continue;
      sanitized[key] = value;
    }
    return sanitized;
  }

  /// 把任意值渲染成已清洗的单行文本，供 context 与诊断输出使用。
  static String describe(
    Object? value, {
    int maxLength = maxContextValueLength,
  }) {
    return _render(value, 0, HashSet<Object>.identity(), maxLength);
  }

  static String _render(
    Object? value,
    int depth,
    Set<Object> seen,
    int maxLength,
  ) {
    if (value == null) return '';
    if (value is String) return text(value, maxLength: maxLength);
    if (value is num || value is bool) return value.toString();

    if (depth >= _maxDepth || !seen.add(value)) {
      return text(_safeToString(value), maxLength: maxLength);
    }

    if (value is Map) {
      final buffer = StringBuffer('{');
      var first = true;
      for (final entry in value.entries) {
        if (!first) buffer.write(', ');
        first = false;
        buffer
          ..write(text('${entry.key}', maxLength: maxContextKeyLength))
          ..write(': ')
          ..write(
            isSensitiveKey(entry.key)
                ? redacted
                : _render(entry.value, depth + 1, seen, maxLength),
          );
      }
      buffer.write('}');
      return text(buffer.toString(), maxLength: maxLength);
    }

    if (value is Iterable) {
      final buffer = StringBuffer('[');
      var first = true;
      for (final item in value) {
        if (!first) buffer.write(', ');
        first = false;
        buffer.write(_render(item, depth + 1, seen, maxLength));
      }
      buffer.write(']');
      return text(buffer.toString(), maxLength: maxLength);
    }

    return text(_safeToString(value), maxLength: maxLength);
  }

  static String _replaceHeaderValue(Match match) {
    final openQuote = match.group(1)!;
    final closeQuote = match.group(3)!;
    return '$openQuote${match.group(2)}$closeQuote${match.group(4)}$redacted';
  }

  static String _replaceScalarValue(Match match) {
    final openQuote = match.group(1)!;
    final closeQuote = match.group(3)!;
    return '$openQuote${match.group(2)}$closeQuote${match.group(4)}$redacted';
  }

  static String _normalizeKey(String key) {
    final buffer = StringBuffer();
    for (final rune in key.toLowerCase().runes) {
      final char = String.fromCharCode(rune);
      if (RegExp(r'[a-z0-9]').hasMatch(char)) buffer.write(char);
    }
    return buffer.toString();
  }

  static String _safeToString(Object value) {
    try {
      return value.toString();
    } catch (_) {
      return value.runtimeType.toString();
    }
  }

  static String _truncate(String value, int maxLength) {
    if (maxLength <= 0 || value.length <= maxLength) return value;
    return '${value.substring(0, maxLength)}...';
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import 'log_sanitizer.dart';

typedef AppLogDirectoryProvider = Future<Directory> Function();

enum AppLogLevel {
  debug,
  info,
  warning,
  error;

  String displayName(AppLocalizations l10n) {
    return switch (this) {
      AppLogLevel.debug => l10n.appLogLevelDebug,
      AppLogLevel.info => l10n.appLogLevelInfo,
      AppLogLevel.warning => l10n.appLogLevelWarning,
      AppLogLevel.error => l10n.appLogLevelError,
    };
  }

  /// Locale-independent fallback label, used where no l10n context exists
  /// (e.g. serialization / logs).
  String get idLabel => name;

  int get severity {
    return switch (this) {
      AppLogLevel.debug => 0,
      AppLogLevel.info => 1,
      AppLogLevel.warning => 2,
      AppLogLevel.error => 3,
    };
  }

  bool isAtLeast(AppLogLevel minimumLevel) {
    return severity >= minimumLevel.severity;
  }

  static AppLogLevel fromName(
    String? name, {
    AppLogLevel fallback = AppLogLevel.error,
  }) {
    return AppLogLevel.values.firstWhere(
      (level) => level.name == name,
      orElse: () => fallback,
    );
  }
}

class AppLogEntry {
  const AppLogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
    this.stackTrace,
    this.context = const {},
  });

  final DateTime timestamp;
  final AppLogLevel level;
  final String source;
  final String message;
  final String? stackTrace;
  final Map<String, String> context;

  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.toUtc().toIso8601String(),
      'level': level.name,
      'source': source,
      'message': message,
      if (stackTrace != null && stackTrace!.isNotEmpty)
        'stackTrace': stackTrace,
      if (context.isNotEmpty) 'context': context,
    };
  }

  factory AppLogEntry.fromJson(Map<String, dynamic> json) {
    final timestamp = DateTime.tryParse(json['timestamp']?.toString() ?? '');
    final contextJson = json['context'];
    final context = <String, String>{};
    if (contextJson is Map) {
      for (final entry in contextJson.entries) {
        context[entry.key.toString()] = entry.value?.toString() ?? '';
      }
    }

    return AppLogEntry(
      timestamp:
          timestamp ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      level: AppLogLevel.fromName(json['level']?.toString()),
      source: json['source']?.toString() ?? 'app',
      message: json['message']?.toString() ?? '',
      stackTrace: json['stackTrace']?.toString(),
      context: context,
    );
  }

  String toPlainText() {
    final buffer = StringBuffer()
      ..writeln('time: ${timestamp.toLocal().toIso8601String()}')
      ..writeln('level: ${level.name}')
      ..writeln('source: $source')
      ..writeln('message: $message');

    if (context.isNotEmpty) {
      buffer.writeln('context:');
      for (final entry in context.entries) {
        buffer.writeln('  ${entry.key}: ${entry.value}');
      }
    }

    final stackTrace = this.stackTrace;
    if (stackTrace != null && stackTrace.isNotEmpty) {
      buffer
        ..writeln('stackTrace:')
        ..write(stackTrace);
    }

    return buffer.toString().trimRight();
  }
}

/// 日志目录初始化失败：读取/清空会显式失败，而不是假报「没有日志」。
///
/// 只暴露失败类型，不携带可能含路径或凭据的原始消息。
class AppLoggerUnavailableException implements Exception {
  const AppLoggerUnavailableException(this.cause);

  final Object cause;

  @override
  String toString() => 'AppLoggerUnavailableException(${cause.runtimeType})';
}

class AppLogger {
  AppLogger({
    AppLogDirectoryProvider? directoryProvider,
    this.maxFileSizeBytes = 1024 * 1024,
    this.maxRotatedFiles = 3,
  }) : _directoryProvider = directoryProvider ?? _defaultLogDirectory {
    assert(maxFileSizeBytes > 0);
    assert(maxRotatedFiles >= 0);
  }

  static final AppLogger instance = AppLogger();

  static const _currentLogFileName = 'error.log';
  static const _keyLoggingEnabled = 'app_logging_enabled';
  static const _keyMinimumLevel = 'app_logging_minimum_level';
  static const defaultLoggingEnabled = false;
  static const defaultMinimumLevel = AppLogLevel.warning;

  /// 单次导出最多带出的条目数，防止极端情况下把整块内存读爆。
  static const _maxExportEntries = 20000;

  final AppLogDirectoryProvider _directoryProvider;
  final int maxFileSizeBytes;
  final int maxRotatedFiles;

  Directory? _directory;
  Future<void>? _initFuture;
  Object? _initError;

  /// 写入、读取、清空共用的串行队列：文件操作彼此不交错。
  Future<void> _queue = Future<void>.value();

  bool _disabled = false;
  bool _loggingEnabled = defaultLoggingEnabled;
  AppLogLevel _minimumLevel = defaultMinimumLevel;

  bool get loggingEnabled => _loggingEnabled;
  AppLogLevel get minimumLevel => _minimumLevel;

  /// 目录不可用（初始化失败）时非空；供页面决定是否给出重试入口。
  bool get isUnavailable => _initError != null;

  Future<void> init() {
    return _initFuture ??= _init().catchError((Object error, StackTrace stack) {
      _disabled = true;
      _initError = error;
      debugPrint(
        'AppLogger init failed: '
        '${LogSanitizer.text('$error', maxLength: 200)}',
      );
    });
  }

  /// 初始化失败后的显式重试入口（日志页「重试」按钮）。
  ///
  /// 不在每条后台记录里反复重试：那只会把失败成本摊到业务路径上。
  Future<void> retryInit() {
    if (_initError == null) return init();
    _initError = null;
    _disabled = false;
    _initFuture = null;
    return init();
  }

  /// 重新读取日志设置(导入备份 / 清除数据后调用)。
  ///
  /// [init] 把首次读取的结果记忆在 `_initFuture` 里,进程内不再重读;导入
  /// 备份后 prefs 已变,必须走这条路径才能让内存态跟上。目录解析结果与
  /// 日志文件无关,无需重建。
  Future<void> reloadFromPrefs() => _loadSettings();

  Future<void> recordFlutterError(FlutterErrorDetails details) {
    final information = _collectFlutterInformation(details);
    return recordError(
      details.exception,
      stackTrace: details.stack,
      source: 'flutter',
      context: {
        if (details.library != null) 'library': details.library,
        if (details.context != null)
          'context': details.context!.toDescription(),
        if (information.isNotEmpty) 'information': information,
      },
    );
  }

  Future<void> recordError(
    Object error, {
    StackTrace? stackTrace,
    String source = 'app',
    Map<String, Object?>? context,
  }) {
    return record(
      error,
      level: AppLogLevel.error,
      stackTrace: stackTrace,
      source: source,
      context: context,
    );
  }

  Future<void> recordWarning(
    Object message, {
    StackTrace? stackTrace,
    String source = 'app',
    Map<String, Object?>? context,
  }) {
    return record(
      message,
      level: AppLogLevel.warning,
      stackTrace: stackTrace,
      source: source,
      context: context,
    );
  }

  Future<void> recordInfo(
    Object message, {
    StackTrace? stackTrace,
    String source = 'app',
    Map<String, Object?>? context,
  }) {
    return record(
      message,
      level: AppLogLevel.info,
      stackTrace: stackTrace,
      source: source,
      context: context,
    );
  }

  Future<void> recordDebug(
    Object message, {
    StackTrace? stackTrace,
    String source = 'app',
    Map<String, Object?>? context,
  }) {
    return record(
      message,
      level: AppLogLevel.debug,
      stackTrace: stackTrace,
      source: source,
      context: context,
    );
  }

  Future<void> record(
    Object message, {
    required AppLogLevel level,
    StackTrace? stackTrace,
    String source = 'app',
    Map<String, Object?>? context,
  }) {
    // 在调用点就固定事件内容：入队后调用方可能继续修改传入的对象，记录的
    // 应该是「当时发生了什么」，而不是「出队时它变成了什么」。
    final entry = AppLogEntry(
      timestamp: DateTime.now().toUtc(),
      level: level,
      source: LogSanitizer.text(
        source,
        maxLength: LogSanitizer.maxContextValueLength,
      ),
      message: LogSanitizer.text(_safeToString(message)),
      stackTrace: stackTrace == null
          ? null
          : LogSanitizer.text(
              stackTrace.toString(),
              maxLength: LogSanitizer.maxStackTraceLength,
            ),
      context: LogSanitizer.context(context),
    );

    return _enqueue(() async {
      await _ensureReady();
      if (!_shouldRecord(level)) return;
      await _writeEntry(entry);
    }).catchError((Object writeError, StackTrace stack) {
      debugPrint(
        'AppLogger write failed: '
        '${LogSanitizer.text('$writeError', maxLength: 200)}',
      );
    });
  }

  Future<void> setLoggingEnabled(bool enabled) async {
    _loggingEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyLoggingEnabled, enabled);
    } catch (error) {
      debugPrint(
        'AppLogger save logging enabled failed: '
        '${LogSanitizer.text('$error', maxLength: 200)}',
      );
    }
  }

  Future<void> setMinimumLevel(AppLogLevel level) async {
    _minimumLevel = level;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyMinimumLevel, level.name);
    } catch (error) {
      debugPrint(
        'AppLogger save minimum level failed: '
        '${LogSanitizer.text('$error', maxLength: 200)}',
      );
    }
  }

  /// 读取最近 [limit] 条（null 表示不限），最新的在前。
  ///
  /// 历史记录在构建条目之前统一净化，因此展示与复制共享同一套规则。
  /// 目录不可用或文件读取失败会抛错，由调用方呈现错误态。
  Future<List<AppLogEntry>> readEntries({int? limit = 200}) {
    return _enqueue(() => _readEntries(limit));
  }

  /// 导出为纯文本；默认带出全部日志（导出文件用），而不是只看得到的 200 条。
  Future<String> exportText({int? limit}) async {
    final entries = await readEntries(limit: limit ?? _maxExportEntries);
    return entries.map((entry) => entry.toPlainText()).join('\n\n---\n\n');
  }

  Future<void> clear() {
    return _enqueue(() async {
      await _ensureReady();
      _throwIfUnavailable();

      final directory = _directory;
      if (directory == null || !await directory.exists()) return;

      await Future.wait(
        _logFiles(
          directory,
        ).where((file) => file.existsSync()).map((file) => file.delete()),
      );
    });
  }

  /// 串行执行一次文件操作，返回给调用方的 Future 保留该操作自身的失败。
  ///
  /// 队列尾部单独吸收错误，避免一次失败卡死后续所有读写；调用方拿到的
  /// Future 仍然会抛出，读取/清空的失败因此可观察。
  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _init() async {
    await _loadSettings();
    final directory = await _directoryProvider();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    _directory = directory;
  }

  Future<void> _ensureReady() => init();

  void _throwIfUnavailable() {
    final error = _initError;
    if (error != null) throw AppLoggerUnavailableException(error);
  }

  Future<void> _writeEntry(AppLogEntry entry) async {
    final directory = _directory;
    if (_disabled || directory == null) return;
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    final line = jsonEncode(entry.toJson());
    final additionalBytes = utf8.encode('$line\n').length;
    await _rotateIfNeeded(directory, additionalBytes);
    await _currentLogFile(
      directory,
    ).writeAsString('$line\n', mode: FileMode.append, flush: true);
  }

  Future<List<AppLogEntry>> _readEntries(int? limit) async {
    await _ensureReady();
    _throwIfUnavailable();

    final directory = _directory;
    if (directory == null || !await directory.exists()) {
      return const [];
    }

    final entries = <AppLogEntry>[];
    for (final file in _logFiles(directory)) {
      if (!await file.exists()) continue;
      final lines = await file.readAsLines();
      for (final line in lines.reversed) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final json = jsonDecode(trimmed);
          if (json is Map<String, dynamic>) {
            entries.add(_sanitizeEntry(AppLogEntry.fromJson(json)));
            if (limit != null && entries.length >= limit) return entries;
          }
        } catch (_) {
          continue;
        }
      }
    }

    return entries;
  }

  /// 旧版本可能留下了未脱敏的记录：读回来时再洗一遍，历史文件本身不改写。
  static AppLogEntry _sanitizeEntry(AppLogEntry entry) {
    return AppLogEntry(
      timestamp: entry.timestamp,
      level: entry.level,
      source: LogSanitizer.text(
        entry.source,
        maxLength: LogSanitizer.maxContextValueLength,
      ),
      message: LogSanitizer.text(entry.message),
      stackTrace: entry.stackTrace == null
          ? null
          : LogSanitizer.text(
              entry.stackTrace!,
              maxLength: LogSanitizer.maxStackTraceLength,
            ),
      context: LogSanitizer.context(entry.context),
    );
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _loggingEnabled =
          prefs.getBool(_keyLoggingEnabled) ?? defaultLoggingEnabled;
      _minimumLevel = AppLogLevel.fromName(
        prefs.getString(_keyMinimumLevel),
        fallback: defaultMinimumLevel,
      );
    } catch (error) {
      debugPrint(
        'AppLogger load settings failed: '
        '${LogSanitizer.text('$error', maxLength: 200)}',
      );
    }
  }

  bool _shouldRecord(AppLogLevel level) {
    return !_disabled && _loggingEnabled && level.isAtLeast(_minimumLevel);
  }

  Future<void> _rotateIfNeeded(Directory directory, int additionalBytes) async {
    final current = _currentLogFile(directory);
    if (!await current.exists()) return;

    final currentLength = await current.length();
    if (currentLength + additionalBytes <= maxFileSizeBytes) return;

    if (maxRotatedFiles == 0) {
      await current.delete();
      return;
    }

    for (var index = maxRotatedFiles; index >= 1; index--) {
      final file = _rotatedLogFile(directory, index);
      if (!await file.exists()) continue;

      if (index == maxRotatedFiles) {
        await file.delete();
      } else {
        final next = _rotatedLogFile(directory, index + 1);
        if (await next.exists()) {
          await next.delete();
        }
        await file.rename(next.path);
      }
    }

    final firstRotated = _rotatedLogFile(directory, 1);
    if (await firstRotated.exists()) {
      await firstRotated.delete();
    }
    await current.rename(firstRotated.path);
  }

  Iterable<File> _logFiles(Directory directory) sync* {
    yield _currentLogFile(directory);
    for (var index = 1; index <= maxRotatedFiles; index++) {
      yield _rotatedLogFile(directory, index);
    }
  }

  File _currentLogFile(Directory directory) {
    return File(
      '${directory.path}${Platform.pathSeparator}$_currentLogFileName',
    );
  }

  File _rotatedLogFile(Directory directory, int index) {
    return File('${directory.path}${Platform.pathSeparator}error.$index.log');
  }

  static Future<Directory> _defaultLogDirectory() async {
    Directory baseDirectory;
    try {
      baseDirectory = await getApplicationSupportDirectory();
    } catch (_) {
      baseDirectory = await getApplicationDocumentsDirectory();
    }
    return Directory('${baseDirectory.path}${Platform.pathSeparator}logs');
  }

  static String _collectFlutterInformation(FlutterErrorDetails details) {
    final collector = details.informationCollector;
    if (collector == null) return '';

    try {
      final information = collector()
          .map((node) => node.toStringDeep())
          .where((line) => line.trim().isNotEmpty)
          .join('\n')
          .trim();
      return information;
    } catch (_) {
      return '';
    }
  }

  static String _safeToString(Object value) {
    try {
      return value.toString();
    } catch (_) {
      return value.runtimeType.toString();
    }
  }
}

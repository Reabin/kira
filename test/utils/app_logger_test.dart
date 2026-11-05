import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/utils/app_logger.dart';
import 'package:kira/utils/log_sanitizer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'app_logging_enabled': true});
    tempDir = await Directory.systemTemp.createTemp('kira_app_logger_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('records errors locally and redacts sensitive values', () async {
    final logger = AppLogger(directoryProvider: () async => tempDir);

    await logger.recordError(
      Exception('request failed token=abc123 password:secret'),
      stackTrace: StackTrace.fromString('authorization: Bearer abc123'),
      source: 'test',
      context: {'access_token': 'secret-token', 'screen': 'profile'},
    );

    final entries = await logger.readEntries();
    final exported = await logger.exportText();

    expect(entries, hasLength(1));
    expect(entries.single.source, 'test');
    expect(entries.single.message, contains('token=[REDACTED]'));
    expect(entries.single.message, contains('password:[REDACTED]'));
    expect(entries.single.message, isNot(contains('abc123')));
    expect(entries.single.stackTrace, contains('authorization: [REDACTED]'));
    expect(entries.single.stackTrace, isNot(contains('abc123')));
    expect(entries.single.context['access_token'], '[REDACTED]');
    expect(entries.single.context['screen'], 'profile');
    expect(exported, contains('source: test'));
  });

  test('rotates log files and reads newest entries first', () async {
    final logger = AppLogger(
      directoryProvider: () async => tempDir,
      maxFileSizeBytes: 320,
      maxRotatedFiles: 2,
    );
    final padding = List.filled(80, 'x').join();

    for (var index = 0; index < 8; index++) {
      await logger.recordError(
        Exception('error-$index $padding'),
        stackTrace: StackTrace.fromString('stack-$index'),
        source: 'rotation',
      );
    }

    final fileNames = await tempDir
        .list()
        .where((entity) => entity is File)
        .map((entity) => entity.uri.pathSegments.last)
        .toList();
    final entries = await logger.readEntries();

    expect(fileNames, contains('error.log'));
    expect(fileNames, contains('error.1.log'));
    expect(entries.first.message, contains('error-7'));
    expect(entries.length, greaterThan(1));
  });

  test('clear removes local log files', () async {
    final logger = AppLogger(directoryProvider: () async => tempDir);

    await logger.recordError(Exception('boom'), source: 'test');
    expect(await logger.readEntries(), isNotEmpty);

    await logger.clear();

    expect(await logger.readEntries(), isEmpty);
    expect(
      await tempDir.list().where((entity) => entity is File).isEmpty,
      true,
    );
  });

  test('defaults to warning threshold', () async {
    final logger = AppLogger(directoryProvider: () async => tempDir);

    await logger.recordInfo('info', source: 'level');
    await logger.recordWarning('warning', source: 'level');

    final entries = await logger.readEntries();

    expect(entries, hasLength(1));
    expect(entries.single.level, AppLogLevel.warning);
    expect(entries.single.message, 'warning');
  });

  test('records debug and info when minimum level is debug', () async {
    final logger = AppLogger(directoryProvider: () async => tempDir);

    await logger.setMinimumLevel(AppLogLevel.debug);
    await logger.recordDebug('debug', source: 'level');
    await logger.recordInfo('info', source: 'level');

    final entries = await logger.readEntries();

    expect(entries.map((entry) => entry.level), [
      AppLogLevel.info,
      AppLogLevel.debug,
    ]);
  });

  test('does not write entries when logging is disabled', () async {
    final logger = AppLogger(directoryProvider: () async => tempDir);

    await logger.setLoggingEnabled(false);
    await logger.recordError(Exception('disabled'), source: 'level');

    expect(await logger.readEntries(), isEmpty);
  });

  test(
    'serializes writes around clear so cleared entries stay cleared',
    () async {
      final logger = AppLogger(directoryProvider: () async => tempDir);

      final firstWrite = logger.recordError(Exception('before'), source: 'q');
      final clearing = logger.clear();
      final secondWrite = logger.recordError(Exception('after'), source: 'q');
      await Future.wait([firstWrite, clearing, secondWrite]);

      final entries = await logger.readEntries();

      expect(entries, hasLength(1));
      expect(entries.single.message, contains('after'));
    },
  );

  test(
    'captures timestamp and context at call time, not at flush time',
    () async {
      final logger = AppLogger(directoryProvider: () async => tempDir);
      final context = <String, Object?>{'step': 'before'};
      final before = DateTime.now().toUtc();

      final pending = logger.recordError(
        Exception('snapshot'),
        source: 'snapshot',
        context: context,
      );
      context['step'] = 'after';
      await pending;

      final entry = (await logger.readEntries()).single;

      expect(entry.context['step'], 'before');
      expect(entry.timestamp.difference(before).inSeconds.abs(), lessThan(5));
    },
  );

  test('keeps writing after a failed operation', () async {
    var failDirectory = true;
    final logger = AppLogger(
      directoryProvider: () async {
        if (failDirectory) throw const FileSystemException('denied');
        return tempDir;
      },
    );

    await logger.recordError(Exception('during-failure'), source: 'q');
    expect(logger.isUnavailable, isTrue);
    await expectLater(
      logger.readEntries(),
      throwsA(isA<AppLoggerUnavailableException>()),
    );

    failDirectory = false;
    await logger.retryInit();
    await logger.recordError(Exception('after-recovery'), source: 'q');

    final entries = await logger.readEntries();
    expect(entries.single.message, contains('after-recovery'));
  });

  test('re-sanitizes entries written by older versions', () async {
    final logger = AppLogger(directoryProvider: () async => tempDir);
    await logger.init();

    final legacy = jsonEncode({
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': 'error',
      'source': 'legacy',
      'message': 'failed {"token":"FAKE_LEGACY"}',
      'context': {'access_token': 'FAKE_LEGACY_CTX', 'screen': 'home'},
    });
    await File(
      '${tempDir.path}${Platform.pathSeparator}error.log',
    ).writeAsString('$legacy\n', mode: FileMode.append, flush: true);

    final entry = (await logger.readEntries()).single;

    expect(entry.message, isNot(contains('FAKE_LEGACY')));
    expect(entry.context['access_token'], LogSanitizer.redacted);
    expect(entry.context['screen'], 'home');
  });

  test('exports every stored entry, not just the newest page', () async {
    // 上限放大，保证 250 条都留在文件里：要验证的是导出的读取范围，
    // 而不是轮转（轮转丢弃最旧记录是预期行为）。
    final logger = AppLogger(
      directoryProvider: () async => tempDir,
      maxFileSizeBytes: 8 * 1024 * 1024,
    );

    for (var index = 0; index < 250; index++) {
      await logger.recordError(Exception('export-$index'), source: 'export');
    }

    final paged = await logger.readEntries();
    final exported = await logger.exportText();

    expect(paged, hasLength(200));
    expect(paged.first.message, contains('export-249'));
    expect(exported, contains('export-0'));
    expect(exported, contains('export-249'));
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/api_transport.dart';
import 'package:kira/utils/app_dio.dart';
import 'package:kira/utils/app_logger.dart';
import 'package:kira/utils/network_error.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 固定应答的假 adapter：只验证拦截器链行为，不发真实请求。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.respond);

  final ResponseBody Function(RequestOptions options) respond;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppLogger logger;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'app_logging_enabled': true});
    tempDir = await Directory.systemTemp.createTemp('kira_net_chain_test_');
    logger = AppLogger(directoryProvider: () async => tempDir);
    await logger.setMinimumLevel(AppLogLevel.debug);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// 复刻 ApiTransport 的真实装配：请求/响应/错误拦截器 + 统一日志拦截器。
  Dio buildDio(
    _StubAdapter adapter, {
    bool validateStatus = true,
    bool enableRateLimit = true,
  }) {
    final dio = Dio(
      BaseOptions(validateStatus: validateStatus ? (_) => true : null),
    );
    dio.httpClientAdapter = adapter;
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) =>
            ApiTransport.rejectIfBusinessError(response, handler),
      ),
    );
    AppDio.attachCommonInterceptors(
      dio,
      source: 'chain',
      enableRateLimit: enableRateLimit,
      enableErrorLog: false,
    );
    dio.interceptors.add(
      NetworkError.loggingInterceptor(source: 'chain', logger: logger),
    );
    return dio;
  }

  ResponseBody jsonBody(Map<String, Object?> payload, {int status = 200}) {
    return ResponseBody.fromString(
      jsonEncode(payload),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  test('records business errors returned as HTTP 200 exactly once', () async {
    final adapter = _StubAdapter(
      (_) => jsonBody({
        'code': 210,
        'message': 'FAKE_UPSTREAM_MESSAGE',
        'results': {'detail': 'FAKE_UPSTREAM_DETAIL', 'token': 'FAKE_NESTED'},
      }),
    );
    final dio = buildDio(adapter);

    await expectLater(
      dio.get<dynamic>('https://example.invalid/api/login'),
      throwsA(isA<DioException>()),
    );

    final entries = await logger.readEntries();
    expect(entries, hasLength(1));
    expect(entries.single.context['responseCode'], '210');

    // 记录的是可读消息，而不是 210 分支里那份整段上游 JSON。
    final text = entries.single.toPlainText();
    expect(text, contains('FAKE_UPSTREAM_MESSAGE'));
    expect(text, isNot(contains('"code":210')));
    expect(text, isNot(contains('FAKE_NESTED')));
    expect(text, isNot(contains('FAKE_UPSTREAM_DETAIL')));
  });

  test('records 429 once without duplicating the rate limit error', () async {
    final adapter = _StubAdapter((_) => ResponseBody.fromString('', 429));
    final dio = buildDio(adapter);

    await expectLater(
      dio.get<dynamic>('https://example.invalid/api/home'),
      throwsA(isA<DioException>()),
    );

    final entries = await logger.readEntries();
    expect(entries, hasLength(1));
    expect(entries.single.context['statusCode'], '429');
    expect(entries.single.message, isNot(contains('Too many requests')));
  });

  test('does not record cancelled requests', () async {
    final token = CancelToken();
    final adapter = _StubAdapter((_) {
      token.cancel();
      return ResponseBody.fromString('', 200);
    });
    final dio = buildDio(adapter);

    await expectLater(
      dio.get<dynamic>('https://example.invalid/api/home', cancelToken: token),
      throwsA(isA<DioException>()),
    );

    expect(await logger.readEntries(), isEmpty);
  });

  test('does not record when logging is disabled', () async {
    await logger.setLoggingEnabled(false);
    final adapter = _StubAdapter((_) => jsonBody({'code': 500}));
    final dio = buildDio(adapter);

    await expectLater(
      dio.get<dynamic>('https://example.invalid/api/home'),
      throwsA(isA<DioException>()),
    );

    expect(await logger.readEntries(), isEmpty);
  });

  test(
    'records plain HTTP failures with status but no response body',
    () async {
      final adapter = _StubAdapter(
        (_) => ResponseBody.fromString('FAKE_BODY_TOKEN=abc', 500),
      );
      final dio = buildDio(adapter, validateStatus: false);

      await expectLater(
        dio.get<dynamic>('https://example.invalid/api/home'),
        throwsA(isA<DioException>()),
      );

      final entry = (await logger.readEntries()).single;
      expect(entry.context['statusCode'], '500');
      expect(entry.toPlainText(), isNot(contains('FAKE_BODY_TOKEN')));
    },
  );
}

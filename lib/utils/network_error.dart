import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../l10n/app_localizations.dart';
import 'app_logger.dart';

/// App-wide network error helpers.
class NetworkError {
  static const _fallbackRateLimitMessage =
      'Too many requests. Please try again later.';

  static String rateLimitMessage([AppLocalizations? l10n]) {
    return l10n?.networkRateLimitMessage ?? _fallbackRateLimitMessage;
  }

  static Interceptor rateLimitInterceptor() {
    return InterceptorsWrapper(
      onResponse: (response, handler) {
        if (response.statusCode == 429) {
          // 继续交给后续错误拦截器（含日志拦截器），否则 429 会被静默吞掉。
          return handler.reject(_rateLimitFromResponse(response), true);
        }
        handler.next(response);
      },
      onError: (error, handler) {
        // 用 next 而不是 reject：reject 会跳过后续错误拦截器（含统一网络
        // 日志），429 就再也留不下痕迹了。已经归一化过的不再重复包装。
        if (error is RateLimitDioException || !isRateLimited(error)) {
          return handler.next(error);
        }
        handler.next(_rateLimitFromError(error));
      },
    );
  }

  static Interceptor loggingInterceptor({
    String source = 'network',
    AppLogger? logger,
  }) {
    return InterceptorsWrapper(
      onError: (error, handler) {
        unawaited(recordDioException(error, source: source, logger: logger));
        handler.next(error);
      },
    );
  }

  static Future<void> recordDioException(
    DioException error, {
    String source = 'network',
    AppLogger? logger,
  }) {
    if (CancelToken.isCancel(error)) return Future<void>.value();
    return (logger ?? AppLogger.instance).recordError(
      // 不直接写异常对象：DioException.toString() 会带上完整响应体与请求
      // 参数，业务错误码 210 的原文就藏在那里。这里只落受控摘要。
      _dioExceptionSummary(error),
      stackTrace: error.stackTrace,
      source: source,
      context: _dioErrorContext(error),
    );
  }

  static Future<void> recordDioResponse(
    Response<dynamic> response, {
    String source = 'network',
    AppLogLevel level = AppLogLevel.warning,
    String? message,
    AppLogger? logger,
  }) {
    return (logger ?? AppLogger.instance).record(
      message ?? _dioResponseMessage(response),
      level: level,
      source: source,
      context: _dioResponseContext(response),
    );
  }

  static Never throwBadResponse({
    required Response<dynamic> response,
    required String message,
    required String source,
    Object? error,
    AppLogger? logger,
  }) {
    final exception = DioException(
      requestOptions: response.requestOptions,
      response: response,
      message: message,
      error: error ?? message,
      type: DioExceptionType.badResponse,
    );
    unawaited(recordDioException(exception, source: source, logger: logger));
    throw exception;
  }

  static bool isRateLimited(Object? error) {
    if (error is RateLimitDioException) return true;
    if (error is DioException) return error.response?.statusCode == 429;
    if (error is Response) return error.statusCode == 429;
    return false;
  }

  static String message(Object error, {AppLocalizations? l10n}) {
    if (isRateLimited(error)) return rateLimitMessage(l10n);
    if (error is DioException) {
      final data = error.response?.data;
      final code = _codeFromData(data)?.toString();
      if (code == '210' || error.response?.statusCode == 210) {
        // Code 210 is intentionally verbose: retain the complete upstream body
        // so the user can diagnose temporary service/API errors.
        return data is String ? data : jsonEncode(data);
      }
      final dataMessage = _messageFromData(data);
      if (dataMessage != null) return dataMessage;
      final message = error.message;
      final responseCode = _codeFromData(data);
      if (l10n != null && responseCode != null) {
        return l10n.networkRequestFailedCode(responseCode.toString());
      }
      if (message != null &&
          message.isNotEmpty &&
          message != _fallbackRateLimitMessage) {
        return message;
      }
    }
    return error.toString();
  }

  static String? _messageFromData(Object? data) {
    if (data is Map) {
      final error = data['error'];
      if (error is Map && error['message'] is String) {
        return error['message'] as String;
      }
      final message = data['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    if (data is String && data.isNotEmpty) return data;
    return null;
  }

  static String _dioResponseMessage(Response<dynamic> response) {
    final method = response.requestOptions.method;
    final uri = response.requestOptions.uri;
    final statusCode = response.statusCode?.toString() ?? 'unknown';
    return 'HTTP $statusCode $method $uri';
  }

  static Map<String, Object?> _dioResponseContext(Response<dynamic> response) {
    final data = response.data;
    final context = <String, Object?>{
      'method': response.requestOptions.method,
      'url': response.requestOptions.uri.toString(),
    };

    final statusCode = response.statusCode;
    if (statusCode != null) context['statusCode'] = statusCode;
    final statusMessage = response.statusMessage;
    if (statusMessage != null) context['statusMessage'] = statusMessage;
    final responseCode = _codeFromData(data);
    if (responseCode != null) context['responseCode'] = responseCode;
    final responseMessage = _logMessageFromData(data);
    if (responseMessage != null) context['responseMessage'] = responseMessage;

    return context;
  }

  /// 日志里只保留可定位、可分享的摘要，不带完整响应体。
  static String _dioExceptionSummary(DioException error) {
    final statusCode = error.response?.statusCode;
    final status = statusCode == null ? '' : ' (HTTP $statusCode)';
    return 'DioException[${error.type.name}]$status';
  }

  /// 供日志使用的短消息：只接受结构化字段，不把整段响应体当消息。
  static String? _logMessageFromData(Object? data) {
    if (data is! Map) return null;
    final error = data['error'];
    if (error is Map && error['message'] is String) {
      return error['message'] as String;
    }
    final message = data['message'];
    if (message is String && message.isNotEmpty) return message;
    return null;
  }

  static Map<String, Object?> _dioErrorContext(DioException error) {
    final response = error.response;
    final data = response?.data;
    final context = <String, Object?>{
      'method': error.requestOptions.method,
      'url': error.requestOptions.uri.toString(),
      'type': error.type.name,
    };

    // 异常自带的 message 在业务错误里就是上游原文（code 210 时为整段
    // JSON），因此不再写入日志；界面提示仍走 message()。
    //
    // error.error 只在它是真正的异常对象时才记录：业务错误码场景下这里是
    // 上游 JSON 原文，写进去等于绕过摘要。SocketException 之类的底层原因
    // 仍要留下，否则分不清 DNS/TLS/连接失败。
    final rawError = error.error;
    if (rawError != null && rawError is! String) context['error'] = rawError;
    final responseCode = _codeFromData(data);
    if (responseCode != null) context['responseCode'] = responseCode;
    final responseMessage = _logMessageFromData(data);
    if (responseMessage != null) context['responseMessage'] = responseMessage;
    final statusCode = response?.statusCode;
    if (statusCode != null) context['statusCode'] = statusCode;

    return context;
  }

  static Object? _codeFromData(Object? data) {
    if (data is Map) return data['code'];
    return null;
  }

  static RateLimitDioException _rateLimitFromResponse(
    Response<dynamic> response,
  ) {
    return RateLimitDioException(
      requestOptions: response.requestOptions,
      response: response,
    );
  }

  static RateLimitDioException _rateLimitFromError(DioException error) {
    return RateLimitDioException(
      requestOptions: error.requestOptions,
      response: error.response,
      type: error.type,
      stackTrace: error.stackTrace,
    );
  }
}

class RateLimitDioException extends DioException {
  RateLimitDioException({
    required super.requestOptions,
    super.response,
    super.type = DioExceptionType.badResponse,
    super.stackTrace,
  }) : super(
         error: NetworkError.rateLimitMessage(),
         message: NetworkError.rateLimitMessage(),
       );

  @override
  String toString() => NetworkError.rateLimitMessage();
}

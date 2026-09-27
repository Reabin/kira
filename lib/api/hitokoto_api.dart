import 'package:dio/dio.dart';

import '../utils/app_dio.dart';
import '../utils/app_logger.dart';
import '../utils/json_helpers.dart';

/// 一言句子及其出处。
class HitokotoSentence {
  const HitokotoSentence({
    required this.text,
    required this.from,
    required this.uuid,
  });

  final String text;
  final String from;

  /// 句子唯一 ID，用于链接到一言官网（hitokoto.cn?uuid=…）。
  final String uuid;
}

/// 一言（Hitokoto）句子接口，用于配色方案预览等轻量装饰文本。
///
/// 请求不保证成功：失败一律静默返回 null，由调用方回退到本地文案。
class HitokotoApi {
  HitokotoApi._() : _dio = AppDio.create(source: 'hitokoto');

  static final HitokotoApi _instance = HitokotoApi._();
  factory HitokotoApi() => _instance;

  final Dio _dio;

  static const _endpoint = 'https://v1.hitokoto.cn/';

  /// 获取一句一言,默认动画+漫画类(c=a&c=b);[maxLength] 限制句子长度。
  Future<HitokotoSentence?> fetchSentence({
    List<String> types = const ['a', 'b'],
    int maxLength = 32,
  }) async {
    try {
      final response = await _dio.get<dynamic>(
        _endpoint,
        queryParameters: {
          'c': types,
          'encode': 'json',
          'max_length': maxLength,
        },
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) return null;
      final sentence = jsonString(data, 'hitokoto').trim();
      if (sentence.isEmpty) return null;
      return HitokotoSentence(
        text: sentence,
        from: jsonString(data, 'from').trim(),
        uuid: jsonString(data, 'uuid').trim(),
      );
    } catch (error, stack) {
      // 预览文本是锦上添花，失败不打扰用户。
      await AppLogger.instance.recordWarning(
        'Hitokoto sentence fetch failed (${error.runtimeType})',
        stackTrace: stack,
        source: 'hitokoto_api',
      );
      return null;
    }
  }
}

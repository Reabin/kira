import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AppIconSwitcher {
  static const _channel = MethodChannel('io.github.caolib.kira/app_icon');

  @visibleForTesting
  static bool? debugSupportedPlatformOverride;

  static bool get isSupportedPlatform =>
      debugSupportedPlatformOverride ??
      (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  static Future<void> setAppIcon(int index) async {
    if (!isSupportedPlatform) return;
    await _channel.invokeMethod<void>('setAppIcon', {'index': index});
  }

  static Future<int> getAppIconIndex() async {
    if (!isSupportedPlatform) return 0;
    final index = await _channel.invokeMethod<int>('getAppIconIndex');
    return index ?? 0;
  }
}

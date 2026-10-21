import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/utils/device_environment.dart';

void main() {
  test('reports the host OS and a plausible architecture', () {
    final environment = deviceEnvironment();
    // 测试跑在 VM 上,`Abi.current()` / `Platform.version` 都应可用;
    // 万一某平台探测不到,这里断言失败是「探测逻辑坏了」的信号。
    expect(environment, isNotNull);
    final host = Platform.isAndroid
        ? 'Android'
        : Platform.isIOS
        ? 'iOS'
        : Platform.isMacOS
        ? 'macOS'
        : Platform.isLinux
        ? 'Linux'
        : Platform.isWindows
        ? 'Windows'
        : null;
    expect(environment!.os, host);
    expect(environment.arch, isNotNull);
    expect(environment.arch, isNotEmpty);
  });

  test('Android architectures use release-file spellings', () {
    // 非 Android 宿主上仅验证可读写法,Android 写法由真机覆盖。
    final environment = deviceEnvironment();
    if (Platform.isAndroid) {
      expect(environment!.arch, anyOf('arm64-v8a', 'armeabi-v7a', 'x86_64'));
    } else {
      expect(environment!.arch, isNot(contains('-')));
    }
  });
}

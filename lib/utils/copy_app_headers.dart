import 'dart:io' show Platform;

import '../models/user_manager.dart';
import 'app_storage.dart';
import 'copy_signature.dart';

/// 拷贝 App 通道的业务请求头（除签名两项外的固定项）。
///
/// 这些头不参与鉴权判定，但值必须**稳定**：`device` / `deviceinfo` 在会话
/// 之间跳变会被服务端当成新设备。所以在首次使用时生成一次并持久化到
/// `AppStorage.preferences`，之后所有请求复用。
///
/// `authorization` 由调用方按需覆盖（登录前是空 token）。
class CopyAppHeaders {
  CopyAppHeaders._();

  static const _keyDevice = 'copy_device_id';
  static const _keyDeviceInfo = 'copy_device_info';

  /// 一次生成、进程内复用，避免每个请求都打一次 prefs。
  static ({String device, String deviceInfo})? _cached;

  static Future<({String device, String deviceInfo})> _identity() async {
    if (_cached != null) return _cached!;
    final prefs = await AppStorage.sharedPreferences();
    var device = prefs.getString(_keyDevice);
    var deviceInfo = prefs.getString(_keyDeviceInfo);
    if (device == null || device.isEmpty) {
      device = _randomToken(16);
      await prefs.setString(_keyDevice, device);
    }
    if (deviceInfo == null || deviceInfo.isEmpty) {
      deviceInfo = _defaultDeviceInfo();
      await prefs.setString(_keyDeviceInfo, deviceInfo);
    }
    return _cached = (device: device, deviceInfo: deviceInfo);
  }

  /// 构建一组完整请求头。`token` 为空时 `authorization` 为 `"Token "`。
  ///
  /// 传入 [token] 会覆盖 `authorization`；其余头调用方一般不需要改。
  static Future<Map<String, String>> build({
    required UserManager user,
    String? token,
  }) async {
    final identity = await _identity();
    final version = user.copyAppVersion;
    final now = DateTime.now();
    // 来源指纹 = MD5(密钥)。密钥缺失时签名头本身就会抛错,这里兜个空串,
    // 只为返回值里不出现 null。
    final umString = CopySignature.umString ?? '';
    return {
      // Referer 与 UA 里的版本号必须与 version 头一致，服务端会交叉校验。
      'user-agent': 'COPY/$version',
      'source': 'copyApp',
      'version': version,
      'versioncode': user.copyVersionCode,
      'platform': '3',
      'region': '1',
      'webp': '1',
      'device': identity.device,
      'deviceinfo': identity.deviceInfo,
      'pseudoid': CopySignature.pseudoId(),
      // 来源指纹 = MD5(密钥)；密钥缺失时整个 App 通道不可用，这里不会为空。
      'umstring': umString,
      'referer': 'com.copymanga.app-$version',
      'accept': 'application/json',
      'accept-language': '',
      'content-type': 'application/x-www-form-urlencoded',
      'authorization': 'Token ${token ?? ''}',
      // `dt` 走 UTC+8，与官方 App 一致；用本地时区会在跨时区设备上偏移。
      'dt': _utc8Date(now),
      ...CopySignature.headers(now: now),
    };
  }

  /// `yyyy.MM.dd`（UTC+8）。
  static String _utc8Date(DateTime now) {
    final shifted = now.toUtc().add(const Duration(hours: 8));
    final month = shifted.month.toString().padLeft(2, '0');
    final day = shifted.day.toString().padLeft(2, '0');
    return '${shifted.year}.$month.$day';
  }

  /// 机型的粗略描述。桌面 / 模拟器上取平台名即可 —— 服务端只用它做
  /// 统计与异常设备识别，不需要真实型号。
  static String _defaultDeviceInfo() {
    if (Platform.isAndroid) return 'Android-generic';
    if (Platform.isIOS) return 'iOS-generic';
    if (Platform.isWindows) return 'Windows-PC';
    if (Platform.isMacOS) return 'macOS-PC';
    if (Platform.isLinux) return 'Linux-PC';
    return 'unknown';
  }

  static String _randomToken(int length) {
    const alphabet =
        '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    final random = DateTime.now().microsecondsSinceEpoch;
    final buffer = StringBuffer();
    var state = random;
    for (var i = 0; i < length; i++) {
      // 设备标识只需唯一，不需要密码学强度，用时间种子线性同余即可。
      state = (state * 1103515245 + 12345) & 0x7fffffff;
      buffer.write(alphabet[state % alphabet.length]);
    }
    return buffer.toString();
  }
}

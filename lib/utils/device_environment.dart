import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

/// 尽力探测当前设备的系统与 CPU 架构,用于「切换到预览版」提示里展示。
///
/// 预览版(CI)只发布 Android arm64-v8a 包,只有 Android 设备会在意架构;
/// 因此 Android 上返回 ABI 文件名写法(arm64-v8a / armeabi-v7a / x86_64),
/// 其它平台返回人类可读的架构名(合并两处来源):
///  - [Abi.current] 直接给出运行中的 ABI(如 `android_arm64`),最准;
///  - `Platform.version` 的 host 标识(如 `windows_x64`)作为兜底,同一份
///    信息,但在极老的 VM 上更差异更小。
///
/// 任何一步失败都返回 null —— 探测失败只影响提示文案(整行不显示),
/// 绝不向上抛异常影响应用。非 Android 或架构串未知时为 null 之外的
/// 情况也一并覆盖。
({String os, String? arch})? deviceEnvironment() {
  try {
    final os = _osLabel();
    if (os == null) return null;
    return (os: os, arch: _archLabel());
  } catch (_) {
    // 兜底:探测本身出错也只会让提示少一行,不影响其它逻辑。
    return null;
  }
}

String? _osLabel() {
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  if (Platform.isWindows) return 'Windows';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isLinux) return 'Linux';
  if (Platform.isFuchsia) return 'Fuchsia';
  return null;
}

/// 架构名:Android 用发布包文件名写法,其它平台给人类可读写法。
String? _archLabel() {
  final raw = _rawAbi();
  if (raw == null) return null;
  final arch = raw.split('_').last;
  if (Platform.isAndroid) return _androidAbi(arch);
  return _readableArch(arch);
}

/// 运行中的 ABI 标识:`android_arm64` / `windows_x64` 这种,取不到时 null。
String? _rawAbi() {
  try {
    final name = Abi.current().toString();
    if (name.contains('_')) return name;
  } catch (_) {
    // 极老的 SDK 或非 VM 运行时:回退到 Platform.version。
  }
  try {
    // `Platform.version` 形如 `... on "windows_x64" ...`。
    final match = RegExp(r'on "([a-z0-9_]+)"').firstMatch(Platform.version);
    return match?.group(1);
  } catch (_) {
    return null;
  }
}

/// Android 架构 → 与发布物文件名一致的写法。
String? _androidAbi(String arch) => switch (arch) {
  'arm64' => 'arm64-v8a',
  'arm' => 'armeabi-v7a',
  'x64' => 'x86_64',
  'ia32' => 'x86',
  _ => null,
};

String? _readableArch(String arch) => switch (arch) {
  'arm64' => 'arm64',
  'arm' => 'arm32',
  'x64' => 'x86_64',
  'ia32' => 'x86',
  'riscv64' => 'riscv64',
  'riscv32' => 'riscv32',
  _ => null,
};

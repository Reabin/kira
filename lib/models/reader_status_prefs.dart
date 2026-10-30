import 'package:flutter/foundation.dart';

/// 状态组件（时间/网络/电量/章节名/页码/帧率浮层）的配置读写接口。
///
/// 漫画侧由 `ReaderSettings` 实现（`reader_status_overlay*` 键，无章节名
/// 段位），轻小说侧由 `NovelReaderStatusSettings` 实现（`novel_status_overlay*`
/// 键，含章节名段位）——两侧配置互不影响；渲染组件 `ReaderStatusOverlay`
/// 与设置组件 `ReaderStatusSettingsSection` 通过本接口复用，不感知来源。
abstract interface class ReaderStatusPrefs implements ChangeNotifier {
  bool get statusOverlay;
  bool get statusOverlayTime;
  bool get statusOverlayBattery;
  bool get statusOverlayNetwork;
  bool get statusOverlayPage;
  bool get statusOverlayFps;

  /// 章节名段位仅轻小说侧有效；漫画侧恒为 false，setter 为空实现。
  bool get statusOverlayChapter;

  /// 该侧支持的段位 id 及默认顺序；漫画不含 `chapter`。
  List<String> get statusOverlaySegmentIds;

  /// 段位显示顺序，是 [statusOverlaySegmentIds] 的一个排列。
  List<String> get statusOverlayOrder;

  /// 0=左上 1=顶部中间 2=右上 3=右下 4=底部中间 5=左下。
  int get statusOverlayPosition;

  /// 0.0（透明）~1.0（不透明），作用于背景色。
  double get statusOverlayOpacity;

  /// 前景色 ARGB；null 表示用默认（漫画白字、轻小说跟随阅读主题）。
  int? get statusOverlayForeground;

  /// 背景色 ARGB；null 表示用默认（漫画黑底、轻小说跟随阅读主题）。
  int? get statusOverlayBackground;

  /// 轻小说侧：配色跟随阅读主题（忽略手动前景/背景色）。
  /// 漫画侧不支持，恒为 false。
  bool get statusOverlayFollowTheme;

  /// 是否提供「跟随主题」能力（决定设置 UI 是否显示该开关）。
  bool get supportsStatusOverlayFollowTheme;

  Future<void> setStatusOverlay(bool value);
  Future<void> setStatusOverlayTime(bool value);
  Future<void> setStatusOverlayBattery(bool value);
  Future<void> setStatusOverlayNetwork(bool value);
  Future<void> setStatusOverlayPage(bool value);
  Future<void> setStatusOverlayFps(bool value);
  Future<void> setStatusOverlayChapter(bool value);
  Future<void> setStatusOverlayOrder(List<String> value);
  Future<void> setStatusOverlayPosition(int value);
  Future<void> setStatusOverlayOpacity(double value);
  Future<void> setStatusOverlayForeground(int? value);
  Future<void> setStatusOverlayBackground(int? value);

  /// 仅轻小说侧有效；漫画侧为空实现。
  Future<void> setStatusOverlayFollowTheme(bool value);
}

/// 保留输入顺序、剔除未知 id、去重，并把缺失的段位按默认顺序补到末尾。
List<String> sanitizeReaderStatusOrder(
  List<String> input,
  List<String> segmentIds,
) {
  final seen = <String>{};
  return [
    for (final id in input)
      if (segmentIds.contains(id) && seen.add(id)) id,
    ...segmentIds.where((id) => !seen.contains(id)),
  ];
}

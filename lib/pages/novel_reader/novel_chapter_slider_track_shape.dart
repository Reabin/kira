import 'package:flutter/material.dart';

/// 连续进度条的章节起点标记，不把拖动吸附到等距分段。
///
/// 只负责在默认轨道上叠画圆点；轨道粗细、滑块与光环由调用方按漫画阅读器
/// 的底栏进度条传入，颜色语义也一致：滑块之前（已读）用 active，之后用
/// inactive。
class NovelChapterSliderTrackShape extends RoundedRectSliderTrackShape {
  const NovelChapterSliderTrackShape({
    required this.chapterStarts,
    required this.activeColor,
    required this.inactiveColor,
    this.markerRadius = 2.5,
  });

  final List<double> chapterStarts;

  /// 已读一侧的圆点颜色（与 activeTickMarkColor 一致）。
  final Color activeColor;

  /// 未读一侧的圆点颜色（与 inactiveTickMarkColor 一致）。
  final Color inactiveColor;

  /// 圆点半径，与漫画底栏的 tickMarkRadius 一致。
  final double markerRadius;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
    if ((sliderTheme.trackHeight ?? 0) <= 0) return;
    final track = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final activePaint = Paint()..color = activeColor;
    final inactivePaint = Paint()..color = inactiveColor;
    for (final start in chapterStarts) {
      if (!start.isFinite || start < 0 || start > 1) continue;
      final fraction = textDirection == TextDirection.ltr ? start : 1 - start;
      final center = Offset(
        track.left + fraction * track.width,
        track.center.dy,
      );
      final passed = textDirection == TextDirection.ltr
          ? center.dx <= thumbCenter.dx
          : center.dx >= thumbCenter.dx;
      context.canvas.drawCircle(
        center,
        markerRadius,
        passed ? activePaint : inactivePaint,
      );
    }
  }
}

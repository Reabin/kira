import 'package:flutter/material.dart';

import '../../theme/reader_chrome.dart';
import '../../utils/adaptive_motion.dart';

/// 专注模式上下遮罩：开启时两块黑色挡板分别从屏幕顶/底伸出到设定比例，
/// 关闭时缩回边缘。
///
/// 高度随动画进度缩放（`ratio * progress`），所以遮罩边缘是滑出来的挡板，
/// 不是整块淡入；收缩到 0 后整个从树中移除。遮罩始终 `IgnorePointer`，
/// 挡板覆盖区域内的点按/翻页照常穿透。
class NovelFocusMask extends StatefulWidget {
  const NovelFocusMask({
    super.key,
    required this.enabled,
    required this.topRatio,
    required this.bottomRatio,
    required this.opacity,
  });

  final bool enabled;

  /// 可见区上/下边界，占屏幕高度比例。
  final double topRatio;
  final double bottomRatio;

  /// 挡板不透明度。
  final double opacity;

  @override
  State<NovelFocusMask> createState() => _NovelFocusMaskState();
}

class _NovelFocusMaskState extends State<NovelFocusMask>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    value: widget.enabled ? 1 : 0,
    duration: const Duration(milliseconds: 260),
  );

  @override
  void didUpdateWidget(covariant NovelFocusMask oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled == widget.enabled) return;
    if (widget.enabled) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  bool? _reducedMotion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = prefersReducedMotion(context);
    // 减少动画时直接跳到终点，不做伸出/缩回过渡。
    _controller.duration = adaptiveDuration(
      context,
      const Duration(milliseconds: 260),
    );
    // 系统设置在阅读途中切换：不留下半截动画，直接对齐当前开关状态。
    if (_reducedMotion != null && _reducedMotion != reduced) {
      _controller.value = widget.enabled ? 1 : 0;
    }
    _reducedMotion = reduced;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final progress = Curves.easeOutCubic.transform(
          _controller.value.clamp(0.0, 1.0),
        );
        if (progress == 0) return const SizedBox.shrink();
        final color = ReaderChrome.dimOverlay(widget.opacity);
        return Positioned.fill(
          key: const ValueKey('novel-focus-mask'),
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final height = constraints.maxHeight;
                return Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: height * widget.topRatio * progress,
                      child: ColoredBox(
                        key: const ValueKey('novel-focus-mask-top'),
                        color: color,
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: height * (1 - widget.bottomRatio) * progress,
                      child: ColoredBox(
                        key: const ValueKey('novel-focus-mask-bottom'),
                        color: color,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

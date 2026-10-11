part of '../main_shell.dart';

/// 测量子节点布局后的高度并回报，用于把页面 FAB 顶到底栏上方。
///
/// 底栏高度随样式（胶囊/经典）、文字缩放与安全区变化，写死常量会在这些场景
/// 下偏移；直接量渲染尺寸最稳。测量放在帧末，避免布局阶段写 notifier。
class _MeasureHeight extends StatefulWidget {
  const _MeasureHeight({required this.onHeight, required this.child});

  final ValueChanged<double> onHeight;
  final Widget child;

  @override
  State<_MeasureHeight> createState() => _MeasureHeightState();
}

class _MeasureHeightState extends State<_MeasureHeight> {
  final _key = GlobalKey();
  double? _reported;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final height = box.size.height;
      if (_reported == height) return;
      _reported = height;
      widget.onHeight(height);
    });
    return KeyedSubtree(key: _key, child: widget.child);
  }
}

/// 把底部导航占用的高度写进 body 的 `MediaQuery.viewPadding`，让页面自己的
/// Scaffold 把 `floatingActionButton`（源切换、回到顶部）放到底栏上方。
///
/// 悬浮模式开着 `extendBody`：Scaffold 只把底栏高度写进 `padding`，而页面
/// Scaffold 定位 FAB 读的是 `viewPadding`——不补的话 FAB 会落到屏幕底被底栏压住。
///
/// **不能碰 `padding`**：`padding` 是列表底部内边距的来源，变化会让整张列表
/// 重排。`viewPadding` 只被 Scaffold 的 FAB 定位读取，页面里贴底的 `Positioned`
/// 按钮改用 [NavBarInset] 单独跟随。
///
/// 只在悬浮模式下传入实际栏高。固定模式底栏不覆盖内容（`extendBody` 关闭），
/// 页面 Scaffold 的 contentBottom 已经减掉了底栏高度，再补一次会抬高两次。
class _BottomInsetForNestedFab extends StatelessWidget {
  const _BottomInsetForNestedFab({
    required this.barHeight,
    required this.child,
  });

  final double barHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final metrics = MediaQuery.of(context);
    // 底栏高度与系统安全区（手势条等）取较大者。
    final inset = math.max(metrics.viewPadding.bottom, barHeight);
    return NavBarInset(
      bottom: inset,
      child: MediaQuery(
        data: metrics.copyWith(
          viewPadding: metrics.viewPadding.copyWith(bottom: inset),
        ),
        child: child,
      ),
    );
  }
}

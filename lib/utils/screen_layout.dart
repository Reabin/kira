/// 列表页的宽屏（横屏 / 桌面窗口）布局约定。
///
/// 内容宽度钳制在 [maxContentWidth] 以内、两侧留白居中；
/// 可用宽度达到 [wideBreakpoint] 后卡片最大宽度放大到 [wideCardExtent]
/// （与首页 `_mangaHomeCardMaxExtent` 规则一致），避免大屏一排挤满小卡片。
class ScreenLayout {
  const ScreenLayout._();

  static const maxContentWidth = 1200.0;
  static const wideBreakpoint = 720.0;
  static const compactCardExtent = 130.0;
  static const wideCardExtent = 150.0;

  static double contentWidth(double screenWidth) =>
      screenWidth.clamp(0.0, maxContentWidth);

  /// 内容区两侧水平留白（含 16 的基础内边距）。
  static double horizontalPadding(double screenWidth) =>
      (screenWidth - contentWidth(screenWidth)) / 2 + 16;

  static double cardExtent(double screenWidth) =>
      contentWidth(screenWidth) >= wideBreakpoint
      ? wideCardExtent
      : compactCardExtent;

  /// 宽屏双列：把 [count] 个条目按 [weightOf] 估算的高度贪心装箱成两列，
  /// 返回两列的索引列表（各自保持原有先后顺序）。
  ///
  /// 按行配对会让同一行里矮的卡片下方留白，独立分列则只受两列总高差影响，
  /// 装箱时始终放入当前较矮的一列，可把总高差压到最小。
  static (List<int>, List<int>) splitTwoColumns(
    int count,
    int Function(int index) weightOf,
  ) {
    final left = <int>[];
    final right = <int>[];
    var leftWeight = 0;
    var rightWeight = 0;
    for (var index = 0; index < count; index++) {
      final weight = weightOf(index);
      if (leftWeight <= rightWeight) {
        left.add(index);
        leftWeight += weight;
      } else {
        right.add(index);
        rightWeight += weight;
      }
    }
    return (left, right);
  }
}

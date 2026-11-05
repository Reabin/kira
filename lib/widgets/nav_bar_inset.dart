import 'package:flutter/material.dart';

/// 页面底部为悬浮导航栏让出的高度（含隐藏动画进度，并已并入系统安全区）。
///
/// 页面里用 `Positioned` 手动贴底的悬浮按钮（搜索/发现/浏览历史等的回到顶部）
/// 读不到 Scaffold 的 `viewPadding`，用 `SafeArea` 又只会拿到固定的底栏高度、
/// 底栏隐藏后不下移。它们改用这个值跟随：
///
/// ```dart
/// Positioned(
///   bottom: AppSpacing.lg + NavBarInset.of(context),
///   child: BackToTopButton(onPressed: _scrollToTop),
/// )
/// ```
///
/// 只有依赖它的小块按钮子树会随动画重建，列表不依赖，因此不会触发重排。
class NavBarInset extends InheritedWidget {
  const NavBarInset({super.key, required this.bottom, required super.child});

  /// 底栏当前占用的高度；隐藏动画结束后回落到系统安全区。
  final double bottom;

  /// 页面底部需要让出的高度。
  ///
  /// 在主导航分支内取 shell 写入的值（已并入系统安全区与隐藏动画进度）；页面
  /// 挂在 shell 之外（如榜单、浏览历史等顶层路由）时回落到系统安全区，等价于
  /// 原先的 `SafeArea`，不会让按钮压到手势条上。
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NavBarInset>()?.bottom ??
      MediaQuery.viewPaddingOf(context).bottom;

  @override
  bool updateShouldNotify(NavBarInset oldWidget) => oldWidget.bottom != bottom;
}

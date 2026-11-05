import 'package:flutter/material.dart';

import 'nav_bar_inset.dart';

/// 主导航分支页面里，主滚动视图**末尾**的底部留白。
///
/// 悬浮底栏开着 `extendBody`，浮在页面内容之上；而 `CustomScrollView` 不会像
/// `ListView` 那样自动消费 `MediaQuery.padding.bottom`（框架明确如此设计：
/// 需要的话自行包 `SliverSafeArea`）。于是每个分支页只能各自硬编码一小段留白
/// （`SizedBox(height: 72)` 之类），那点留白只够让右下角的悬浮按钮不压住最后
/// 一行——底栏一浮起来就盖住了列表末尾，「我的」页最底下的「关于」正是如此。
///
/// 这里把留白接到 [NavBarInset] 上：高度 = 底栏占位 + [extra]。
/// [extra] 就是各页原有的那点硬编码留白，保留它继续给悬浮按钮让位。
///
/// 用法——把末尾的占位换成它，原来的小留白作为 [extra] 传入：
///
/// ```dart
/// slivers: [
///   // ...
///   SliverToBoxAdapter(child: BranchBottomSlack(extra: AppSpacing.xxl)),
/// ],
/// ```
class BranchBottomSlack extends StatelessWidget {
  const BranchBottomSlack({super.key, this.extra = 0});

  /// 底栏占位之外额外让出的高度（原本给悬浮按钮让位的留白）。
  final double extra;

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: NavBarInset.of(context) + extra);
}

import 'package:flutter/material.dart';

import '../utils/adaptive_motion.dart';

/// [Hero] 的统一入口：只在需要飞行动画时创建 Hero。
///
/// 开启「减少动画」（应用开关或系统无障碍设置）时直接返回 [child]，
/// 页面间不再有封面飞行，避免与关闭转场互相打架。
class AppHero extends StatelessWidget {
  const AppHero({
    super.key,
    required this.tag,
    required this.child,
    this.createRectTween,
    this.placeholderBuilder,
  });

  final Object tag;
  final Widget child;
  final CreateRectTween? createRectTween;
  final HeroPlaceholderBuilder? placeholderBuilder;

  @override
  Widget build(BuildContext context) {
    if (prefersReducedMotion(context)) return child;
    return Hero(
      tag: tag,
      createRectTween: createRectTween,
      placeholderBuilder: placeholderBuilder,
      child: child,
    );
  }
}

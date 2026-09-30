import 'package:flutter/material.dart';

/// 轻小说封面 Hero 动画标签，与 [ComicHeroTags] 同款时序与插值。
class NovelHeroTags {
  const NovelHeroTags._();

  static const transitionDuration = Duration(milliseconds: 650);
  static const reverseTransitionDuration = Duration(milliseconds: 500);

  static String base({
    required String scope,
    required String pathWord,
    required int index,
  }) {
    return 'novelHero:$scope:$pathWord:$index';
  }

  static String cover(String base) => '$base:cover';

  static RectTween createRectTween(Rect? begin, Rect? end) {
    return RectTween(begin: begin, end: end);
  }
}

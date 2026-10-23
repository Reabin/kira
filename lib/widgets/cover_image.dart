import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../utils/adaptive_motion.dart';
import 'cover_placeholder.dart';

/// 统一的网络封面：占位图与真实图交叉淡化。
///
/// 只在这里定义过渡，所有封面共用，避免各页面各写一套 fade 参数。
/// 内存缓存命中时 OctoImage 直接返回图片、不播动画，不会闪一下占位图。
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder = const CoverPlaceholder(),
    this.errorWidget = const CoverPlaceholder.error(),
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget placeholder;
  final Widget errorWidget;

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      imageUrl: url,
      width: width,
      height: height,
      fit: fit,
      fadeInDuration: adaptiveDuration(context, coverFadeDuration),
      fadeOutDuration: adaptiveDuration(context, coverFadeOutDuration),
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => errorWidget,
    );
  }
}

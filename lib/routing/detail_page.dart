import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Preserve the existing hero transition elsewhere, while allowing iOS to
/// interactively pop a detail route from the leading screen edge.
Page<void> buildDetailPage({
  required BuildContext context,
  required LocalKey key,
  required Widget child,
  required Duration transitionDuration,
  required Duration reverseTransitionDuration,
}) {
  if (Theme.of(context).platform == TargetPlatform.iOS) {
    return CupertinoPage<void>(key: key, child: child);
  }
  return CustomTransitionPage<void>(
    key: key,
    child: child,
    transitionDuration: transitionDuration,
    reverseTransitionDuration: reverseTransitionDuration,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      if (animation.status == AnimationStatus.reverse) {
        return Opacity(opacity: 0, child: child);
      }
      return child;
    },
  );
}

import 'package:flutter/material.dart';

/// Fade durations when a real cover takes over from its placeholder.
/// The placeholder fades out over the same window, giving a crossfade instead
/// of an abrupt swap.
const coverFadeDuration = Duration(milliseconds: 180);
const coverFadeOutDuration = Duration(milliseconds: 180);

/// Whether the user (or platform) requested reduced motion.
bool prefersReducedMotion(BuildContext context) {
  return MediaQuery.disableAnimationsOf(context);
}

/// Returns [duration], or [Duration.zero] when animations should be skipped.
Duration adaptiveDuration(BuildContext context, Duration duration) {
  return prefersReducedMotion(context) ? Duration.zero : duration;
}

/// Instant curve when reduced motion is on; otherwise [curve].
Curve adaptiveCurve(BuildContext context, [Curve curve = Curves.linear]) {
  return prefersReducedMotion(context) ? Curves.linear : curve;
}

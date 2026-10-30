import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Softens the newly reflowed layout without retaining a second Navigator tree
/// or competing with UIKit's window rotation. No first-frame or keyboard fade.
class OrientationReflow extends StatefulWidget {
  const OrientationReflow({super.key, required this.child});
  final Widget child;

  @override
  State<OrientationReflow> createState() => _OrientationReflowState();
}

class _OrientationReflowState extends State<OrientationReflow>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 220),
  );
  late final _opacity = Tween<double>(
    begin: 0.82,
    end: 1,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
  Orientation? _orientation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final orientation = MediaQuery.orientationOf(context);
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced || defaultTargetPlatform != TargetPlatform.iOS) {
      _controller.value = 1;
    } else if (_orientation != null && orientation != _orientation) {
      _controller.forward(from: 0);
    }
    _orientation = orientation;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    key: const ValueKey('orientation-reflow'),
    opacity: _opacity,
    child: widget.child,
  );
}

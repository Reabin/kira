import 'package:flutter/material.dart';

import '../utils/adaptive_motion.dart';

/// Keeps collapsible content mounted while hiding its input and semantics.
class CollapsibleContent extends StatefulWidget {
  const CollapsibleContent({
    super.key,
    required this.expanded,
    required this.child,
  });

  final bool expanded;
  final Widget child;

  @override
  State<CollapsibleContent> createState() => _CollapsibleContentState();
}

class _CollapsibleContentState extends State<CollapsibleContent>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    value: widget.expanded ? 1 : 0,
  );
  late final _height = _controller.drive(CurveTween(curve: Curves.easeOut));
  bool _reducedMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = prefersReducedMotion(context);
    if (_reducedMotion) {
      _controller.value = widget.expanded ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(covariant CollapsibleContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded == widget.expanded) return;
    final target = widget.expanded ? 1.0 : 0.0;
    if (_reducedMotion) {
      _controller.value = target;
    } else {
      _controller.animateTo(
        target,
        duration: Duration(milliseconds: widget.expanded ? 180 : 120),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _height,
      builder: (context, child) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: _height.value,
          child: child,
        ),
      ),
      child: ExcludeFocus(
        excluding: !widget.expanded,
        child: ExcludeSemantics(
          excluding: !widget.expanded,
          child: IgnorePointer(ignoring: !widget.expanded, child: widget.child),
        ),
      ),
    );
  }
}

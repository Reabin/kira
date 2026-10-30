import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../utils/app_logger.dart';
import 'layout_reflow.dart';

/// Keep the previously painted frame until the new layout has painted. Fade
/// that opaque frame over the live new page, never fade the entire app to black.
class OrientationReflow extends StatefulWidget {
  const OrientationReflow({
    super.key,
    required this.child,
    this.snapshotBackground,
    this.captureSnapshot,
  });
  final Widget child;
  final Color? snapshotBackground;
  final bool Function()? captureSnapshot;
  @override
  State<OrientationReflow> createState() => _OrientationReflowState();
}

class _OrientationReflowState extends State<OrientationReflow>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final boundaryKey = GlobalKey();
  ui.Image? snapshot;
  bool reduced = false;
  bool _capturePending = false;
  late final AnimationController controller;
  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted && snapshot != null) {
      final old = snapshot;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || snapshot != old) return;
        setState(() => snapshot = null);
        WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
      });
    }
  }

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 300),
    )..addStatusListener(_onStatus);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      controller.value = 1;
    }
  }

  bool _hasPlatformView(RenderObject node) {
    if (node is RenderOffstage && node.offstage) return false;
    if (node is PlatformViewRenderBox || node is RenderUiKitView) return true;
    var found = false;
    node.visitChildren((child) {
      if (!found) found = _hasPlatformView(child);
    });
    return found;
  }

  @override
  void didChangeMetrics() {
    if (widget.captureSnapshot?.call() == false) return;
    if (!mounted ||
        reduced ||
        defaultTargetPlatform != TargetPlatform.iOS ||
        snapshot != null ||
        _capturePending) {
      return;
    }
    final object = boundaryKey.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary ||
        !object.hasSize ||
        object.debugNeedsPaint ||
        _hasPlatformView(object)) {
      return;
    }
    final view = View.of(context);
    final next = view.physicalSize / view.devicePixelRatio;
    final oldSize = object.size;
    if (next.isEmpty ||
        oldSize.isEmpty ||
        (next.width > next.height) == (oldSize.width > oldSize.height)) {
      return;
    }
    try {
      final image = object.toImageSync(
        pixelRatio: math.min(view.devicePixelRatio, 1.5),
      );
      snapshot = image;
      _capturePending = true;
      controller.value = 0;
      // Metrics are delivered before the new frame, so this schedules only a
      // repaint and preserves the old texture without mounting a second route.
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _capturePending = false;
        if (mounted && snapshot != null && !reduced) {
          controller.forward(from: 0);
        }
      });
    } catch (error, stack) {
      AppLogger.instance.recordWarning(
        error,
        stackTrace: stack,
        source: 'orientation.snapshot',
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    snapshot?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutReflowScope(
    child: Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(key: boundaryKey, child: widget.child),
        if (snapshot != null)
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) => Opacity(
                    key: const ValueKey('orientation-snapshot'),
                    opacity:
                        1 - Curves.easeOutCubic.transform(controller.value),
                    child: ColoredBox(
                      color:
                          widget.snapshotBackground ??
                          Theme.of(context).scaffoldBackgroundColor,
                      child: RawImage(image: snapshot, fit: BoxFit.contain),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

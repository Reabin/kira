import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// FLIP geometry is shared across reparenting at responsive breakpoints.
class LayoutReflowScope extends StatefulWidget {
  const LayoutReflowScope({super.key, required this.child});
  final Widget child;
  @override
  State<LayoutReflowScope> createState() => _LayoutReflowScopeState();
}

class _LayoutReflowScopeState extends State<LayoutReflowScope> {
  final registry = _Registry();
  @override
  Widget build(BuildContext context) {
    registry.observe(MediaQuery.sizeOf(context));
    return _Scope(
      registry: registry,
      generation: registry.generation,
      child: widget.child,
    );
  }
}

class _Scope extends InheritedWidget {
  const _Scope({
    required this.registry,
    required this.generation,
    required super.child,
  });
  final _Registry registry;
  final int generation;
  @override
  bool updateShouldNotify(_Scope oldWidget) =>
      generation != oldWidget.generation;
}

class _Position {
  const _Position(this.rect, this.window);
  final Rect rect;
  final Size window;
}

class _Registry {
  Size window = Size.zero;
  int generation = 0;
  Duration changedAt = Duration.zero;
  final positions = <Object, _Position>{};
  void observe(Size size) {
    if (window == size) return;
    if (!window.isEmpty) {
      generation++;
      changedAt = SchedulerBinding.instance.currentFrameTimeStamp;
    }
    window = size;
  }

  bool get enteringWindow =>
      generation > 0 &&
      SchedulerBinding.instance.currentFrameTimeStamp - changedAt <
          const Duration(milliseconds: 500);
  void record(Object id, Rect rect) {
    positions.remove(id);
    positions[id] = _Position(rect, window);
    while (positions.length > 400) {
      positions.remove(positions.keys.first);
    }
  }
}

/// Animates only layout changes caused by a resized window, never scrolling,
/// navigation, or data refresh. The first resized frame is already inverted.
class ReflowMotion extends StatefulWidget {
  const ReflowMotion({
    super.key,
    required this.id,
    required this.child,
    this.resize = true,
  });
  final Object id;
  final Widget child;
  final bool resize;
  @override
  State<ReflowMotion> createState() => _ReflowMotionState();
}

class _ReflowMotionState extends State<ReflowMotion>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  AnimationController get controller => _controller ??= AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 340),
  );
  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_Scope>();
    if (scope == null) return widget.child;
    return _MotionRenderWidget(
      registry: scope.registry,
      generation: scope.generation,
      id: widget.id,
      resize: widget.resize,
      animation: controller,
      enabled:
          defaultTargetPlatform == TargetPlatform.iOS &&
          !MediaQuery.disableAnimationsOf(context),
      start: () {
        if (mounted) controller.forward(from: 0);
      },
      child: widget.child,
    );
  }
}

class _MotionRenderWidget extends SingleChildRenderObjectWidget {
  const _MotionRenderWidget({
    required this.registry,
    required this.generation,
    required this.id,
    required this.resize,
    required this.animation,
    required this.enabled,
    required this.start,
    required super.child,
  });
  final _Registry registry;
  final int generation;
  final Object id;
  final bool resize;
  final Animation<double> animation;
  final bool enabled;
  final VoidCallback start;
  @override
  _MotionBox createRenderObject(BuildContext context) => _MotionBox(this);
  @override
  void updateRenderObject(BuildContext context, _MotionBox renderObject) =>
      renderObject.update(this);
}

class _MotionBox extends RenderProxyBox {
  // Entrance opacity and motion can add layers even for a plain-text child.
  // Ancestor clips must therefore use composited clipping throughout reflow.
  @override
  bool get alwaysNeedsCompositing => true;

  _MotionBox(this.config);
  _MotionRenderWidget config;
  int observedGeneration = -1;
  Rect? from;
  bool pendingStart = false;
  bool entering = false;
  Matrix4 matrix = Matrix4.identity();
  void update(_MotionRenderWidget value) {
    if (value.id != config.id || value.registry != config.registry) {
      observedGeneration = -1;
      from = null;
      pendingStart = false;
    }
    if (attached && value.animation != config.animation) {
      config.animation.removeListener(markNeedsPaint);
      value.animation.addListener(markNeedsPaint);
    }
    config = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    config.animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    config.animation.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    final target = localToGlobal(Offset.zero) & size;
    final registry = config.registry;
    if (observedGeneration != config.generation) {
      final previous = registry.positions[config.id];
      observedGeneration = config.generation;
      entering = previous == null && registry.enteringWindow;
      if (config.enabled &&
          registry.enteringWindow &&
          (entering ||
              (previous != null && previous.window != registry.window))) {
        from = previous?.rect ?? target.shift(const Offset(0, 40));
        pendingStart = true;
        final revision = observedGeneration;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!attached || observedGeneration != revision || from == null) {
            return;
          }
          pendingStart = false;
          config.start();
        });
      } else {
        from = null;
        entering = false;
        pendingStart = false;
      }
    }
    final progress = pendingStart ? 0.0 : config.animation.value;
    // New cells rise in a short spatial cascade; existing cells keep their
    // continuous old-to-new trajectory, including interrupted window resizing.
    final lag = entering
        ? ((target.top / 80).floor() + (target.left / 160).floor()) % 4 * 0.04
        : 0.0;
    final t = config.enabled && from != null
        ? Curves.easeInOutCubic.transform(
            ((progress - lag) / (1 - lag)).clamp(0, 1),
          )
        : 1.0;
    final actual = from == null ? target : Rect.lerp(from, target, t)!;
    final sx = config.resize ? actual.width / size.width : 1.0;
    final sy = config.resize ? actual.height / size.height : 1.0;
    matrix = Matrix4.diagonal3Values(
      sx,
      sy,
      1,
    )..setTranslationRaw(actual.left - target.left, actual.top - target.top, 0);
    registry.record(
      config.id,
      Rect.fromLTWH(actual.left, actual.top, size.width * sx, size.height * sy),
    );
    void paintChild(PaintingContext context, Offset offset) =>
        context.pushTransform(needsCompositing, offset, matrix, super.paint);
    if (entering && t < 1) {
      context.pushOpacity(offset, (255 * t).round(), paintChild);
    } else {
      paintChild(context, offset);
    }
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(matrix);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!hitTestChildren(result, position: position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintTransform(
        transform: matrix,
        position: position,
        hitTest: (result, position) =>
            child?.hitTest(result, position: position) ?? false,
      );
}

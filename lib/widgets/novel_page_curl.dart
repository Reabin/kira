import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 由父层驱动的仿真书页翻页，仅负责渲染，不处理手势或提交页码。
///
/// [animation] 的 0/1 分别表示起始/完成。向前翻时当前页从右侧卷起，
/// 向后翻时使用反向卷曲进度，让上一页从左侧展开。视口宽高必须有界。
/// [originY] 是落点相对视口高度的 0..1 坐标，决定卷起上角、下角或侧边。
/// 正文保持原排版；[turningPageBack] 必须使用独立的 widget 实例。
class NovelPageCurl extends StatelessWidget {
  const NovelPageCurl({
    super.key,
    required this.animation,
    required this.forward,
    required this.originY,
    required this.paperColor,
    required this.turningPage,
    required this.turningPageBack,
    required this.underneath,
  });

  final Animation<double> animation;
  final bool forward;
  final double originY;
  final Color paperColor;
  final Widget turningPage;
  final Widget turningPageBack;
  final Widget underneath;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) {
          assert(
            constraints.hasBoundedWidth && constraints.hasBoundedHeight,
            'NovelPageCurl requires a bounded viewport.',
          );
          final size = constraints.biggest;
          final dark = paperColor.computeLuminance() < 0.25;
          final backColor = Color.lerp(
            paperColor,
            dark ? Colors.white : Colors.black,
            dark ? 0.045 : 0.025,
          )!;
          // 子树固定在帧 builder 外，动画只改变裁剪与绘制，不重排正文。
          final front = RepaintBoundary(
            child: ColoredBox(color: paperColor, child: turningPage),
          );
          final back = Opacity(
            opacity: 0.16,
            child: RepaintBoundary(child: turningPageBack),
          );
          final below = RepaintBoundary(
            child: ColoredBox(color: paperColor, child: underneath),
          );

          return AnimatedBuilder(
            animation: animation,
            child: below,
            builder: (context, underneathLayer) {
              final value = animation.value.clamp(0.0, 1.0);
              final curl = forward ? value : 1.0 - value;
              final geometry = _CurlGeometry(size, curl, originY);
              return Stack(
                fit: StackFit.expand,
                children: [
                  ExcludeSemantics(
                    excluding: curl == 0,
                    child: underneathLayer!,
                  ),
                  ExcludeSemantics(
                    excluding: curl == 1,
                    child: ClipPath(
                      clipper: _CurlClipper(geometry.frontPath),
                      clipBehavior: curl == 0 ? Clip.hardEdge : Clip.antiAlias,
                      child: front,
                    ),
                  ),
                  CustomPaint(painter: _CurlShadowPainter(geometry)),
                  IgnorePointer(
                    child: ExcludeSemantics(
                      child: ClipPath(
                        clipper: _CurlClipper(geometry.backPath),
                        child: ColoredBox(
                          color: backColor,
                          child: Transform(
                            transform: geometry.reflection,
                            transformHitTests: false,
                            child: back,
                          ),
                        ),
                      ),
                    ),
                  ),
                  CustomPaint(
                    painter: _CurlSurfacePainter(
                      geometry,
                      paperColor,
                      backColor,
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Two-page sheet: the front is the current right leaf, and its opaque back
/// is the next left leaf. The same curved fold crosses the gutter continuously.
class SpreadPageCurl extends StatelessWidget {
  const SpreadPageCurl({
    super.key,
    required this.progress,
    required this.reverse,
    required this.paperColor,
    required this.before,
    required this.after,
  });
  final double progress;
  final bool reverse;
  final Color paperColor;
  final Widget Function() before;
  final Widget Function() after;

  Widget _normal(Widget page) =>
      reverse ? Transform.flip(flipX: true, child: page) : page;

  @override
  Widget build(BuildContext context) {
    Widget spread = LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final leaf = Rect.fromLTWH(
          size.width / 2,
          0,
          size.width / 2,
          size.height,
        );
        final geometry = _CurlGeometry(
          size,
          progress.clamp(0, 1),
          0.9,
          leafRect: leaf,
          keepBackAtEnd: true,
        );
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: paperColor, child: _normal(after())),
              ClipRect(clipper: _LeftLeafClipper(), child: _normal(before())),
              ClipPath(
                clipper: _CurlClipper(geometry.frontPath),
                child: RepaintBoundary(child: _normal(before())),
              ),
              CustomPaint(painter: _CurlShadowPainter(geometry)),
              ClipPath(
                clipper: _CurlClipper(geometry.backPath),
                child: Transform(
                  transform: geometry.reflection,
                  transformHitTests: false,
                  child: RepaintBoundary(
                    child: Transform.flip(flipX: true, child: _normal(after())),
                  ),
                ),
              ),
              CustomPaint(
                painter: _CurlSurfacePainter(
                  geometry,
                  Colors.white,
                  Colors.white,
                ),
              ),
            ],
          ),
        );
      },
    );
    if (reverse) spread = Transform.flip(flipX: true, child: spread);
    return spread;
  }
}

class _LeftLeafClipper extends CustomClipper<Rect> {
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width / 2, size.height);
  @override
  bool shouldReclip(_LeftLeafClipper oldClipper) => false;
}

/// 纸角沿连续轨迹移动，折线是原纸角与移动纸角的垂直平分线。
/// 折线附近按半圆柱投影，远离卷边的纸背仅反射，不整体缩放纸张。
class _CurlGeometry {
  _CurlGeometry(
    Size size,
    double curl,
    double originY, {
    Rect? leafRect,
    bool keepBackAtEnd = false,
  }) {
    final rect = leafRect ?? (Offset.zero & size);
    if (size.isEmpty || curl == 0 || (curl == 1 && !keepBackAtEnd)) {
      frontPath = curl == 0 ? (Path()..addRect(rect)) : Path();
      return;
    }

    strength = math.sin(math.pi * curl);
    final origin = originY.clamp(0.0, 1.0);
    final fromBottom = origin >= 0.5;
    final corner = fromBottom ? rect.bottomRight : rect.topRight;
    final lift =
        math.min(rect.height * 0.16, rect.width * 0.2) *
        (origin - 0.5).abs() *
        2 *
        strength;
    final touch =
        corner - Offset(rect.width * 2 * curl, fromBottom ? lift : -lift);
    final displacement = corner - touch;
    normal = displacement / displacement.distance;
    radius = math.min(
      rect.shortestSide * 0.075 * strength,
      displacement.distance * 0.16,
    );
    final halfArc = math.pi * radius / 2;
    final bisector = (_project(corner) + _project(touch)) / 2;
    crease = bisector - halfArc;

    // 纯反射保留折线方向上的长度，原纸角恰好落在移动纸角上。
    // 不能对整个矩阵乘缩放系数，否则折线上的点也会滑动、纸面会缩水。
    reflection = Matrix4.identity()
      ..setEntry(0, 0, 1 - 2 * normal.dx * normal.dx)
      ..setEntry(0, 1, -2 * normal.dx * normal.dy)
      ..setEntry(1, 0, -2 * normal.dx * normal.dy)
      ..setEntry(1, 1, 1 - 2 * normal.dy * normal.dy)
      ..setEntry(0, 3, 2 * bisector * normal.dx)
      ..setEntry(1, 3, 2 * bisector * normal.dy);

    final corners = [
      rect.topLeft,
      rect.topRight,
      rect.bottomRight,
      rect.bottomLeft,
    ];
    final front = _cut(corners, bisector, keepBelow: true);
    final back = _cut(corners, bisector, keepBelow: false);
    frontPath = _outline(front);
    backPath = _outline(back);
    frontRoll = _outline(_cut(front, crease, keepBelow: false));
    backRoll = _outline(_cut(back, crease + math.pi * radius, keepBelow: true));
    final ridge = front
        .where((point) => (_project(point) - bisector).abs() < 0.00001)
        .map(_bend)
        .toList();
    if (ridge.length >= 2) {
      ridgePath
        ..moveTo(ridge.first.dx, ridge.first.dy)
        ..lineTo(ridge.last.dx, ridge.last.dy);
    }
  }

  Path frontPath = Path();
  Path backPath = Path();
  Path frontRoll = Path();
  Path backRoll = Path();
  final Path ridgePath = Path();
  Matrix4 reflection = Matrix4.identity();
  Offset normal = const Offset(1, 0);
  double crease = 0;
  double radius = 0;
  double strength = 0;

  bool get active => radius > 0 && !backPath.getBounds().isEmpty;

  double _project(Offset point) => point.dx * normal.dx + point.dy * normal.dy;

  Offset _bend(Offset point) {
    final distance = _project(point) - crease;
    if (distance <= 0) return point;
    final arc = math.pi * radius;
    final projected = distance < arc
        ? radius * math.sin(distance / radius)
        : arc - distance;
    return point + normal * (projected - distance);
  }

  List<Offset> _cut(
    List<Offset> polygon,
    double limit, {
    required bool keepBelow,
  }) {
    if (polygon.isEmpty) return [];
    final result = <Offset>[];
    var previous = polygon.last;
    var previousDistance = _project(previous) - limit;
    for (final point in polygon) {
      final distance = _project(point) - limit;
      final inside = keepBelow ? distance <= 0 : distance >= 0;
      final previousInside = keepBelow
          ? previousDistance <= 0
          : previousDistance >= 0;
      if (inside != previousInside) {
        result.add(
          previous +
              (point - previous) *
                  (previousDistance / (previousDistance - distance)),
        );
      }
      if (inside) result.add(point);
      previous = point;
      previousDistance = distance;
    }
    return result;
  }

  Path _outline(List<Offset> polygon) {
    if (polygon.length < 3) return Path();
    final first = _bend(polygon.first);
    final path = Path()..moveTo(first.dx, first.dy);
    for (var index = 0; index < polygon.length; index++) {
      final start = polygon[index];
      final end = polygon[(index + 1) % polygon.length];
      final startProjection = _project(start);
      final span = _project(end) - startProjection;
      // 在圆柱与平面的交界处分段，避免长边插值切掉卷边或制造折角。
      final stops = <double>[0, 1];
      if (span.abs() > 0.00001) {
        for (final limit in [crease, crease + math.pi * radius]) {
          final fraction = (limit - startProjection) / span;
          if (fraction > 0 && fraction < 1) stops.add(fraction);
        }
      }
      stops.sort();
      for (var segment = 1; segment < stops.length; segment++) {
        final from = stops[segment - 1];
        final to = stops[segment];
        final middle = startProjection + span * (from + to) / 2 - crease;
        final steps = middle > 0 && middle < math.pi * radius ? 16 : 1;
        for (var step = 1; step <= steps; step++) {
          final fraction = from + (to - from) * step / steps;
          final point = _bend(start + (end - start) * fraction);
          path.lineTo(point.dx, point.dy);
        }
      }
    }
    return path..close();
  }
}

class _CurlClipper extends CustomClipper<Path> {
  const _CurlClipper(this.path);

  final Path path;

  @override
  Path getClip(Size size) => path;

  @override
  bool shouldReclip(_CurlClipper oldClipper) => oldClipper.path != path;
}

class _CurlShadowPainter extends CustomPainter {
  const _CurlShadowPainter(this.geometry);

  final _CurlGeometry geometry;

  @override
  void paint(Canvas canvas, Size size) {
    if (!geometry.active) return;
    final radius = geometry.radius;
    canvas.drawPath(
      geometry.backPath.shift(geometry.normal * (radius * 0.28)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18 * geometry.strength)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.38),
    );
    canvas.drawPath(
      geometry.ridgePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * 0.32
        ..color = Colors.black.withValues(alpha: 0.12 * geometry.strength)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.2),
    );
  }

  @override
  bool shouldRepaint(_CurlShadowPainter oldDelegate) =>
      oldDelegate.geometry != geometry;
}

class _CurlSurfacePainter extends CustomPainter {
  const _CurlSurfacePainter(this.geometry, this.paperColor, this.backColor);

  final _CurlGeometry geometry;
  final Color paperColor;
  final Color backColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (!geometry.active) return;
    final dark = paperColor.computeLuminance() < 0.25;
    final start = geometry.normal * geometry.crease;
    final end = start + geometry.normal * geometry.radius;
    final strength = geometry.strength;
    final frontLight = Color.lerp(
      paperColor,
      Colors.white,
      (dark ? 0.025 : 0.1) * strength,
    )!;
    final edge = Color.lerp(backColor, Colors.black, 0.2 * strength)!;
    // 圆柱上的正文投影会急剧变窄，卷边用纸色与连续明暗覆盖，平面正文
    // 保持清晰。渐变沿真实法线绘制，不能使用外接矩形的对角线方向。
    canvas.drawPath(
      geometry.frontRoll,
      Paint()
        ..shader = ui.Gradient.linear(
          start,
          end,
          [paperColor, frontLight, edge],
          [0, 0.42, 1],
        ),
    );
    // 纸背在纸面正面上方，最后绘制，避免卷边光影穿透到纸背之外。
    canvas.save();
    canvas.clipPath(geometry.backPath);
    canvas.drawPath(
      geometry.backRoll,
      Paint()
        ..shader = ui.Gradient.linear(
          start,
          end,
          [
            backColor,
            Color.lerp(
              backColor,
              Colors.white,
              (dark ? 0.04 : 0.16) * strength,
            )!,
            edge,
          ],
          [0, 0.65, 1],
        ),
    );
    canvas.restore();
    canvas.drawPath(
      geometry.ridgePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = Colors.white.withValues(
          alpha: (dark ? 0.08 : 0.3) * strength,
        ),
    );
  }

  @override
  bool shouldRepaint(_CurlSurfacePainter oldDelegate) =>
      oldDelegate.geometry != geometry ||
      oldDelegate.paperColor != paperColor ||
      oldDelegate.backColor != backColor;
}

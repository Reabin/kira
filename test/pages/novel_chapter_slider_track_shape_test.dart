import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/pages/novel_reader/novel_chapter_slider_track_shape.dart';

const _active = Color(0xFF3366FF);
const _inactive = Color(0x3DFFFFFF);
const _sliderSize = Size(300, 40);

/// 默认拇指半径 10 / 光环半径 24，所以轨道两侧各留 24：24..276。
const _trackLeft = 24.0;
const _trackRight = 276.0;
const _trackMid = (_trackLeft + _trackRight) / 2;

SliderThemeData _theme({double trackHeight = 3}) => SliderThemeData(
  trackHeight: trackHeight,
  thumbColor: _active,
  disabledThumbColor: _active,
  activeTrackColor: _active,
  inactiveTrackColor: _inactive,
  disabledActiveTrackColor: _active,
  disabledInactiveTrackColor: _inactive,
  thumbShape: const RoundSliderThumbShape(),
  overlayShape: const RoundSliderOverlayShape(),
);

RenderBox _parentBox() {
  final box = RenderConstrainedBox(
    additionalConstraints: BoxConstraints.tight(_sliderSize),
  );
  box.layout(const BoxConstraints());
  return box;
}

/// 绘制一次并回收所有圆点（轨道本体画的是 RRect，不会混进来）。
List<({Offset center, double radius, Color color})> _paint(
  NovelChapterSliderTrackShape shape, {
  required TextDirection textDirection,
  Offset thumbCenter = const Offset(_trackLeft, 20),
  double trackHeight = 3,
}) {
  final canvas = TestRecordingCanvas();
  final context = TestRecordingPaintingContext(canvas);
  shape.paint(
    context,
    Offset.zero,
    parentBox: _parentBox(),
    sliderTheme: _theme(trackHeight: trackHeight),
    enableAnimation: const AlwaysStoppedAnimation<double>(1),
    textDirection: textDirection,
    thumbCenter: thumbCenter,
    isEnabled: true,
  );
  return [
    for (final invocation in canvas.invocations)
      if (invocation.invocation.memberName == #drawCircle)
        (
          center: invocation.invocation.positionalArguments[0] as Offset,
          radius: invocation.invocation.positionalArguments[1] as double,
          color: (invocation.invocation.positionalArguments[2] as Paint).color,
        ),
  ];
}

/// Paint 复制会经过浮点色值往返，按 1/255 容差比较与框架一致。
Matcher _isColor(Color expected) => predicate<Color>(
  (color) =>
      (color.a - expected.a).abs() < 1 / 255 &&
      (color.r - expected.r).abs() < 1 / 255 &&
      (color.g - expected.g).abs() < 1 / 255 &&
      (color.b - expected.b).abs() < 1 / 255,
  'color $expected',
);

void main() {
  test('markers sit at chapter offsets and split at the thumb', () {
    const shape = NovelChapterSliderTrackShape(
      chapterStarts: [0, 0.25, 0.5, 0.75, 1],
      activeColor: _active,
      inactiveColor: _inactive,
    );
    final circles = _paint(
      shape,
      textDirection: TextDirection.ltr,
      thumbCenter: const Offset(_trackMid, 20),
    );

    expect(circles, hasLength(5));
    for (final (index, start) in const [0.0, 0.25, 0.5, 0.75, 1.0].indexed) {
      final dot = circles[index];
      expect(dot.center, Offset(_trackLeft + start * 252, 20));
      // 与漫画底栏的 tickMarkRadius 一致。
      expect(dot.radius, 2.5);
      // 滑块之前（含压线）用 active，之后用 inactive。
      expect(
        dot.color,
        _isColor(start <= 0.5 ? _active : _inactive),
        reason: 'start $start',
      );
    }
  });

  test('markers mirror horizontally in right-to-left layouts', () {
    const shape = NovelChapterSliderTrackShape(
      chapterStarts: [0, 0.25, 1],
      activeColor: _active,
      inactiveColor: _inactive,
    );
    final circles = _paint(
      shape,
      textDirection: TextDirection.rtl,
      thumbCenter: const Offset(_trackMid, 20),
    );

    expect(
      circles.map((circle) => circle.center.dx),
      [_trackRight, _trackRight - 0.25 * 252, _trackLeft],
    );
    // RTL 下 thumb 右侧（坐标更大的一侧）是已读方向。
    expect(circles.first.color, _isColor(_active));
    expect(circles.last.color, _isColor(_inactive));
  });

  test('out-of-range starts are skipped instead of painted off-track', () {
    const shape = NovelChapterSliderTrackShape(
      chapterStarts: [-0.2, 0, 1, 1.4, double.nan, double.infinity],
      activeColor: _active,
      inactiveColor: _inactive,
    );
    final circles = _paint(shape, textDirection: TextDirection.ltr);

    expect(circles.map((circle) => circle.center.dx), [_trackLeft, _trackRight]);
  });

  test('a zero-height track paints neither markers nor track', () {
    const shape = NovelChapterSliderTrackShape(
      chapterStarts: [0, 0.5, 1],
      activeColor: _active,
      inactiveColor: _inactive,
    );
    expect(
      _paint(shape, textDirection: TextDirection.ltr, trackHeight: 0),
      isEmpty,
    );
  });
}

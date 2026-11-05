import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/pages/novel_reader/novel_focus_mask.dart';

import '../test_helpers.dart';

Widget _host({
  required bool enabled,
  double topRatio = 0.2,
  double bottomRatio = 0.55,
  bool reduceMotion = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(
      body: Stack(
        children: [
          NovelFocusMask(
            enabled: enabled,
            topRatio: topRatio,
            bottomRatio: bottomRatio,
            opacity: 0.5,
          ),
        ],
      ),
    ),
  ),
);

void main() {
  double heightOf(WidgetTester tester, String key) =>
      tester.getSize(find.byKey(ValueKey(key))).height;

  testWidgets('enabling slides the two panels out from the edges', (
    tester,
  ) async {
    await tester.pumpWidget(wrapWithApp(_host(enabled: false)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('novel-focus-mask')), findsNothing);

    await tester.pumpWidget(wrapWithApp(_host(enabled: true)));
    // 起点进度为 0：此时两块挡板高度都为 0，遮罩整体尚未出现。
    await tester.pump();
    expect(find.byKey(const ValueKey('novel-focus-mask')), findsNothing);
    await tester.pump(const Duration(milliseconds: 16));
    // 动画开头仍在边缘，挡板高度接近 0。
    final startTop = heightOf(tester, 'novel-focus-mask-top');
    final startBottom = heightOf(tester, 'novel-focus-mask-bottom');
    final screen =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(startTop, lessThan(screen * 0.2 * 0.5));
    expect(startBottom, lessThan(screen * 0.45 * 0.5));
    expect(startTop, greaterThanOrEqualTo(0));

    // 中间帧处于两端之间。
    await tester.pump(const Duration(milliseconds: 80));
    final midTop = heightOf(tester, 'novel-focus-mask-top');
    expect(midTop, greaterThan(startTop));

    await tester.pumpAndSettle();
    expect(heightOf(tester, 'novel-focus-mask-top'), closeTo(screen * 0.2, 1));
    expect(
      heightOf(tester, 'novel-focus-mask-bottom'),
      closeTo(screen * 0.45, 1),
    );
  });

  testWidgets('disabling retracts the panels and removes the mask', (
    tester,
  ) async {
    await tester.pumpWidget(wrapWithApp(_host(enabled: true)));
    await tester.pumpAndSettle();
    final screen =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final full = heightOf(tester, 'novel-focus-mask-top');
    expect(full, closeTo(screen * 0.2, 1));

    await tester.pumpWidget(wrapWithApp(_host(enabled: false)));
    await tester.pump(const Duration(milliseconds: 80));
    expect(heightOf(tester, 'novel-focus-mask-top'), lessThan(full));

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('novel-focus-mask')), findsNothing);
  });

  testWidgets('switching reduced motion mid-flight snaps to the final state', (
    tester,
  ) async {
    await tester.pumpWidget(wrapWithApp(_host(enabled: false)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(wrapWithApp(_host(enabled: true)));
    await tester.pump(const Duration(milliseconds: 80));
    final screen =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(heightOf(tester, 'novel-focus-mask-top'), lessThan(screen * 0.2));

    // 阅读途中打开系统的「减少动画」：立刻结束剩余过渡。
    await tester.pumpWidget(
      wrapWithApp(_host(enabled: true, reduceMotion: true)),
    );
    await tester.pump();
    expect(heightOf(tester, 'novel-focus-mask-top'), closeTo(screen * 0.2, 1));
    expect(
      heightOf(tester, 'novel-focus-mask-bottom'),
      closeTo(screen * 0.45, 1),
    );
  });

  testWidgets('reduced motion applies the final state immediately', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapWithApp(_host(enabled: false, reduceMotion: true)),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      wrapWithApp(_host(enabled: true, reduceMotion: true)),
    );
    await tester.pump();
    final screen =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(heightOf(tester, 'novel-focus-mask-top'), closeTo(screen * 0.2, 1));
    expect(
      heightOf(tester, 'novel-focus-mask-bottom'),
      closeTo(screen * 0.45, 1),
    );
  });
}

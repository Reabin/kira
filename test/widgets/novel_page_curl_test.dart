import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/novel_page_curl.dart';

import '../test_helpers.dart';

const _paper = Color(0xFFFDF6E3);
const _size = Size(320, 480);

/// 记录 build 次数：动画帧不应重建页面正文。
class _Counter extends StatelessWidget {
  const _Counter({required this.label, required this.counts});

  final String label;
  final Map<String, int> counts;

  @override
  Widget build(BuildContext context) {
    counts[label] = (counts[label] ?? 0) + 1;
    return RepaintBoundary(child: Center(child: Text(label)));
  }
}

Widget _curl({
  required Animation<double> animation,
  required bool forward,
  double originY = 0.75,
  Map<String, int>? counts,
}) {
  final tally = counts ?? <String, int>{};
  return wrapWithApp(
    SizedBox(
      width: _size.width,
      height: _size.height,
      child: NovelPageCurl(
        animation: animation,
        forward: forward,
        originY: originY,
        paperColor: _paper,
        turningPage: _Counter(label: 'front', counts: tally),
        turningPageBack: _Counter(label: 'back', counts: tally),
        underneath: _Counter(label: 'below', counts: tally),
      ),
    ),
  );
}

/// 卷曲裁剪路径按绘制顺序返回：[正面, 纸背]；空路径表示该层不可见。
List<Path> _clipPaths(WidgetTester tester) => tester
    .widgetList<ClipPath>(
      find.descendant(
        of: find.byType(NovelPageCurl),
        matching: find.byType(ClipPath),
      ),
    )
    .map((widget) => widget.clipper!.getClip(_size))
    .toList();

/// 底页是否参与绘制（被翻起的页之外露出的那一页）。
bool _underneathVisible(WidgetTester tester) => !tester
    .widgetList<ExcludeSemantics>(
      find.descendant(
        of: find.byType(NovelPageCurl),
        matching: find.byType(ExcludeSemantics),
      ),
    )
    .first
    .excluding;

/// 纸背的镜像变换行列式：负值表示文字真正镜像，而不是平移。
double _backDeterminant(WidgetTester tester) {
  final transform = tester
      .widgetList<Transform>(
        find.descendant(
          of: find.byType(NovelPageCurl),
          matching: find.byType(Transform),
        ),
      )
      .first
      .transform;
  return transform.entry(0, 0) * transform.entry(1, 1) -
      transform.entry(0, 1) * transform.entry(1, 0);
}

/// 纸张正面在给定高度上被卷走的右边界（像素）。
double _rightEdge(Path path, double y) {
  for (var x = _size.width - 1; x >= 0; x--) {
    if (path.contains(Offset(x + 0.5, y))) return x + 1;
  }
  return 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  testWidgets('forward curl starts on the current page and ends on the next', (
    tester,
  ) async {
    final controller = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 100),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(_curl(animation: controller, forward: true));
    // 起点：正面铺满视口，纸背被裁掉，底页不参与绘制。
    expect(_clipPaths(tester).first.getBounds(), Offset.zero & _size);
    expect(_clipPaths(tester).last.getBounds().isEmpty, isTrue);
    expect(_underneathVisible(tester), isFalse);

    controller.value = 1;
    await tester.pump();
    // 终点：正面已翻走，露出下一页，不留任何卷曲残影。
    expect(_clipPaths(tester).first.getBounds().isEmpty, isTrue);
    expect(_clipPaths(tester).last.getBounds().isEmpty, isTrue);
    expect(_underneathVisible(tester), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('backward curl unfolds the previous page over the current one', (
    tester,
  ) async {
    final controller = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 100),
    );
    addTearDown(controller.dispose);

    // forward=false：起点只有当前页，上一页尚未展开。
    await tester.pumpWidget(_curl(animation: controller, forward: false));
    expect(_clipPaths(tester).first.getBounds().isEmpty, isTrue);
    expect(_underneathVisible(tester), isTrue);

    controller.value = 1;
    await tester.pump();
    // 终点：上一页完全展开，盖住当前页。
    expect(_clipPaths(tester).first.getBounds(), Offset.zero & _size);
    expect(_clipPaths(tester).last.getBounds().isEmpty, isTrue);
    expect(_underneathVisible(tester), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mid-turn paints a curled sheet with a mirrored back', (
    tester,
  ) async {
    final controller = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 100),
    );
    addTearDown(controller.dispose);
    for (final originY in [0.1, 0.5, 0.9]) {
      for (final value in [0.15, 0.5, 0.85]) {
        controller.value = value;
        await tester.pumpWidget(
          _curl(animation: controller, forward: true, originY: originY),
        );
        await tester.pump();
        final paths = _clipPaths(tester);
        final front = paths.first;
        // 中间态：正面被卷走一角，纸背出现在折线另一侧，底页露出。
        expect(front.getBounds().isEmpty, isFalse);
        expect(paths.last.getBounds().isEmpty, isFalse);
        expect(_underneathVisible(tester), isTrue);
        // 折线斜穿纸张：靠下的落点先卷下角，靠上的落点先卷上角，
        // 落点在正中时折线竖直（两侧同时卷起）。
        final upper = _rightEdge(front, 4);
        final lower = _rightEdge(front, _size.height - 4);
        expect(
          upper < _size.width || lower < _size.width,
          isTrue,
          reason: '纸张右侧应被卷起',
        );
        if (originY < 0.5) {
          expect(upper, lessThan(lower), reason: '靠上的落点先卷上角');
        } else if (originY > 0.5) {
          expect(lower, lessThan(upper), reason: '靠下的落点先卷下角');
        } else {
          expect(upper, lower, reason: '落点在正中时折线竖直');
        }
        // 纸背是反射（负行列式），不是把正面平移过去。
        expect(_backDeterminant(tester), closeTo(-1, 1e-9));
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('reflection preserves paper dimensions instead of shrinking it', (
    tester,
  ) async {
    for (final origin in [0.1, 0.5, 0.9]) {
      await tester.pumpWidget(
        _curl(
          animation: const AlwaysStoppedAnimation(0.5),
          forward: true,
          originY: origin,
        ),
      );
      final matrix = tester
          .widgetList<Transform>(
            find.descendant(
              of: find.byType(NovelPageCurl),
              matching: find.byType(Transform),
            ),
          )
          .first
          .transform;
      final x = Offset(matrix.entry(0, 0), matrix.entry(1, 0));
      final y = Offset(matrix.entry(0, 1), matrix.entry(1, 1));
      expect(x.distance, closeTo(1, 1e-9));
      expect(y.distance, closeTo(1, 1e-9));
      expect(x.dx * y.dx + x.dy * y.dy, closeTo(0, 1e-9));
    }
  });

  testWidgets('upper and lower corners have symmetric curl outlines', (
    tester,
  ) async {
    await tester.pumpWidget(
      _curl(
        animation: const AlwaysStoppedAnimation(0.4),
        forward: true,
        originY: 0.1,
      ),
    );
    final upperPaths = _clipPaths(tester);
    await tester.pumpWidget(
      _curl(
        animation: const AlwaysStoppedAnimation(0.4),
        forward: true,
        originY: 0.9,
      ),
    );
    final lowerPaths = _clipPaths(tester);
    for (var index = 0; index < upperPaths.length; index++) {
      for (var y = 10.0; y < _size.height; y += 23) {
        for (var x = 10.0; x < _size.width; x += 19) {
          expect(
            upperPaths[index].contains(Offset(x, y)),
            lowerPaths[index].contains(Offset(x, _size.height - y)),
          );
        }
      }
    }
  });

  testWidgets('animation ticks repaint without rebuilding the pages', (
    tester,
  ) async {
    final counts = <String, int>{};
    final controller = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 300),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _curl(animation: controller, forward: true, counts: counts),
    );
    final baseline = Map<String, int>.from(counts);
    expect(baseline.keys, containsAll(['front', 'back', 'below']));
    for (final value in [0.2, 0.45, 0.7]) {
      controller.value = value;
      await tester.pump();
    }
    // 页面子树在帧之间保持稳定：正文不随卷曲宽度重新排版。
    expect(counts, baseline);
  });

  testWidgets('an unbounded viewport is rejected', (tester) async {
    final controller = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 100),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      wrapWithApp(
        SingleChildScrollView(
          child: NovelPageCurl(
            animation: controller,
            forward: true,
            originY: 0.5,
            paperColor: _paper,
            turningPage: const Text('front'),
            turningPageBack: const Text('back'),
            underneath: const Text('below'),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isAssertionError);
  });
}

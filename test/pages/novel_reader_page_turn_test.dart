import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/models/novel_reader_settings.dart';
import 'package:kira/pages/novel_reader/novel_reader_document.dart';
import 'package:kira/pages/novel_reader/novel_reader_page_view.dart';
import 'package:kira/theme/novel_reader_theme.dart';
import 'package:kira/widgets/novel_page_curl.dart';

import '../test_helpers.dart';

const _surfaceKey = ValueKey('novel-page-surface');
const _slideKey = ValueKey('novel-page-slide');
const _size = Size(360, 640);

class _Harness {
  final key = GlobalKey<NovelReaderPageViewState>();
  final document = NovelReaderDocument([
    NovelReaderEntry(
      entryIndex: 0,
      entry: const NovelContentEntry(name: 'chapter', contentType: 1),
      paragraphs: List.generate(300, (index) => 'paragraph $index'),
    ),
  ]);
  NovelReaderSettings settings = const NovelReaderSettings(
    mode: NovelReaderMode.paged,
  );
  NovelReaderAnchor target = const NovelReaderAnchor(entryIndex: 0);
  int jumpRevision = 0;
  int bookmarkRevision = 0;
  int turns = 0;
  int toolbarTaps = 0;
  bool toolbarVisible = false;
  int longPresses = 0;
  final boundaries = <bool>[];
  final positions = <NovelReaderLocation>[];
  Size size = _size;

  double get progress => key.currentState!.currentLocation!.progress;

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      wrapWithApp(
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: NovelReaderPageView(
              key: key,
              document: document,
              settings: settings,
              palette: NovelReaderPalette.resolve(settings, Brightness.light),
              target: target,
              jumpRevision: jumpRevision,
              bookmarkRevision: bookmarkRevision,
              emptyChapterText: 'empty',
              contentPadding: const EdgeInsets.all(24),
              onPosition: positions.add,
              toolbarVisible: toolbarVisible,
              onTap: () => toolbarTaps++,
              onPageTurned: () => turns++,
              onBoundary: boundaries.add,
              onParagraphLongPress: (_, _) => longPresses++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }
}

Future<TestGesture> _drag(
  WidgetTester tester,
  double distance, {
  int steps = 6,
}) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(_surfaceKey)),
  );
  // 先跨过识别阈值，后续距离才是已开始手势的净位移。
  await gesture.moveBy(Offset(distance.sign * 24, 0));
  await tester.pump();
  for (var index = 0; index < steps; index++) {
    await gesture.moveBy(Offset(distance / steps, 0));
    await tester.pump(const Duration(milliseconds: 50));
  }
  return gesture;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  for (final realistic in [true, false]) {
    for (final instant in [true, false]) {
      testWidgets('animation priority realistic=$realistic instant=$instant', (
        tester,
      ) async {
        final harness = _Harness()
          ..settings = NovelReaderSettings(
            mode: NovelReaderMode.paged,
            realisticPageTurn: realistic,
            instantPageTurn: instant,
          );
        await harness.mount(tester);
        final start = harness.progress;
        harness.key.currentState!.nextPage();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(
          find.byType(NovelPageCurl),
          !instant && realistic ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(_slideKey),
          !instant && !realistic ? findsOneWidget : findsNothing,
        );
        if (!instant) expect(harness.progress, start);
        await _settle(tester);
        expect(harness.progress, greaterThan(start));
        expect(harness.turns, 1);
        harness.key.currentState!.prevPage();
        await _settle(tester);
        expect(harness.progress, start);
        expect(harness.turns, 2);
      });

      testWidgets(
        'toolbar visibility gates taps realistic=$realistic instant=$instant',
        (tester) async {
          final harness = _Harness()
            ..toolbarVisible = true
            ..settings = NovelReaderSettings(
              mode: NovelReaderMode.paged,
              realisticPageTurn: realistic,
              instantPageTurn: instant,
            );
          await harness.mount(tester);
          final start = harness.progress;
          final rect = tester.getRect(find.byKey(_surfaceKey));
          for (final fraction in [1 / 6, 5 / 6, 1 / 2]) {
            await tester.tapAt(
              Offset(rect.left + rect.width * fraction, rect.center.dy),
            );
            await _settle(tester);
            expect(harness.progress, start);
            expect(harness.turns, 0);
            expect(harness.boundaries, isEmpty);
          }
          expect(harness.toolbarTaps, 3);

          harness.toolbarVisible = false;
          await harness.mount(tester);
          await tester.tapAt(Offset(rect.right - 20, rect.center.dy));
          await _settle(tester);
          expect(harness.progress, greaterThan(start));
          await tester.tapAt(Offset(rect.left + 20, rect.center.dy));
          await _settle(tester);
          expect(harness.progress, start);
          expect(harness.turns, 2);
          expect(harness.toolbarTaps, 3);
        },
      );

      testWidgets(
        'visible toolbar allows direct and drag turns realistic=$realistic instant=$instant',
        (tester) async {
          final harness = _Harness()
            ..toolbarVisible = true
            ..settings = NovelReaderSettings(
              mode: NovelReaderMode.paged,
              realisticPageTurn: realistic,
              instantPageTurn: instant,
            );
          await harness.mount(tester);
          final start = harness.progress;
          harness.key.currentState!.nextPage();
          await _settle(tester);
          expect(harness.progress, greaterThan(start));
          expect(harness.turns, 1);

          final gesture = await _drag(tester, 200);
          await gesture.up();
          await _settle(tester);
          expect(harness.progress, start);
          expect(harness.turns, 2);
          expect(harness.toolbarTaps, 0);
        },
      );
    }

    testWidgets('instant long drag turns only once realistic=$realistic', (
      tester,
    ) async {
      final harness = _Harness()
        ..settings = NovelReaderSettings(
          mode: NovelReaderMode.paged,
          realisticPageTurn: realistic,
          instantPageTurn: true,
        );
      await harness.mount(tester);
      final gesture = await _drag(tester, -300);
      expect(harness.turns, 1);
      expect(find.byType(NovelPageCurl), findsNothing);
      expect(find.byKey(_slideKey), findsNothing);
      await gesture.up();
      await _settle(tester);
      expect(harness.turns, 1);
      final second = await _drag(tester, -300);
      await second.up();
      await _settle(tester);
      expect(harness.turns, 2);
    });

    testWidgets('drag can cross directions realistic=$realistic', (
      tester,
    ) async {
      final harness = _Harness()
        ..settings = NovelReaderSettings(
          mode: NovelReaderMode.paged,
          realisticPageTurn: realistic,
        );
      await harness.mount(tester);
      harness.key.currentState!.nextPage();
      await _settle(tester);
      final start = harness.progress;
      final gesture = await _drag(tester, -120);
      await gesture.moveBy(const Offset(280, 0));
      await tester.pump(const Duration(milliseconds: 200));
      if (realistic) {
        expect(
          tester.widget<NovelPageCurl>(find.byType(NovelPageCurl)).forward,
          isFalse,
        );
      } else {
        final translation = tester.widget<FractionalTranslation>(
          find
              .descendant(
                of: find.byKey(_slideKey),
                matching: find.byType(FractionalTranslation),
              )
              .first,
        );
        expect(translation.translation.dx, greaterThan(0));
      }
      await gesture.up();
      await _settle(tester);
      expect(harness.progress, lessThan(start));
      expect(harness.turns, 2);
    });

    testWidgets('returning a drag to origin cancels realistic=$realistic', (
      tester,
    ) async {
      final harness = _Harness()
        ..settings = NovelReaderSettings(
          mode: NovelReaderMode.paged,
          realisticPageTurn: realistic,
        );
      await harness.mount(tester);
      final start = harness.progress;
      final gesture = await _drag(tester, -120);
      await gesture.moveBy(const Offset(120, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await _settle(tester);
      expect(harness.progress, start);
      expect(harness.turns, 0);
      expect(harness.boundaries, isEmpty);
    });

    testWidgets(
      'rebound plus next request only advances once realistic=$realistic',
      (tester) async {
        final harness = _Harness()
          ..settings = NovelReaderSettings(
            mode: NovelReaderMode.paged,
            realisticPageTurn: realistic,
          );
        await harness.mount(tester);
        final gesture = await _drag(tester, -70);
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
        await tester.pump();
        harness.key.currentState!.nextPage();
        await _settle(tester);
        expect(harness.turns, 1);
      },
    );

    testWidgets('quick next requests do not lose pages realistic=$realistic', (
      tester,
    ) async {
      final harness = _Harness()
        ..settings = NovelReaderSettings(
          mode: NovelReaderMode.paged,
          realisticPageTurn: realistic,
        );
      await harness.mount(tester);
      for (var index = 0; index < 3; index++) {
        harness.key.currentState!.nextPage();
        await tester.pump(const Duration(milliseconds: 30));
      }
      await _settle(tester);
      expect(harness.turns, 3);
    });

    testWidgets(
      'center tap does not cancel existing turn realistic=$realistic',
      (tester) async {
        final harness = _Harness()
          ..settings = NovelReaderSettings(
            mode: NovelReaderMode.paged,
            realisticPageTurn: realistic,
          );
        await harness.mount(tester);
        harness.key.currentState!.nextPage();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(tester.getCenter(find.byKey(_surfaceKey)));
        await _settle(tester);
        expect(harness.toolbarTaps, 1);
        expect(harness.turns, 1);
      },
    );

    testWidgets('opposite fling does not commit realistic=$realistic', (
      tester,
    ) async {
      final harness = _Harness()
        ..settings = NovelReaderSettings(
          mode: NovelReaderMode.paged,
          realisticPageTurn: realistic,
        );
      await harness.mount(tester);
      final start = harness.progress;
      final surface = tester.widget<GestureDetector>(find.byKey(_surfaceKey));
      surface.onHorizontalDragStart!(
        DragStartDetails(globalPosition: const Offset(180, 300)),
      );
      surface.onHorizontalDragUpdate!(
        DragUpdateDetails(
          delta: const Offset(-70, 0),
          globalPosition: const Offset(110, 300),
        ),
      );
      await tester.pump();
      surface.onHorizontalDragEnd!(
        DragEndDetails(
          velocity: const Velocity(pixelsPerSecond: Offset(1000, 0)),
        ),
      );
      await _settle(tester);
      expect(harness.progress, start);
      expect(harness.turns, 0);
    });

    testWidgets(
      'blocked second drag cancel preserves turn realistic=$realistic',
      (tester) async {
        final harness = _Harness()
          ..settings = NovelReaderSettings(
            mode: NovelReaderMode.paged,
            realisticPageTurn: realistic,
          );
        await harness.mount(tester);
        harness.key.currentState!.nextPage();
        await tester.pump();
        final gesture = await _drag(tester, -40, steps: 1);
        await gesture.cancel();
        await _settle(tester);
        expect(harness.turns, 1);
      },
    );

    testWidgets('near-complete release settles quickly realistic=$realistic', (
      tester,
    ) async {
      final harness = _Harness()
        ..settings = NovelReaderSettings(
          mode: NovelReaderMode.paged,
          realisticPageTurn: realistic,
        );
      await harness.mount(tester);
      final gesture = await _drag(tester, -324);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(harness.turns, 1, reason: '只剩 10% 不应再播放完整 360ms');
      await _settle(tester);
    });
  }

  testWidgets('pulling back from the volume boundary does not leave it', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    final gesture = await _drag(tester, 120);
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await _settle(tester);
    expect(harness.boundaries, isEmpty);
    expect(harness.turns, 0);
  });

  testWidgets('instant boundary is called only once per drag', (tester) async {
    final harness = _Harness()
      ..settings = const NovelReaderSettings(
        mode: NovelReaderMode.paged,
        instantPageTurn: true,
      );
    await harness.mount(tester);
    final gesture = await _drag(tester, 300);
    await gesture.up();
    await _settle(tester);
    expect(harness.boundaries, [false]);
  });

  testWidgets('page jump cancels a turn and ignores the remaining gesture', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    final gesture = await _drag(tester, -160);
    harness.target = const NovelReaderAnchor(
      entryIndex: 0,
      paragraphIndex: 150,
    );
    harness.jumpRevision++;
    await harness.mount(tester);
    final restored = harness.progress;
    await gesture.moveBy(const Offset(-80, 0));
    await gesture.up();
    await _settle(tester);
    expect(harness.progress, restored);
    expect(harness.turns, 0);
    harness.key.currentState!.nextPage();
    await _settle(tester);
    expect(harness.turns, 1);
  });

  testWidgets('switching animation cancels unconfirmed drag without moving', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    final start = harness.progress;
    final gesture = await _drag(tester, -160);
    harness.settings = harness.settings.copyWith(realisticPageTurn: false);
    await harness.mount(tester);
    await gesture.moveBy(const Offset(-80, 0));
    await gesture.up();
    await _settle(tester);
    expect(harness.progress, start);
    expect(harness.turns, 0);
    harness.key.currentState!.nextPage();
    await tester.pump();
    expect(find.byKey(_slideKey), findsOneWidget);
    await _settle(tester);
    expect(harness.turns, 1);
  });

  testWidgets('enabling instant settles the confirmed turn exactly once', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    harness.key.currentState!.nextPage();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    harness.settings = harness.settings.copyWith(instantPageTurn: true);
    await harness.mount(tester);
    await _settle(tester);
    expect(harness.turns, 1);
    expect(find.byType(NovelPageCurl), findsNothing);
    expect(find.byKey(_slideKey), findsNothing);
  });

  testWidgets('curl includes page margins, not just the text column', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    harness.key.currentState!.nextPage();
    await tester.pump();
    expect(
      tester.getSize(find.byType(NovelPageCurl)),
      tester.getSize(find.byType(NovelReaderPageView)),
    );
    await _settle(tester);
  });
}

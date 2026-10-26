import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/models/novel_reader_settings.dart';
import 'package:kira/pages/novel_reader/novel_reader_document.dart';
import 'package:kira/pages/novel_reader/novel_reader_page_view.dart';
import 'package:kira/pages/novel_reader/novel_reader_paginator.dart';
import 'package:kira/pages/novel_reader/novel_reader_viewport.dart';
import 'package:kira/theme/novel_reader_theme.dart';

import '../test_helpers.dart';

const _safePadding = EdgeInsets.fromLTRB(32, 24, 28, 20);

class _Harness {
  _Harness(this.mode);

  final NovelReaderMode mode;
  final scrollKey = GlobalKey<NovelReaderViewportState>();
  final pagedKey = GlobalKey<NovelReaderPageViewState>();
  final positions = <NovelReaderLocation>[];
  final document = NovelReaderDocument([
    NovelReaderEntry(
      entryIndex: 0,
      entry: const NovelContentEntry(name: '', contentType: 1),
      paragraphs: List.generate(
        100,
        (index) => '$index ${'这是用于验证正文宽度与阅读位置的测试内容。' * 12}',
      ),
    ),
  ]);
  static const target = NovelReaderAnchor(entryIndex: 0, paragraphIndex: 60);

  NovelReaderLocation get location => mode == NovelReaderMode.scroll
      ? scrollKey.currentState!.currentLocation!
      : pagedKey.currentState!.currentLocation!;

  Future<void> mount(WidgetTester tester, double width) async {
    final settings = NovelReaderSettings(mode: mode, contentWidth: width);
    final palette = NovelReaderPalette.resolve(settings, Brightness.light);
    await tester.pumpWidget(
      wrapWithApp(
        mode == NovelReaderMode.scroll
            ? NovelReaderViewport(
                key: scrollKey,
                document: document,
                settings: settings,
                palette: palette,
                target: target,
                jumpRevision: 0,
                contentPadding: _safePadding,
                onPosition: positions.add,
                onTap: () {},
              )
            : NovelReaderPageView(
                key: pagedKey,
                document: document,
                settings: settings,
                palette: palette,
                target: target,
                jumpRevision: 0,
                toolbarVisible: false,
                contentPadding: _safePadding,
                emptyChapterText: '空章节',
                onPosition: positions.add,
                onTap: () {},
                onBoundary: (_) {},
              ),
      ),
    );
    // 收窄正文的第一帧也不能用旧分页内容渲染出溢出。
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Finder paragraph(int index) {
    if (mode == NovelReaderMode.scroll) {
      return find.byKey(ValueKey('novel-paragraph-0-$index'));
    }
    return find.byWidgetPredicate((widget) {
      if (widget is! Padding) return false;
      return switch (widget.key) {
        ValueKey<String>(:final value) => value.startsWith(
          'novel-page-0-$index-',
        ),
        _ => false,
      };
    }).first;
  }
}

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  test('width metrics preserve safe insets, minimum gutters and default', () {
    const wide = Size(1400, 900);
    expect(novelPageMetricsFor(wide, _safePadding), (
      width: 720.0,
      horizontalPadding: 310.0,
    ));
    for (final width in [320.0, 720.0, 960.0, 1200.0]) {
      final metrics = novelPageMetricsFor(
        wide,
        _safePadding,
        maxContentWidth: width,
      );
      expect(metrics.width, width);
      expect(metrics.horizontalPadding, (1340 - width) / 2);
      expect(
        novelPageMetricsFor(
          const Size(420, 900),
          _safePadding,
          maxContentWidth: width,
        ),
        (width: 312.0, horizontalPadding: 24.0),
      );
    }
    expect(novelPageMetricsFor(const Size(40, 900), _safePadding).width, 0);
  });

  for (final mode in NovelReaderMode.values) {
    testWidgets('${mode.name} width changes retain the current paragraph', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);
      final harness = _Harness(mode);
      await harness.mount(tester, 720);
      expect(harness.location.anchor.paragraphIndex, greaterThan(0));
      final initialRect = tester.getRect(
        harness.paragraph(harness.location.anchor.paragraphIndex),
      );
      expect(initialRect.width, closeTo(720, 0.01));
      for (final width in [960.0, 320.0, 1200.0, 720.0]) {
        final before = harness.location.anchor;
        harness.positions.clear();
        await harness.mount(tester, width);
        final rect = tester.getRect(harness.paragraph(before.paragraphIndex));
        expect(rect.width, closeTo(width, 0.01));
        expect(rect.left, closeTo(32 + (1340 - width) / 2, 0.01));
        expect(rect.bottom, greaterThan(0));
        expect(rect.top, lessThan(900));
        if (mode == NovelReaderMode.scroll) {
          expect(harness.location.anchor.paragraphIndex, before.paragraphIndex);
          expect(
            harness.location.anchor.alignment,
            closeTo(before.alignment, 0.01),
          );
        }
        expect(harness.positions, isNotEmpty);
        expect(
          harness.positions.every(
            (position) => position.anchor.paragraphIndex > 0,
          ),
          isTrue,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets(
      '${mode.name} keeps narrow-screen gutters when width is larger',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(420, 900);
        addTearDown(tester.view.reset);
        final harness = _Harness(mode);
        await harness.mount(tester, 1200);
        final rect = tester.getRect(
          harness.paragraph(harness.location.anchor.paragraphIndex),
        );
        expect(rect.left, closeTo(56, 0.01));
        expect(rect.right, closeTo(368, 0.01));
        expect(rect.width, closeTo(312, 0.01));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}

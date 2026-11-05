import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/pages/chapter_comments/comment_toolbar.dart';

import '../../test_helpers.dart';

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  Future<void> pumpToolbar(
    WidgetTester tester, {
    double width = 360,
    double textScale = 1,
    bool dark = false,
    bool hasNextChapter = true,
    VoidCallback? onComment,
    VoidCallback? onCatalog,
    VoidCallback? onNextChapter,
    VoidCallback? onScrollToTop,
    VoidCallback? onClose,
  }) => tester.pumpWidget(
    wrapWithApp(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Theme(
            data: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
            child: Align(
              alignment: Alignment.bottomRight,
              child: SizedBox(
                width: width,
                child: ChapterCommentToolbar(
                  onComment: onComment ?? () {},
                  onCatalog: onCatalog ?? () {},
                  onScrollToTop: onScrollToTop ?? () {},
                  onClose: onClose ?? () {},
                  hasNextChapter: hasNextChapter,
                  onNextChapter: onNextChapter ?? () {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Finder action(String name) => find.byKey(ValueKey('chapter_${name}_action'));

  for (final scale in [1.0, 1.35, 2.0, 3.0]) {
    testWidgets('章节评论在 ${scale}x 字号下保留同行与右侧上下按钮', (tester) async {
      await pumpToolbar(tester, width: 288, textScale: scale);
      expect(tester.takeException(), isNull);
      expect(find.byType(IconButton), findsNothing);
      expect(
        find.byWidgetPredicate((widget) => widget is FilledButton),
        findsNWidgets(5),
      );
      final comment = tester.getRect(action('comment'));
      final catalog = tester.getRect(action('catalog'));
      final next = tester.getRect(action('next'));
      final top = tester.getRect(action('scroll_top'));
      final close = tester.getRect(action('close'));
      expect(comment.right + 8, closeTo(catalog.left, 0.01));
      expect(catalog.right + 8, closeTo(next.left, 0.01));
      expect(next.right + 8, closeTo(close.left, 0.01));
      for (final rect in [comment, catalog, next]) {
        expect(rect.bottom, closeTo(close.bottom, 0.01));
        expect(rect.height, 52);
      }
      expect(top.size, const Size.square(52));
      expect(close.size, const Size.square(52));
      expect(top.left, closeTo(close.left, 0.01));
      expect(top.bottom + 8, closeTo(close.top, 0.01));
    });
  }

  testWidgets('章节评论按钮没有共用的不透明底板', (tester) async {
    await pumpToolbar(tester);
    final materials = find.descendant(
      of: find.byType(ChapterCommentToolbar),
      matching: find.byType(Material),
    );
    for (final name in ['comment', 'catalog', 'next', 'scroll_top', 'close']) {
      expect(
        find.ancestor(of: action(name), matching: materials),
        findsNothing,
      );
    }
  });

  for (final dark in [false, true]) {
    testWidgets('保留评论主色和辅助按钮次色、原悬浮阴影（dark=$dark）', (tester) async {
      await pumpToolbar(tester, dark: dark);
      final cs = Theme.of(tester.element(action('comment'))).colorScheme;
      final primary = tester.widget<FilledButton>(action('comment')).style!;
      expect(primary.backgroundColor!.resolve({}), cs.primary);
      expect(primary.foregroundColor!.resolve({}), cs.onPrimary);
      for (final name in ['catalog', 'next', 'scroll_top', 'close']) {
        final secondary = tester.widget<FilledButton>(action(name)).style!;
        expect(secondary.backgroundColor!.resolve({}), cs.secondaryContainer);
        expect(secondary.foregroundColor!.resolve({}), cs.onSecondaryContainer);
        expect(secondary.elevation!.resolve({}), 6);
      }
      expect(primary.elevation!.resolve({}), 6);
    });
  }

  testWidgets('所有操作保留原入口与独立回调', (tester) async {
    final calls = <String>[];
    await pumpToolbar(
      tester,
      onComment: () => calls.add('comment'),
      onCatalog: () => calls.add('catalog'),
      onNextChapter: () => calls.add('next'),
      onScrollToTop: () => calls.add('top'),
      onClose: () => calls.add('close'),
    );
    for (final name in ['comment', 'catalog', 'next', 'scroll_top', 'close']) {
      await tester.tap(action(name));
    }
    expect(calls, ['comment', 'catalog', 'next', 'top', 'close']);
    expect(find.text('目录'), findsOneWidget);
    expect(find.byTooltip('回到顶部'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
  });

  testWidgets('没有下一话时只移除下一话入口', (tester) async {
    await pumpToolbar(tester, hasNextChapter: false);
    expect(action('next'), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    expect(
      find.byWidgetPredicate((widget) => widget is FilledButton),
      findsNWidgets(4),
    );
    expect(find.text('目录'), findsOneWidget);
  });
}

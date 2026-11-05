import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/pages/comic_detail/reading_actions.dart';

import '../../test_helpers.dart';

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  Future<void> pumpActions(
    WidgetTester tester, {
    double width = 288,
    double textScale = 1,
    VoidCallback? onContinue,
    VoidCallback? onNext,
    VoidCallback? onDownloads,
  }) => tester.pumpWidget(
    wrapWithApp(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Align(
            alignment: Alignment.bottomRight,
            child: SizedBox(
              width: width,
              child: ComicDetailReadingActions(
                continueLabel: '第123话 很长的章节名 · 20/30',
                onContinue: onContinue ?? () {},
                nextLabel: '第124话 下一章节名称',
                onNext: onNext ?? () {},
                onDownloads: onDownloads ?? () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );

  for (final scale in [1.0, 1.35, 2.0, 3.0]) {
    testWidgets('详情 FAB 在 ${scale}x 字号下保留同行顺序且不溢出', (tester) async {
      await pumpActions(tester, textScale: scale);
      expect(tester.takeException(), isNull);
      final continuing = tester.getRect(
        find.byKey(const ValueKey('comic_continue_action')),
      );
      final next = tester.getRect(
        find.byKey(const ValueKey('comic_next_action')),
      );
      final downloads = tester.getRect(
        find.byKey(const ValueKey('comic_downloads_action')),
      );
      expect(next.top, closeTo(continuing.top, 0.01));
      expect(next.bottom, closeTo(continuing.bottom, 0.01));
      expect(next.right, lessThan(continuing.left));
      expect(downloads.bottom, lessThan(next.top));
      expect(downloads.right, closeTo(continuing.right, 0.01));
    });
  }

  testWidgets('悬浮 FAB 没有共用的不透明底板', (tester) async {
    await pumpActions(tester);
    final subject = find.byType(ComicDetailReadingActions);
    final materials = find.descendant(
      of: subject,
      matching: find.byType(Material),
    );
    for (final action in ['continue', 'next', 'downloads']) {
      expect(
        find.ancestor(
          of: find.byKey(ValueKey('comic_${action}_action')),
          matching: materials,
        ),
        findsNothing,
      );
    }
  });

  testWidgets('下一话出现时使用主色，继续阅读和下载使用次色', (tester) async {
    await pumpActions(tester);
    final cs = Theme.of(
      tester.element(find.byType(ComicDetailReadingActions)),
    ).colorScheme;
    final next = tester.widget<FloatingActionButton>(
      find.byKey(const ValueKey('comic_next_action')),
    );
    final continuing = tester.widget<FloatingActionButton>(
      find.byKey(const ValueKey('comic_continue_action')),
    );
    final downloads = tester.widget<FloatingActionButton>(
      find.byKey(const ValueKey('comic_downloads_action')),
    );
    expect(next.backgroundColor, cs.primaryContainer);
    expect(next.foregroundColor, cs.onPrimaryContainer);
    for (final secondary in [continuing, downloads]) {
      expect(secondary.backgroundColor, cs.secondaryContainer);
      expect(secondary.foregroundColor, cs.onSecondaryContainer);
    }
  });

  testWidgets('没有下一话时继续阅读使用主色', (tester) async {
    await tester.pumpWidget(
      wrapWithApp(
        ComicDetailReadingActions(continueLabel: '继续阅读', onContinue: () {}),
      ),
    );
    final cs = Theme.of(
      tester.element(find.byType(ComicDetailReadingActions)),
    ).colorScheme;
    final continuing = tester.widget<FloatingActionButton>(
      find.byKey(const ValueKey('comic_continue_action')),
    );
    expect(continuing.backgroundColor, cs.primaryContainer);
    expect(continuing.foregroundColor, cs.onPrimaryContainer);
  });

  testWidgets('继续阅读、下一话、下载中心保留各自回调', (tester) async {
    final calls = <String>[];
    await pumpActions(
      tester,
      onContinue: () => calls.add('continue'),
      onNext: () => calls.add('next'),
      onDownloads: () => calls.add('downloads'),
    );
    for (final action in ['continue', 'next', 'downloads']) {
      await tester.tap(find.byKey(ValueKey('comic_${action}_action')));
    }
    expect(calls, ['continue', 'next', 'downloads']);
    expect(find.byTooltip('下载中心'), findsOneWidget);
  });

  testWidgets('只提供下载中心时不显示阅读按钮', (tester) async {
    await tester.pumpWidget(
      wrapWithApp(
        ComicDetailReadingActions(
          continueLabel: '',
          onContinue: null,
          onDownloads: () {},
        ),
      ),
    );
    expect(find.byKey(const ValueKey('comic_continue_action')), findsNothing);
    expect(find.byKey(const ValueKey('comic_next_action')), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });
}

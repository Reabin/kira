import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/pages/reader/reader_book_pager.dart';
import 'package:kira/widgets/novel_page_curl.dart';

import '../../test_helpers.dart';

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  Widget sheet(int index) => Row(
    children: [
      Expanded(
        child: ColoredBox(color: index == 0 ? Colors.red : Colors.green),
      ),
      Expanded(
        child: ColoredBox(color: index == 0 ? Colors.blue : Colors.orange),
      ),
    ],
  );

  for (final doublePage in [false, true]) {
    for (final reverse in [false, true]) {
      testWidgets(
        'book turn follows controller and finishes ($doublePage, $reverse)',
        (tester) async {
          final controller = PageController();
          addTearDown(controller.dispose);
          var selected = 0;
          await tester.pumpWidget(
            wrapWithApp(
              SizedBox(
                width: 800,
                height: 600,
                child: ReaderBookPager(
                  controller: controller,
                  itemCount: 3,
                  pageBuilder: (_, index) => sheet(index),
                  doublePage: doublePage,
                  reverse: reverse,
                  axis: Axis.horizontal,
                  enabled: true,
                  child: PageView.builder(
                    controller: controller,
                    reverse: reverse,
                    itemCount: 3,
                    onPageChanged: (index) => selected = index,
                    itemBuilder: (_, index) => sheet(index),
                  ),
                ),
              ),
            ),
          );
          final width = controller.position.viewportDimension;
          for (final fraction in [0.2, 0.4, 0.6, 0.8]) {
            controller.jumpTo(width * fraction);
            await tester.pump();
            expect(find.byType(ReaderBookTransition), findsOneWidget);
            expect(
              find.byType(NovelPageCurl),
              doublePage ? findsNothing : findsOneWidget,
            );
            expect(tester.takeException(), isNull);
          }
          controller.jumpToPage(1);
          await tester.pumpAndSettle();
          expect(selected, 1);
          expect(find.byType(ReaderBookTransition), findsNothing);
          controller.jumpTo(width * 0.7);
          await tester.pump();
          expect(find.byType(ReaderBookTransition), findsOneWidget);
          // Cancel a backwards drag without losing the settled page.
          controller.jumpToPage(1);
          await tester.pumpAndSettle();
          expect(selected, 1);
          expect(tester.takeException(), isNull);
          final gesture = await tester.startGesture(
            tester.getCenter(find.byType(PageView)),
          );
          await gesture.moveBy(Offset(reverse ? width * 0.3 : -width * 0.3, 0));
          await tester.pump();
          expect(find.byType(ReaderBookTransition), findsOneWidget);
          await gesture.cancel();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'disabled animation keeps normal page rendering during movement',
    (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        wrapWithApp(
          ReaderBookPager(
            controller: controller,
            itemCount: 2,
            pageBuilder: (_, index) => sheet(index),
            doublePage: true,
            reverse: false,
            axis: Axis.horizontal,
            enabled: false,
            child: PageView(
              controller: controller,
              children: [sheet(0), sheet(1)],
            ),
          ),
        ),
      );
      controller.jumpTo(controller.position.viewportDimension * 0.3);
      await tester.pump();
      expect(find.byType(ReaderBookTransition), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

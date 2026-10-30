import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/routing/detail_page.dart';

import '../test_helpers.dart';

void main() {
  for (final complete in [false, true]) {
    testWidgets('iOS edge swipe ${complete ? 'pops' : 'cancels'} detail', (
      tester,
    ) async {
      var showDetail = true;
      var popCount = 0;
      await tester.pumpWidget(
        wrapWithApp(
          Theme(
            data: ThemeData(platform: TargetPlatform.iOS),
            child: StatefulBuilder(
              builder: (context, setState) => Navigator(
                pages: [
                  const MaterialPage<void>(
                    key: ValueKey('home'),
                    child: Scaffold(body: Text('home')),
                  ),
                  if (showDetail)
                    buildDetailPage(
                      context: context,
                      key: const ValueKey('detail'),
                      child: const Scaffold(body: Text('detail')),
                      transitionDuration: const Duration(milliseconds: 300),
                      reverseTransitionDuration: const Duration(
                        milliseconds: 300,
                      ),
                    ),
                ],
                onDidRemovePage: (page) {
                  popCount++;
                  setState(() => showDetail = false);
                },
              ),
            ),
          ),
          wrapInScaffold: false,
        ),
      );
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(const Offset(5, 250));
      await gesture.moveBy(Offset(complete ? 500 : 70, 0));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(popCount, complete ? 1 : 0);
      expect(find.text('detail'), complete ? findsNothing : findsOneWidget);
    });
  }
}

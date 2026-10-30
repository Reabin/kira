import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/layout_reflow.dart';
import '../test_helpers.dart';

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);
  for (final reduced in [false, true]) {
    testWidgets(
      'window reflow moves from painted position without a first-frame jump ($reduced)',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(400, 800);
          addTearDown(tester.view.reset);
          var taps = 0;
          final item = find.byKey(const ValueKey('moving-child'));
          await tester.pumpWidget(
            wrapWithApp(
              Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: reduced),
                  child: LayoutReflowScope(
                    child: Stack(
                      children: [
                        Positioned(
                          right: 0,
                          top: 0,
                          width: 80,
                          height: 80,
                          child: ReflowMotion(
                            id: 'test-card',
                            child: GestureDetector(
                              onTap: () => taps++,
                              child: const ColoredBox(
                                key: ValueKey('moving-child'),
                                color: Colors.blue,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(tester.getTopLeft(item).dx, 320);
          tester.view.physicalSize = const Size(800, 400);
          await tester.pump();
          expect(tester.getTopLeft(item).dx, reduced ? 720 : 320);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 170));
          final middle = tester.getTopLeft(item).dx;
          if (!reduced) {
            expect(middle, greaterThan(320));
            expect(middle, lessThan(720));
          }
          await tester.tapAt(tester.getCenter(item));
          expect(taps, 1);
          await tester.pumpAndSettle();
          expect(tester.getTopLeft(item).dx, 720);
          await tester.tap(item);
          expect(taps, 2);
          expect(tester.takeException(), isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}

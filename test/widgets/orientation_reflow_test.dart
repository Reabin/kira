import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/orientation_reflow.dart';

import '../test_helpers.dart';

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  for (final capture in [false, true]) {
    for (final reduced in [false, true]) {
      testWidgets(
        'iPad orientation preserves route state and respects reduced motion ($reduced, snapshot=$capture)',
        (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          try {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = const Size(834, 1210);
            addTearDown(tester.view.reset);
            var count = 0;
            await tester.pumpWidget(
              wrapWithApp(
                Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(disableAnimations: reduced),
                    child: OrientationReflow(
                      captureSnapshot: () => capture,
                      child: StatefulBuilder(
                        builder: (context, update) => TextButton(
                          onPressed: () => update(() => count++),
                          child: Text('count:$count'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('count:0'));
            await tester.pumpAndSettle();
            tester.view.physicalSize = const Size(1210, 834);
            await tester.pump();
            final snapshot = find.byKey(const ValueKey('orientation-snapshot'));
            expect(
              snapshot,
              reduced || !capture ? findsNothing : findsOneWidget,
            );
            if (!reduced && capture) {
              final image = tester.widget<RawImage>(find.byType(RawImage));
              expect(image.image!.width, 834);
              expect(image.image!.height, 1210);
            }
            expect(find.text('count:1'), findsOneWidget);
            if (!reduced) {
              tester.view.physicalSize = const Size(834, 1210);
              await tester.pump(const Duration(milliseconds: 80));
              tester.view.physicalSize = const Size(1210, 834);
              await tester.pump(const Duration(milliseconds: 80));
            }
            await tester.pumpAndSettle();
            expect(snapshot, findsNothing);
            expect(tester.takeException(), isNull);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        },
      );
    }
  }
}

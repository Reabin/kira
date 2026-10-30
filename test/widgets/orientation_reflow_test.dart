import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/orientation_reflow.dart';

import '../test_helpers.dart';

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  for (final reduced in [false, true]) {
    testWidgets(
      'iPad orientation preserves route state and respects reduced motion ($reduced)',
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
          final fade = tester.widget<FadeTransition>(
            find.byKey(const ValueKey('orientation-reflow')),
          );
          expect(fade.opacity.value, reduced ? 1 : lessThan(1));
          expect(find.text('count:1'), findsOneWidget);
          await tester.pumpAndSettle();
          expect(fade.opacity.value, 1);
          expect(tester.takeException(), isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}

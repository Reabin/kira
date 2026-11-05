import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/app_hero.dart';

import '../test_helpers.dart';

void main() {
  Future<void> pumpHero(
    WidgetTester tester, {
    required bool disableAnimations,
  }) async {
    final media = MediaQueryData(
      size: const Size(400, 600),
      disableAnimations: disableAnimations,
    );
    await tester.pumpWidget(
      wrapWithApp(
        MediaQuery(
          data: media,
          child: const AppHero(
            tag: 'cover',
            child: SizedBox(width: 40, height: 60),
          ),
        ),
      ),
    );
  }

  testWidgets('AppHero keeps the flight when motion is allowed', (
    tester,
  ) async {
    await pumpHero(tester, disableAnimations: false);
    expect(find.byType(Hero), findsOneWidget);
  });

  testWidgets('AppHero drops the flight under reduced motion', (tester) async {
    await pumpHero(tester, disableAnimations: true);
    expect(find.byType(Hero), findsNothing);
    expect(find.byType(SizedBox), findsWidgets);
  });
}

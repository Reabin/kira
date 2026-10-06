import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/recent_region_filter.dart';
import '../test_helpers.dart';

void main() {
  testWidgets('Multi-select applies only on confirmation and can cancel', (
    tester,
  ) async {
    Set<int>? saved;
    await tester.pumpWidget(
      wrapWithApp(
        RecentRegionFilter(
          regions: const {0},
          onChanged: (value) => saved = value,
        ),
      ),
    );
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('韩漫'));
    await tester.pump();
    expect(saved, isNull);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(saved, {0, 1});
    saved = null;
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('美漫'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
  });

  testWidgets('Cannot confirm an empty selection', (tester) async {
    await tester.pumpWidget(
      wrapWithApp(RecentRegionFilter(regions: const {0}, onChanged: (_) {})),
    );
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日漫'));
    await tester.pump();
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '确认'),
    );
    expect(button.onPressed, isNull);
  });
}

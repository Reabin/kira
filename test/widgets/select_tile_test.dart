import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/select_tile.dart';

import '../test_helpers.dart';

void main() {
  testWidgets('open menu updates labels, selection and capsule width', (
    tester,
  ) async {
    late StateSetter rebuild;
    var rate = 60;
    var selected = 0;
    await tester.pumpWidget(
      wrapWithApp(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Center(
              child: SelectTile<int>(
                value: selected,
                items: [
                  SelectItem(0, '自动', compactLabel: '自动 · ${rate}Hz'),
                  SelectItem(120, rate == 120 ? '120Hz（当前）' : '120 Hz'),
                ],
                onChanged: (value) => setState(() => selected = value),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.byType(SelectTile<int>));
    await tester.pumpAndSettle();
    expect(find.text('120 Hz'), findsOneWidget);
    final oldWidth = tester.getSize(find.byType(SelectTile<int>)).width;

    rebuild(() => rate = 120);
    await tester.pump();
    await tester.pump();
    expect(find.text('自动 · 120Hz'), findsOneWidget);
    expect(find.text('120Hz（当前）'), findsOneWidget);
    expect(find.text('120 Hz'), findsNothing);
    final width = tester.getSize(find.byType(SelectTile<int>)).width;
    expect(width, greaterThan(oldWidth));
    final menuItem = find.ancestor(
      of: find.text('120Hz（当前）'),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(menuItem).width, width);

    rebuild(() => selected = 120);
    await tester.pump();
    await tester.pump();
    final menuLabel = tester.widget<Text>(find.text('120Hz（当前）').last);
    expect(menuLabel.style?.fontWeight, FontWeight.w600);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

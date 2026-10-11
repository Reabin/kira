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

  testWidgets('appearance overrides tint the pill and icon without a border '
      'by default', (tester) async {
    const fg = Color(0xFFFF6F00);
    const bg = Color(0x24FFC107);
    const accent = Color(0xFFFFC107);
    await tester.pumpWidget(
      wrapWithApp(
        Center(
          child: SelectTile<String>(
            value: 'beta',
            foregroundColor: fg,
            backgroundColor: bg,
            borderSide: const BorderSide(color: accent),
            leadingIcon: Icons.science_outlined,
            items: const [SelectItem('beta', 'beta')],
            onChanged: (_) {},
          ),
        ),
      ),
    );

    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(SelectTile<String>),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, bg);
    final shape = material.shape as RoundedRectangleBorder;
    expect(shape.side.color, accent);

    expect(find.byIcon(Icons.science_outlined), findsOneWidget);
    final label = tester.widget<Text>(find.text('beta'));
    expect(label.style?.color, fg);
    final arrow = tester.widget<Icon>(find.byIcon(Icons.keyboard_arrow_down));
    expect(arrow.color, fg);
  });

  testWidgets('without overrides the pill keeps its pre-existing colouring', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapWithApp(
        Center(
          child: SelectTile<int>(
            value: 0,
            items: const [SelectItem(0, '自动')],
            onChanged: (_) {},
          ),
        ),
      ),
    );
    final cs = Theme.of(
      tester.element(find.byType(SelectTile<int>)),
    ).colorScheme;
    expect(
      tester.widget<Icon>(find.byIcon(Icons.keyboard_arrow_down)).color,
      cs.onSurfaceVariant,
    );
    expect(find.byIcon(Icons.science_outlined), findsNothing);
  });
}

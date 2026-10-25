import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/filter_chip_row.dart';

import '../test_helpers.dart';

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  testWidgets('filter chip stays compact and responds at the top edge', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      wrapWithApp(
        Align(
          alignment: Alignment.topLeft,
          child: FilterChipRow(
            options: const [FilterChipOption(label: '全部', value: '')],
            onTap: (option) => selected = option.value,
          ),
        ),
      ),
    );
    final chip = find.byType(FilterChip);
    final rect = tester.getRect(chip);
    // 紧凑档（shrinkWrap）：与热门搜索关键字同高，低于 48dp 触控建议值。
    expect(rect.height, allOf(greaterThanOrEqualTo(38), lessThan(48)));
    await tester.tapAt(Offset(rect.center.dx, rect.top + 1));
    expect(selected, '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('filter row grows with large text and the reset keeps working', (
    tester,
  ) async {
    var reset = 0;
    await tester.pumpWidget(
      wrapWithApp(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(3)),
            child: Align(
              alignment: Alignment.topLeft,
              child: FilterChipRow(
                options: const [FilterChipOption(label: '爱情', value: 'love')],
                onTap: (_) {},
                trailing: FilterRowResetButton(
                  icon: Icons.refresh,
                  label: '重置',
                  onPressed: () => reset++,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final chip = find.widgetWithText(FilterChip, '爱情');
    expect(tester.getSize(chip).height, greaterThan(48));
    final resetButton = find.byType(FilterRowResetButton);
    expect(tester.getSize(resetButton).height, greaterThan(48));
    await tester.tap(resetButton);
    expect(reset, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded tags keep the same compact height', (tester) async {
    String? selected;
    await tester.pumpWidget(
      wrapWithApp(
        AllTagsGrid(
          tags: const [FilterTagOption(name: '奇幻', pathWord: 'fantasy')],
          selectedTag: null,
          onSelected: (value) => selected = value,
        ),
      ),
    );
    final chip = find.widgetWithText(FilterChip, '奇幻');
    final rect = tester.getRect(chip);
    expect(rect.height, allOf(greaterThanOrEqualTo(38), lessThan(48)));
    await tester.tapAt(Offset(rect.center.dx, rect.top + 1));
    expect(selected, 'fantasy');
    expect(tester.takeException(), isNull);
  });
}

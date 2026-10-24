import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/filter_chip_row.dart';

import '../test_helpers.dart';

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  testWidgets('filter labels respond in the padded area outside the pill', (
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
    expect(rect.height, greaterThanOrEqualTo(48));
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
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
    final resetButton = find.byType(FilterRowResetButton);
    expect(tester.getSize(resetButton).height, greaterThanOrEqualTo(48));
    await tester.tap(resetButton);
    expect(reset, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded tags keep the same minimum touch height', (
    tester,
  ) async {
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
    expect(rect.height, greaterThanOrEqualTo(48));
    await tester.tapAt(Offset(rect.center.dx, rect.top + 1));
    expect(selected, 'fantasy');
    expect(tester.takeException(), isNull);
  });
}

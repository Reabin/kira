import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/section_header.dart';

import '../test_helpers.dart';

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  testWidgets('a collapsible section responds across its minimum row height', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      wrapWithApp(
        Align(
          alignment: Alignment.topLeft,
          child: SectionHeader(
            title: '分区',
            icon: Icons.menu_book,
            onTap: () => taps++,
            trailing: const Icon(Icons.expand_more),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(SectionHeader));
    expect(rect.height, greaterThanOrEqualTo(48));
    await tester.tapAt(Offset(rect.center.dx, rect.bottom - 1));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('more does not trigger the parent collapse action', (
    tester,
  ) async {
    var taps = 0;
    var more = 0;
    await tester.pumpWidget(
      wrapWithApp(
        SectionHeader(title: '分区', onTap: () => taps++, onMore: () => more++),
      ),
    );
    await tester.tap(find.text('更多'));
    expect(more, 1);
    expect(taps, 0);
  });
}

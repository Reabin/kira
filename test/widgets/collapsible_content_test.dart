import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/collapsible_content.dart';

import '../test_helpers.dart';

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  testWidgets(
    'reduced motion stops an in-flight fold without remounting content',
    (tester) async {
      var expanded = false;
      var reduced = false;
      late StateSetter rebuild;
      final controller = TextEditingController(text: '保留内容');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        wrapWithApp(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: reduced),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: CollapsibleContent(
                    expanded: expanded,
                    child: SizedBox(
                      height: 100,
                      child: TextField(controller: controller),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      final fieldElement = tester.element(find.byType(TextField));
      expect(find.byType(TextField).hitTestable(), findsNothing);
      rebuild(() => expanded = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final partial = tester.getSize(find.byType(CollapsibleContent)).height;
      expect(partial, greaterThan(0));
      expect(partial, lessThan(100));
      rebuild(() => reduced = true);
      await tester.pump();
      expect(tester.getSize(find.byType(CollapsibleContent)).height, 100);
      expect(tester.element(find.byType(TextField)), same(fieldElement));
      expect(controller.text, '保留内容');
      rebuild(() => expanded = false);
      await tester.pump();
      expect(tester.getSize(find.byType(CollapsibleContent)).height, 0);
      expect(find.byType(TextField).hitTestable(), findsNothing);
      expect(tester.element(find.byType(TextField)), same(fieldElement));
      expect(tester.takeException(), isNull);
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/models/novel_reader_settings.dart';
import 'package:kira/pages/novel_reader/novel_reader_document.dart';
import 'package:kira/pages/novel_reader/novel_reader_viewport.dart';
import 'package:kira/theme/novel_reader_theme.dart';

import '../test_helpers.dart';

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  for (final lines in [1, 3, 24]) {
    testWidgets(
      'volume seam uses the bottom of a $lines-line final paragraph',
      (tester) async {
        final lastText = List.generate(
          lines,
          (index) => 'closing line $index',
        ).join('\n');
        final document = NovelReaderDocument([
          NovelReaderEntry(
            entryIndex: 0,
            entry: const NovelContentEntry(name: '', contentType: 1),
            paragraphs: [List.filled(40, 'opening line').join('\n'), lastText],
          ),
        ]);
        var reached = 0;
        var approached = 0;
        const settings = NovelReaderSettings(paragraphSpacing: 0);
        await tester.pumpWidget(
          wrapWithApp(
            NovelReaderViewport(
              document: document,
              settings: settings,
              palette: NovelReaderPalette.resolve(settings, Brightness.light),
              target: const NovelReaderAnchor(
                entryIndex: 0,
                paragraphIndex: 1,
                alignment: 0.95,
              ),
              jumpRevision: 0,
              onPosition: (_) {},
              onTap: () {},
              onApproachEnd: () => approached++,
              onReachSeam: () => reached++,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(reached, 0);
        final surface = find.byKey(const ValueKey('novel-reader-surface'));
        final viewport = tester.getRect(surface);
        final last = find.text(lastText);
        final gesture = await tester.startGesture(viewport.center);
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();

        Future<void> moveBottomTo(double ratio) async {
          final target = viewport.top + viewport.height * ratio;
          await gesture.moveBy(
            Offset(0, target - tester.getBottomLeft(last).dy),
          );
          await tester.pump();
        }

        await moveBottomTo(0.95);
        expect(
          tester.getBottomLeft(last).dy,
          closeTo(viewport.top + viewport.height * 0.95, 1),
        );
        expect(approached, 1);
        expect(reached, 0);
        await moveBottomTo(0.895);
        expect(
          tester.getBottomLeft(last).dy,
          closeTo(viewport.top + viewport.height * 0.895, 1),
        );
        expect(reached, 1);
        await moveBottomTo(0.85);
        expect(reached, 1);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}

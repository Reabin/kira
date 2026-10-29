import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/pages/reader/reader_spread_layout.dart';

void main() {
  test(
    'odd chapter end stays alone instead of pairing with the next chapter',
    () {
      final layout = ReaderSpreadLayout([3, 4], pagesPerSpread: 2);
      expect(layout.spreadCount, 4);
      expect(
        [for (var i = 0; i < 4; i++) layout.imagesForSpread(i)],
        [
          (first: 0, last: 1),
          (first: 2, last: 2),
          (first: 3, last: 4),
          (first: 5, last: 6),
        ],
      );
      expect(
        [for (var i = 0; i < 8; i++) layout.spreadForImage(i)],
        [0, 0, 1, 2, 2, 3, 3, 4],
      );
    },
  );

  test(
    'all leaves remain reachable with different chapter lengths and modes',
    () {
      for (final columns in [1, 2]) {
        final layout = ReaderSpreadLayout([
          1,
          2,
          3,
          4,
          5,
        ], pagesPerSpread: columns);
        final images = <int>[];
        for (var spread = 0; spread < layout.spreadCount; spread++) {
          final range = layout.imagesForSpread(spread);
          for (var image = range.first; image <= range.last; image++) {
            images.add(image);
            expect(layout.spreadForImage(image), spread);
          }
        }
        expect(images, List.generate(15, (i) => i));
        expect(layout.spreadForImage(15), layout.spreadCount);
      }
    },
  );

  test(
    'landscape tablet uses two leaves; portrait, narrow windows and phones do not',
    () {
      expect(
        ReaderSpreadLayout.columnsFor(const Size(1210, 834), isIOS: true),
        2,
      );
      for (final window in [
        const Size(834, 1210),
        const Size(420, 650),
        const Size(932, 430),
      ]) {
        expect(ReaderSpreadLayout.columnsFor(window, isIOS: true), 1);
      }
      expect(
        ReaderSpreadLayout.columnsFor(const Size(1210, 834), isIOS: false),
        1,
      );
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/utils/chapter_page_order.dart';

void main() {
  test(
    'reverse catalogue starts at newest server batch and preserves source page hints',
    () {
      const order = ChapterPageOrder(totalPages: 3, reversed: true);
      expect(order.firstServerPage, 2);
      expect([for (var i = 0; i < 3; i++) order.serverPage(i)], [2, 1, 0]);
      for (var server = 0; server < 3; server++) {
        expect(order.serverPage(order.displayedPage(server)), server);
      }
    },
  );
  test(
    'ascending, single-page and empty catalogues keep valid first offsets',
    () {
      expect(
        const ChapterPageOrder(totalPages: 3, reversed: false).firstServerPage,
        0,
      );
      expect(
        const ChapterPageOrder(totalPages: 1, reversed: true).serverPage(0),
        0,
      );
      expect(
        const ChapterPageOrder(totalPages: 0, reversed: true).firstServerPage,
        0,
      );
    },
  );
}

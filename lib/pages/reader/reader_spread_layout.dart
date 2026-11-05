import 'package:flutter/widgets.dart';

/// Spread boundaries belong to each chapter: an odd last page stays alone.
class ReaderSpreadLayout {
  ReaderSpreadLayout(this.chapterLengths, {required this.pagesPerSpread})
    : assert(pagesPerSpread == 1 || pagesPerSpread == 2);

  final List<int> chapterLengths;
  final int pagesPerSpread;

  int get spreadCount => chapterLengths.fold(
    0,
    (count, length) => count + (length + pagesPerSpread - 1) ~/ pagesPerSpread,
  );

  int spreadForImage(int globalImage) {
    var imageStart = 0;
    var spreadStart = 0;
    for (final length in chapterLengths) {
      if (globalImage < imageStart + length) {
        return spreadStart + (globalImage - imageStart) ~/ pagesPerSpread;
      }
      imageStart += length;
      spreadStart += (length + pagesPerSpread - 1) ~/ pagesPerSpread;
    }
    return spreadCount; // The final blank catalogue-return screen.
  }

  ({int first, int last}) imagesForSpread(int spread) {
    if (spread < 0 || spread >= spreadCount) {
      throw RangeError.value(spread, 'spread');
    }
    var imageStart = 0;
    var spreadStart = 0;
    for (final length in chapterLengths) {
      final count = (length + pagesPerSpread - 1) ~/ pagesPerSpread;
      if (spread < spreadStart + count) {
        final first = imageStart + (spread - spreadStart) * pagesPerSpread;
        return (
          first: first,
          last: (first + pagesPerSpread - 1).clamp(
            first,
            imageStart + length - 1,
          ),
        );
      }
      imageStart += length;
      spreadStart += count;
    }
    throw RangeError.value(spread, 'spread');
  }

  static int columnsFor(Size window, {required bool isIOS}) =>
      isIOS &&
          window.width >= 900 &&
          window.height >= 600 &&
          window.width > window.height
      ? 2
      : 1;
}

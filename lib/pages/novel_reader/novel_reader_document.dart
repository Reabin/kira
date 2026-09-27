import '../../models/novel.dart';

/// Logical position, independent of widgets and pixel heights. Alignment is the
/// paragraph's leading edge in viewport units; negative values are intentional.
class NovelReaderAnchor {
  const NovelReaderAnchor({
    required this.entryIndex,
    this.paragraphIndex = 0,
    this.alignment = 0,
  });

  final int entryIndex;
  final int paragraphIndex;
  final double alignment;
}

class NovelReaderLocation {
  const NovelReaderLocation({
    required this.anchor,
    required this.itemIndex,
    required this.progress,
  });

  final NovelReaderAnchor anchor;
  final int itemIndex;
  final double progress;
}

class NovelReaderParagraph {
  const NovelReaderParagraph(this.entry, this.paragraphIndex);

  final NovelReaderEntry entry;
  final int paragraphIndex;

  String get text =>
      entry.paragraphs.isEmpty ? '' : entry.paragraphs[paragraphIndex];
}

/// Prefix offsets avoid creating a widget (or copying text) for every paragraph.
/// Only text contributes to progress; source entry indexes remain stable.
class NovelReaderDocument {
  NovelReaderDocument(List<NovelReaderEntry> source)
    : entries = List.unmodifiable(source.where((entry) => !entry.isImage)) {
    for (final entry in source) {
      if (entry.isImage) {
        // Old versions allowed stopping on an illustration. Recover beside the
        // preceding text without renumbering text entries or counting images.
        _illustrationOffsets[entry.entryIndex] = itemCount > 0
            ? itemCount - 1
            : 0;
        continue;
      }
      _offsets.add(itemCount);
      _entryOffsets[entry.entryIndex] = itemCount;
      itemCount += entry.paragraphs.isEmpty ? 1 : entry.paragraphs.length;
    }
  }

  final List<NovelReaderEntry> entries;
  final List<int> _offsets = [];
  final Map<int, int> _entryOffsets = {};
  final Map<int, int> _illustrationOffsets = {};
  int itemCount = 0;

  int itemFor(NovelReaderAnchor anchor) {
    final offset = _entryOffsets[anchor.entryIndex];
    if (offset == null) return _illustrationOffsets[anchor.entryIndex] ?? 0;
    final slot = _slotFor(offset);
    final end = slot + 1 < _offsets.length ? _offsets[slot + 1] : itemCount;
    return offset + anchor.paragraphIndex.clamp(0, end - offset - 1);
  }

  NovelReaderParagraph paragraphAt(int itemIndex) {
    final slot = _slotFor(itemIndex);
    return NovelReaderParagraph(entries[slot], itemIndex - _offsets[slot]);
  }

  NovelReaderAnchor anchorFor(int itemIndex, {double alignment = 0}) {
    final paragraph = paragraphAt(itemIndex.clamp(0, itemCount - 1));
    return NovelReaderAnchor(
      entryIndex: paragraph.entry.entryIndex,
      paragraphIndex: paragraph.paragraphIndex,
      alignment: alignment.isFinite ? alignment : 0,
    );
  }

  int _slotFor(int itemIndex) {
    var low = 0;
    var high = _offsets.length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (_offsets[middle] <= itemIndex) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }
}

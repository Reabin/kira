import '../../models/novel.dart';

extension<T> on Iterable<T> {
  T? get _lastOrNull => isEmpty ? null : last;
}

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
  NovelReaderDocument(
    List<NovelReaderEntry> source, {
    bool ignoreBlankParagraphs = false,
  }) : entries = List.unmodifiable(source.where((entry) => !entry.isImage)) {
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
      if (entry.paragraphs.isEmpty) {
        itemCount += 1;
        continue;
      }
      if (!ignoreBlankParagraphs) {
        itemCount += entry.paragraphs.length;
        continue;
      }
      // 只隐藏空行，不重排原始下标：paragraphAt 仍返回源数组下标，
      // 锚点（进度/书签）身份在开关切换前后保持不变。
      final visible = [
        for (var index = 0; index < entry.paragraphs.length; index++)
          if (entry.paragraphs[index].trim().isNotEmpty) index,
      ];
      if (visible.isEmpty) {
        // 整章只有空白行：保留首行占位，避免该章从文档与目录里消失。
        _visibleParagraphs[entry.entryIndex] = const [0];
      } else {
        _visibleParagraphs[entry.entryIndex] = List.unmodifiable(visible);
      }
      itemCount += _visibleParagraphs[entry.entryIndex]!.length;
    }
  }

  final List<NovelReaderEntry> entries;
  final List<int> _offsets = [];
  final Map<int, int> _entryOffsets = {};
  final Map<int, int> _illustrationOffsets = {};
  final Map<int, List<int>> _visibleParagraphs = {};
  int itemCount = 0;

  /// 章节起点按整卷进度条的 0..1 坐标表示；插图不占正文进度。
  List<double> get chapterStarts => itemCount > 1
      ? [for (final offset in _offsets) offset / (itemCount - 1)]
      : const [];

  int itemFor(NovelReaderAnchor anchor) {
    final offset = _entryOffsets[anchor.entryIndex];
    if (offset == null) return _illustrationOffsets[anchor.entryIndex] ?? 0;
    final visible = _visibleParagraphs[anchor.entryIndex];
    if (visible == null) {
      final slot = _slotFor(offset);
      final end = slot + 1 < _offsets.length ? _offsets[slot + 1] : itemCount;
      return offset + anchor.paragraphIndex.clamp(0, end - offset - 1);
    }
    // 旧锚点可能落在被隐藏的空行上（如开启开关前的书签）：向前找第一个
    // 可见段，没有则退回该章最后一个可见段；整章占位时退到首行。
    final index = visible.indexOf(anchor.paragraphIndex);
    if (index >= 0) return offset + index;
    final fallback = visible
        .where((candidate) => candidate < anchor.paragraphIndex)
        ._lastOrNull;
    return offset + visible.indexOf(fallback ?? visible.last);
  }

  NovelReaderParagraph paragraphAt(int itemIndex) {
    final slot = _slotFor(itemIndex);
    final entry = entries[slot];
    final visible = _visibleParagraphs[entry.entryIndex];
    final local = itemIndex - _offsets[slot];
    return NovelReaderParagraph(
      entry,
      visible == null ? local : visible[local.clamp(0, visible.length - 1)],
    );
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

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
    this.volumeId = '',
  });

  final int entryIndex;
  final int paragraphIndex;
  final double alignment;

  /// 所属卷。连续阅读拼接多卷后，同一 entryIndex 会在不同卷里重复出现，
  /// 只有带上卷 id 才能把锚点还原到正确的正文位置。单卷文档忽略该字段。
  final String volumeId;
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
  const NovelReaderParagraph(
    this.entry,
    this.paragraphIndex, {
    this.volumeId = '',
  });

  final NovelReaderEntry entry;
  final int paragraphIndex;

  /// 所属卷；单卷文档为空串。连续阅读时 entryIndex 会跨卷重复，
  /// 书签与高亮必须带上卷 id 才能定位。
  final String volumeId;

  String get text =>
      entry.paragraphs.isEmpty ? '' : entry.paragraphs[paragraphIndex];
}

/// 阅读视图（滚动 / 翻页 / 分页器）需要的只读正文能力。单卷文档与连续
/// 阅读的卷栈都实现它，视图因此不需要区分是否跨卷。
abstract interface class NovelTextDocument {
  int get itemCount;

  /// 章节起点按整个文档的 0..1 坐标表示（进度条刻度）；插图不占正文进度。
  List<double> get chapterStarts;

  int itemFor(NovelReaderAnchor anchor);

  NovelReaderAnchor anchorFor(int itemIndex, {double alignment = 0});

  NovelReaderParagraph paragraphAt(int itemIndex);

  /// 该段落在所属卷内的 0..1 进度。连续阅读按当前卷计算。
  double progressAt(int itemIndex, double fraction);

  /// 该段落所属卷的 id；单卷文档返回空串。
  String volumeIdForItem(int itemIndex);

  /// 该段落在所属卷 entries 里的槽位（未命名章节编号用）。
  int entrySlotFor(int itemIndex);

  /// 该段落所属卷内的 item 下标与总数：工具栏进度条按当前卷显示。
  int localItemFor(int itemIndex);

  int localItemCountFor(int itemIndex);

  /// 该段落所属卷的章节刻度（0..1，卷内坐标）。
  List<double> chapterStartsFor(int itemIndex);
}

/// Prefix offsets avoid creating a widget (or copying text) for every paragraph.
/// Only text contributes to progress; source entry indexes remain stable.
class NovelReaderDocument implements NovelTextDocument {
  NovelReaderDocument(
    List<NovelReaderEntry> source, {
    bool ignoreBlankParagraphs = false,
  }) : _source = List.unmodifiable(source),
       entries = List.unmodifiable(source.where((entry) => !entry.isImage)) {
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

  /// 构造时传入的原始 entry 序列（含插图），空行显隐切换时据此重建。
  final List<NovelReaderEntry> _source;
  final List<NovelReaderEntry> entries;
  final List<int> _offsets = [];
  final Map<int, int> _entryOffsets = {};
  final Map<int, int> _illustrationOffsets = {};
  final Map<int, List<int>> _visibleParagraphs = {};
  @override
  int itemCount = 0;

  /// 以同一份原始内容换一种空行策略重建（空行显隐开关）。
  NovelReaderDocument rebuild({required bool ignoreBlankParagraphs}) =>
      NovelReaderDocument(
        _source,
        ignoreBlankParagraphs: ignoreBlankParagraphs,
      );

  /// 章节起点按整卷进度条的 0..1 坐标表示；插图不占正文进度。
  @override
  List<double> get chapterStarts => itemCount > 1
      ? [for (final offset in _offsets) offset / (itemCount - 1)]
      : const [];

  /// 章节起点的原始 item 下标（卷栈换算绝对坐标用）。
  List<int> get chapterOffsets => List.unmodifiable(_offsets);

  @override
  int entrySlotFor(int itemIndex) =>
      _slotFor(itemIndex.clamp(0, itemCount - 1));

  @override
  String volumeIdForItem(int itemIndex) => '';

  @override
  double progressAt(int itemIndex, double fraction) =>
      ((itemIndex + fraction) / itemCount).clamp(0.0, 1.0);

  @override
  int localItemFor(int itemIndex) => itemIndex;

  @override
  int localItemCountFor(int itemIndex) => itemCount;

  @override
  List<double> chapterStartsFor(int itemIndex) => chapterStarts;

  @override
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

  @override
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

  @override
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

/// 一卷正文在卷栈里的切片。
class NovelReaderVolumeDocument {
  const NovelReaderVolumeDocument({
    required this.volumeId,
    required this.volumeName,
    required this.document,
  });

  final String volumeId;
  final String volumeName;
  final NovelReaderDocument document;

  /// 空行显隐切换：同一份原始内容按新策略重建，锚点身份不变。
  NovelReaderVolumeDocument rebuilt({required bool ignoreBlankParagraphs}) =>
      NovelReaderVolumeDocument(
        volumeId: volumeId,
        volumeName: volumeName,
        document: document.rebuild(
          ignoreBlankParagraphs: ignoreBlankParagraphs,
        ),
      );
}

/// 连续阅读的卷栈：把「当前卷 + 下一卷」拼成一个可滚动的正文序列。
///
/// 对外与单卷文档同构（[NovelTextDocument]），滚动视图、书签高亮都无需
/// 区分是否跨卷。段落身份是「卷 id + entryIndex + paragraphIndex」，卷 id
/// 为空时回落到第一卷（旧锚点与手动跳卷）。
class NovelReaderStack implements NovelTextDocument {
  NovelReaderStack(List<NovelReaderVolumeDocument> volumes)
    : assert(volumes.isNotEmpty),
      volumes = List.unmodifiable(volumes) {
    for (final volume in this.volumes) {
      _starts.add(itemCount);
      itemCount += volume.document.itemCount;
    }
  }

  final List<NovelReaderVolumeDocument> volumes;
  final List<int> _starts = [];

  @override
  int itemCount = 0;

  /// 某个 item 落在卷栈里的位置，供回收旧卷后的滚动补偿。
  int slotForItem(int itemIndex) {
    if (volumes.length == 1) return 0;
    final index = itemCount == 0 ? 0 : itemIndex.clamp(0, itemCount - 1);
    var low = 0;
    var high = _starts.length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (_starts[middle] <= index) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }

  /// 某卷第一个 item 在栈里的下标。
  int startOfSlot(int slot) => _starts[slot.clamp(0, _starts.length - 1)];

  /// 某卷最后一个 item 在栈里的下标。
  int endOfSlot(int slot) =>
      (slot + 1 < _starts.length ? _starts[slot + 1] : itemCount) - 1;

  NovelReaderDocument documentAt(int slot) => volumes[slot].document;

  @override
  int localItemFor(int itemIndex) => itemCount == 0
      ? 0
      : itemIndex.clamp(0, itemCount - 1) - _starts[slotForItem(itemIndex)];

  @override
  int localItemCountFor(int itemIndex) =>
      volumes[slotForItem(itemIndex)].document.itemCount;

  @override
  List<double> chapterStartsFor(int itemIndex) =>
      volumes[slotForItem(itemIndex)].document.chapterStarts;

  @override
  List<double> get chapterStarts {
    if (itemCount <= 1) return const [];
    return [
      for (var slot = 0; slot < volumes.length; slot++)
        for (final offset in volumes[slot].document.chapterOffsets)
          (_starts[slot] + offset) / (itemCount - 1),
    ];
  }

  @override
  String volumeIdForItem(int itemIndex) =>
      volumes[slotForItem(itemIndex)].volumeId;

  @override
  int entrySlotFor(int itemIndex) => volumes[slotForItem(itemIndex)].document
      .entrySlotFor(localItemFor(itemIndex));

  @override
  double progressAt(int itemIndex, double fraction) =>
      volumes[slotForItem(itemIndex)].document.progressAt(
        localItemFor(itemIndex),
        fraction,
      );

  @override
  NovelReaderParagraph paragraphAt(int itemIndex) {
    final slot = slotForItem(itemIndex);
    final paragraph = volumes[slot].document.paragraphAt(
      localItemFor(itemIndex),
    );
    return NovelReaderParagraph(
      paragraph.entry,
      paragraph.paragraphIndex,
      volumeId: volumes[slot].volumeId,
    );
  }

  @override
  NovelReaderAnchor anchorFor(int itemIndex, {double alignment = 0}) {
    final slot = slotForItem(itemIndex);
    final local = volumes[slot].document.anchorFor(
      localItemFor(itemIndex),
      alignment: alignment,
    );
    return NovelReaderAnchor(
      entryIndex: local.entryIndex,
      paragraphIndex: local.paragraphIndex,
      alignment: local.alignment,
      volumeId: volumes[slot].volumeId,
    );
  }

  @override
  int itemFor(NovelReaderAnchor anchor) {
    var slot = 0;
    if (anchor.volumeId.isNotEmpty) {
      final found = volumes.indexWhere(
        (volume) => volume.volumeId == anchor.volumeId,
      );
      if (found >= 0) slot = found;
    }
    return _starts[slot] + volumes[slot].document.itemFor(anchor);
  }
}

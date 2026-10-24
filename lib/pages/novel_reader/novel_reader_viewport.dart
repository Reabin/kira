import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../l10n/app_localizations.dart';
import '../../models/novel_reader_settings.dart';
import '../../theme/app_icon_sizes.dart';
import '../../theme/app_spacing.dart';
import '../../theme/novel_reader_theme.dart';
import '../../utils/app_logger.dart';
import '../../utils/fling_brake_tap_guard.dart';
import 'novel_reader_document.dart';

/// Owns layout restoration, so neither initial layout nor a font/viewport change
/// can emit a spurious paragraph zero to the persistence layer.
class NovelReaderViewport extends StatefulWidget {
  const NovelReaderViewport({
    super.key,
    required this.document,
    required this.settings,
    required this.palette,
    required this.target,
    required this.jumpRevision,
    required this.onPosition,
    required this.onTap,
    this.onParagraphLongPress,
    this.isBookmarkedParagraph,
    this.onBookmarkMarkerTap,
    this.highlight,
    this.highlightOpacity,
    this.onScroll,
    this.contentPadding = EdgeInsets.zero,
    this.contentRevision = 0,
    this.seam,
    this.onApproachEnd,
    this.onReachSeam,
  });

  final NovelTextDocument document;
  final NovelReaderSettings settings;
  final NovelReaderPalette palette;
  final NovelReaderAnchor target;
  final int jumpRevision;
  final ValueChanged<NovelReaderLocation> onPosition;
  final VoidCallback onTap;

  /// 长按段落弹出上下文菜单（与翻页模式同一手势）；回携带落点全局坐标
  /// 供菜单定位。点按仍然只切换工具栏（由外层 surface 统一处理）。
  final void Function(NovelReaderParagraph paragraph, Offset position)?
  onParagraphLongPress;

  /// 段落是否已有书签（决定是否渲染小书签标记）。
  final bool Function(NovelReaderParagraph paragraph)? isBookmarkedParagraph;

  /// 点按段落上的小书签标记（取消该书签）。
  final void Function(NovelReaderParagraph paragraph)? onBookmarkMarkerTap;

  /// 短暂高亮的书签段落（书签指向处进入/打书签成功时闪光提示）。
  /// 由阅读页持有定时清除，viewport 只按参数渲染，不改变布局。
  final NovelReaderAnchor? highlight;

  /// 高亮的淡入淡出动画：画笔挂它逐帧重绘，高亮不触发整树 rebuild。
  final Animation<double>? highlightOpacity;

  final VoidCallback? onScroll;

  /// 进入页面时快照的系统栏安全区 inset。viewport 本身铺满全屏（纸张延伸
  /// 到屏幕顶/底），这份 inset 作为列表内容的固定 padding，保证首段不被
  /// 状态栏遮挡、滚动途中不触发 viewport 尺寸变化。
  final EdgeInsets contentPadding;

  /// 正文在原位追加了新卷（item 数变多但已有内容位置不变）。与文档身份
  /// 变化区分开：追加不重定位滚动，空行显隐/换卷才重定位。
  final int contentRevision;

  /// 卷末接缝处的内容：下一卷加载中 / 加载失败 / 未下载。无下一卷时为 null。
  final Widget? seam;

  /// 接近卷末（约两屏）时触发下一卷预取。
  final VoidCallback? onApproachEnd;

  /// 卷末最后一段滑到距视口顶部 1/3 时触发追加下一卷。
  final VoidCallback? onReachSeam;

  @override
  State<NovelReaderViewport> createState() => NovelReaderViewportState();
}

class NovelReaderViewportState extends State<NovelReaderViewport> {
  final _scroll = ItemScrollController();
  final _offset = ScrollOffsetController();
  final _positions = ItemPositionsListener.create();
  late NovelReaderAnchor _desired;
  NovelReaderLocation? _lastLocation;
  Size? _size;
  TextScaler? _textScaler;
  bool _restoring = true;
  int _restoration = 0;

  /// True from a user drag start (or fling) until the gesture-driven scroll
  /// ends. Only these notifications hide the toolbar, so programmatic anchor
  /// restoration never does.
  bool _userScrolling = false;

  /// 猛滑后点一下只是给惯性刹车，这种点击不切换工具栏（与漫画阅读器一致）。
  final _flingBrakeGuard = FlingBrakeTapGuard();

  /// 卷末预取/追加的节流：同一次滑动只触发一次，直到回调方装载新内容。
  bool _approachNotified = false;
  bool _seamNotified = false;

  /// 本轮是否真的由读者向下滑过。打开一卷时若内容很短，末段本来就在
  /// 触发阈值内；没有这道闸门会在开卷瞬间一路追加，把整本书都读进来。
  bool _scrolledForward = false;

  /// Null during any restoration: callers may flush their last valid snapshot,
  /// but must not replace it with a transient layout position.
  NovelReaderLocation? get currentLocation =>
      _restoring ? null : _readPosition();

  /// 视口垂直中点所覆盖段落的定位。打书签以此为参照（阅读习惯是
  /// 把内容滚到屏幕中间看，而不是以顶部首段为基准），恢复位置时
  /// 用锚点自带的 alignment 即可还原到保存时的视口位置。
  /// 中点落在空行/空章节占位上时，就近改选有文本的段落——
  /// 绝不给空行打书签。恢复过程中或无可见内容时返回 null。
  NovelReaderLocation? anchorAtViewportCenter() {
    if (_restoring || widget.document.itemCount == 0) return null;
    ItemPosition? center;
    var bestDistance = double.infinity;
    for (final item in _positions.itemPositions.value) {
      if (item.itemTrailingEdge <= 0 || item.itemLeadingEdge >= 1) continue;
      final mid = (item.itemLeadingEdge + item.itemTrailingEdge) / 2;
      final distance = (mid - 0.5).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        center = item;
      }
    }
    if (center == null) return null;
    if (_isEmptyParagraph(center.index)) {
      ItemPosition? fallback;
      var fallbackDistance = double.infinity;
      for (final item in _positions.itemPositions.value) {
        if (item.itemTrailingEdge <= 0 || item.itemLeadingEdge >= 1) continue;
        if (_isEmptyParagraph(item.index)) continue;
        final mid = (item.itemLeadingEdge + item.itemTrailingEdge) / 2;
        final distance = (mid - 0.5).abs();
        if (distance < fallbackDistance) {
          fallbackDistance = distance;
          fallback = item;
        }
      }
      // 可见项里没有正文时按目录顺序向外找（先向前）。
      center =
          fallback ??
          _nearestTextItemAway(center.index, center.itemLeadingEdge);
      if (center == null) return null;
    }
    final extent = center.itemTrailingEdge - center.itemLeadingEdge;
    final fraction = extent <= 0
        ? 0.0
        : ((0.5 - center.itemLeadingEdge) / extent).clamp(0.0, 1.0);
    return NovelReaderLocation(
      anchor: widget.document.anchorFor(
        center.index,
        alignment: center.itemLeadingEdge,
      ),
      itemIndex: center.index,
      progress: widget.document.progressAt(center.index, fraction),
    );
  }

  bool _isEmptyParagraph(int index) =>
      widget.document.paragraphAt(index).text.trim().isEmpty;

  /// 从 [from] 按目录顺序向外（先向前）找最近的有文本段落，
  /// 返回合成的 ItemPosition（视口位置用 [leadingEdge] 近似）。
  ItemPosition? _nearestTextItemAway(int from, double leadingEdge) {
    final count = widget.document.itemCount;
    for (var distance = 1; distance < count; distance++) {
      final previous = from - distance;
      if (previous >= 0 && !_isEmptyParagraph(previous)) {
        return ItemPosition(
          index: previous,
          itemLeadingEdge: leadingEdge,
          itemTrailingEdge: leadingEdge + 1,
        );
      }
      final next = from + distance;
      if (next < count && !_isEmptyParagraph(next)) {
        return ItemPosition(
          index: next,
          itemLeadingEdge: leadingEdge,
          itemTrailingEdge: leadingEdge + 1,
        );
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _desired = widget.target;
    _positions.itemPositions.addListener(_onPositions);
    _scheduleRestore(_desired);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scaler = MediaQuery.textScalerOf(context);
    if (_textScaler != null && _textScaler != scaler) {
      _scheduleRestore(
        _restoring ? _desired : _lastLocation?.anchor ?? _desired,
      );
    }
    _textScaler = scaler;
  }

  @override
  void didUpdateWidget(NovelReaderViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.contentRevision != widget.contentRevision) {
      // 连续阅读在原位追加了下一卷：已有内容位置不变，只解锁接缝节流，
      // 让读者能继续下滑到新的卷末。不重定位滚动，否则视口会跳。
      _rearmSeam();
      // 回收旧卷会改变 item 下标，此时 jumpRevision 同步递增，走下面的
      // 重定位分支；单纯追加则到此为止。
      if (oldWidget.jumpRevision == widget.jumpRevision) return;
    }
    if (!identical(oldWidget.document, widget.document)) {
      // 文档重建（空行显隐切换）：列表项数与内容都变了，按目标锚点重新
      // 挂载定位；不能沿用旧 offset，恢复流程与字体变化同一套。
      _scheduleRestore(widget.target);
    } else if (oldWidget.jumpRevision != widget.jumpRevision) {
      _scheduleRestore(widget.target);
    } else if (oldWidget.settings.fontSize != widget.settings.fontSize ||
        oldWidget.settings.lineHeight != widget.settings.lineHeight ||
        oldWidget.settings.paragraphSpacing !=
            widget.settings.paragraphSpacing) {
      _scheduleRestore(
        _restoring ? _desired : _lastLocation?.anchor ?? _desired,
      );
    }
  }

  void _scheduleRestore(NovelReaderAnchor anchor) {
    _desired = anchor;
    _restoring = true;
    // 换卷/跳转后重新要求一次真实的向下滑动，卷末判定才恢复生效。
    _rearmSeam();
    final generation = ++_restoration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_restore(generation));
    });
  }

  bool _isCurrent(int generation) => mounted && generation == _restoration;

  Future<void> _restore(int generation) async {
    if (!_isCurrent(generation) || !_scroll.isAttached) return;
    final index = widget.document.itemFor(_desired);
    final alignment = _desired.alignment.isFinite ? _desired.alignment : 0.0;
    try {
      // PositionedList uses alignment as a viewport anchor and asserts [0, 1].
      // Never pass a saved negative leading edge to initialAlignment/jumpTo.
      _scroll.jumpTo(index: index, alignment: alignment.clamp(0.0, 0.99));
      await WidgetsBinding.instance.endOfFrame;
      if (!_isCurrent(generation)) return;
      if (alignment < 0) {
        final target = _positions.itemPositions.value
            .where((item) => item.index == index)
            .firstOrNull;
        final height = _size?.height ?? 0;
        if (target == null || height <= 0) return;
        // Corrupt/stale offsets (or shorter text after reflow) must not jump
        // into a different paragraph. Keep at least one pixel of this one.
        final extent = target.itemTrailingEdge - target.itemLeadingEdge;
        final inside = math.min(
          -alignment * height,
          math.max(0.0, extent * height - 1),
        );
        if (inside > 0) {
          await _offset.animateScroll(
            offset: inside,
            duration: const Duration(milliseconds: 1),
          );
          if (!_isCurrent(generation)) return;
          await WidgetsBinding.instance.endOfFrame;
        }
      }
      if (!_isCurrent(generation)) return;
      setState(() => _restoring = false);
      _onPositions();
    } catch (error, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          error,
          stackTrace: stack,
          source: 'novel_reader.restore',
        ),
      );
    }
  }

  NovelReaderLocation? _readPosition() {
    final visible = _positions.itemPositions.value.where(
      (item) => item.itemTrailingEdge > 0.001 && item.itemLeadingEdge < 1,
    );
    ItemPosition? first;
    for (final item in visible) {
      if (first == null || item.index < first.index) first = item;
    }
    if (first == null || first.index >= widget.document.itemCount) return null;
    final extent = first.itemTrailingEdge - first.itemLeadingEdge;
    final fraction = extent <= 0
        ? 0.0
        : (-first.itemLeadingEdge / extent).clamp(0.0, 1.0);
    return NovelReaderLocation(
      anchor: widget.document.anchorFor(
        first.index,
        alignment: first.itemLeadingEdge,
      ),
      itemIndex: first.index,
      progress:
          first.index == widget.document.itemCount - 1 &&
              first.itemTrailingEdge <= 1.001
          ? 1
          : widget.document.progressAt(first.index, fraction),
    );
  }

  void _onPositions() {
    if (!mounted || _restoring) return;
    _checkVolumeSeam();
    final location = _readPosition();
    if (location == null) return;
    _lastLocation = location;
    widget.onPosition(location);
  }

  /// 卷末接缝判定。末段的 leading edge 就是「最后一行到视口顶部」的距离
  /// （末段被撑到至少一屏高，正文贴在段首）：
  /// - ≤ 2 屏：提前预取下一卷，触发点到来时内容已就绪；
  /// - ≤ 1/3 屏：追加下一卷，读者继续下滑即进入新卷正文。
  void _checkVolumeSeam() {
    if (!_scrolledForward) return;
    if (widget.onApproachEnd == null && widget.onReachSeam == null) return;
    final lastIndex = widget.document.itemCount - 1;
    if (lastIndex < 0) return;
    ItemPosition? last;
    for (final item in _positions.itemPositions.value) {
      if (item.index == lastIndex) last = item;
    }
    if (last == null) return;
    if (!_approachNotified && last.itemLeadingEdge <= 2) {
      _approachNotified = true;
      widget.onApproachEnd?.call();
    }
    if (!_seamNotified && last.itemLeadingEdge <= 1 / 3) {
      _seamNotified = true;
      widget.onReachSeam?.call();
    }
  }

  /// 追加新卷后重新解锁接缝：只有读者继续向下滑才会再次触发，
  /// 避免一帧内连跳多卷。
  void _rearmSeam() {
    _approachNotified = false;
    _seamNotified = false;
    _scrolledForward = false;
  }

  @override
  void dispose() {
    ++_restoration;
    _positions.itemPositions.removeListener(_onPositions);
    super.dispose();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (_restoring) {
      _userScrolling = false;
      return false;
    }
    // 喂给刹车守卫：区分「手指仍按着拖」与「抬手后的惯性」，供点击刹车判定
    // 使用。程序化 restore 已在上面提前返回，不会污染记录。
    if (notification is ScrollUpdateNotification &&
        (notification.scrollDelta ?? 0) != 0) {
      _flingBrakeGuard.recordScroll(
        isDrag: notification.dragDetails != null,
        at: DateTime.now(),
      );
      // 只有读者真正向下滑过，卷末接缝判定才生效（见 _scrolledForward）。
      if ((notification.scrollDelta ?? 0) > 0) _scrolledForward = true;
    }
    // 正文恰好一屏（或末段被撑满一屏）时无法产生滚动位移，向下越界也算
    // 读者在继续下滑：此时接缝判定已经成立，直接补一次。
    if (notification is OverscrollNotification && notification.overscroll > 0) {
      _scrolledForward = true;
      _checkVolumeSeam();
    }
    // A user session opens at any ScrollStart (drag or the ballistic phase
    // after finger release) or an explicit direction change, but only an
    // actual ScrollUpdate hides the toolbar: a programmatic jumpTo also
    // emits a Start/End pair without updates, and must not hide anything.
    // Because the session stays open through the ballistic update stream,
    // a toolbar expanded mid-inertia hides again on the next update.
    if (notification is ScrollStartNotification ||
        (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle)) {
      _userScrolling = true;
    } else if (notification is ScrollUpdateNotification && _userScrolling) {
      widget.onScroll?.call();
    } else if (notification is ScrollEndNotification) {
      _userScrolling = false;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (_size != null && _size != size) {
          _scheduleRestore(
            _restoring ? _desired : _lastLocation?.anchor ?? _desired,
          );
        }
        _size = size;
        return Listener(
          // 按下的瞬间列表若还在惯性滚动，这次触摸只是刹车（见
          // FlingBrakeTapGuard）。判定放在 pointer-down 而不是 onTap 里。
          onPointerDown: (_) => _flingBrakeGuard.onPointerDown(DateTime.now()),
          child: AbsorbPointer(
            absorbing: _restoring,
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: GestureDetector(
                key: const ValueKey('novel-reader-surface'),
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_flingBrakeGuard.consumeTap()) return;
                  widget.onTap();
                },
                child: ScrollablePositionedList.builder(
                  key: const ValueKey('novel-reader-paragraphs'),
                  itemCount: widget.document.itemCount,
                  itemScrollController: _scroll,
                  scrollOffsetController: _offset,
                  itemPositionsListener: _positions,
                  initialScrollIndex: widget.document.itemFor(_desired),
                  initialAlignment: _desired.alignment.isFinite
                      ? _desired.alignment.clamp(0.0, 0.99)
                      : 0,
                  addAutomaticKeepAlives: false,
                  // 横向：安全区 inset 之上再做 720dp 限宽居中；纵向直接
                  // 用快照 inset（首段避开状态栏、末段避开导航栏）。
                  padding: () {
                    final contentWidth = math.max(
                      0,
                      size.width - widget.contentPadding.horizontal,
                    );
                    final side = math.max(
                      AppSpacing.xxl,
                      (contentWidth - 720) / 2,
                    );
                    return EdgeInsets.fromLTRB(
                      widget.contentPadding.left + side,
                      widget.contentPadding.top,
                      widget.contentPadding.right + side,
                      widget.contentPadding.bottom,
                    );
                  }(),
                  itemBuilder: _buildParagraph,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildParagraph(BuildContext context, int index) {
    final paragraph = widget.document.paragraphAt(index);
    final entry = paragraph.entry;
    final tt = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context)!;
    final foreground = widget.palette.foreground;
    final style = tt.bodyLarge!.copyWith(
      color: foreground,
      fontSize: widget.settings.fontSize,
      height: widget.settings.lineHeight,
    );
    final highlighted =
        widget.highlight != null &&
        widget.highlight!.entryIndex == entry.entryIndex &&
        widget.highlight!.paragraphIndex == paragraph.paragraphIndex &&
        (widget.highlight!.volumeId.isEmpty ||
            widget.highlight!.volumeId ==
                widget.document.volumeIdForItem(index));
    final bodyText = entry.paragraphs.isEmpty
        ? l10n.novelReaderEmptyChapter
        : (paragraph.text.isEmpty ? ' ' : paragraph.text);
    // 已加书签的段落在段末显示一个小书签标记（正文同色，弱化存在感）；
    // 点按标记直接取消书签。
    final marked = widget.isBookmarkedParagraph?.call(paragraph) ?? false;
    Widget body = marked
        ? Text.rich(
            TextSpan(
              children: [
                TextSpan(text: bodyText),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: GestureDetector(
                    key: ValueKey(
                      'novel-paragraph-marker-${entry.entryIndex}-'
                      '${paragraph.paragraphIndex}',
                    ),
                    onTap: () => widget.onBookmarkMarkerTap?.call(paragraph),
                    child: Padding(
                      padding: const EdgeInsets.only(left: AppSpacing.sm),
                      // 标记常驻正文，用降透明度的正文色弱化存在感。
                      child: Icon(
                        Icons.bookmark,
                        size: AppIconSize.md,
                        color: widget.palette.foreground.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            style: style,
          )
        : Text(bodyText, style: style);
    // 高亮样式由演示切换器实时决定；DecoratedBox 不参与布局，高亮
    // 出现/消失时正文一个像素都不动，锚点与进度不受闪光影响。
    // 高亮卡片画在段落矩形之外的留白里（不参与布局），出现/消失正文
    // 零位移；透明度由页面持有的动画驱动，逐帧重绘不重建子树。
    if (highlighted) {
      body = CustomPaint(
        painter: NovelHighlightPainter(
          color: widget.palette.foreground,
          fontSize: widget.settings.fontSize,
          opacity: widget.highlightOpacity,
        ),
        child: body,
      );
    }
    if (widget.onParagraphLongPress != null) {
      body = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: (details) =>
            widget.onParagraphLongPress!(paragraph, details.globalPosition),
        child: body,
      );
    }
    final child = Padding(
      key: ValueKey(
        'novel-paragraph-${entry.entryIndex}-${paragraph.paragraphIndex}',
      ),
      padding: EdgeInsets.only(bottom: widget.settings.paragraphSpacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (paragraph.paragraphIndex == 0 && entry.name.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
              child: Text(
                entry.name,
                style: tt.headlineSmall?.copyWith(color: foreground),
              ),
            ),
          // An empty source line is a real paragraph, not something to trim.
          body,
        ],
      ),
    );
    // Leave room to put even a short final paragraph at the top. Without it,
    // the list clamps a jump near EOF backwards into the preceding chapter or
    // illustration, and the next saved anchor would silently be wrong.
    // 卷末接缝提示紧贴最后一段之后，不额外占 item 下标。
    return index == widget.document.itemCount - 1
        ? ConstrainedBox(
            constraints: BoxConstraints(minHeight: _size?.height ?? 0),
            child: widget.seam == null
                ? child
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [child, widget.seam!],
                  ),
          )
        : child;
  }
}

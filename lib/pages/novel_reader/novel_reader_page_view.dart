import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/novel_reader_settings.dart';
import '../../theme/app_icon_sizes.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_spacing.dart';
import '../../theme/novel_reader_theme.dart';
import 'novel_reader_document.dart';
import 'novel_reader_paginator.dart';

/// 整页翻页视图：把整卷正文按可用区域切分成页，横向左到右翻页。
///
/// 与滚动视口（[NovelReaderViewport]）对齐的语义：
/// - 恢复完成前 [currentLocation] 返回 null，程序化跳转不触发工具栏隐藏；
/// - 锚点沿用 entryIndex + paragraphIndex + alignment（负值表示段内位置），
///   进度与滚动模式同一算法，模式切换时百分比连续。
class NovelReaderPageView extends StatefulWidget {
  const NovelReaderPageView({
    super.key,
    required this.document,
    required this.settings,
    required this.palette,
    required this.target,
    required this.jumpRevision,
    required this.bookmarkRevision,
    required this.emptyChapterText,
    required this.contentPadding,
    required this.onPosition,
    required this.onTap,
    this.onParagraphLongPress,
    this.isBookmarkedParagraph,
    this.onBookmarkMarkerTap,
    this.highlight,
    this.onPageTurned,
    this.onBoundary,
  });

  final NovelReaderDocument document;
  final NovelReaderSettings settings;
  final NovelReaderPalette palette;

  /// 目标锚点；[jumpRevision] 变化时按同一锚点重新定位。
  final NovelReaderAnchor target;
  final int jumpRevision;

  /// 书签集合的版本号：变化时只从受影响段落重建分页。
  final int bookmarkRevision;
  final String emptyChapterText;
  final EdgeInsets contentPadding;
  final ValueChanged<NovelReaderLocation> onPosition;

  /// 页面中间区域点击（切换工具栏）。
  final VoidCallback onTap;

  /// 长按段落（复制/书签菜单）；回携带落点全局坐标供菜单定位。
  final void Function(NovelReaderParagraph paragraph, Offset position)?
  onParagraphLongPress;

  /// 段落是否已有书签（决定是否渲染小书签标记并参与排版）。
  final bool Function(NovelReaderParagraph paragraph)? isBookmarkedParagraph;

  /// 点按段落上的小书签标记（取消该书签）。
  final void Function(NovelReaderParagraph paragraph)? onBookmarkMarkerTap;

  /// 短暂高亮的书签段落。
  final NovelReaderAnchor? highlight;

  /// 用户翻页（非程序化）：隐藏工具栏、清除高亮。
  final VoidCallback? onPageTurned;

  /// 越过卷首/卷末继续翻页；由宿主决定加载相邻卷或提示。
  final void Function(bool forward)? onBoundary;

  @override
  State<NovelReaderPageView> createState() => NovelReaderPageViewState();
}

class NovelReaderPageViewState extends State<NovelReaderPageView> {
  PageController _controller = PageController();
  NovelReaderPaginator? _paginator;
  Set<int> _markedItems = const {};
  int _currentPage = 0;
  bool _restoring = true;
  int _generation = 0;
  Size? _size;
  EdgeInsets? _contentPadding;
  TextScaler? _textScaler;
  Timer? _buildTimer;
  NovelReaderLocation? _lastLocation;
  double _instantTurnDelta = 0;
  bool _instantTurnCommitted = false;

  /// 一次滑动内是否已按卷界处理过（越界后继续滑动不再重复触发）。
  bool _boundaryArmed = false;

  /// Null during any restoration: callers may flush their last valid snapshot,
  /// but must not replace it with a transient page position.
  NovelReaderLocation? get currentLocation {
    if (_restoring) return null;
    return _locationForPage(_currentPage) ?? _lastLocation;
  }

  /// 视口垂直中点所在页的最近有正文段落（打书签以此为参照）。
  NovelReaderLocation? anchorAtViewportCenter() {
    if (_restoring) return null;
    final paragraph = _paginator?.centerParagraph(_currentPage);
    if (paragraph == null) return null;
    final anchor = NovelReaderAnchor(
      entryIndex: paragraph.entry.entryIndex,
      paragraphIndex: paragraph.paragraphIndex,
    );
    final item = widget.document.itemFor(anchor);
    return NovelReaderLocation(
      anchor: anchor,
      itemIndex: item,
      progress: (item / widget.document.itemCount).clamp(0.0, 1.0),
    );
  }

  void nextPage() => _turn(forward: true);

  void prevPage() => _turn(forward: false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scaler = MediaQuery.textScalerOf(context);
    if (_textScaler != null && _textScaler != scaler) {
      _scheduleRepaginate(_anchorNow());
    }
    _textScaler = scaler;
  }

  @override
  void didUpdateWidget(NovelReaderPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.document, widget.document)) {
      _restart(widget.target);
      return;
    }
    if (oldWidget.jumpRevision != widget.jumpRevision) {
      _restoreTarget(widget.target);
      return;
    }
    if (oldWidget.settings.fontSize != widget.settings.fontSize ||
        oldWidget.settings.lineHeight != widget.settings.lineHeight ||
        oldWidget.settings.paragraphSpacing !=
            widget.settings.paragraphSpacing) {
      _scheduleRepaginate(_anchorNow());
      return;
    }
    if (oldWidget.bookmarkRevision != widget.bookmarkRevision) {
      _handleBookmarkRevision();
    }
  }

  NovelReaderAnchor _anchorNow() =>
      _lastLocation?.anchor ?? _paginator?.anchorForPage(_currentPage) ??
      widget.target;

  bool _isCurrent(int generation) => mounted && generation == _generation;

  // ── 分页构建 ──

  void _scheduleRepaginate(NovelReaderAnchor anchor) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _restart(anchor);
    });
  }

  /// 整体重建分页（字体/行距/尺寸/文本缩放变化），并围绕 [anchor] 重新定位。
  void _restart(NovelReaderAnchor anchor) {
    if (_size == null) return;
    final generation = ++_generation;
    _buildTimer?.cancel();
    _restoring = true;
    final paginator = NovelReaderPaginator(
      document: widget.document,
      spec: _spec(_size!, _contentPadding ?? EdgeInsets.zero),
    );
    _paginator = paginator;
    _markedItems = _snapshotMarked();
    _pumpPagination(generation, anchor);
  }

  /// 构建到目标页可用，跳转并放行交互，随后后台续建剩余页。
  void _pumpPagination(int generation, NovelReaderAnchor anchor) {
    final paginator = _paginator;
    if (paginator == null) return;
    while (paginator.pageForAnchor(anchor) == null && paginator.buildMore()) {}
    final target = paginator.pageForAnchor(anchor) ?? paginator.pages.length - 1;
    final page = target
        .clamp(0, math.max(0, paginator.pages.length - 1))
        .toInt();
    _currentPage = page;
    setState(() {});
    // 帧后 PageView 已按新的页数完成布局，跳页不再受旧页数限制。
    // jumpToPage 同步派发 onPageChanged（此刻 _restoring 仍为 true，被忽略），
    // 所以不需要等待 endOfFrame：目标页与当前页相同时不会产生新帧，
    // 等待会把恢复状态永久卡住（界面失去响应、进度不再记录）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isCurrent(generation)) return;
      if (_controller.hasClients) {
        _controller.jumpToPage(page);
      } else {
        _replaceController(page);
      }
      setState(() => _restoring = false);
      _emitPosition();
      _scheduleBackgroundBuild(generation);
    });
  }

  /// 仅重新定位（滑杆跳转等）：分页已就绪，构建到目标页即可。
  void _restoreTarget(NovelReaderAnchor anchor) {
    if (_size == null) return;
    final generation = ++_generation;
    _buildTimer?.cancel();
    _restoring = true;
    _pumpPagination(generation, anchor);
  }

  void _handleBookmarkRevision() {
    final paginator = _paginator;
    if (paginator == null || _size == null) return;
    final next = _snapshotMarked();
    final changed = _markedDifferences(next);
    if (changed.isEmpty) return;
    _markedItems = next;
    final generation = ++_generation;
    _buildTimer?.cancel();
    _restoring = true;
    paginator.rebuildFrom(changed.reduce(math.min), invalidate: changed);
    _pumpPagination(generation, _anchorNow());
  }

  Set<int> _snapshotMarked() {
    final isMarked = widget.isBookmarkedParagraph;
    if (isMarked == null) return const {};
    final marked = <int>{};
    for (var item = 0; item < widget.document.itemCount; item++) {
      if (isMarked(widget.document.paragraphAt(item))) marked.add(item);
    }
    return marked;
  }

  /// 与上次快照相比书签状态发生变化的段落集合。
  Set<int> _markedDifferences(Set<int> next) {
    final previous = _markedItems;
    final all = {...previous, ...next};
    return {
      for (final item in all)
        if (previous.contains(item) != next.contains(item)) item,
    };
  }

  void _scheduleBackgroundBuild(int generation) {
    _buildTimer?.cancel();
    _buildTimer = Timer(const Duration(milliseconds: 16), () {
      if (!_isCurrent(generation)) return;
      _backgroundBuildStep(generation);
    });
  }

  void _backgroundBuildStep(int generation) {
    final paginator = _paginator;
    if (paginator == null || paginator.complete) return;
    final stopwatch = Stopwatch()..start();
    while (!paginator.complete && stopwatch.elapsedMilliseconds < 8) {
      paginator.buildMore(maxItems: 4);
    }
    if (!_isCurrent(generation)) return;
    setState(() {});
    if (!paginator.complete) _scheduleBackgroundBuild(generation);
  }

  /// 正文最终样式：与 [Text] 内部一致地把主题样式合并到 DefaultTextStyle
  /// 上。分页测量与页面渲染必须共用同一份样式，否则行高/换行会漂移。
  TextStyle _bodyStyle(BuildContext context) =>
      DefaultTextStyle.of(context).style.merge(
        Theme.of(context).textTheme.bodyLarge!.copyWith(
          color: widget.palette.foreground,
          fontSize: widget.settings.fontSize,
          height: widget.settings.lineHeight,
        ),
      );

  TextStyle _titleStyle(BuildContext context) =>
      DefaultTextStyle.of(context).style.merge(
        Theme.of(context).textTheme.headlineSmall?.copyWith(
          color: widget.palette.foreground,
        ) ??
        const TextStyle(),
      );

  NovelPaginationSpec _spec(Size size, EdgeInsets contentPadding) {
    final metrics = novelPageMetricsFor(size, contentPadding);
    return NovelPaginationSpec(
      textStyle: _bodyStyle(context),
      titleStyle: _titleStyle(context),
      textScaler: _textScaler ?? TextScaler.noScaling,
      textDirection: Directionality.of(context),
      size: Size(
        metrics.width,
        math.max(0, size.height - contentPadding.vertical),
      ),
      viewportHeight: size.height,
      contentTopInset: contentPadding.top,
      paragraphSpacing: widget.settings.paragraphSpacing,
      titleSpacing: AppSpacing.xxl,
      emptyChapterText: widget.emptyChapterText,
      markerSpacing: AppSpacing.sm,
      markerSize: AppIconSize.md,
      markerColor: widget.palette.foreground,
      isMarked: (paragraph) =>
          widget.isBookmarkedParagraph?.call(paragraph) ?? false,
    );
  }

  // ── 翻页 ──

  void _replaceController(int initialPage) {
    final old = _controller;
    _controller = PageController(initialPage: initialPage);
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  void _jumpToPage(int page, {required bool animate}) {
    if (!_controller.hasClients) {
      _replaceController(page);
      return;
    }
    if (animate) {
      unawaited(
        _controller.animateToPage(
          page,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        ),
      );
    } else {
      _controller.jumpToPage(page);
    }
  }

  void _turn({required bool forward}) {
    final paginator = _paginator;
    if (_restoring || paginator == null) return;
    final target = _currentPage + (forward ? 1 : -1);
    if (target < 0) {
      widget.onBoundary?.call(false);
      return;
    }
    if (target >= paginator.pages.length) {
      // 后台分页未完成：同步补齐目标页；仍不足说明已到卷末。
      while (target >= paginator.pages.length && paginator.buildMore()) {}
      if (target >= paginator.pages.length) {
        widget.onBoundary?.call(true);
        return;
      }
      setState(() {});
    }
    _jumpToPage(target, animate: !widget.settings.instantPageTurn);
  }

  void _onPageChanged(int page) {
    _currentPage = page;
    if (_restoring) return;
    _emitPosition();
    widget.onPageTurned?.call();
  }

  // ── 滑动越过卷首/卷末 ──

  /// PageView 在首尾页只会回弹（不产生翻页事件），需按卷界处理，
  /// 与漫画一致：overscroll 的符号只取决于方向（>0 前翻、<0 回翻）。
  /// 走 [_turn] 而不是直接回调：后台分页未完成时先补齐页面再前进。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _boundaryArmed = true;
    } else if (notification is ScrollEndNotification) {
      _boundaryArmed = false;
    } else if (notification is OverscrollNotification &&
        _boundaryArmed &&
        !_restoring &&
        notification.overscroll.abs() > 1) {
      _boundaryArmed = false;
      _turn(forward: notification.overscroll > 0);
    }
    return false;
  }

  NovelReaderLocation? _locationForPage(int page) {
    final paginator = _paginator;
    if (paginator == null || page < 0 || page >= paginator.pages.length) {
      return null;
    }
    return paginator.locationForPage(page);
  }

  void _emitPosition() {
    final location = _locationForPage(_currentPage);
    if (location == null) return;
    _lastLocation = location;
    widget.onPosition(location);
  }

  void _handleTap(Offset globalPosition) {
    if (_restoring) return;
    final box = context.findRenderObject() as RenderBox?;
    final width = _size?.width ?? box?.size.width ?? 0;
    if (box == null || width <= 0) return;
    final x = box.globalToLocal(globalPosition).dx;
    if (x < width / 3) {
      _turn(forward: false);
    } else if (x > width * 2 / 3) {
      _turn(forward: true);
    } else {
      widget.onTap();
    }
  }

  // ── 无动画翻页拖动（与漫画一致：越过约 1/5 视口即翻一页） ──

  void _onInstantTurnDragStart(DragStartDetails details) {
    _instantTurnDelta = 0;
    _instantTurnCommitted = false;
  }

  void _onInstantTurnDragUpdate(DragUpdateDetails details) {
    if (_instantTurnCommitted || _restoring) return;
    _instantTurnDelta += details.delta.dx;
    final width = _size?.width ?? MediaQuery.sizeOf(context).width;
    if (_instantTurnDelta.abs() >= width * 0.2) {
      _instantTurnCommitted = true;
      _turn(forward: _instantTurnDelta < 0);
    }
  }

  void _onInstantTurnDragEnd(DragEndDetails details) {
    _instantTurnDelta = 0;
    _instantTurnCommitted = false;
  }

  void _onInstantTurnDragCancel() {
    _instantTurnDelta = 0;
    _instantTurnCommitted = false;
  }

  @override
  void dispose() {
    ++_generation;
    _buildTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final contentPadding = widget.contentPadding;
        final sizeChanged = _size != size;
        final paddingChanged = _contentPadding != contentPadding;
        _size = size;
        _contentPadding = contentPadding;
        if (sizeChanged || paddingChanged) {
          final anchor = _paginator == null ? widget.target : _anchorNow();
          _scheduleRepaginate(anchor);
        }
        final paginator = _paginator;
        if (paginator == null) return const SizedBox.expand();
        final metrics = novelPageMetricsFor(size, contentPadding);
        final instant = widget.settings.instantPageTurn;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            contentPadding.left + metrics.horizontalPadding,
            contentPadding.top,
            contentPadding.right + metrics.horizontalPadding,
            contentPadding.bottom,
          ),
          child: AbsorbPointer(
            absorbing: _restoring,
            child: Listener(
              onPointerDown: (_) {
                _instantTurnDelta = 0;
                _instantTurnCommitted = false;
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScrollNotification,
                child: GestureDetector(
                  key: const ValueKey('novel-page-surface'),
                  behavior: HitTestBehavior.translucent,
                  onTapUp: (details) => _handleTap(details.globalPosition),
                  onHorizontalDragStart: instant
                      ? _onInstantTurnDragStart
                      : null,
                  onHorizontalDragUpdate: instant
                      ? _onInstantTurnDragUpdate
                      : null,
                  onHorizontalDragEnd: instant ? _onInstantTurnDragEnd : null,
                  onHorizontalDragCancel: instant
                      ? _onInstantTurnDragCancel
                      : null,
                  child: PageView.builder(
                    key: const ValueKey('novel-reader-pages'),
                    controller: _controller,
                    itemCount: paginator.pages.length,
                    onPageChanged: _onPageChanged,
                    physics: instant
                        ? const NeverScrollableScrollPhysics()
                        : null,
                    itemBuilder: _buildPage,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPage(BuildContext context, int index) {
    final paginator = _paginator!;
    final page = paginator.pages[index];
    final foreground = widget.palette.foreground;
    final style = _bodyStyle(context);
    final children = <Widget>[];
    final slices = page.slices;
    for (var sliceIndex = 0; sliceIndex < slices.length; sliceIndex++) {
      final slice = slices[sliceIndex];
      final isLastOfPage = sliceIndex == slices.length - 1;
      final paragraph = widget.document.paragraphAt(slice.itemIndex);
      final entry = paragraph.entry;
      if (slice.hasTitle) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
            child: Text(entry.name, style: _titleStyle(context)),
          ),
        );
      }
      final display = novelParagraphDisplayText(
        paragraph,
        widget.emptyChapterText,
      );
      final start = slice.startOffset.clamp(0, display.length);
      final end = slice.endOffset.clamp(start, display.length);
      final isFinalSlice = end >= display.length;
      final marked =
          isFinalSlice &&
          (widget.isBookmarkedParagraph?.call(paragraph) ?? false);
      final span = buildNovelParagraphSpan(
        text: display.substring(start, end),
        marked: marked,
        markerSpacing: AppSpacing.sm,
        markerSize: AppIconSize.md,
        markerColor: foreground,
        markerChild: marked
            ? GestureDetector(
                key: ValueKey(
                  'novel-page-marker-${entry.entryIndex}-'
                  '${paragraph.paragraphIndex}',
                ),
                onTap: () => widget.onBookmarkMarkerTap?.call(paragraph),
                child: Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.sm),
                  child: Icon(
                    Icons.bookmark,
                    size: AppIconSize.md,
                    color: foreground,
                  ),
                ),
              )
            : null,
      );
      Widget body = Text.rich(
        span,
        style: style,
        textScaler: _textScaler,
        textWidthBasis: TextWidthBasis.parent,
      );
      final highlighted =
          slice.startLine == 0 &&
          widget.highlight != null &&
          widget.highlight!.entryIndex == entry.entryIndex &&
          widget.highlight!.paragraphIndex == paragraph.paragraphIndex;
      if (highlighted) {
        body = DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: foreground, width: 2),
            borderRadius: AppRadius.smR,
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
      children.add(
        Padding(
          key: ValueKey(
            'novel-page-${entry.entryIndex}-${paragraph.paragraphIndex}-'
            '${slice.startLine}',
          ),
          // 段距是段与段之间的分隔，页面末尾不需要：分页测量已把段距
          // 计入页高，若最后一个片段再加一次，渲染会高出页面（溢出）。
          padding: EdgeInsets.only(
            bottom: isFinalSlice && !isLastOfPage
                ? widget.settings.paragraphSpacing
                : 0,
          ),
          child: body,
        ),
      );
    }
    return Align(
      alignment: Alignment.topLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

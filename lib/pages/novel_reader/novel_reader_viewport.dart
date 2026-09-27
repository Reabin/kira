import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../l10n/app_localizations.dart';
import '../../models/novel_reader_settings.dart';
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
    this.onScroll,
  });

  final NovelReaderDocument document;
  final NovelReaderSettings settings;
  final NovelReaderPalette palette;
  final NovelReaderAnchor target;
  final int jumpRevision;
  final ValueChanged<NovelReaderLocation> onPosition;
  final VoidCallback onTap;
  final VoidCallback? onScroll;

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

  /// Null during any restoration: callers may flush their last valid snapshot,
  /// but must not replace it with a transient layout position.
  NovelReaderLocation? get currentLocation =>
      _restoring ? null : _readPosition();

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
    if (oldWidget.jumpRevision != widget.jumpRevision) {
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
          : ((first.index + fraction) / widget.document.itemCount).clamp(0, 1),
    );
  }

  void _onPositions() {
    if (!mounted || _restoring) return;
    final location = _readPosition();
    if (location == null) return;
    _lastLocation = location;
    widget.onPosition(location);
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
                  padding: EdgeInsets.symmetric(
                    horizontal: math.max(
                      AppSpacing.xxl,
                      (size.width - 720) / 2,
                    ),
                  ),
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
          if (entry.paragraphs.isEmpty)
            Text(l10n.novelReaderEmptyChapter, style: style)
          else
            // An empty source line is a real paragraph, not something to trim.
            Text(paragraph.text.isEmpty ? ' ' : paragraph.text, style: style),
        ],
      ),
    );
    // Leave room to put even a short final paragraph at the top. Without it,
    // the list clamps a jump near EOF backwards into the preceding chapter or
    // illustration, and the next saved anchor would silently be wrong.
    return index == widget.document.itemCount - 1
        ? ConstrainedBox(
            constraints: BoxConstraints(minHeight: _size?.height ?? 0),
            child: child,
          )
        : child;
  }
}

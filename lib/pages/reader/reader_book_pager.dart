import 'package:flutter/material.dart';

import '../../theme/reader_chrome.dart';
import '../../widgets/novel_page_curl.dart';

/// Keeps PageView's gestures, controller and page callbacks, replacing only its
/// moving pixels. Settled pages remain the original interactive image widgets.
class ReaderBookPager extends StatelessWidget {
  const ReaderBookPager({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.pageBuilder,
    required this.doublePage,
    required this.reverse,
    required this.axis,
    required this.enabled,
    required this.child,
  });

  final PageController controller;
  final int itemCount;
  final IndexedWidgetBuilder pageBuilder;
  final bool doublePage;
  final bool reverse;
  final Axis axis;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    child: child,
    builder: (context, pageView) {
      final page =
          controller.hasClients && controller.position.hasContentDimensions
          ? controller.page ?? controller.initialPage.toDouble()
          : controller.initialPage.toDouble();
      final lower = page.floor();
      final progress = page - lower;
      final turning =
          enabled &&
          lower >= 0 &&
          lower + 1 < itemCount &&
          progress > 0.0001 &&
          progress < 0.9999;
      return Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(
            excluding: turning,
            child: Opacity(opacity: turning ? 0 : 1, child: pageView),
          ),
          if (turning)
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: ReaderBookTransition(
                    key: ValueKey('reader-book-turn-$lower'),
                    progress: progress,
                    doublePage: doublePage,
                    reverse: reverse,
                    axis: axis,
                    before: () => pageBuilder(context, lower),
                    after: () => pageBuilder(context, lower + 1),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// A single sheet curls; a spread turns one leaf around the book's centre.
/// Builders supply independent elements for the front, back and stationary
/// leaves. ImageProvider continues to share decoded images through ImageCache.
class ReaderBookTransition extends StatelessWidget {
  const ReaderBookTransition({
    super.key,
    required this.progress,
    required this.doublePage,
    required this.reverse,
    required this.axis,
    required this.before,
    required this.after,
  });

  final double progress;
  final bool doublePage;
  final bool reverse;
  final Axis axis;
  final Widget Function() before;
  final Widget Function() after;

  Widget _unmirror(Widget child) => Transform.flip(flipX: true, child: child);

  @override
  Widget build(BuildContext context) {
    if (doublePage) return _spread();
    final vertical = axis == Axis.vertical;
    Widget content(Widget child) {
      if (vertical) return RotatedBox(quarterTurns: -1, child: child);
      return reverse ? _unmirror(child) : child;
    }

    Widget curl = NovelPageCurl(
      animation: AlwaysStoppedAnimation(progress),
      forward: true,
      originY: 0.85,
      paperColor: ReaderChrome.surface,
      turningPage: content(before()),
      turningPageBack: content(before()),
      underneath: content(after()),
    );
    if (vertical) return RotatedBox(quarterTurns: 1, child: curl);
    if (reverse) curl = _unmirror(curl);
    return curl;
  }

  Widget _spread() => SpreadPageCurl(
    progress: progress,
    reverse: reverse,
    paperColor: ReaderChrome.surface,
    before: before,
    after: after,
  );
}

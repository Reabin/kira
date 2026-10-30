part of '../reader_page.dart';

extension _ReaderPageMode on _ReaderPageState {
  bool get _pageTurnAnimationsDisabled =>
      _user.readerInstantPageTurn || prefersReducedMotion(context);

  ReaderSpreadLayout get _spreadLayout => ReaderSpreadLayout(
    _chain.map((chapter) => chapter.contents.length).toList(),
    pagesPerSpread: _pagesPerSpread,
  );
  int _pageIndexForImage(int globalImage) =>
      _spreadLayout.spreadForImage(globalImage.clamp(0, _chainImageCount));
  int get _visibleFirstPage =>
      ((_currentPage - 1) ~/ _pagesPerSpread) * _pagesPerSpread + 1;
  int get _visibleLastPage => (_visibleFirstPage + _pagesPerSpread - 1).clamp(
    1,
    _detail?.contents.length ?? 1,
  );

  void _prevPage() {
    if (_detail == null) return;
    final previousPage = _visibleFirstPage - _pagesPerSpread;
    if (previousPage >= 1 || _chainIndex > 0) {
      // 连续阅读：已到当前章首页但前面还有拼接的章节 -> 回到上一章末页
      if (previousPage < 1 && _chainIndex > 0 && _continuousReading) {
        final prevChapter = _chain[_chainIndex - 1];
        final prevChapterStart = _chainChapterStart(_chainIndex - 1);
        final targetGlobal = prevChapterStart + prevChapter.contents.length - 1;
        _syncActiveChapterFromGlobal(_chainIndex - 1);
        _currentPage = prevChapter.contents.length;
        _jumpPageControllerTo(targetGlobal);
        _setState(() {});
        _saveReadingHistory();
        return;
      }
      _goToPage(previousPage);
    } else if (_detail!.prev != null && !_continuousReading) {
      _goChapter(_detail!.prev);
    } else if (_detail!.prev != null && _continuousReading) {
      // 链首之前还有上一话：拼接上一话后跳到其末页，
      // 与链中从下一话首页上翻回上一话末页的行为一致。
      final prevUuid = _detail!.prev!;
      if (_loadingPrevChainChapter) {
        showToast(
          context,
          AppLocalizations.of(context)!.readerLoadingPrevChapter,
        );
        return;
      }
      unawaited(
        _prependPrevChapterToChain().then((prepended) {
          if (!mounted) return;
          if (!prepended) {
            // 拼接失败：降级为整章跳转（重新加载）
            _goChapter(prevUuid);
            return;
          }
          final prevChapter = _chain.first;
          final targetGlobal =
              _chainChapterStart(0) + prevChapter.contents.length - 1;
          _syncActiveChapterFromGlobal(0);
          _currentPage = prevChapter.contents.length;
          if (_isPageMode) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _jumpPageControllerTo(targetGlobal);
            });
          }
          _setState(() {});
          _saveReadingHistory();
        }),
      );
    } else {
      showToast(context, AppLocalizations.of(context)!.readerNoPreviousChapter);
    }
  }

  /// 翻页模式辅助：按设置跳转到全局页索引（无动画/带动画），无 client 时静默跳过。
  void _jumpPageControllerTo(int globalIndex) {
    if (!_isPageMode || !_pageController.hasClients) return;
    if (_pageTurnAnimationsDisabled) {
      _pageController.jumpToPage(_pageIndexForImage(globalIndex));
    } else {
      _pageController.animateToPage(
        _pageIndexForImage(globalIndex),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _nextPage() {
    if (_detail == null) return;
    final imageCount = _detail!.contents.length;
    if (_visibleLastPage < imageCount) {
      _goToPage(_visibleLastPage + 1);
      return;
    }
    // 已到当前章末页
    if (_continuousReading) {
      // 链中后续章节已拼接 -> 直接进入下一章首页
      if (_chainIndex < _chain.length - 1) {
        final nextChapterStart = _chainChapterStart(_chainIndex + 1);
        _syncActiveChapterFromGlobal(_chainIndex + 1);
        _currentPage = 1;
        if (_isPageMode) {
          _jumpPageControllerTo(nextChapterStart);
        }
        _setState(() {});
        _saveReadingHistory();
        return;
      }
      // 链尾且还有下一话 -> 追加后跳到新章首页
      final nextUuid = _chain.last.next;
      if (nextUuid != null && !_loadingNextChainChapter) {
        _appendNextChapterToChain().then((_) {
          if (!mounted) return;
          final newChapterIdx = _chain.length - 1;
          final newStart = _chainChapterStart(newChapterIdx);
          _syncActiveChapterFromGlobal(newChapterIdx);
          _currentPage = 1;
          if (_isPageMode) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _jumpPageControllerTo(newStart);
            });
          }
          _setState(() {});
          _saveReadingHistory();
        });
        return;
      }
      if (_loadingNextChainChapter) {
        showToast(
          context,
          AppLocalizations.of(context)!.readerLoadingNextChapter,
        );
        return;
      }
      // 最后一话：跳转到末尾空白页（触发返回目录）
      if (_isPageMode && _pageController.hasClients) {
        final blankPageIndex = _spreadLayout.spreadCount;
        if (_pageTurnAnimationsDisabled) {
          _pageController.jumpToPage(blankPageIndex);
        } else {
          _pageController.animateToPage(
            blankPageIndex,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
      }
      return;
    }
  }

  /// 翻到指定页码（1-based，当前章内页码）。开启「无动画翻页」时瞬时切换，否则带过渡动画。
  void _goToPage(int page) {
    if (!_pageController.hasClients) return;
    final globalIndex = _continuousReading
        ? _chainChapterStart(_chainIndex) + (page - 1)
        : page;
    if (_pageTurnAnimationsDisabled) {
      _pageController.jumpToPage(_pageIndexForImage(globalIndex));
      return;
    }
    _pageController.animateToPage(
      _pageIndexForImage(globalIndex),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  // ── 翻页模式 ──

  void _handlePageModeTapAt(Offset globalPosition) {
    if (_flingBrakeGuard.consumeTap()) return;
    if (_isVerticalPageMode) {
      final screenHeight = MediaQuery.of(context).size.height;
      final y = globalPosition.dy;
      if (y < screenHeight / 3) {
        _prevPage();
      } else if (y > screenHeight * 2 / 3) {
        _nextPage();
      } else {
        _toggleToolbar();
      }
      return;
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final x = globalPosition.dx;
    if (x < screenWidth / 3) {
      _user.readerScrollDirection == 1 ? _nextPage() : _prevPage();
    } else if (x > screenWidth * 2 / 3) {
      _user.readerScrollDirection == 1 ? _prevPage() : _nextPage();
    } else {
      _toggleToolbar();
    }
  }

  /// 拖动位移是否代表"向下一页前进"。
  /// 左到右: 向左拖前进; 右到左: 向右拖前进; 垂直: 向上拖前进（与 PageView 一致）。
  bool _instantTurnForward(double delta) {
    if (_isVerticalPageMode) return delta < 0;
    final rtl = _user.readerScrollDirection == 1;
    return rtl ? delta > 0 : delta < 0;
  }

  void _onInstantTurnDragStart(DragStartDetails details) {
    _instantTurnDragDelta = 0;
    _instantTurnCommitted = false;
  }

  void _onInstantTurnDragUpdate(DragUpdateDetails details) {
    if (_instantTurnCommitted || _detail == null) return;
    _instantTurnDragDelta += _isVerticalPageMode
        ? details.delta.dy
        : details.delta.dx;
    final viewport = _isVerticalPageMode
        ? MediaQuery.sizeOf(context).height
        : MediaQuery.sizeOf(context).width;
    // 越过视口约五分之一即翻页；一次拖动只翻一页，抬手后才能再翻。
    if (_instantTurnDragDelta.abs() >= viewport * 0.2) {
      _instantTurnCommitted = true;
      if (_instantTurnForward(_instantTurnDragDelta)) {
        _nextPage();
      } else {
        _prevPage();
      }
    }
  }

  void _onInstantTurnDragEnd(DragEndDetails details) {
    _instantTurnDragDelta = 0;
    _instantTurnCommitted = false;
  }

  void _onInstantTurnDragCancel() {
    _instantTurnDragDelta = 0;
    _instantTurnCommitted = false;
  }

  Widget _buildPageMode() {
    final instantTurn = _pageTurnAnimationsDisabled;
    // 当前页被捏合放大时锁定翻页手势：单指拖动交给图片平移，收拢回
    // 1x 后由 _handlePageZoomChanged 触发重建恢复。
    final turnGesturesLocked = _pageImageZoomed;
    final horizontalDrag =
        instantTurn && !_isVerticalPageMode && !turnGesturesLocked;
    final verticalDrag =
        instantTurn && _isVerticalPageMode && !turnGesturesLocked;
    final layout = _spreadLayout;
    final viewVersion = _scrollWidgetVersion;
    final totalChapters = layout.spreadCount;
    // 最后一话无下一话时，末尾追加一个空白页用于返回目录
    final hasEndBlank = _chain.last.next == null;
    final itemCount = totalChapters + (hasEndBlank ? 1 : 0);
    Widget buildPage(BuildContext context, int i) {
      // 末尾空白页
      if (hasEndBlank && i == totalChapters) {
        return const SizedBox.expand();
      }
      final images = layout.imagesForSpread(i);
      final (ci, li) = _resolveChainImage(images.first);
      final chapter = _chain[ci];
      final lastLocal = images.last - _chainChapterStart(ci);
      final isChapterLastPage = lastLocal == chapter.contents.length - 1;
      final currentImage = _chainChapterStart(_chainIndex) + _currentPage - 1;
      final zoomActive =
          currentImage >= images.first && currentImage <= images.last;
      Widget pageImage(int globalImage) {
        final (_, local) = _resolveChainImage(globalImage);
        return Center(
          child: _buildReaderImageGesture(
            chapter,
            local,
            retryKey: globalImage,
            zoomActive: zoomActive,
          ),
        );
      }

      final child = _pagesPerSpread == 1
          ? pageImage(images.first)
          : Row(
              key: ValueKey('reader-spread-${chapter.uuid}-$li'),
              textDirection: _user.readerScrollDirection == 1
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              children: [
                Expanded(child: pageImage(images.first)),
                Expanded(
                  child: images.last > images.first
                      ? pageImage(images.last)
                      : const SizedBox.expand(),
                ),
              ],
            );
      if (isChapterLastPage) {
        return Column(
          children: [
            Expanded(child: child),
            _PageModeEndActions(
              hasNext: chapter.next != null,
              commentCount: _commentCountFor(chapter),
              onCatalog: _exitToCatalog,
              onComments: () => _showChapterComments(chapter: chapter),
              onNextChapter: chapter.next != null
                  ? () => _goChapter(chapter.next)
                  : null,
            ),
          ],
        );
      }
      return child;
    }

    final pageView = NotificationListener<ScrollNotification>(
      onNotification: (n) {
        _recordFlingBrakeScroll(n);
        // 回翻意图才拼接上一话（竖向上拖 / 横向反向拖，均产生 overscroll < 0，
        // 符号只取决于滚动轴方向与 reverse 无关）。进入一话不预取，章节数据
        // 请求数与不预取时一致：翻回第一页由 onPageChanged 触发，在第一页
        // 立即回翻由这里触发。无动画翻页模式拖动走 _prevPage，无此通知。
        if (n is OverscrollNotification && n.overscroll < 0) {
          _maybePrependPrevForPageMode();
        }
        return false;
      },
      child: GestureDetector(
        onTapUp: (details) => _handlePageModeTapAt(details.globalPosition),
        onHorizontalDragStart: horizontalDrag ? _onInstantTurnDragStart : null,
        onHorizontalDragUpdate: horizontalDrag
            ? _onInstantTurnDragUpdate
            : null,
        onHorizontalDragEnd: horizontalDrag ? _onInstantTurnDragEnd : null,
        onHorizontalDragCancel: horizontalDrag
            ? _onInstantTurnDragCancel
            : null,
        onVerticalDragStart: verticalDrag ? _onInstantTurnDragStart : null,
        onVerticalDragUpdate: verticalDrag ? _onInstantTurnDragUpdate : null,
        onVerticalDragEnd: verticalDrag ? _onInstantTurnDragEnd : null,
        onVerticalDragCancel: verticalDrag ? _onInstantTurnDragCancel : null,
        child: PageView.builder(
          // 连续阅读：章切换不重建 PageView，避免丢位置；用稳定 key。
          key: ValueKey('page-continuous-$_scrollWidgetVersion'),
          controller: _pageController,
          scrollDirection: _isVerticalPageMode
              ? Axis.vertical
              : Axis.horizontal,
          reverse: !_isVerticalPageMode && _user.readerScrollDirection == 1,
          allowImplicitScrolling: true,
          physics: instantTurn || turnGesturesLocked
              ? const NeverScrollableScrollPhysics()
              : null,
          itemCount: itemCount,
          onPageChanged: (index) {
            if (viewVersion != _scrollWidgetVersion) return;
            // 末尾空白页：返回目录
            if (hasEndBlank && index == totalChapters) {
              if (!_autoAdvancingChapter) {
                _autoAdvancingChapter = true;
                _exitToCatalog();
              }
              return;
            }
            final range = layout.imagesForSpread(index);
            final requestedImage =
                _chainChapterStart(_chainIndex) + _currentPage - 1;
            final globalImage =
                _isDraggingSlider &&
                    requestedImage >= range.first &&
                    requestedImage <= range.last
                ? requestedImage
                : range.first;
            final (ci, li) = _resolveChainImage(globalImage);
            final chapterChanged = _syncActiveChapterFromGlobal(ci);
            _setState(() {
              _currentPage = li + 1;
              // 跳页（滑块等）后当前页未放大，恢复翻页手势。
              _zoomedPageImages.clear();
              _pageImageZoomed = false;
              if (!_isDraggingSlider) {
                _showToolbar = false;
                SystemChrome.setEnabledSystemUIMode(
                  SystemUiMode.immersiveSticky,
                );
              }
            });
            _saveReadingHistory();
            _preloadChainImages(ci, li);
            // 接近链尾且有下一话：预加载下一话到链中，翻页时即可无缝衔接
            if (ci == _chain.length - 1 &&
                layout.imagesForSpread(index).last - _chainChapterStart(ci) >=
                    _chain.last.contents.length - 2 &&
                _chain.last.next != null &&
                !_loadingNextChainChapter) {
              _appendNextChapterToChain();
            }
            if (chapterChanged) {
              _preloadComments();
            }
            // 停在链首话第一页且还有上一话：预拼接上一话，让索引 0 之前有
            // 真实页面，拖动即可回翻（否则 PageView 无前页，拖动无响应）。
            _maybePrependPrevForPageMode();
          },
          itemBuilder: buildPage,
        ),
      ),
    );
    return Listener(
      onPointerDown: (_) => _flingBrakeGuard.onPointerDown(DateTime.now()),
      child: ReaderBookPager(
        key: ValueKey('reader-book-pager-$viewVersion'),
        controller: _pageController,
        itemCount: itemCount,
        pageBuilder: buildPage,
        doublePage: _pagesPerSpread == 2,
        reverse: _user.readerScrollDirection == 1,
        axis: _isVerticalPageMode ? Axis.vertical : Axis.horizontal,
        enabled:
            _user.reader.realisticPageTurn &&
            !instantTurn &&
            !turnGesturesLocked,
        child: pageView,
      ),
    );
  }
}

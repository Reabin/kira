part of '../comic_detail_page.dart';

extension _ComicDetailReadingActionsPart on _ComicDetailPageState {
  double get _readingActionsBottomPadding =>
      (_readingActionsHeight == 0 ? 0 : _readingActionsHeight + AppSpacing.lg) +
      AppSpacing.lg +
      MediaQuery.viewPaddingOf(context).bottom;

  void _measureReadingActions() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final height = _readingActionsKey.currentContext?.size?.height ?? 0;
      if (height == _readingActionsHeight) return;
      _setState(() => _readingActionsHeight = height);
    });
  }

  Widget _buildReadingActions() {
    final hasDownloads = _downloads
        .downloadedChapterIds(widget.pathWord)
        .isNotEmpty;
    final availableWidth = MediaQuery.sizeOf(context).width - AppSpacing.lg * 2;
    return Positioned(
      right: AppSpacing.lg,
      bottom: AppSpacing.lg,
      child: SafeArea(
        top: false,
        left: false,
        right: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: availableWidth),
          child: ComicDetailReadingActions(
            key: _readingActionsKey,
            continueLabel: _continueReadingLabel(),
            onContinue: _canShowLastBrowseAction ? _continueReading : null,
            nextLabel: _nextBrowseChapter == null
                ? null
                : _truncateNextChapterName(_nextBrowseChapter!.name),
            onNext: _nextBrowseChapter == null ? null : _readNextChapter,
            onDownloads: hasDownloads
                ? () => context
                      .pushNamed(AppRoutes.downloadCenter)
                      .then((_) => _handleDownloadChanged())
                : null,
          ),
        ),
      ),
    );
  }

  void _continueReading() {
    context
        .pushNamed(
          AppRoutes.reader,
          pathParameters: {
            'pathWord': widget.pathWord,
            'chapterUuid': _lastBrowseId!,
          },
          extra: ReaderExtra(
            comicName: _comic?.name,
            group: _selectedGroup,
            chapterName: _lastBrowseName ?? '',
            chapterListPage: _lastBrowseReaderChapterListPage,
            initialPage: _lastBrowsePage,
          ),
        )
        .then((_) => _loadLocalHistory());
  }

  void _readNextChapter() {
    final chapter = _nextBrowseChapter!;
    context
        .pushNamed(
          AppRoutes.reader,
          pathParameters: {
            'pathWord': widget.pathWord,
            'chapterUuid': chapter.uuid,
          },
          extra: ReaderExtra(
            comicName: _comic?.name,
            group: _selectedGroup,
            chapterName: chapter.name,
            chapterListPage: _nextBrowseChapterListPage ?? _chapterPage,
          ),
        )
        .then((_) => _loadLocalHistory());
  }
}

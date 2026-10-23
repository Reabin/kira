part of '../download_center_page.dart';

class _UnifiedDownloadQueueView extends StatefulWidget {
  const _UnifiedDownloadQueueView({
    required this.comicDownloads,
    required this.novelDownloads,
  });

  final DownloadManager comicDownloads;
  final NovelDownloadManager novelDownloads;

  @override
  State<_UnifiedDownloadQueueView> createState() =>
      _UnifiedDownloadQueueViewState();
}

class _UnifiedDownloadQueueViewState extends State<_UnifiedDownloadQueueView> {
  _QueueFilter _filter = _QueueFilter.all;
  final Set<String> _selectedNovelKeys = {};
  final Set<String> _selectedComicKeys = {};

  @override
  void initState() {
    super.initState();
    widget.comicDownloads.addListener(_changed);
    widget.novelDownloads.addListener(_changed);
  }

  @override
  void dispose() {
    widget.comicDownloads.removeListener(_changed);
    widget.novelDownloads.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final validNovelKeys = widget.novelDownloads.tasks.map(_novelKey).toSet();
    final validComicKeys = widget.comicDownloads.tasks.map(_comicKey).toSet();
    setState(() {
      _selectedNovelKeys.removeWhere((key) => !validNovelKeys.contains(key));
      _selectedComicKeys.removeWhere((key) => !validComicKeys.contains(key));
    });
  }

  String _novelKey(NovelDownloadTask task) =>
      '${task.pathWord}\n${task.volumeId}';
  String _comicKey(ComicDownloadTaskInfo task) =>
      '${task.pathWord}|||${task.chapterUuid}';

  bool get _isSelecting =>
      _selectedNovelKeys.isNotEmpty || _selectedComicKeys.isNotEmpty;

  List<NovelDownloadTask> get _selectedNovelTasks => widget.novelDownloads.tasks
      .where((task) => _selectedNovelKeys.contains(_novelKey(task)))
      .toList();

  List<ComicDownloadTaskInfo> get _selectedComicTasks => widget
      .comicDownloads
      .tasks
      .where((task) => _selectedComicKeys.contains(_comicKey(task)))
      .toList();

  List<NovelDownloadTask> get _novelTasks => switch (_filter) {
    _QueueFilter.all => widget.novelDownloads.tasks,
    _QueueFilter.downloading =>
      widget.novelDownloads.tasks
          .where((task) => task.status == NovelDownloadStatus.downloading)
          .toList(),
    _QueueFilter.paused =>
      widget.novelDownloads.tasks
          .where((task) => task.status == NovelDownloadStatus.paused)
          .toList(),
  };

  List<ComicDownloadTaskInfo> get _comicTasks => switch (_filter) {
    _QueueFilter.all => widget.comicDownloads.tasks,
    _QueueFilter.downloading =>
      widget.comicDownloads.tasks
          .where((task) => task.status == ComicDownloadTaskStatus.downloading)
          .toList(),
    _QueueFilter.paused =>
      widget.comicDownloads.tasks
          .where((task) => task.status == ComicDownloadTaskStatus.paused)
          .toList(),
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final comicTasks = _comicTasks;
    final novelTasks = _novelTasks;
    final allTotal =
        widget.comicDownloads.tasks.length + widget.novelDownloads.tasks.length;
    final total = comicTasks.length + novelTasks.length;
    return Column(
      children: [
        _filterBar(context, l10n),
        if (_isSelecting) _selectionBar(context, l10n),
        Expanded(
          child: allTotal == 0
              ? _empty(context, l10n)
              : total == 0
              ? Center(child: Text(l10n.noContent))
              : ListView.separated(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.xs,
                    AppSpacing.lg,
                    88 + MediaQuery.paddingOf(context).bottom,
                  ),
                  itemCount: total,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, index) {
                    if (index < comicTasks.length) {
                      final task = comicTasks[index];
                      final key = _comicKey(task);
                      return _ComicQueueTaskCard(
                        task: task,
                        selected: _selectedComicKeys.contains(key),
                        selecting: _isSelecting,
                        onToggleSelect: () => _toggleComic(task),
                        onTogglePause: widget.comicDownloads.paused
                            ? null
                            : () => _toggleComicPause(task),
                        onDelete: () =>
                            unawaited(_confirmDeleteComic(context, task)),
                      );
                    }
                    final task = novelTasks[index - comicTasks.length];
                    final key = _novelKey(task);
                    return _NovelQueueTaskCard(
                      task: task,
                      selected: _selectedNovelKeys.contains(key),
                      selecting: _isSelecting,
                      onToggleSelect: () => _toggleNovel(task),
                      onTogglePause: widget.novelDownloads.paused
                          ? null
                          : () => _toggleNovelPause(task),
                      onRetry: () => unawaited(
                        widget.novelDownloads.retry(
                          task.pathWord,
                          task.volumeId,
                        ),
                      ),
                      onDelete: () =>
                          unawaited(_confirmDeleteNovel(context, task)),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _empty(BuildContext context, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.download_done_outlined,
            size: 56,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            l10n.downloadQueueEmpty,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(l10n.downloadQueueEmptyComicHint),
        ],
      ),
    );
  }

  Widget _filterBar(BuildContext context, AppLocalizations l10n) {
    final all =
        widget.comicDownloads.tasks.length + widget.novelDownloads.tasks.length;
    final downloading =
        widget.comicDownloads.tasks
            .where((task) => task.status == ComicDownloadTaskStatus.downloading)
            .length +
        widget.novelDownloads.tasks
            .where((task) => task.status == NovelDownloadStatus.downloading)
            .length;
    final paused =
        widget.comicDownloads.tasks
            .where((task) => task.status == ComicDownloadTaskStatus.paused)
            .length +
        widget.novelDownloads.tasks
            .where((task) => task.status == NovelDownloadStatus.paused)
            .length;

    final allPaused = _allDownloadsPaused;
    final hasVisibleTasks = _comicTasks.isNotEmpty || _novelTasks.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: SelectTile<_QueueFilter>(
                key: const ValueKey('download_queue_filter'),
                value: _filter,
                items: [
                  SelectItem(
                    _QueueFilter.all,
                    '${l10n.downloadQueueFilterAll} $all',
                  ),
                  SelectItem(
                    _QueueFilter.downloading,
                    '${l10n.downloadQueueFilterDownloading} $downloading',
                  ),
                  SelectItem(
                    _QueueFilter.paused,
                    '${l10n.downloadQueueFilterPaused} $paused',
                  ),
                ],
                onChanged: (filter) {
                  if (_filter == filter) return;
                  setState(() {
                    _filter = filter;
                    _selectedNovelKeys.clear();
                    _selectedComicKeys.clear();
                  });
                },
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          TextButton(
            key: const ValueKey('download_queue_pause'),
            onPressed: all == 0 ? null : _toggleDownloads,
            child: Text(
              all > 0 && allPaused
                  ? l10n.downloadQueueResume
                  : l10n.downloadQueuePause,
            ),
          ),
          TextButton(
            key: const ValueKey('download_queue_select_all'),
            onPressed: hasVisibleTasks ? _toggleSelectAll : null,
            child: Text(
              _allVisibleSelected
                  ? l10n.downloadQueueDeselectAll
                  : l10n.downloadQueueSelectAll,
            ),
          ),
        ],
      ),
    );
  }

  // 空队列不参与判断，避免另一类没有任务时遮蔽当前队列的暂停状态。
  bool get _allDownloadsPaused =>
      (widget.comicDownloads.tasks.isEmpty || widget.comicDownloads.paused) &&
      (widget.novelDownloads.tasks.isEmpty || widget.novelDownloads.paused);

  void _toggleDownloads() {
    if (_allDownloadsPaused) {
      widget.comicDownloads.resumeDownloads();
      unawaited(widget.novelDownloads.resumeDownloads());
    } else {
      widget.comicDownloads.pauseDownloads();
      unawaited(widget.novelDownloads.pauseDownloads());
    }
  }

  bool get _allVisibleSelected {
    final novels = _novelTasks;
    final comics = _comicTasks;
    final count = novels.length + comics.length;
    return count > 0 &&
        novels.every((task) => _selectedNovelKeys.contains(_novelKey(task))) &&
        comics.every((task) => _selectedComicKeys.contains(_comicKey(task)));
  }

  void _toggleSelectAll() {
    final novels = _novelTasks;
    final comics = _comicTasks;
    setState(() {
      if (_allVisibleSelected) {
        for (final task in novels) {
          _selectedNovelKeys.remove(_novelKey(task));
        }
        for (final task in comics) {
          _selectedComicKeys.remove(_comicKey(task));
        }
      } else {
        for (final task in novels) {
          _selectedNovelKeys.add(_novelKey(task));
        }
        for (final task in comics) {
          _selectedComicKeys.add(_comicKey(task));
        }
      }
    });
  }

  Widget _selectionBar(BuildContext context, AppLocalizations l10n) {
    final count = _selectedComicKeys.length + _selectedNovelKeys.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(child: Text('${l10n.downloadQueueSelect}: $count')),
          IconButton(
            tooltip: l10n.downloadPauseButton,
            onPressed: () => unawaited(_pauseSelected()),
            icon: const Icon(Icons.pause_rounded),
          ),
          IconButton(
            tooltip: l10n.downloadResumeButton,
            onPressed: () => unawaited(_resumeSelected()),
            icon: const Icon(Icons.play_arrow_rounded),
          ),
          IconButton(
            tooltip: l10n.downloadQueueDeleteSelected,
            onPressed: () => unawaited(_deleteSelected()),
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: l10n.cancelButton,
            onPressed: () => setState(() {
              _selectedNovelKeys.clear();
              _selectedComicKeys.clear();
            }),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  void _toggleComicPause(ComicDownloadTaskInfo task) {
    if (widget.comicDownloads.isChapterPaused(
      task.pathWord,
      task.chapterUuid,
    )) {
      widget.comicDownloads.resumeChapter(task.pathWord, task.chapterUuid);
    } else {
      widget.comicDownloads.pauseChapter(task.pathWord, task.chapterUuid);
    }
  }

  void _toggleComic(ComicDownloadTaskInfo task) {
    setState(() {
      final key = _comicKey(task);
      if (!_selectedComicKeys.remove(key)) _selectedComicKeys.add(key);
    });
  }

  void _toggleNovel(NovelDownloadTask task) {
    setState(() {
      final key = _novelKey(task);
      if (!_selectedNovelKeys.remove(key)) _selectedNovelKeys.add(key);
    });
  }

  void _toggleNovelPause(NovelDownloadTask task) {
    if (task.status == NovelDownloadStatus.paused) {
      unawaited(
        widget.novelDownloads.resumeVolume(task.pathWord, task.volumeId),
      );
    } else {
      unawaited(
        widget.novelDownloads.pauseVolume(task.pathWord, task.volumeId),
      );
    }
  }

  Future<void> _pauseSelected() async {
    for (final task in _selectedNovelTasks) {
      await widget.novelDownloads.pauseVolume(task.pathWord, task.volumeId);
    }
    if (widget.comicDownloads.paused) return;
    widget.comicDownloads.pauseChapters([
      for (final task in _selectedComicTasks)
        (pathWord: task.pathWord, chapterUuid: task.chapterUuid),
    ]);
  }

  Future<void> _resumeSelected() async {
    for (final task in _selectedNovelTasks) {
      await widget.novelDownloads.resumeVolume(task.pathWord, task.volumeId);
    }
    if (widget.comicDownloads.paused) return;
    widget.comicDownloads.resumeChapters([
      for (final task in _selectedComicTasks)
        (pathWord: task.pathWord, chapterUuid: task.chapterUuid),
    ]);
  }

  Future<void> _deleteSelected() async {
    final novels = _selectedNovelTasks;
    final comics = _selectedComicTasks;
    if (novels.isEmpty && comics.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          l10n.downloadQueueDeleteBatchTitle(novels.length + comics.length),
        ),
        content: Text(l10n.downloadQueueDeleteSelectedConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.deleteButton),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final task in novels) {
      await widget.novelDownloads.deleteVolume(task.pathWord, task.volumeId);
    }
    await widget.comicDownloads.deleteQueuedChapters([
      for (final task in comics)
        (pathWord: task.pathWord, chapterUuid: task.chapterUuid),
    ]);
    if (mounted) {
      setState(() {
        _selectedNovelKeys.clear();
        _selectedComicKeys.clear();
      });
    }
  }

  Future<void> _confirmDeleteNovel(
    BuildContext context,
    NovelDownloadTask task,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.deleteButton),
        content: Text(l10n.novelDownloadDeleteConfirm(task.volumeName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.deleteButton),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.novelDownloads.deleteVolume(task.pathWord, task.volumeId);
    }
  }

  Future<void> _confirmDeleteComic(
    BuildContext context,
    ComicDownloadTaskInfo task,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final count = await widget.comicDownloads.downloadedFileCountOf(
      task.pathWord,
      task.chapterUuid,
    );
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.downloadQueueDeleteTitle),
        content: Text(l10n.downloadQueueDeleteContent(task.chapterName, count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.deleteButton),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.comicDownloads.deleteQueuedChapter(
        task.pathWord,
        task.chapterUuid,
      );
    }
  }
}

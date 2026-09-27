import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/user_manager.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_status_colors.dart';
import '../utils/download_manager.dart';
import '../utils/novel_download_manager.dart';
import '../utils/toast.dart';
import '../widgets/download_settings_sheet.dart';
import '../widgets/select_tile.dart';
import 'local_comics_page.dart';
import 'local_novels_page.dart';

class DownloadCenterPage extends StatefulWidget {
  /// 0：漫画；1：轻小说；2：下载队列。
  /// 轻小说开关关闭时没有小说页：1 落到漫画，≥2 落到队列。
  final int initialTab;
  final DownloadManager? comicDownloads;
  final NovelDownloadManager? novelDownloads;

  const DownloadCenterPage({
    super.key,
    this.initialTab = 0,
    this.comicDownloads,
    this.novelDownloads,
  });

  @override
  State<DownloadCenterPage> createState() => _DownloadCenterPageState();
}

class _DownloadCenterPageState extends State<DownloadCenterPage>
    with TickerProviderStateMixin {
  TabController? _tabController;
  late final _comicDownloads = widget.comicDownloads ?? DownloadManager();
  late final _novelDownloads = widget.novelDownloads ?? NovelDownloadManager();
  late bool _showNovel;

  @override
  void initState() {
    super.initState();
    _showNovel = UserManager().showNovel;
    _tabController = _showNovel
        ? TabController(
            length: 3,
            vsync: this,
            initialIndex: widget.initialTab.clamp(0, 2),
          )
        : TabController(
            length: 2,
            vsync: this,
            initialIndex: widget.initialTab >= 2 ? 1 : 0,
          );
    _comicDownloads.addListener(_onQueueChanged);
    _novelDownloads.addListener(_onQueueChanged);
    unawaited(_novelDownloads.init());
  }

  @override
  void dispose() {
    _comicDownloads.removeListener(_onQueueChanged);
    _novelDownloads.removeListener(_onQueueChanged);
    _tabController?.dispose();
    super.dispose();
  }

  void _onQueueChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final controller = _tabController!;
    final queueCount =
        _comicDownloads.tasks.length + _novelDownloads.tasks.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.downloadCenterTitle),
        bottom: TabBar(
          controller: controller,
          tabs: [
            Tab(
              icon: const Icon(Icons.menu_book_outlined),
              text: l10n.comicLabel,
            ),
            if (_showNovel)
              Tab(
                icon: const Icon(Icons.auto_stories_outlined),
                text: l10n.novelTitle,
              ),
            Tab(
              icon: Badge(
                isLabelVisible: queueCount > 0,
                label: Text('$queueCount'),
                child: const Icon(Icons.downloading_outlined),
              ),
              text: l10n.downloadQueueTab,
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: controller,
        children: [
          LocalComicsPage(
            embedded: true,
            trailingAction: _settingsFab('download_settings_comic'),
          ),
          if (_showNovel)
            LocalNovelsPage(
              embedded: true,
              trailingAction: _settingsFab('download_settings_novel'),
            ),
          _buildQueueTab(),
        ],
      ),
    );
  }

  Widget _buildQueueTab() {
    final summary = _comicDownloads.lastBatchSummary;
    return Column(
      children: [
        if (summary != null)
          _BatchSummaryBanner(
            summary: summary,
            onRetry: _retryFailedBatch,
            onDismiss: _comicDownloads.clearBatchSummary,
          ),
        Expanded(
          child: _withSettingsFab(
            _UnifiedDownloadQueueView(
              comicDownloads: _comicDownloads,
              novelDownloads: _novelDownloads,
            ),
            'download_settings_queue',
          ),
        ),
      ],
    );
  }

  Future<void> _retryFailedBatch() async {
    final added = await _comicDownloads.retryFailedBatch();
    if (!mounted || added == 0) return;
    showToast(
      context,
      AppLocalizations.of(context)!.downloadBatchRequeued(added),
    );
  }

  /// 统一打开同一个下载设置面板（同时包含漫画与轻小说配置）。
  Widget _settingsFab(String heroTag) {
    return FloatingActionButton(
      heroTag: heroTag,
      tooltip: AppLocalizations.of(context)!.downloadSettingsTitle,
      onPressed: () => showDownloadSettingsSheet(
        context,
        downloads: _comicDownloads,
        novelDownloads: _novelDownloads,
      ),
      child: const Icon(Icons.settings_outlined),
    );
  }

  Widget _withSettingsFab(Widget child, String heroTag) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(right: 16, bottom: 16, child: _settingsFab(heroTag)),
      ],
    );
  }
}

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

class _NovelQueueTaskCard extends StatelessWidget {
  const _NovelQueueTaskCard({
    required this.task,
    required this.selected,
    required this.selecting,
    required this.onToggleSelect,
    required this.onTogglePause,
    required this.onRetry,
    required this.onDelete,
  });

  final NovelDownloadTask task;
  final bool selected;
  final bool selecting;
  final VoidCallback onToggleSelect;
  final VoidCallback? onTogglePause;
  final VoidCallback onRetry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final status = task.status;
    final canPause =
        status == NovelDownloadStatus.queued ||
        status == NovelDownloadStatus.downloading;
    final canResume = status == NovelDownloadStatus.paused;
    final canRetry = {
      NovelDownloadStatus.failed,
      NovelDownloadStatus.partial,
      NovelDownloadStatus.unauthorized,
      NovelDownloadStatus.locked,
      NovelDownloadStatus.needsRepair,
    }.contains(status);
    final progress = task.total > 0 ? task.progress.clamp(0.0, 1.0) : 0.0;

    return Card(
      color: selected ? cs.primaryContainer : cs.surfaceBright,
      child: InkWell(
        borderRadius: AppRadius.mdR,
        onTap: selecting ? onToggleSelect : null,
        onLongPress: selecting ? null : onToggleSelect,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (selecting) ...[
                    Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: selected ? cs.primary : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                  ],
                  _NovelTaskCover(task: task, colorScheme: cs),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.bookName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.labelMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          task.volumeName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          _statusText(l10n),
                          style: tt.labelSmall?.copyWith(
                            color: _statusColor(cs),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!selecting) ...[
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: canResume
                          ? l10n.downloadResumeButton
                          : l10n.downloadPauseButton,
                      onPressed: canPause || canResume ? onTogglePause : null,
                      icon: Icon(
                        canResume
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: canRetry ? l10n.retryButton : l10n.deleteButton,
                      onPressed: canRetry ? onRetry : onDelete,
                      icon: Icon(
                        canRetry ? Icons.refresh : Icons.delete_outline,
                      ),
                    ),
                  ],
                ],
              ),
              if (status == NovelDownloadStatus.downloading ||
                  status == NovelDownloadStatus.queued ||
                  status == NovelDownloadStatus.partial) ...[
                const SizedBox(height: AppSpacing.sm),
                ClipRRect(
                  borderRadius: AppRadius.xsR,
                  child: LinearProgressIndicator(value: progress),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${task.completed}/${task.total}',
                  style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _statusText(AppLocalizations l10n) => switch (task.status) {
    NovelDownloadStatus.queued => l10n.waitingStatus,
    NovelDownloadStatus.downloading => l10n.downloadingStatus,
    NovelDownloadStatus.paused => l10n.pausedStatus,
    NovelDownloadStatus.completed => l10n.novelDownloadCompleted,
    NovelDownloadStatus.partial => l10n.novelDownloadPartial,
    NovelDownloadStatus.failed => l10n.novelDownloadFailed,
    NovelDownloadStatus.unauthorized => l10n.novelDownloadUnauthorized,
    NovelDownloadStatus.locked => l10n.novelDownloadLocked,
    NovelDownloadStatus.needsRepair => l10n.novelDownloadNeedsRepair,
  };

  Color _statusColor(ColorScheme cs) => switch (task.status) {
    NovelDownloadStatus.completed => AppStatusColors.success(cs),
    NovelDownloadStatus.partial => AppStatusColors.warning(cs),
    NovelDownloadStatus.failed ||
    NovelDownloadStatus.unauthorized ||
    NovelDownloadStatus.locked ||
    NovelDownloadStatus.needsRepair => AppStatusColors.danger(cs),
    _ => AppStatusColors.neutral(cs),
  };
}

class _NovelTaskCover extends StatelessWidget {
  const _NovelTaskCover({required this.task, required this.colorScheme});

  final NovelDownloadTask task;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.auto_stories_outlined,
        color: colorScheme.onSurfaceVariant,
      ),
    );
    return ClipRRect(
      borderRadius: AppRadius.smR,
      child: SizedBox(
        width: 48,
        height: 64,
        child: task.book.cover.isEmpty
            ? placeholder
            : Image.network(
                task.book.cover,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

/// 批次下载结束后有失败章节时，在队列页顶部展示的提示条。
class _BatchSummaryBanner extends StatelessWidget {
  final DownloadBatchSummary summary;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  const _BatchSummaryBanner({
    required this.summary,
    required this.onRetry,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Material(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.xs,
          AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 20, color: cs.onErrorContainer),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                l10n.downloadBatchFailedCount(summary.failures.length),
                style: tt.bodyMedium?.copyWith(color: cs.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(foregroundColor: cs.onErrorContainer),
              child: Text(l10n.downloadBatchRetryAll),
            ),
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
              iconSize: 18,
              color: cs.onErrorContainer,
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            ),
          ],
        ),
      ),
    );
  }
}

enum _QueueFilter { all, downloading, paused }

/// 漫画任务卡：沿用原队列的多选、进度、暂停和删除交互。
class _ComicQueueTaskCard extends StatelessWidget {
  const _ComicQueueTaskCard({
    required this.task,
    required this.selected,
    required this.selecting,
    required this.onToggleSelect,
    required this.onTogglePause,
    required this.onDelete,
  });

  final ComicDownloadTaskInfo task;
  final bool selected;
  final bool selecting;
  final VoidCallback? onToggleSelect;
  final VoidCallback? onTogglePause;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Card(
      color: selected ? cs.primaryContainer : cs.surfaceBright,
      child: InkWell(
        borderRadius: AppRadius.mdR,
        onTap: selecting ? onToggleSelect : null,
        onLongPress: selecting ? null : onToggleSelect,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (selecting) ...[
                    Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 22,
                      color: selected ? cs.primary : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.comicName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.labelMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          task.chapterName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        _comicStatusLabel(context, cs, tt),
                      ],
                    ),
                  ),
                  if (!selecting) ...[
                    IconButton(
                      onPressed: onTogglePause,
                      visualDensity: VisualDensity.compact,
                      tooltip: task.status == ComicDownloadTaskStatus.paused
                          ? l10n.downloadResumeButton
                          : l10n.downloadPauseButton,
                      icon: Icon(
                        task.status == ComicDownloadTaskStatus.paused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                      ),
                    ),
                    IconButton(
                      onPressed: onDelete,
                      visualDensity: VisualDensity.compact,
                      tooltip: l10n.deleteButton,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ],
              ),
              if (task.status != ComicDownloadTaskStatus.pending &&
                  task.progress != null) ...[
                const SizedBox(height: AppSpacing.sm),
                ClipRRect(
                  borderRadius: AppRadius.xsR,
                  child: LinearProgressIndicator(value: task.progress!.ratio),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  task.progress!.failed > 0
                      ? l10n.downloadProgressPartial(
                          (task.progress!.ratio * 100).toStringAsFixed(0),
                          task.progress!.completed,
                          task.progress!.total,
                          task.progress!.failed,
                        )
                      : l10n.downloadProgressCount(
                          (task.progress!.ratio * 100).toStringAsFixed(0),
                          task.progress!.completed,
                          task.progress!.total,
                        ),
                  style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _comicStatusLabel(BuildContext context, ColorScheme cs, TextTheme tt) {
    final l10n = AppLocalizations.of(context)!;
    final isDownloading = task.status == ComicDownloadTaskStatus.downloading;
    final isPaused = task.status == ComicDownloadTaskStatus.paused;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isDownloading)
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: cs.primary,
            ),
          )
        else
          Icon(
            isPaused ? Icons.pause_circle_outline : Icons.schedule,
            size: 14,
            color: cs.onSurfaceVariant,
          ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          isDownloading
              ? l10n.downloadingStatus
              : isPaused
              ? l10n.pausedStatus
              : l10n.waitingStatus,
          style: tt.labelSmall?.copyWith(
            color: isDownloading ? cs.primary : cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

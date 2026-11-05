part of '../download_center_page.dart';

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
              // 失败原因一直存在 task.error 里却从未展示过；用户只能看到
              // 「下载失败」四个字，既无法判断原因也无法反馈。
              if (task.error != null && task.error!.trim().isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  task.error!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: tt.labelSmall?.copyWith(color: cs.error),
                ),
              ],
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

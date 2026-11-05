part of '../novel_detail_page.dart';

extension _NovelDetailSliversPart on _NovelDetailPageState {
  List<Widget> _buildInfoSlivers(ColorScheme cs, TextTheme tt, NovelBook book) {
    final l10n = AppLocalizations.of(context)!;
    final authors = book.authors
        .where((author) => author.name.trim().isNotEmpty)
        .toList();
    final statusLabel = _statusLabel(book);

    return [
      // ── 轻小说信息卡片 ──
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCover(book),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tt.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (authors.isNotEmpty ||
                        statusLabel.isNotEmpty ||
                        book.regionDisplay.isNotEmpty ||
                        book.themes.isNotEmpty)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final author in authors)
                            InfoChip(
                              icon: Icons.person_outline,
                              label: author.name,
                              color: cs.primaryContainer,
                              textColor: cs.onPrimaryContainer,
                              onTap: author.pathWord.trim().isEmpty
                                  ? null
                                  : () => _openTag(
                                      author,
                                      NovelFilterKind.author,
                                    ),
                            ),
                          if (statusLabel.isNotEmpty)
                            InfoChip(
                              icon: Icons.timelapse,
                              label: statusLabel,
                              color: cs.primaryContainer,
                              textColor: cs.onPrimaryContainer,
                            ),
                          if (book.regionDisplay.isNotEmpty)
                            InfoChip(
                              icon: Icons.public,
                              label: book.regionDisplay,
                              color: cs.secondaryContainer,
                              textColor: cs.onSecondaryContainer,
                            ),
                          for (final theme in book.themes)
                            InfoChip(
                              icon: Icons.label_outline,
                              label: theme.name,
                              color: cs.tertiaryContainer,
                              textColor: cs.onTertiaryContainer,
                              onTap: theme.pathWord.trim().isEmpty
                                  ? null
                                  : () =>
                                        _openTag(theme, NovelFilterKind.theme),
                            ),
                        ],
                      ),
                    if (book.popular > 0) ...[
                      const SizedBox(height: 10),
                      _buildMetaRow(
                        Icons.local_fire_department,
                        formatPopularCount(context, book.popular),
                        tt,
                        cs.primary,
                      ),
                    ],
                    if (book.datetimeUpdated.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      _buildMetaRow(
                        Icons.update,
                        TimeFormat.relativeOf(book.datetimeUpdated, l10n),
                        tt,
                        cs.onSurfaceVariant,
                      ),
                    ],
                    if (book.lastChapterName case final name?) ...[
                      const SizedBox(height: AppSpacing.xs),
                      _buildMetaRow(
                        Icons.menu_book_outlined,
                        name,
                        tt,
                        cs.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      // ── 简介 ──（竖屏默认折叠 3 行，点击展开；宽屏左栏空间充裕，默认展开）
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Builder(
            builder: (context) {
              final expanded =
                  _briefExpanded ||
                  comicDetailUsesTwoPane(MediaQuery.sizeOf(context));
              final brief = book.brief.isEmpty ? l10n.novelNoBrief : book.brief;
              return GestureDetector(
                onTap: _toggleBriefExpanded,
                child: Text(
                  brief,
                  maxLines: expanded ? null : 3,
                  overflow: expanded ? null : TextOverflow.ellipsis,
                  style: tt.bodyMedium?.copyWith(
                    fontSize: 13,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              );
            },
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _buildDetailActions(book),
        ),
      ),
      if (_detailFailed)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _loadDetail(refresh: true),
                icon: const Icon(Icons.refresh),
                label: Text(
                  novelErrorMessage(
                    _detailError,
                    fallback: l10n.novelLoadFailed,
                  ),
                ),
              ),
            ),
          ),
        ),
      if (_queryFailed)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _loadQuery,
                icon: const Icon(Icons.refresh),
                label: Text(
                  novelErrorMessage(
                    _queryError,
                    fallback: l10n.novelQueryFailed,
                  ),
                ),
              ),
            ),
          ),
        ),
      if (_progressFailed)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _loadProgress,
                icon: const Icon(Icons.refresh),
                label: Text(
                  novelErrorMessage(
                    _progressError,
                    fallback: l10n.novelHistoryFailed,
                  ),
                ),
              ),
            ),
          ),
        ),
    ];
  }

  List<Widget> _buildVolumeSlivers() {
    final l10n = AppLocalizations.of(context)!;
    return [
      // 后台拉新时的刷新指示（漫画详情页同款小转圈）。
      if (_refreshingDetail || _refreshingVolumes)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              0,
            ),
            child: Align(
              alignment: Alignment.centerRight,
              child: SizedBox.square(
                dimension: 22,
                child: ExpressiveLoadingIndicator(),
              ),
            ),
          ),
        ),
      if (_volumesLoading && _volumes.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: ExpressiveLoadingIndicator()),
          ),
        )
      else if (_volumesFailed && _volumes.isEmpty)
        SliverToBoxAdapter(
          child: ErrorRetryView(
            message: novelErrorMessage(
              _volumesError,
              fallback: l10n.novelVolumesFailed,
            ),
            onRetry: () => _loadVolumes(refresh: true),
          ),
        )
      else if (_volumes.isEmpty)
        SliverToBoxAdapter(child: NovelEmptyView(message: l10n.novelNoVolumes))
      else ...[
        if (_downloadSelectionMode)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                0,
              ),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                    ),
                    child: Text(
                      l10n.selectedCount(_selectedDownloadVolumes.length, '卷'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed:
                        _enqueuingDownloads ||
                            !_volumes.any(_isVolumeSelectable)
                        ? null
                        : _selectAllDownloadableVolumes,
                    child: Text(l10n.selectAll),
                  ),
                  IconButton(
                    tooltip: l10n.cancelButton,
                    onPressed: _enqueuingDownloads
                        ? null
                        : _exitDownloadSelectionMode,
                    icon: const Icon(Icons.close),
                  ),
                  FilledButton.tonalIcon(
                    onPressed:
                        _enqueuingDownloads || _selectedDownloadVolumes.isEmpty
                        ? null
                        : _downloadSelectedVolumes,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: Text(l10n.downloadActionButton),
                  ),
                  OutlinedButton(
                    onPressed: _showDownloadSettings,
                    child: Text(l10n.downloadSettingsTitle),
                  ),
                ],
              ),
            ),
          ),
        // 与漫画详情的章节区同款卡片网格：同样的卡片组件、同样的列宽与间距。
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            0,
          ),
          sliver: SliverGrid(
            delegate: SliverChildBuilderDelegate((_, index) {
              final volume = _volumes[index];
              final selected =
                  volume.id ==
                  (_hasLocalResume ? _progress?.volumeId : _remoteVolumeId);
              final task = _downloads.taskFor(widget.pathWord, volume.id);
              final downloaded = _downloads.isVolumeDownloaded(
                widget.pathWord,
                volume.id,
              );
              final queued = _downloads.isVolumeQueued(
                widget.pathWord,
                volume.id,
              );
              final downloading =
                  !downloaded &&
                  task?.status == NovelDownloadStatus.downloading &&
                  task!.total > 0;
              return ChapterCard(
                name: volume.name,
                subtitle: downloading
                    ? '${task.completed}/${task.total}'
                    : null,
                isSelected: _selectedDownloadVolumes.contains(volume.id),
                isLastRead: selected,
                isRead: _readVolumeIds.contains(volume.id),
                isDownloaded: downloaded,
                progressRatio: downloading ? task.progress : null,
                onTap:
                    _opening ||
                        _enqueuingDownloads ||
                        (_downloadSelectionMode && (downloaded || queued))
                    ? null
                    : _downloadSelectionMode
                    ? () => _toggleDownloadSelection(volume)
                    : () => _read(volume: volume),
                onLongPress:
                    _opening || _enqueuingDownloads || downloaded || queued
                    ? null
                    : () => _toggleDownloadSelection(volume),
              );
            }, childCount: _volumes.length),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 150,
              mainAxisExtent: chapterTileExtent(
                MediaQuery.textScalerOf(context).scale(1),
              ),
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
          ),
        ),
      ],
      SliverPadding(
        // 为随文字缩放增高的续读按钮留出滚动空间，避免遮住最后一行卷册。
        padding: EdgeInsets.only(
          bottom:
              96 *
                  MediaQuery.textScalerOf(
                    context,
                  ).scale(1).clamp(1.0, double.infinity) +
              (_hasDownloads ? 56 + AppSpacing.md : 0),
        ),
      ),
    ];
  }
}

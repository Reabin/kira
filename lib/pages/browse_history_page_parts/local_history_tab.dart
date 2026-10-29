part of '../browse_history_page.dart';

class _LocalReadingHistoryTab extends ConsumerStatefulWidget {
  const _LocalReadingHistoryTab({required this.novel});

  final bool novel;

  @override
  ConsumerState<_LocalReadingHistoryTab> createState() =>
      _LocalReadingHistoryTabState();
}

class _LocalReadingHistoryTabState
    extends ConsumerState<_LocalReadingHistoryTab>
    with AutomaticKeepAliveClientMixin {
  final _searchController = TextEditingController();
  late final NovelReadingStore _novelStore = ref.read(
    novelReadingStoreProvider,
  );
  List<_LocalHistoryEntry> _items = [];
  Object? _error;
  bool _loading = true;
  bool _deleting = false;
  bool _opening = false;
  int _generation = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    (widget.novel ? NovelReadingStore.changes : ReadingHistory.changes)
        .addListener(_onHistoryChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    (widget.novel ? NovelReadingStore.changes : ReadingHistory.changes)
        .removeListener(_onHistoryChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() => setState(() {});
  void _onHistoryChanged() {
    // 阅读器返回和删除完成时会统一刷新，避免翻页时反复扫描整个历史库。
    if (_opening || _deleting) return;
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = <_LocalHistoryEntry>[];
      if (widget.novel) {
        for (final progress in await _novelStore.readRecent(limit: null)) {
          items.add(
            _LocalHistoryEntry(
              pathWord: progress.pathWord,
              name: progress.name.isEmpty ? progress.pathWord : progress.name,
              novel: progress,
            ),
          );
        }
      } else {
        for (final entry in await ReadingHistory.readRecent()) {
          var name = entry.record.comicName;
          if (name.trim().isEmpty) {
            // 旧进度没有书名，只补已有缓存，不为展示记录发网络请求。
            try {
              final cached = await ComicDetailRepository(
                entry.pathWord,
              ).loadFromCache();
              name = cached?.comic.name ?? '';
            } catch (error, stack) {
              _log(error, stack, 'cached_name');
            }
          }
          items.add(
            _LocalHistoryEntry(
              pathWord: entry.pathWord,
              name: name.trim().isEmpty ? entry.pathWord : name,
              comic: entry.record,
            ),
          );
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() => _items = items);
    } catch (error, stack) {
      _log(error, stack, 'load');
      if (mounted && generation == _generation) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _log(Object error, StackTrace stack, String action) {
    unawaited(
      AppLogger.instance.recordWarning(
        error,
        stackTrace: stack,
        source: 'local_reading_history.$action',
      ),
    );
  }

  Future<void> _open(_LocalHistoryEntry entry, {bool details = false}) async {
    if (_opening || _deleting) return;
    _opening = true;
    FocusScope.of(context).unfocus();
    try {
      if (details) {
        await context.pushNamed(
          widget.novel ? AppRoutes.novelDetail : AppRoutes.comicDetail,
          pathParameters: {'pathWord': entry.pathWord},
        );
      } else if (widget.novel) {
        // 导航前读取最新进度，列表更新尚未完成时也不恢复旧卷。
        final latest = await _novelStore.readProgress(entry.pathWord);
        if (!mounted) return;
        if (latest != null) {
          await context.pushNamed(
            AppRoutes.novelReader,
            pathParameters: {
              'pathWord': latest.pathWord,
              'volumeId': latest.volumeId,
            },
            extra: NovelReaderExtra(
              name: latest.name,
              cover: latest.cover,
              entryIndex: latest.entryIndex,
              resume: true,
              noDetailBelow: true,
            ),
          );
        }
      } else {
        final latest = await ReadingHistory.latestForComic(entry.pathWord);
        if (!mounted) return;
        if (latest != null && latest.chapterUuid.isNotEmpty) {
          await context.pushNamed(
            AppRoutes.reader,
            pathParameters: {
              'pathWord': entry.pathWord,
              'chapterUuid': latest.chapterUuid,
            },
            extra: ReaderExtra(
              comicName: entry.name,
              group: latest.group,
              chapterName: latest.chapterName,
              chapterListPage: latest.chapterListPage,
              initialPage: latest.page,
              noCatalogBelow: true,
            ),
          );
        }
      }
    } catch (error, stack) {
      _log(error, stack, 'open');
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        showToast(
          context,
          novelErrorMessage(error, fallback: l10n.novelHistoryFailed),
          isError: true,
        );
      }
    } finally {
      _opening = false;
      if (mounted) await _load();
    }
  }

  Future<void> _remove({_LocalHistoryEntry? entry}) async {
    if (_deleting || _opening) return;
    setState(() => _deleting = true);
    final l10n = AppLocalizations.of(context)!;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            entry == null ? l10n.novelClearHistory : l10n.novelRemoveHistory,
          ),
          content: Text(
            entry == null
                ? l10n.localHistoryClearConfirm(
                    widget.novel ? l10n.historyTabNovel : l10n.historyTabComic,
                  )
                : l10n.localHistoryRemoveConfirm(entry.name),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancelButton),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                entry == null ? l10n.cacheClearButton : l10n.novelRemoveHistory,
              ),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      if (widget.novel) {
        if (entry == null) {
          await _novelStore.clear();
        } else {
          await _novelStore.removeProgress(entry.pathWord);
        }
      } else if (entry == null) {
        await ReadingHistory.clear();
      } else {
        await ReadingHistory.removeProgress(entry.pathWord);
      }
      if (mounted) await _load();
    } catch (error, stack) {
      _log(error, stack, 'remove');
      if (mounted) {
        showToast(
          context,
          l10n.novelHistoryDeleteFailedDetail(
            NetworkError.message(error, l10n: l10n),
          ),
          isError: true,
        );
        await _load();
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final hp = ScreenLayout.horizontalPadding(MediaQuery.sizeOf(context).width);
    final query = _searchController.text.trim().toLowerCase();
    final visible = _items
        .where(
          (item) => query.isEmpty || item.name.toLowerCase().contains(query),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(hp, AppSpacing.sm, hp, AppSpacing.sm),
          child: TextField(
            key: ValueKey(
              'local_history_search_${widget.novel ? 'novel' : 'comic'}',
            ),
            controller: _searchController,
            decoration: InputDecoration(
              hintText: l10n.localHistorySearchHint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: l10n.cacheClearButton,
                      onPressed: _searchController.clear,
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: CustomScrollView(
              key: PageStorageKey(
                'local_history_${widget.novel ? 'novel' : 'comic'}',
              ),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (_loading && _items.isEmpty)
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: hp),
                    sliver: SliverToBoxAdapter(
                      child: ShimmerShell(
                        child: Column(
                          children: [
                            for (var i = 0; i < 6; i++)
                              const Padding(
                                padding: EdgeInsets.only(bottom: AppSpacing.sm),
                                child: ShimmerBox(
                                  height: 88,
                                  radius: AppRadius.lg,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  )
                else if (_error != null && _items.isEmpty)
                  SliverErrorRetryView(
                    message: novelErrorMessage(
                      _error,
                      fallback: l10n.novelHistoryFailed,
                    ),
                    onRetry: _load,
                  )
                else ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: hp),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.localHistoryTotal(visible.length),
                              style: AppTypography.meta(
                                Theme.of(context).textTheme,
                              )?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ),
                          IconButton(
                            tooltip: l10n.novelClearHistory,
                            icon: const Icon(Icons.delete_outline),
                            onPressed: _deleting || _items.isEmpty
                                ? null
                                : () => _remove(),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_error != null)
                    SliverToBoxAdapter(
                      child: ErrorRetryView(
                        message: novelErrorMessage(
                          _error,
                          fallback: l10n.novelHistoryFailed,
                        ),
                        onRetry: _load,
                      ),
                    ),
                  if (visible.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: NovelEmptyView(
                        message: query.isEmpty
                            ? l10n.novelEmptyHistory
                            : l10n.localHistorySearchEmpty,
                        icon: query.isEmpty
                            ? Icons.history_rounded
                            : Icons.search,
                      ),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(hp, 0, hp, AppSpacing.lg),
                      sliver: SliverList.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final entry = visible[index];
                          return Padding(
                            padding: const EdgeInsets.only(
                              bottom: AppSpacing.sm,
                            ),
                            child: _LocalHistoryCard(
                              key: ValueKey(
                                '${widget.novel ? 'novel' : 'comic'}_history_${entry.pathWord}',
                              ),
                              entry: entry,
                              onRead: () => _open(entry),
                              onDetails: () => _open(entry, details: true),
                              onRemove: _deleting
                                  ? null
                                  : () => _remove(entry: entry),
                            ),
                          );
                        },
                      ),
                    ),
                ],
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: AppSpacing.lg + NavBarInset.of(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _LocalHistoryEntry {
  const _LocalHistoryEntry({
    required this.pathWord,
    required this.name,
    this.comic,
    this.novel,
  });

  final String pathWord;
  final String name;
  final ReadingRecord? comic;
  final NovelReadingProgress? novel;
}

class _LocalHistoryCard extends StatelessWidget {
  const _LocalHistoryCard({
    super.key,
    required this.entry,
    required this.onRead,
    required this.onDetails,
    required this.onRemove,
  });

  final _LocalHistoryEntry entry;
  final VoidCallback onRead;
  final VoidCallback onDetails;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final comic = entry.comic;
    final novel = entry.novel;
    final location = novel == null
        ? comic?.chapterName ?? ''
        : [
            novel.volumeName,
            novel.chapterName,
          ].where((part) => part.trim().isNotEmpty).join(' · ');
    final updatedAt = novel?.updatedAt ?? comic?.updatedAt;
    final progress = novel == null
        ? (comic != null && comic.totalPage > 0
              ? l10n.localHistoryPageProgress(comic.page, comic.totalPage)
              : '')
        : '${novel.progress >= 1 ? 100 : (novel.progress * 100).floor()}%';
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onRead,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.titleSmall,
                    ),
                    if (location.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${l10n.browseHistorySeenLabel} ',
                              style: AppTypography.meta(
                                tt,
                              )?.copyWith(color: cs.onSurfaceVariant),
                            ),
                            TextSpan(text: location, style: tt.bodyMedium),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (progress.isNotEmpty || updatedAt != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        [
                          if (progress.isNotEmpty) progress,
                          if (updatedAt != null)
                            TimeFormat.relative(updatedAt, l10n),
                        ].join(' · '),
                        style: AppTypography.meta(
                          tt,
                        )?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              PopupMenuButton<String>(
                key: ValueKey(
                  '${novel == null ? 'comic' : 'novel'}_history_actions_${entry.pathWord}',
                ),
                onSelected: (action) {
                  if (action == 'details') onDetails();
                  if (action == 'remove') onRemove?.call();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'details',
                    child: Text(l10n.novelBookDetails),
                  ),
                  PopupMenuItem(
                    value: 'remove',
                    enabled: onRemove != null,
                    child: Text(l10n.novelRemoveHistory),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

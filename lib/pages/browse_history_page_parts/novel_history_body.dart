part of '../browse_history_page.dart';

/// 两个历史入口共享的小说列表：仅使用本机进度，与漫画登录状态无关。
class NovelHistoryBody extends ConsumerStatefulWidget {
  const NovelHistoryBody({super.key});

  @override
  ConsumerState<NovelHistoryBody> createState() => _NovelHistoryBodyState();
}

class _NovelHistoryBodyState extends ConsumerState<NovelHistoryBody>
    with AutomaticKeepAliveClientMixin {
  static const _pageSize = 30;
  final _scrollController = ScrollController();
  late final NovelReadingStore _store;

  List<NovelReadingProgress> _items = [];
  bool _loading = true;
  bool _failed = false;
  Object? _loadError;
  bool _deleting = false;
  bool _opening = false;
  bool _hasMore = false;
  bool _canScrollUp = false;
  int _limit = _pageSize;
  int _generation = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _store = ref.read(novelReadingStoreProvider);
    NovelReadingStore.changes.addListener(_onProgressChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    NovelReadingStore.changes.removeListener(_onProgressChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onProgressChanged() {
    if (mounted) unawaited(_load());
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_loading || !_hasMore)) return;
    final generation = ++_generation;
    final limit = _limit + (more ? _pageSize : 0);
    setState(() => _loading = true);
    try {
      final items = await _store.readRecent(limit: limit + 1);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = items.take(limit).toList();
        _limit = limit;
        _hasMore = items.length > limit;
        _failed = false;
      });
    } catch (e, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: stack,
          source: 'browse_history_page.load_novel',
        ),
      );
      if (mounted && generation == _generation) {
        setState(() {
          _failed = true;
          _loadError = e;
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open(
    NovelReadingProgress progress, {
    bool details = false,
  }) async {
    if (_opening || _deleting) return;
    _opening = true;
    try {
      if (details) {
        await context.pushNamed(
          AppRoutes.novelDetail,
          pathParameters: {'pathWord': progress.pathWord},
        );
      } else {
        // 卡片可能尚未收到进度通知；导航前排队读取最新卷，绝不回退旧快照。
        final latest = await _store.readProgress(progress.pathWord);
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
      }
    } catch (error, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          error,
          stackTrace: stack,
          source: 'browse_history_page.open_novel',
        ),
      );
      if (mounted) {
        showToast(
          context,
          AppLocalizations.of(context)!.novelHistoryFailed,
          isError: true,
        );
      }
    } finally {
      _opening = false;
      if (mounted) await _load();
    }
  }

  Future<void> _removeHistory({String? pathWord}) async {
    if (_deleting) return;
    final l10n = AppLocalizations.of(context)!;
    if (pathWord == null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.novelClearHistory),
          content: Text(l10n.novelClearHistoryConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancelButton),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.cacheClearButton),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || _deleting) return;
    }
    setState(() => _deleting = true);
    try {
      if (pathWord == null) {
        await _store.clear();
      } else {
        await _store.removeProgress(pathWord);
      }
    } catch (e, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: stack,
          source: 'browse_history_page.remove_novel',
        ),
      );
      if (mounted) {
        showToast(
          context,
          l10n.novelHistoryDeleteFailedDetail(NetworkError.message(e)),
          isError: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _deleting = false);
        await _load();
      }
    }
  }

  Future<void> _scrollToTop() async {
    if (!_scrollController.hasClients) return;
    await _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final screenWidth = MediaQuery.of(context).size.width;
    final hp = ScreenLayout.horizontalPadding(screenWidth);

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _load,
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.axis == Axis.vertical) {
                final shouldShow = n.metrics.pixels > 400;
                if (shouldShow != _canScrollUp) {
                  setState(() => _canScrollUp = shouldShow);
                }
              }
              return false;
            },
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (_loading && _items.isEmpty)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(hp, 0, hp, 24),
                    sliver: SliverToBoxAdapter(
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (var i = 0; i < 6; i++)
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 440),
                              child: const _HistoryCardSkeleton(),
                            ),
                        ],
                      ),
                    ),
                  )
                else if (_failed && _items.isEmpty)
                  SliverErrorRetryView(
                    message: _loadError == null
                        ? l10n.novelHistoryFailed
                        : '${l10n.novelHistoryFailed}：'
                              '${NetworkError.message(_loadError!)}',
                    onRetry: _load,
                  )
                else if (_items.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: NovelEmptyView(
                      message: l10n.novelEmptyHistory,
                      icon: Icons.history_rounded,
                    ),
                  )
                else ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(hp, 4, hp, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.browseHistoryTotal(
                                _items.length,
                                l10n.historyTabNovel,
                              ),
                              style: tt.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: l10n.novelClearHistory,
                            onPressed: _deleting ? null : _removeHistory,
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(hp, 0, hp, 24),
                    sliver: SliverToBoxAdapter(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          // 与漫画标签页同一套宽屏/窄屏规则。
                          final wide =
                              constraints.maxWidth >=
                              ScreenLayout.wideBreakpoint;
                          return Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              for (final progress in _items)
                                _NovelBrowseHistoryCard(
                                  key: ValueKey(
                                    'novel_history_${progress.pathWord}',
                                  ),
                                  progress: progress,
                                  hugText: wide,
                                  onRead: () => _open(progress),
                                  onDetails: () =>
                                      _open(progress, details: true),
                                  onRemove: _deleting
                                      ? null
                                      : () => _removeHistory(
                                          pathWord: progress.pathWord,
                                        ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ],
                if (_items.isNotEmpty && (_hasMore || _failed))
                  SliverToBoxAdapter(
                    child: LoadMoreFooter(
                      loading: _loading,
                      onPressed: () => _load(more: _hasMore),
                      label: _failed
                          ? l10n.novelLoadMoreFailed
                          : l10n.novelLoadMore,
                      detail: _failed ? novelErrorMessage(_loadError) : null,
                      horizontalPadding: hp,
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 72)),
              ],
            ),
          ),
        ),
        if (_canScrollUp)
          Positioned(
            right: AppSpacing.md,
            // 叠加悬浮导航栏高度，底栏隐藏时按钮落到屏幕底部。
            bottom: AppSpacing.md + NavBarInset.of(context),
            child: BackToTopButton(onPressed: _scrollToTop),
          ),
      ],
    );
  }
}

class _NovelBrowseHistoryCard extends StatelessWidget {
  final NovelReadingProgress progress;
  final bool hugText;
  final VoidCallback onRead;
  final VoidCallback onDetails;
  final VoidCallback? onRemove;

  const _NovelBrowseHistoryCard({
    super.key,
    required this.progress,
    required this.onRead,
    required this.onDetails,
    required this.onRemove,
    this.hugText = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final location = [
      progress.volumeName,
      progress.chapterName,
    ].where((part) => part.trim().isNotEmpty).join(' · ');

    return _HistoryCardShell(
      onTap: onRead,
      trailing: PopupMenuButton<String>(
        key: ValueKey('novel_history_actions_${progress.pathWord}'),
        onSelected: (value) {
          if (value == 'details') onDetails();
          if (value == 'remove') onRemove?.call();
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'details', child: Text(l10n.novelBookDetails)),
          PopupMenuItem(
            value: 'remove',
            enabled: onRemove != null,
            child: Text(l10n.novelRemoveHistory),
          ),
        ],
      ),
      cover: NovelCover(url: progress.cover),
      title: progress.name.isEmpty ? progress.pathWord : progress.name,
      lastBrowseName: location.isEmpty ? null : location,
      chips: [
        if (progress.progress > 0)
          _HistoryMetaChip(
            icon: Icons.timelapse,
            label: '${(progress.progress * 100).round()}%',
          ),
        _HistoryMetaChip(
          icon: Icons.schedule,
          label: TimeFormat.relative(progress.updatedAt, l10n),
        ),
      ],
      hugText: hugText,
    );
  }
}

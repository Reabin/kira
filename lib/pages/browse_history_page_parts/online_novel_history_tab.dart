part of '../browse_history_page.dart';

class _OnlineNovelHistoryTab extends ConsumerStatefulWidget {
  const _OnlineNovelHistoryTab();

  @override
  ConsumerState<_OnlineNovelHistoryTab> createState() =>
      _OnlineNovelHistoryTabState();
}

class _OnlineNovelHistoryTabState extends ConsumerState<_OnlineNovelHistoryTab>
    with AutomaticKeepAliveClientMixin {
  late final _api = ref.read(novelApiProvider);
  late final _user = ref.read(userManagerProvider);
  late String _scope = _api.cacheScope;
  List<NovelBrowseEntry> _items = [];
  Object? _error;
  Object? _moreError;
  bool _loading = false;
  bool _loadingMore = false;
  bool _deleting = false;
  bool _unauthorized = false;
  bool _showingLoginPrompt = false;
  int _generation = 0;
  int _offset = 0;
  int _total = 0;
  Future<void>? _loadFuture;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _user.addListener(_onAccountChanged);
    if (_user.isCopyLoggedIn) unawaited(_load());
  }

  @override
  void dispose() {
    _user.removeListener(_onAccountChanged);
    super.dispose();
  }

  bool _isCurrent(int generation, String scope) =>
      mounted &&
      generation == _generation &&
      scope == _scope &&
      scope == _api.cacheScope;

  void _onAccountChanged() {
    if (!mounted || _scope == _api.cacheScope) return;
    setState(() {
      ++_generation;
      _scope = _api.cacheScope;
      _items = [];
      _offset = _total = 0;
      _error = _moreError = null;
      _loading = _loadingMore = _unauthorized = false;
      _loadFuture = null;
    });
    if (_user.isCopyLoggedIn) unawaited(_load());
  }

  void _log(Object error, StackTrace stack, String action) {
    unawaited(
      AppLogger.instance.recordWarning(
        error,
        stackTrace: stack,
        source: 'online_novel_history.$action',
      ),
    );
  }

  Future<void> _load() {
    if (!_user.isCopyLoggedIn || _unauthorized || _deleting) {
      return Future<void>.value();
    }
    if (_loading) return _loadFuture ?? Future<void>.value();
    final generation = ++_generation;
    final scope = _scope;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = _moreError = null;
    });
    return _loadFuture = _performLoad(generation, scope);
  }

  Future<void> _performLoad(int generation, String scope) async {
    try {
      final page = await _api.getBrowseHistory();
      if (!_isCurrent(generation, scope)) return;
      setState(() {
        _items = _unique(page.list);
        _offset = page.offset + page.list.length;
        _total = page.total;
      });
    } catch (error, stack) {
      if (!_isCurrent(generation, scope)) return;
      _log(error, stack, 'load');
      setState(() => _error = error);
      if (_isUnauthorized(error)) await _handleUnauthorized();
    } finally {
      if (_isCurrent(generation, scope)) {
        setState(() {
          _loading = false;
          _loadFuture = null;
        });
      }
    }
  }

  List<NovelBrowseEntry> _unique(Iterable<NovelBrowseEntry> items) {
    final seen = <String>{};
    return [
      for (final item in items)
        if (seen.add(item.book.pathWord)) item,
    ];
  }

  Future<void> _loadMore() async {
    if (_loading ||
        _loadingMore ||
        _deleting ||
        _unauthorized ||
        _offset >= _total) {
      return;
    }
    final generation = _generation;
    final scope = _scope;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final page = await _api.getBrowseHistory(offset: _offset);
      if (!_isCurrent(generation, scope)) return;
      setState(() {
        _items = _unique([..._items, ...page.list]);
        // 重复条目也消耗服务器分页偏移，不能用去重后的数量代替。
        _offset = page.offset + page.list.length;
        _total = page.list.isEmpty ? _offset : page.total;
      });
    } catch (error, stack) {
      if (!_isCurrent(generation, scope)) return;
      _log(error, stack, 'load_more');
      setState(() => _moreError = error);
      if (_isUnauthorized(error)) await _handleUnauthorized();
    } finally {
      if (_isCurrent(generation, scope)) setState(() => _loadingMore = false);
    }
  }

  bool _isUnauthorized(Object error) =>
      (error is NovelApiException && error.isUnauthorized) ||
      (error is DioException && error.response?.statusCode == 401);

  Future<void> _handleUnauthorized() async {
    if (!mounted) return;
    final scope = _scope;
    setState(() {
      _unauthorized = true;
      _items = [];
    });
    if (_showingLoginPrompt) return;
    _showingLoginPrompt = true;
    try {
      // 小说使用 COPY 账号；过期不能退出独立的 HOT 账号。
      final login = await showLoginExpiredDialog(
        context,
        content: AppLocalizations.of(context)!.browseHistoryLoginExpiredContent,
      );
      if (mounted && scope == _scope && login) await _login();
    } finally {
      _showingLoginPrompt = false;
    }
  }

  Future<void> _login() async {
    await context.pushNamed(
      AppRoutes.login,
      queryParameters: {'copyOnly': 'true'},
    );
    if (mounted && _user.isCopyLoggedIn) {
      setState(() => _unauthorized = false);
      await _load();
    }
  }

  Future<void> _clearHistory() async {
    if (_deleting) return;
    final scope = _scope;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _deleting = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.browseHistoryClearTitle),
          content: Text(l10n.browseHistoryClearContent(l10n.historyTabNovel)),
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
      // 确认期间切换账号时，不能清空另一个账号的记录。
      if (confirmed != true ||
          !mounted ||
          scope != _api.cacheScope ||
          _unauthorized) {
        return;
      }
      final generation = ++_generation;
      setState(() {
        _loading = _loadingMore = false;
        _loadFuture = null;
      });
      await _api.clearBrowseHistory();
      if (!mounted || !_isCurrent(generation, scope)) return;
      setState(() {
        _items = [];
        _offset = _total = 0;
        _error = _moreError = null;
      });
      showToast(context, l10n.browseHistoryCleared(l10n.historyTabNovel));
    } catch (error, stack) {
      _log(error, stack, 'clear');
      if (mounted && scope == _api.cacheScope) {
        showToast(
          context,
          l10n.browseHistoryClearFailed(novelErrorMessage(error)),
          isError: true,
        );
        if (_isUnauthorized(error)) await _handleUnauthorized();
      }
    } finally {
      if (mounted) {
        setState(() => _deleting = false);
        if (scope != _scope) unawaited(_load());
      }
    }
  }

  Future<void> _open(NovelBrowseEntry entry) async {
    final scope = _scope;
    await context.pushNamed(
      AppRoutes.novelDetail,
      pathParameters: {'pathWord': entry.book.pathWord},
      extra: NovelDetailExtra(initialBook: entry.book),
    );
    if (mounted && scope == _scope) await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final hp = ScreenLayout.horizontalPadding(MediaQuery.sizeOf(context).width);
    if (!_user.isCopyLoggedIn || _unauthorized) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_outline,
                size: AppIconSize.display,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(l10n.browseHistoryLoginToView, style: tt.titleMedium),
              const SizedBox(height: AppSpacing.md),
              FilledButton.icon(
                onPressed: _login,
                icon: const Icon(Icons.login),
                label: Text(l10n.goLoginButton),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (_loading && _items.isEmpty)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                hp,
                AppSpacing.sm,
                hp,
                AppSpacing.lg,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  children: [
                    for (var i = 0; i < 6; i++)
                      const Padding(
                        padding: EdgeInsets.only(bottom: AppSpacing.sm),
                        child: _HistoryCardSkeleton(),
                      ),
                  ],
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
          else if (_items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: NovelEmptyView(
                message: l10n.browseHistoryEmptyTitle(l10n.historyTabNovel),
                icon: Icons.history_rounded,
              ),
            )
          else ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: hp),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.browseHistoryTotal(_total, l10n.historyTabNovel),
                        style: AppTypography.meta(
                          tt,
                        )?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                    IconButton(
                      onPressed: _deleting ? null : _clearHistory,
                      tooltip: l10n.browseHistoryClearTitle,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ),
            ),
            if (_loading)
              const SliverToBoxAdapter(child: LinearProgressIndicator()),
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
            SliverPadding(
              padding: EdgeInsets.fromLTRB(hp, 0, hp, AppSpacing.lg),
              sliver: SliverToBoxAdapter(
                child: LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      for (final entry in _items)
                        _HistoryCardShell(
                          onTap: () => _open(entry),
                          cover: NovelCover(url: entry.book.cover),
                          title: entry.book.name,
                          subtitle: entry.book.authors.isEmpty
                              ? null
                              : entry.book.authors
                                    .map((author) => author.name)
                                    .join(' / '),
                          lastBrowseName: entry.lastChapterName,
                          latestName: entry.book.lastChapterName,
                          hugText:
                              constraints.maxWidth >=
                              ScreenLayout.wideBreakpoint,
                          metadata: [
                            _HistoryMetaItem(
                              icon: Icons.local_fire_department,
                              label: _BrowseHistoryPageState.formatPopular(
                                context,
                                entry.book.popular,
                              ),
                            ),
                            if (entry.book.datetimeUpdated.isNotEmpty)
                              _HistoryMetaItem(
                                icon: Icons.schedule,
                                label: l10n.browseHistoryUpdatedAt(
                                  TimeFormat.relativeOf(
                                    entry.book.datetimeUpdated,
                                    l10n,
                                  ),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (_offset < _total || _moreError != null)
              SliverToBoxAdapter(
                child: LoadMoreFooter(
                  loading: _loadingMore,
                  onPressed: _loadMore,
                  label: l10n.loadMoreProgress(_offset, _total),
                  detail: _moreError == null
                      ? null
                      : novelErrorMessage(_moreError),
                  horizontalPadding: hp,
                ),
              ),
          ],
          SliverToBoxAdapter(
            child: SizedBox(height: AppSpacing.lg + NavBarInset.of(context)),
          ),
        ],
      ),
    );
  }
}

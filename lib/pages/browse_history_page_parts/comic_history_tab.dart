part of '../browse_history_page.dart';

class _ComicBrowseHistoryPage extends StatefulWidget {
  final WidgetBuilder loginPageBuilder;

  const _ComicBrowseHistoryPage({required this.loginPageBuilder});

  @override
  State<_ComicBrowseHistoryPage> createState() => _BrowseHistoryPageState();
}

class _BrowseHistoryPageState extends State<_ComicBrowseHistoryPage>
    with AutomaticKeepAliveClientMixin {
  final _api = ApiClient();
  final _user = UserManager();
  late (String?, String) _identity = (_user.token, _user.loginSource);

  List<BrowseHistoryItem> _comicItems = [];
  bool _loading = true;

  /// 首屏加载失败的原因。此前失败只是把列表留空，用户看到的是「没有记录」，
  /// 完全掩盖了真实错误。
  String? _loadError;
  bool _refreshing = false;
  bool _loadingMore = false;
  String? _loadMoreError;
  bool _showingLoginPrompt = false;
  int _offset = 0;
  int _total = 0;

  String _modeLabel(AppLocalizations l10n) => l10n.comicLabel;
  bool get _currentItemsEmpty => _comicItems.isEmpty;
  int get _currentLength => _comicItems.length;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _user.addListener(_onUserChanged);
    if (_user.isLoggedIn) {
      _load(silent: true);
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _user.removeListener(_onUserChanged);
    super.dispose();
  }

  void _onUserChanged() {
    if (!mounted) return;
    final identity = (_user.token, _user.loginSource);
    if (identity == _identity) return;
    _identity = identity;
    if (_user.isLoggedIn) {
      _load(silent: true, force: true);
    } else {
      setState(() {
        _clearItems();
        _loading = false;
      });
    }
  }

  void _clearItems() {
    _comicItems = [];
    _offset = 0;
    _total = 0;
  }

  Future<void> _clearHistory() async {
    final l10n = AppLocalizations.of(context)!;
    final modeLabel = _modeLabel(l10n);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.browseHistoryClearTitle),
        content: Text(l10n.browseHistoryClearContent(modeLabel)),
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
    if (confirmed != true || !mounted) return;

    try {
      await _api.user.clearBrowseHistory();
      if (!mounted) return;
      showToast(context, l10n.browseHistoryCleared(modeLabel));
      setState(_clearItems);
    } catch (e) {
      if (!mounted) return;
      showToast(
        context,
        l10n.browseHistoryClearFailed(NetworkError.message(e, l10n: l10n)),
        isError: true,
      );
    }
  }

  Future<void> _load({bool silent = false, bool force = false}) async {
    if (_refreshing && !force) return;
    _refreshing = true;
    final isInitial = _currentItemsEmpty;
    if (isInitial) {
      setState(() {
        _loading = true;
        _loadError = null;
        _loadMoreError = null;
      });
    } else {
      setState(() {
        _loadError = null;
        _loadMoreError = null;
      });
    }
    _offset = 0;

    try {
      final data = await _api.user.getBrowseHistory();
      if (!mounted) return;
      setState(() {
        _comicItems = data.list;
        _total = data.total;
        _offset = data.list.length;
        _loading = false;
        _loadError = null;
      });
      if (!silent && mounted) {
        showToast(context, AppLocalizations.of(context)!.refreshSuccess);
      }
    } catch (e, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: stack,
          source: 'browse_history_page.load',
        ),
      );
      if (isInitial && mounted) {
        setState(() {
          _loading = false;
          _loadError = NetworkError.message(e);
        });
      }
      if (_isUnauthorized(e)) {
        await _handleUnauthorized();
      } else if (!silent && mounted) {
        final l10n = AppLocalizations.of(context)!;
        showToast(
          context,
          l10n.refreshFailedDetail(NetworkError.message(e, l10n: l10n)),
          isError: true,
        );
      }
    } finally {
      _refreshing = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _refreshing || _offset >= _total) return;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final data = await _api.user.getBrowseHistory(offset: _offset);
      if (!mounted) return;
      setState(() {
        _comicItems.addAll(data.list);
        _offset = _comicItems.length;
      });
    } catch (e, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: stack,
          source: 'browse_history_page.load_more',
        ),
      );
      if (_isUnauthorized(e)) {
        await _handleUnauthorized();
      } else if (mounted) {
        setState(() => _loadMoreError = NetworkError.message(e));
      }
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      } else {
        _loadingMore = false;
      }
    }
  }

  bool _isUnauthorized(Object error) =>
      error is DioException && error.response?.statusCode == 401;

  Future<void> _handleUnauthorized() async {
    if (_showingLoginPrompt || !mounted) return;
    final l10n = AppLocalizations.of(context)!;

    _showingLoginPrompt = true;

    await _user.logout();
    if (!mounted) {
      _showingLoginPrompt = false;
      return;
    }

    final shouldLogin = await showLoginExpiredDialog(
      context,
      content: l10n.browseHistoryLoginExpiredContent,
    );

    if (shouldLogin == true && mounted) {
      await _goLogin();
    } else if (mounted) {
      showToast(context, l10n.browseHistoryLoginToView, isError: true);
    }

    _showingLoginPrompt = false;
  }

  Future<void> _goLogin() async {
    final loggedIn = await context.pushNamed<bool>(AppRoutes.login);
    if (loggedIn == true && mounted) {
      unawaited(_load(silent: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final modeLabel = _modeLabel(l10n);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final screenWidth = MediaQuery.of(context).size.width;
    final hp = ScreenLayout.horizontalPadding(screenWidth);

    // 清空按钮从顶部 AppBar 移到了列表首行:列表头本身就在滚动区里,
    // 用户滚动列表时不会觉得按钮"丢了"。
    return !_user.isLoggedIn
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 64,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    l10n.browseHistoryLoginToView,
                    style: tt.titleMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    l10n.browseHistoryLoginHintComicOnly,
                    textAlign: TextAlign.center,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  FilledButton.icon(
                    onPressed: _goLogin,
                    icon: const Icon(Icons.login),
                    label: Text(l10n.goLoginButton),
                  ),
                ],
              ),
            ),
          )
        : _loading
        ? CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(hp, 0, hp, 24),
                sliver: SliverToBoxAdapter(
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (var i = 0; i < 20; i++)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 440),
                          child: const _HistoryCardSkeleton(),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          )
        : RefreshIndicator(
            onRefresh: _load,
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                // pixels > 0：只在用户确实滚动过后才自动翻页，
                // 否则宽屏首屏不满一页时会立刻连发第二页。
                if (!_currentItemsEmpty &&
                    n.metrics.pixels > 0 &&
                    n.metrics.pixels > n.metrics.maxScrollExtent - 300) {
                  _loadMore();
                }
                return false;
              },
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  if (_refreshing)
                    const SliverToBoxAdapter(
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (_currentItemsEmpty && _loadError != null)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: ErrorRetryView(
                        message: l10n.browseHistoryLoadFailed(_loadError!),
                        onRetry: () => _load(force: true),
                      ),
                    )
                  else if (_currentItemsEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.history,
                                size: 64,
                                color: cs.onSurfaceVariant,
                              ),
                              const SizedBox(height: AppSpacing.lg),
                              Text(
                                l10n.browseHistoryEmptyTitle(modeLabel),
                                style: tt.titleMedium?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              Text(
                                l10n.browseHistoryEmptySubtitle(modeLabel),
                                textAlign: TextAlign.center,
                                style: tt.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: AppSpacing.lg),
                              FilledButton.tonalIcon(
                                onPressed: _user.isLoggedIn ? _load : null,
                                icon: const Icon(Icons.refresh),
                                label: Text(l10n.refreshButton),
                              ),
                            ],
                          ),
                        ),
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
                                l10n.browseHistoryTotal(_total, modeLabel),
                                style: tt.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: l10n.browseHistoryClearTitle,
                              onPressed: _clearHistory,
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
                            // 宽屏：卡片宽度贴合文本内容，一行能容纳几张
                            // 就排几张，列数随窗口宽度自适应；
                            // 窄屏：卡片 Expanded 铺满单列。
                            // 卡片为横向行卡、高度由内容撑起，
                            // 不能用固定宽高比的 SliverGrid。
                            final wide =
                                constraints.maxWidth >=
                                ScreenLayout.wideBreakpoint;
                            return Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                for (var i = 0; i < _currentLength; i++)
                                  _ComicBrowseHistoryCard(
                                    item: _comicItems[i],
                                    hugText: wide,
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    if (_offset < _total)
                      SliverToBoxAdapter(
                        child: LoadMoreFooter(
                          loading: _loadingMore,
                          onPressed: _loadMore,
                          label: l10n.loadMoreProgress(_offset, _total),
                          detail: _loadMoreError,
                          horizontalPadding: hp,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          );
  }

  static String formatPopular(BuildContext context, int n) {
    final l10n = AppLocalizations.of(context)!;
    if (n >= 100000000) {
      return l10n.hundredMillionUnit((n / 100000000).toStringAsFixed(1));
    }
    if (n >= 10000) {
      return l10n.tenThousandUnit((n / 10000).toStringAsFixed(1));
    }
    return n.toString();
  }
}

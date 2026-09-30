import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/app_localizations.dart';
import '../models/api_ordering.dart';
import '../models/novel.dart';
import '../providers/novel_providers.dart';
import '../routing/app_router.dart';
import '../theme/app_spacing.dart';
import '../utils/screen_layout.dart';
import '../widgets/back_to_top_button.dart';
import '../widgets/error_retry_view.dart';
import '../widgets/filter_chip_row.dart'
    show FilterChipOption, FilterChipRow, InlineRetryNotice;
import '../widgets/load_more_footer.dart';
import '../widgets/novel_hero_tags.dart';
import '../widgets/novel_paged_controller.dart';
import '../widgets/novel_widgets.dart';
import '../widgets/result_scroll_listener.dart';
import '../widgets/shimmer_skeleton.dart';

enum NovelFilterKind { author, theme }

/// 独立在线结果页：标签筛选不修改小说首页的搜索、排序或滚动状态。
class NovelFilterPage extends ConsumerStatefulWidget {
  const NovelFilterPage({
    super.key,
    required this.kind,
    required this.pathWord,
    this.name = '',
  });

  final NovelFilterKind kind;
  final String pathWord;
  final String name;

  @override
  ConsumerState<NovelFilterPage> createState() => _NovelFilterPageState();
}

class _NovelFilterPageState extends ConsumerState<NovelFilterPage> {
  final _scrollController = ScrollController();
  late final NovelPagedController<NovelBook> _books;
  String _ordering = ApiOrdering.popular;
  bool _canScrollUp = false;

  bool get _isAuthor => widget.kind == NovelFilterKind.author;
  bool get _canLoadMore =>
      !_books.loading &&
      _books.items.isNotEmpty &&
      _books.hasMore &&
      _books.error == null &&
      _books.refreshError == null;

  @override
  void initState() {
    super.initState();
    _books = NovelPagedController<NovelBook>(
      loadPage: (offset) {
        final pathWord = widget.pathWord.trim();
        // 空标识不能退化成无筛选的在线列表。
        if (pathWord.isEmpty) throw ArgumentError('小说标签标识不能为空');
        return ref
            .read(novelApiProvider)
            .getBooks(
              author: _isAuthor ? pathWord : '',
              theme: _isAuthor ? '' : pathWord,
              ordering: _ordering,
              offset: offset,
            );
      },
      keyOf: (book) => book.pathWord,
    )..addListener(_rebuild);
    unawaited(_books.refresh());
  }

  @override
  void didUpdateWidget(covariant NovelFilterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind ||
        oldWidget.pathWord != widget.pathWord) {
      unawaited(_books.refresh());
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _books.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() => _books.refresh(keepItems: true);

  Future<void> _selectOrdering(String ordering) async {
    if (_ordering == ordering) return;
    setState(() => _ordering = ordering);
    await _books.refresh();
    if (mounted) unawaited(_scrollToTop());
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
    final l10n = AppLocalizations.of(context)!;
    final width = MediaQuery.sizeOf(context).width;
    final hp = ScreenLayout.horizontalPadding(width);
    final grid = novelGridDelegate(context, width - hp * 2);
    final label = widget.name.trim().isEmpty
        ? widget.pathWord
        : widget.name.trim();
    final title = _isAuthor ? l10n.rankingAuthorWorks : l10n.rankingThemeWorks;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '$title · $label',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: _refresh,
              child: ResultScrollListener(
                canScrollUp: _canScrollUp,
                onCanScrollUpChanged: (value) =>
                    setState(() => _canScrollUp = value),
                onLoadMore: _canLoadMore ? _books.loadMore : null,
                child: CustomScrollView(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          hp,
                          AppSpacing.md,
                          hp,
                          AppSpacing.sm,
                        ),
                        child: FilterChipRow(
                          options: [
                            FilterChipOption(
                              label: l10n.popularOrder,
                              value: ApiOrdering.popular,
                              icon: Icons.whatshot,
                              selected: _ordering == ApiOrdering.popular,
                            ),
                            FilterChipOption(
                              label: l10n.updateOrder,
                              value: ApiOrdering.datetimeUpdated,
                              icon: Icons.schedule,
                              selected: _ordering == ApiOrdering.datetimeUpdated,
                            ),
                          ],
                          onTap: (option) =>
                              unawaited(_selectOrdering(option.value)),
                        ),
                      ),
                    ),
                    if (_books.loading && _books.items.isEmpty)
                      SliverPadding(
                        padding: EdgeInsets.symmetric(horizontal: hp),
                        sliver: ComicCoverSkeletonGrid(
                          count: 8,
                          gridDelegate: grid,
                        ),
                      )
                    else if (_books.items.isEmpty && _books.error != null)
                      SliverErrorRetryView(
                        message: l10n.novelLoadFailed,
                        onRetry: () => unawaited(_books.refresh()),
                      )
                    else if (_books.items.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: NovelEmptyView(
                          message: _isAuthor
                              ? l10n.rankingNoAuthorWorks
                              : l10n.rankingNoThemeWorks,
                        ),
                      )
                    else ...[
                      if (_books.refreshing)
                        const SliverToBoxAdapter(
                          child: LinearProgressIndicator(),
                        ),
                      if (_books.refreshError != null)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: hp),
                            child: InlineRetryNotice(
                              message: l10n.novelLoadFailed,
                              onRetry: () => unawaited(_refresh()),
                            ),
                          ),
                        ),
                      SliverPadding(
                        padding: EdgeInsets.symmetric(horizontal: hp),
                        sliver: SliverGrid(
                          gridDelegate: grid,
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final book = _books.items[index];
                              final heroTagBase = NovelHeroTags.base(
                                scope: 'novel-filter',
                                pathWord: book.pathWord,
                                index: index,
                              );
                              return NovelBookCard(
                                book: book,
                                heroTagBase: heroTagBase,
                                onTap: () => context.pushNamed(
                                  AppRoutes.novelDetail,
                                  pathParameters: {'pathWord': book.pathWord},
                                  extra: NovelDetailExtra(
                                    initialBook: book,
                                    heroTagBase: heroTagBase,
                                  ),
                                ),
                              );
                            },
                            childCount: _books.items.length,
                          ),
                        ),
                      ),
                    ],
                    if (_books.items.isNotEmpty &&
                        _books.hasMore &&
                        !_books.refreshing &&
                        _books.refreshError == null)
                      SliverToBoxAdapter(
                        child: LoadMoreFooter(
                          loading: _books.loading,
                          onPressed: _books.loadMore,
                          label: _books.error == null
                              ? l10n.novelLoadMore
                              : l10n.novelLoadMoreFailed,
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
                right: AppSpacing.lg,
                bottom: AppSpacing.lg,
                child: BackToTopButton(onPressed: _scrollToTop),
              ),
          ],
        ),
      ),
    );
  }
}

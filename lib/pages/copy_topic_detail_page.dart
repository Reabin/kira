import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/app_localizations.dart';
import '../models/comic.dart' hide Theme;
import '../providers/repository_providers.dart';
import '../repositories/copy_topic_repository.dart';
import '../routing/app_router.dart';
import '../utils/app_logger.dart';
import '../utils/screen_layout.dart';
import '../widgets/back_to_top_button.dart';
import '../widgets/comic_card_skeleton.dart';
import '../widgets/comic_hero_tags.dart';
import '../widgets/cover_placeholder.dart';
import '../widgets/error_retry_view.dart';
import '../widgets/load_more_footer.dart';
import 'home_page.dart' show ComicCard;

/// COPY 专题详情及其漫画列表。
class CopyTopicDetailPage extends ConsumerStatefulWidget {
  final String pathWord;

  const CopyTopicDetailPage({super.key, required this.pathWord});

  @override
  ConsumerState<CopyTopicDetailPage> createState() =>
      _CopyTopicDetailPageState();
}

class _CopyTopicDetailPageState extends ConsumerState<CopyTopicDetailPage> {
  static const _pageSize = 20;

  CopyTopicRepository get _repository => ref.read(copyTopicRepositoryProvider);
  final _scrollController = ScrollController();
  final _comics = <Comic>[];
  MangaTopic? _topic;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  int _total = 0;
  String? _error;
  bool _showBackToTop = false;

  String get _scope => 'copy-topic-${widget.pathWord}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _scrollToTop() async {
    if (!_scrollController.hasClients) return;
    await _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() {
      _loading = true;
      _loadingMore = false;
      _hasMore = true;
      _offset = 0;
      _total = 0;
      _error = null;
      _topic = null;
      _comics.clear();
    });
    try {
      final topic = await _repository.loadTopic(
        widget.pathWord,
        forceRefresh: forceRefresh,
      );
      final data = await _repository.loadTopicComics(
        widget.pathWord,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        _topic = topic;
        _comics.addAll(data.list);
        _offset = _comics.length;
        _total = data.total;
        _hasMore = data.list.isNotEmpty && _offset < _total;
        _loading = false;
      });
    } catch (e, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: stack,
          source: 'copy_topic_detail_page.load',
        ),
      );
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _hasMore = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final data = await _repository.loadTopicComics(
        widget.pathWord,
        offset: _offset,
      );
      if (!mounted) return;
      setState(() {
        _comics.addAll(data.list);
        _offset = _comics.length;
        _total = data.total;
        _hasMore = data.list.isNotEmpty && _offset < _total;
      });
    } catch (e, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: stack,
          source: 'copy_topic_detail_page.load_more',
        ),
      );
    }
    if (mounted) {
      setState(() => _loadingMore = false);
    } else {
      _loadingMore = false;
    }
  }

  void _openComic(Comic comic, String heroTagBase) {
    context.pushNamed(
      AppRoutes.comicDetail,
      pathParameters: {'pathWord': comic.pathWord},
      extra: ComicDetailExtra(initialComic: comic, heroTagBase: heroTagBase),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final hp = ScreenLayout.horizontalPadding(screenWidth);
    final cardExtent = ScreenLayout.cardExtent(screenWidth);
    final gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: cardExtent,
      childAspectRatio: 0.55,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _topic?.title ?? l10n.copyTopicComics,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      floatingActionButton: _showBackToTop
          ? BackToTopButton(onPressed: _scrollToTop)
          : null,
      body: _loading
          ? _buildLoading(hp, gridDelegate)
          : RefreshIndicator(
              onRefresh: () => _load(forceRefresh: true),
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.metrics.axis != Axis.vertical) {
                    return false;
                  }
                  final shouldShow = notification.metrics.pixels > 400;
                  if (shouldShow != _showBackToTop) {
                    setState(() => _showBackToTop = shouldShow);
                  }
                  if (notification.metrics.pixels > 0 &&
                      notification.metrics.extentAfter < 300) {
                    _loadMore();
                  }
                  return false;
                },
                child: _buildContent(hp, gridDelegate),
              ),
            ),
    );
  }

  Widget _buildLoading(
    double hp,
    SliverGridDelegateWithMaxCrossAxisExtent gridDelegate,
  ) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(hp, 12, hp, 12),
          sliver: const SliverToBoxAdapter(child: _CopyTopicHeaderSkeleton()),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(hp, 0, hp, 0),
          sliver: SliverGrid(
            gridDelegate: gridDelegate,
            delegate: SliverChildBuilderDelegate(
              (_, _) => const ComicCardSkeleton(),
              childCount: _pageSize,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(
    double hp,
    SliverGridDelegateWithMaxCrossAxisExtent gridDelegate,
  ) {
    final l10n = AppLocalizations.of(context)!;
    return CustomScrollView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (_error != null && _topic == null && _comics.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorRetryView(onRetry: _load),
          )
        else ...[
          if (_topic != null)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(hp, 12, hp, 12),
              sliver: SliverToBoxAdapter(
                child: _CopyTopicHeader(topic: _topic!),
              ),
            ),
          if (_comics.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text(l10n.noContent)),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(hp, 0, hp, 0),
              sliver: SliverGrid(
                gridDelegate: gridDelegate,
                delegate: SliverChildBuilderDelegate((_, index) {
                  if (index >= _comics.length) {
                    return const ComicCardSkeleton();
                  }
                  final comic = _comics[index];
                  final heroTagBase = ComicHeroTags.base(
                    scope: _scope,
                    pathWord: comic.pathWord,
                    index: index,
                  );
                  return ComicCard(
                    comic: comic,
                    heroTagBase: heroTagBase,
                    onTap: () => _openComic(comic, heroTagBase),
                  );
                }, childCount: _comics.length + (_loadingMore ? 6 : 0)),
              ),
            ),
          if (_comics.isNotEmpty && _hasMore)
            SliverToBoxAdapter(
              child: LoadMoreFooter(
                loading: _loadingMore,
                onPressed: _loadMore,
                label: l10n.loadMoreProgress(_offset, _total),
                horizontalPadding: hp,
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
        ],
      ],
    );
  }
}

class _CopyTopicHeader extends StatelessWidget {
  final MangaTopic topic;

  const _CopyTopicHeader({required this.topic});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 3.72,
            child: CachedNetworkImage(
              imageUrl: topic.cover,
              fit: BoxFit.cover,
              fadeInDuration: Duration.zero,
              fadeOutDuration: Duration.zero,
              placeholder: (_, _) => const CoverPlaceholder(),
              errorWidget: (_, _, _) => const CoverPlaceholder.error(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  topic.title,
                  style: tt.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                if (topic.period.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    topic.period,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
                if (topic.brief.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    topic.brief,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyTopicHeaderSkeleton extends StatelessWidget {
  const _CopyTopicHeaderSkeleton();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 3.72,
            child: ColoredBox(color: cs.surfaceContainerHighest),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FractionallySizedBox(
                  widthFactor: 0.72,
                  child: SizedBox(
                    height: 18,
                    child: ColoredBox(color: cs.surfaceContainerHighest),
                  ),
                ),
                const SizedBox(height: 8),
                FractionallySizedBox(
                  widthFactor: 0.32,
                  child: SizedBox(
                    height: 14,
                    child: ColoredBox(color: cs.surfaceContainerHighest),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

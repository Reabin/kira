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
import '../theme/app_spacing.dart';
import '../utils/app_logger.dart';
import '../utils/screen_layout.dart';
import '../widgets/back_to_top_button.dart';
import '../widgets/cover_placeholder.dart';
import '../widgets/error_retry_view.dart';
import '../widgets/load_more_footer.dart';

/// COPY 漫画专题列表。
class CopyTopicListPage extends ConsumerStatefulWidget {
  const CopyTopicListPage({super.key});

  @override
  ConsumerState<CopyTopicListPage> createState() => _CopyTopicListPageState();
}

class _CopyTopicListPageState extends ConsumerState<CopyTopicListPage> {
  CopyTopicRepository get _repository => ref.read(copyTopicRepositoryProvider);
  final _scrollController = ScrollController();
  final _topics = <MangaTopic>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  int _total = 0;
  String? _error;
  bool _showBackToTop = false;

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
      _topics.clear();
    });
    try {
      final data = await _repository.loadTopics(forceRefresh: forceRefresh);
      if (!mounted) return;
      setState(() {
        _topics.addAll(data.list);
        _offset = _topics.length;
        _total = data.total;
        _hasMore = data.list.isNotEmpty && _offset < _total;
        _loading = false;
      });
    } catch (e, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: stack,
          source: 'copy_topic_list_page.load',
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
      final data = await _repository.loadTopics(offset: _offset);
      if (!mounted) return;
      setState(() {
        _topics.addAll(data.list);
        _offset = _topics.length;
        _total = data.total;
        _hasMore = data.list.isNotEmpty && _offset < _total;
      });
    } catch (e, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: stack,
          source: 'copy_topic_list_page.load_more',
        ),
      );
    }
    if (mounted) {
      setState(() => _loadingMore = false);
    } else {
      _loadingMore = false;
    }
  }

  void _openTopic(MangaTopic topic) {
    if (topic.pathWord.isEmpty) return;
    context.pushNamed(
      AppRoutes.copyTopicDetail,
      pathParameters: {'pathWord': topic.pathWord},
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hp = ScreenLayout.horizontalPadding(MediaQuery.sizeOf(context).width);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.copyTopics)),
      floatingActionButton: _showBackToTop
          ? BackToTopButton(onPressed: _scrollToTop)
          : null,
      body: _loading
          ? _buildLoading(hp)
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
                child: _buildContent(hp),
              ),
            ),
    );
  }

  Widget _buildLoading(double hp) {
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(hp, 12, hp, 16),
      itemCount: 6,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
      itemBuilder: (_, _) => const _CopyTopicSkeleton(),
    );
  }

  Widget _buildContent(double hp) {
    final l10n = AppLocalizations.of(context)!;
    return CustomScrollView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (_error != null && _topics.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorRetryView(onRetry: _load),
          )
        else if (_topics.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text(l10n.noContent)),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(hp, 12, hp, 0),
            sliver: SliverList.builder(
              itemCount: _topics.length,
              itemBuilder: (_, index) {
                final topic = _topics[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: _CopyTopicCard(
                    topic: topic,
                    onTap: () => _openTopic(topic),
                  ),
                );
              },
            ),
          ),
        if (_topics.isNotEmpty && _hasMore)
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
    );
  }
}

class _CopyTopicCard extends StatelessWidget {
  final MangaTopic topic;
  final VoidCallback onTap;

  const _CopyTopicCard({required this.topic, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
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
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          topic.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: tt.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (topic.period.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            topic.period,
                            style: tt.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CopyTopicSkeleton extends StatelessWidget {
  const _CopyTopicSkeleton();

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
                    height: 16,
                    child: ColoredBox(color: cs.surfaceContainerHighest),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                FractionallySizedBox(
                  widthFactor: 0.28,
                  child: SizedBox(
                    height: 13,
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

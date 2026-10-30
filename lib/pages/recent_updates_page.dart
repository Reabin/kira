import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';

import '../l10n/app_localizations.dart';
import '../models/api_ordering.dart';
import '../models/comic.dart' hide Theme;
import '../models/recent_updates_settings.dart';
import '../providers/app_providers.dart';
import '../repositories/recent_updates_repository.dart';
import '../routing/app_router.dart';
import '../utils/app_logger.dart';
import '../utils/screen_layout.dart';
import '../widgets/comic_cover_card.dart';
import '../widgets/comic_hero_tags.dart';
import '../widgets/error_retry_view.dart';
import '../widgets/load_more_footer.dart';
import '../widgets/recent_region_filter.dart';

class RecentUpdatesPage extends ConsumerStatefulWidget {
  const RecentUpdatesPage({super.key, required this.isCopy});
  final bool isCopy;
  @override
  ConsumerState<RecentUpdatesPage> createState() => _RecentUpdatesPageState();
}

class _RecentUpdatesPageState extends ConsumerState<RecentUpdatesPage> {
  final _settings = RecentUpdatesSettings();
  final _scrollController = ScrollController();
  final _comics = <Comic>[];
  bool _loading = true;
  bool _failed = false;
  bool _hasMore = true;
  int _offset = 0;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _settings.load();
      if (mounted) await _load(reset: true);
    } catch (error, stack) {
      await AppLogger.instance.recordWarning(
        error,
        stackTrace: stack,
        source: 'recent_updates.settings',
      );
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  Future<void> _load({bool reset = false, bool refresh = false}) async {
    if (!reset && (_loading || !_hasMore)) return;
    final generation = ++_generation;
    if (reset) {
      _comics.clear();
      _offset = 0;
      _hasMore = true;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    if (reset && _scrollController.hasClients) _scrollController.jumpTo(0);
    try {
      final api = ref.read(mangaApiProvider);
      final repository = RecentUpdatesRepository(
        isCopy: widget.isCopy,
        regions: _settings.regions,
        offset: _offset,
        fetchPage: (offset) => widget.isCopy
            ? api.getCopyComicList(
                ordering: ApiOrdering.datetimeUpdated,
                offset: offset,
              )
            : api.getComicList(
                ordering: ApiOrdering.datetimeUpdated,
                offset: offset,
              ),
        fetchDetail: api.getComicDetail,
      );
      if (refresh) await repository.invalidateCache();
      final data = await repository.load();
      if (!mounted || generation != _generation) return;
      final seen = _comics.map((c) => c.pathWord).toSet();
      setState(() {
        _comics.addAll(data.comics.where((c) => seen.add(c.pathWord)));
        _offset = data.nextOffset;
        _hasMore = data.hasMore;
        _loading = false;
      });
    } catch (error, stack) {
      await AppLogger.instance.recordWarning(
        error,
        stackTrace: stack,
        source: 'recent_updates.list',
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _select(Set<int> regions) async {
    try {
      await _settings.setRegions(regions);
      if (mounted) await _load(reset: true);
    } catch (error, stack) {
      await AppLogger.instance.recordWarning(
        error,
        stackTrace: stack,
        source: 'recent_updates.filter',
      );
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _generation++;
    _scrollController.dispose();
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final width = MediaQuery.sizeOf(context).width;
    final padding = ScreenLayout.horizontalPadding(width);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.homeRecentUpdates)),
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true, refresh: true),
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.axis == Axis.vertical &&
                notification.metrics.pixels > 0 &&
                notification.metrics.extentAfter < 300 &&
                !_failed) {
              unawaited(_load());
            }
            return false;
          },
          child: CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: padding),
                  child: RecentRegionFilter(
                    regions: _settings.regions,
                    onChanged: _select,
                    enabled: !_loading,
                  ),
                ),
              ),
              if (_failed && _comics.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: ErrorRetryView(
                    onRetry: () => _load(reset: true, refresh: true),
                  ),
                )
              else ...[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(padding, 12, padding, 12),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: ScreenLayout.cardExtent(width),
                      childAspectRatio: .55,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                    ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final comic = _comics[index];
                      final hero = ComicHeroTags.base(
                        scope: 'recent-more-${widget.isCopy}',
                        pathWord: comic.pathWord,
                        index: index,
                      );
                      return ComicCoverCard(
                        comic: comic,
                        heroTagBase: hero,
                        showPopular: false,
                        onTap: () => context.pushNamed(
                          AppRoutes.comicDetail,
                          pathParameters: {'pathWord': comic.pathWord},
                          extra: ComicDetailExtra(
                            initialComic: comic,
                            heroTagBase: hero,
                          ),
                        ),
                      );
                    }, childCount: _comics.length),
                  ),
                ),
                if (_loading && _comics.isEmpty)
                  const SliverToBoxAdapter(
                    child: Center(child: ExpressiveLoadingIndicator()),
                  )
                else if (_failed)
                  SliverToBoxAdapter(child: ErrorRetryView(onRetry: _load))
                else if (_hasMore)
                  SliverToBoxAdapter(
                    child: LoadMoreFooter(
                      loading: _loading,
                      onPressed: _load,
                      label: l10n.loadMore,
                    ),
                  )
                else if (_comics.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(l10n.homeRecentEmpty),
                    ),
                  ),
                const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

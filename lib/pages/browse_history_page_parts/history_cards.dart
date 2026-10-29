part of '../browse_history_page.dart';

class _ComicBrowseHistoryCard extends StatelessWidget {
  final BrowseHistoryItem item;
  final bool hugText;
  const _ComicBrowseHistoryCard({required this.item, this.hugText = false});

  @override
  Widget build(BuildContext context) {
    final comic = item.comic;
    final authors = comic.authors.map((e) => e.name).where((e) => e.isNotEmpty);
    final heroTagBase = ComicHeroTags.base(
      scope: 'browse-history',
      pathWord: comic.pathWord,
      index: item.id,
    );

    return _HistoryCardShell(
      onTap: () => context.pushNamed(
        AppRoutes.comicDetail,
        pathParameters: {'pathWord': comic.pathWord},
        extra: ComicDetailExtra(
          initialComic: comic,
          heroTagBase: heroTagBase,
          lastBrowseId: item.lastBrowseId,
          lastBrowseName: item.lastBrowseName,
        ),
      ),
      hugText: hugText,
      cover: _hero(
        heroTagBase,
        ComicHeroTags.cover,
        _HistoryCover(imageUrl: comic.cover, icon: Icons.image),
      ),
      title: comic.name,
      subtitle: authors.isEmpty ? null : authors.join(' / '),
      lastBrowseName: item.lastBrowseName,
      latestName:
          comic.lastChapterName == null || comic.lastChapterName!.isEmpty
          ? null
          : comic.lastChapterName,
      metadata: [
        _HistoryMetaItem(
          icon: Icons.local_fire_department,
          label: _BrowseHistoryPageState.formatPopular(context, comic.popular),
        ),
        if (comic.datetimeUpdated != null)
          _HistoryMetaItem(
            icon: Icons.schedule,
            label: AppLocalizations.of(context)!.browseHistoryUpdatedAt(
              TimeFormat.relativeOf(
                comic.datetimeUpdated!,
                AppLocalizations.of(context)!,
              ),
            ),
          ),
      ],
    );
  }

  Widget _hero(
    String heroTagBase,
    String Function(String base) tagOf,
    Widget child,
  ) {
    return AppHero(
      tag: tagOf(heroTagBase),
      createRectTween: ComicHeroTags.createRectTween,
      placeholderBuilder: _buildHeroPlaceholder,
      child: child,
    );
  }

  Widget _buildHeroPlaceholder(
    BuildContext context,
    Size heroSize,
    Widget child,
  ) {
    return SizedBox(width: heroSize.width, height: heroSize.height);
  }
}

class _HistoryCardShell extends StatelessWidget {
  final VoidCallback onTap;
  final Widget cover;
  final String title;
  final String? subtitle;
  final String? lastBrowseName;
  final String? latestName;
  final List<Widget> metadata;

  /// 宽屏流式布局：文本列用宽松约束，卡片宽度随文本内容收缩，
  /// 由外层 Wrap 决定一行排几张；窄屏保持 Expanded 铺满。
  final bool hugText;

  const _HistoryCardShell({
    required this.onTap,
    required this.cover,
    required this.title,
    this.subtitle,
    this.lastBrowseName,
    this.latestName,
    required this.metadata,
    this.hugText = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final textColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tt.titleSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        if ((lastBrowseName != null && lastBrowseName!.isNotEmpty) ||
            (latestName != null && latestName!.isNotEmpty)) ...[
          const SizedBox(height: 10),
          // 「看到」「最新」都用小字作标记，章节名保持同字号，最新章节另起一行。
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (lastBrowseName != null && lastBrowseName!.isNotEmpty)
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${l10n.browseHistorySeenLabel} ',
                        style: AppTypography.meta(
                          tt,
                        )?.copyWith(color: cs.onSurfaceVariant),
                      ),
                      TextSpan(text: lastBrowseName!, style: tt.bodyMedium),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              if (lastBrowseName != null &&
                  lastBrowseName!.isNotEmpty &&
                  latestName != null &&
                  latestName!.isNotEmpty)
                const SizedBox(height: 4),
              if (latestName != null && latestName!.isNotEmpty)
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${l10n.browseHistoryLatestLabel} ',
                        style: AppTypography.meta(
                          tt,
                        )?.copyWith(color: cs.onSurfaceVariant),
                      ),
                      TextSpan(text: latestName!, style: tt.bodyMedium),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: metadata),
      ],
    );

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            // hugText 时 min 让卡片收缩到内容宽度；
            // 窄屏 Expanded(tight) 依然撑满，结果一致。
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 84,
                child: AspectRatio(aspectRatio: 0.72, child: cover),
              ),
              const SizedBox(width: AppSpacing.md),
              hugText
                  ? Flexible(child: textColumn)
                  : Expanded(child: textColumn),
              const SizedBox(width: AppSpacing.sm),
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryCover extends StatelessWidget {
  final String imageUrl;
  final IconData icon;

  const _HistoryCover({required this.imageUrl, required this.icon});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: AppRadius.mdR,
      child: CoverBrightnessFilter(
        child: CoverImage(
          url: imageUrl,
          placeholder: Container(
            color: cs.surfaceContainerHighest,
            child: Center(
              child: Icon(icon, color: cs.onSurfaceVariant, size: 28),
            ),
          ),
          errorWidget: Container(
            color: cs.surfaceContainerHighest,
            child: Center(
              child: Icon(
                Icons.broken_image,
                color: cs.onSurfaceVariant,
                size: 28,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryMetaItem extends StatelessWidget {
  final IconData icon;
  final String label;
  const _HistoryMetaItem({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: AppIconSize.sm, color: cs.onSurfaceVariant),
        const SizedBox(width: AppSpacing.xs),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.meta(tt)?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _HistoryCardSkeleton extends StatelessWidget {
  const _HistoryCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(12),
        child: ShimmerShell(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 84,
                child: AspectRatio(
                  aspectRatio: 0.72,
                  child: ShimmerBox(radius: AppRadius.md),
                ),
              ),
              SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ShimmerBox(height: 16),
                    SizedBox(height: AppSpacing.sm),
                    ShimmerBox(width: 120, height: 12),
                    SizedBox(height: AppSpacing.md),
                    ShimmerBox(width: 160),
                    SizedBox(height: 10),
                    Row(
                      children: [
                        ShimmerBox(width: 60, height: 24, radius: 999),
                        SizedBox(width: AppSpacing.sm),
                        ShimmerBox(width: 60, height: 24, radius: 999),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(width: AppSpacing.sm),
            ],
          ),
        ),
      ),
    );
  }
}

part of '../search_page.dart';

/// 排序行行尾的数据源切换按钮（仅「发现」页用，搜索页固定 HOT 源）。
///
/// 显示**当前**源名称，点击后切到另一个源。只影响「发现」页，
/// 与首页各自独立。
class _SourceToggle extends StatelessWidget {
  final bool isCopy;
  final VoidCallback onPressed;

  const _SourceToggle({required this.isCopy, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return FilterRowAction(
      icon: Icons.swap_horiz,
      label: isCopy ? l10n.homeSourceCopy : l10n.homeSourceHot,
      tooltip: isCopy ? l10n.switchToHotSource : l10n.switchToCopySource,
      onPressed: onPressed,
    );
  }
}

/// 漫画结果网格，两个标签页共用。
class _ComicGrid extends StatelessWidget {
  final List<Comic> comics;
  final double hp;
  final double cardExtent;
  final bool loadingMore;
  final String scope;
  final void Function(Comic comic, String heroTagBase) onOpen;

  const _ComicGrid({
    required this.comics,
    required this.hp,
    required this.cardExtent,
    required this.loadingMore,
    required this.scope,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(hp, 8, hp, 0),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate((_, i) {
          if (i >= comics.length) {
            return const ComicCardSkeleton();
          }
          final comic = comics[i];
          final heroTagBase = ComicHeroTags.base(
            scope: scope,
            pathWord: comic.pathWord,
            index: i,
          );
          return ComicCard(
            comic: comic,
            heroTagBase: heroTagBase,
            onTap: () => onOpen(comic, heroTagBase),
          );
        }, childCount: comics.length + (loadingMore ? 6 : 0)),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: cardExtent,
          childAspectRatio: 0.55,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
      ),
    );
  }
}

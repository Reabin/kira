import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/novel.dart';
import '../models/novel_reading_progress.dart';
import '../theme/app_icon_sizes.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import '../utils/cover_brightness_filter.dart';
import '../utils/time_format.dart';
import 'comic_card_surface.dart';
import 'cover_placeholder.dart';
import 'novel_hero_tags.dart';

/// The same cover treatment as manga cards, without rewriting CDN URLs.
class NovelCover extends StatelessWidget {
  const NovelCover({
    super.key,
    required this.url,
    this.localPath,
    this.withSurface = true,
  });

  final String url;

  /// 非 null 表示明确的本地来源；空路径或坏文件只显示占位，不回退联网。
  final String? localPath;
  final bool withSurface;

  @override
  Widget build(BuildContext context) {
    final local = localPath;
    final Widget image;
    if (local != null) {
      image = local.isEmpty
          ? const CoverPlaceholder()
          : Image.file(
              File(local),
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const CoverPlaceholder.error(),
            );
    } else {
      image = url.isEmpty
          ? const CoverPlaceholder()
          : CachedNetworkImage(
              imageUrl: url,
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
              fadeInDuration: Duration.zero,
              fadeOutDuration: Duration.zero,
              placeholder: (_, _) => const CoverPlaceholder(),
              errorWidget: (_, _, _) => const CoverPlaceholder.error(),
            );
    }
    final cover = CoverBrightnessFilter(child: image);
    return withSurface
        ? ComicCardSurface(child: cover)
        : ClipRRect(borderRadius: AppRadius.smR, child: cover);
  }
}

class NovelBookCard extends StatelessWidget {
  const NovelBookCard({
    super.key,
    required this.book,
    required this.onTap,
    this.subtitle,
    this.onLongPress,
    this.heroTagBase,
  });

  final NovelBook book;
  final VoidCallback onTap;
  final String? subtitle;
  final VoidCallback? onLongPress;

  /// 非 null 时封面参与进详情页的 Hero 动画。
  final String? heroTagBase;

  Widget _buildHero(Widget child) {
    final base = heroTagBase;
    if (base == null) return child;
    return Hero(
      tag: NovelHeroTags.cover(base),
      createRectTween: NovelHeroTags.createRectTween,
      placeholderBuilder: (_, heroSize, _) =>
          SizedBox(width: heroSize.width, height: heroSize.height),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final metaStyle = AppTypography.meta(
      theme.textTheme,
    )?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final meta =
        subtitle ?? book.authors.map((author) => author.name).join(' / ');
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _buildHero(NovelCover(url: book.cover))),
          const SizedBox(height: 6),
          Text(
            book.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.xs),
          if (meta.isNotEmpty || book.datetimeUpdated.isNotEmpty)
            Row(
              children: [
                if (meta.isNotEmpty)
                  Expanded(
                    child: Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: metaStyle,
                    ),
                  ),
                if (meta.isNotEmpty && book.datetimeUpdated.isNotEmpty)
                  const SizedBox(width: AppSpacing.xs),
                if (book.datetimeUpdated.isNotEmpty)
                  Text(
                    TimeFormat.relativeOf(book.datetimeUpdated, l10n),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// A compact, responsive card which always resumes from local progress.
class NovelProgressCard extends StatelessWidget {
  const NovelProgressCard({
    super.key,
    required this.progress,
    required this.onRead,
    this.onDetails,
    this.onRemove,
  });

  final NovelReadingProgress progress;
  final VoidCallback onRead;
  final VoidCallback? onDetails;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final location = [
      progress.volumeName,
      progress.chapterName,
    ].where((part) => part.isNotEmpty).join(' · ');
    return ComicCardSurface(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 66,
              height: 90,
              child: NovelCover(url: progress.cover),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    progress.name.isEmpty ? progress.pathWord : progress.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  if (location.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      location,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.meta(
                        theme.textTheme,
                      )?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: onRead,
                        icon: const Icon(
                          Icons.menu_book_rounded,
                          size: AppIconSize.md,
                        ),
                        label: Text(l10n.novelContinueReading),
                      ),
                      if (onDetails != null)
                        IconButton(
                          tooltip: l10n.novelBookDetails,
                          onPressed: onDetails,
                          icon: const Icon(Icons.info_outline),
                        ),
                      if (onRemove != null)
                        IconButton(
                          tooltip: l10n.novelRemoveHistory,
                          onPressed: onRemove,
                          icon: const Icon(Icons.delete_outline),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NovelEmptyView extends StatelessWidget {
  const NovelEmptyView({
    super.key,
    required this.message,
    this.icon = Icons.menu_book_outlined,
    this.action,
  });

  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: AppIconSize.empty,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Keep covers in the app's existing size range; reserve enough room for two
/// title lines even with accessibility text scaling enabled.
SliverGridDelegate novelGridDelegate(BuildContext context, double width) {
  final columns = (width / 150).ceil().clamp(2, 8);
  final coverWidth = (width - AppSpacing.md * (columns - 1)) / columns;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    crossAxisSpacing: AppSpacing.md,
    mainAxisSpacing: AppSpacing.lg,
    mainAxisExtent:
        coverWidth * 1.4 + MediaQuery.textScalerOf(context).scale(58),
  );
}

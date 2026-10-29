import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_shadows.dart';
import '../../theme/app_spacing.dart';

class ChapterCommentToolbar extends StatelessWidget {
  const ChapterCommentToolbar({
    super.key,
    required this.onComment,
    required this.onCatalog,
    required this.onScrollToTop,
    required this.onClose,
    this.hasNextChapter = false,
    this.onNextChapter,
  });

  final VoidCallback onComment;
  final VoidCallback onCatalog;
  final VoidCallback onScrollToTop;
  final VoidCallback onClose;
  final bool hasNextChapter;
  final VoidCallback? onNextChapter;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final buttonStyle = FilledButton.styleFrom(
      backgroundColor: cs.secondaryContainer,
      foregroundColor: cs.onSecondaryContainer,
      elevation: 6,
      shadowColor: AppShadows.floatingTint(0.22),
      minimumSize: const Size(0, 52),
      maximumSize: const Size.fromHeight(52),
      fixedSize: const Size.fromHeight(52),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.smR),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final squareStyle = buttonStyle.copyWith(
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      minimumSize: const WidgetStatePropertyAll(Size.square(52)),
      maximumSize: const WidgetStatePropertyAll(Size.square(52)),
      fixedSize: const WidgetStatePropertyAll(Size.square(52)),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: FilledButton.icon(
            key: const ValueKey('chapter_comment_action'),
            style: buttonStyle.copyWith(
              backgroundColor: WidgetStatePropertyAll(cs.primary),
              foregroundColor: WidgetStatePropertyAll(cs.onPrimary),
            ),
            onPressed: onComment,
            icon: const Icon(Icons.comment_outlined),
            label: Text(
              l10n.chapterCommentsComment,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: FilledButton.icon(
            key: const ValueKey('chapter_catalog_action'),
            style: buttonStyle,
            onPressed: onCatalog,
            icon: const Icon(Icons.list_rounded),
            label: Text(
              l10n.chapterCommentsCatalog,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (hasNextChapter) ...[
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: FilledButton.icon(
              key: const ValueKey('chapter_next_action'),
              style: buttonStyle,
              onPressed: onNextChapter,
              icon: const Icon(Icons.skip_next_rounded),
              label: Text(
                l10n.chapterCommentsNext,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
        const SizedBox(width: AppSpacing.sm),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 52,
              child: Tooltip(
                message: l10n.backToTop,
                child: FilledButton(
                  key: const ValueKey('chapter_scroll_top_action'),
                  style: squareStyle,
                  onPressed: onScrollToTop,
                  child: const Icon(Icons.arrow_upward_rounded),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox.square(
              dimension: 52,
              child: Tooltip(
                message: l10n.closeButton,
                child: FilledButton(
                  key: const ValueKey('chapter_close_action'),
                  style: squareStyle,
                  onPressed: onClose,
                  child: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

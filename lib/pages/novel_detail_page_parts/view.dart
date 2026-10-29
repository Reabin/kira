part of '../novel_detail_page.dart';

extension _NovelDetailViewPart on _NovelDetailPageState {
  /// 封面：与漫画详情页同款圆角裁剪、亮度过滤与占位图。
  /// 来源卡片传了 heroTagBase 时包裹 Hero，飞行期间占位保持卡片槽位。
  Widget _buildCover(NovelBook book) {
    final child = ClipRRect(
      borderRadius: AppRadius.mdR,
      child: SizedBox(
        width: 120,
        height: 160,
        child: CoverBrightnessFilter(
          child: book.cover.isEmpty
              ? const CoverPlaceholder()
              : CoverImage(url: book.cover, width: 120, height: 160),
        ),
      ),
    );
    final base = widget.heroTagBase;
    if (base == null) return child;
    return AppHero(
      tag: NovelHeroTags.cover(base),
      createRectTween: NovelHeroTags.createRectTween,
      placeholderBuilder: (_, heroSize, _) =>
          SizedBox(width: heroSize.width, height: heroSize.height),
      child: child,
    );
  }

  /// 标题下的元信息行：小图标 + 灰色小字，与漫画详情页的热度/更新时间行同款。
  Widget _buildMetaRow(IconData icon, String label, TextTheme tt, Color color) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: AppSpacing.xs),
        Text(label, style: tt.labelSmall?.copyWith(color: color)),
      ],
    );
  }

  String _statusLabel(NovelBook book) {
    final l10n = AppLocalizations.of(context)!;
    if (book.statusDisplay.isNotEmpty) return book.statusDisplay;
    if (book.status == 0) return l10n.novelSerializing;
    if (book.status == 1) return l10n.novelCompleted;
    return '';
  }

  /// 与漫画详情页完全同款文案：只有「收藏 / 已收藏」两态，不再造新词。
  /// 未登录或状态未知时显示「收藏」，点下去由 [_toggleCollect] 引导登录。
  String _collectLabel() {
    final l10n = AppLocalizations.of(context)!;
    return _collected == true ? l10n.alreadyCollectedLabel : l10n.collectButton;
  }

  /// 动作行按漫画详情页顺序：下载、评论、收藏。
  Widget _buildDetailActions(NovelBook book) {
    final l10n = AppLocalizations.of(context)!;
    final buttonStyle = FilledButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );

    return Row(
      children: [
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed:
                _enqueuingDownloads ||
                    (!_downloadSelectionMode &&
                        !_volumes.any(_isVolumeSelectable))
                ? null
                : _toggleDownloadSelectionMode,
            icon: Icon(
              _downloadSelectionMode ? Icons.close : Icons.download_outlined,
              size: 18,
            ),
            label: Text(
              _downloadSelectionMode
                  ? l10n.cancelButton
                  : l10n.downloadActionButton,
            ),
            style: buttonStyle,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: book.uuid.isEmpty ? null : _showComments,
            icon: const Icon(Icons.forum_outlined, size: 18),
            label: Text(l10n.chapterCommentsComment),
            style: buttonStyle,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: _collecting || _queryLoading || book.uuid.isEmpty
                ? null
                : _toggleCollect,
            // 用爱心区分「收藏」（服务端）与右上角的「书签」（本地）。
            icon: Icon(
              _collected == true ? Icons.favorite : Icons.favorite_border,
              size: 18,
            ),
            label: Text(_collectLabel()),
            style: buttonStyle,
          ),
        ),
      ],
    );
  }
}

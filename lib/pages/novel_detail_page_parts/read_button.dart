part of '../novel_detail_page.dart';

extension _NovelDetailReadButtonPart on _NovelDetailPageState {
  Widget _buildReadButton() {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final continuing = _hasLocalResume || _remoteVolumeId != null;
    // 按用户要求：按钮不显示「继续阅读/开始阅读」与章节名，
    // 单行显示卷名和百分比（不带「本卷」前缀）；图标与漫画详情页续读按钮一致。
    final volumeName = continuing
        ? (_resumeVolumeName ?? '')
        : _volumes.firstOrNull?.name ?? '';
    final percent = continuing ? _resumePercent : null;
    final progressLabel = percent == null ? null : '$percent%';

    return LayoutBuilder(
      builder: (context, constraints) {
        // Extended FAB 的内部 Row 不约束 label，必须单独限制其宽度。
        final labelWidth =
            (constraints.maxWidth -
                    AppSpacing.lg * 2 -
                    AppIconSize.lg -
                    AppSpacing.sm)
                .clamp(0.0, double.infinity);
        return Align(
          alignment: Alignment.centerRight,
          child: Theme(
            data: theme.copyWith(
              floatingActionButtonTheme: theme.floatingActionButtonTheme
                  .copyWith(
                    // 保持常规 FAB 最小高度，允许大字号下按内容增高。
                    extendedSizeConstraints: const BoxConstraints(
                      minHeight: 56,
                    ),
                  ),
            ),
            child: FloatingActionButton.extended(
              heroTag: 'novel_continue_reading',
              onPressed: _canRead ? () => _read() : null,
              tooltip: [
                continuing ? l10n.novelContinueReading : l10n.novelStartReading,
                if (volumeName.isNotEmpty) volumeName,
                ?progressLabel,
              ].join(' · '),
              extendedPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
              ),
              extendedIconLabelSpacing: AppSpacing.sm,
              icon: const Icon(Icons.play_arrow, size: AppIconSize.lg),
              label: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: labelWidth),
                // 单行：卷名 · 百分比，超长省略，不再折成两行。
                child: Text(
                  [
                    if (volumeName.isNotEmpty) volumeName,
                    ?progressLabel,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.fabLabel(theme.textTheme),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

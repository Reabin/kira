part of '../novel_detail_page.dart';

extension _NovelDetailBodyPart on _NovelDetailPageState {
  /// 横屏（宽 > 高且 ≥640）时左右分栏：左侧轻小说信息 + 简介 + 操作按钮，
  /// 右侧分卷目录，与漫画详情页同款断点与栏宽。
  Widget _buildBody(NovelBook book) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);
    final infoSlivers = _buildInfoSlivers(cs, tt, book);
    final volumeSlivers = _buildVolumeSlivers();

    if (!comicDetailUsesTwoPane(size)) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [...infoSlivers, ...volumeSlivers],
        ),
      );
    }

    final leftWidth = comicDetailInfoPaneWidth(size);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: leftWidth,
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                ...infoSlivers,
                const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
              ],
            ),
          ),
        ),
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: cs.outlineVariant.withValues(alpha: 0.6),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: CustomScrollView(slivers: volumeSlivers),
          ),
        ),
      ],
    );
  }
}

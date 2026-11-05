import 'package:flutter/material.dart';
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';

/// 列表底部的「加载更多」按钮。
///
/// 宽屏下一页结果可能不满一屏、列表不可滚动，近底自动加载永远等不到
/// 触发——这个显式按钮是那种场景下的兜底入口；可滚动的列表里它同时
/// 充当底部加载指示，与自动加载互不冲突（由各页 `_loadMore` 守卫防重）。
class LoadMoreFooter extends StatelessWidget {
  const LoadMoreFooter({
    super.key,
    required this.loading,
    required this.onPressed,
    required this.label,
    this.detail,
    this.horizontalPadding = 0,
  });

  final bool loading;
  final VoidCallback onPressed;
  final String label;

  /// 上一页失败的具体原因（`NetworkError.describe` 的结果）。只显示
  /// 「加载失败」会让用户无法把错误反馈成可排查的信息。
  final String? detail;

  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = this.detail?.trim() ?? '';
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 4, horizontalPadding, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: loading
                ? const SizedBox.square(
                    dimension: 28,
                    child: ExpressiveLoadingIndicator(),
                  )
                : OutlinedButton.icon(
                    onPressed: onPressed,
                    icon: const Icon(Icons.expand_more_rounded),
                    label: Text(label),
                  ),
          ),
          if (!loading && detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                detail,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

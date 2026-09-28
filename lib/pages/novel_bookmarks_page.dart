import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/app_localizations.dart';
import '../providers/novel_providers.dart';
import '../routing/app_router.dart';
import '../theme/app_icon_sizes.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import '../utils/app_logger.dart';
import '../utils/novel_bookmark_store.dart';
import '../utils/novel_chapter_display.dart';
import '../utils/screen_layout.dart';
import '../utils/time_format.dart';
import '../utils/toast.dart';
import '../widgets/error_retry_view.dart';
import '../widgets/novel_widgets.dart';

/// 统一书签页的轻小说分页，不查询网络目录，也不改写最后阅读进度。
class NovelBookmarksPage extends ConsumerStatefulWidget {
  const NovelBookmarksPage({super.key, required this.onChanged});

  final VoidCallback onChanged;

  @override
  ConsumerState<NovelBookmarksPage> createState() => NovelBookmarksPageState();
}

class NovelBookmarksPageState extends ConsumerState<NovelBookmarksPage>
    with AutomaticKeepAliveClientMixin {
  late final NovelBookmarkStore _store;
  ScaffoldMessengerState? _messenger;
  bool _loading = true;
  bool _failed = false;
  bool _updating = false;

  bool get hasBookmarks =>
      !_loading && !_updating && _store.bookmarks.isNotEmpty;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _store = ref.read(novelBookmarkStoreProvider)..addListener(_onStoreChanged);
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.of(context);
  }

  @override
  void dispose() {
    _messenger?.clearSnackBars();
    _store.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    setState(() {});
    widget.onChanged();
  }

  Future<void> _load({bool refresh = false}) async {
    try {
      if (refresh) {
        await _store.reload();
      } else {
        await _store.ensureLoaded();
      }
      if (mounted) setState(() => _failed = false);
    } catch (error, stack) {
      _logFailure(error, stack);
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        widget.onChanged();
      }
    }
  }

  void _logFailure(Object error, StackTrace stack) {
    unawaited(
      AppLogger.instance.recordWarning(
        'Novel bookmark page operation failed (${error.runtimeType})',
        stackTrace: stack,
        source: 'novel_bookmarks_page',
      ),
    );
  }

  Future<void> _update(
    Future<List<NovelBookmark>> Function() action, {
    bool undo = false,
  }) async {
    if (_updating) return;
    setState(() => _updating = true);
    widget.onChanged();
    try {
      final removed = await action();
      if (mounted && !undo && removed.isNotEmpty) _showUndo(removed);
    } catch (error, stack) {
      _logFailure(error, stack);
      if (mounted) {
        showToast(
          context,
          AppLocalizations.of(context)!.bookmarksUpdateFailed,
          isError: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _updating = false);
        widget.onChanged();
      }
    }
  }

  Future<void> _remove(NovelBookmark bookmark) => _update(() async {
    final removed = await _store.remove(bookmark.id);
    return removed == null ? const [] : [removed];
  });

  Future<void> _clearGroup(String pathWord) =>
      _update(() => _store.removeForNovel(pathWord));

  Future<void> clearAll() async {
    if (!hasBookmarks) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.bookmarksClearTitle),
        content: Text(l10n.bookmarksTabClearContent(l10n.historyTabNovel)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.cacheClearButton),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _update(_store.clear);
  }

  void _showUndo(List<NovelBookmark> removed) {
    final l10n = AppLocalizations.of(context)!;
    final style = TextButton.styleFrom(
      foregroundColor: Theme.of(context).colorScheme.onInverseSurface,
    );
    _messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.fixed,
          duration: const Duration(seconds: 5),
          content: Row(
            children: [
              Expanded(
                child: Text(
                  removed.length == 1
                      ? l10n.bookmarkDeleted
                      : l10n.bookmarksGroupDeleted(removed.length),
                ),
              ),
              TextButton(
                style: style,
                onPressed: () {
                  _messenger?.hideCurrentSnackBar();
                  unawaited(
                    _update(() async {
                      await _store.restoreAll(removed);
                      return const [];
                    }, undo: true),
                  );
                },
                child: Text(l10n.bookmarkUndo),
              ),
              TextButton(
                style: style,
                onPressed: () => _messenger?.hideCurrentSnackBar(),
                child: Text(l10n.closeButton),
              ),
            ],
          ),
        ),
      );
  }

  Future<void> _open(NovelBookmark bookmark, {bool details = false}) async {
    _messenger?.clearSnackBars();
    if (details) {
      await context.pushNamed(
        AppRoutes.novelDetail,
        pathParameters: {'pathWord': bookmark.pathWord},
      );
    } else {
      await context.pushNamed(
        AppRoutes.novelReader,
        pathParameters: {
          'pathWord': bookmark.pathWord,
          'volumeId': bookmark.volumeId,
        },
        extra: NovelReaderExtra(
          name: bookmark.name,
          cover: bookmark.cover,
          entryIndex: bookmark.entryIndex,
          initialParagraphIndex: bookmark.paragraphIndex,
          initialParagraphAlignment: bookmark.paragraphAlignment,
          noDetailBelow: true,
          // 书签进入时短暂高亮目标段落。
          highlightParagraph: true,
        ),
      );
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final groups = <String, List<NovelBookmark>>{};
    for (final bookmark in _store.bookmarks) {
      groups.putIfAbsent(bookmark.pathWord, () => []).add(bookmark);
    }
    final entries = groups.entries.toList();
    final hp = ScreenLayout.horizontalPadding(MediaQuery.sizeOf(context).width);

    if (_loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: CustomScrollView(
        key: const PageStorageKey('novel_bookmarks_list'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (_failed)
            SliverErrorRetryView(
              message: l10n.bookmarksLoadFailed,
              onRetry: () => _load(refresh: true),
            )
          else if (entries.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xxl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.bookmark_border,
                        size: AppIconSize.display,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Text(
                        l10n.bookmarksEmptyTitle,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        l10n.novelBookmarksEmptySubtitle,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else ...[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                hp,
                AppSpacing.sm,
                hp,
                AppSpacing.md,
              ),
              sliver: SliverList.separated(
                itemCount: entries.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppSpacing.md),
                itemBuilder: (context, index) => _NovelBookmarkGroupCard(
                  bookmarks: entries[index].value,
                  updating: _updating,
                  onOpen: _open,
                  onDetails: (bookmark) => _open(bookmark, details: true),
                  onRemove: _remove,
                  onClear: () => _clearGroup(entries[index].key),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                child: Text(
                  l10n.bookmarksSwipeHint,
                  textAlign: TextAlign.center,
                  style: AppTypography.meta(
                    theme.textTheme,
                  )?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NovelBookmarkGroupCard extends StatelessWidget {
  const _NovelBookmarkGroupCard({
    required this.bookmarks,
    required this.updating,
    required this.onOpen,
    required this.onDetails,
    required this.onRemove,
    required this.onClear,
  });

  final List<NovelBookmark> bookmarks;
  final bool updating;
  final Future<void> Function(NovelBookmark) onOpen;
  final Future<void> Function(NovelBookmark) onDetails;
  final Future<void> Function(NovelBookmark) onRemove;
  final Future<void> Function() onClear;

  /// 百分比保留两位小数；未到结尾不得四舍五入成 100%。
  static String _percentLabel(double progress) {
    if (progress >= 1) return '100.00';
    final percent = progress * 100;
    return (percent > 99.99 ? 99.99 : percent).toStringAsFixed(2);
  }

  Widget _dismissible({
    required String id,
    required Widget child,
    required Future<void> Function() remove,
    required ColorScheme cs,
  }) => Dismissible(
    key: ValueKey(id),
    direction: updating ? DismissDirection.none : DismissDirection.endToStart,
    background: Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: AppSpacing.xl),
      color: cs.errorContainer,
      child: Icon(Icons.delete_outline, color: cs.onErrorContainer),
    ),
    // 等待落盘后由 store 通知移除条目；失败时保留，不留下已滑走的假删除。
    confirmDismiss: (_) async {
      await remove();
      return false;
    },
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final first = bookmarks.first;
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final name = bookmarks
        .map((bookmark) => bookmark.name)
        .firstWhere((name) => name.isNotEmpty, orElse: () => first.pathWord);
    final cover = bookmarks
        .map((bookmark) => bookmark.cover)
        .firstWhere((cover) => cover.isNotEmpty, orElse: () => '');
    return Card(
      margin: EdgeInsets.zero,
      color: cs.surfaceBright,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _dismissible(
            id: 'novel_bookmark_group_${first.pathWord}',
            cs: cs,
            remove: onClear,
            child: InkWell(
              key: ValueKey('novel_bookmark_details_${first.pathWord}'),
              onTap: () => onDetails(first),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 44,
                      child: AspectRatio(
                        aspectRatio: 0.72,
                        child: CardTheme(
                          data: CardTheme.of(context).copyWith(elevation: 0),
                          child: NovelCover(url: cover),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            l10n.bookmarksCount(bookmarks.length),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Divider(
            height: 1,
            indent: AppSpacing.md,
            endIndent: AppSpacing.md,
          ),
          for (final bookmark in bookmarks)
            _dismissible(
              id: 'novel_bookmark_${bookmark.id}',
              cs: cs,
              remove: () => onRemove(bookmark),
              child: ListTile(
                key: ValueKey('novel_bookmark_open_${bookmark.id}'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                ),
                horizontalTitleGap: AppSpacing.sm,
                minLeadingWidth: AppIconSize.sm,
                leading: Icon(
                  Icons.bookmark,
                  size: AppIconSize.sm,
                  color: cs.primary,
                ),
                title: Text(
                  [
                    bookmark.volumeName,
                    stripVolumePrefix(
                      bookmark.chapterName,
                      bookmark.volumeName,
                    ),
                  ].where((part) => part.isNotEmpty).join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: Text(
                  '${l10n.novelVolumeProgress(_percentLabel(bookmark.progress))}'
                  ' · ${TimeFormat.relative(bookmark.updatedAt, l10n)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.meta(
                    theme.textTheme,
                  )?.copyWith(color: cs.onSurfaceVariant),
                ),
                onTap: () => onOpen(bookmark),
                // 与漫画书签条目一致：尾部只放导航箭头，删除走左滑。
                trailing: Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../api/novel/novel_api.dart' show novelErrorMessage;
import '../../l10n/app_localizations.dart';
import '../../models/novel.dart';
import '../../repositories/novel_reader_source.dart';
import '../../repositories/novel_repository.dart';
import '../../theme/app_icon_sizes.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_spacing.dart';
import '../../utils/app_logger.dart';
import '../../utils/novel_chapter_display.dart';
import '../../widgets/error_retry_view.dart';
import '../../widgets/select_tile.dart';
import 'novel_reader_illustrations.dart';

/// 目录抽屉「总目录」按钮的返回哨兵：阅读页收到后退出阅读、回到小说详情。
/// 选章则照旧返回 (volumeId, entryIndex)。
class NovelReaderCatalogExit {
  const NovelReaderCatalogExit();
}

const novelReaderCatalogExit = NovelReaderCatalogExit();

class NovelReaderContentsSheet extends StatefulWidget {
  const NovelReaderContentsSheet({
    super.key,
    required this.repository,
    this.source,
    required this.pathWord,
    required this.volumeId,
    required this.entryIndex,
    this.detail,
    this.volumes,
    this.loadVolumes,
    this.volumeDetails,
    this.onDetailLoaded,
  });

  final NovelRepository repository;
  final NovelReaderSource? source;
  final String pathWord;
  final String volumeId;
  final int entryIndex;
  final NovelVolumeDetail? detail;

  /// 复用阅读会话的目录快照/在途请求，打开抽屉不额外刷新网络。
  final List<NovelVolume>? volumes;
  final Future<List<NovelVolume>> Function()? loadVolumes;
  final Map<String, NovelVolumeDetail>? volumeDetails;
  final ValueChanged<NovelVolumeDetail>? onDetailLoaded;

  @override
  State<NovelReaderContentsSheet> createState() =>
      _NovelReaderContentsSheetState();
}

class _NovelReaderContentsSheetState extends State<NovelReaderContentsSheet> {
  late List<NovelVolume> _volumes = widget.volumes ?? [];
  late String _selected = widget.volumeId;
  late final Map<String, NovelVolumeDetail> _details = {
    ...?widget.volumeDetails,
  };
  late NovelVolumeDetail? _detail = _details[_selected];
  bool _loading = false;
  bool _volumesLoading = true;
  bool _volumesFailed = false;
  Object? _volumesError;
  bool _detailFailed = false;
  Object? _detailError;
  int _request = 0;
  final _itemScrollController = ItemScrollController();

  NovelReaderSource get _source =>
      widget.source ?? RepositoryNovelReaderSource(widget.repository);

  @override
  void initState() {
    super.initState();
    if (widget.detail case final detail?) {
      _details[detail.volume.id] = detail;
    }
    if (widget.volumes == null) {
      unawaited(_loadVolumes());
    } else {
      _volumesLoading = false;
    }
    if (_detail == null) unawaited(_loadDetail(_selected));
  }

  Future<void> _loadVolumes() async {
    setState(() {
      _volumesLoading = true;
      _volumesFailed = false;
    });
    try {
      final volumes =
          await (widget.loadVolumes?.call() ??
              _source.loadVolumes(widget.pathWord));
      if (!mounted) return;
      setState(() => _volumes = volumes);
    } catch (error, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          error,
          stackTrace: stack,
          source: 'novel_reader.contents.volumes',
        ),
      );
      if (mounted) {
        setState(() {
          _volumesFailed = true;
          _volumesError = error;
        });
      }
    } finally {
      if (mounted) setState(() => _volumesLoading = false);
    }
  }

  Future<void> _loadDetail(String id) async {
    final request = ++_request;
    setState(() {
      _selected = id;
      _loading = true;
      _detailFailed = false;
    });
    try {
      final detail =
          _details[id] ?? await _source.loadVolumeDetail(widget.pathWord, id);
      if (!mounted) return;
      _details[id] = detail;
      widget.onDetailLoaded?.call(detail);
      if (request != _request) return;
      setState(() => _detail = detail);
    } catch (error, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          error,
          stackTrace: stack,
          source: 'novel_reader.contents.detail',
        ),
      );
      if (mounted && request == _request) {
        setState(() {
          _detailFailed = true;
          _detailError = error;
        });
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final choices = {for (final volume in _volumes) volume.id: volume.name};
    choices.putIfAbsent(
      widget.volumeId,
      () => widget.detail?.volume.name ?? l10n.novelReaderVolume,
    );
    choices.putIfAbsent(
      _selected,
      () => _detail?.volume.id == _selected
          ? _detail!.volume.name
          : l10n.novelReaderVolume,
    );
    final detail = _detail?.volume.id == _selected ? _detail : null;
    final entries = detail?.volume.contents ?? <NovelContentEntry>[];
    // 展示序号与原始目录索引分离，插图合并后选章仍返回原始索引。
    final chapters = [
      for (final indexed in entries.indexed)
        if (!indexed.$2.isImage) indexed,
    ];
    final illustrations = entries.where((entry) => entry.isImage).toList();
    final currentRow = _selected == widget.volumeId
        ? chapters.indexWhere((entry) => entry.$1 == widget.entryIndex)
        : -1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Semantics(
                    label: l10n.novelReaderVolume,
                    child: SelectTile<String>(
                      key: ValueKey('novel-volume-$_selected'),
                      value: _selected,
                      leadingIcon: Icons.menu_book_outlined,
                      menuMaxCharacters: 8,
                      items: [
                        for (final choice in choices.entries)
                          SelectItem(choice.key, choice.value),
                      ],
                      onChanged: (id) {
                        if (id != _selected) unawaited(_loadDetail(id));
                      },
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('novel-toc-close'),
                tooltip: l10n.closeButton,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 2,
            child: _volumesLoading ? const LinearProgressIndicator() : null,
          ),
          if (_volumesFailed)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _loadVolumes,
                icon: const Icon(Icons.refresh, size: AppIconSize.md),
                label: Text(
                  l10n.novelReaderVolumesRetryDetail(
                    novelErrorMessage(_volumesError),
                  ),
                ),
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: ExpressiveLoadingIndicator())
                : _detailFailed
                ? Center(
                    child: SingleChildScrollView(
                      child: ErrorRetryView(
                        message: _source.localOnly
                            ? l10n.novelDownloadUnavailable
                            : novelErrorMessage(_detailError),
                        onRetry: () => unawaited(_loadDetail(_selected)),
                      ),
                    ),
                  )
                : entries.isEmpty
                ? Center(child: Text(l10n.novelReaderEmptyVolume))
                : ScrollablePositionedList.builder(
                    key: ValueKey('novel-toc-list-$_selected-$_request'),
                    itemScrollController: _itemScrollController,
                    initialScrollIndex: currentRow > 4 ? currentRow - 1 : 0,
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.sm,
                    ),
                    itemCount:
                        chapters.length + (illustrations.isEmpty ? 0 : 1),
                    itemBuilder: (context, row) {
                      if (row == chapters.length) {
                        final locked = detail?.isLocked ?? false;
                        return Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.sm),
                          child: ListTile(
                            key: ValueKey('novel-toc-illustrations-$_selected'),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.md,
                            ),
                            leading: const Icon(Icons.collections_outlined),
                            title: Text(l10n.novelReaderIllustration),
                            subtitle: locked
                                ? Text(l10n.novelReaderLocked)
                                : null,
                            trailing: const Icon(
                              Icons.chevron_right,
                              size: AppIconSize.lg,
                            ),
                            enabled: !locked,
                            // 看图不关闭目录、不更改正文卷或阅读进度。
                            onTap: locked
                                ? null
                                : () => unawaited(
                                    showDialog<void>(
                                      context: context,
                                      useSafeArea: false,
                                      builder: (_) => NovelReaderIllustrations(
                                        volumeName: detail!.volume.name,
                                        illustrations: illustrations,
                                        loadBytes: (url) =>
                                            _source.loadImageBytes(
                                              widget.pathWord,
                                              _selected,
                                              url,
                                            ),
                                      ),
                                    ),
                                  ),
                          ),
                        );
                      }
                      final (index, entry) = chapters[row];
                      final selected = row == currentRow;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.xs,
                        ),
                        child: Material(
                          color: selected
                              ? cs.secondaryContainer
                              : Colors.transparent,
                          borderRadius: AppRadius.mdR,
                          clipBehavior: Clip.antiAlias,
                          child: ListTile(
                            key: ValueKey('novel-toc-entry-$index'),
                            selected: selected,
                            selectedColor: cs.onSecondaryContainer,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.md,
                            ),
                            leading: Text(
                              '${row + 1}'.padLeft(2, '0'),
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: selected
                                    ? cs.onSecondaryContainer
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                            title: Text(
                              entry.name.isEmpty
                                  ? l10n.novelReaderUnnamedChapter(index + 1)
                                  : stripVolumePrefix(
                                      entry.name,
                                      detail?.volume.name ?? '',
                                    ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: selected ? FontWeight.w600 : null,
                              ),
                            ),
                            onTap: () =>
                                Navigator.of(context).pop((_selected, index)),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          // 独立底部操作区，不再覆盖章节列表或依赖固定的避让高度。
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FloatingActionButton.extended(
                key: const ValueKey('novel-toc-catalog'),
                heroTag: 'novel-toc-catalog',
                tooltip: l10n.novelReaderCatalog,
                icon: const Icon(Icons.library_books_outlined),
                label: Text(l10n.novelReaderCatalog),
                onPressed: () =>
                    Navigator.of(context).pop(novelReaderCatalogExit),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

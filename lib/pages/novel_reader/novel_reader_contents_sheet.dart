import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/novel.dart';
import '../../repositories/novel_reader_source.dart';
import '../../repositories/novel_repository.dart';
import '../../theme/app_spacing.dart';
import '../../utils/app_logger.dart';
import '../../utils/novel_chapter_display.dart';
import '../../widgets/error_retry_view.dart';
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
  });

  final NovelRepository repository;
  final NovelReaderSource? source;
  final String pathWord;
  final String volumeId;
  final int entryIndex;
  final NovelVolumeDetail? detail;

  @override
  State<NovelReaderContentsSheet> createState() =>
      _NovelReaderContentsSheetState();
}

class _NovelReaderContentsSheetState extends State<NovelReaderContentsSheet> {
  List<NovelVolume> _volumes = [];
  late String _selected = widget.volumeId;
  late NovelVolumeDetail? _detail = widget.detail;
  bool _loading = false;
  bool _volumesLoading = true;
  bool _volumesFailed = false;
  bool _detailFailed = false;
  int _request = 0;

  NovelReaderSource get _source =>
      widget.source ?? RepositoryNovelReaderSource(widget.repository);

  @override
  void initState() {
    super.initState();
    unawaited(_loadVolumes());
    if (_detail == null) unawaited(_loadDetail(_selected));
  }

  Future<void> _loadVolumes() async {
    setState(() {
      _volumesLoading = true;
      _volumesFailed = false;
    });
    try {
      final volumes = await _source.loadVolumes(widget.pathWord);
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
      if (mounted) setState(() => _volumesFailed = true);
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
      final detail = id == widget.volumeId && widget.detail != null
          ? widget.detail!
          : await _source.loadVolumeDetail(widget.pathWord, id);
      if (!mounted || request != _request) return;
      setState(() => _detail = detail);
    } catch (error, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          error,
          stackTrace: stack,
          source: 'novel_reader.contents.detail',
        ),
      );
      if (mounted && request == _request) setState(() => _detailFailed = true);
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final choices = {for (final volume in _volumes) volume.id: volume.name};
    choices.putIfAbsent(
      _selected,
      () => _detail?.volume.id == _selected
          ? _detail!.volume.name
          : l10n.novelReaderVolume,
    );
    final entries = _detail?.volume.contents ?? <NovelContentEntry>[];
    // Group only the presentation. Text selections keep the original contents
    // indices, including gaps occupied by illustrations and unknown entries.
    final chapters = [
      for (final indexed in entries.indexed)
        if (!indexed.$2.isImage) indexed,
    ];
    final illustrations = entries.where((entry) => entry.isImage).toList();
    final illustrationCount = illustrations.isEmpty ? 0 : 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.novelReaderContents,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.md),
          DropdownButtonFormField<String>(
            key: ValueKey('novel-volume-$_selected'),
            initialValue: _selected,
            isExpanded: true,
            decoration: InputDecoration(labelText: l10n.novelReaderVolume),
            items: [
              for (final choice in choices.entries)
                DropdownMenuItem(
                  value: choice.key,
                  child: Text(choice.value, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (id) {
              if (id != null && id != _selected) unawaited(_loadDetail(id));
            },
          ),
          if (_volumesLoading) const LinearProgressIndicator(),
          if (_volumesFailed)
            TextButton.icon(
              onPressed: _loadVolumes,
              icon: const Icon(Icons.refresh),
              label: Text(l10n.novelReaderVolumesRetry),
            ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: Stack(
              children: [
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else if (_detailFailed)
                  Center(
                    child: SingleChildScrollView(
                      child: ErrorRetryView(
                        message: _source.localOnly
                            ? l10n.novelDownloadUnavailable
                            : null,
                        onRetry: () => unawaited(_loadDetail(_selected)),
                      ),
                    ),
                  )
                else if (entries.isEmpty)
                  Center(child: Text(l10n.novelReaderEmptyVolume))
                else
                  ListView.builder(
                    padding: const EdgeInsets.only(bottom: 72),
                    itemCount: chapters.length + illustrationCount,
                    itemBuilder: (context, row) {
                      if (row == chapters.length) {
                        final locked = _detail?.isLocked ?? false;
                        return ListTile(
                          key: ValueKey('novel-toc-illustrations-$_selected'),
                          leading: const Icon(Icons.collections_outlined),
                          title: Text(l10n.novelReaderIllustration),
                          subtitle: locked
                              ? Text(l10n.novelReaderLocked)
                              : null,
                          trailing: const Icon(Icons.chevron_right),
                          enabled: !locked,
                          // Do not pop the contents sheet or return a reader
                          // selection. The reader remains at its text anchor.
                          onTap: locked
                              ? null
                              : () => unawaited(
                                  showDialog<void>(
                                    context: context,
                                    useSafeArea: false,
                                    builder: (_) => NovelReaderIllustrations(
                                      volumeName: _detail!.volume.name,
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
                        );
                      }
                      final (index, entry) = chapters[row];
                      final selected =
                          _selected == widget.volumeId &&
                          index == widget.entryIndex;
                      final volumeName = _detail?.volume.name ?? '';
                      return ListTile(
                        key: ValueKey('novel-toc-entry-$index'),
                        selected: selected,
                        leading: const Icon(Icons.subject),
                        title: Text(
                          entry.name.isEmpty
                              ? l10n.novelReaderUnnamedChapter(index + 1)
                              : stripVolumePrefix(entry.name, volumeName),
                        ),
                        onTap: () =>
                            Navigator.of(context).pop((_selected, index)),
                      );
                    },
                  ),
                Positioned(
                  right: 0,
                  bottom: AppSpacing.sm,
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

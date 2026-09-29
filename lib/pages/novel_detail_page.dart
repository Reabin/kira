import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';

import '../l10n/app_localizations.dart';
import '../models/novel.dart';
import '../models/novel_download.dart';
import '../models/novel_reading_progress.dart';
import '../models/user_manager.dart';
import '../providers/app_providers.dart';
import '../providers/novel_providers.dart';
import '../routing/app_router.dart';
import '../theme/app_icon_sizes.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import '../utils/app_logger.dart';
import '../utils/cover_brightness_filter.dart';
import '../utils/download_manager.dart';
import '../utils/time_format.dart';
import '../utils/toast.dart';
import '../widgets/app_sheet.dart';
import '../widgets/comic_info_chips.dart';
import '../widgets/cover_placeholder.dart';
import '../widgets/download_settings_sheet.dart';
import '../widgets/error_retry_view.dart';
import '../widgets/novel_comments_sheet.dart';
import '../widgets/novel_widgets.dart';
import 'comic_detail_page.dart'
    show
        ChapterCard,
        chapterTileExtent,
        comicDetailUsesTwoPane,
        comicDetailInfoPaneWidth;
import 'novel_filter_page.dart';

class NovelDetailPage extends ConsumerStatefulWidget {
  const NovelDetailPage({super.key, required this.pathWord});

  final String pathWord;

  @override
  ConsumerState<NovelDetailPage> createState() => _NovelDetailPageState();
}

class _NovelDetailPageState extends ConsumerState<NovelDetailPage> {
  late final UserManager _user = ref.read(userManagerProvider);
  late final _downloads = ref.read(novelDownloadManagerProvider);
  NovelDetail? _detail;
  NovelQuery? _query;
  NovelReadingProgress? _progress;
  List<NovelVolume> _volumes = [];
  final Set<String> _selectedDownloadVolumes = {};
  bool _downloadSelectionMode = false;
  bool _enqueuingDownloads = false;
  bool _detailLoading = true;
  bool _detailFailed = false;
  bool _volumesLoading = true;
  bool _volumesFailed = false;
  bool _queryLoading = true;
  bool _queryFailed = false;
  bool _progressLoading = true;
  bool _progressFailed = false;
  bool? _collected;
  bool _collecting = false;
  bool _opening = false;
  bool _briefExpanded = false;
  String? _token;
  int _detailGeneration = 0;
  int _volumeGeneration = 0;
  int _queryGeneration = 0;
  int _progressGeneration = 0;
  int _accountGeneration = 0;

  @override
  void initState() {
    super.initState();
    _token = _user.copyToken;
    _user.addListener(_onAccountChanged);
    _downloads.addListener(_onDownloadsChanged);
    unawaited(_refresh(refresh: false));
  }

  @override
  void didUpdateWidget(covariant NovelDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pathWord == widget.pathWord) return;
    ++_accountGeneration;
    _detail = null;
    _query = null;
    _progress = null;
    _volumes = [];
    _selectedDownloadVolumes.clear();
    _downloadSelectionMode = false;
    _collected = null;
    _collecting = false;
    unawaited(_refresh(refresh: false));
  }

  @override
  void dispose() {
    _user.removeListener(_onAccountChanged);
    _downloads.removeListener(_onDownloadsChanged);
    super.dispose();
  }

  void _onDownloadsChanged() {
    if (!mounted) return;
    setState(() {
      _selectedDownloadVolumes.retainAll(
        _volumes.where(_isVolumeSelectable).map((volume) => volume.id),
      );
    });
  }

  void _onAccountChanged() {
    if (!mounted || _token == _user.copyToken) return;
    _token = _user.copyToken;
    ++_accountGeneration;
    setState(() {
      _query = null;
      _collected = null;
      _collecting = false;
    });
    unawaited(_loadQuery());
    unawaited(_loadDetail(refresh: true));
  }

  Future<void> _refresh({bool refresh = true}) async {
    await Future.wait([
      _loadDetail(refresh: refresh),
      _loadVolumes(refresh: refresh),
      _loadQuery(),
      _loadProgress(),
    ]);
  }

  void _log(Object e, StackTrace stack, String operation) {
    unawaited(
      AppLogger.instance.recordWarning(
        e,
        stackTrace: stack,
        source: 'novel_detail.$operation',
      ),
    );
  }

  Future<void> _loadDetail({bool refresh = false}) async {
    final generation = ++_detailGeneration;
    setState(() {
      _detailLoading = true;
      _detailFailed = false;
    });
    try {
      final detail = await ref
          .read(novelRepositoryProvider)
          .loadDetail(widget.pathWord, refresh: refresh);
      if (!mounted || generation != _detailGeneration) return;
      setState(() => _detail = detail);
    } catch (e, stack) {
      _log(e, stack, 'load');
      if (mounted && generation == _detailGeneration) {
        setState(() => _detailFailed = true);
      }
    } finally {
      if (mounted && generation == _detailGeneration) {
        setState(() => _detailLoading = false);
      }
    }
  }

  Future<void> _loadVolumes({bool refresh = false}) async {
    final generation = ++_volumeGeneration;
    setState(() {
      _volumesLoading = true;
      _volumesFailed = false;
    });
    try {
      final volumes = await ref
          .read(novelRepositoryProvider)
          .loadVolumes(widget.pathWord, refresh: refresh);
      if (!mounted || generation != _volumeGeneration) return;
      setState(() {
        _volumes = volumes;
        _selectedDownloadVolumes.retainAll(
          _volumes.where(_isVolumeSelectable).map((volume) => volume.id),
        );
      });
    } catch (e, stack) {
      _log(e, stack, 'volumes');
      if (mounted && generation == _volumeGeneration) {
        setState(() => _volumesFailed = true);
      }
    } finally {
      if (mounted && generation == _volumeGeneration) {
        setState(() => _volumesLoading = false);
      }
    }
  }

  Future<void> _loadQuery() async {
    final generation = ++_queryGeneration;
    setState(() {
      _queryLoading = true;
      _queryFailed = false;
      _collected = null;
    });
    try {
      final query = await ref.read(novelApiProvider).getQuery(widget.pathWord);
      if (!mounted || generation != _queryGeneration) return;
      setState(() {
        _query = query;
        // collect is a nullable collection association, never a popularity
        // count. A failed/anonymous query must not assert "not collected".
        _collected = _user.isCopyLoggedIn && query.isLoggedIn
            ? query.collect != null
            : null;
      });
    } catch (e, stack) {
      _log(e, stack, 'query');
      if (mounted && generation == _queryGeneration) {
        setState(() => _queryFailed = true);
      }
    } finally {
      if (mounted && generation == _queryGeneration) {
        setState(() => _queryLoading = false);
      }
    }
  }

  Future<void> _loadProgress() async {
    final generation = ++_progressGeneration;
    setState(() => _progressLoading = true);
    try {
      final progress = await ref
          .read(novelReadingStoreProvider)
          .readProgress(widget.pathWord);
      if (!mounted || generation != _progressGeneration) return;
      setState(() {
        _progress = progress;
        _progressFailed = false;
      });
    } catch (e, stack) {
      _log(e, stack, 'progress');
      if (mounted && generation == _progressGeneration) {
        setState(() => _progressFailed = true);
      }
    } finally {
      if (mounted && generation == _progressGeneration) {
        setState(() => _progressLoading = false);
      }
    }
  }

  Future<void> _login() async {
    await context.pushNamed(
      AppRoutes.login,
      queryParameters: {'copyOnly': 'true'},
    );
    if (mounted) await _loadQuery();
  }

  Future<void> _toggleCollect() async {
    if (_collecting) return;
    if (!_user.isCopyLoggedIn || _query?.isLoggedIn == false) return _login();
    final collected = _collected;
    if (collected == null) return _loadQuery();
    final book = _detail?.book;
    if (book == null || book.uuid.isEmpty) return;
    final account = _accountGeneration;
    ++_queryGeneration;
    setState(() {
      _collecting = true;
      _queryLoading = false;
    });
    try {
      await ref
          .read(novelApiProvider)
          .setCollected(bookUuid: book.uuid, collected: !collected);
    } catch (e, stack) {
      _log(e, stack, 'collect');
      if (mounted && account == _accountGeneration) {
        setState(() => _collecting = false);
        showToast(
          context,
          AppLocalizations.of(context)!.novelCollectFailed,
          isError: true,
        );
      }
      return;
    }
    if (!mounted || account != _accountGeneration) return;
    ++_queryGeneration;
    setState(() {
      _collected = !collected;
      _queryLoading = false;
      _collecting = false;
    });
    // Update the visible state as soon as the mutation succeeds. Cache cleanup
    // is independent persistence work and must not delay the user feedback.
    try {
      await ref.read(novelShelfRepoProvider).invalidateCache();
    } catch (e, stack) {
      _log(e, stack, 'invalidate_shelf');
    }
  }

  bool get _hasLocalResume => _progress?.volumeId.isNotEmpty == true;

  /// 读过的卷：历史集合 + 当前进度所在卷（旧记录无集合时兜底）。
  Set<String> get _readVolumeIds => {
    ...?_progress?.readVolumeIds,
    if (_hasLocalResume) _progress!.volumeId,
  };

  String? get _remoteVolumeId {
    final id = _query?.browse?.chapterId;
    return id == null || id.isEmpty ? null : id;
  }

  bool get _canRead =>
      !_opening &&
      (_hasLocalResume ||
          (!_progressLoading &&
              !_queryLoading &&
              (_remoteVolumeId != null || _volumes.isNotEmpty)));

  /// 续读按钮只显示卷名：本地卷名优先，其次远端卷名，最后按目录取名。
  /// API 的章节名自带「第一卷 …」前缀，按钮不再拼接章节名。
  String? get _resumeVolumeName {
    final local = _hasLocalResume ? _progress : null;
    final id = local?.volumeId ?? _remoteVolumeId;
    final names = [
      if (local != null) local.volumeName,
      if (local == null) _query?.browse?.chapterName ?? '',
      _volumes.where((volume) => volume.id == id).firstOrNull?.name ?? '',
    ];
    return names
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .firstOrNull;
  }

  String? get _resumePercent {
    final local = _hasLocalResume ? _progress : null;
    if (local == null) return null;
    // Reader 保存的是整卷段落位置比例（包含插图/空章节占位），不是目录索引。
    // 旧记录缺少 progress 时会解码为 0；非卷首锚点不能据此声称读了 0%。
    final ratio = local.progress;
    if (ratio == 0 &&
        (local.entryIndex > 0 ||
            local.paragraphIndex > 0 ||
            local.paragraphAlignment < 0)) {
      return null;
    }
    if (ratio == 1) return '100.00';
    final percent = ratio * 100;
    // 可以四舍五入到两位小数，但不能把尚未到达结尾的位置显示成已读完。
    final capped = ratio < 1 && percent > 99.99 ? 99.99 : percent;
    return capped.toStringAsFixed(2);
  }

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

  Future<void> _read({NovelVolume? volume}) async {
    if (_opening) return;
    final local = volume == null && _hasLocalResume ? _progress : null;
    final id =
        volume?.id ??
        local?.volumeId ??
        _remoteVolumeId ??
        (_volumes.isEmpty ? null : _volumes.first.id);
    if (id == null || id.isEmpty) return;
    final book = _detail?.book;
    setState(() => _opening = true);
    try {
      await context.pushNamed(
        AppRoutes.novelReader,
        pathParameters: {'pathWord': widget.pathWord, 'volumeId': id},
        extra: NovelReaderExtra(
          name: local?.name ?? book?.name ?? '',
          cover: local?.cover ?? book?.cover ?? '',
          entryIndex: local?.entryIndex ?? 0,
          resume: volume == null && (local != null || _remoteVolumeId != null),
        ),
      );
      if (mounted) await _loadProgress();
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  // 已完成任务会从队列移除，本地卷（含待修复）也必须保留下载中心入口。
  bool get _hasDownloadTasks =>
      _downloads.tasks.any((task) => task.pathWord == widget.pathWord);

  bool get _hasDownloads =>
      _downloads.localVolumeIds(widget.pathWord).isNotEmpty ||
      _hasDownloadTasks;

  bool _isVolumeSelectable(NovelVolume volume) =>
      !_downloads.isVolumeDownloaded(widget.pathWord, volume.id) &&
      !_downloads.isVolumeQueued(widget.pathWord, volume.id);

  void _exitDownloadSelectionMode() {
    setState(() {
      _downloadSelectionMode = false;
      _selectedDownloadVolumes.clear();
    });
  }

  void _toggleDownloadSelectionMode() {
    if (_enqueuingDownloads) return;
    if (_downloadSelectionMode) {
      _exitDownloadSelectionMode();
    } else if (_volumes.any(_isVolumeSelectable)) {
      // 与漫画详情一致：主按钮只进入空选择态，不自动勾选或入队。
      setState(() {
        _downloadSelectionMode = true;
        _selectedDownloadVolumes.clear();
      });
    }
  }

  void _toggleDownloadSelection(NovelVolume volume) {
    if (_enqueuingDownloads || !_isVolumeSelectable(volume)) return;
    setState(() {
      _downloadSelectionMode = true;
      if (!_selectedDownloadVolumes.add(volume.id)) {
        _selectedDownloadVolumes.remove(volume.id);
      }
      // 清空勾选仍留在选择态，只有确认成功或显式取消才退出。
    });
  }

  void _selectAllDownloadableVolumes() {
    if (_enqueuingDownloads) return;
    final selectable = _volumes
        .where(_isVolumeSelectable)
        .map((volume) => volume.id)
        .toSet();
    final allSelected =
        selectable.isNotEmpty &&
        _selectedDownloadVolumes.containsAll(selectable);
    setState(() {
      // 再点全选只清空勾选，保持选择态，便于重新手动选择。
      _downloadSelectionMode = true;
      _selectedDownloadVolumes
        ..clear()
        ..addAll(allSelected ? const <String>{} : selectable);
    });
  }

  Future<void> _downloadSelectedVolumes() async {
    if (_enqueuingDownloads || !_downloadSelectionMode) return;
    final book = _detail?.book;
    if (book == null) return;
    final selectedVolumes = _volumes
        .where((volume) => _selectedDownloadVolumes.contains(volume.id))
        .where(_isVolumeSelectable)
        .toList(growable: false);
    if (selectedVolumes.isEmpty) return;
    final pathWord = widget.pathWord;
    setState(() => _enqueuingDownloads = true);
    try {
      await _downloads.enqueueVolumes(
        book: book,
        volumes: _volumes,
        selected: selectedVolumes,
      );
      if (!mounted || widget.pathWord != pathWord) return;
      _exitDownloadSelectionMode();
      showToast(context, AppLocalizations.of(context)!.downloadActionButton);
    } catch (error, stack) {
      _log(error, stack, 'download');
      if (mounted && widget.pathWord == pathWord) {
        showToast(
          context,
          AppLocalizations.of(context)!.refreshFailed,
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _enqueuingDownloads = false);
    }
  }

  /// 与漫画详情一致：选择工具栏上的设置按钮，打开统一的下载设置面板。
  Future<void> _showDownloadSettings() async {
    await showDownloadSettingsSheet(
      context,
      downloads: DownloadManager(),
      novelDownloads: _downloads,
    );
  }

  Future<void> _showComments() async {
    final book = _detail?.book;
    if (book == null || book.uuid.isEmpty) return;
    await showAppSheet<void>(
      context,
      heightFactor: 0.85,
      child: NovelCommentsSheet(
        bookUuid: book.uuid,
        bookName: book.name,
        allowPosting: !book.closeComment,
      ),
    );
  }

  /// 封面：与漫画详情页同款圆角裁剪、亮度过滤与占位图。
  Widget _buildCover(NovelBook book) {
    return ClipRRect(
      borderRadius: AppRadius.mdR,
      child: SizedBox(
        width: 120,
        height: 160,
        child: CoverBrightnessFilter(
          child: book.cover.isEmpty
              ? const CoverPlaceholder()
              : CachedNetworkImage(
                  imageUrl: book.cover,
                  width: 120,
                  height: 160,
                  fit: BoxFit.cover,
                  fadeInDuration: Duration.zero,
                  fadeOutDuration: Duration.zero,
                  placeholder: (_, _) => const CoverPlaceholder(),
                  errorWidget: (_, _, _) => const CoverPlaceholder.error(),
                ),
        ),
      ),
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
            icon: Icon(
              _collected == true ? Icons.bookmark : Icons.bookmark_border,
              size: 18,
            ),
            label: Text(_collectLabel()),
            style: buttonStyle,
          ),
        ),
      ],
    );
  }

  void _openTag(NovelTag tag, NovelFilterKind kind) {
    final pathWord = tag.pathWord.trim();
    if (pathWord.isEmpty) return;
    unawaited(
      context.pushNamed(
        AppRoutes.novelFilter,
        pathParameters: {'kind': kind.name, 'pathWord': pathWord},
        queryParameters: {'name': tag.name},
      ),
    );
  }

  List<Widget> _buildInfoSlivers(ColorScheme cs, TextTheme tt, NovelBook book) {
    final l10n = AppLocalizations.of(context)!;
    final authors = book.authors
        .where((author) => author.name.trim().isNotEmpty)
        .toList();
    final statusLabel = _statusLabel(book);

    return [
      // ── 轻小说信息卡片 ──
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCover(book),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tt.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (authors.isNotEmpty ||
                        statusLabel.isNotEmpty ||
                        book.regionDisplay.isNotEmpty ||
                        book.themes.isNotEmpty)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final author in authors)
                            InfoChip(
                              icon: Icons.person_outline,
                              label: author.name,
                              color: cs.primaryContainer,
                              textColor: cs.onPrimaryContainer,
                              onTap: author.pathWord.trim().isEmpty
                                  ? null
                                  : () => _openTag(
                                      author,
                                      NovelFilterKind.author,
                                    ),
                            ),
                          if (statusLabel.isNotEmpty)
                            InfoChip(
                              icon: Icons.timelapse,
                              label: statusLabel,
                              color: cs.primaryContainer,
                              textColor: cs.onPrimaryContainer,
                            ),
                          if (book.regionDisplay.isNotEmpty)
                            InfoChip(
                              icon: Icons.public,
                              label: book.regionDisplay,
                              color: cs.secondaryContainer,
                              textColor: cs.onSecondaryContainer,
                            ),
                          for (final theme in book.themes)
                            InfoChip(
                              icon: Icons.label_outline,
                              label: theme.name,
                              color: cs.tertiaryContainer,
                              textColor: cs.onTertiaryContainer,
                              onTap: theme.pathWord.trim().isEmpty
                                  ? null
                                  : () =>
                                        _openTag(theme, NovelFilterKind.theme),
                            ),
                        ],
                      ),
                    if (book.popular > 0) ...[
                      const SizedBox(height: 10),
                      _buildMetaRow(
                        Icons.local_fire_department,
                        formatPopularCount(context, book.popular),
                        tt,
                        cs.primary,
                      ),
                    ],
                    if (book.datetimeUpdated.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      _buildMetaRow(
                        Icons.update,
                        TimeFormat.relativeOf(book.datetimeUpdated, l10n),
                        tt,
                        cs.onSurfaceVariant,
                      ),
                    ],
                    if (book.lastChapterName case final name?) ...[
                      const SizedBox(height: AppSpacing.xs),
                      _buildMetaRow(
                        Icons.menu_book_outlined,
                        name,
                        tt,
                        cs.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      // ── 简介 ──（竖屏默认折叠 3 行，点击展开；宽屏左栏空间充裕，默认展开）
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Builder(
            builder: (context) {
              final expanded =
                  _briefExpanded ||
                  comicDetailUsesTwoPane(MediaQuery.sizeOf(context));
              final brief = book.brief.isEmpty ? l10n.novelNoBrief : book.brief;
              return GestureDetector(
                onTap: () => setState(() => _briefExpanded = !_briefExpanded),
                child: Text(
                  brief,
                  maxLines: expanded ? null : 3,
                  overflow: expanded ? null : TextOverflow.ellipsis,
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              );
            },
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _buildDetailActions(book),
        ),
      ),
      if (_detailFailed)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _loadDetail(refresh: true),
                icon: const Icon(Icons.refresh),
                label: Text(l10n.novelLoadFailed),
              ),
            ),
          ),
        ),
      if (_queryFailed)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _loadQuery,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.novelQueryFailed),
              ),
            ),
          ),
        ),
      if (_progressFailed)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _loadProgress,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.novelHistoryFailed),
              ),
            ),
          ),
        ),
    ];
  }

  List<Widget> _buildVolumeSlivers() {
    final l10n = AppLocalizations.of(context)!;
    return [
      if (_volumesLoading && _volumes.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: ExpressiveLoadingIndicator()),
          ),
        )
      else if (_volumesFailed)
        SliverToBoxAdapter(
          child: ErrorRetryView(
            message: l10n.novelVolumesFailed,
            onRetry: () => _loadVolumes(refresh: true),
          ),
        )
      else if (_volumes.isEmpty)
        SliverToBoxAdapter(child: NovelEmptyView(message: l10n.novelNoVolumes))
      else ...[
        if (_downloadSelectionMode)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                0,
              ),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                    ),
                    child: Text(
                      l10n.selectedCount(_selectedDownloadVolumes.length, '卷'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed:
                        _enqueuingDownloads ||
                            !_volumes.any(_isVolumeSelectable)
                        ? null
                        : _selectAllDownloadableVolumes,
                    child: Text(l10n.selectAll),
                  ),
                  IconButton(
                    tooltip: l10n.cancelButton,
                    onPressed: _enqueuingDownloads
                        ? null
                        : _exitDownloadSelectionMode,
                    icon: const Icon(Icons.close),
                  ),
                  FilledButton.tonalIcon(
                    onPressed:
                        _enqueuingDownloads || _selectedDownloadVolumes.isEmpty
                        ? null
                        : _downloadSelectedVolumes,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: Text(l10n.downloadActionButton),
                  ),
                  OutlinedButton(
                    onPressed: _showDownloadSettings,
                    child: Text(l10n.downloadSettingsTitle),
                  ),
                ],
              ),
            ),
          ),
        // 与漫画详情的章节区同款卡片网格：同样的卡片组件、同样的列宽与间距。
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            0,
          ),
          sliver: SliverGrid(
            delegate: SliverChildBuilderDelegate((_, index) {
              final volume = _volumes[index];
              final selected =
                  volume.id ==
                  (_hasLocalResume ? _progress?.volumeId : _remoteVolumeId);
              final task = _downloads.taskFor(widget.pathWord, volume.id);
              final downloaded = _downloads.isVolumeDownloaded(
                widget.pathWord,
                volume.id,
              );
              final queued = _downloads.isVolumeQueued(
                widget.pathWord,
                volume.id,
              );
              final downloading =
                  !downloaded &&
                  task?.status == NovelDownloadStatus.downloading &&
                  task!.total > 0;
              return ChapterCard(
                name: volume.name,
                subtitle: downloading
                    ? '${task.completed}/${task.total}'
                    : null,
                isSelected: _selectedDownloadVolumes.contains(volume.id),
                isLastRead: selected,
                isRead: _readVolumeIds.contains(volume.id),
                isDownloaded: downloaded,
                progressRatio: downloading ? task.progress : null,
                onTap:
                    _opening ||
                        _enqueuingDownloads ||
                        (_downloadSelectionMode && (downloaded || queued))
                    ? null
                    : _downloadSelectionMode
                    ? () => _toggleDownloadSelection(volume)
                    : () => _read(volume: volume),
                onLongPress:
                    _opening || _enqueuingDownloads || downloaded || queued
                    ? null
                    : () => _toggleDownloadSelection(volume),
              );
            }, childCount: _volumes.length),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 150,
              mainAxisExtent: chapterTileExtent(
                MediaQuery.textScalerOf(context).scale(1),
              ),
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
          ),
        ),
      ],
      SliverPadding(
        // 为随文字缩放增高的续读按钮留出滚动空间，避免遮住最后一行卷册。
        padding: EdgeInsets.only(
          bottom:
              96 *
                  MediaQuery.textScalerOf(
                    context,
                  ).scale(1).clamp(1.0, double.infinity) +
              (_hasDownloads ? 56 + AppSpacing.md : 0),
        ),
      ),
    ];
  }

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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final book = _detail?.book;
    final size = MediaQuery.sizeOf(context);
    final showReadButton = book != null || _canRead;
    final hasDownloads = _hasDownloads;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          book?.name ?? l10n.novelTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      // 继续阅读固定在右下角，与漫画详情页的续读入口同款、同位置。
      body: Stack(
        children: [
          if (book == null)
            (_detailLoading
                ? const Center(child: ExpressiveLoadingIndicator())
                : ErrorRetryView(
                    message: l10n.novelLoadFailed,
                    onRetry: () => _loadDetail(refresh: true),
                  ))
          else
            _buildBody(book),
          // 详情拉不到时也要能续读：轻小说进度是本机数据，离线可续。
          if (showReadButton || hasDownloads)
            Positioned(
              left: book != null && comicDetailUsesTwoPane(size)
                  ? comicDetailInfoPaneWidth(size) + 1 + AppSpacing.lg
                  : AppSpacing.lg,
              right: AppSpacing.lg,
              bottom: AppSpacing.lg,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 与漫画一致，下载中心固定在右下续读按钮上方。
                  if (hasDownloads)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: showReadButton ? AppSpacing.md : 0,
                      ),
                      child: FloatingActionButton(
                        heroTag: 'novel_download_center',
                        tooltip: l10n.downloadCenterTitle,
                        onPressed: () => context
                            .pushNamed(
                              AppRoutes.downloadCenter,
                              queryParameters: {
                                'tab': _hasDownloadTasks ? '2' : '1',
                              },
                            )
                            .then((_) => _onDownloadsChanged()),
                        child: const Icon(
                          Icons.download_for_offline,
                          size: AppIconSize.xl,
                        ),
                      ),
                    ),
                  if (showReadButton) _buildReadButton(),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

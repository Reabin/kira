import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/user_manager.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_status_colors.dart';
import '../utils/download_manager.dart';
import '../utils/novel_download_manager.dart';
import '../utils/toast.dart';
import '../widgets/download_settings_sheet.dart';
import '../widgets/select_tile.dart';
import 'local_comics_page.dart';
import 'local_novels_page.dart';

part 'download_center_page_parts/queue_view.dart';
part 'download_center_page_parts/queue_cards.dart';

class DownloadCenterPage extends StatefulWidget {
  /// 0：漫画；1：轻小说；2：下载队列。
  /// 轻小说开关关闭时没有小说页：1 落到漫画，≥2 落到队列。
  final int initialTab;
  final DownloadManager? comicDownloads;
  final NovelDownloadManager? novelDownloads;

  const DownloadCenterPage({
    super.key,
    this.initialTab = 0,
    this.comicDownloads,
    this.novelDownloads,
  });

  @override
  State<DownloadCenterPage> createState() => _DownloadCenterPageState();
}

class _DownloadCenterPageState extends State<DownloadCenterPage>
    with TickerProviderStateMixin {
  TabController? _tabController;
  late final _comicDownloads = widget.comicDownloads ?? DownloadManager();
  late final _novelDownloads = widget.novelDownloads ?? NovelDownloadManager();
  late bool _showNovel;

  @override
  void initState() {
    super.initState();
    _showNovel = UserManager().showNovel;
    _tabController = _showNovel
        ? TabController(
            length: 3,
            vsync: this,
            initialIndex: widget.initialTab.clamp(0, 2),
          )
        : TabController(
            length: 2,
            vsync: this,
            initialIndex: widget.initialTab >= 2 ? 1 : 0,
          );
    _comicDownloads.addListener(_onQueueChanged);
    _novelDownloads.addListener(_onQueueChanged);
    unawaited(_novelDownloads.init());
  }

  @override
  void dispose() {
    _comicDownloads.removeListener(_onQueueChanged);
    _novelDownloads.removeListener(_onQueueChanged);
    _tabController?.dispose();
    super.dispose();
  }

  void _onQueueChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final controller = _tabController!;
    final queueCount =
        _comicDownloads.tasks.length + _novelDownloads.tasks.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.downloadCenterTitle),
        bottom: TabBar(
          controller: controller,
          tabs: [
            Tab(
              icon: const Icon(Icons.menu_book_outlined),
              text: l10n.comicLabel,
            ),
            if (_showNovel)
              Tab(
                icon: const Icon(Icons.auto_stories_outlined),
                text: l10n.novelTitle,
              ),
            Tab(
              icon: Badge(
                isLabelVisible: queueCount > 0,
                label: Text('$queueCount'),
                child: const Icon(Icons.downloading_outlined),
              ),
              text: l10n.downloadQueueTab,
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: controller,
        children: [
          LocalComicsPage(
            embedded: true,
            trailingAction: _settingsFab('download_settings_comic'),
          ),
          if (_showNovel)
            LocalNovelsPage(
              embedded: true,
              trailingAction: _settingsFab('download_settings_novel'),
            ),
          _buildQueueTab(),
        ],
      ),
    );
  }

  Widget _buildQueueTab() {
    final summary = _comicDownloads.lastBatchSummary;
    return Column(
      children: [
        if (summary != null)
          _BatchSummaryBanner(
            summary: summary,
            onRetry: _retryFailedBatch,
            onDismiss: _comicDownloads.clearBatchSummary,
          ),
        Expanded(
          child: _withSettingsFab(
            _UnifiedDownloadQueueView(
              comicDownloads: _comicDownloads,
              novelDownloads: _novelDownloads,
            ),
            'download_settings_queue',
          ),
        ),
      ],
    );
  }

  Future<void> _retryFailedBatch() async {
    final added = await _comicDownloads.retryFailedBatch();
    if (!mounted || added == 0) return;
    showToast(
      context,
      AppLocalizations.of(context)!.downloadBatchRequeued(added),
    );
  }

  /// 统一打开同一个下载设置面板（同时包含漫画与轻小说配置）。
  Widget _settingsFab(String heroTag) {
    return FloatingActionButton(
      heroTag: heroTag,
      tooltip: AppLocalizations.of(context)!.downloadSettingsTitle,
      onPressed: () => showDownloadSettingsSheet(
        context,
        downloads: _comicDownloads,
        novelDownloads: _novelDownloads,
      ),
      child: const Icon(Icons.settings_outlined),
    );
  }

  Widget _withSettingsFab(Widget child, String heroTag) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(right: 16, bottom: 16, child: _settingsFab(heroTag)),
      ],
    );
  }
}

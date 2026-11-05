import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/api_client.dart';
import '../api/novel/novel_api.dart' show NovelApiException, novelErrorMessage;
import '../l10n/app_localizations.dart';
import '../models/comic.dart' hide Theme;
import '../models/novel.dart';
import '../models/novel_reading_progress.dart';
import '../models/theme_settings.dart';
import '../models/user_manager.dart';
import '../providers/app_providers.dart';
import '../providers/novel_providers.dart';
import '../providers/settings_providers.dart';
import '../repositories/comic_detail_repository.dart';
import '../routing/app_router.dart';
import '../theme/app_icon_sizes.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import '../utils/app_logger.dart';
import '../utils/cover_brightness_filter.dart';
import '../utils/network_error.dart';
import '../utils/novel_reading_store.dart';
import '../utils/reading_history.dart';
import '../utils/screen_layout.dart';
import '../utils/time_format.dart';
import '../utils/toast.dart';
import '../widgets/app_hero.dart';
import '../widgets/comic_hero_tags.dart';
import '../widgets/cover_image.dart';
import '../widgets/error_retry_view.dart';
import '../widgets/load_more_footer.dart';
import '../widgets/login_expired_dialog.dart';
import '../widgets/nav_bar_inset.dart';
import '../widgets/novel_widgets.dart';
import '../widgets/shimmer_skeleton.dart';

part 'browse_history_page_parts/comic_history_tab.dart';
part 'browse_history_page_parts/history_cards.dart';
part 'browse_history_page_parts/novel_history_body.dart';
part 'browse_history_page_parts/online_novel_history_tab.dart';
part 'browse_history_page_parts/local_history_tab.dart';

class BrowseHistoryPage extends ConsumerStatefulWidget {
  final WidgetBuilder loginPageBuilder;

  const BrowseHistoryPage({super.key, required this.loginPageBuilder});

  @override
  ConsumerState<BrowseHistoryPage> createState() =>
      _BrowseHistoryPageStateHost();
}

class _BrowseHistoryPageStateHost extends ConsumerState<BrowseHistoryPage> {
  late final ThemeSettings _settings = ref.read(themeSettingsProvider);
  bool _savingMode = false;

  Future<void> _toggleMode() async {
    if (_savingMode) return;
    FocusScope.of(context).unfocus();
    setState(() => _savingMode = true);
    try {
      await _settings.setBrowseHistoryLocal(!_settings.browseHistoryLocal);
    } catch (error, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          error,
          stackTrace: stack,
          source: 'browse_history_page.save_mode',
        ),
      );
      if (mounted) {
        showToast(
          context,
          NetworkError.message(error, l10n: AppLocalizations.of(context)!),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _savingMode = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _settings,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context)!;
      final local = _settings.browseHistoryLocal;
      final showNovel = _settings.showNovel;
      return DefaultTabController(
        length: showNovel ? 2 : 1,
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              local ? l10n.localReadingHistoryTitle : l10n.browseHistoryTitle,
            ),
            actions: [
              TextButton.icon(
                key: const ValueKey('history_mode_toggle'),
                onPressed: _savingMode ? null : _toggleMode,
                icon: Icon(
                  local ? Icons.cloud_outlined : Icons.phone_android_outlined,
                  size: AppIconSize.lg,
                ),
                label: Text(
                  local ? l10n.historyModeOnline : l10n.historyModeLocal,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
            bottom: showNovel
                ? TabBar(
                    tabs: [
                      Tab(text: l10n.historyTabComic),
                      Tab(text: l10n.historyTabNovel),
                    ],
                  )
                : null,
          ),
          body: TabBarView(
            children: [
              _HistoryModePane(
                local: local,
                online: _ComicBrowseHistoryPage(
                  loginPageBuilder: widget.loginPageBuilder,
                ),
                localBody: const _LocalReadingHistoryTab(novel: false),
              ),
              if (showNovel)
                _HistoryModePane(
                  local: local,
                  online: const NovelHistoryBody(),
                  localBody: const _LocalReadingHistoryTab(novel: true),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// 按需创建两种模式，切换后保留已加载列表、搜索词和滚动位置。
class _HistoryModePane extends StatefulWidget {
  const _HistoryModePane({
    required this.local,
    required this.online,
    required this.localBody,
  });

  final bool local;
  final Widget online;
  final Widget localBody;

  @override
  State<_HistoryModePane> createState() => _HistoryModePaneState();
}

class _HistoryModePaneState extends State<_HistoryModePane>
    with AutomaticKeepAliveClientMixin {
  late bool _onlineVisited = !widget.local;
  late bool _localVisited = widget.local;

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant _HistoryModePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    _onlineVisited |= !widget.local;
    _localVisited |= widget.local;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return IndexedStack(
      index: widget.local ? 1 : 0,
      children: [
        if (_onlineVisited) widget.online else const SizedBox.shrink(),
        if (_localVisited) widget.localBody else const SizedBox.shrink(),
      ],
    );
  }
}

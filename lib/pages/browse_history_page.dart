import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/api_client.dart';
import '../api/novel/novel_api.dart' show novelErrorMessage;
import '../l10n/app_localizations.dart';
import '../models/comic.dart' hide Theme;
import '../models/novel_reading_progress.dart';
import '../models/user_manager.dart';
import '../providers/novel_providers.dart';
import '../routing/app_router.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../utils/app_logger.dart';
import '../utils/cover_brightness_filter.dart';
import '../utils/network_error.dart';
import '../utils/novel_reading_store.dart';
import '../utils/screen_layout.dart';
import '../utils/time_format.dart';
import '../utils/toast.dart';
import '../widgets/app_hero.dart';
import '../widgets/back_to_top_button.dart';
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

class BrowseHistoryPage extends StatelessWidget {
  final WidgetBuilder loginPageBuilder;

  const BrowseHistoryPage({super.key, required this.loginPageBuilder});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 通用页「轻小说」开关关闭时隐藏 tab 组件，只展示漫画历史。
    final showNovel = UserManager().showNovel;
    return DefaultTabController(
      length: showNovel ? 2 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.browseHistoryTitle),
          bottom: showNovel
              ? TabBar(
                  tabs: [
                    Tab(text: l10n.historyTabComic),
                    Tab(text: l10n.historyTabNovel),
                  ],
                )
              : null,
        ),
        // 两个列表各自保活：切回来不丢已加载分页与滚动位置。
        body: TabBarView(
          children: [
            _ComicBrowseHistoryPage(loginPageBuilder: loginPageBuilder),
            if (showNovel) const NovelHistoryBody(),
          ],
        ),
      ),
    );
  }
}

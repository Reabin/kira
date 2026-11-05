part of '../profile_page.dart';

extension _ProfileCards on _ProfilePageState {
  /// 第一块设置卡片：账号 / 通用 / 外观 / 网络。
  Widget _buildGeneralSettingsCard() {
    final l10n = AppLocalizations.of(context)!;
    return SettingTileGroup(
      children: [
        ListTile(
          key: const ValueKey('profile-account-entry'),
          leading: AccountAvatar(avatar: _user.avatar, radius: 12),
          title: Text(
            _accountDisplayName(l10n),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => context.pushNamed(AppRoutes.accountCenter),
        ),
        ListTile(
          leading: const _SettingIcon(icon: Icons.tune_rounded),
          title: Text(l10n.generalTitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.pushNamed(AppRoutes.general),
        ),
        ListTile(
          leading: const _SettingIcon(icon: Icons.palette_rounded),
          title: Text(l10n.appearanceTitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.pushNamed(AppRoutes.appearance),
        ),
        ListTile(
          leading: const _SettingIcon(icon: Icons.dns_rounded),
          title: Text(l10n.networkTitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.pushNamed(AppRoutes.network),
        ),
      ],
    );
  }

  /// 「继续阅读」入口:与其它选项卡同款 ListTile,带副标题展示上次进度。
  /// 无本地阅读记录时返回 null,调用方据此跳过。
  Widget? _buildContinueReadingTile() {
    final entry = _continueRecord;
    if (entry == null) return null;
    final l10n = AppLocalizations.of(context)!;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final record = entry.record;
    // 副标题左侧：漫画名 · 章节名；任一段缺失就跳过,避免空段。
    final parts = <String>[
      if (entry.comicName.isNotEmpty) entry.comicName,
      record.chapterName.trim().isNotEmpty
          ? record.chapterName.trim()
          : l10n.continueReadingChapterFallback,
    ].where((s) => s.trim().isNotEmpty).toList();
    return ListTile(
      leading: const _SettingIcon(icon: Icons.menu_book_rounded),
      title: Text(l10n.continueReadingComic),
      subtitle: _continueSubtitle(
        name: parts.join(' · '),
        // 与书签页的继续阅读按钮同款：当前页/总页数；老记录没记总页数时
        // 退回「第 N 页」，总比整段进度消失好。
        progress: record.totalPage > 1
            ? '${record.page}/${record.totalPage}'
            : l10n.continueReadingPageLabel(record.page),
        tt: tt,
        cs: cs,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _continueReading(entry),
    );
  }

  /// 副标题：可收缩的名称 + 固定不退让的进度。
  ///
  /// 不能再用「单段 Text + 省略号」：章节名很长时省略号会把进度一起吃掉。
  /// 名称走 [Flexible]（短名不被拉伸），进度不参与收缩，永远留在行尾。
  Widget _continueSubtitle({
    required String name,
    required String progress,
    required TextTheme tt,
    required ColorScheme cs,
  }) {
    final style = AppTypography.meta(tt)?.copyWith(color: cs.onSurfaceVariant);
    final trimmedName = name.trim();
    return Row(
      children: [
        if (trimmedName.isNotEmpty) ...[
          Flexible(
            child: Text(
              trimmedName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
        Text(progress, maxLines: 1, style: style),
      ],
    );
  }

  /// 「继续阅读轻小说」入口:与漫画那条同款,读取本机小说阅读进度。
  Widget? _buildContinueNovelTile() {
    if (!_user.showNovel) return null;
    final progress = _continueNovel;
    if (progress == null) return null;
    final l10n = AppLocalizations.of(context)!;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    // 副标题左侧：书名 · 卷名；任一段缺失就跳过,避免空段。
    final parts = <String>[
      progress.name.isEmpty ? progress.pathWord : progress.name,
      progress.volumeName.trim(),
    ].where((s) => s.trim().isNotEmpty).toList();
    return ListTile(
      leading: const _SettingIcon(icon: Icons.auto_stories_rounded),
      title: Text(l10n.continueReadingNovel),
      subtitle: _continueSubtitle(
        name: parts.join(' · '),
        // 与书签页同口径：卷内进度百分比。
        progress: '${_novelPercent(progress.progress)}%',
        tt: tt,
        cs: cs,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _continueNovelReading(progress),
    );
  }

  /// 卷内进度百分比（整数）。未读到卷末不四舍五入成 100%：99.9% 显示 99%。
  int _novelPercent(double progress) {
    if (progress >= 1) return 100;
    final percent = progress * 100;
    if (percent <= 0) return 0;
    final floored = percent.floor();
    return floored > 99 ? 99 : floored;
  }

  /// 直入小说阅读器:进度本身已经包含卷与段落定位,无需先请求详情。
  Future<void> _continueNovelReading(NovelReadingProgress progress) async {
    await context.pushNamed(
      AppRoutes.novelReader,
      pathParameters: {
        'pathWord': progress.pathWord,
        'volumeId': progress.volumeId,
      },
      extra: NovelReaderExtra(
        name: progress.name,
        cover: progress.cover,
        entryIndex: progress.entryIndex,
        resume: true,
        noDetailBelow: true,
      ),
    );
    if (!mounted) return;
    await _loadContinueNovel();
  }

  /// 跳转到阅读器,恢复上次阅读的章节与页码;返回后刷新记录。
  Future<void> _continueReading(
    ({String pathWord, ReadingRecord record, String comicName}) entry,
  ) async {
    final record = entry.record;
    await context.pushNamed(
      AppRoutes.reader,
      pathParameters: {
        'pathWord': entry.pathWord,
        'chapterUuid': record.chapterUuid,
      },
      extra: ReaderExtra(
        comicName: entry.comicName.isEmpty ? null : entry.comicName,
        group: record.group,
        chapterName: record.chapterName,
        chapterListPage: record.chapterListPage,
        initialPage: record.page,
        noCatalogBelow: true,
      ),
    );
    if (!mounted) return;
    await _loadContinueRecord();
  }

  /// 第二块设置卡片：下载中心 / 浏览历史 / 书签 / 继续阅读 / 阅读统计。
  Widget _buildDataSettingsCard() {
    final l10n = AppLocalizations.of(context)!;
    return SettingTileGroup(
      children: [
        ListTile(
          leading: const _SettingIcon(icon: Icons.download_done_rounded),
          title: Text(l10n.downloadCenterTitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.pushNamed(AppRoutes.downloadCenter),
        ),
        ListTile(
          leading: const _SettingIcon(icon: Icons.history_rounded),
          title: Text(l10n.browseHistoryTitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.pushNamed(AppRoutes.browseHistory),
        ),
        ListTile(
          leading: const _SettingIcon(icon: Icons.bookmark_outline_rounded),
          title: Text(l10n.bookmarksTitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.pushNamed(AppRoutes.bookmarks),
        ),
        ?_buildContinueReadingTile(),
        ?_buildContinueNovelTile(),
      ],
    );
  }

  /// 第三块设置卡片：阅读统计 / AI 配置 / 通知中心 / 关于。
  Widget _buildAboutCard() {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return SettingTileGroup(
      children: [
        ListTile(
          leading: const _SettingIcon(icon: Icons.bar_chart_rounded),
          title: Text(l10n.statsTitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.pushNamed(AppRoutes.stats),
        ),
        ListTile(
          leading: const _SettingIcon(icon: Icons.smart_toy_outlined),
          title: Text(l10n.aiConfigTitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.pushNamed(AppRoutes.aiConfig),
        ),
        ValueListenableBuilder<int>(
          valueListenable: RemoteNoticeService.unreadActiveCount,
          builder: (context, count, _) {
            return ListTile(
              leading: Stack(
                clipBehavior: Clip.none,
                children: [
                  const _SettingIcon(icon: Icons.notifications_active_outlined),
                  if (count > 0)
                    Positioned(
                      right: -1,
                      top: -1,
                      child: _NoticeRedDot(
                        color: _noticeCenterColor,
                        borderColor: cs.surfaceBright,
                      ),
                    ),
                ],
              ),
              title: Text(l10n.noticeCenterTitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.pushNamed(AppRoutes.noticeCenter),
            );
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: AppUpdateService.hasUnseenUpdate,
          builder: (context, hasUnseenUpdate, _) {
            return ListTile(
              leading: Stack(
                clipBehavior: Clip.none,
                children: [
                  const _SettingIcon(icon: Icons.info_rounded),
                  if (hasUnseenUpdate)
                    Positioned(
                      right: -1,
                      top: -1,
                      child: _NoticeRedDot(
                        color: _noticeCenterColor,
                        borderColor: cs.surfaceBright,
                      ),
                    ),
                ],
              ),
              title: Text(l10n.aboutTitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.pushNamed(AppRoutes.about),
            );
          },
        ),
      ],
    );
  }

  /// 入口只展示当前漫画身份，不能借用独立的轻小说账号。
  String _accountDisplayName(AppLocalizations l10n) {
    if (!_user.isLoggedIn) return l10n.notLoggedInTitle;
    final nickname = _user.nickname?.trim() ?? '';
    final username = _user.username?.trim() ?? '';
    if (nickname.isNotEmpty) return nickname;
    return username.isEmpty ? l10n.accountProfileMissing : username;
  }
}

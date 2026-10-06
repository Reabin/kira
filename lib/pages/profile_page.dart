import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../l10n/app_localizations.dart';
import '../models/novel_reading_progress.dart';
import '../models/user_manager.dart';
import '../repositories/comic_detail_repository.dart';
import '../routing/app_router.dart';
import '../routing/branch_activation.dart';

import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import '../utils/app_logger.dart';
import '../utils/app_update.dart';
import '../utils/novel_reading_store.dart';
import '../utils/reading_history.dart';
import '../utils/remote_notice_service.dart';
import '../utils/screen_layout.dart';

import '../widgets/account_avatar.dart';
import '../widgets/setting_tile_group.dart';
part 'profile/profile_cards.dart';

const _noticeCenterColor = Color(0xFFEB6F92);

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> with BranchDeferredInit {
  final _user = UserManager();

  /// 最近一次阅读记录,供「继续阅读」入口展示。null 表示无本地阅读记录。
  ({String pathWord, ReadingRecord record, String comicName})? _continueRecord;

  /// 最近一次轻小说阅读进度,供「继续阅读轻小说」入口展示。
  NovelReadingProgress? _continueNovel;

  @override
  void initState() {
    super.initState();
    _user.addListener(_onUserChanged);
    // 页面常驻于底部导航分支，initState 只在首次进入时跑一次；
    // 阅读别处产生的新记录后回到本页，需要靠变更通知刷新「继续阅读」。
    ReadingHistory.changes.addListener(_onReadingHistoryChanged);
    NovelReadingStore.changes.addListener(_onReadingHistoryChanged);
    deferInitialLoadToBranchActivation();
  }

  @override
  void onBranchFirstActivated() {
    unawaited(_loadContinueRecord());
    unawaited(_loadContinueNovel());
  }

  @override
  void dispose() {
    NovelReadingStore.changes.removeListener(_onReadingHistoryChanged);
    ReadingHistory.changes.removeListener(_onReadingHistoryChanged);
    _user.removeListener(_onUserChanged);
    super.dispose();
  }

  void _onReadingHistoryChanged() {
    unawaited(_loadContinueRecord());
    unawaited(_loadContinueNovel());
  }

  void _onUserChanged() {
    if (!mounted) return;
    setState(() {});
    // 开关重新打开时补一次进度加载，避免入口一直空缺。
    if (_user.showNovel) unawaited(_loadContinueNovel());
  }

  /// 载入最近一条本地阅读记录。记录里的漫画名可能为空(旧记录),
  /// 此时回退到详情本地缓存取一次名字——避免「继续阅读」副标题缺名字。
  Future<void> _loadContinueRecord() async {
    final latest = await ReadingHistory.latestRecord();
    final record = latest?.record;
    if (latest == null || record == null) {
      if (!mounted) return;
      setState(() {
        _continueRecord = null;
      });
      return;
    }
    var comicName = record.comicName;
    if (comicName.isEmpty) {
      try {
        final data = await ComicDetailRepository(
          latest.pathWord,
        ).loadFromCache();
        comicName = data?.comic.name ?? '';
      } catch (e, stack) {
        unawaited(
          AppLogger.instance.recordWarning(
            e,
            stackTrace: stack,
            source: 'profile.load_continue_record',
          ),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _continueRecord = (
        pathWord: latest.pathWord,
        record: record,
        comicName: comicName,
      );
    });
  }

  /// 载入本机最近一条轻小说阅读进度,只读本地存储,不发业务请求。
  Future<void> _loadContinueNovel() async {
    if (!_user.showNovel) return;
    try {
      final recent = await NovelReadingStore().readRecent(limit: 1);
      if (!mounted) return;
      setState(() => _continueNovel = recent.isEmpty ? null : recent.first);
    } catch (e, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: stack,
          source: 'profile.load_continue_novel',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final hp = ScreenLayout.horizontalPadding(screenWidth);
    final isWide =
        ScreenLayout.contentWidth(screenWidth) >= ScreenLayout.wideBreakpoint;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(height: MediaQuery.of(context).padding.top),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.md)),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(hp, 0, hp, 16),
              // 宽屏双栏：左列为通用设置卡片，右列为下载/记录卡片 + 关于卡片；
              // 窄屏维持原来的单列纵向排布。
              child: isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _buildGeneralSettingsCard()),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            children: [
                              _buildDataSettingsCard(),
                              const SizedBox(height: AppSpacing.md),
                              _buildAboutCard(),
                            ],
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        _buildGeneralSettingsCard(),
                        const SizedBox(height: AppSpacing.md),
                        _buildDataSettingsCard(),
                        const SizedBox(height: AppSpacing.md),
                        _buildAboutCard(),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeRedDot extends StatelessWidget {
  const _NoticeRedDot({required this.color, required this.borderColor});

  final Color color;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: borderColor, width: 1.2),
      ),
    );
  }
}

class _SettingIcon extends StatelessWidget {
  final IconData icon;

  const _SettingIcon({required this.icon});

  @override
  Widget build(BuildContext context) {
    // 与许可证页头部图标同款：裸图标 + 主题色，不带底衬色块。
    return Icon(
      icon,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      size: 24,
    );
  }
}

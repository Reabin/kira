import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/api_transport.dart';
import '../api/user/user_api.dart';
import '../utils/app_icon_switcher.dart';
import '../utils/app_logger.dart';
import '../utils/copy_web_login.dart' show CopyWebLoginForm, canApplyLoginForm;
import 'api_ordering.dart';
import 'app_theme_option.dart';
import 'comment_settings.dart';
import 'copy_account_store.dart';
import 'network_proxy_types.dart';
import 'network_settings.dart';
import 'reader_settings.dart';
import 'secure_credential_store.dart';
import 'theme_settings.dart';

export 'network_proxy_types.dart';
export 'network_settings.dart' show NetworkSelectionMode;
export 'theme_settings.dart' show BottomNavLabelMode;

part 'user_manager_parts/app_settings.dart';
part 'user_manager_parts/comment.dart';
part 'user_manager_parts/init.dart';
part 'user_manager_parts/reader.dart';
part 'user_manager_parts/theme_nav.dart';

class SavedCredential {
  final String username;
  final String password;
  final String? token;
  final String? loginSource;
  final String? userId;
  final String? nickname;
  final String? avatar;
  final String? accountId;

  const SavedCredential({
    required this.username,
    required this.password,
    this.token,
    this.loginSource,
    this.userId,
    this.nickname,
    this.avatar,
    this.accountId,
  });

  factory SavedCredential.fromJson(Map<String, dynamic> json) =>
      SavedCredential(
        username: json['username']?.toString() ?? '',
        password: json['password']?.toString() ?? '',
        token: json['token'] is String ? json['token'] : null,
        loginSource: json['login_source']?.toString(),
        userId: json['user_id']?.toString(),
        nickname: json['nickname']?.toString(),
        avatar: json['avatar']?.toString(),
        accountId: switch (json['account_id']) {
          final String value when value.trim().isNotEmpty => value.trim(),
          _ => null,
        },
      );

  Map<String, dynamic> toJson() => {
    'username': username,
    'password': password,
    if (token != null) 'token': token,
    if (loginSource != null) 'login_source': loginSource,
    if (userId != null) 'user_id': userId,
    if (nickname != null) 'nickname': nickname,
    if (avatar != null) 'avatar': avatar,
    if (accountId != null) 'account_id': accountId,
  };

  String get source => loginSource == 'copy' ? 'copy' : 'hotmanga';

  bool get hasIdentity =>
      username.trim().isNotEmpty || userId?.trim().isNotEmpty == true;

  /// A local COPY handle supports token-only accounts without inventing a
  /// server identity. Password-only legacy credentials still need a name.
  bool get hasAccountKey =>
      hasIdentity ||
      (source == 'copy' &&
          accountId?.trim().isNotEmpty == true &&
          token?.trim().isNotEmpty == true);

  bool sameAccount(SavedCredential other) {
    if (source != other.source) return false;
    if (source == 'copy') {
      if (token?.isNotEmpty == true && token == other.token) return true;
      if (accountId?.isNotEmpty == true &&
          other.accountId?.isNotEmpty == true) {
        return accountId == other.accountId;
      }
      if (userId?.isNotEmpty == true && other.userId?.isNotEmpty == true) {
        return userId == other.userId;
      }
    }
    if (username.isNotEmpty && other.username.isNotEmpty) {
      return username == other.username;
    }
    return userId?.isNotEmpty == true && userId == other.userId;
  }

  SavedCredential copyWith({
    String? username,
    String? password,
    String? token,
    String? loginSource,
    String? userId,
    String? nickname,
    String? avatar,
    String? accountId,
  }) => SavedCredential(
    username: username ?? this.username,
    password: password ?? this.password,
    token: token ?? this.token,
    loginSource: loginSource ?? this.loginSource,
    userId: userId ?? this.userId,
    nickname: nickname ?? this.nickname,
    avatar: avatar ?? this.avatar,
    accountId: accountId ?? this.accountId,
  );
}

class UserManager extends ChangeNotifier {
  static final UserManager _instance = UserManager._();
  factory UserManager() => _instance;
  UserManager._();

  // ── Domain-specific sub-stores ─────────────────────────────────────
  // Each store is an independent ChangeNotifier.  Callers that only
  // need reader / comment / theme / network settings should
  // import the specific store directly and skip the facade entirely.

  final reader = ReaderSettings();
  final comment = CommentSettings();
  final theme = ThemeSettings();
  final network = NetworkSettings();
  final CopyAccountStore _copyAccount = CopyAccountStore();

  CopyAccountStore get copyAccount => _copyAccount;
  String? get copyToken => copyAccount.token;
  bool get isCopyLoggedIn => copyAccount.isLoggedIn;

  // ── Backward-compat constant re-exports ────────────────────────────
  // These delegate to the canonical definitions in each sub-store so
  // existing callers that reference UserManager.defaultXxx keep working.

  static const double minDarkModeCoverBrightness =
      ThemeSettings.minDarkModeCoverBrightness;
  static const double maxDarkModeCoverBrightness =
      ThemeSettings.maxDarkModeCoverBrightness;
  static const double defaultDarkModeCoverBrightness =
      ThemeSettings.defaultDarkModeCoverBrightness;
  static const defaultNavKey = ThemeSettings.defaultNavKey;
  static const defaultNavOrder = ThemeSettings.defaultNavOrder;
  static const defaultDisplayModeRefreshRate =
      ThemeSettings.defaultDisplayModeRefreshRate;
  static const defaultUpdateMirrorPrefix = 'https://ghproxy.net/';

  static const appLogoPaths = ThemeSettings.appLogoPaths;

  static const _keyToken = 'user_token';
  static const _keyUsername = 'user_username';
  static const _keyNickname = 'user_nickname';
  static const _keyAvatar = 'user_avatar';
  static const _keyUserId = 'user_id';
  static const _keyAccountId = 'user_account_id';
  static const _keySavedUsername = 'saved_username';
  static const _keySavedPassword = 'saved_password';
  static const _keySavedCredentials = 'saved_credentials';
  static const _keyThemeMode = 'theme_mode';
  static const _keyThemeColor = 'theme_color';
  static const _keyThemeVariant = 'theme_variant';
  static const _keyCustomThemeColor = 'custom_theme_color';
  static const _keyDarkModeCoverBrightness = 'dark_mode_cover_brightness';
  static const _keyBottomNavShowLabels = 'bottom_nav_show_labels';
  static const _keyBottomNavLabelMode = 'bottom_nav_label_mode';
  static const _keyDesktopFontFamily = 'desktop_font_family';
  static const _keyDisplayModeRefreshRate = 'pref_display_mode_refresh_rate';
  static const _keyBookshelfOrdering = 'bookshelf_ordering';
  static const _keyReaderScrollDirection = 'reader_scroll_direction';
  static const _keyReaderImageGap = 'reader_image_gap';
  static const _keyReaderVolumeKey = 'reader_volume_key';
  static const _keyReaderInstantPageTurn = 'reader_instant_page_turn';
  static const _keyReaderPageRTL = 'reader_page_rtl';
  static const _keyReaderPageVertical = 'reader_page_vertical';
  static const _keyReaderDimming = 'reader_dimming';
  static const _keyReaderAutoScrollEnabled = 'reader_auto_scroll_enabled';
  static const _keyReaderAutoScrollPause = 'reader_auto_scroll_pause';
  static const _keyReaderAutoScrollResume = 'reader_auto_scroll_resume';
  static const _keyReaderAutoScrollResumeDelay =
      'reader_auto_scroll_resume_delay';
  static const _keyReaderAutoScrollDistance = 'reader_auto_scroll_distance';
  static const _keyReaderContinuousReading = 'reader_continuous_reading';
  static const _keyReaderHorizontalImageScale = 'reader_horizontal_image_scale';
  static const _keyImageViewerAutoRotateLandscape =
      'image_viewer_auto_rotate_landscape';
  static const _keyImageViewerLandscapeRotation =
      'image_viewer_landscape_rotation';
  static const _keyImageLoadTimeout = 'image_load_timeout';
  static const _keyImageRetryCount = 'image_retry_count';
  static const _keyCommentCompactLayout = 'comment_compact_layout';
  static const _keyCommentPreload = 'comment_preload';
  static const _keyCommentAutoLoadAll = 'comment_auto_load_all';
  static const _keyAutoCheckUpdate = 'auto_check_update';
  static const _keySkippedUpdateVersion = 'skipped_update_version';
  static const _keyUpdateMirrorPrefix = 'update_mirror_prefix';
  static const _keyUpdateChannel = 'update_channel'; // stable | beta
  static const _keyLastBetaAssetName = 'last_beta_asset_name';
  static const _keyUseUpdateMirror = 'use_update_mirror';
  static const _keyAutoLogin = 'auto_login';
  static const _keyDisclaimerAccepted = 'disclaimer_accepted';
  static const _keyLoginSource = 'login_source';
  static const _keyApiRoute = 'api_route';
  static const _keyRemoteNoticeEnabled = 'remote_notice_enabled';
  static const _keyLocale = 'locale';
  static const _keyBannerVisible = 'banner_visible';
  static const _keyMangaHomeSource = 'manga_home_source';
  static const _keyDiscoverSource = 'discover_source';
  static const _keySearchTabIndex = 'search_tab_index';
  static const _keyCopyApiHost = 'copy_api_host';
  static const _keyCopyLoginHost = 'copy_login_host';
  static const _keyCustomCopyLoginHosts = 'copy_login_custom_hosts';
  static const _keyCopyAppVersion = 'copy_app_version';
  static const _keyCopyAutoUpdate = 'copy_auto_update';
  static const _keyCopySettingsUpdatedAt = 'copy_settings_updated_at';
  static const _keyCopyHomeSectionCollapsed = 'copy_home_section_collapsed';
  static const _keyCommentBlockedUsers = 'comment_blocked_users';
  static const _keyCommentBlockNoRemind = 'comment_block_no_remind';
  static const _keyCommentBlockwords = 'comment_blockwords';
  static const _keyCommentBlockGroupSpam = 'comment_block_group_spam';
  static const _keyLogoIndex = 'logo_index';

  String? _token;
  String? _username;
  String? _nickname;
  String? _avatar;
  String? _userId;
  String? _accountId;
  String? _savedUsername;
  String? _savedPassword;
  List<SavedCredential> _savedCredentials = [];

  /// Free-form note attached to the COPY account the next login creates
  /// (「这是谁的账号」). Not a credential: safe to persist in the record.
  String _copyAccountLabel = '';
  ThemeMode _themeMode = ThemeMode.system;
  String _themeColor = appThemeOptions.first.id;
  DynamicSchemeVariant _themeVariant = appThemeVariantOptions.first.variant;
  int _customThemeColorValue = defaultCustomThemeColor.toARGB32();
  double _darkModeCoverBrightness = defaultDarkModeCoverBrightness;
  BottomNavLabelMode _bottomNavLabelMode = BottomNavLabelMode.selectedOnly;
  String _desktopFontFamily = '';
  int _displayModeRefreshRate = defaultDisplayModeRefreshRate;
  String _bookshelfOrdering = ApiOrdering.datetimeUpdated;
  int _readerScrollDirection = 2;
  double _readerImageGap = 0.0;
  bool _readerVolumeKey = true;
  bool _readerInstantPageTurn = false;
  bool _readerPageRTL = false;
  bool _readerPageVertical = false;
  double _readerDimming = 0.3;
  bool _readerAutoScrollEnabled = false;
  double _readerAutoScrollPause = 3.0;
  bool _readerAutoScrollResume = false;
  double _readerAutoScrollResumeDelay = 2.0;
  double _readerAutoScrollDistance = 0.8;
  bool _readerContinuousReading = true;
  // 横向滚动模式下图片相对视口高度的缩放档位，1.0 = 填满高度。
  double _readerHorizontalImageScale = 1.0;
  bool _imageViewerAutoRotateLandscape = false;
  int _imageViewerLandscapeRotation = 1;
  int _imageLoadTimeout = 15; // 秒
  int _imageRetryCount = 1;
  bool _commentCompactLayout = true;
  bool _commentPreload = true;
  bool _commentAutoLoadAll = false;
  bool _autoCheckUpdate = true;
  String? _skippedUpdateVersion;
  String _updateMirrorPrefix = defaultUpdateMirrorPrefix;
  String _updateChannel = 'stable'; // stable | beta
  String? _lastBetaAssetName;
  bool _useUpdateMirror = true;
  bool _autoLogin = false;
  bool _disclaimerAccepted = false;
  String _loginSource = 'hotmanga';
  int _apiRoute = 0; // 0=线路1(默认), 1=线路2
  bool _remoteNoticeEnabled = true;

  /// '' = follow system, 'zh' = Simplified, 'zh-Hant' = Traditional.
  String _locale = '';
  bool _bannerVisible = true;
  String _mangaHomeSource = 'hot';

  /// 「发现」页自己的数据源，与首页互不影响。
  String _discoverSource = 'hot';

  /// 搜索页当前标签：0 = 搜索，1 = 发现。与 [lastNavKey] 同理，冷启动恢复。
  int _searchTabIndex = 0;
  String _copyApiHost = defaultCopyApiHost;
  String _copyLoginHost = defaultCopyLoginHost;

  /// 用户自定义的拷贝登录域名（内置 [copyLoginHostOptions] 之外）。
  List<String> _customCopyLoginHosts = [];
  String _copyAppVersion = defaultCopyAppVersion;
  bool _copyAutoUpdate = true;
  int? _copySettingsUpdatedAt;
  Map<String, bool> _copyHomeSectionCollapsed = {};

  /// 评论屏蔽用户黑名单，元素为 `userId|userName` 形式
  List<String> _commentBlockedUsers = [];
  bool _commentBlockNoRemind = false;

  /// 评论屏蔽词列表，评论内容包含任一屏蔽词即被过滤
  List<String> _commentBlockwords = [];

  /// 群广告屏蔽预设：同时包含「群」与 8~12 位数字的评论将被过滤。默认关闭。
  bool _commentBlockGroupSpam = false;
  int _logoIndex = 1;

  /// extension part 文件里的成员不是 UserManager 自身的成员，不能直接调用受
  /// 保护的 [notifyListeners]，统一经由这个转发方法。
  void _notifyListeners() => notifyListeners();

  String? get token => _token;
  String? get username => _username;
  String? get nickname => _nickname;
  String? get avatar => _avatar;
  String? get userId => _userId;
  String? get savedUsername => _savedUsername;
  String? get savedPassword => _savedPassword;
  List<SavedCredential> get savedCredentials =>
      List.unmodifiable(_savedCredentials);
  ThemeMode get themeMode => _themeMode;
  String get themeColor => _themeColor;
  DynamicSchemeVariant get themeVariant => _themeVariant;
  Color get customThemeColor => Color(_customThemeColorValue);
  double get darkModeCoverBrightness => _darkModeCoverBrightness;
  BottomNavLabelMode get bottomNavLabelMode => _bottomNavLabelMode;

  /// Compatibility: true when labels are not fully hidden.
  bool get bottomNavShowLabels =>
      _bottomNavLabelMode != BottomNavLabelMode.hidden;
  List<String> get navOrder => theme.navOrder;
  bool get showNovel => theme.showNovel;
  String get lastNavKey => theme.lastNavKey;
  String get desktopFontFamily => _desktopFontFamily;
  int get displayModeRefreshRate => _displayModeRefreshRate;
  AppThemeOption get themeOption {
    if (_themeColor == customThemeOptionId) {
      return AppThemeOption(
        id: customThemeOptionId,
        label: '自定',
        seedColor: customThemeColor,
      );
    }
    return resolveAppThemeOption(_themeColor);
  }

  AppThemeVariantOption get themeVariantOption =>
      resolveAppThemeVariantOption(_themeVariant.name);

  String get bookshelfOrdering => _bookshelfOrdering;

  /// 委托给 [reader]：两边曾各自缓存 'reader_mode'，
  /// 经此处修改不会同步到子 store，反之亦然。
  int get readerMode => reader.mode;
  int get readerScrollDirection => _readerScrollDirection;
  double get readerImageGap => _readerImageGap;
  bool get readerVolumeKey => _readerVolumeKey;
  bool get readerInstantPageTurn => _readerInstantPageTurn;
  bool get readerPageRTL => _readerPageRTL;
  bool get readerPageVertical => _readerPageVertical;
  double get readerDimming => _readerDimming;
  bool get readerAutoScrollEnabled => _readerAutoScrollEnabled;
  double get readerAutoScrollPause => _readerAutoScrollPause;
  bool get readerAutoScrollResume => _readerAutoScrollResume;
  double get readerAutoScrollResumeDelay => _readerAutoScrollResumeDelay;
  double get readerAutoScrollDistance => _readerAutoScrollDistance;
  bool get readerContinuousReading => _readerContinuousReading;
  double get readerHorizontalImageScale => _readerHorizontalImageScale;
  bool get imageViewerAutoRotateLandscape => _imageViewerAutoRotateLandscape;
  int get imageViewerLandscapeRotation => _imageViewerLandscapeRotation;
  int get imageLoadTimeout => _imageLoadTimeout;
  int get imageRetryCount => _imageRetryCount;
  bool get commentCompactLayout => _commentCompactLayout;
  bool get commentShowAvatar => comment.showAvatar;
  bool get commentShowUserName => comment.showUserName;
  bool get commentShowTime => comment.showTime;

  /// 委托给 [comment]。子 store 的 notifyListeners 会经
  /// _onSubStoreChanged 转发到本 facade 的监听者。
  double get commentFontScale => comment.fontScale;
  bool get commentPreload => _commentPreload;
  bool get commentAutoLoadAll => _commentAutoLoadAll;
  bool get autoCheckUpdate => _autoCheckUpdate;
  String? get skippedUpdateVersion => _skippedUpdateVersion;
  String get updateMirrorPrefix => _updateMirrorPrefix;
  String get updateChannel => _updateChannel;
  bool get isBetaUpdateChannel => _updateChannel == 'beta';
  String? get lastBetaAssetName => _lastBetaAssetName;
  bool get useUpdateMirror => _useUpdateMirror;
  bool get autoLogin => _autoLogin;
  bool get disclaimerAccepted => _disclaimerAccepted;
  String get loginSource => _loginSource;
  int get apiRoute => _apiRoute;
  NetworkSelectionMode get networkSelectionMode => network.selectionMode;
  String? get fixedNodeHost => network.fixedNodeHost;
  NetworkProxyMode get networkProxyMode => network.proxyMode;
  NetworkProxyType get networkProxyType => network.proxyType;
  String get networkProxyHost => network.proxyHost;
  int get networkProxyPort => network.proxyPort;
  bool get hasManualProxy => network.hasManualProxy;
  bool get remoteNoticeEnabled => _remoteNoticeEnabled;

  /// '' = follow system, 'zh' = 简体中文, 'zh-Hant' = 繁體中文
  String get locale => _locale;
  bool get bannerVisible => _bannerVisible;
  String get mangaHomeSource => _mangaHomeSource;

  /// 「发现」页当前数据源，独立于 [mangaHomeSource]。
  String get discoverSource => _discoverSource;

  /// 搜索页上次停留的标签（0 = 搜索，1 = 发现）。
  int get searchTabIndex => _searchTabIndex;
  String get copyApiHost => _copyApiHost;
  String get copyLoginHost => _copyLoginHost;
  List<String> get customCopyLoginHosts =>
      List.unmodifiable(_customCopyLoginHosts);

  /// 高级设置中可选的全部登录域名：内置 + 自定义，去重保序。
  List<String> get copyLoginHostChoices => List.unmodifiable([
    ...copyLoginHostOptions,
    ..._customCopyLoginHosts.where((h) => !copyLoginHostOptions.contains(h)),
  ]);
  String get copyAppVersion => _copyAppVersion;
  bool get copyAutoUpdate => _copyAutoUpdate;
  int? get copySettingsUpdatedAt => _copySettingsUpdatedAt;
  bool isCopyHomeSectionCollapsed(String key) =>
      _copyHomeSectionCollapsed[key] ?? false;
  List<String> get commentBlockedUsers =>
      List.unmodifiable(_commentBlockedUsers);
  bool get commentBlockNoRemind => _commentBlockNoRemind;
  List<String> get commentBlockwords => List.unmodifiable(_commentBlockwords);
  bool get commentBlockGroupSpam => _commentBlockGroupSpam;

  // ── 屏蔽判定与屏蔽用户写入 ────────────────────────────────────────────
  // 这几个成员留在类体（而非 UserManagerCommentPart 扩展）是因为扩展成员
  // 静态解析、无法被测试假体覆写；各评论区对其有真实的多态需求。

  /// `entry` 格式：`userId|userName`（userId 可为空字符串，userName 作为兜底标识）。
  bool isCommentUserBlocked(String userId, String userName) {
    if (userId.isEmpty && userName.isEmpty) return false;
    for (final raw in _commentBlockedUsers) {
      final sep = raw.indexOf('|');
      if (sep < 0) {
        if (userId.isNotEmpty && raw == userId) return true;
        continue;
      }
      final bId = raw.substring(0, sep);
      final bName = raw.substring(sep + 1);
      if (userId.isNotEmpty && bId == userId) return true;
      if (userId.isEmpty && userName.isNotEmpty && bName == userName) {
        return true;
      }
    }
    return false;
  }

  Future<void> blockCommentUser(String userId, String userName) async {
    final key = '$userId|$userName';
    if (_commentBlockedUsers.any((e) => e == key)) return;
    _commentBlockedUsers = [..._commentBlockedUsers, key];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      UserManager._keyCommentBlockedUsers,
      _commentBlockedUsers,
    );
    _notifyListeners();
  }

  /// 评论内容是否命中任一屏蔽词（大小写不敏感）。
  bool isCommentBlockedByWord(String content) {
    if (_commentBlockwords.isEmpty || content.isEmpty) return false;
    final lower = content.toLowerCase();
    for (final word in _commentBlockwords) {
      if (word.isEmpty) continue;
      if (lower.contains(word.toLowerCase())) return true;
    }
    return false;
  }

  /// 群广告预设正则：内容含「群」且含 8~12 位连续数字。
  static final _groupSpamRegex = RegExp(r'\d{8,12}');

  bool isCommentGroupSpam(String content) {
    if (!_commentBlockGroupSpam || content.isEmpty) return false;
    if (!content.contains('群')) return false;
    return _groupSpamRegex.hasMatch(content);
  }

  Future<void> setCommentBlockNoRemind(bool value) async {
    _commentBlockNoRemind = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(UserManager._keyCommentBlockNoRemind, value);
    _notifyListeners();
  }

  int get logoIndex => _logoIndex;
  String get appLogoPath =>
      appLogoPaths[_logoIndex.clamp(0, appLogoPaths.length - 1)];
  bool get isLoggedIn => _token != null && _token!.isNotEmpty;

  static String normalizeUpdateMirrorPrefix(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return defaultUpdateMirrorPrefix;

    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.hasScheme ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return defaultUpdateMirrorPrefix;
    }

    return trimmed.endsWith('/') ? trimmed : '$trimmed/';
  }

  static String normalizeCopyApiHost(String? value) =>
      _normalizeHost(value, defaultCopyApiHost);

  /// 登录域名不做合法性校验（填什么由用户自己负责），仅去两端空白；
  /// 空值回落内置默认。
  static String normalizeCopyLoginHost(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? defaultCopyLoginHost : trimmed;
  }

  static String _normalizeHost(String? value, String fallback) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return fallback;

    final rawUri = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final uri = Uri.tryParse(rawUri);
    if (uri == null || uri.host.isEmpty) return fallback;

    final host = uri.host.trim().toLowerCase();
    if (host.isEmpty || host.contains(' ')) return fallback;

    final authorityHost = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    return uri.hasPort ? '$authorityHost:${uri.port}' : authorityHost;
  }

  static String normalizeCopyAppVersion(String? value) {
    final version = value?.trim() ?? '';
    return version.isEmpty ? defaultCopyAppVersion : version;
  }

  static bool isValidProxyPort(int? port) =>
      port != null && port > 0 && port <= 65535;

  static Map<String, bool> _decodeBoolMap(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value == true),
      );
    } catch (_) {
      return {};
    }
  }

  void _onSubStoreChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    reader.removeListener(_onSubStoreChanged);
    comment.removeListener(_onSubStoreChanged);
    theme.removeListener(_onSubStoreChanged);
    network.removeListener(_onSubStoreChanged);
    copyAccount.removeListener(_onSubStoreChanged);
    super.dispose();
  }

  int _accountRevision = 0;
  Future<void>? _pendingAccountMutation;
  bool _accountsPausedForRestore = false;

  /// Keep backup snapshots outside partially written account transactions.
  Future<T> readAccountStorage<T>(Future<T> Function() read) =>
      _serializeAccounts(read, allowDuringRestore: true);

  Future<void> pauseAccountMutationsForRestore() async {
    _accountsPausedForRestore = true;
    ++_accountRevision;
    await _pendingAccountMutation;
  }

  void resumeAccountMutationsAfterRestore() {
    _accountsPausedForRestore = false;
  }

  Future<T> _serializeAccounts<T>(
    Future<T> Function() action, {
    bool allowDuringRestore = false,
  }) {
    if (_accountsPausedForRestore && !allowDuringRestore) {
      return Future.error(const CopyAccountStorageException());
    }
    final previous = _pendingAccountMutation;
    final barrier = Completer<void>();
    _pendingAccountMutation = barrier.future;
    Future<T> run() async {
      try {
        return await action();
      } finally {
        if (identical(_pendingAccountMutation, barrier.future)) {
          _pendingAccountMutation = null;
        }
        barrier.complete();
      }
    }

    return previous == null ? run() : previous.then((_) => run());
  }

  SavedCredential? get currentCredential => !isLoggedIn
      ? null
      : SavedCredential(
          username: _username ?? '',
          password: '',
          token: _token,
          loginSource: _loginSource,
          userId: _userId,
          nickname: _nickname,
          avatar: _avatar,
          accountId: _accountId,
        );

  static const _profileKeys = [
    _keyAccountId,
    _keyUserId,
    _keyUsername,
    _keyNickname,
    _keyAvatar,
    _keyLoginSource,
  ];

  Future<void> _requireAccountWrite(Future<bool> write) async {
    if (!await write) throw const CopyAccountStorageException();
  }

  Future<void> _persistProfile(SavedCredential credential) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in {
      _keyUserId: credential.userId ?? '',
      _keyAccountId: credential.accountId ?? '',
      _keyUsername: credential.username,
      _keyNickname: credential.nickname ?? '',
      _keyAvatar: credential.avatar ?? '',
      _keyLoginSource: credential.source,
    }.entries) {
      await _requireAccountWrite(prefs.setString(entry.key, entry.value));
    }
  }

  /// All explicit logins share one commit path: COPY selects both domains;
  /// HOT selects comics only. Reserve revisions before network work so an old
  /// response cannot undo a newer login, logout or manual account selection.
  Future<bool> authenticateAndLogin({
    required String source,
    required Future<Map<String, dynamic>> Function() authenticate,
    String? password,
    bool syncCopyAccount = true,
  }) async {
    final revision = ++_accountRevision;
    final copyRevision = source == 'copy' && syncCopyAccount
        ? copyAccount.beginLogin()
        : null;
    final result = await authenticate();
    if (revision != _accountRevision ||
        (copyRevision != null && copyRevision != copyAccount.revision)) {
      return false;
    }
    final token = result['token'];
    if (token is! String || token.trim().isEmpty) {
      throw const FormatException('Login response lacks a valid token');
    }
    final account = SavedCredential(
      username: result['username']?.toString().trim() ?? '',
      password: '',
      token: token.trim(),
      loginSource: source,
      userId: result['user_id']?.toString().trim(),
      nickname: result['nickname']?.toString(),
      avatar: result['avatar']?.toString(),
      accountId: result['account_id'] is String ? result['account_id'] : null,
    );
    return _serializeAccounts(
      () => _commitLogin(
        account,
        revision: revision,
        copyRevision: copyRevision,
        password: password,
      ),
    );
  }

  Future<void> saveLogin({
    required String token,
    required String userId,
    required String username,
    required String nickname,
    required String avatar,
    bool syncCopyAccount = false,
    int? copyAccountRevision,
    String? loginSource,
  }) async {
    final revision = ++_accountRevision;
    final source = loginSource ?? _loginSource;
    final copyRevision = syncCopyAccount && source == 'copy'
        ? (copyAccountRevision ?? copyAccount.beginLogin())
        : null;
    await _serializeAccounts(
      () => _commitLogin(
        SavedCredential(
          username: username,
          password: '',
          token: token,
          loginSource: source,
          userId: userId,
          nickname: nickname,
          avatar: avatar,
        ),
        revision: revision,
        copyRevision: copyRevision,
      ),
    );
  }

  SavedCredential _resolveCopyCredential(SavedCredential account) {
    final known = [
      ?currentCredential,
      ..._savedCredentials,
    ].where((item) => item.sameAccount(account)).firstOrNull;
    // Resolve before either domain writes: a pre-existing novel binding wins,
    // even if a restored primary credential has another local handle.
    final session = copyAccount.resolveSession(
      CopyAccountSession(
        token: account.token!,
        accountId:
            known?.accountId ??
            (known == null
                ? account.accountId
                : CopyAccountSession.identityOf(
                        userId: known.userId ?? '',
                        username: known.username,
                      ) ??
                      account.accountId),
        userId: account.userId?.isNotEmpty == true
            ? account.userId!
            : known?.userId ?? '',
        username: account.username.isNotEmpty
            ? account.username
            : known?.username ?? '',
        nickname: account.nickname?.isNotEmpty == true
            ? account.nickname!
            : known?.nickname ?? '',
        avatar: account.avatar?.isNotEmpty == true
            ? account.avatar!
            : known?.avatar ?? '',
      ),
    );
    return SavedCredential(
      username: session.username,
      password: account.password,
      token: session.token,
      loginSource: 'copy',
      userId: session.userId,
      nickname: session.nickname,
      avatar: session.avatar,
      accountId: session.id,
    );
  }

  Future<bool> _commitLogin(
    SavedCredential account, {
    required int revision,
    int? copyRevision,
    String? password,
  }) async {
    bool isCurrent() =>
        revision == _accountRevision &&
        (copyRevision == null || copyRevision == copyAccount.revision);
    if (!isCurrent()) return false;
    if (account.token?.trim().isNotEmpty != true ||
        (account.source != 'copy' && !account.hasIdentity)) {
      throw const FormatException('Invalid login account');
    }
    if (account.source == 'copy') account = _resolveCopyCredential(account);
    final retained = [..._savedCredentials];
    final current = currentCredential;
    if (current != null && current.hasAccountKey) {
      final idx = retained.indexWhere((item) => item.sameAccount(current));
      if (idx < 0) {
        retained.add(current);
      } else {
        retained[idx] = current.copyWith(password: retained[idx].password);
      }
    }
    final previous = retained.where((item) => item.sameAccount(account));
    final updated = account.copyWith(
      password: password ?? (previous.isEmpty ? '' : previous.first.password),
    );
    final next = [
      updated,
      ...retained.where((item) => !item.sameAccount(account)),
    ];
    final secure = SecureCredentialStore();
    final prefs = await SharedPreferences.getInstance();
    final previousProfile = {
      for (final key in _profileKeys) key: prefs.getString(key),
    };

    Future<void> restorePrimary() async {
      await secure.writeCredentials(_savedCredentials);
      await secure.writeUsername(_savedUsername);
      await secure.writePassword(_savedPassword);
      await secure.writeToken(_token);
      for (final entry in previousProfile.entries) {
        final value = entry.value;
        await _requireAccountWrite(
          value == null
              ? prefs.remove(entry.key)
              : prefs.setString(entry.key, value),
        );
      }
    }

    void publishPrimary() {
      _savedCredentials = next;
      _savedUsername = updated.username;
      _savedPassword = updated.password;
      _token = updated.token;
      _userId = updated.userId;
      _accountId = updated.accountId;
      _username = updated.username;
      _nickname = updated.nickname;
      _avatar = updated.avatar;
      _loginSource = updated.source;
      ApiClient().user.clearAuthState();
    }

    try {
      await secure.writeCredentials(next);
      await secure.writeUsername(updated.username);
      await secure.writePassword(updated.password);
      await secure.writeToken(updated.token);
      await _persistProfile(updated);
      for (final key in [
        _keyToken,
        _keySavedCredentials,
        _keySavedUsername,
        _keySavedPassword,
      ]) {
        await _requireAccountWrite(prefs.remove(key));
      }
      if (!isCurrent()) {
        await restorePrimary();
        return false;
      }
      if (copyRevision != null) {
        final saved = await copyAccount.saveSession(
          CopyAccountSession(
            token: updated.token!,
            userId: updated.userId ?? '',
            username: updated.username,
            nickname: updated.nickname ?? '',
            avatar: updated.avatar ?? '',
            accountId: updated.accountId,
          ),
          expectedRevision: copyRevision,
          isCurrent: isCurrent,
          onCommitted: publishPrimary,
        );
        if (!saved) {
          await restorePrimary();
          return false;
        }
      } else {
        publishPrimary();
      }
      notifyListeners();
      return true;
    } catch (_) {
      try {
        await restorePrimary();
      } catch (_) {
        unawaited(
          AppLogger.instance.recordWarning(
            const CopyAccountStorageException(),
            source: 'user_manager.restore_login',
          ),
        );
      }
      // Storage failure cannot masquerade as a completed COPY login while the
      // novel account is still empty (the original partial-success bug).
      throw const CopyAccountStorageException();
    }
  }

  Future<void> logout() {
    ++_accountRevision;
    return _serializeAccounts(() async {
      await SecureCredentialStore().writeToken(null);
      final prefs = await SharedPreferences.getInstance();
      for (final key in [
        _keyToken,
        _keyAccountId,
        _keyUserId,
        _keyUsername,
        _keyNickname,
        _keyAvatar,
      ]) {
        await prefs.remove(key);
      }
      ApiClient().user.clearAuthState();
      _token = null;
      _userId = null;
      _accountId = null;
      _username = null;
      _nickname = null;
      _avatar = null;
      notifyListeners();
    });
  }

  /// 把官网登录表单里抓到的用户名/密码并回本机凭据。
  ///
  /// 官网 cookie 常常没有登录名，所以只对「用户名匹配、或用户名尚为空」的
  /// 账号写入；写入失败只记日志，不影响已经完成的登录。
  ///
  /// [anchorToken] 用于自动填表登录：kira 侧明确知道提交的账号密码，登录
  /// 成功后该 token 对应的账号就是本次登录的账号，直接按 token 锚定写入，
  /// 不再要求用户名对得上（新落库的 token-only 账号用户名是空的）。
  Future<void> saveLoginFormPasswords(
    Map<String, String> passwords, {
    String? anchorToken,
  }) async {
    if (passwords.isEmpty) return;
    try {
      await _serializeAccounts(() async {
        var changed = false;
        final next = <SavedCredential>[];
        for (final credential in _savedCredentials) {
          CopyWebLoginForm? match;
          var anchored = false;
          if (credential.source == 'copy') {
            if (anchorToken != null && credential.token == anchorToken) {
              anchored = true;
              for (final entry in passwords.entries) {
                if (entry.value.isNotEmpty) {
                  match = CopyWebLoginForm(
                    username: entry.key,
                    password: entry.value,
                  );
                  break;
                }
              }
            } else {
              for (final entry in passwords.entries) {
                final form = CopyWebLoginForm(
                  username: entry.key,
                  password: entry.value,
                );
                if (canApplyLoginForm(
                  accountUsername: credential.username,
                  accountNickname: credential.nickname ?? '',
                  formUsername: form.username,
                  password: form.password,
                )) {
                  match = form;
                  break;
                }
              }
            }
          }
          final form = match;
          if (form == null) {
            next.add(credential);
            continue;
          }
          // 自动填表登录时表单里的账号名就是登录名，顺手补上，登录页与账号
          // 中心才能按名字回填；已有登录名不覆盖，身份仍以 token 为准。
          final fillsLoginName =
              anchored &&
              credential.username.isEmpty &&
              form.username.isNotEmpty;
          if (credential.password == form.password && !fillsLoginName) {
            next.add(credential);
            continue;
          }
          changed = true;
          next.add(
            credential.copyWith(
              username: fillsLoginName ? form.username : null,
              password: form.password,
            ),
          );
        }
        if (!changed) return;
        await SecureCredentialStore().writeCredentials(next);
        _savedCredentials = next;
        final active = currentCredential;
        if (active != null) {
          for (final credential in next) {
            if (credential.sameAccount(active) &&
                credential.password.isNotEmpty) {
              _savedPassword = credential.password;
              // 自动重登读的是这个槽位，不写的话重启后就丢了。
              await SecureCredentialStore().writePassword(credential.password);
              break;
            }
          }
        }
        notifyListeners();
      });
    } catch (_, st) {
      unawaited(
        AppLogger.instance.recordWarning(
          StateError('Unable to save COPY web login password'),
          stackTrace: st,
          source: 'user_manager.save_login_form',
        ),
      );
    }
  }

  Future<void> saveCredentials(
    String username,
    String password, {
    String? loginSource,
  }) {
    ++_accountRevision;
    final source = loginSource ?? _loginSource;
    return _serializeAccounts(() async {
      final identity = SavedCredential(
        username: username,
        password: password,
        loginSource: source,
      );
      final existing = _savedCredentials.where(
        (item) => item.sameAccount(identity),
      );
      final next = [
        existing.isEmpty
            ? identity
            : existing.first.copyWith(password: password),
        ..._savedCredentials.where((item) => !item.sameAccount(identity)),
      ];
      await SecureCredentialStore().writeCredentials(next);
      await SecureCredentialStore().writeUsername(username);
      await SecureCredentialStore().writePassword(password);
      _savedUsername = username;
      _savedPassword = password;
      _savedCredentials = next;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keySavedUsername);
      await prefs.remove(_keySavedPassword);
      await prefs.remove(_keySavedCredentials);
      notifyListeners();
    });
  }

  Future<void> clearCredentials() {
    ++_accountRevision;
    return _serializeAccounts(() async {
      await SecureCredentialStore().writeCredentials([]);
      await SecureCredentialStore().writeUsername(null);
      await SecureCredentialStore().writePassword(null);
      _savedUsername = null;
      _savedPassword = null;
      _savedCredentials = [];
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keySavedUsername);
      await prefs.remove(_keySavedPassword);
      await prefs.remove(_keySavedCredentials);
      notifyListeners();
    });
  }

  // Kept for legacy callers; account-center UI no longer creates notes.
  void setCopyAccountLabel(String? label) {
    _copyAccountLabel = label?.trim() ?? '';
  }

  String? consumeCopyAccountLabel() {
    final label = _copyAccountLabel;
    _copyAccountLabel = '';
    return label.isEmpty ? null : label;
  }

  Future<bool> switchToCredential(SavedCredential credential) {
    if (credential.token?.isNotEmpty != true || !credential.hasAccountKey) {
      return Future.value(false);
    }
    final revision = ++_accountRevision;
    // Local comic selection must not switch the independent novel account.
    return _serializeAccounts(
      () => _commitLogin(
        credential,
        revision: revision,
        password: credential.password.isEmpty ? null : credential.password,
      ),
    );
  }

  Future<void> removeSavedCredential(
    String username, {
    String? loginSource,
    String? userId,
    String? accountId,
    String? token,
  }) {
    ++_accountRevision;
    final source = loginSource ?? _loginSource;
    final identity = SavedCredential(
      username: username,
      password: '',
      loginSource: source,
      userId: userId,
    );
    bool matches(SavedCredential item) {
      if (source != item.source) return false;
      if (source == 'copy' && accountId?.isNotEmpty == true) {
        final key =
            item.accountId ??
            CopyAccountSession.identityOf(
              userId: item.userId ?? '',
              username: item.username,
            );
        return key == accountId ||
            (token?.isNotEmpty == true && item.token == token);
      }
      return item.sameAccount(identity);
    }

    return _serializeAccounts(() async {
      final next = _savedCredentials.where((item) => !matches(item)).toList();
      await SecureCredentialStore().writeCredentials(next);
      final selected = next.where(
        (item) => currentCredential?.sameAccount(item) == true,
      );
      final replacement = selected.isNotEmpty
          ? selected.first
          : (next.isNotEmpty ? next.first : null);
      await SecureCredentialStore().writeUsername(replacement?.username);
      await SecureCredentialStore().writePassword(replacement?.password);
      _savedCredentials = next;
      _savedUsername = replacement?.username;
      _savedPassword = replacement?.password;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keySavedCredentials);
      await prefs.remove(_keySavedUsername);
      await prefs.remove(_keySavedPassword);
      notifyListeners();
    });
  }

  /// Fetch and apply profile data for the exact stored COPY account. The
  /// request does not change selection; late responses are discarded if either
  /// account domain changes while it is in flight.
  Future<bool> refreshCopyCredential(
    CopyAccountSession credential, {
    required UserApi api,
  }) async {
    final token = credential.token;
    final id = credential.id;
    if (token.isEmpty || id == null) return false;
    final revision = _accountRevision;
    final copyRevision = copyAccount.revision;
    final info = await api.getCopyCredentialInfo(token);

    return _serializeAccounts(() async {
      if (revision != _accountRevision ||
          copyRevision != copyAccount.revision) {
        return false;
      }
      final stored = copyAccount.byId(id);
      if (stored == null || stored.token != token) return false;

      String field(String key, String oldValue) {
        final value = info[key];
        return value is String && value.trim().isNotEmpty
            ? value.trim()
            : oldValue;
      }

      String? nullableField(String key, String? oldValue) {
        final value = info[key];
        return value is String && value.trim().isNotEmpty
            ? value.trim()
            : oldValue;
      }

      final returnedId = field('user_id', '');
      final returnedName = field('username', '');
      final returnedNickname = nullableField('nickname', null);
      final returnedAvatar = nullableField('avatar', null);
      if (returnedId.isEmpty &&
          returnedName.isEmpty &&
          returnedNickname == null &&
          returnedAvatar == null) {
        return false;
      }
      if (returnedId.isNotEmpty &&
          stored.userId.isNotEmpty &&
          returnedId != stored.userId) {
        return false;
      }

      final active = currentCredential;
      final activeMatches = active?.source == 'copy' && active?.token == token;
      final credentialIndex = _savedCredentials.indexWhere(
        (item) => item.source == 'copy' && item.token == token,
      );
      final saved = credentialIndex >= 0
          ? _savedCredentials[credentialIndex]
          : activeMatches
          ? active
          : null;
      if (saved != null &&
          returnedId.isNotEmpty &&
          saved.userId?.isNotEmpty == true &&
          returnedId != saved.userId) {
        return false;
      }

      SavedCredential? updatedPrimary;
      final nextCredentials = [..._savedCredentials];
      if (saved != null) {
        updatedPrimary = SavedCredential(
          username: field('username', saved.username),
          password: saved.password.isNotEmpty
              ? saved.password
              : (activeMatches ? _savedPassword ?? '' : ''),
          token: token,
          loginSource: 'copy',
          userId: returnedId.isNotEmpty ? returnedId : saved.userId,
          nickname: returnedNickname ?? saved.nickname,
          avatar: returnedAvatar ?? saved.avatar,
          accountId: id,
        );
        if (credentialIndex >= 0) {
          nextCredentials[credentialIndex] = updatedPrimary;
        } else {
          nextCredentials.insert(0, updatedPrimary);
        }
      }

      final prefs = await SharedPreferences.getInstance();
      final previousProfile = {
        for (final key in _profileKeys) key: prefs.getString(key),
      };
      final previousCredentials = _savedCredentials;
      var credentialsTouched = false;
      var profileTouched = false;

      Future<void> restorePrimary() async {
        if (credentialsTouched) {
          await SecureCredentialStore().writeCredentials(previousCredentials);
        }
        if (profileTouched) {
          for (final entry in previousProfile.entries) {
            final value = entry.value;
            await _requireAccountWrite(
              value == null
                  ? prefs.remove(entry.key)
                  : prefs.setString(entry.key, value),
            );
          }
        }
      }

      try {
        if (updatedPrimary != null) {
          credentialsTouched = true;
          await SecureCredentialStore().writeCredentials(nextCredentials);
          if (activeMatches) {
            profileTouched = true;
            await _persistProfile(updatedPrimary);
          }
        }
        if (revision != _accountRevision) {
          await restorePrimary();
          return false;
        }
        final updated = await copyAccount.updateProfile(
          id: id,
          token: token,
          profile: info,
          expectedRevision: copyRevision,
          isCurrent: () => revision == _accountRevision,
          onCommitted: (_) {
            _savedCredentials = nextCredentials;
            if (activeMatches && updatedPrimary != null) {
              _userId = updatedPrimary.userId;
              _accountId = id;
              _username = updatedPrimary.username;
              _nickname = updatedPrimary.nickname;
              _avatar = updatedPrimary.avatar;
              _savedUsername = updatedPrimary.username;
            }
          },
        );
        if (!updated) {
          await restorePrimary();
          return false;
        }
        notifyListeners();
        return true;
      } catch (_) {
        try {
          await restorePrimary();
        } catch (_) {
          unawaited(
            AppLogger.instance.recordWarning(
              const CopyAccountStorageException(),
              source: 'user_manager.restore_copy_profile',
            ),
          );
        }
        throw const CopyAccountStorageException();
      }
    });
  }

  /// Profile refresh after successful login is best-effort and never delays or
  /// reverses authentication. Errors are logged without request details.
  void refreshCopyCredentialInBackground(
    CopyAccountSession credential, {
    required UserApi api,
  }) {
    unawaited(
      refreshCopyCredential(credential, api: api).then<void>(
        (_) {},
        onError: (Object _, StackTrace stackTrace) {
          unawaited(
            AppLogger.instance.recordWarning(
              StateError('Background COPY profile refresh failed'),
              stackTrace: stackTrace,
              source: 'user_manager.copy_profile_refresh',
            ),
          );
        },
      ),
    );
  }

  /// Refresh the clicked identity without changing any selection. A response
  /// is discarded if auth/credentials changed while its request was in flight.
  Future<bool> refreshCredential(SavedCredential credential) async {
    final token = credential.token;
    if (token == null || token.isEmpty) return false;
    final revision = _accountRevision;
    final info = await ApiClient().user.getCredentialInfo(
      token: token,
      source: credential.source,
    );
    return _serializeAccounts(() async {
      if (revision != _accountRevision) return false;
      final idx = _savedCredentials.indexWhere(
        (item) => item.sameAccount(credential) && item.token == token,
      );
      final active = currentCredential;
      final isActive =
          active?.sameAccount(credential) == true && active?.token == token;
      if (idx < 0 && !isActive) return false;
      final returnedId = info['user_id']?.toString() ?? '';
      final returnedName = info['username']?.toString() ?? '';
      if (returnedId.isEmpty && returnedName.isEmpty) return false;
      if (credential.userId?.isNotEmpty == true &&
          returnedId.isNotEmpty &&
          credential.userId != returnedId) {
        return false;
      }
      if (returnedName.isNotEmpty && returnedName != credential.username) {
        return false;
      }
      final updated = (idx < 0 ? credential : _savedCredentials[idx]).copyWith(
        userId: returnedId.isEmpty ? credential.userId : returnedId,
        nickname: info['nickname']?.toString(),
        avatar: info['avatar']?.toString(),
      );
      final next = [..._savedCredentials];
      if (idx >= 0) next[idx] = updated;
      // Identity-changing operations reserve a revision before they queue.
      await SecureCredentialStore().writeCredentials(next);
      if (revision != _accountRevision) {
        await SecureCredentialStore().writeCredentials(_savedCredentials);
        return false;
      }
      if (isActive) await _persistProfile(updated);
      if (revision != _accountRevision) {
        await SecureCredentialStore().writeCredentials(_savedCredentials);
        if (isActive && active != null) await _persistProfile(active);
        return false;
      }
      _savedCredentials = next;
      if (isActive) {
        _userId = updated.userId;
        _nickname = updated.nickname;
        _avatar = updated.avatar;
      }
      notifyListeners();
      return true;
    });
  }

  Future<void> refreshUserInfo() async {
    final credential = currentCredential;
    if (credential != null) await refreshCredential(credential);
  }

  Future<void> setLoginSource(String source) {
    ++_accountRevision;
    return _serializeAccounts(() async {
      final prefs = await SharedPreferences.getInstance();
      await _requireAccountWrite(prefs.setString(_keyLoginSource, source));
      _loginSource = source;
    });
  }

  static double _normalizeDarkModeCoverBrightness(double value) {
    return value
        .clamp(minDarkModeCoverBrightness, maxDarkModeCoverBrightness)
        .toDouble();
  }

  /// Prefer the new string key; fall back to the legacy bool for upgrades.
  static BottomNavLabelMode _loadBottomNavLabelMode(SharedPreferences prefs) {
    final saved = prefs.getString(_keyBottomNavLabelMode);
    if (saved != null) {
      for (final mode in BottomNavLabelMode.values) {
        if (mode.name == saved) return mode;
      }
    }
    // Upgrades: old "show labels" becomes the new capsule selected-only
    // mode so users pick up the new bar without staying on classic always.
    final legacy = prefs.getBool(_keyBottomNavShowLabels);
    if (legacy == false) return BottomNavLabelMode.hidden;
    return BottomNavLabelMode.selectedOnly;
  }

  static int _normalizeDisplayModeRefreshRate(int? refreshRate) {
    if (refreshRate == null || refreshRate < 0) {
      return defaultDisplayModeRefreshRate;
    }
    return refreshRate;
  }
}

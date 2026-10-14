import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../api/user/user_api.dart';
import '../l10n/app_localizations.dart';
import '../models/copy_account_store.dart';
import '../models/user_manager.dart';
import '../routing/app_router.dart';
import '../theme/app_icon_sizes.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_status_colors.dart';
import '../utils/app_logger.dart';
import '../utils/copy_signature.dart';
import '../utils/network_error.dart';
import '../utils/toast.dart';
import '../widgets/account_avatar.dart';
import '../widgets/login_node_status.dart';
import '../widgets/setting_tile_group.dart';

/// 拷贝账号的登录通道。声明顺序即选择器里的展示顺序。
enum CopyLoginChannel {
  /// 网页接口登录：直接调官网桌面站登录表单打的那个接口
  /// （`POST {copyLoginHost}/api/kb/web/login`），与 [web] 同一个地址，
  /// 只是省掉 WebView。
  webApi,

  /// App 接口登录：直接调官方 App 的 `/api/v3/login`。
  app,

  /// 官网网页登录：应用内 WebView 自动填表，由网页自己提交登录后取 token。
  web,
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.copyOnly = false, this.userApi});

  final bool copyOnly;

  /// Allows offline tests to inject an API backed exclusively by fake adapters.
  final UserApi? userApi;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static final _hotMangaRegisterUri = Uri.parse(
    'https://m.manga2026.xyz/v2h5/register',
  );

  /// 拷贝官网的注册入口就是登录页：桌面站的「賬號註冊」是登录页里的一个
  /// tab（`/web/login/loginByAccount` 的 el-tabs），没有独立的注册路由。
  /// 域名跟着用户配置的 `copyLoginHost` 走。
  static Uri get _copyMangaRegisterUri => Uri.parse(
    'https://${UserManager().copyLoginHost}/web/login/loginByAccount',
  );

  final _api = ApiClient();
  final _user = UserManager();
  UserApi get _userApi => widget.userApi ?? _api.user;
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  bool _loading = false;
  bool _obscure = true;
  bool _rememberMe = false;
  bool _useCopyLogin = false;

  /// 拷贝模式下的登录通道：默认网页接口登录（官网接口直连，省掉 WebView）。
  /// App 接口登录需要构建期注入签名密钥，未配置时该通道不展示；网页接口
  /// 登录走的是官网浏览器接口，不需要签名，任何构建都提供。
  CopyLoginChannel _copyChannel = CopyLoginChannel.webApi;
  String? _error;

  /// [_error] 是否该用警告框呈现。IP 风控封禁要用户换网络/换节点，是一条
  /// 需要照做的操作指引，比一行红字更该被看见；其余错误（字段没填、密码错）
  /// 是普通失败，保持红字。
  bool _errorWarning = false;

  /// App 接口登录是否可用：功能开关开启且签名密钥就绪时才提供该入口。
  /// 密钥缺失时服务端对无效签名返回空数据（不报错），展示出来只会变成
  /// 「密码正确却登不上」。
  bool get _appLoginAvailable => _appLoginEnabled && CopySignature.isConfigured;

  /// App 接口登录的临时开关：该功能当前仍有问题，先整体关闭入口。修好后
  /// 置回 true 即恢复（届时仍要求签名密钥就绪，见 [_appLoginAvailable]）。
  static const _appLoginEnabled = false;

  /// 两种接口登录都「优先直连，失败再用代理重试一次」。用户配代理多是为了
  /// 看漫画，接口登录走直连通常更快；直连被墙/被风控时再退回代理。
  /// 显式选了「直连」模式时没有可退回的代理，重试没有意义。
  bool get _proxyRetryAvailable =>
      _user.networkProxyMode != NetworkProxyMode.direct;

  @override
  void initState() {
    super.initState();
    _useCopyLogin = widget.copyOnly || _user.loginSource == 'copy';
    _loadSavedCredentials(copy: _useCopyLogin);
    _user.addListener(_onUserChanged);
  }

  @override
  void dispose() {
    _user.removeListener(_onUserChanged);
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _onUserChanged() {
    if (mounted) setState(() {});
  }

  bool _isCopyCredential(SavedCredential credential) {
    final source = credential.loginSource;
    if (source != null && source.isNotEmpty) {
      return source == 'copy';
    }
    if (credential.username == _user.savedUsername) {
      return _user.loginSource == 'copy';
    }
    return false;
  }

  /// 回填已保存的账号密码。热辣模式还会勾上「记住账号」；拷贝模式的密码
  /// 只有网页自动填表与接口登录用得到，不涉及「记住」语义。
  void _loadSavedCredentials({required bool copy}) {
    final next = _user.savedCredentials
        .where((credential) => _isCopyCredential(credential) == copy)
        .firstOrNull;
    if (!copy) _rememberMe = next != null;
    _usernameCtrl.text = next?.username ?? '';
    _passwordCtrl.text = next?.password ?? '';
  }

  /// 当前登录源下已保存、且带登录名的账号，倒序展示（最近保存的靠前）。
  /// 没有登录名的账号无法回填，列出来也没用。
  List<SavedCredential> _savedAccounts() {
    final accounts = _user.savedCredentials
        .where(
          (credential) =>
              _isCopyCredential(credential) == _useCopyLogin &&
              credential.username.trim().isNotEmpty,
        )
        .toList();
    return accounts.reversed.toList();
  }

  /// 一键回填已保存账号的账号与密码。
  void _fillFromSuggestion(SavedCredential credential) {
    _usernameCtrl.text = credential.username;
    _passwordCtrl.text = credential.password;
    _usernameFocus.unfocus();
  }

  /// 登录按钮下方的已保存账号列表，点一项即回填账号与密码。
  List<Widget> _buildSavedAccountList(BuildContext context) {
    final accounts = _savedAccounts();
    if (accounts.isEmpty) return const [];
    return [
      const SizedBox(height: AppSpacing.lg),
      _SavedAccountList(options: accounts, onSelected: _fillFromSuggestion),
    ];
  }

  void _selectLoginSource(bool useCopyLogin) {
    if (widget.copyOnly || _loading) return;
    setState(() {
      _useCopyLogin = useCopyLogin;
      _clearError();
      if (useCopyLogin) _rememberMe = false;
      // 两个来源各有一份已保存账密，切换时换成对应那份，避免把热辣账号
      // 带进拷贝表单（反之亦然）。
      _loadSavedCredentials(copy: useCopyLogin);
    });
  }

  /// 清空错误提示。就地写 `_error = null` 容易漏掉 [_errorWarning]，
  /// 留下「红字变了但仍是警告框」的错配。
  void _clearError() {
    _error = null;
    _errorWarning = false;
  }

  /// 统一设置错误提示。[warning] 为 true 时用警告框呈现（见 [_errorWarning]）。
  void _showError(String message, {bool warning = false}) {
    _error = message;
    _errorWarning = warning;
  }

  Future<void> _openOfficialRegister() async {
    final uri = _useCopyLogin ? _copyMangaRegisterUri : _hotMangaRegisterUri;
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      showToast(
        context,
        AppLocalizations.of(context)!.profileOpenOfficialRegisterFailed,
        isError: true,
      );
    }
  }

  Future<void> _loginHot() async {
    if (_loading || widget.copyOnly || _useCopyLogin) return;
    final l10n = AppLocalizations.of(context)!;
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _showError(l10n.profileUsernamePasswordRequired));
      return;
    }

    setState(() {
      _loading = true;
      _clearError();
    });

    try {
      final saved = await _user.authenticateAndLogin(
        source: 'hotmanga',
        password: _rememberMe ? password : '',
        authenticate: () => _userApi.login(username, password),
      );
      if (!mounted) return;
      if (saved) {
        Navigator.pop(context, true);
      } else {
        setState(() {
          _showError(l10n.copyAccountLoginSuperseded);
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      final blocked = isIpBlockedLoginError(e);
      setState(() {
        _showError(
          blocked
              ? l10n.profileLoginIpBlockedHint
              : l10n.profileLoginFailedProxyHint,
          warning: blocked,
        );
        _loading = false;
      });
    }
  }

  /// 拷贝账号密码登录。网页通道跳转官网登录页并自动填入账号密码，由网页
  /// 自己发出登录请求、成功后从 cookie 拿 token 落库；两个接口通道直接调
  /// 官网/官方 App 的登录接口拿 token。
  Future<void> _loginCopy() async {
    if (_loading) return;
    final l10n = AppLocalizations.of(context)!;
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _showError(l10n.profileUsernamePasswordRequired));
      return;
    }
    if (_copyChannel == CopyLoginChannel.web) {
      final result = await context.pushNamed<bool>(
        AppRoutes.webviewLogin,
        extra: (username: username, password: password),
      );
      if (result == true && mounted) {
        Navigator.pop(context, true);
      }
      return;
    }

    setState(() {
      _loading = true;
      _clearError();
    });
    try {
      final saved = await _user.authenticateAndLogin(
        source: 'copy',
        password: password,
        authenticate: () => _authenticateCopyInterface(username, password),
      );
      if (!mounted) return;
      if (saved) {
        final session = _user.copyAccount.accounts
            .where((item) => item.username == username)
            .firstOrNull;
        if (session != null) {
          _user.refreshCopyCredentialInBackground(session, api: _userApi);
        }
        Navigator.pop(context, true);
      } else {
        setState(() {
          _showError(l10n.copyAccountLoginSuperseded);
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      final blocked = isIpBlockedLoginError(e);
      setState(() {
        _showError(
          blocked
              ? l10n.profileLoginIpBlockedHint
              : l10n.copyAccountInterfaceLoginFailed(NetworkError.message(e)),
          warning: blocked,
        );
        _loading = false;
      });
    }
  }

  /// 接口通道的认证：先直连，失败且用户配了代理时再用代理重试一次。
  ///
  /// 直连失败可能是网络不通，也可能是密码错/风控，两者都值得再试一次代理
  /// （一次请求很便宜）。重试对用户是静默的——两趟都失败时只报最后那次错误，
  /// 免得用户以为「代理才是问题」而去改设置。
  Future<Map<String, dynamic>> _authenticateCopyInterface(
    String username,
    String password,
  ) async {
    final viaApp = _copyChannel == CopyLoginChannel.app;
    Future<Map<String, dynamic>> attempt({required bool useProxy}) => viaApp
        ? _userApi.loginViaApp(username, password, useProxy: useProxy)
        : _userApi.copyLogin(username, password, useProxy: useProxy);

    try {
      return await attempt(useProxy: false);
    } catch (e, st) {
      if (!_proxyRetryAvailable) rethrow;
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: st,
          source: 'login_page.copy_interface_retry',
        ),
      );
      return attempt(useProxy: true);
    }
  }

  /// 切换拷贝登录通道（网页接口 / App 接口 / 网页）。
  void _selectCopyChannel(CopyLoginChannel channel) {
    if (_loading || _copyChannel == channel) return;
    // 已保存的密码按来源通用，切换通道只需清掉上一次的错误提示。
    setState(() {
      _copyChannel = channel;
      _clearError();
    });
  }

  Future<void> _showTokenLoginDialog() async {
    final l10n = AppLocalizations.of(context)!;
    // The selected validation channel is fixed for this dialog. Neither a
    // stale primary loginSource nor later UI changes can reclassify the token.
    final useCopyToken = widget.copyOnly || _useCopyLogin;
    var tokenDraft = '';
    var dialogLoading = false;
    String? dialogError;

    final loggedIn = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> submit() async {
            if (dialogLoading) return;
            final token = tokenDraft.trim();
            if (token.isEmpty) {
              setDialogState(() => dialogError = l10n.profileTokenRequired);
              return;
            }

            setDialogState(() {
              dialogLoading = true;
              dialogError = null;
            });

            try {
              final saved = await _user.authenticateAndLogin(
                source: useCopyToken ? 'copy' : 'hotmanga',
                authenticate: () async {
                  if (useCopyToken) {
                    final session = await _userApi.validateCopyToken(token);
                    return session.toJson();
                  }
                  final info = await _userApi.getCredentialInfo(
                    token: token,
                    source: 'hotmanga',
                  );
                  return {...info, 'token': token};
                },
              );
              if (!dialogContext.mounted) return;
              if (saved) {
                if (useCopyToken) {
                  final session = _user.copyAccount.accounts
                      .where((item) => item.token == token)
                      .firstOrNull;
                  if (session != null) {
                    _user.refreshCopyCredentialInBackground(
                      session,
                      api: _userApi,
                    );
                  }
                }
                Navigator.of(dialogContext).pop(true);
              } else {
                setDialogState(() {
                  dialogError = l10n.copyAccountLoginSuperseded;
                  dialogLoading = false;
                });
              }
            } catch (e) {
              if (!dialogContext.mounted) return;
              setDialogState(() {
                dialogError = e is CopyAccountStorageException
                    ? l10n.copyAccountStorageFailed
                    : l10n.profileTokenInvalidOrExpired;
                dialogLoading = false;
              });
            }
          }

          return PopScope(
            canPop: !dialogLoading,
            child: AlertDialog(
              title: Text(l10n.profileTokenLoginEntry),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      useCopyToken
                          ? l10n.profileCopyCredentialLabel
                          : l10n.profileHotCredentialLabel,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      autofocus: true,
                      enabled: !dialogLoading,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (value) => tokenDraft = value,
                      decoration: InputDecoration(
                        labelText: l10n.profileTokenLabel,
                        prefixIcon: const Icon(Icons.key),
                        hintText: l10n.profileTokenHint,
                        border: OutlineInputBorder(borderRadius: AppRadius.mdR),
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => submit(),
                    ),
                    if (dialogError != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        dialogError!,
                        style: TextStyle(
                          color: Theme.of(dialogContext).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: dialogLoading
                      ? null
                      : () => Navigator.of(dialogContext).pop(false),
                  child: Text(l10n.cancelButton),
                ),
                FilledButton(
                  onPressed: dialogLoading ? null : submit,
                  child: dialogLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.profileLoginButton),
                ),
              ],
            ),
          );
        },
      ),
    );

    if (loggedIn == true && mounted) {
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;
    final contentWidth = screenWidth.clamp(0.0, 400.0);
    final hp = (screenWidth - contentWidth) / 2;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.copyOnly ? l10n.copyAccountLoginTitle : l10n.profileLoginTitle,
        ),
        actions: [
          IconButton(
            tooltip: l10n.profileTokenLoginEntry,
            onPressed: _loading ? null : _showTokenLoginDialog,
            icon: const Icon(Icons.key),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(hp + 24, 24, hp + 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LoginNodeStatusCard(
              useCopyLogin: _useCopyLogin,
              copyChannel: _copyChannel,
            ),
            const SizedBox(height: AppSpacing.lg),
            _buildLoginSourceSelector(context, cs),
            if (_useCopyLogin) ...[
              const SizedBox(height: AppSpacing.lg),
              _buildCopyChannelSelector(),
            ],
            const SizedBox(height: AppSpacing.lg),
            ..._buildAccountPasswordForm(
              context,
              onSubmit: _useCopyLogin ? _loginCopy : _loginHot,
              showRememberMe: !_useCopyLogin,
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: _loading
                  ? null
                  : (_useCopyLogin ? _loginCopy : _loginHot),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: AppRadius.mdR),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      l10n.profileLoginButton,
                      style: const TextStyle(fontSize: 16),
                    ),
            ),
            // 错误提示放在按钮下面：登录失败后视线停在按钮附近，这里最容易被
            // 看到，也不会把表单和按钮挤开。
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              if (_errorWarning)
                _LoginWarningBox(message: _error!)
              else
                Text(
                  _error!,
                  style: TextStyle(color: cs.error),
                  textAlign: TextAlign.center,
                ),
            ],
            ..._buildSavedAccountList(context),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomBar(context, l10n),
    );
  }

  Widget _buildBottomBar(BuildContext context, AppLocalizations l10n) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    // 与页面背景同色：亮色下页面底是 surfaceContainer，写作 cs.surface 会差一档色阶。
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            AppSpacing.sm,
            24,
            AppSpacing.sm + viewInsets,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                key: ValueKey(
                  _useCopyLogin
                      ? 'official-register-copy'
                      : 'official-register-hotmanga',
                ),
                onPressed: _loading ? null : _openOfficialRegister,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(
                  _useCopyLogin
                      ? l10n.loginGoOfficialRegisterCopy
                      : l10n.loginGoOfficialRegisterHot,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoginSourceSelector(BuildContext context, ColorScheme cs) {
    final l10n = AppLocalizations.of(context)!;
    if (widget.copyOnly) {
      return Text(
        l10n.copyAccountIndependentHint,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
      );
    }
    return SegmentedButton<bool>(
      segments: [
        ButtonSegment(
          value: false,
          label: Text(l10n.profileHotCredentialLabel),
          icon: const Icon(Icons.phone_android, size: 18),
        ),
        ButtonSegment(
          value: true,
          label: Text(l10n.profileCopyCredentialLabel),
          icon: const Icon(Icons.language, size: 18),
        ),
      ],
      selected: {_useCopyLogin},
      onSelectionChanged: (v) => _selectLoginSource(v.first),
    );
  }

  /// 拷贝登录通道选择器（网页接口 / App 接口 / 网页）。App 接口通道在签名
  /// 密钥缺失时不提供（见 [_appLoginAvailable]）——密钥无效时服务端只返回
  /// 空数据，摆出来就是「密码正确却登不上」。
  ///
  /// 只有文字：三项都是「XX登录」，文字本身已说明含义，图标（含选中态的
  /// 对勾）会把这一行挤得很挤。
  Widget _buildCopyChannelSelector() {
    final l10n = AppLocalizations.of(context)!;
    return SegmentedButton<CopyLoginChannel>(
      showSelectedIcon: false,
      segments: [
        ButtonSegment(
          value: CopyLoginChannel.webApi,
          label: Text(l10n.copyAccountChannelWebApi),
        ),
        if (_appLoginAvailable)
          ButtonSegment(
            value: CopyLoginChannel.app,
            label: Text(l10n.copyAccountChannelApp),
          ),
        ButtonSegment(
          value: CopyLoginChannel.web,
          label: Text(l10n.copyAccountChannelWeb),
        ),
      ],
      selected: {_copyChannel},
      onSelectionChanged: (v) => _selectCopyChannel(v.first),
    );
  }

  List<Widget> _buildAccountPasswordForm(
    BuildContext context, {
    required Future<void> Function() onSubmit,
    bool showRememberMe = true,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return [
      TextField(
        key: const ValueKey('login-username-field'),
        controller: _usernameCtrl,
        focusNode: _usernameFocus,
        decoration: InputDecoration(
          labelText: l10n.profileUsernameLabel,
          prefixIcon: const Icon(Icons.person_outline),
          border: OutlineInputBorder(borderRadius: AppRadius.mdR),
        ),
        textInputAction: TextInputAction.next,
        onSubmitted: (_) => _passwordFocus.requestFocus(),
      ),
      const SizedBox(height: AppSpacing.lg),
      TextField(
        key: const ValueKey('login-password-field'),
        controller: _passwordCtrl,
        focusNode: _passwordFocus,
        obscureText: _obscure,
        decoration: InputDecoration(
          labelText: l10n.profilePasswordLabel,
          prefixIcon: const Icon(Icons.lock_outline),
          suffixIcon: IconButton(
            icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
          border: OutlineInputBorder(borderRadius: AppRadius.mdR),
        ),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => onSubmit(),
      ),
      const SizedBox(height: AppSpacing.sm),
      if (showRememberMe)
        CheckboxListTile(
          value: _rememberMe,
          onChanged: (v) => setState(() => _rememberMe = v ?? false),
          title: Text(l10n.profileRememberAccountLabel),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
        ),
    ];
  }
}

/// 需要用户照做的失败提示（IP 风控封禁）用的警告框：图标 + 警告色底。
///
/// 与设置页的并发警告同款（`download_settings_sheet.dart`），比一行红字更
/// 难被忽略——这条提示要求用户换网络/换节点，而不是重试一次就好。
class _LoginWarningBox extends StatelessWidget {
  const _LoginWarningBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final warning = AppStatusColors.warning(cs);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: warning.withValues(alpha: 0.12),
        borderRadius: AppRadius.mdR,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: AppIconSize.lg,
            color: warning,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(message, style: tt.bodySmall?.copyWith(color: warning)),
          ),
        ],
      ),
    );
  }
}

/// 登录按钮下方的已保存账号列表，点一项即回填账号与密码。
/// 视觉沿用账号中心的账号行（头像 + 名称 + 昵称）与设置项分组卡片。
class _SavedAccountList extends StatelessWidget {
  const _SavedAccountList({required this.options, required this.onSelected});

  final List<SavedCredential> options;
  final ValueChanged<SavedCredential> onSelected;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return SettingTileGroup(
      children: [
        for (final credential in options)
          ListTile(
            key: ValueKey('login-saved-account-${credential.username}'),
            leading: AccountAvatar(avatar: credential.avatar),
            title: Text(
              credential.username,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tt.bodyLarge,
            ),
            subtitle: (credential.nickname ?? '').isNotEmpty
                ? Text(credential.nickname!, style: tt.bodySmall)
                : null,
            onTap: () => onSelected(credential),
          ),
      ],
    );
  }
}

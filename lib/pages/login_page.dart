import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../api/user/user_api.dart';
import '../l10n/app_localizations.dart';
import '../models/copy_account_store.dart';
import '../models/user_manager.dart';
import '../routing/app_router.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../utils/toast.dart';
import '../widgets/account_avatar.dart';
import '../widgets/login_node_status.dart';
import '../widgets/setting_tile_group.dart';

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
  String? _error;

  @override
  void initState() {
    super.initState();
    _useCopyLogin = widget.copyOnly || _user.loginSource == 'copy';
    if (!_useCopyLogin) _loadHotCredentials();
    _usernameCtrl.addListener(_onCredentialDraftChanged);
    _usernameFocus.addListener(_onCredentialDraftChanged);
    _user.addListener(_onUserChanged);
  }

  @override
  void dispose() {
    _user.removeListener(_onUserChanged);
    _usernameCtrl.removeListener(_onCredentialDraftChanged);
    _usernameFocus.removeListener(_onCredentialDraftChanged);
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _onUserChanged() {
    if (mounted) setState(() {});
  }

  void _onCredentialDraftChanged() {
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

  void _loadHotCredentials() {
    final next = _user.savedCredentials
        .where((credential) => !_isCopyCredential(credential))
        .firstOrNull;
    _rememberMe = next != null;
    _usernameCtrl.text = next?.username ?? '';
    _passwordCtrl.text = next?.password ?? '';
  }

  /// 当前登录源下已保存、且带登录名的账号，倒序展示（最近保存的靠前）。
  /// 没有登录名的账号无法回填，列出来也没用。
  List<SavedCredential> _savedAccounts() =>
      _user.savedCredentials
          .where(
            (credential) =>
                _isCopyCredential(credential) == _useCopyLogin &&
                credential.username.trim().isNotEmpty,
          )
          .toList()
          .reversed
          .toList();

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
      _SavedAccountList(
        options: accounts,
        onSelected: _fillFromSuggestion,
      ),
    ];
  }

  Widget _buildUsernameField(BuildContext context, AppLocalizations l10n) {
    return TextField(
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
    );
  }

  void _selectLoginSource(bool useCopyLogin) {
    if (widget.copyOnly || _loading) return;
    setState(() {
      _useCopyLogin = useCopyLogin;
      _error = null;
      if (useCopyLogin) {
        _rememberMe = false;
        _usernameCtrl.clear();
        _passwordCtrl.clear();
      } else {
        _loadHotCredentials();
      }
    });
  }

  Future<void> _goWebLogin() async {
    final result = await context.pushNamed<bool>(AppRoutes.webviewLogin);
    if (result == true && mounted) {
      Navigator.pop(context, true);
    }
  }

  Future<void> _openOfficialRegister() async {
    final launched = await launchUrl(
      _hotMangaRegisterUri,
      mode: LaunchMode.externalApplication,
    );
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
      setState(() => _error = l10n.profileUsernamePasswordRequired);
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
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
          _error = l10n.copyAccountLoginSuperseded;
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = isIpBlockedLoginError(e)
            ? l10n.profileLoginIpBlockedHint
            : l10n.profileLoginFailedProxyHint;
        _loading = false;
      });
    }
  }

  /// 拷贝账号密码登录：跳转官网登录页并自动填入账号密码、由网页自己发出
  /// 登录请求，成功后从 cookie 拿 token 走令牌登录落库；网页里失败时用户
  /// 仍可手动改密码重试。
  Future<void> _loginCopy() async {
    if (_loading) return;
    final l10n = AppLocalizations.of(context)!;
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = l10n.profileUsernamePasswordRequired);
      return;
    }
    final result = await context.pushNamed<bool>(
      AppRoutes.webviewLogin,
      extra: (username: username, password: password),
    );
    if (result == true && mounted) {
      Navigator.pop(context, true);
    }
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
          if (_useCopyLogin)
            IconButton(
              tooltip: l10n.profileWebLoginButton,
              onPressed: _loading ? null : _goWebLogin,
              icon: const Icon(Icons.language),
            ),
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
            LoginNodeStatusCard(useCopyLogin: _useCopyLogin),
            const SizedBox(height: AppSpacing.lg),
            _buildLoginSourceSelector(context, cs),
            const SizedBox(height: AppSpacing.lg),
            ..._buildAccountPasswordForm(
              context,
              onSubmit: _useCopyLogin ? _loginCopy : _loginHot,
              showRememberMe: !_useCopyLogin,
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                _error!,
                style: TextStyle(color: cs.error),
                textAlign: TextAlign.center,
              ),
            ],
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
            ..._buildSavedAccountList(context),
          ],
        ),
      ),
      bottomNavigationBar: _useCopyLogin
          ? null
          : _buildBottomBar(context, l10n),
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
                key: const ValueKey('official-register-hotmanga'),
                onPressed: _loading ? null : _openOfficialRegister,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(l10n.loginGoOfficialRegisterHot),
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

  List<Widget> _buildAccountPasswordForm(
    BuildContext context, {
    required Future<void> Function() onSubmit,
    bool showRememberMe = true,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return [
      _buildUsernameField(context, l10n),
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

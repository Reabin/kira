import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../api/user/user_api.dart';
import '../l10n/app_localizations.dart';
import '../models/copy_account_store.dart';
import '../models/user_manager.dart';
import '../routing/app_router.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import '../utils/app_logger.dart';
import '../utils/screen_layout.dart';
import '../utils/toast.dart';
import '../widgets/account_avatar.dart';
import '../widgets/select_tile.dart';
import '../widgets/setting_tile_group.dart';

class AccountCenterPage extends StatefulWidget {
  const AccountCenterPage({super.key});

  @override
  State<AccountCenterPage> createState() => _AccountCenterPageState();
}

class _AccountCenterPageState extends State<AccountCenterPage> {
  final _user = UserManager();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _user.addListener(_onChanged);
  }

  @override
  void dispose() {
    _user.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _toast(String message, {bool isError = false}) {
    if (mounted) showToast(context, message, isError: isError);
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      await action();
    } on CopyProfileUnavailableException {
      _toast(l10n.copyProfileRefreshUnavailable, isError: true);
    } on CopyAccountStorageException {
      _toast(l10n.copyAccountStorageFailed, isError: true);
    } catch (_) {
      unawaited(
        AppLogger.instance.recordWarning(
          StateError('Account action failed'),
          source: 'account_center.action',
        ),
      );
      _toast(l10n.userInfoRefreshFailedToast, isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  SavedCredential? get _current => _user.currentCredential;
  List<CopyAccountSession> get _copyAccounts => _user.copyAccount.accounts;

  List<SavedCredential> get _primaryAccounts {
    final result = <SavedCredential>[];
    for (final credential in [?_current, ..._user.savedCredentials]) {
      if (credential.token?.isNotEmpty != true) continue;
      if (result.any((item) => item.sameAccount(credential))) continue;
      if (credential.source == 'copy' &&
          _copyAccounts.any((item) => item.token == credential.token)) {
        continue;
      }
      result.add(credential);
    }
    return result;
  }

  bool _isCurrent(SavedCredential credential) =>
      _current?.sameAccount(credential) == true;

  bool _copyIsCurrent(CopyAccountSession account) =>
      _user.isLoggedIn &&
      _user.loginSource == 'copy' &&
      _user.token == account.token;

  String _name(String username, String? nickname, String? id) {
    if (username.trim().isNotEmpty) return username.trim();
    if (nickname?.trim().isNotEmpty == true) return nickname!.trim();
    return id?.trim() ?? '';
  }

  String _credentialName(SavedCredential account) =>
      _name(account.username, account.nickname, account.userId);
  String _copyName(CopyAccountSession account) =>
      _name(account.username, account.nickname, account.userId);
  String _credentialKey(SavedCredential account) =>
      'primary-${account.source}-${account.username.isNotEmpty ? account.username : account.userId}';
  String _copyKey(CopyAccountSession account) => 'copy-${account.id}';
  String _sourceLabel(AppLocalizations l10n, SavedCredential account) =>
      account.source == 'copy'
      ? l10n.profileCopyCredentialLabel
      : l10n.profileHotCredentialLabel;

  Widget _comicSelect(AppLocalizations l10n) {
    final primary = _primaryAccounts;
    final copies = _copyAccounts;
    final selectedCopy = copies.where(_copyIsCurrent).firstOrNull;
    final current = _current;
    final selected = selectedCopy != null
        ? _copyKey(selectedCopy)
        : current == null
        ? 'none'
        : _credentialKey(current);
    return IgnorePointer(
      ignoring: _busy,
      child: SelectTile<String>(
        key: const ValueKey('comic-account-select'),
        value: selected,
        items: [
          if (current == null)
            SelectItem('none', l10n.accountCenterNotLoggedIn),
          for (final account in primary)
            SelectItem(
              _credentialKey(account),
              _credentialName(account),
            ),
          for (final account in copies)
            SelectItem(_copyKey(account), _copyName(account)),
          SelectItem('add', l10n.addAccountButton),
        ],
        onChanged: (value) {
          if (_busy || value == selected) return;
          if (value == 'add') {
            unawaited(_login());
            return;
          }
          final credential = primary
              .where((item) => _credentialKey(item) == value)
              .firstOrNull;
          if (credential != null) {
            unawaited(_switchToCredential(credential));
            return;
          }
          final copy = copies
              .where((item) => _copyKey(item) == value)
              .firstOrNull;
          if (copy != null) unawaited(_useCopyAsPrimary(copy));
        },
      ),
    );
  }

  Widget _novelSelect(AppLocalizations l10n) {
    final copies = _copyAccounts;
    final selected = _user.copyAccount.session;
    return IgnorePointer(
      ignoring: _busy,
      child: SelectTile<String>(
        key: const ValueKey('novel-account-select'),
        value: selected == null ? 'none' : _copyKey(selected),
        items: [
          if (selected == null)
            SelectItem('none', l10n.accountCenterNotLoggedIn),
          for (final account in copies)
            SelectItem(_copyKey(account), _copyName(account)),
          SelectItem('add', l10n.addAccountButton),
        ],
        onChanged: (value) {
          if (_busy) return;
          if (value == 'add') {
            unawaited(_login(copyOnly: true));
            return;
          }
          final account = copies
              .where((item) => _copyKey(item) == value)
              .firstOrNull;
          if (account != null && account.id != selected?.id) {
            unawaited(_selectCopy(account));
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hp = ScreenLayout.horizontalPadding(MediaQuery.sizeOf(context).width);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.accountCenterTitle)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(hp, AppSpacing.md, hp, AppSpacing.xl),
        children: [
          _SectionLabel(l10n.accountCenterActiveLabel),
          SettingTileGroup(
            children: [
              ListTile(
                leading: const Icon(Icons.menu_book_rounded),
                title: Text(l10n.accountCenterComicAccount),
                trailing: _comicSelect(l10n),
              ),
              ListTile(
                leading: const Icon(Icons.auto_stories_rounded),
                title: Text(l10n.accountCenterNovelAccount),
                trailing: _novelSelect(l10n),
              ),
            ],
          ),
          Padding(
            key: const ValueKey('novel-account-copy-only-hint'),
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.xs,
              AppSpacing.lg,
              0,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    l10n.accountCenterNovelCopyOnlyHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _SectionLabel(l10n.accountCenterSavedLabel),
          SettingTileGroup(
            children: [
              for (final account in _primaryAccounts)
                _AccountTile(
                  key: ValueKey(_credentialKey(account)),
                  title: _credentialName(account),
                  avatar: account.avatar,
                  badge: _sourceLabel(l10n, account),
                  selectedLabel: _isCurrent(account)
                      ? l10n.accountCenterComicAccount
                      : '',
                  busy: _busy,
                  onRefresh: () => _refreshCredential(account),
                  onCopy: () => _copyToken(account.token),
                  onLogout: () => _removeCredential(account),
                ),
              for (final account in _copyAccounts)
                _AccountTile(
                  key: ValueKey(_copyKey(account)),
                  title: _copyName(account),
                  avatar: account.avatar,
                  badge: l10n.profileCopyCredentialLabel,
                  selectedLabel: [
                    if (_copyIsCurrent(account)) l10n.accountCenterComicAccount,
                    if (account.id == _user.copyAccount.activeId)
                      l10n.accountCenterNovelAccount,
                  ].join(' · '),
                  busy: _busy,
                  onRefresh: _refreshCopy,
                  onCopy: () => _copyToken(account.token),
                  onLogout: () => _removeCopy(account),
                ),
              ListTile(
                key: const ValueKey('add-account'),
                leading: const Icon(Icons.person_add_alt_1),
                title: Text(l10n.addAccountButton),
                onTap: _busy ? null : _login,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _login({bool copyOnly = false}) async {
    final switched = AppLocalizations.of(context)!.accountSwitchedToast;
    final result = await context.pushNamed<bool>(
      AppRoutes.login,
      queryParameters: copyOnly ? {'copyOnly': 'true'} : const {},
    );
    if (result == true) _toast(switched);
  }

  Future<void> _copyToken(String? token) => _guard(() async {
    final l10n = AppLocalizations.of(context)!;
    if (token == null || token.isEmpty) {
      _toast(l10n.tokenUnavailableToast, isError: true);
      return;
    }
    await Clipboard.setData(ClipboardData(text: token));
    _toast(l10n.tokenCopiedToast);
  });

  Future<void> _refreshCredential(SavedCredential account) => _guard(() async {
    final l10n = AppLocalizations.of(context)!;
    final refreshed = await _user.refreshCredential(account);
    _toast(
      refreshed ? l10n.userInfoRefreshedToast : l10n.userInfoRefreshFailedToast,
      isError: !refreshed,
    );
  });

  Future<void> _refreshCopy() => _guard(() async {
    throw const CopyProfileUnavailableException();
  });

  Future<void> _switchToCredential(SavedCredential account) => _guard(() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await _user.switchToCredential(account);
    _toast(
      ok ? l10n.accountSwitchedToast : l10n.switchAccountFailedToast,
      isError: !ok,
    );
  });

  // Manual comic selection deliberately differs from a new COPY login: it
  // selects comics only and preserves the separately chosen novel account.
  Future<void> _useCopyAsPrimary(CopyAccountSession account) =>
      _switchToCredential(
        SavedCredential(
          username: account.username,
          password: '',
          token: account.token,
          loginSource: 'copy',
          userId: account.userId,
          nickname: account.nickname,
          avatar: account.avatar,
        ),
      );

  Future<void> _selectCopy(CopyAccountSession account) => _guard(() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await _user.copyAccount.selectAccount(account.id);
    _toast(
      ok ? l10n.accountSwitchedToast : l10n.switchAccountFailedToast,
      isError: !ok,
    );
  });

  Future<void> _removeCredential(SavedCredential account) async {
    final l10n = AppLocalizations.of(context)!;
    if (!await _confirm(l10n.logoutTitle, l10n.logoutConfirmContent)) {
      return;
    }
    await _guard(() async {
      if (_isCurrent(account)) await _user.logout();
      await _user.removeSavedCredential(
        account.username,
        loginSource: account.source,
        userId: account.userId,
      );
    });
  }

  Future<void> _removeCopy(CopyAccountSession account) async {
    final l10n = AppLocalizations.of(context)!;
    if (!await _confirm(
      l10n.logoutTitle,
      l10n.accountCenterRemoveConfirm(_copyName(account)),
    )) {
      return;
    }
    await _guard(() async {
      await _user.copyAccount.removeAccount(account.id!);
      if (_copyIsCurrent(account)) await _user.logout();
      await _user.removeSavedCredential(
        account.username,
        loginSource: 'copy',
        userId: account.userId,
      );
    });
  }

  Future<bool> _confirm(String title, String content) async {
    final l10n = AppLocalizations.of(context)!;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.cancelButton),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.confirmButton),
              ),
            ],
          ),
        ) ==
        true;
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.xs,
      AppSpacing.xs,
      AppSpacing.xs,
      AppSpacing.sm,
    ),
    child: Text(
      text,
      style: AppTypography.meta(
        Theme.of(context).textTheme,
      )?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

enum _AccountAction { refresh, copy, logout }

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    super.key,
    required this.title,
    required this.avatar,
    required this.badge,
    required this.selectedLabel,
    required this.busy,
    required this.onRefresh,
    required this.onCopy,
    required this.onLogout,
  });

  final String title;
  final String? avatar;
  final String badge;
  final String selectedLabel;
  final bool busy;
  final VoidCallback onRefresh;
  final VoidCallback onCopy;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: AccountAvatar(avatar: avatar),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: cs.secondaryContainer,
              borderRadius: AppRadius.fullR,
            ),
            child: Text(
              badge,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: cs.onSecondaryContainer),
            ),
          ),
          if (selectedLabel.isNotEmpty)
            Text(
              selectedLabel,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: cs.primary),
            ),
        ],
      ),
      trailing: PopupMenuButton<_AccountAction>(
        enabled: !busy,
        onSelected: (action) {
          switch (action) {
            case _AccountAction.refresh:
              onRefresh();
            case _AccountAction.copy:
              onCopy();
            case _AccountAction.logout:
              onLogout();
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: _AccountAction.refresh,
            child: Text(l10n.refreshUserButton),
          ),
          PopupMenuItem(
            value: _AccountAction.copy,
            child: Text(l10n.copyTokenButton),
          ),
          PopupMenuItem(
            value: _AccountAction.logout,
            child: Text(l10n.logoutTitle),
          ),
        ],
      ),
    );
  }
}

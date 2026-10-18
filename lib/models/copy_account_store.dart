import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../utils/app_logger.dart';
import 'account_identity.dart';
import 'secure_credential_store.dart';

/// Only COPY credentials may enter this store. The primary account is separate.
///
/// [id] is a stable, non-secret handle, independent of the token. Accounts
/// without a known server identity receive a local handle when saved. Bindings
/// (「轻小说用哪个账号」) keep that handle when profile fields are later filled in.
@immutable
class CopyAccountSession {
  final String token;
  final String? accountId;
  final String userId;
  final String username;
  final String nickname;
  final String avatar;

  /// User-chosen note for telling accounts apart in 账号中心. Server identity
  /// stays authoritative; the label is only a display aid.
  final String label;

  /// Historical local handles proven to name this account. Kept with the
  /// account so deleting it also invalidates queued downloads' old bindings.
  final List<String> mergedAccountIds;

  const CopyAccountSession({
    required this.token,
    this.accountId,
    this.userId = '',
    this.username = '',
    this.nickname = '',
    this.avatar = '',
    this.label = '',
    this.mergedAccountIds = const [],
  });

  CopyAccountSession copyWith({
    String? token,
    String? accountId,
    String? userId,
    String? username,
    String? nickname,
    String? avatar,
    String? label,
    List<String>? mergedAccountIds,
  }) => CopyAccountSession(
    token: token ?? this.token,
    accountId: accountId ?? this.accountId,
    userId: userId ?? this.userId,
    username: username ?? this.username,
    nickname: nickname ?? this.nickname,
    avatar: avatar ?? this.avatar,
    label: label ?? this.label,
    mergedAccountIds: mergedAccountIds == null
        ? this.mergedAccountIds
        : List.unmodifiable(mergedAccountIds),
  );

  /// Stable, opaque identity for bindings. Prefer the server id; fall back to
  /// a digest of the login name for entries saved before `user_id` was
  /// recorded. The digest keeps the account list itself free of plaintext
  /// usernames — a record is only persisted when a token exists anyway.
  static String? identityOf({String userId = '', String username = ''}) {
    final id = userId.trim();
    if (id.isNotEmpty) return 'u:$id';
    final name = username.trim();
    if (name.isEmpty) return null;
    return 'n:${sha256.convert(utf8.encode(name)).toString().substring(0, 32)}';
  }

  AccountIdentity get identity => AccountIdentity(
    source: 'copy',
    username: username,
    userId: userId,
    token: token,
    accountId: id,
  );

  bool sameAccount(CopyAccountSession other) =>
      identity.matches(other.identity);

  bool acceptsProfile({String userId = '', String username = ''}) {
    final name = username.trim();
    if (name.isNotEmpty && this.username.trim().isNotEmpty) {
      return name == this.username.trim();
    }
    final id = userId.trim();
    return id.isEmpty || this.userId.trim().isEmpty || id == this.userId.trim();
  }

  bool get hasIdentity =>
      userId.trim().isNotEmpty || username.trim().isNotEmpty;

  /// Older records keep their derived id. Once saved, the pinned account id
  /// takes precedence even when a later login provides more profile fields.
  String? get id {
    final savedId = accountId?.trim();
    return savedId?.isNotEmpty == true
        ? savedId
        : identityOf(userId: userId, username: username);
  }

  factory CopyAccountSession.fromJson(Map<String, dynamic> json) {
    final token = json['token'];
    if (token is! String || token.trim().isEmpty) {
      throw const FormatException('Invalid COPY session');
    }
    final accountId = json['account_id'];
    final aliases = json['merged_account_ids'];
    final mergedAccountIds = aliases is List
        ? aliases
              .whereType<String>()
              .map((id) => id.trim())
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList()
        : <String>[];
    mergedAccountIds.sort();
    return CopyAccountSession(
      token: token.trim(),
      accountId: accountId is String && accountId.trim().isNotEmpty
          ? accountId.trim()
          : null,
      userId: json['user_id']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      nickname: json['nickname']?.toString() ?? '',
      avatar: json['avatar']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      mergedAccountIds: List.unmodifiable(mergedAccountIds),
    );
  }

  Map<String, dynamic> toJson() => {
    'token': token,
    if (accountId != null) 'account_id': accountId,
    'user_id': userId,
    'username': username,
    'nickname': nickname,
    'avatar': avatar,
    'label': label,
    if (mergedAccountIds.isNotEmpty) 'merged_account_ids': mergedAccountIds,
  };

  /// Identity is the membership key: a re-login of the same person updates
  /// that entry (and its token/label) instead of duplicating the list.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CopyAccountSession && id != null && other.id == id;

  @override
  int get hashCode => id?.hashCode ?? identityHashCode(this);
}

String? _resolveAccountId(List<CopyAccountSession> accounts, String? id) {
  if (id == null || id.isEmpty) return null;
  final current = accounts.where((account) => account.id == id).toList();
  if (current.isNotEmpty) return current.length == 1 ? id : null;
  final aliases = accounts
      .where((account) => account.mergedAccountIds.contains(id))
      .toList();
  return aliases.length == 1 ? aliases.single.id : null;
}

/// A pure reconciliation result shared with the primary-account transaction.
/// The map keeps bindings reachable when several old handles name one person.
class CopyAccountMerge {
  final List<CopyAccountSession> accounts;
  final String? activeId;
  final Map<String, String> idRemap;
  final CopyAccountSession? incoming;

  const CopyAccountMerge({
    required this.accounts,
    required this.activeId,
    required this.idRemap,
    this.incoming,
  });
}

CopyAccountMerge mergeCopyAccounts(
  List<CopyAccountSession> accounts, {
  String? activeId,
  CopyAccountSession? incoming,
  CopyAccountSession? preferredSession,
  bool selectIncoming = false,
}) {
  final groups = groupAccounts<CopyAccountSession>([
    ...accounts,
    ?incoming,
  ], (account) => account.identity);
  // Two different people sharing one handle is never trustworthy: the handle
  // dies for both. A handle that is another group's persisted merge alias is
  // different — history wins, so the adopting group takes a new handle rather
  // than stealing the alias from its rightful owner.
  final currentOwners = <String, List<int>>{};
  final aliasOwners = <String, List<int>>{};
  for (var index = 0; index < groups.length; index++) {
    for (final id
        in groups[index].map((item) => item.id).whereType<String>().toSet()) {
      (currentOwners[id] ??= []).add(index);
    }
    for (final id in groups[index].expand((item) => item.mergedAccountIds)) {
      (aliasOwners[id] ??= []).add(index);
    }
  }
  final conflictingIds = currentOwners.entries
      .where((entry) => entry.value.length > 1)
      .map((entry) => entry.key)
      .toSet();
  bool foreignAlias(String? id, int group) =>
      id != null &&
      !conflictingIds.contains(id) &&
      (aliasOwners[id] ?? const []).any((owner) => owner != group);
  final preferredGroups = preferredSession == null
      ? <List<CopyAccountSession>>[]
      : groups
            .where(
              (group) =>
                  group.any((item) => item.sameAccount(preferredSession)),
            )
            .toList();
  final merged = <CopyAccountSession>[];
  final positions = Map<CopyAccountSession, int>.identity();
  final remap = <String, String>{};
  CopyAccountSession? mergedIncoming;
  for (var index = 0; index < groups.length; index++) {
    final group = groups[index];
    final originals = group
        .where((item) => !identical(item, incoming))
        .toList();
    // Existing identified handles win over a temporary token-only handle.
    // With no timestamps, lexical handle order is a deterministic fallback,
    // not a claim that a particular historical token is newer.
    int compare(CopyAccountSession a, CopyAccountSession b) {
      if (a.hasIdentity != b.hasIdentity) return a.hasIdentity ? -1 : 1;
      return (a.id ?? '').compareTo(b.id ?? '');
    }

    originals.sort(compare);
    final stable = originals.isEmpty ? group.first : originals.first;
    // A historical id shared by different people is not a trustworthy alias,
    // and one already aliased to another account is not free to adopt: give
    // this group a distinct handle and leave the old id with its owner.
    final reclaimed = conflictingIds.contains(stable.id)
        ? stable.id
        : foreignAlias(stable.id, index)
        ? stable.id
        : null;
    final id = reclaimed != null ? CopyAccountStore._newAccountId() : stable.id;
    if (id == null) continue;
    final hasIncoming =
        incoming != null && group.any((item) => identical(item, incoming));
    final preferred =
        preferredGroups.length == 1 && identical(preferredGroups.single, group)
        ? preferredSession
        : null;
    final selected = group.where((item) => item.id == activeId).firstOrNull;
    var entry = hasIncoming ? incoming : preferred ?? selected ?? stable;
    final fields = [entry, ...originals, ...group];
    String nonEmpty(String Function(CopyAccountSession) field) =>
        fields
            .map(field)
            .where((value) => value.trim().isNotEmpty)
            .firstOrNull ??
        '';
    final aliases = <String>{
      for (final item in group) ...[?item.id, ...item.mergedAccountIds],
    }..removeAll({id, ...conflictingIds, ?reclaimed});
    final mergedAccountIds = aliases.toList()..sort();
    entry = entry.copyWith(
      accountId: id,
      mergedAccountIds: mergedAccountIds,
      userId: nonEmpty((item) => item.userId),
      username: nonEmpty((item) => item.username),
      nickname: nonEmpty((item) => item.nickname),
      avatar: nonEmpty((item) => item.avatar),
      label: nonEmpty((item) => item.label),
    );
    if (!hasIncoming &&
        group.length == 1 &&
        stable.accountId == null &&
        !conflictingIds.contains(stable.id) &&
        jsonEncode(stable.toJson()..remove('account_id')) ==
            jsonEncode(entry.toJson()..remove('account_id'))) {
      // Merely loading an unchanged legacy record must not pin its derived id
      // or rewrite storage. Pin it when identity/profile/token actually changes.
      entry = stable;
    }
    merged.add(entry);
    positions[entry] = accounts.indexWhere(
      (original) => group.any((item) => identical(item, original)),
    );
    if (hasIncoming) mergedIncoming = entry;
  }
  for (final entry in merged) {
    for (final oldId in [?entry.id, ...entry.mergedAccountIds]) {
      final resolved = _resolveAccountId(merged, oldId);
      if (resolved != null) remap[oldId] = resolved;
    }
  }
  // Preserve presentation order; identity grouping itself processes named
  // entries first only to avoid ambiguous incomplete-identity bridges.
  int position(CopyAccountSession entry) {
    if (mergedIncoming != null && entry.id == mergedIncoming.id) return -1;
    return positions[entry]!;
  }

  merged.sort((a, b) => position(a).compareTo(position(b)));
  final selected = selectIncoming && mergedIncoming != null
      ? mergedIncoming.id
      : remap[activeId];
  return CopyAccountMerge(
    accounts: merged,
    activeId: selected ?? (merged.isEmpty ? null : merged.first.id),
    idRemap: remap,
    incoming: mergedIncoming,
  );
}

/// Deliberately excludes the underlying storage error, which may contain secrets.
class CopyAccountStorageException implements Exception {
  const CopyAccountStorageException();

  @override
  String toString() => 'COPY account local storage unavailable';
}

/// Independent COPY account list with a durable one-time migration marker.
///
/// Every mutation is serialized. A revision is reserved *before* validation,
/// so a late login result cannot undo a logout or a newer account selection.
class CopyAccountStore extends ChangeNotifier {
  final SecureCredentialStore? _secureStore;
  SecureCredentialStore get _secure => _secureStore ?? SecureCredentialStore();

  CopyAccountStore({SecureCredentialStore? secureStore})
    : _secureStore = secureStore;

  List<CopyAccountSession> _accounts = [];
  String? _activeId;
  bool _migrationHandled = false;
  bool _cleared = false;
  int _revision = 0;
  Future<void>? _pending;

  /// Every stored COPY account, most recently added first.
  List<CopyAccountSession> get accounts => List.unmodifiable(_accounts);

  /// The COPY account the light-novel module currently authenticates with.
  CopyAccountSession? get session => byId(_activeId);

  CopyAccountSession? byId(String? id) {
    if (id == null) return null;
    for (final account in _accounts) {
      if (account.id == id) return account;
    }
    return null;
  }

  /// Resolve only current handles or persisted, unambiguous merge aliases.
  /// [byId] intentionally stays strict for account mutations and auth checks.
  String? resolveAccountId(String? id) => _resolveAccountId(_accounts, id);

  /// A stored list with no explicit selection still has an obvious answer:
  /// the most recent account. Used by the legacy import path, which may hold a
  /// primary COPY session that was deliberately not persisted yet.
  String? get activeId {
    if (_activeId != null) return _activeId;
    return _accounts.isEmpty ? null : _accounts.first.id;
  }

  String? get token => session?.token;
  bool get isLoggedIn => token != null && token!.isNotEmpty;
  bool get migrationHandled => _migrationHandled;

  /// Changes as soon as an identity-changing operation begins, before storage
  /// finishes or notifications fire. Consumers can reject stale responses.
  int get revision => _revision;

  Future<T> _serialize<T>(Future<T> Function() action) {
    final previous = _pending;
    final barrier = Completer<void>();
    _pending = barrier.future;

    Future<T> run() async {
      try {
        return await action();
      } finally {
        // Never retain an idle Future from another Zone (e.g. setUp versus
        // widget FakeAsync). Release it before the caller can observe the
        // operation completing, while keeping queued operations serialized.
        if (identical(_pending, barrier.future)) _pending = null;
        barrier.complete();
      }
    }

    // The barrier is success-only; a failed operation still releases the next
    // operation while its own result preserves the error for its caller.
    return previous == null ? run() : previous.then((_) => run());
  }

  /// [error] 只用于日志：界面文案刻意不含底层存储错误（可能带密钥内容），
  /// 但日志至少要留下异常类型，否则「保存失败」永远无从定位。
  static void _logStorageFailure(String operation, [Object? error]) {
    unawaited(
      AppLogger.instance.recordWarning(
        'COPY account storage unavailable (${(error ?? const CopyAccountStorageException()).runtimeType})',
        stackTrace: error == null ? null : StackTrace.current,
        source: 'copy_account.$operation',
      ),
    );
  }

  /// Load the record. [legacySession] must only be supplied for a COPY primary
  /// account, after its source and all profile fields have finished loading.
  /// A record explicitly cleared by the user is a tombstone; a legacy empty
  /// record written by an older build is not — a live COPY primary may still
  /// be imported into an empty list.
  Future<void> init({
    CopyAccountSession? legacySession,
    bool persistMigrations = true,
    bool Function()? isCurrent,
    Future<void> Function(CopyAccountMerge merge)? prepareCommit,
    void Function(CopyAccountMerge merge)? onCommitted,
    Future<void> Function()? rollback,
  }) {
    final revision = ++_revision;
    bool current() => revision == _revision && isCurrent?.call() != false;
    return _serialize(() async {
      if (!current()) return;
      try {
        final raw = await _secure.readCopyAccountRecord();
        var accounts = <CopyAccountSession>[];
        String? activeId;
        var handled = false;
        var cleared = false;
        if (raw != null) {
          final decoded = jsonDecode(raw);
          if (decoded is! Map || decoded['migrationHandled'] is! bool) {
            throw const FormatException('Invalid COPY account record');
          }
          handled = decoded['migrationHandled'] == true;
          accounts = _decodeAccounts(decoded);
          activeId = decoded['activeId']?.toString();
          cleared = decoded['cleared'] == true;
        }
        if (!current()) return;
        final originalAccounts = accounts;
        final originalActiveId = activeId;
        // An explicit clear always wins. Read-only backup reloads must neither
        // import the primary nor rotate the independent novel credentials.
        final importLegacy =
            persistMigrations &&
            !cleared &&
            accounts.isEmpty &&
            legacySession != null &&
            (raw == null || handled);
        if (importLegacy) {
          accounts = [_resolveSession(legacySession, accounts)];
        }
        var merge = mergeCopyAccounts(
          accounts,
          activeId: activeId,
          preferredSession: persistMigrations ? legacySession : null,
        );
        final changed =
            jsonEncode(originalAccounts.map((a) => a.toJson()).toList()) !=
                jsonEncode(merge.accounts.map((a) => a.toJson()).toList()) ||
            originalActiveId != merge.activeId;
        var primaryPrepared = false;
        var copyWritten = false;
        final originalHandled = handled;
        Future<void> rollbackPrimary() async {
          if (!primaryPrepared) return;
          try {
            await rollback?.call();
          } catch (error) {
            // Compensation failure must not discard the readable COPY snapshot.
            _logStorageFailure('restore_primary', error);
          }
        }

        try {
          primaryPrepared = prepareCommit != null;
          await prepareCommit?.call(merge);
          if (!current()) {
            await rollbackPrimary();
            return;
          }
          if (persistMigrations && (!handled || importLegacy || changed)) {
            if (cleared && merge.accounts.isEmpty) {
              await _writeClearedRecord();
            } else {
              await _writeRecord(merge.accounts, merge.activeId);
            }
            copyWritten = true;
            handled = true;
          }
          if (!current()) {
            if (copyWritten) await _restorePublishedRecord();
            await rollbackPrimary();
            return;
          }
          onCommitted?.call(merge);
        } catch (error) {
          // Keep both readable snapshots when either side fails. Normal startup
          // can retry the cleanup; it must not report a half-committed identity.
          await rollbackPrimary();
          if (copyWritten) {
            try {
              if (raw != null) {
                await _secure.writeCopyAccountRecord(raw);
              } else {
                await _restorePublishedRecord();
              }
            } catch (error) {
              _logStorageFailure('restore_copy', error);
            }
          }
          handled = originalHandled;
          _logStorageFailure('migrate', error);
          merge = CopyAccountMerge(
            accounts: originalAccounts,
            activeId: _reachable(originalActiveId, originalAccounts),
            idRemap: const {},
          );
        }
        if (!current()) return;
        _accounts = merge.accounts;
        _activeId = merge.activeId;
        _migrationHandled = handled;
        _cleared = cleared && _accounts.isEmpty;
        notifyListeners();
      } catch (error) {
        // Storage failures never block or clear the primary account.
        _logStorageFailure('init', error);
      }
    });
  }

  /// Accepts the current list record and the single-session record written by
  /// earlier builds, so an upgrade never loses the logged-in COPY account.
  static List<CopyAccountSession> _decodeAccounts(Map<dynamic, dynamic> raw) {
    final list = raw['accounts'];
    final source = list is List ? list : [raw['session']];
    final accounts = <CopyAccountSession>[];
    for (final item in source) {
      if (item is! Map) continue;
      final account = CopyAccountSession.fromJson(
        Map<String, dynamic>.from(item),
      );
      accounts.add(
        account.id == null
            ? account.copyWith(accountId: _newAccountId())
            : account,
      );
    }
    return accounts;
  }

  /// An active pointer must never dangle: a record edited or truncated by an
  /// older/newer build still has to resolve to a real account.
  static String? _reachable(String? activeId, List<CopyAccountSession> list) {
    for (final account in list) {
      if (account.id == activeId) return activeId;
    }
    return list.isEmpty ? null : list.first.id;
  }

  /// Resolve a validated login before a dual-domain commit writes credentials.
  /// This does not publish or persist anything; the caller must retain the
  /// returned id and keep its revision guard until saveSession completes.
  CopyAccountMerge previewSession(
    CopyAccountSession session, {
    bool select = true,
  }) {
    final validated = CopyAccountSession.fromJson(session.toJson());
    var candidate = validated.copyWith(
      accountId: validated.id ?? _newAccountId(),
    );
    final groups = groupAccounts<CopyAccountSession>([
      ..._accounts,
      candidate,
    ], (account) => account.identity);
    final incomingGroup = groups.firstWhere(
      (group) => group.any((item) => identical(item, candidate)),
    );
    if (_accounts.any(
      (existing) =>
          existing.id == candidate.id &&
          !incomingGroup.any((item) => identical(item, existing)),
    )) {
      candidate = candidate.copyWith(accountId: _newAccountId());
    }
    return mergeCopyAccounts(
      _accounts,
      activeId: activeId,
      incoming: candidate,
      selectIncoming: select,
    );
  }

  CopyAccountSession resolveSession(CopyAccountSession session) =>
      previewSession(session).incoming!;

  static CopyAccountSession _resolveSession(
    CopyAccountSession session,
    List<CopyAccountSession> accounts,
  ) {
    final validated = CopyAccountSession.fromJson(session.toJson());
    return mergeCopyAccounts(
      accounts,
      incoming: validated.copyWith(accountId: validated.id ?? _newAccountId()),
    ).incoming!;
  }

  static String _newAccountId() {
    final random = Random.secure();
    final bytes = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    );
    return 'local:${bytes.join()}';
  }

  int beginLogin() => ++_revision;

  Future<bool> login(Future<CopyAccountSession> Function() validate) async {
    final revision = beginLogin();
    final session = await validate();
    return saveSession(session, expectedRevision: revision);
  }

  /// Adds (or replaces) an account. Persists before notifying. False means a
  /// newer operation superseded this login. Invalid data never modifies the
  /// stored accounts.
  ///
  /// [select] 为 false 时只入库不改选中：登录不再抢占已选好的轻小说账号，
  /// 只有当前没有选中账号时才由调用方置为 true。
  Future<bool> saveSession(
    CopyAccountSession session, {
    int? expectedRevision,
    bool Function()? isCurrent,
    void Function()? onCommitted,
    bool select = true,
  }) {
    final validated = CopyAccountSession.fromJson(session.toJson());
    final revision = expectedRevision ?? beginLogin();
    bool superseded() => revision != _revision || isCurrent?.call() == false;
    return _serialize(() async {
      if (superseded()) return false;
      final merge = previewSession(validated, select: select);
      final next = merge.accounts;
      final nextActiveId = merge.activeId;
      try {
        await _writeRecord(next, nextActiveId);
        if (superseded()) {
          // The write may have been in flight when logout/a newer validation
          // began. Restore the last published state before the next queued
          // operation runs, so a failed newer validation cannot revive it.
          await _restorePublishedRecord();
          return false;
        }
      } catch (error) {
        _logStorageFailure('save', error);
        throw const CopyAccountStorageException();
      }
      if (superseded()) return false;
      _accounts = next;
      _activeId = nextActiveId;
      _migrationHandled = true;
      _cleared = false;
      // A dual-domain login publishes the primary state before either set of
      // listeners observes this newly selected COPY identity.
      onCommitted?.call();
      notifyListeners();
      return true;
    });
  }

  /// Refreshes profile fields for a stored account without changing either
  /// selected account. The exact token and revisions guard against stale data.
  Future<bool> updateProfile({
    required String id,
    required String token,
    required Map<String, dynamic> profile,
    required int expectedRevision,
    bool Function()? isCurrent,
    void Function(CopyAccountSession session)? onCommitted,
  }) {
    if (_revision != expectedRevision || isCurrent?.call() == false) {
      return Future.value(false);
    }
    final revision = ++_revision;
    bool current() => revision == _revision && isCurrent?.call() != false;
    String field(String key, String oldValue) {
      final value = profile[key];
      return value is String && value.trim().isNotEmpty
          ? value.trim()
          : oldValue;
    }

    return _serialize(() async {
      if (!current()) return false;
      final existing = byId(id);
      if (existing == null || existing.token != token) return false;
      final returnedId = field('user_id', '');
      if (!existing.acceptsProfile(
        userId: returnedId,
        username: field('username', ''),
      )) {
        return false;
      }
      final updated = existing.copyWith(
        accountId: existing.id,
        userId: returnedId.isEmpty ? existing.userId : returnedId,
        username: field('username', existing.username),
        nickname: field('nickname', existing.nickname),
        avatar: field('avatar', existing.avatar),
      );
      final merge = previewSession(updated, select: false);
      final next = merge.accounts;
      try {
        await _writeRecord(next, merge.activeId);
        if (!current()) {
          await _restorePublishedRecord();
          return false;
        }
      } catch (error) {
        _logStorageFailure('refresh', error);
        throw const CopyAccountStorageException();
      }
      if (!current()) return false;
      _accounts = next;
      _activeId = merge.activeId;
      _migrationHandled = true;
      onCommitted?.call(merge.incoming!);
      notifyListeners();
      return true;
    });
  }

  /// Refreshes the stored token and profile of an already known account
  /// without changing the active selection. Used by commits that run without a
  /// COPY revision (auto-relogin, manual comic selection): the identity must
  /// already be stored, so a background relogin can never add accounts or
  /// override a manual novel selection. False means superseded or unknown id.
  Future<bool> syncSessionToken({
    required String id,
    required CopyAccountSession session,
    int? expectedRevision,
    bool Function()? isCurrent,
    void Function(CopyAccountSession session)? onCommitted,
  }) {
    if (expectedRevision != null && expectedRevision != _revision) {
      return Future.value(false);
    }
    final revision = ++_revision;
    bool current() => revision == _revision && isCurrent?.call() != false;
    String field(String value, String oldValue) =>
        value.trim().isNotEmpty ? value.trim() : oldValue;
    return _serialize(() async {
      if (!current()) return false;
      final existing = byId(id);
      if (existing == null) return false;
      final returnedId = field(session.userId, existing.userId);
      if (!existing.acceptsProfile(
        userId: returnedId,
        username: session.username,
      )) {
        return false;
      }
      final updated = existing.copyWith(
        token: field(session.token, existing.token),
        userId: returnedId,
        username: field(session.username, existing.username),
        nickname: field(session.nickname, existing.nickname),
        avatar: field(session.avatar, existing.avatar),
      );
      final merge = previewSession(updated, select: false);
      final next = merge.accounts;
      try {
        await _writeRecord(next, merge.activeId);
        if (!current()) {
          await _restorePublishedRecord();
          return false;
        }
      } catch (error) {
        _logStorageFailure('sync', error);
        throw const CopyAccountStorageException();
      }
      if (!current()) return false;
      _accounts = next;
      _activeId = merge.activeId;
      _migrationHandled = true;
      onCommitted?.call(merge.incoming!);
      notifyListeners();
      return true;
    });
  }

  /// Repoints the light-novel module at another already-stored account.
  /// Unknown ids are refused rather than silently falling back.
  Future<bool> selectAccount(String? id) {
    if (byId(id) == null) return Future.value(false);
    final revision = ++_revision;
    return _serialize(() async {
      if (revision != _revision) return false;
      try {
        await _writeRecord(_accounts, id);
        if (revision != _revision) {
          await _restorePublishedRecord();
          return false;
        }
      } catch (error) {
        _logStorageFailure('select', error);
        throw const CopyAccountStorageException();
      }
      if (revision != _revision) return false;
      _activeId = id;
      _migrationHandled = true;
      notifyListeners();
      return true;
    });
  }

  /// Renames one stored account's note. The token and identity are untouched.
  Future<bool> renameAccount(String id, String label) {
    final account = byId(id);
    if (account == null) return Future.value(false);
    final revision = ++_revision;
    return _serialize(() async {
      if (revision != _revision) return false;
      final next = [
        for (final item in _accounts)
          if (item.id == id) account.copyWith(label: label.trim()) else item,
      ];
      try {
        await _writeRecord(next, _activeId);
      } catch (error) {
        _logStorageFailure('rename', error);
        throw const CopyAccountStorageException();
      }
      if (revision != _revision) return false;
      _accounts = next;
      _migrationHandled = true;
      notifyListeners();
      return true;
    });
  }

  /// Removes one account. When it was active, the next stored account takes
  /// over so the user is never left pointed at a removed identity. Removing
  /// the last account persists an explicit clear tombstone: the user has
  /// emptied the list and a later COPY-primary restart must not import the
  /// primary back.
  Future<void> removeAccount(String id) {
    ++_revision;
    return _serialize(() async {
      final next = _accounts.where((account) => account.id != id).toList();
      final activeId = _reachable(_activeId == id ? null : _activeId, next);
      try {
        if (next.isEmpty) {
          await _writeClearedRecord();
        } else {
          await _writeRecord(next, activeId);
        }
      } catch (error) {
        _logStorageFailure('remove', error);
        throw const CopyAccountStorageException();
      }
      _accounts = next;
      _activeId = activeId;
      _migrationHandled = true;
      _cleared = next.isEmpty;
      notifyListeners();
    });
  }

  /// Does not call the primary API, clear cookies, or delete any other secrets.
  Future<void> logout() {
    final id = _activeId;
    return id == null ? Future.value() : removeAccount(id);
  }

  /// Drops every COPY account, including the persisted record.
  Future<void> clear() {
    ++_revision;
    return _serialize(() async {
      try {
        await _writeClearedRecord();
      } catch (error) {
        _logStorageFailure('clear', error);
        throw const CopyAccountStorageException();
      }
      _accounts = const [];
      _activeId = null;
      _migrationHandled = true;
      _cleared = true;
      notifyListeners();
    });
  }

  /// Restoring an empty list must retain an explicit logout tombstone, not
  /// turn it into a legacy empty record that can re-import the primary account.
  Future<void> _restorePublishedRecord() =>
      _cleared ? _writeClearedRecord() : _writeRecord(_accounts, _activeId);

  Future<void> _writeRecord(
    List<CopyAccountSession> accounts,
    String? activeId,
  ) => _secure.writeCopyAccountRecord(
    jsonEncode({
      'migrationHandled': true,
      'activeId': _reachable(activeId, accounts),
      'accounts': accounts.map((account) => account.toJson()).toList(),
    }),
  );

  /// The explicit tombstone: unlike a legacy empty record it also survives a
  /// later COPY-primary restart.
  Future<void> _writeClearedRecord() => _secure.writeCopyAccountRecord(
    jsonEncode({
      'migrationHandled': true,
      'cleared': true,
      'activeId': null,
      'accounts': const [],
    }),
  );
}

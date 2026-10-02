import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../utils/app_logger.dart';
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

  const CopyAccountSession({
    required this.token,
    this.accountId,
    this.userId = '',
    this.username = '',
    this.nickname = '',
    this.avatar = '',
    this.label = '',
  });

  CopyAccountSession copyWith({
    String? accountId,
    String? userId,
    String? username,
    String? nickname,
    String? avatar,
    String? label,
  }) => CopyAccountSession(
    token: token,
    accountId: accountId ?? this.accountId,
    userId: userId ?? this.userId,
    username: username ?? this.username,
    nickname: nickname ?? this.nickname,
    avatar: avatar ?? this.avatar,
    label: label ?? this.label,
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

/// Deliberately excludes the platform exception, which may contain secrets.
class CopyAccountStorageException implements Exception {
  const CopyAccountStorageException();

  @override
  String toString() => 'COPY account secure storage unavailable';
}

/// Secure, independent COPY account list with a durable one-time migration
/// marker.
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

  static void _logStorageFailure(String operation) {
    unawaited(
      AppLogger.instance.recordWarning(
        const CopyAccountStorageException(),
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
  }) {
    final revision = ++_revision;
    return _serialize(() async {
      if (revision != _revision) return;
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
        if (revision != _revision) return;
        if (!handled && persistMigrations) {
          // Prefer an existing record over legacy credentials, even if a
          // future/older writer left its marker false.
          accounts = raw == null && legacySession != null
              ? [_resolveSession(legacySession, accounts)]
              : accounts;
          activeId = accounts.isEmpty ? null : accounts.first.id;
          await _writeRecord(accounts, activeId);
          if (revision != _revision) {
            await _writeRecord(_accounts, _activeId);
            return;
          }
          handled = true;
        } else if (handled &&
            !cleared &&
            accounts.isEmpty &&
            legacySession != null &&
            persistMigrations) {
          // An empty record left by an HOT-first init (or an older build) is
          // not a user intent: once the primary is a live COPY session it may
          // be imported. Only an explicit clear (「cleared」 tombstone) blocks
          // re-import after the user deliberately emptied the list.
          accounts = [_resolveSession(legacySession, accounts)];
          activeId = accounts.first.id;
          await _writeRecord(accounts, activeId);
          if (revision != _revision) return;
        }
        if (revision != _revision) return;
        _accounts = accounts;
        _activeId = _reachable(activeId, accounts);
        _migrationHandled = handled;
        notifyListeners();
      } catch (_) {
        // Secure storage outages never block or clear the primary account.
        _logStorageFailure('init');
      }
    });
  }

  /// Accepts the current list record and the single-session record written by
  /// earlier builds, so an upgrade never loses the logged-in COPY account.
  static List<CopyAccountSession> _decodeAccounts(Map<dynamic, dynamic> raw) {
    final list = raw['accounts'];
    final source = list is List ? list : [raw['session']];
    final accounts = <CopyAccountSession>[];
    final seen = <String>{};
    for (final item in source) {
      if (item is! Map) continue;
      final account = CopyAccountSession.fromJson(
        Map<String, dynamic>.from(item),
      );
      final id = account.id;
      if (id == null || !seen.add(id)) continue;
      accounts.add(account);
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
  CopyAccountSession resolveSession(CopyAccountSession session) =>
      _resolveSession(session, _accounts);

  static CopyAccountSession _resolveSession(
    CopyAccountSession session,
    List<CopyAccountSession> accounts,
  ) {
    final candidate = CopyAccountSession.fromJson(session.toJson());
    var known = accounts
        .where((account) => account.token == candidate.token)
        .firstOrNull;
    known ??= accounts
        .where(
          (account) =>
              candidate.accountId != null && account.id == candidate.accountId,
        )
        .firstOrNull;
    if (known == null && candidate.userId.trim().isNotEmpty) {
      known = accounts
          .where((account) => account.userId.trim() == candidate.userId.trim())
          .firstOrNull;
    }
    if (known == null && candidate.username.trim().isNotEmpty) {
      known = accounts
          .where(
            (account) =>
                account.username.trim() == candidate.username.trim() &&
                (account.userId.trim().isEmpty ||
                    candidate.userId.trim().isEmpty),
          )
          .firstOrNull;
    }
    if (known == null) {
      return candidate.copyWith(accountId: candidate.id ?? _newAccountId());
    }
    // An exact token or known identity may fill profile gaps, but must not
    // change an existing binding (including legacy username-derived ids).
    return candidate.copyWith(
      accountId: known.id,
      userId: candidate.userId.trim().isEmpty ? known.userId : candidate.userId,
      username: candidate.username.trim().isEmpty
          ? known.username
          : candidate.username,
      nickname: candidate.nickname.trim().isEmpty
          ? known.nickname
          : candidate.nickname,
      avatar: candidate.avatar.trim().isEmpty ? known.avatar : candidate.avatar,
      label: candidate.label.trim().isEmpty ? known.label : candidate.label,
    );
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

  /// Adds (or replaces) an account and makes it the active COPY account.
  /// Persists before notifying. False means a newer operation superseded this
  /// login. Invalid data never modifies the stored accounts.
  Future<bool> saveSession(
    CopyAccountSession session, {
    int? expectedRevision,
    bool Function()? isCurrent,
    void Function()? onCommitted,
  }) {
    final validated = CopyAccountSession.fromJson(session.toJson());
    final revision = expectedRevision ?? beginLogin();
    bool superseded() => revision != _revision || isCurrent?.call() == false;
    return _serialize(() async {
      if (superseded()) return false;
      final entry = resolveSession(validated);
      final next = [
        entry,
        ..._accounts.where((account) => account.id != entry.id),
      ];
      try {
        await _writeRecord(next, entry.id);
        if (superseded()) {
          // The write may have been in flight when logout/a newer validation
          // began. Restore the last published state before the next queued
          // operation runs, so a failed newer validation cannot revive it.
          await _writeRecord(_accounts, _activeId);
          return false;
        }
      } catch (_) {
        _logStorageFailure('save');
        throw const CopyAccountStorageException();
      }
      if (superseded()) return false;
      _accounts = next;
      _activeId = entry.id;
      _migrationHandled = true;
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
      if (returnedId.isNotEmpty &&
          existing.userId.isNotEmpty &&
          returnedId != existing.userId) {
        return false;
      }
      final updated = existing.copyWith(
        accountId: existing.id,
        userId: returnedId.isEmpty ? existing.userId : returnedId,
        username: field('username', existing.username),
        nickname: field('nickname', existing.nickname),
        avatar: field('avatar', existing.avatar),
      );
      final next = [
        for (final account in _accounts)
          if (account.id == id) updated else account,
      ];
      try {
        await _writeRecord(next, _activeId);
        if (!current()) {
          await _writeRecord(_accounts, _activeId);
          return false;
        }
      } catch (_) {
        _logStorageFailure('refresh');
        throw const CopyAccountStorageException();
      }
      if (!current()) return false;
      _accounts = next;
      _migrationHandled = true;
      onCommitted?.call(updated);
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
          await _writeRecord(_accounts, _activeId);
          return false;
        }
      } catch (_) {
        _logStorageFailure('select');
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
      } catch (_) {
        _logStorageFailure('rename');
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
      } catch (_) {
        _logStorageFailure('remove');
        throw const CopyAccountStorageException();
      }
      _accounts = next;
      _activeId = activeId;
      _migrationHandled = true;
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
      } catch (_) {
        _logStorageFailure('clear');
        throw const CopyAccountStorageException();
      }
      _accounts = const [];
      _activeId = null;
      _migrationHandled = true;
      notifyListeners();
    });
  }

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

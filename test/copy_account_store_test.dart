import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/copy_account_store.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/models/user_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecureStore extends InMemorySecureCredentialStore {
  bool failRead = false;
  bool failWrite = false;
  bool failAllWrites = false;
  int writes = 0;
  Completer<void>? writeStarted;
  Completer<void>? releaseWrite;

  @override
  Future<String?> readCopyAccountRecord() async {
    if (failRead) throw StateError('secret-token-in-platform-read-error');
    return super.readCopyAccountRecord();
  }

  @override
  Future<void> doWrite(String key, String value) async {
    // 模拟 secure 存储整体不可写（迁移主凭据同样失败）。
    if (failAllWrites) throw StateError('secure-storage-unavailable');
    return super.doWrite(key, value);
  }

  @override
  Future<void> writeCopyAccountRecord(String value) async {
    writes++;
    if (failWrite) throw StateError('secret-token-in-platform-write-error');
    final started = writeStarted;
    final release = releaseWrite;
    writeStarted = null;
    releaseWrite = null;
    started?.complete();
    if (release != null) await release.future;
    await super.writeCopyAccountRecord(value);
  }
}

const _copyA = CopyAccountSession(
  token: 'copy-a',
  userId: 'copy-id',
  username: 'copy-user',
  nickname: 'COPY name',
);
const _copyB = CopyAccountSession(
  token: 'copy-b',
  userId: 'copy-b-id',
  username: 'copy-b-user',
);

Map<String, Object?> _primarySnapshot(UserManager user) => {
  'token': user.token,
  'source': user.loginSource,
  'id': user.userId,
  'username': user.username,
  'nickname': user.nickname,
  'avatar': user.avatar,
  'savedUsername': user.savedUsername,
  'savedPassword': user.savedPassword,
  'credentials': jsonEncode(
    user.savedCredentials.map((e) => e.toJson()).toList(),
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _MemorySecureStore secure;
  late CopyAccountStore store;
  final user = UserManager();

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'user_token': 'hot-token',
      'user_username': 'same-username',
      'user_nickname': 'HOT name',
      'user_id': 'hot-id',
      'user_avatar': '',
      'login_source': 'hotmanga',
      'saved_username': 'same-username',
      'saved_password': 'hot-password',
      'saved_credentials': jsonEncode([
        {
          'username': 'same-username',
          'password': 'hot-password',
          'token': 'hot-token',
          'login_source': 'hotmanga',
        },
      ]),
    });
    secure = _MemorySecureStore();
    SecureCredentialStore.setInstance(secure);
    store = CopyAccountStore(secureStore: secure);
    await user.init();
  });

  tearDown(() {
    store.dispose();
    SecureCredentialStore.resetInstance();
  });

  test(
    'HOT primary never supplies a COPY token; secure holds a tombstone',
    () async {
      expect(user.token, 'hot-token');
      expect(user.isLoggedIn, isTrue);
      expect(user.copyToken, isNull);
      expect(user.isCopyLoggedIn, isFalse);
      expect(jsonDecode((await secure.readCopyAccountRecord())!), {
        'migrationHandled': true,
        'activeId': null,
        'accounts': <Object?>[],
      });
    },
  );

  test(
    'COPY success/failure/logout/restart leave HOT primary and prefs intact',
    () async {
      final before = _primarySnapshot(user);
      final prefs = await SharedPreferences.getInstance();
      final beforePrefs = {
        for (final key in prefs.getKeys()) key: prefs.get(key),
      };
      await secure.writeWebDavCredentials('webdav-secret');
      await secure.writeBackupPassword('backup-secret');
      await secure.writeBackupRollbackKey('journal-secret');
      await user.copyAccount.saveSession(_copyA);
      expect(user.copyToken, _copyA.token);
      expect(user.isCopyLoggedIn, isTrue);
      await user.init();
      expect(user.copyToken, _copyA.token);
      await expectLater(
        user.copyAccount.login(
          () async => throw StateError('validation failed'),
        ),
        throwsStateError,
      );
      expect(user.copyToken, _copyA.token);
      await user.copyAccount.logout();
      await user.init();
      expect(user.copyToken, isNull);
      expect(_primarySnapshot(user), before);
      expect({
        for (final key in prefs.getKeys()) key: prefs.get(key),
      }, beforePrefs);
      expect(await secure.readWebDavCredentials(), 'webdav-secret');
      expect(await secure.readBackupPassword(), 'backup-secret');
      expect(await secure.readBackupRollbackKey(), 'journal-secret');
    },
  );

  test(
    'first COPY init copies complete primary metadata exactly once',
    () async {
      secure = _MemorySecureStore();
      SecureCredentialStore.setInstance(secure);
      SharedPreferences.setMockInitialValues({
        'login_source': 'copy',
        'user_token': 'legacy-copy',
        'user_id': 'legacy-id',
        'user_username': 'legacy-user',
        'user_nickname': 'legacy-name',
        'user_avatar': 'legacy-avatar',
      });
      await user.init();
      expect(user.copyAccount.session?.toJson(), {
        // 迁移固定原派生标识；后续补充资料不改变已有绑定。
        'token': 'legacy-copy',
        'account_id': 'u:legacy-id',
        'user_id': 'legacy-id',
        'username': 'legacy-user',
        'nickname': 'legacy-name',
        'avatar': 'legacy-avatar',
        'label': '',
      });
      expect(user.copyAccount.session?.id, 'u:legacy-id');
      expect(user.copyAccount.accounts.length, 1);
      expect(secure.writes, 1);
      await user.init();
      expect(secure.writes, 1);
      await user.copyAccount.logout();
      await user.init();
      expect(user.token, 'legacy-copy');
      expect(user.copyToken, isNull);
      final restarted = CopyAccountStore(secureStore: secure);
      addTearDown(restarted.dispose);
      await restarted.init(legacySession: _copyA);
      expect(restarted.token, isNull);
    },
  );

  test(
    'a later explicit primary COPY login syncs despite migration tombstone',
    () async {
      await user.setLoginSource('copy');
      await user.saveLogin(
        token: 'new-primary-copy',
        userId: 'id',
        username: 'copy',
        nickname: 'Copy',
        avatar: '',
        syncCopyAccount: true,
      );
      expect(user.copyToken, 'new-primary-copy');
      await user.copyAccount.logout();
      // Unclassified primary/profile saves do not opt in to COPY syncing.
      await user.saveLogin(
        token: 'new-primary-copy',
        userId: 'id',
        username: 'copy',
        nickname: 'refreshed',
        avatar: '',
      );
      expect(user.copyToken, isNull);
      await user.setLoginSource('hotmanga');
      await user.saveLogin(
        token: 'other-hot',
        userId: 'hot-id',
        username: 'hot',
        nickname: 'Hot',
        avatar: '',
      );
      expect(user.copyToken, isNull);
    },
  );

  test('primary logout does not clear independent COPY', () async {
    await user.copyAccount.saveSession(_copyA);
    await user.logout();
    expect(user.isLoggedIn, isFalse);
    expect(user.copyToken, _copyA.token);
  });

  test(
    'persistMigrations false performs no secure writes or legacy import',
    () async {
      final memory = _MemorySecureStore();
      SecureCredentialStore.setInstance(memory);
      SharedPreferences.setMockInitialValues({
        'login_source': 'copy',
        'user_token': 'legacy',
        'user_id': 'legacy-id',
        'user_username': 'legacy-user',
      });
      await user.init(persistMigrations: false);
      expect(memory.writes, 0);
      expect(await memory.readCopyAccountRecord(), isNull);
      expect(user.copyToken, isNull);
      await user.init();
      expect(user.copyToken, 'legacy');
      expect(memory.writes, 1);
      await user.init(persistMigrations: false);
      expect(user.copyToken, 'legacy');
      expect(memory.writes, 1);
    },
  );

  test('init read/write failures do not block primary or import HOT', () async {
    final before = _primarySnapshot(user);
    secure.failRead = true;
    await user.init();
    expect(_primarySnapshot(user), before);
    secure.failRead = false;
    // 场景：升级后 secure 存储整体写入失败（failing fresh store），但 legacy
    // prefs 键仍在——init 不得因迁移失败而丢主账号，prefs 也不得被删，
    // 下次 init 仍可重试迁移。
    final failedMigration = _MemorySecureStore()..failAllWrites = true;
    SecureCredentialStore.setInstance(failedMigration);
    SharedPreferences.setMockInitialValues({
      'user_token': 'hot-token',
      'user_username': 'same-username',
      'user_nickname': 'HOT name',
      'user_id': 'hot-id',
      'user_avatar': '',
      'login_source': 'hotmanga',
      'saved_username': 'same-username',
      'saved_password': 'hot-password',
      'saved_credentials': jsonEncode([
        {
          'username': 'same-username',
          'password': 'hot-password',
          'token': 'hot-token',
          'login_source': 'hotmanga',
        },
      ]),
    });
    await user.init();
    expect(_primarySnapshot(user), before);
    expect(user.copyToken, isNull);
    expect(await failedMigration.readCopyAccountRecord(), isNull);
    final prefs = await SharedPreferences.getInstance();
    // 迁移未成功完成，legacy 键必须保留供下次重试。
    expect(prefs.getString('saved_username'), 'same-username');
    expect(prefs.getString('saved_password'), 'hot-password');
    expect(prefs.getString('saved_credentials'), isNotNull);
  });

  test('primary COPY login rolls back when secure write fails', () async {
    secure.failWrite = true;
    await user.setLoginSource('copy');
    final before = _primarySnapshot(user);
    // 新语义：secure 写失败时回滚主账号并抛 CopyAccountStorageException，
    // 不允许在小说侧凭据缺失的情况下假报「双域登录成功」。
    await expectLater(
      user.saveLogin(
        token: 'primary-copy',
        userId: 'id',
        username: 'copy',
        nickname: '',
        avatar: '',
        syncCopyAccount: true,
      ),
      throwsA(isA<CopyAccountStorageException>()),
    );
    expect(_primarySnapshot(user), before);
    expect(user.copyToken, isNull);
  });

  test(
    'save/logout failures retain published account and sanitize errors',
    () async {
      await store.saveSession(_copyA);
      final before = await secure.readCopyAccountRecord();
      var notifications = 0;
      store.addListener(() => notifications++);
      secure.failWrite = true;
      await expectLater(
        store.saveSession(_copyB),
        throwsA(isA<CopyAccountStorageException>()),
      );
      await expectLater(
        store.logout(),
        throwsA(isA<CopyAccountStorageException>()),
      );
      expect(store.token, _copyA.token);
      expect(await secure.readCopyAccountRecord(), before);
      expect(notifications, 0);
      expect(
        const CopyAccountStorageException().toString(),
        isNot(contains('secret-token')),
      );
      secure.failWrite = false;
      await store.saveSession(_copyB);
      expect(store.token, _copyB.token);
      expect(notifications, 1);
    },
  );

  test('non-string and empty tokens are never accepted as sessions', () {
    for (final token in [null, '', ' ', 42, const <String, String>{}]) {
      expect(
        () => CopyAccountSession.fromJson({'token': token}),
        throwsFormatException,
      );
    }
  });

  test(
    'invalid session and corrupt record never overwrite existing data',
    () async {
      await store.saveSession(_copyA);
      final before = await secure.readCopyAccountRecord();
      expect(
        () => store.saveSession(const CopyAccountSession(token: ' ')),
        throwsFormatException,
      );
      expect(await secure.readCopyAccountRecord(), before);
      await secure.writeCopyAccountRecord('{broken-record');
      await store.init(legacySession: _copyB);
      expect(await secure.readCopyAccountRecord(), '{broken-record');
      expect(store.token, _copyA.token);
    },
  );

  test(
    'publish and facade forwarding happen only after successful persistence',
    () async {
      await user.copyAccount.saveSession(_copyA);
      final started = Completer<void>();
      final release = Completer<void>();
      secure.writeStarted = started;
      secure.releaseWrite = release;
      var notifications = 0;
      void onChange() => notifications++;
      user.addListener(onChange);
      addTearDown(() => user.removeListener(onChange));
      final pending = user.copyAccount.saveSession(_copyB);
      await started.future;
      expect(user.copyToken, _copyA.token);
      expect(notifications, 0);
      release.complete();
      expect(await pending, isTrue);
      expect(user.copyToken, _copyB.token);
      expect(notifications, 1);
    },
  );

  test(
    'old validation cannot resurrect COPY after independent logout',
    () async {
      await store.saveSession(_copyA);
      final validation = Completer<CopyAccountSession>();
      final pending = store.login(() => validation.future);
      await store.logout();
      validation.complete(_copyB);
      expect(await pending, isFalse);
      expect(store.token, isNull);
      final restarted = CopyAccountStore(secureStore: secure);
      addTearDown(restarted.dispose);
      await restarted.init(legacySession: _copyA);
      expect(restarted.token, isNull);
    },
  );

  test('newer successful login wins over older validation', () async {
    final older = Completer<CopyAccountSession>();
    final pending = store.login(() => older.future);
    await store.login(() async => _copyB);
    older.complete(_copyA);
    expect(await pending, isFalse);
    expect(store.token, _copyB.token);
  });

  test(
    'superseded in-flight write cannot survive a failed newer validation',
    () async {
      await store.saveSession(_copyA);
      final started = Completer<void>();
      final release = Completer<void>();
      secure.writeStarted = started;
      secure.releaseWrite = release;
      final pending = store.saveSession(_copyB);
      await started.future;
      await expectLater(
        store.login(() async => throw StateError('invalid')),
        throwsStateError,
      );
      release.complete();
      expect(await pending, isFalse);
      expect(store.token, _copyA.token);
      final restarted = CopyAccountStore(secureStore: secure);
      addTearDown(restarted.dispose);
      await restarted.init();
      expect(restarted.token, _copyA.token);
    },
  );

  test(
    'logout survives a failed newer login while an older write is pending',
    () async {
      await store.saveSession(_copyA);
      final started = Completer<void>();
      final release = Completer<void>();
      secure.writeStarted = started;
      secure.releaseWrite = release;
      final pending = store.saveSession(_copyB);
      await started.future;
      final logout = store.logout();
      await expectLater(
        store.login(() async => throw StateError('invalid')),
        throwsStateError,
      );
      release.complete();
      await pending;
      await logout;
      expect(store.token, isNull);
      final restarted = CopyAccountStore(secureStore: secure);
      addTearDown(restarted.dispose);
      await restarted.init();
      expect(restarted.token, isNull);
    },
  );

  testWidgets(
    'idle queue can reinitialize inside widget FakeAsync without runAsync',
    (tester) async {
      // setUp completed UserManager.init() in the outer test Zone. An idle tail
      // retained from there must not block this new widget-zone operation.
      await user.init();
      await user.copyAccount.saveSession(_copyA);
      expect(user.copyToken, _copyA.token);
      await user.copyAccount.logout();
      await user.init();
      expect(user.copyToken, isNull);
      expect(user.token, 'hot-token');
    },
  );

  test('deleteAll explicitly includes COPY account record', () async {
    await store.saveSession(_copyA);
    await secure.deleteAll();
    expect(await secure.readCopyAccountRecord(), isNull);
  });

  test(
    'multiple COPY accounts coexist and selection picks the active one',
    () async {
      await store.saveSession(_copyA);
      await store.saveSession(_copyB);
      expect(store.accounts.length, 2);
      expect(store.token, _copyB.token);
      expect(store.activeId, _copyB.id);

      expect(await store.selectAccount(_copyA.id), isTrue);
      expect(store.token, _copyA.token);
      // Selection survives a restart and never duplicates the list.
      await store.init();
      expect(store.token, _copyA.token);
      expect(store.accounts.length, 2);
    },
  );

  test(
    're-login of a known account updates it in place and keeps its label',
    () async {
      await store.saveSession(_copyA.copyWith(label: '主号'));
      await store.saveSession(_copyB);
      await store.saveSession(
        const CopyAccountSession(
          token: 'copy-a-refreshed',
          userId: 'copy-id',
          username: 'copy-user',
          nickname: 'COPY name',
        ),
      );
      expect(store.accounts.length, 2);
      expect(store.session?.token, 'copy-a-refreshed');
      expect(store.session?.label, '主号');
      expect(store.activeId, _copyA.id);
    },
  );

  test(
    'renameAccount only touches the note, never the token or identity',
    () async {
      await store.saveSession(_copyA);
      expect(await store.renameAccount(_copyA.id!, '小号'), isTrue);
      expect(store.session?.label, '小号');
      expect(store.session?.token, _copyA.token);
      await store.init();
      expect(store.session?.label, '小号');
      // Unknown ids are refused rather than silently created.
      expect(await store.renameAccount('u:missing', 'x'), isFalse);
      expect(store.accounts.length, 1);
    },
  );

  test(
    'selectAccount refuses unknown ids and never leaves a dangling pointer',
    () async {
      await store.saveSession(_copyA);
      expect(await store.selectAccount('u:missing'), isFalse);
      expect(store.token, _copyA.token);

      await store.removeAccount(_copyA.id!);
      expect(store.accounts, isEmpty);
      expect(store.token, isNull);
      // A removed identity cannot be reselected from a stale handle.
      expect(await store.selectAccount(_copyA.id), isFalse);
      await store.init();
      expect(store.accounts, isEmpty);
      expect(store.token, isNull);
    },
  );

  test(
    'removing the active account falls back to another stored account',
    () async {
      await store.saveSession(_copyA);
      await store.saveSession(_copyB);
      expect(store.token, _copyB.token);
      await store.removeAccount(_copyB.id!);
      expect(store.accounts.length, 1);
      expect(store.token, _copyA.token);
      // The fallback is persisted, not just in-memory.
      await store.init();
      expect(store.token, _copyA.token);
    },
  );

  test(
    'record without an explicit selection still resolves to an account',
    () async {
      await store.saveSession(_copyA);
      // Models a record written before `activeId` existed (or edited on disk).
      await secure.writeCopyAccountRecord(
        jsonEncode({
          'migrationHandled': true,
          'accounts': [_copyA.toJson()],
        }),
      );
      await store.init();
      expect(store.accounts, isNotEmpty);
      expect(store.token, _copyA.token);
    },
  );

  test(
    'upgrading from the single-session record keeps the logged-in account',
    () async {
      // The exact shape earlier builds wrote, including the hashed fallback id
      // for an account without a user_id.
      await secure.writeCopyAccountRecord(
        jsonEncode({
          'migrationHandled': true,
          'session': const CopyAccountSession(
            token: 'legacy-session',
            userId: 'legacy-id',
            username: 'legacy-user',
          ).toJson(),
        }),
      );
      await store.init();
      expect(store.token, 'legacy-session');
      expect(store.activeId, 'u:legacy-id');
      expect(store.accounts.length, 1);
    },
  );

  test('token-only login gets a durable, non-identity account id', () async {
    expect(
      await store.login(
        () async => const CopyAccountSession(token: 'anonymous-token'),
      ),
      isTrue,
    );
    final session = store.session!;
    expect(session.id, matches(r'^local:[0-9a-f]{32}$'));
    expect(session.accountId, session.id);
    expect(session.hasIdentity, isFalse);
    expect(session.userId, isEmpty);
    expect(session.username, isEmpty);
    expect(session.nickname, isEmpty);
    expect(store.isLoggedIn, isTrue);

    final restarted = CopyAccountStore(secureStore: secure);
    addTearDown(restarted.dispose);
    await restarted.init();
    expect(restarted.token, 'anonymous-token');
    expect(restarted.activeId, session.id);
    expect(restarted.session?.toJson(), session.toJson());
    expect(restarted.session?.hasIdentity, isFalse);
  });

  test('unresolved sessions do not share a null membership key', () {
    final first = CopyAccountSession.fromJson(const {'token': 'candidate'});
    final second = CopyAccountSession.fromJson(const {'token': 'candidate'});
    expect(first.id, isNull);
    expect(first.accountId, isNull);
    expect(first.hasIdentity, isFalse);
    expect(first, first);
    expect(first, isNot(second));
    expect({first, second}, hasLength(2));
    expect(CopyAccountSession.fromJson(first.toJson()).id, isNull);
  });

  test('pinned account id round-trips and overrides later identity', () {
    const original = CopyAccountSession(
      token: 'candidate',
      accountId: 'local:record',
      label: '备注',
    );
    final profiled = original.copyWith(
      userId: 'server-id',
      username: 'server-name',
      nickname: 'nickname',
      avatar: 'avatar',
    );
    expect(profiled.id, original.id);
    expect(profiled.hasIdentity, isTrue);
    expect(profiled.label, original.label);
    expect(
      CopyAccountSession.fromJson(profiled.toJson()).toJson(),
      profiled.toJson(),
    );
    expect(original.copyWith(label: '新备注').accountId, original.accountId);
    expect(
      original.copyWith(accountId: 'local:replacement').id,
      'local:replacement',
    );
  });

  test('same validated token reuses its handle and optional profile', () async {
    await store.saveSession(
      const CopyAccountSession(token: 'anonymous-token', label: '主号'),
    );
    final id = store.activeId;
    await store.saveSession(
      const CopyAccountSession(token: ' anonymous-token '),
    );
    expect(store.accounts, hasLength(1));
    expect(store.activeId, id);
    expect(store.session?.label, '主号');
    expect(store.session?.hasIdentity, isFalse);

    await store.saveSession(
      const CopyAccountSession(
        token: 'anonymous-token',
        userId: 'learned-id',
        username: 'learned-name',
        nickname: '昵称',
        avatar: 'avatar',
      ),
    );
    expect(store.activeId, id);
    expect(store.session?.hasIdentity, isTrue);
    await store.saveSession(const CopyAccountSession(token: 'anonymous-token'));
    expect(store.activeId, id);
    expect(store.session?.userId, 'learned-id');
    expect(store.session?.username, 'learned-name');
    expect(store.session?.nickname, '昵称');
    expect(store.session?.avatar, 'avatar');
    expect(store.session?.label, '主号');

    await store.saveSession(
      const CopyAccountSession(token: 'rotated-token', userId: 'learned-id'),
    );
    expect(store.accounts, hasLength(1));
    expect(store.activeId, id);
    expect(store.token, 'rotated-token');
    await store.init();
    expect(store.activeId, id);
    expect(store.token, 'rotated-token');
  });

  test(
    'different unknown tokens remain separately selectable and removable',
    () async {
      await store.saveSession(const CopyAccountSession(token: 'unknown-a'));
      final a = store.session!;
      await store.saveSession(const CopyAccountSession(token: 'unknown-b'));
      final b = store.session!;
      expect(a.id, isNot(b.id));
      expect(a, isNot(b));
      expect(store.accounts, hasLength(2));

      expect(await store.selectAccount(a.id), isTrue);
      await store.init();
      expect(store.token, a.token);
      expect(store.activeId, a.id);
      expect(store.accounts, hasLength(2));
      await store.removeAccount(a.id!);
      expect(store.token, b.token);
      expect(store.byId(a.id), isNull);
      expect(store.accounts, hasLength(1));
      await store.init();
      expect(store.activeId, b.id);
      await store.removeAccount(b.id!);
      expect(store.isLoggedIn, isFalse);
      await store.init(legacySession: a);
      expect(store.accounts, isEmpty);
    },
  );

  test(
    'pre-resolved handle is reused by save and existing COPY handle wins',
    () async {
      final resolved = store.resolveSession(
        const CopyAccountSession(token: 'candidate'),
      );
      expect(store.accounts, isEmpty);
      expect(store.isLoggedIn, isFalse);
      final writes = secure.writes;
      expect(resolved.id, startsWith('local:'));
      await store.saveSession(resolved);
      expect(store.activeId, resolved.id);
      expect(secure.writes, writes + 1);

      final restoredPrimary = store.resolveSession(
        const CopyAccountSession(
          token: 'candidate',
          accountId: 'local:primary',
        ),
      );
      expect(restoredPrimary.id, resolved.id);
      await store.saveSession(restoredPrimary);
      expect(store.accounts, hasLength(1));
      expect(store.activeId, resolved.id);

      await store.saveSession(
        CopyAccountSession(token: 'rotated', accountId: resolved.id),
      );
      expect(store.accounts, hasLength(1));
      expect(store.activeId, resolved.id);
      expect(store.token, 'rotated');
    },
  );

  test(
    'legacy username binding stays pinned when a server id arrives',
    () async {
      const legacy = CopyAccountSession(
        token: 'legacy-token',
        username: 'legacy-name',
      );
      await secure.writeCopyAccountRecord(
        jsonEncode({
          'migrationHandled': true,
          'activeId': legacy.id,
          'accounts': [legacy.toJson()],
        }),
      );
      await store.init();
      expect(store.session?.accountId, isNull);
      expect(store.activeId, legacy.id);
      await store.saveSession(
        const CopyAccountSession(
          token: 'new-token',
          username: 'legacy-name',
          userId: 'known-id',
        ),
      );
      expect(store.accounts, hasLength(1));
      expect(store.activeId, legacy.id);
      expect(store.session?.accountId, legacy.id);
      expect(store.session?.userId, 'known-id');
      await store.init();
      expect(store.activeId, legacy.id);
      await store.saveSession(
        const CopyAccountSession(token: 'another-token', userId: 'known-id'),
      );
      expect(store.accounts, hasLength(1));
      expect(store.activeId, legacy.id);
      expect(store.session?.username, 'legacy-name');
    },
  );

  test(
    'matching usernames cannot merge conflicting server identities',
    () async {
      await store.saveSession(
        const CopyAccountSession(
          token: 'a-token',
          userId: 'a-id',
          username: 'same',
        ),
      );
      await store.saveSession(
        const CopyAccountSession(
          token: 'b-token',
          userId: 'b-id',
          username: 'same',
        ),
      );
      expect(store.accounts, hasLength(2));
      expect(store.byId('u:a-id')?.token, 'a-token');
      expect(store.byId('u:b-id')?.token, 'b-token');
      await store.saveSession(
        const CopyAccountSession(
          token: 'a-new-token',
          userId: 'a-id',
          username: 'same',
        ),
      );
      expect(store.accounts, hasLength(2));
      expect(store.activeId, 'u:a-id');
      expect(store.byId('u:b-id')?.token, 'b-token');
    },
  );

  test(
    'legacy token-only import allocates and persists a handle once',
    () async {
      final freshSecure = _MemorySecureStore();
      final fresh = CopyAccountStore(secureStore: freshSecure);
      addTearDown(fresh.dispose);
      const legacy = CopyAccountSession(token: 'legacy-token-only');
      await fresh.init(legacySession: legacy);
      final id = fresh.activeId;
      expect(id, startsWith('local:'));
      expect(fresh.session?.hasIdentity, isFalse);
      final writes = freshSecure.writes;
      await fresh.init(legacySession: legacy);
      expect(fresh.activeId, id);
      expect(freshSecure.writes, writes);
    },
  );

  test('token-only write failure retains prior account and record', () async {
    await store.saveSession(_copyA);
    final before = await secure.readCopyAccountRecord();
    secure.failWrite = true;
    await expectLater(
      store.saveSession(const CopyAccountSession(token: 'new-unknown')),
      throwsA(isA<CopyAccountStorageException>()),
    );
    expect(store.accounts, hasLength(1));
    expect(store.activeId, _copyA.id);
    expect(await secure.readCopyAccountRecord(), before);
  });

  test('clear drops every COPY account and persists the tombstone', () async {
    await store.saveSession(_copyA);
    await store.saveSession(_copyB);
    await store.clear();
    expect(store.accounts, isEmpty);
    expect(store.token, isNull);
    expect(jsonDecode((await secure.readCopyAccountRecord())!), {
      'migrationHandled': true,
      'cleared': true,
      'activeId': null,
      'accounts': <Object?>[],
    });
    // 显式清空的 tombstone 不因 COPY 主账号重启而复活。
    final copyUser = UserManager();
    SharedPreferences.setMockInitialValues({
      'login_source': 'copy',
      'user_token': 'copy-primary',
      'user_id': 'copy-id',
      'user_username': 'copy-user',
    });
    await copyUser.init();
    expect(copyUser.copyAccount.accounts, isEmpty);
  });

  test('empty legacy record does not block COPY primary import', () async {
    // 旧版本/HOT 先初始化会留下「migrationHandled: true 但无账号」的记录。
    await secure.writeCopyAccountRecord(
      jsonEncode({
        'migrationHandled': true,
        'activeId': null,
        'accounts': const [],
      }),
    );
    final copyUser = UserManager();
    SharedPreferences.setMockInitialValues({
      'login_source': 'copy',
      'user_token': 'copy-primary',
      'user_id': 'copy-id',
      'user_username': 'copy-user',
    });
    await secure.writeToken('copy-primary');
    await copyUser.init();
    expect(copyUser.copyAccount.accounts, hasLength(1));
    expect(copyUser.copyToken, 'copy-primary');
    expect(
      jsonDecode((await secure.readCopyAccountRecord())!)['accounts'],
      hasLength(1),
    );
  });

  test(
    'syncSessionToken rotates the stored token without changing active',
    () async {
      await store.saveSession(_copyA);
      await store.saveSession(_copyB);
      expect(store.activeId, 'u:copy-b-id');
      final committed = <CopyAccountSession>[];
      final synced = await store.syncSessionToken(
        id: 'u:copy-id',
        session: const CopyAccountSession(
          token: 'copy-a-rotated',
          userId: 'copy-id',
          username: 'copy-user',
          nickname: '新昵称',
        ),
        onCommitted: committed.add,
      );
      expect(synced, isTrue);
      expect(committed.single.token, 'copy-a-rotated');
      expect(store.byId('u:copy-id')?.token, 'copy-a-rotated');
      expect(store.byId('u:copy-id')?.nickname, '新昵称');
      // 空字段不覆盖已有资料。
      expect(store.byId('u:copy-id')?.username, 'copy-user');
      // 非活动账号的同步不得改写选中的轻小说账号。
      expect(store.activeId, 'u:copy-b-id');
      await store.init();
      expect(store.byId('u:copy-id')?.token, 'copy-a-rotated');
    },
  );

  test('syncSessionToken refuses unknown ids and identity conflicts', () async {
    await store.saveSession(_copyA);
    expect(
      await store.syncSessionToken(
        id: 'u:missing',
        session: const CopyAccountSession(token: 'x'),
      ),
      isFalse,
    );
    expect(
      await store.syncSessionToken(
        id: 'u:copy-id',
        session: const CopyAccountSession(
          token: 'copy-a-rotated',
          userId: 'someone-else',
        ),
      ),
      isFalse,
    );
    expect(store.byId('u:copy-id')?.token, 'copy-a');
  });

  test(
    'superseded syncSessionToken leaves the stored record untouched',
    () async {
      await store.saveSession(_copyA);
      final before = await secure.readCopyAccountRecord();
      final revision = store.revision;
      final pending = store.syncSessionToken(
        id: 'u:copy-id',
        session: const CopyAccountSession(
          token: 'late-rotation',
          userId: 'copy-id',
        ),
      );
      // selectAccount 的 ++_revision 在调用瞬间推进，排队中的 sync 据此失效。
      await store.selectAccount('u:copy-id');
      expect(await pending, isFalse);
      expect(store.revision, isNot(revision));
      expect(await secure.readCopyAccountRecord(), before);
    },
  );
}

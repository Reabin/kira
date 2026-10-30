import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/copy_account_store.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_storage_test_support.dart';
import 'test_helpers.dart';

const _a = CopyAccountSession(
  token: 'fictional-token-a',
  accountId: 'local:a',
  userId: 'fictional-user',
  username: 'fictional-reader',
);
const _b = CopyAccountSession(
  token: 'fictional-token-b',
  accountId: 'local:b',
  userId: 'fictional-user',
  username: 'fictional-reader',
);
const _other = CopyAccountSession(
  token: 'fictional-other-token',
  accountId: 'local:other',
  userId: 'fictional-other-user',
  username: 'fictional-other-reader',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CopyAccountStore store;

  setUp(() {
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({});
    SecureCredentialStore.resetInstance();
    store = CopyAccountStore();
  });

  tearDown(() {
    store.dispose();
    teardownSecureCredentialStoreForTest();
  });

  Future<void> seed(
    List<CopyAccountSession> accounts, {
    String activeId = 'local:b',
    bool persistMigrations = true,
  }) async {
    await SecureCredentialStore().writeCopyAccountRecord(
      jsonEncode({
        'migrationHandled': true,
        'activeId': activeId,
        'accounts': accounts.map((account) => account.toJson()).toList(),
      }),
    );
    await store.init(persistMigrations: persistMigrations);
  }

  void expectAliases(String canonicalId) {
    expect(store.resolveAccountId(_a.id), canonicalId);
    expect(store.resolveAccountId(_b.id), canonicalId);
    expect(store.resolveAccountId(null), isNull);
    expect(store.resolveAccountId('local:unknown'), isNull);
    expect(store.resolveAccountId('guest'), isNull);
  }

  test(
    'historical account handles resolve after repeated cold starts',
    () async {
      await seed([_a, _other, _b]);
      final canonicalId = store.session!.id!;
      expect(store.accounts, hasLength(2));
      expectAliases(canonicalId);
      expect(store.resolveAccountId(_other.id), _other.id);
      for (var boot = 0; boot < 2; boot++) {
        store.dispose();
        SecureCredentialStore.resetInstance();
        store = CopyAccountStore();
        await store.init();
        expectAliases(canonicalId);
        expect(store.activeId, canonicalId);
        expect(store.resolveAccountId(_other.id), _other.id);
      }
    },
  );

  test('profile merge preserves the temporary handle for old tasks', () async {
    await seed([_a], activeId: _a.id!);
    expect(
      await store.saveSession(
        const CopyAccountSession(token: 'fictional-new-token'),
        select: false,
      ),
      isTrue,
    );
    final temporary = store.accounts.singleWhere((item) => !item.hasIdentity);
    expect(
      await store.updateProfile(
        id: temporary.id!,
        token: temporary.token,
        profile: {'username': _a.username, 'user_id': _a.userId},
        expectedRevision: store.revision,
      ),
      isTrue,
    );
    final canonicalId = store.accounts.single.id!;
    expect(store.resolveAccountId(_a.id), canonicalId);
    expect(store.resolveAccountId(temporary.id), canonicalId);
    expect(store.session?.token, temporary.token);
    store.dispose();
    store = CopyAccountStore();
    await store.init();
    expect(store.resolveAccountId(temporary.id), canonicalId);
    expect(store.resolveAccountId(_a.id), canonicalId);
  });

  test('token rotation keeps previously persisted account aliases', () async {
    await seed([_a, _b]);
    final canonicalId = store.session!.id!;
    await store.saveSession(_a.copyWith(token: 'fictional-rotated-token'));
    expectAliases(canonicalId);
    expect(store.accounts.single.token, 'fictional-rotated-token');
    store.dispose();
    store = CopyAccountStore();
    await store.init();
    expectAliases(canonicalId);
  });

  for (final clearAll in [false, true]) {
    test('removed account aliases cannot be reused: clear=$clearAll', () async {
      await seed([_a, _b, _other]);
      final canonicalId = store.session!.id!;
      if (clearAll) {
        await store.clear();
      } else {
        await store.removeAccount(canonicalId);
      }
      expect(store.resolveAccountId(_a.id), isNull);
      expect(store.resolveAccountId(_b.id), isNull);
      expect(store.resolveAccountId(_other.id), clearAll ? isNull : _other.id);
      store.dispose();
      store = CopyAccountStore();
      await store.init();
      expect(store.resolveAccountId(_a.id), isNull);
      expect(store.resolveAccountId(_b.id), isNull);
    });
  }

  test('another identity cannot reuse a retired account handle', () async {
    await seed([_a, _b]);
    final canonicalId = store.accounts.single.id!;
    final alias = [_a.id!, _b.id!].firstWhere((id) => id != canonicalId);
    await store.saveSession(_other.copyWith(accountId: alias), select: false);
    final other = store.accounts.singleWhere(
      (item) => item.username == _other.username,
    );
    expect(other.id, isNot(alias));
    expect(other.id, isNot(canonicalId));
    expect(store.resolveAccountId(alias), canonicalId);
    expect(store.resolveAccountId(other.id), other.id);
    store.dispose();
    store = CopyAccountStore();
    await store.init();
    expect(store.resolveAccountId(alias), canonicalId);
    expect(store.resolveAccountId(other.id), other.id);
  });

  test('failed profile merge does not publish alias redirects', () async {
    final secure = FailingAccountSecureStore();
    SecureCredentialStore.setInstance(secure);
    await seed([_a], activeId: _a.id!);
    await store.saveSession(
      const CopyAccountSession(token: 'fictional-new-token'),
      select: false,
    );
    final temporary = store.accounts.singleWhere((item) => !item.hasIdentity);
    final before = await secure.readCopyAccountRecord();
    var failed = false;
    secure.beforeWrite = (key, _) async {
      if (key == 'copy_account_v1' && !failed) {
        failed = true;
        throw StateError('Injected alias write failure');
      }
    };
    await expectLater(
      store.updateProfile(
        id: temporary.id!,
        token: temporary.token,
        profile: {'username': _a.username, 'user_id': _a.userId},
        expectedRevision: store.revision,
      ),
      throwsA(isA<CopyAccountStorageException>()),
    );
    expect(failed, isTrue);
    expect(store.accounts, hasLength(2));
    expect(store.resolveAccountId(_a.id), _a.id);
    expect(store.resolveAccountId(temporary.id), temporary.id);
    expect(await secure.readCopyAccountRecord(), before);
  });
}

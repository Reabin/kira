import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/backup/backup_preferences.dart';
import 'package:kira/models/copy_account_store.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/models/user_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account_storage_test_support.dart';

const _accountA = SavedCredential(
  username: 'account-a',
  password: 'password-a',
  token: 'token-a',
  loginSource: 'hotmanga',
  userId: 'id-a',
  nickname: 'name-a',
  avatar: 'avatar-a',
);
const _accountB = SavedCredential(
  username: 'account-b',
  password: 'password-b',
  token: 'token-b',
  loginSource: 'copy',
  userId: 'id-b',
  nickname: 'name-b',
  avatar: 'avatar-b',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final user = UserManager();
  late FailingAccountSecureStore secure;
  late AccountPreferencesPlatform platform;
  late SharedBackupPreferences backend;

  setUp(() async {
    platform = AccountPreferencesPlatform()..install();
    secure = FailingAccountSecureStore();
    SecureCredentialStore.setInstance(secure);
    backend = SharedBackupPreferences(secure: secure);
    user.resumeAccountMutationsAfterRestore();
    await user.init();
    await user.switchToCredential(_accountB);
    await user.switchToCredential(_accountA);
    await user.copyAccount.saveSession(
      const CopyAccountSession(token: 'novel-token', userId: 'novel-id'),
    );
  });

  tearDown(() {
    user.resumeAccountMutationsAfterRestore();
    platform.dispose();
    SecureCredentialStore.resetInstance();
  });

  test(
    'comic selection reuses transaction without switching novel account',
    () async {
      final copyRecord = await secure.readCopyAccountRecord();
      expect(
        await user.switchToCredential(_accountB.copyWith(password: '')),
        isTrue,
      );
      expect(user.token, 'token-b');
      expect(user.userId, 'id-b');
      expect(user.savedPassword, 'password-b');
      expect(user.savedCredentials.last.token, 'token-a');
      expect(user.copyToken, 'novel-token');
      expect(await secure.readCopyAccountRecord(), copyRecord);
      await user.init();
      expect(user.token, 'token-b');
      expect(user.userId, 'id-b');
      expect(user.copyToken, 'novel-token');
    },
  );

  for (final failure in ['secure-token', 'profile-false', 'profile-throw']) {
    test(
      '$failure after partial writes restores both backends and memory',
      () async {
        final before = await backend.readAll();
        final copyRecord = await secure.readCopyAccountRecord();
        var notifications = 0;
        void changed() => notifications++;
        user.addListener(changed);
        addTearDown(() => user.removeListener(changed));
        if (failure == 'secure-token') {
          secure.failKey = 'user_token';
          secure.failValue = 'token-b';
        } else {
          platform.failKey = 'user_nickname';
          platform.failValue = 'name-b';
          platform.throwOnFailure = failure == 'profile-throw';
        }
        await expectLater(
          user.switchToCredential(_accountB),
          throwsA(isA<CopyAccountStorageException>()),
        );
        expect(notifications, 0);
        expect(user.token, 'token-a');
        expect(user.userId, 'id-a');
        expect(user.savedPassword, 'password-a');
        expect(await backend.readAll(), before);
        expect(await secure.readCopyAccountRecord(), copyRecord);
        await (await SharedPreferences.getInstance()).reload();
        await user.init();
        expect(user.token, 'token-a');
        expect(user.userId, 'id-a');
        expect(user.nickname, 'name-a');
        expect(user.copyToken, 'novel-token');
      },
    );
  }

  test('backup snapshot waits for all account writes', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    secure.beforeWrite = (key, value) async {
      if (key == 'user_token' && value == 'token-b') {
        started.complete();
        await release.future;
      }
    };
    final switching = user.switchToCredential(_accountB);
    await started.future;
    var captured = false;
    final snapshot = backend.readAll().then((value) {
      captured = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(captured, isFalse);
    release.complete();
    expect(await switching, isTrue);
    final values = await snapshot;
    expect(values['user_token'], 'token-b');
    expect(values['user_id'], 'id-b');
  });

  test('newer comic selection wins while an older commit is blocked', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    secure.beforeWrite = (key, value) async {
      if (key == 'user_token' && value == 'token-b') {
        started.complete();
        await release.future;
      }
    };
    final older = user.switchToCredential(_accountB);
    await started.future;
    final newer = user.switchToCredential(_accountA);
    release.complete();
    expect(await older, isFalse);
    expect(await newer, isTrue);
    expect(await secure.readToken(), 'token-a');
    expect(user.userId, 'id-a');
    expect(user.copyToken, 'novel-token');
  });

  test('restore pause rejects new account writes until resumed', () async {
    await user.pauseAccountMutationsForRestore();
    await expectLater(
      user.switchToCredential(_accountB),
      throwsA(isA<CopyAccountStorageException>()),
    );
    expect(await secure.readToken(), 'token-a');
    user.resumeAccountMutationsAfterRestore();
    expect(await user.switchToCredential(_accountB), isTrue);
  });
}

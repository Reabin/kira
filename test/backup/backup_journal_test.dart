import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/backup/backup_journal.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/utils/settings_backup.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account_storage_test_support.dart';

import 'backup_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late InMemorySecureCredentialStore secrets;
  late EncryptedBackupJournal journal;
  final original = backupDocument(
    {
      'user_token': 'never-plaintext-on-disk',
      'saved_password': 'local-account-password',
    },
    categories: {BackupCategory.account},
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('kira_backup_journal_');
    secrets = InMemorySecureCredentialStore();
    journal = EncryptedBackupJournal(
      directory: () async => directory,
      secrets: secrets,
    );
  });

  tearDown(() async => directory.delete(recursive: true));

  for (final key in [
    'backup_rollback_key_v1',
    '${SecureCredentialStore.preferencePrefix}backup_rollback_key_v1',
  ]) {
    test(
      'startup recovery reads old $key before account init and after recreation',
      () async {
        final platform = AccountPreferencesPlatform()..install();
        SecureCredentialStore.resetInstance();
        addTearDown(() {
          SecureCredentialStore.resetInstance();
          platform.dispose();
        });
        final rawKey = base64Encode(List<int>.generate(32, (index) => index));
        // Simulate a journal written by the former backend with its mirrored key.
        await secrets.writeBackupRollbackKey(rawKey);
        await journal.save(original);
        await (await SharedPreferences.getInstance()).setString(key, rawKey);
        final before = Map.of(platform.values);

        // Neither constructing nor reading this journal may need UserManager.init
        // or a credential migration to locate the old key.
        final restartedJournal = EncryptedBackupJournal(
          directory: () async => directory,
        );
        expect((await restartedJournal.read())?.toJson(), original.toJson());
        expect(platform.values, before);
        SharedPreferences.resetStatic();
        SecureCredentialStore.resetInstance();
        final nextJournal = EncryptedBackupJournal(
          directory: () async => directory,
        );
        expect((await nextJournal.read())?.toJson(), original.toJson());
        final service = SettingsBackupService(
          journal: nextJournal,
          runtime: TestBackupRuntime(),
        );
        expect(await service.recoverPendingRestore(), isTrue);
        expect(await nextJournal.read(), isNull);
        SharedPreferences.resetStatic();
        SecureCredentialStore.resetInstance();
        expect(
          await SecureCredentialStore().readToken(),
          'never-plaintext-on-disk',
        );
        expect(
          await SecureCredentialStore().readPassword(),
          'local-account-password',
        );
        expect(await SecureCredentialStore().readBackupRollbackKey(), rawKey);
      },
    );
  }

  test(
    'new journal key persists in prefs across recreated store and journal',
    () async {
      final platform = AccountPreferencesPlatform()..install();
      SecureCredentialStore.resetInstance();
      addTearDown(() {
        SecureCredentialStore.resetInstance();
        platform.dispose();
      });
      final currentJournal = EncryptedBackupJournal(
        directory: () async => directory,
      );
      await currentJournal.save(original);
      final key = await SecureCredentialStore().readBackupRollbackKey();
      expect(key, isNotNull);
      SharedPreferences.resetStatic();
      SecureCredentialStore.resetInstance();
      expect(await SecureCredentialStore().readBackupRollbackKey(), key);
      final restarted = EncryptedBackupJournal(
        directory: () async => directory,
      );
      expect((await restarted.read())?.toJson(), original.toJson());
    },
  );

  test('encrypted journal roundtrip and atomic publish', () async {
    expect(await journal.read(), isNull);
    await journal.save(original);
    final pending = File('${directory.path}/backup-restore.pending');
    expect(await pending.exists(), isTrue);
    expect(await File('${pending.path}.tmp').exists(), isFalse);
    final bytes = await pending.readAsBytes();
    expect(
      String.fromCharCodes(bytes),
      isNot(contains('never-plaintext-on-disk')),
    );
    expect(await secrets.readBackupRollbackKey(), isNotNull);
    expect((await journal.read())?.toJson(), original.toJson());
    await journal.clear();
    expect(await journal.read(), isNull);
  });

  test('backup password changes do not affect rollback key', () async {
    await journal.save(original);
    await secrets.writeBackupPassword('totally-different-password');
    expect((await journal.read())?.toJson(), original.toJson());
  });

  test(
    'tampered and unavailable-key journals fail closed and remain present',
    () async {
      await journal.save(original);
      final file = File('${directory.path}/backup-restore.pending');
      final bytes = await file.readAsBytes();
      bytes[8] ^= 1;
      await file.writeAsBytes(bytes, flush: true);
      await expectLater(journal.read(), throwsA(isA<Exception>()));
      expect(await file.exists(), isTrue);
      await secrets.writeBackupRollbackKey(null);
      await expectLater(journal.read(), throwsA(isA<Exception>()));
      expect(await file.exists(), isTrue);
    },
  );

  test(
    'never overwrites a pending journal; unpublished temporary file is ignored',
    () async {
      await File(
        '${directory.path}/backup-restore.pending.tmp',
      ).writeAsString('partial');
      expect(await journal.read(), isNull);
      await journal.save(original);
      await expectLater(journal.save(original), throwsA(isA<Exception>()));
      expect((await journal.read())?.toJson(), original.toJson());
    },
  );
}

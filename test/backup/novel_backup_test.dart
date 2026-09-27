import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/backup/backup_category.dart';
import 'package:kira/backup/backup_document.dart';
import 'package:kira/backup/backup_error.dart';
import 'package:kira/backup/backup_validation.dart';
import 'package:kira/models/novel_reader_settings.dart';
import 'package:kira/models/novel_reading_progress.dart';
import 'package:kira/utils/novel_reading_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('novel progress belongs to reading history, not disposable cache', () {
    expect(
      BackupSchema.categoryOf('${NovelReadingStore.prefix}sample'),
      BackupCategory.readingHistory,
    );
    expect(BackupSchema.typeOf('${NovelReadingStore.prefix}sample'), 'string');
    expect(
      BackupSchema.categoryOf(NovelReaderSettings.storageKey),
      BackupCategory.settings,
    );
    expect(BackupSchema.typeOf(NovelReaderSettings.storageKey), 'string');
  });

  test(
    'novel business caches and secure sessions are not preference backups',
    () {
      for (final key in [
        'cache_novel_detail_v1',
        'novel_text_cache_v1',
        'copy_account_v1',
      ]) {
        expect(BackupSchema.categoryOf(key), isNull);
        expect(BackupSchema.typeOf(key), isNull);
      }
    },
  );

  test('backup validation accepts serialized reader data', () {
    final progress = NovelReadingProgress(
      pathWord: 'sample',
      name: '示例小说',
      cover: '',
      volumeId: 'vol-7',
      volumeName: '第七卷',
      chapterName: '第二章',
      entryIndex: 4,
      paragraphIndex: 17,
      paragraphAlignment: -0.35,
      updatedAt: DateTime.utc(2026, 9, 25),
    );
    expect(
      () => validateBackupRecords({
        '${NovelReadingStore.prefix}sample': BackupPreference.fromValue(
          jsonEncode(progress.toJson()),
        ),
        NovelReaderSettings.storageKey: BackupPreference.fromValue(
          jsonEncode(const NovelReaderSettings(fontSize: 24).toJson()),
        ),
      }),
      returnsNormally,
    );
  });

  test('backup validation rejects malformed novel record containers', () {
    for (final key in [
      '${NovelReadingStore.prefix}sample',
      NovelReaderSettings.storageKey,
    ]) {
      for (final value in ['[1, 2]', 'null', '{broken']) {
        expect(
          () => validateBackupRecords({key: BackupPreference.fromValue(value)}),
          throwsA(isA<SettingsBackupException>()),
        );
      }
    }
  });

  test(
    'restored settings and progress are visible without restarting',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = NovelReadingStore(prefs: Future.value(prefs));
      expect(await store.readProgress('sample'), isNull);
      await NovelReaderSettings.load(prefs: Future.value(prefs));
      final restored = NovelReadingProgress(
        pathWord: 'sample',
        name: '示例小说',
        cover: '',
        volumeId: 'vol-2',
        volumeName: '第二卷',
        chapterName: '第三章',
        paragraphIndex: 24,
        updatedAt: DateTime.utc(2026, 9, 25),
      );
      await prefs.setString(
        '${NovelReadingStore.prefix}sample',
        jsonEncode(restored.toJson()),
      );
      await prefs.setString(
        NovelReaderSettings.storageKey,
        jsonEncode(const NovelReaderSettings(fontSize: 28).toJson()),
      );
      expect((await store.readProgress('sample'))?.paragraphIndex, 24);
      expect(
        (await NovelReaderSettings.load(prefs: Future.value(prefs))).fontSize,
        28,
      );
    },
  );
}

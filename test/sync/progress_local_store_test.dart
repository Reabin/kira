import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/backup/backup_category.dart';
import 'package:kira/sync/progress_document.dart';
import 'package:kira/sync/progress_local_store.dart';
import 'package:kira/utils/novel_reading_store.dart';
import 'package:kira/utils/reading_history.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'progress_sync_service_test.dart' show comic;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await ReadingHistory.flush();
    ReadingHistory.beforeRead = null;
    NovelReadingStore.beforeRead = null;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    ReadingHistory.resumeAfterRestore();
    await ReadingHistory.flush();
  });

  test(
    'legacy default and group mirror form one identity across recreated stores',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('reading_history_book', jsonEncode(comic(4)));
      final snapshot = await SharedProgressLocalStore().snapshot();
      expect(snapshot.keys, ['reading_history_book_group_default']);
      final data = progressData(snapshot.keys.single, comic(8));
      expect(
        await SharedProgressLocalStore().apply(
          snapshot.keys.single,
          snapshot.values.single,
          data,
        ),
        isTrue,
      );
      expect((await ReadingHistory.get('book', group: 'default'))!.page, 8);
      expect((await ReadingHistory.get('book'))!.page, 8);
      expect(
        prefs.getString('reading_history_book'),
        prefs.getString('reading_history_book_group_default'),
      );
      expect((await SharedProgressLocalStore().snapshot()).length, 1);
    },
  );

  test(
    'pending page turn is flushed and prevents delayed remote overwrite',
    () async {
      await ReadingHistory.save(
        pathWord: 'book',
        chapterUuid: 'chapter',
        chapterName: 'chapter',
      );
      final snapshot = await SharedProgressLocalStore().snapshot();
      await ReadingHistory.save(
        pathWord: 'book',
        chapterUuid: 'chapter',
        chapterName: 'chapter',
        page: 9,
      );
      expect(
        await SharedProgressLocalStore().apply(
          snapshot.keys.single,
          snapshot.values.single,
          progressData(snapshot.keys.single, comic(2)),
        ),
        isFalse,
      );
      expect((await ReadingHistory.get('book'))!.page, 9);
    },
  );

  test(
    'novel restores semantic location, unions read marks and keeps local signed URLs',
    () async {
      final prefs = await SharedPreferences.getInstance();
      const key = 'novel_reading_history_novel';
      final existing = {
        'pathWord': 'novel',
        'volumeId': 'one',
        'updatedAt': '2026-11-01T00:00:00Z',
        'entryIndex': 0,
        'paragraphIndex': 0,
        'readVolumeIds': ['one'],
        'txtAddr': 'https://local/text?token=private',
        'cover': 'https://local/cover',
      };
      final raw = jsonEncode(existing);
      await prefs.setString(key, raw);
      final remote = progressData(key, {
        ...existing,
        'volumeId': 'two',
        'entryIndex': 5,
        'paragraphIndex': 7,
        'paragraphAlignment': -0.2,
        'readVolumeIds': ['two'],
        'updatedAt': '2099-01-01T00:00:00Z',
      });
      expect(await SharedProgressLocalStore().apply(key, raw, remote), isTrue);
      final stored = await NovelReadingStore().readProgress('novel');
      expect(stored!.volumeId, 'two');
      expect(stored.entryIndex, 5);
      expect(stored.paragraphIndex, 7);
      expect(stored.paragraphAlignment, -0.2);
      expect(stored.readVolumeIds, containsAll(['one', 'two']));
      expect(stored.txtAddr, existing['txtAddr']);
      expect(stored.updatedAt.isBefore(DateTime(2099)), isTrue);
    },
  );

  test('backup restore gate rejects synced comic writes', () async {
    await ReadingHistory.pauseForRestore();
    expect(
      await ReadingHistory.applySynced(
        'reading_history_book_group_default',
        null,
        jsonEncode(comic(2)),
      ),
      isFalse,
    );
  });

  test(
    'sync state and transport configuration are excluded from portable backup',
    () {
      for (final key in [
        'progress_sync_state_v1_example',
        'progress_sync_enabled',
        'progress_sync_backend',
        'kira.progress-folder.bookmark.v1',
      ]) {
        expect(BackupSchema.categoryOf(key), isNull);
      }
    },
  );
}

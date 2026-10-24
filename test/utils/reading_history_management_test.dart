import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/utils/reading_history.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _HistoryPreferences extends SharedPreferencesStorePlatform {
  _HistoryPreferences(Map<String, Object> initial) : values = {...initial};

  final Map<String, Object> values;
  Completer<void>? writeGate;
  final writeStarted = Completer<void>();
  bool failRemove = false;
  Object? removeError;

  @override
  Future<Map<String, Object>> getAll() async => {...values};

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await writeGate?.future;
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    final error = removeError;
    if (error != null) throw error;
    if (failRemove) return false;
    values.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    values.clear();
    return true;
  }
}

String _record({String chapter = 'chapter', String? group, String? time}) =>
    jsonEncode({
      'chapterUuid': chapter,
      'chapterName': chapter,
      'page': 4,
      'group': ?group,
      'updatedAt': ?time,
      'readChapterUuids': [chapter],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ReadingHistory.flush();
    ReadingHistory.resumeAfterRestore();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await ReadingHistory.flush();
    ReadingHistory.resumeAfterRestore();
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'recent deduplicates default mirrors and chooses the latest group',
    () async {
      SharedPreferences.setMockInitialValues({
        'reading_history_a': _record(
          group: 'default',
          time: '2026-10-21T00:00:00Z',
        ),
        'reading_history_a_group_default': _record(
          group: 'default',
          time: '2026-10-21T00:00:00Z',
        ),
        'reading_history_a_group_%E5%8D%95%E8%A1%8C%E6%9C%AC': _record(
          chapter: 'volume',
          time: '2026-10-23T00:00:00Z',
        ),
        'reading_history_b': _record(time: '2026-10-22T00:00:00Z'),
        'reading_history_d': _record(time: '2026-10-22T00:00:00Z'),
        'reading_history_c': _record(),
        'reading_history_a_group_invalid': _record(
          chapter: '',
          time: '2026-10-24T00:00:00Z',
        ),
      });

      final items = await ReadingHistory.readRecent();

      expect(items.map((item) => item.pathWord), ['a', 'b', 'd', 'c']);
      expect(items.first.record.chapterUuid, 'volume');
      expect(items.first.record.group, '单行本');
      expect((await ReadingHistory.latestForComic('a'))?.chapterUuid, 'volume');
      expect(await ReadingHistory.readRecent(limit: 2), hasLength(2));
      expect(await ReadingHistory.readRecent(limit: 0), isEmpty);
      expect(await ReadingHistory.readRecent(limit: -1), isEmpty);
    },
  );

  test(
    'recent skips malformed records and flushes pending positions',
    () async {
      SharedPreferences.setMockInitialValues({
        'reading_history_broken': '{',
        'reading_history_list': '[]',
        'reading_history_wrong-type': 1,
        'reading_history_empty': '{}',
      });
      await ReadingHistory.save(
        pathWord: 'fresh',
        group: 'default',
        chapterUuid: 'latest',
        chapterName: 'latest',
      );

      final items = await ReadingHistory.readRecent();

      expect(items, hasLength(1));
      expect(items.single.pathWord, 'fresh');
      expect(items.single.record.chapterUuid, 'latest');
      final latest = await ReadingHistory.latestRecord();
      expect(latest?.pathWord, items.single.pathWord);
      expect(latest?.record.chapterUuid, items.single.record.chapterUuid);
    },
  );

  test(
    'remove deletes all groups without touching another comic or other data',
    () async {
      SharedPreferences.setMockInitialValues({
        'reading_history_a': _record(),
        'reading_history_a_group_default': _record(group: 'default'),
        'reading_history_a_group_extra': _record(group: 'extra'),
        'reading_history_ab': _record(),
        'novel_reading_history_a': 'novel',
        'reader_bookmarks': 'bookmark',
        'download_queue_state_v1': 'download',
        'nav_browse_history_local': true,
      });
      await ReadingHistory.save(
        pathWord: 'a',
        group: 'pending',
        chapterUuid: 'new',
        chapterName: 'new',
      );

      await ReadingHistory.removeProgress('a');
      await ReadingHistory.flush();

      final prefs = await SharedPreferences.getInstance();
      expect(await ReadingHistory.latestForComic('a'), isNull);
      expect(
        prefs.getKeys().where(
          (key) => key.startsWith('reading_history_a_group_'),
        ),
        isEmpty,
      );
      expect(prefs.getString('reading_history_ab'), isNotNull);
      expect(prefs.getString('novel_reading_history_a'), 'novel');
      expect(prefs.getString('reader_bookmarks'), 'bookmark');
      expect(prefs.getString('download_queue_state_v1'), 'download');
      expect(prefs.getBool('nav_browse_history_local'), isTrue);
    },
  );

  test('clear removes pending and stored comic history only', () async {
    SharedPreferences.setMockInitialValues({
      'reading_history_a': _record(),
      'reading_history_b_group_extra': _record(),
      'novel_reading_history_a': 'novel',
      'nav_browse_history_local': true,
    });
    await ReadingHistory.save(
      pathWord: 'pending',
      chapterUuid: 'pending',
      chapterName: 'pending',
    );

    await ReadingHistory.clear();
    await ReadingHistory.flush();

    final prefs = await SharedPreferences.getInstance();
    expect(await ReadingHistory.readRecent(), isEmpty);
    expect(prefs.getString('novel_reading_history_a'), 'novel');
    expect(prefs.getBool('nav_browse_history_local'), isTrue);
  });

  test(
    'delete waits for an in-flight flush and cannot resurrect its position',
    () async {
      final backend = _HistoryPreferences({})..writeGate = Completer<void>();
      SharedPreferencesStorePlatform.instance = backend;
      await ReadingHistory.save(
        pathWord: 'a',
        group: 'default',
        chapterUuid: 'first',
        chapterName: 'first',
      );
      final writing = ReadingHistory.flush();
      await backend.writeStarted.future;
      final deleting = ReadingHistory.removeProgress('a');
      backend.writeGate!.complete();

      await Future.wait([writing, deleting]);
      await ReadingHistory.flush();

      expect(await ReadingHistory.get('a'), isNull);
      expect(
        backend.values.keys.where(
          (key) => key.startsWith('flutter.reading_history_'),
        ),
        isEmpty,
      );
    },
  );

  test('group names containing the key marker remain one comic', () async {
    await ReadingHistory.save(
      pathWord: 'a',
      group: 'extra_group_archive',
      chapterUuid: 'chapter',
      chapterName: 'chapter',
    );
    final items = await ReadingHistory.readRecent();
    expect(items.single.pathWord, 'a');
    expect(items.single.record.group, 'extra_group_archive');
    await ReadingHistory.removeProgress('a');
    expect(await ReadingHistory.readRecent(), isEmpty);
  });

  test('a position saved after deletion may create a new record', () async {
    final deleting = ReadingHistory.removeProgress('a');
    await ReadingHistory.save(
      pathWord: 'a',
      chapterUuid: 'new-read',
      chapterName: 'new-read',
    );
    await deleting;
    expect((await ReadingHistory.get('a'))?.chapterUuid, 'new-read');
  });

  test('remove failure propagates and the queue remains usable', () async {
    final raw = _record();
    final backend = _HistoryPreferences({'flutter.reading_history_a': raw})
      ..failRemove = true;
    SharedPreferencesStorePlatform.instance = backend;
    final changes = ReadingHistory.changes.value;

    await expectLater(ReadingHistory.removeProgress('a'), throwsStateError);
    expect(ReadingHistory.changes.value, changes);
    expect(backend.values['flutter.reading_history_a'], raw);
    expect((await ReadingHistory.get('a'))?.chapterUuid, 'chapter');
    backend.failRemove = false;
    await ReadingHistory.removeProgress('a');
    expect(await ReadingHistory.readRecent(), isEmpty);
  });

  test(
    'remove propagates the original exception rather than synthesizing one',
    () async {
      final original = StateError('backend deletion failed');
      final backend = _HistoryPreferences({
        'flutter.reading_history_a': _record(),
      })..removeError = original;
      SharedPreferencesStorePlatform.instance = backend;

      await expectLater(
        ReadingHistory.removeProgress('a'),
        throwsA(same(original)),
      );
    },
  );

  test(
    'restore pause still flushes existing progress and suppresses new saves',
    () async {
      await ReadingHistory.save(
        pathWord: 'a',
        chapterUuid: 'before',
        chapterName: 'before',
      );
      await ReadingHistory.pauseForRestore();
      await ReadingHistory.save(
        pathWord: 'a',
        chapterUuid: 'ignored',
        chapterName: 'ignored',
      );
      expect((await ReadingHistory.get('a'))?.chapterUuid, 'before');
      ReadingHistory.resumeAfterRestore();
      await ReadingHistory.save(
        pathWord: 'a',
        chapterUuid: 'after',
        chapterName: 'after',
      );
      expect((await ReadingHistory.get('a'))?.chapterUuid, 'after');
    },
  );
}

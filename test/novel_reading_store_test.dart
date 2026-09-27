import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/novel_reading_progress.dart';
import 'package:kira/utils/novel_reading_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late NovelReadingStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'reading_history_manga': 'manga history',
      'cache_novel_detail': 'cached detail',
      'reader_novel_settings_v1': 'reader settings',
    });
    prefs = await SharedPreferences.getInstance();
    store = NovelReadingStore(prefs: Future.value(prefs));
  });

  test('idle queue does not retain a completed FakeAsync zone', () {
    for (var index = 0; index < 3; index++) {
      fakeAsync((async) {
        final nextStore = NovelReadingStore(prefs: Future.value(prefs));
        var saved = false;
        var read = false;
        unawaited(
          nextStore
              .saveProgress(_progress().copyWith(paragraphIndex: index))
              .then((_) {
                saved = true;
              }),
        );
        unawaited(
          nextStore.readProgress('novel-a').then((progress) {
            expect(progress?.paragraphIndex, index);
            read = true;
          }),
        );
        async.flushMicrotasks();
        expect(saved, isTrue, reason: 'save in FakeAsync zone $index');
        expect(read, isTrue, reason: 'read in FakeAsync zone $index');
      });
    }
  });

  group('NovelReadingProgress', () {
    test(
      'JSON preserves raw entry index and negative paragraph leading edge',
      () {
        final progress = _progress().copyWith(
          entryIndex: 350,
          paragraphIndex: 120000,
          paragraphAlignment: -12.75,
          txtAddr: 'local-text-version-2',
        );
        final json = progress.toJson();
        final restored = NovelReadingProgress.fromJson(json);
        expect(restored.toJson(), json);
        expect(restored.entryIndex, 350);
        expect(restored.paragraphIndex, 120000);
        expect(restored.paragraphAlignment, -12.75);
        expect(restored.updatedAt, progress.updatedAt);
        expect(json.keys, isNot(contains('chapterUuid')));
        expect(json.keys, isNot(contains('volumeUuid')));
        expect(json.keys, isNot(contains('scrollOffset')));
      },
    );

    test('optional text version and positions have safe defaults', () {
      final json = _progress().toJson()
        ..remove('txtAddr')
        ..remove('entryIndex')
        ..remove('paragraphIndex')
        ..remove('paragraphAlignment')
        ..remove('progress');
      final restored = NovelReadingProgress.fromJson(json);
      expect(restored.txtAddr, '');
      expect(restored.entryIndex, 0);
      expect(restored.paragraphIndex, 0);
      expect(restored.paragraphAlignment, 0);
      expect(restored.progress, 0);
    });

    test('parses numeric strings and clamps out-of-range positions', () {
      final restored = NovelReadingProgress.fromJson({
        ..._progress().toJson(),
        'entryIndex': '-4',
        'paragraphIndex': '800000',
        'paragraphAlignment': '-3.25',
        'progress': '4.5',
      });
      expect(restored.entryIndex, 0);
      expect(restored.paragraphIndex, 800000);
      expect(restored.paragraphAlignment, -3.25);
      expect(restored.progress, 1);
    });

    test('constructors and JSON never retain non-finite position values', () {
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        final progress = _progress().copyWith(
          entryIndex: -1,
          paragraphIndex: -2,
          paragraphAlignment: value,
          progress: value,
        );
        expect(progress.entryIndex, 0);
        expect(progress.paragraphIndex, 0);
        expect(progress.paragraphAlignment, 0);
        expect(progress.progress, inInclusiveRange(0, 1));
        expect(() => jsonEncode(progress.toJson()), returnsNormally);
        final restored = NovelReadingProgress.fromJson({
          ..._progress().toJson(),
          'paragraphAlignment': value,
          'progress': value,
        });
        expect(restored.paragraphAlignment.isFinite, isTrue);
        expect(restored.progress, inInclusiveRange(0, 1));
      }
    });

    test('invalid identity or date is rejected rather than looking recent', () {
      for (final patch in <Map<String, dynamic>>[
        {'pathWord': ''},
        {'pathWord': <String, dynamic>{}},
        {'volumeId': ' '},
        {'volumeId': <dynamic>[]},
        {'updatedAt': null},
        {'updatedAt': 'not a timestamp'},
      ]) {
        expect(
          () => NovelReadingProgress.fromJson({
            ..._progress().toJson(),
            ...patch,
          }),
          throwsFormatException,
        );
      }
    });

    test('copyWith keeps metadata and does not modify its source', () {
      final original = _progress().copyWith(txtAddr: 'old-text');
      final changed = original.copyWith(
        volumeId: 'volume-2',
        volumeName: '第二卷',
        entryIndex: 45,
        chapterName: '第四章',
        paragraphIndex: 999,
        paragraphAlignment: -0.5,
        progress: 0.9,
        txtAddr: '',
      );
      expect(changed.name, original.name);
      expect(changed.cover, original.cover);
      expect(changed.volumeId, 'volume-2');
      expect(changed.entryIndex, 45);
      expect(changed.paragraphIndex, 999);
      expect(changed.txtAddr, '');
      expect(original.volumeId, 'volume-1');
      expect(original.txtAddr, 'old-text');
    });
  });

  test(
    'empty storage has no progress and default instances share MockPrefs',
    () async {
      expect(await store.readProgress('missing'), isNull);
      expect(await store.readRecent(), isEmpty);
      final progress = _progress();
      await NovelReadingStore().saveProgress(progress);
      final restored = await NovelReadingStore().readProgress(
        progress.pathWord,
      );
      // 存储层会把当前卷并入只增不减的已读卷集合，其余字段原样保留。
      expect(
        restored?.toJson(),
        progress
            .copyWith(readVolumeIds: {...progress.readVolumeIds, 'volume-1'})
            .toJson(),
      );
      expect(
        prefs.containsKey('${NovelReadingStore.prefix}${progress.pathWord}'),
        isTrue,
      );
      expect(
        prefs.containsKey('reading_history_${progress.pathWord}'),
        isFalse,
      );
    },
  );

  test(
    'older events cannot overwrite newer progress; equal timestamps use call order',
    () async {
      final older = _progress();
      final newer = older.copyWith(
        volumeId: 'volume-2',
        entryIndex: 40,
        updatedAt: older.updatedAt.add(const Duration(seconds: 1)),
      );
      await store.saveProgress(newer);
      await store.saveProgress(older);
      // 迟到的旧事件整体丢弃，不会把它的卷并进已读集合。
      expect(
        (await store.readProgress(older.pathWord))?.toJson(),
        newer.copyWith(readVolumeIds: {'volume-2'}).toJson(),
      );
      final sameTime = newer.copyWith(paragraphIndex: 30);
      await store.saveProgress(sameTime);
      final merged = await store.readProgress(older.pathWord);
      expect(merged?.paragraphIndex, 30);
      expect(merged?.readVolumeIds, {'volume-2'});
      await store.saveProgress(_progress(pathWord: 'other-book'));
      expect(
        (await store.readProgress('other-book'))?.updatedAt,
        older.updatedAt,
      );
    },
  );

  test(
    'recent records are newest first with a default 30-item limit',
    () async {
      final origin = _progress();
      for (var index = 0; index < 35; index++) {
        await store.saveProgress(
          origin.copyWith(
            pathWord: 'book-$index',
            updatedAt: origin.updatedAt.add(Duration(minutes: index)),
          ),
        );
      }
      final recent = await store.readRecent();
      expect(recent, hasLength(30));
      expect(recent.first.pathWord, 'book-34');
      expect(recent.last.pathWord, 'book-5');
      expect((await store.readRecent(limit: 2)).map((item) => item.pathWord), [
        'book-34',
        'book-33',
      ]);
      expect(await store.readRecent(limit: 0), isEmpty);
      expect(await store.readRecent(limit: -2), isEmpty);
      expect(await store.readRecent(limit: 100), hasLength(35));
      expect(() => recent.clear(), throwsUnsupportedError);
    },
  );

  test(
    'corrupt JSON and mismatched identities are skipped without hiding good records',
    () async {
      for (final entry in <String, String>{
        'broken': '{',
        'list': '[]',
        'null': 'null',
        'empty': '{}',
        'wrong-key': jsonEncode(_progress().toJson()),
        'bad-date': jsonEncode({
          ..._progress(pathWord: 'bad-date').toJson(),
          'updatedAt': 'broken',
        }),
      }.entries) {
        await prefs.setString(
          '${NovelReadingStore.prefix}${entry.key}',
          entry.value,
        );
        expect(await store.readProgress(entry.key), isNull);
      }
      await prefs.setInt('${NovelReadingStore.prefix}non-string', 7);
      expect(await store.readProgress('non-string'), isNull);
      final good = _progress();
      await store.saveProgress(good);
      expect((await store.readRecent()).map((item) => item.pathWord), [
        good.pathWord,
      ]);
      await store.saveProgress(_progress(pathWord: 'broken'));
      expect(await store.readProgress('broken'), isNotNull);
    },
  );

  test(
    'each read sees externally restored, changed, or removed prefs immediately',
    () async {
      final old = _progress();
      await store.saveProgress(old);
      expect(await store.readProgress(old.pathWord), isNotNull);
      final restored = old.copyWith(entryIndex: 345, paragraphAlignment: -2);
      final key = '${NovelReadingStore.prefix}${old.pathWord}';
      await prefs.setString(key, jsonEncode(restored.toJson()));
      expect(
        (await store.readProgress(old.pathWord))?.toJson(),
        restored.toJson(),
      );
      expect((await store.readRecent()).single.entryIndex, 345);
      await prefs.remove(key);
      expect(await store.readProgress(old.pathWord), isNull);
      expect(await store.readRecent(), isEmpty);
    },
  );

  test('remove and clear touch only novel reading history', () async {
    await store.saveProgress(_progress());
    await store.saveProgress(_progress(pathWord: 'book-b'));
    await store.removeProgress('novel-a');
    expect(await store.readProgress('novel-a'), isNull);
    expect(await store.readProgress('book-b'), isNotNull);
    await store.removeProgress('missing');
    await store.clear();
    expect(await store.readRecent(), isEmpty);
    expect(prefs.getKeys(), {
      'reading_history_manga',
      'cache_novel_detail',
      'reader_novel_settings_v1',
    });
  });

  test(
    'a slow write finishes before later save, read, remove, and clear',
    () async {
      final controlled = _ControlledPreferences(prefs);
      final gate = Completer<void>();
      controlled.writeGate = gate;
      store = NovelReadingStore(prefs: Future.value(controlled));
      final progress = _progress();
      final first = store.saveProgress(progress);
      await Future<void>.delayed(Duration.zero);
      expect(controlled.writes, 1);
      final second = store.saveProgress(progress.copyWith(paragraphIndex: 99));
      final reading = store.readProgress(progress.pathWord);
      final removing = store.removeProgress(progress.pathWord);
      final third = store.saveProgress(progress.copyWith(paragraphIndex: 100));
      final clearing = store.clear();
      final last = store.saveProgress(_progress(pathWord: 'last-book'));
      await Future<void>.delayed(Duration.zero);
      expect(controlled.writes, 1);
      gate.complete();
      await Future.wait([first, second, removing, third, clearing, last]);
      expect((await reading)?.paragraphIndex, 99);
      expect((await store.readRecent()).single.pathWord, 'last-book');
    },
  );

  test(
    'multiple instances preserve call order even when prefs resolve out of order',
    () async {
      final delayedPrefs = Completer<SharedPreferences>();
      final firstStore = NovelReadingStore(prefs: delayedPrefs.future);
      final secondStore = NovelReadingStore(prefs: Future.value(prefs));
      final progress = _progress();
      final first = firstStore.saveProgress(progress);
      final second = secondStore.saveProgress(
        progress.copyWith(paragraphIndex: 50),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        prefs.containsKey('${NovelReadingStore.prefix}${progress.pathWord}'),
        isFalse,
      );
      delayedPrefs.complete(prefs);
      await Future.wait([first, second]);
      expect((await store.readProgress(progress.pathWord))?.paragraphIndex, 50);
    },
  );

  test(
    'persistence failure reaches caller but does not poison the queue',
    () async {
      final controlled = _ControlledPreferences(prefs)..failNextWrite = true;
      store = NovelReadingStore(prefs: Future.value(controlled));
      await expectLater(store.saveProgress(_progress()), throwsStateError);
      await store.saveProgress(_progress().copyWith(paragraphIndex: 9));
      expect((await store.readProgress('novel-a'))?.paragraphIndex, 9);
    },
  );

  test(
    'saving invalid identities fails without creating unusable records',
    () async {
      await expectLater(
        store.saveProgress(_progress().copyWith(pathWord: ' ')),
        throwsArgumentError,
      );
      await expectLater(
        store.saveProgress(_progress().copyWith(volumeId: '')),
        throwsArgumentError,
      );
      expect(await store.readRecent(), isEmpty);
      await store.saveProgress(_progress());
      expect(await store.readRecent(), hasLength(1));
    },
  );

  test('read volume ids accumulate across saves and survive reload', () async {
    await store.saveProgress(_progress(volumeId: 'volume-1'));
    await store.saveProgress(
      _progress(
        volumeId: 'volume-2',
      ).copyWith(updatedAt: DateTime.utc(2026, 9, 25, 13)),
    );
    expect((await store.readProgress('novel-a'))?.readVolumeIds, {
      'volume-1',
      'volume-2',
    });
    // 重建 store（等价于应用重启）后再读，集合仍在持久化记录里。
    final reopened = NovelReadingStore(prefs: Future.value(prefs));
    expect((await reopened.readProgress('novel-a'))?.readVolumeIds, {
      'volume-1',
      'volume-2',
    });
  });
}

NovelReadingProgress _progress({
  String pathWord = 'novel-a',
  String volumeId = 'volume-1',
}) => NovelReadingProgress(
  pathWord: pathWord,
  name: '本地测试小说',
  cover: 'local-cover',
  volumeId: volumeId,
  volumeName: '第一卷',
  entryIndex: 8,
  chapterName: '第一章',
  paragraphIndex: 12,
  paragraphAlignment: -0.2,
  progress: 0.4,
  updatedAt: DateTime.utc(2026, 9, 25, 12),
);

/// 只给 MockPrefs 增加写入门闩/失败，不接触平台存储或网络。
class _ControlledPreferences implements SharedPreferences {
  _ControlledPreferences(this.delegate);

  final SharedPreferences delegate;
  Completer<void>? writeGate;
  bool failNextWrite = false;
  int writes = 0;

  @override
  Object? get(String key) => delegate.get(key);

  @override
  Set<String> getKeys() => delegate.getKeys();

  @override
  Future<bool> remove(String key) => delegate.remove(key);

  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    final gate = writeGate;
    writeGate = null;
    if (gate != null) await gate.future;
    if (failNextWrite) {
      failNextWrite = false;
      return false;
    }
    return delegate.setString(key, value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/novel_reading_progress.dart';
import 'package:kira/utils/novel_bookmark_store.dart';
import 'package:kira/utils/novel_reading_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late NovelBookmarkStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = NovelBookmarkStore.forTesting(prefs: Future.value(prefs));
  });

  tearDown(() async {
    await store.flush();
    store.dispose();
  });

  test('toggle persists exact anchors and excludes text URLs', () async {
    final progress = _position().copyWith(txtAddr: 'secret-signed-text-url');
    expect(await store.toggle(progress: progress), isTrue);
    expect(
      store.isBookmarked(
        pathWord: progress.pathWord,
        volumeId: progress.volumeId,
        entryIndex: 8,
        paragraphIndex: 12,
      ),
      isTrue,
    );
    final raw = prefs.getString(NovelBookmarkStore.storageKey)!;
    expect(raw, isNot(contains('txtAddr')));
    expect(raw, isNot(contains('secret-signed-text-url')));
    await store.reload();
    final bookmark = store.bookmarks.single;
    expect(bookmark.entryIndex, 8);
    expect(bookmark.paragraphIndex, 12);
    expect(bookmark.paragraphAlignment, -0.35);
    expect(bookmark.progress, 0.42);
    expect(bookmark.position.txtAddr, isEmpty);
    expect(() => store.bookmarks.clear(), throwsUnsupportedError);

    expect(
      await store.toggle(
        progress: progress.copyWith(paragraphAlignment: -0.351),
      ),
      isFalse,
    );
    expect(store.bookmarks, isEmpty);
  });

  test(
    'book, volume, original entry and paragraph all participate in identity',
    () async {
      final position = _position();
      for (final value in [
        position,
        position.copyWith(pathWord: 'other-book'),
        position.copyWith(volumeId: 'other-volume'),
        position.copyWith(entryIndex: 9),
        position.copyWith(paragraphIndex: 13),
      ]) {
        await store.toggle(progress: value);
      }
      expect(store.bookmarks, hasLength(5));
      expect(store.bookmarks.map((item) => item.id).toSet(), hasLength(5));
    },
  );

  test('concurrent initial loading does not hide existing bookmarks', () async {
    final existing = NovelBookmark(position: _position());
    await prefs.setString(
      NovelBookmarkStore.storageKey,
      jsonEncode([existing.toJson()]),
    );
    final delayed = Completer<SharedPreferences>();
    store.dispose();
    store = NovelBookmarkStore.forTesting(prefs: delayed.future);
    var loaded = false;
    final first = store.ensureLoaded();
    final second = store.ensureLoaded().then<void>((_) {
      loaded = true;
    });
    final toggle = store.toggle(
      progress: _position().copyWith(paragraphIndex: 99),
    );
    await Future<void>.delayed(Duration.zero);
    expect(loaded, isFalse);
    delayed.complete(prefs);
    await Future.wait<void>([first, second]);
    await toggle;
    expect(store.bookmarks, hasLength(2));
    expect(store.bookmarks.map((item) => item.paragraphIndex), contains(12));
  });

  test(
    'serialized writes publish only after persistence and retain call order',
    () async {
      final controlled = _ControlledPreferences(prefs);
      store.dispose();
      store = NovelBookmarkStore.forTesting(prefs: Future.value(controlled));
      final gate = Completer<void>();
      controlled.writeGate = gate;
      final first = store.toggle(progress: _position());
      await controlled.started.future;
      final second = store.toggle(
        progress: _position().copyWith(paragraphIndex: 99),
      );
      expect(store.bookmarks, isEmpty);
      expect(controlled.writes, 1);
      gate.complete();
      await Future.wait([first, second]);
      await store.reload();
      expect(controlled.writes, 2);
      expect(store.bookmarks, hasLength(2));
    },
  );

  test(
    'write failure is visible, retains memory, and does not poison queue',
    () async {
      final controlled = _ControlledPreferences(prefs)..failNextWrite = true;
      store.dispose();
      store = NovelBookmarkStore.forTesting(prefs: Future.value(controlled));
      var notifications = 0;
      store.addListener(() => notifications++);
      await expectLater(store.toggle(progress: _position()), throwsStateError);
      expect(store.bookmarks, isEmpty);
      expect(notifications, 0);
      expect(await store.toggle(progress: _position()), isTrue);
      expect(store.bookmarks, hasLength(1));
      expect(notifications, 1);
    },
  );

  test('single/group/all deletions support deduplicating undo', () async {
    await store.toggle(progress: _position());
    await store.toggle(progress: _position().copyWith(paragraphIndex: 40));
    await store.toggle(progress: _position().copyWith(pathWord: 'other'));
    final removed = await store.remove(store.bookmarks.first.id);
    expect(removed, isNotNull);
    expect(await store.remove('missing'), isNull);
    await store.restoreAll([removed!, removed]);
    expect(store.bookmarks, hasLength(3));
    final group = await store.removeForNovel('novel-a');
    expect(group, hasLength(2));
    expect(store.bookmarks.single.pathWord, 'other');
    await store.restoreAll(group);
    final all = await store.clear();
    expect(all, hasLength(3));
    expect(store.bookmarks, isEmpty);
    await store.restoreAll(all);
    await store.reload();
    expect(store.bookmarks, hasLength(3));
    expect(store.bookmarks.map((item) => item.id).toSet(), hasLength(3));
  });

  test(
    'undo does not overwrite a newer bookmark of the same paragraph',
    () async {
      await store.toggle(progress: _position());
      final removed = await store.clear();
      await store.toggle(
        progress: _position().copyWith(paragraphAlignment: -0.7),
      );
      await store.restoreAll(removed);
      expect(store.bookmarks.single.paragraphAlignment, -0.7);
    },
  );

  test(
    'normalization deduplicates and retains newest bounded bookmarks',
    () async {
      final bookmarks = [
        for (var index = 0; index <= NovelBookmarkStore.maxBookmarks; index++)
          NovelBookmark(
            position: _position().copyWith(
              paragraphIndex: index,
              updatedAt: DateTime.utc(2026).add(Duration(seconds: index)),
            ),
          ),
      ];
      await store.restoreAll([...bookmarks, bookmarks.last]);
      expect(store.bookmarks, hasLength(NovelBookmarkStore.maxBookmarks));
      expect(
        store.bookmarks.first.paragraphIndex,
        NovelBookmarkStore.maxBookmarks,
      );
      expect(store.bookmarks.last.paragraphIndex, 1);
    },
  );

  test(
    'malformed records are skipped individually, invalid indexes rejected',
    () async {
      final valid = NovelBookmark(position: _position()).toJson();
      await prefs.setString(
        NovelBookmarkStore.storageKey,
        jsonEncode([
          {'pathWord': 'broken'},
          null,
          {...valid, 'entryIndex': '8'},
          {...valid, 'paragraphIndex': -1},
          {...valid, 'progress': 7},
          valid,
          valid,
        ]),
      );
      await store.ensureLoaded();
      expect(store.bookmarks, hasLength(1));
      for (final raw in ['not-json', '{}', 'null']) {
        await prefs.setString(NovelBookmarkStore.storageKey, raw);
        await store.reload();
        expect(store.bookmarks, isEmpty);
      }
    },
  );

  test('history deletion never reads or deletes manual bookmarks', () async {
    final history = NovelReadingStore(prefs: Future.value(prefs));
    await history.saveProgress(_position());
    await store.toggle(progress: _position());
    expect(await history.readRecent(), hasLength(1));
    await history.clear();
    await store.reload();
    expect(await history.readRecent(), isEmpty);
    expect(store.bookmarks, hasLength(1));
  });

  test(
    'restore barrier drains active writes and rejects pending mutations',
    () async {
      final controlled = _ControlledPreferences(prefs);
      store.dispose();
      store = NovelBookmarkStore.forTesting(prefs: Future.value(controlled));
      final gate = Completer<void>();
      controlled.writeGate = gate;
      final active = store.toggle(progress: _position());
      await controlled.started.future;
      final pending = store.toggle(
        progress: _position().copyWith(paragraphIndex: 50),
      );
      final paused = store.pauseForRestore();
      gate.complete();
      await Future.wait([active, pending]);
      await paused;
      expect(store.bookmarks, hasLength(1));
      final restored = NovelBookmark(
        position: _position().copyWith(volumeId: 'restored-volume'),
      );
      await prefs.setString(
        NovelBookmarkStore.storageKey,
        jsonEncode([restored.toJson()]),
      );
      await store.reload();
      await store.clear();
      await store.restoreAll([NovelBookmark(position: _position())]);
      expect(store.bookmarks.single.volumeId, 'restored-volume');
      store.resumeAfterRestore();
      await store.toggle(progress: _position());
      expect(store.bookmarks, hasLength(2));
    },
  );

  test(
    'restore barrier also blocks a toggle waiting on initial prefs',
    () async {
      final delayed = Completer<SharedPreferences>();
      store.dispose();
      store = NovelBookmarkStore.forTesting(prefs: delayed.future);
      final oldToggle = store.toggle(progress: _position());
      final paused = store.pauseForRestore();
      delayed.complete(prefs);
      await oldToggle;
      await paused;
      expect(prefs.getString(NovelBookmarkStore.storageKey), isNull);
      store.resumeAfterRestore();
    },
  );
}

NovelReadingProgress _position() => NovelReadingProgress(
  pathWord: 'novel-a',
  name: '小说 A',
  cover: '',
  volumeId: 'volume-1',
  volumeName: '第一卷',
  entryIndex: 8,
  chapterName: '第二章',
  paragraphIndex: 12,
  paragraphAlignment: -0.35,
  progress: 0.42,
  updatedAt: DateTime.utc(2026, 9, 25),
);

class _ControlledPreferences implements SharedPreferences {
  _ControlledPreferences(this.delegate);

  final SharedPreferences delegate;
  final started = Completer<void>();
  Completer<void>? writeGate;
  bool failNextWrite = false;
  int writes = 0;

  @override
  Object? get(String key) => delegate.get(key);

  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    if (!started.isCompleted) started.complete();
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

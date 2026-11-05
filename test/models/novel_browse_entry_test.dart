import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/novel.dart';

void main() {
  test(
    'browse entry keeps saved chapter separate from the book latest one',
    () {
      final entry = NovelBrowseEntry.fromJson({
        'last_chapter_id': '4060',
        'last_chapter_name': '第01卷',
        'book': {
          'uuid': 'eae40b06-7c86-11ed-bf69-024352452ce0',
          'path_word': 'qingchunzhutou',
          'name': '青春豬頭少年',
          'last_chapter_id': '15109',
          'last_chapter_name': '第16卷',
        },
      });

      expect(entry.lastChapterId, '4060');
      expect(entry.lastChapterName, '第01卷');
      expect(entry.book.uuid, 'eae40b06-7c86-11ed-bf69-024352452ce0');
      expect(entry.book.lastChapterId, '15109');
      expect(entry.book.lastChapterName, '第16卷');
      expect(entry.hasUpdate, isTrue);
      expect(
        NovelBrowseEntry.fromJson(entry.toJson()).toJson(),
        entry.toJson(),
      );
    },
  );

  test('browse entry does not require an id/uuid of its own', () {
    final entry = NovelBrowseEntry.fromJson({
      'last_chapter_id': 7,
      'book': {
        'uuid': 'book-uuid',
        'path_word': 'book',
        'name': '书名',
        'last_chapter_id': 7,
      },
    });

    expect(entry.lastChapterId, '7');
    expect(entry.lastChapterName, isNull);
    // Same chapter means no update, not a missing record.
    expect(entry.hasUpdate, isFalse);
  });

  test('missing saved or latest chapter never reports a false update', () {
    final noSaved = NovelBrowseEntry.fromJson({
      'book': {'last_chapter_id': '9', 'path_word': 'book'},
    });
    expect(noSaved.lastChapterId, isNull);
    expect(noSaved.hasUpdate, isFalse);

    final noLatest = NovelBrowseEntry.fromJson({
      'last_chapter_id': '7',
      'book': {'path_word': 'book'},
    });
    expect(noLatest.book.lastChapterId, isNull);
    expect(noLatest.hasUpdate, isFalse);

    final missingBook = NovelBrowseEntry.fromJson({'last_chapter_id': ''});
    expect(missingBook.book.pathWord, '');
    expect(missingBook.lastChapterId, isNull);
  });

  test('browse page uses server total/offset and skips malformed entries', () {
    final page = NovelPage.fromJson({
      'list': [
        null,
        'malformed',
        {
          'last_chapter_id': '1',
          'last_chapter_name': '第1卷',
          'book': {'path_word': 'book', 'name': '书名'},
        },
      ],
      'total': 3,
      'limit': 1,
      'offset': 1,
    }, NovelBrowseEntry.fromJson);

    expect(page.list, hasLength(1));
    expect(page.list.single.book.pathWord, 'book');
    expect(page.total, 3);
    expect(page.limit, 1);
    expect(page.offset, 1);
    expect(page.hasMore, isTrue);
  });
}

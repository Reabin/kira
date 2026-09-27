import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/novel/novel_text.dart';
import 'package:kira/models/novel.dart';

NovelVolumeDetail _detail(List<NovelContentEntry> entries) => NovelVolumeDetail(
  book: const NovelBook(pathWord: 'book', name: '书名'),
  volume: NovelVolume(id: '7', name: '第七卷', contents: entries),
);

void main() {
  test(
    'book safely normalizes list/detail status and separate identifiers',
    () {
      final book = NovelBook.fromJson({
        'path_word': 'slug',
        'uuid': 'book-uuid',
        'name': '书名',
        'status': {'value': '1', 'display': '已完结'},
        'region': {'value': 0, 'display': '日本'},
        'author': [
          null,
          3,
          {'name': '作者', 'path_word': 'author'},
        ],
        'theme': 'malformed',
        'popular': '25',
        'last_chapter': {'id': 10, 'name': '第十卷'},
        'brief': '首行\r\n第二行',
      });
      expect(book.pathWord, 'slug');
      expect(book.uuid, 'book-uuid');
      expect(book.status, 1);
      expect(book.statusDisplay, '已完结');
      expect(book.authors.single.name, '作者');
      expect(book.themes, isEmpty);
      expect(book.lastChapterId, '10');
      expect(NovelBook.fromJson(book.toJson()).toJson(), book.toJson());
      expect(NovelBook.fromJson({'status': 1}).status, 1);
      expect(NovelBook.fromJson({'last_chapter_id': '9'}).lastChapterId, '9');
    },
  );

  test(
    'query preserves null collect, login/lock flags and non-VIP readability',
    () {
      final guest = NovelQuery.fromJson({
        'is_lock': true,
        'is_login': false,
        'is_vip': true,
        'collect': null,
        'browse': null,
      });
      expect(guest.collect, isNull);
      expect(guest.browse, isNull);
      expect(guest.isLocked, isTrue);
      final member = NovelQuery.fromJson({
        'is_lock': false,
        'is_login': true,
        'is_vip': false,
        'collect': 42,
        'browse': {'book_id': 'uuid', 'path_word': 'book', 'chapter_id': '7'},
      });
      expect(member.collect, 42);
      expect(member.isLocked, isFalse);
      expect(member.isVip, isFalse);
      expect(member.browse!.chapterId, '7');
      expect(NovelQuery.fromJson(member.toJson()).toJson(), member.toJson());
    },
  );

  test('volume directory preserves ID, sort, index and prev/next', () {
    final volume = NovelVolume.fromJson({
      'id': 7,
      'index': 6,
      'sort': 70,
      'count': 1,
      'name': '第七卷',
      'book_id': 'uuid',
      'book_path_word': 'book',
      'prev': '6',
      'next': null,
      'txt_addr': 'https://cdn.invalid/exact-name.txt',
      'txt_encoding': 'GBK',
      'contents': [
        {'name': '正文', 'content_type': 1, 'start_lines': 0, 'end_lines': 1},
        {
          'name': '插图',
          'content_type': 2,
          'content': 'https://cdn.invalid/a.png',
        },
      ],
    });
    expect(volume.id, '7');
    expect(volume.index, 6);
    expect(volume.sort, 70);
    expect(volume.prev, '6');
    expect(volume.next, isNull);
    expect(volume.contents.length, 2); // count is NOT contents length.
    expect(NovelVolume.fromJson(volume.toJson()).toJson(), volume.toJson());
  });

  test(
    'UTF8 decoding preserves BOM-free text, CRLF, spaces and empty lines',
    () {
      final text = NovelText.decode([
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('\r\n\r\n  章名  \r\n正文\r\n\r\n下一章\r\n'),
      ], 'UTF-8');
      expect(text.startsWith('\r\n\r\n'), isTrue);
      final content = NovelText.parse(
        _detail(const [
          NovelContentEntry(
            name: '第一章',
            contentType: 1,
            startLines: 2,
            endLines: 5,
          ),
          NovelContentEntry(
            name: '第二章',
            contentType: 1,
            startLines: 5,
            endLines: 7,
          ),
        ]),
        text,
      );
      expect(content.entries[0].paragraphs, ['  章名  ', '正文', '']);
      expect(content.entries[1].paragraphs, ['下一章', '']);
    },
  );

  test('known GBK bytes decode without trusting UTF8 Content-Type', () {
    const bytes = [0xd6, 0xd0, 0xce, 0xc4, 13, 10, 13, 10, 65];
    final text = NovelText.decode(bytes, 'GBK');
    expect(text, '中文\r\n\r\nA');
    expect(NovelText.decode(bytes, 'gb2312'), text);
    expect(() => NovelText.decode(bytes, 'utf-8'), throwsFormatException);
    expect(() => NovelText.decode([0x81], 'GBK'), throwsFormatException);
    expect(() => NovelText.decode(bytes, 'unknown'), throwsFormatException);
  });

  test(
    'zero-based half-open ranges retain blank lines and independent images',
    () {
      final content = NovelText.parse(
        _detail(const [
          NovelContentEntry(name: '第一章', contentType: 1, endLines: 3),
          NovelContentEntry(
            name: '插图',
            contentType: 2,
            content: 'https://cdn.invalid/image.png',
            startLines: 999,
            endLines: 1000,
          ),
          NovelContentEntry(
            name: '第二章',
            contentType: 1,
            startLines: 3,
            endLines: 5,
          ),
        ]),
        '\nA\n\nB\n',
      );
      expect(content.entries.map((e) => e.entryIndex), [0, 1, 2]);
      expect(content.entries[0].paragraphs, ['', 'A', '']);
      expect(content.entries[1].isImage, isTrue);
      expect(content.entries[1].paragraphs, isEmpty);
      expect(content.entries[1].imageUrl, 'https://cdn.invalid/image.png');
      expect(content.entries[2].paragraphs, ['B', '']);
    },
  );

  test(
    'invalid text ranges fail explicitly instead of clamping or losing text',
    () {
      for (final range in [(-1, 1), (2, 1), (0, 4)]) {
        expect(
          () => NovelText.parse(
            _detail([
              NovelContentEntry(
                name: '错误',
                contentType: 1,
                startLines: range.$1,
                endLines: range.$2,
              ),
            ]),
            'A\nB',
          ),
          throwsFormatException,
        );
      }
      final empty = NovelText.parse(
        _detail(const [
          NovelContentEntry(
            name: '空章',
            contentType: 1,
            startLines: 1,
            endLines: 1,
          ),
        ]),
        'A\nB',
      );
      expect(empty.entries.single.paragraphs, isEmpty);
    },
  );

  test('unknown directory entries do not shift following reading indices', () {
    final volume = NovelVolume.fromJson({
      'contents': [
        null,
        {'name': '章节', 'content_type': 1, 'start_lines': 0, 'end_lines': 1},
      ],
    });
    final content = NovelText.parse(
      NovelVolumeDetail(
        book: const NovelBook(pathWord: 'book', name: '书名'),
        volume: volume,
      ),
      '正文',
    );
    expect(content.entries.length, 2);
    expect(content.entries[1].entryIndex, 1);
    expect(content.entries[1].paragraphs, ['正文']);
  });

  test('shelf and comment IDs/nullable fields are preserved', () {
    final shelf = NovelShelfEntry.fromJson({
      'uuid': 43,
      'book': {'uuid': 'book-uuid', 'path_word': 'book', 'name': '书名'},
      'last_browse': {'last_browse_id': '7', 'last_browse_name': '第七卷'},
    });
    expect(shelf.uuid, 43);
    expect(shelf.book.uuid, 'book-uuid');
    expect(shelf.lastBrowseId, '7');
    expect(NovelShelfEntry.fromJson(shelf.toJson()).toJson(), shelf.toJson());
    final comment = NovelComment.fromJson({
      'id': 9,
      'parent_id': 3,
      'comment': '回复',
      'count': '2',
    });
    expect(comment.id, '9');
    expect(comment.parentId, '3');
    expect(comment.count, 2);
    expect(comment.parentUserId, isNull);
    expect(NovelComment.fromJson(comment.toJson()).toJson(), comment.toJson());
  });

  test('pagination uses server total and offset, stops on empty pages', () {
    final page = NovelPage.fromJson({
      'list': [
        {'name': 'x'},
      ],
      'total': 20,
      'limit': 18,
      'offset': 18,
    }, NovelBook.fromJson);
    expect(page.hasMore, isTrue);
    expect(
      const NovelPage<NovelBook>(
        list: [],
        total: 100,
        limit: 18,
        offset: 18,
      ).hasMore,
      isFalse,
    );
  });
}

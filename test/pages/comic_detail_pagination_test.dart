import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/api_client.dart';
import 'package:kira/api/manga/manga_api.dart';
import 'package:kira/models/chapter.dart';
import 'package:kira/models/comic.dart' hide Theme;
import 'package:kira/models/reader_settings.dart';
import 'package:kira/pages/comic_detail_page.dart';
import 'package:kira/utils/bookmark_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

class _Api extends Fake implements ApiClient {
  _Api(this.manga);
  @override
  final MangaApi manga;
}

class _Manga extends Fake implements MangaApi {
  _Manga({this.knownTotal = 230});
  final int knownTotal;
  final offsets = <int>[];
  Completer<void>? pending;

  @override
  Future<Comic> getComicDetail(
    String pathWord, {
    bool forceRefresh = false,
  }) async => Comic(
    name: '测试漫画',
    pathWord: pathWord,
    cover: '',
    groups: {
      'default': ComicGroup(pathWord: 'default', count: knownTotal, name: '章节'),
    },
  );
  @override
  Future<Map<String, dynamic>> getComicQuery(String pathWord) async => {};
  @override
  Future<({List<Chapter> list, int total})> getChapterList(
    String pathWord, {
    String group = 'default',
    int limit = 100,
    int offset = 0,
  }) async {
    offsets.add(offset);
    if (offset == 0 && pending != null) await pending!.future;
    return (
      list: List.generate(
        (230 - offset).clamp(0, limit),
        (i) => Chapter(
          uuid: 'chapter-${offset + i + 1}',
          index: offset + i,
          name: '第${offset + i + 1}话',
        ),
      ),
      total: 230,
    );
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ApiClient original;
  late Directory folder;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  setUpAll(() async {
    folder = await Directory.systemTemp.createTemp('kira-catalogue-tests-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => folder.path);
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await folder.delete(recursive: true);
  });
  setUp(() {
    original = ApiClient();
    setupSecureCredentialStoreForTest();
    BookmarkStore().debugReset();
  });
  tearDown(() {
    ApiClient.setTestInstance(original);
    BookmarkStore().debugReset();
    teardownSecureCredentialStoreForTest();
  });

  for (final knownTotal in [230, 0, 100]) {
    testWidgets(
      'saved reverse order requests latest batch (known total $knownTotal)',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'comic_chapter_reversed': true,
        });
        final settings = ReaderSettings()..resetPrefsCache();
        await settings.initFromPrefs(await SharedPreferences.getInstance());
        final manga = _Manga(knownTotal: knownTotal);
        ApiClient.setTestInstance(_Api(manga));
        await tester.pumpWidget(
          wrapWithApp(
            const ComicDetailPage(pathWord: 'catalogue'),
            wrapInScaffold: false,
          ),
        );
        await _settle(tester);
        expect(manga.offsets.last, 200);
        if (knownTotal == 230) expect(manga.offsets, [200]);
        await tester.scrollUntilVisible(
          find.byType(ChapterCard).first,
          250,
          scrollable: find.byType(Scrollable).last,
        );
        final cards = tester
            .widgetList<ChapterCard>(find.byType(ChapterCard))
            .toList();
        expect(cards.first.name, '第230话');
        if (knownTotal == 230) {
          await tester.ensureVisible(find.widgetWithText(FilledButton, '2'));
          await tester.tap(find.widgetWithText(FilledButton, '2'));
          await _settle(tester);
          expect(manga.offsets.last, 100);
        }

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 11));
        await _settle(tester);
      },
    );
  }

  testWidgets(
    'toggling order loads first page of the newly selected ordering',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = ReaderSettings()..resetPrefsCache();
      await settings.initFromPrefs(await SharedPreferences.getInstance());
      final manga = _Manga();
      ApiClient.setTestInstance(_Api(manga));
      await tester.pumpWidget(
        wrapWithApp(
          const ComicDetailPage(pathWord: 'catalogue'),
          wrapInScaffold: false,
        ),
      );
      await _settle(tester);
      expect(manga.offsets, [0]);
      await tester.ensureVisible(find.byIcon(Icons.arrow_upward));
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await _settle(tester);
      expect(manga.offsets.last, 200);
      expect(settings.chapterReversed, isTrue);
      await tester.ensureVisible(find.byIcon(Icons.arrow_downward));
      await tester.tap(find.byIcon(Icons.arrow_downward));
      await _settle(tester);
      expect(settings.chapterReversed, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
      await _settle(tester);
    },
  );
  testWidgets(
    'changing sort while a chapter request is pending reloads the newest batch',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = ReaderSettings()..resetPrefsCache();
      await settings.initFromPrefs(await SharedPreferences.getInstance());
      final manga = _Manga()..pending = Completer<void>();
      ApiClient.setTestInstance(_Api(manga));
      await tester.pumpWidget(
        wrapWithApp(
          const ComicDetailPage(pathWord: 'catalogue'),
          wrapInScaffold: false,
        ),
      );
      for (var i = 0; i < 10 && manga.offsets.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(manga.offsets, [0]);
      await settings.setChapterReversed(true);
      manga.pending!.complete();
      await _settle(tester);
      expect(manga.offsets, [0, 200]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
      await _settle(tester);
    },
  );
}

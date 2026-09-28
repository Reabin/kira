import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kira/api/novel/novel_api.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/models/novel_reader_settings.dart';
import 'package:kira/models/novel_reading_progress.dart';
import 'package:kira/models/reader_settings.dart';
import 'package:kira/pages/novel_reader/novel_reader_document.dart';
import 'package:kira/pages/novel_reader/novel_reader_viewport.dart';
import 'package:kira/pages/novel_reader_page.dart';
import 'package:kira/providers/novel_providers.dart';
import 'package:kira/repositories/novel_repository.dart';
import 'package:kira/theme/app_icon_sizes.dart';
import 'package:kira/theme/novel_reader_theme.dart';
import 'package:kira/theme/reader_chrome.dart';
import 'package:kira/utils/novel_bookmark_store.dart';
import 'package:kira/utils/novel_reading_store.dart';
import 'package:kira/widgets/app_sheet.dart';
import 'package:kira/widgets/error_retry_view.dart';
import 'package:kira/widgets/reader_status_overlay.dart';
import 'package:kira/widgets/select_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api implements NovelApi {
  @override
  bool get hasCopyToken => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected API access: ${invocation.memberName}');
}

class _Repository implements NovelRepository {
  _Repository(this.content);

  final Map<String, NovelVolumeContent> content;
  final calls = <String>[];
  final pending = <String, Completer<NovelVolumeContent>>{};
  final errors = <String, Object>{};
  final cached = <String, NovelVolumeContent>{};
  final detailPending = <String, Completer<NovelVolumeDetail>>{};

  @override
  Future<NovelVolumeContent> loadVolumeContent(
    String pathWord,
    String volumeId, {
    bool refresh = false,
  }) async {
    calls.add('$pathWord/$volumeId/$refresh');
    if (errors[volumeId] case final error?) throw error;
    if (pending[volumeId] case final completer?) return completer.future;
    return content[volumeId]!;
  }

  @override
  Future<NovelVolumeContent?> getCachedVolumeContent(
    String pathWord,
    String volumeId,
  ) async {
    calls.add('cache/$pathWord/$volumeId');
    return cached[volumeId];
  }

  @override
  Future<List<NovelVolume>> loadVolumes(
    String pathWord, {
    bool refresh = false,
  }) async => content.values
      .where((item) => item.detail.book.pathWord == pathWord)
      .map((item) => item.detail.volume)
      .toList();

  @override
  Future<NovelVolumeDetail> loadVolumeDetail(
    String pathWord,
    String volumeId, {
    bool refresh = false,
  }) async {
    if (detailPending[volumeId] case final completer?) return completer.future;
    return content[volumeId]!.detail;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected repository access: ${invocation.memberName}',
  );
}

class _Store implements NovelReadingStore {
  _Store(this.preferences);

  final SharedPreferences preferences;
  final writes = <NovelReadingProgress>[];
  Completer<NovelReadingProgress?>? pendingRead;
  int failures = 0;

  @override
  Future<NovelReadingProgress?> readProgress(String pathWord) async {
    if (pendingRead != null) return pendingRead!.future;
    final raw = preferences.getString('test_novel_progress_$pathWord');
    if (raw == null) return null;
    final json = jsonDecode(raw);
    return json is Map<String, dynamic>
        ? NovelReadingProgress.fromJson(json)
        : null;
  }

  @override
  Future<void> saveProgress(NovelReadingProgress progress) async {
    writes.add(progress);
    if (failures > 0) {
      --failures;
      throw StateError('Simulated preference write failure');
    }
    await preferences.setString(
      'test_novel_progress_${progress.pathWord}',
      jsonEncode(progress.toJson()),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected reading store access: ${invocation.memberName}',
  );
}

NovelVolumeContent _volume({
  String book = 'book',
  String id = 'v1',
  int entries = 3,
  int paragraphs = 100,
  bool locked = false,
  String? previous,
  String? next,
  bool image = false,
  bool longParagraph = false,
  Set<int> blanks = const {},
}) {
  final parsed = <NovelReaderEntry>[
    for (var entry = 0; entry < entries; entry++)
      NovelReaderEntry(
        entryIndex: entry,
        entry: NovelContentEntry(
          name: '$id chapter $entry',
          contentType: image && entry == 1 ? 2 : 1,
          content: image && entry == 1
              ? 'https://images.invalid/illustration.png'
              : null,
        ),
        paragraphs: image && entry == 1
            ? []
            : [
                for (var paragraph = 0; paragraph < paragraphs; paragraph++)
                  if (blanks.contains(paragraph))
                    ''
                  else if (longParagraph)
                    List.filled(
                      80,
                      '$id.$entry.$paragraph long paragraph',
                    ).join(' ')
                  else
                    '$id entry $entry paragraph $paragraph',
              ],
      ),
  ];
  return NovelVolumeContent(
    detail: NovelVolumeDetail(
      book: NovelBook(pathWord: book, name: '$book title'),
      volume: NovelVolume(
        id: id,
        name: '$id volume',
        bookPathWord: book,
        prev: previous,
        next: next,
        contents: parsed.map((item) => item.entry).toList(),
      ),
      isLocked: locked,
    ),
    entries: parsed,
  );
}

NovelReadingProgress _progress({
  String book = 'book',
  String volume = 'v1',
  int entry = 1,
  int paragraph = 40,
  double alignment = -0.04,
}) => NovelReadingProgress(
  pathWord: book,
  name: '$book title',
  cover: '',
  volumeId: volume,
  volumeName: '$volume volume',
  chapterName: '$volume chapter $entry',
  updatedAt: DateTime(2025),
  entryIndex: entry,
  paragraphIndex: paragraph,
  paragraphAlignment: alignment,
);

late NovelBookmarkStore _bookmarks;

Future<void> _mount(
  WidgetTester tester,
  _Repository repository,
  NovelReadingStore store, {
  String book = 'book',
  String volume = 'v1',
  bool resume = false,
  int initialEntry = 0,
  int initialParagraph = 0,
  double initialAlignment = 0,
  bool settle = true,
  EdgeInsets padding = EdgeInsets.zero,
  double textScale = 1,
  bool highlightOnEntry = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        novelRepositoryProvider.overrideWithValue(repository),
        novelReadingStoreProvider.overrideWithValue(store),
        novelBookmarkStoreProvider.overrideWithValue(_bookmarks),
        novelApiProvider.overrideWithValue(_Api()),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: padding,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NovelReaderPage(
          pathWord: book,
          volumeId: volume,
          resume: resume,
          initialEntryIndex: initialEntry,
          initialParagraphIndex: initialParagraph,
          initialParagraphAlignment: initialAlignment,
          highlightOnEntry: highlightOnEntry,
        ),
      ),
    ),
  );
  if (settle) await _settle(tester);
}

// SharedPreferences' singleton/serial queues are created outside fakeAsync.
// Yield real microtasks for this local mock backend, while pumping layout and
// debounce timers exclusively on the widget test's virtual clock.
Future<void> _seed(
  WidgetTester tester,
  NovelReadingStore store,
  NovelReadingProgress progress,
) async {
  await tester.runAsync(() => store.saveProgress(progress));
}

Future<NovelReadingProgress?> _read(
  WidgetTester tester,
  NovelReadingStore store,
  String book,
) => tester.runAsync<NovelReadingProgress?>(() => store.readProgress(book));

Future<NovelReaderSettings> _readSettings(WidgetTester tester) async =>
    (await tester.runAsync(NovelReaderSettings.load))!;

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle(
    const Duration(milliseconds: 20),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 3),
  );
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await _settle(tester);
}

NovelReaderLocation _location(WidgetTester tester) => tester
    .state<NovelReaderViewportState>(find.byType(NovelReaderViewport))
    .currentLocation!;

/// 段落闪光高亮的正文色描边（DecoratedBox，无布局影响）。
/// 不传颜色时匹配任意描边高亮。
Finder highlightBand([Color? color]) => find.byWidgetPredicate((widget) {
  if (widget is! DecoratedBox) return false;
  final decoration = widget.decoration;
  if (decoration is! BoxDecoration || decoration.border is! Border) {
    return false;
  }
  final top = (decoration.border as Border).top.color;
  return color == null || top == color;
});

/// 段落正文的颜色（= 高亮描边用色）。
Color? paragraphForeground(WidgetTester tester, Finder paragraph) =>
    tester.widget<Text>(paragraph).style?.color;

/// 精确匹配段落文本（忽略书签标记的 WidgetSpan 占位符，且避免
/// 「paragraph 7」误匹配「paragraph 70」之类的前缀包含问题）。
Finder paragraphText(String text) => find.byWidgetPredicate((widget) {
  if (widget is! Text) return false;
  final plain =
      (widget.data ?? widget.textSpan?.toPlainText())?.replaceAll('\uFFFC', '');
  return plain == text;
});

NovelReaderLocation _centerLocation(WidgetTester tester) => tester
    .state<NovelReaderViewportState>(find.byType(NovelReaderViewport))
    .anchorAtViewportCenter()!;

/// 双击一个段落：第二次 tap 落在双击窗口内，由段落的 onDoubleTap 接管。
Future<void> _doubleTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tap(finder, warnIfMissed: false);
  await tester.pumpAndSettle();
}

Future<void> _slideTo(WidgetTester tester, double item) async {
  final slider = tester.widget<Slider>(
    find.byKey(const ValueKey('novel-reader-progress')),
  );
  slider.onChanged!(item);
  slider.onChangeEnd!(item);
  await _settle(tester);
}

Future<void> _remove(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Store store;
  late _Repository repository;
  late HttpOverrides? previousOverrides;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = _Store(await SharedPreferences.getInstance());
    _bookmarks = NovelBookmarkStore.forTesting(
      prefs: Future.value(store.preferences),
    );
    repository = _Repository({'v1': _volume()});
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _ImageOverrides();
  });

  tearDown(() {
    HttpOverrides.global = previousOverrides;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  test(
    'document excludes illustrations without renumbering text or blank lines',
    () {
      final document = NovelReaderDocument(const [
        NovelReaderEntry(
          entryIndex: 4,
          entry: NovelContentEntry(name: 'text', contentType: 1),
          paragraphs: ['a', '', 'b'],
        ),
        NovelReaderEntry(
          entryIndex: 9,
          entry: NovelContentEntry(
            name: 'image',
            contentType: 2,
            content: 'local',
          ),
        ),
        NovelReaderEntry(
          entryIndex: 10,
          entry: NovelContentEntry(name: 'empty', contentType: 1),
        ),
      ]);
      expect(document.itemCount, 4);
      expect(document.paragraphAt(1).text, '');
      expect(document.paragraphAt(3).entry.entryIndex, 10);
      expect(
        document.itemFor(
          const NovelReaderAnchor(entryIndex: 4, paragraphIndex: 999),
        ),
        2,
      );
      expect(
        document.itemFor(
          const NovelReaderAnchor(entryIndex: 9, paragraphIndex: 999),
        ),
        2,
      );
      expect(document.itemFor(const NovelReaderAnchor(entryIndex: 999)), 0);
    },
  );

  testWidgets(
    'resume restores exact paragraph and negative alignment, not chapter start',
    (tester) async {
      await tester.runAsync(() => store.saveProgress(_progress()));
      store.writes.clear();
      await _mount(tester, repository, store, resume: true);
      final position = _location(tester).anchor;
      expect(position.entryIndex, 1);
      expect(position.paragraphIndex, 40);
      expect(position.alignment, closeTo(-0.04, 0.005));
      await _flush(tester);
      expect(store.writes, isNotEmpty);
      expect(
        store.writes.every((p) => p.entryIndex == 1 && p.paragraphIndex == 40),
        isTrue,
      );
      await _remove(tester);
    },
  );

  testWidgets('negative offset deeper than one screen is restored safely', (
    tester,
  ) async {
    repository = _Repository({'v1': _volume(longParagraph: true)});
    await _seed(tester, store, _progress(paragraph: 12, alignment: -1.25));
    store.writes.clear();
    await _mount(tester, repository, store, resume: true);
    final anchor = _location(tester).anchor;
    expect(anchor.paragraphIndex, 12);
    expect(anchor.alignment, closeTo(-1.25, 0.01));
    expect(tester.takeException(), isNull);
    await _remove(tester);
  });

  testWidgets(
    'startup does not overwrite progress before async restore has loaded',
    (tester) async {
      final saved = _progress(paragraph: 65);
      await _seed(tester, store, saved);
      store.writes.clear();
      store.pendingRead = Completer<NovelReadingProgress?>();
      await _mount(tester, repository, store, resume: true, settle: false);
      await tester.pump(const Duration(seconds: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(store.writes, isEmpty);
      store.pendingRead!.complete(saved);
      await _settle(tester);
      expect(_location(tester).anchor.paragraphIndex, 65);
      expect(store.writes.any((p) => p.paragraphIndex == 0), isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _remove(tester);
    },
  );

  testWidgets(
    'dispose during volume loading leaves the old progress untouched',
    (tester) async {
      await tester.runAsync(() => store.saveProgress(_progress()));
      store.writes.clear();
      final pending = Completer<NovelVolumeContent>();
      repository.pending['v1'] = pending;
      await _mount(tester, repository, store, resume: true, settle: false);
      await tester.pump(const Duration(milliseconds: 500));
      await _remove(tester);
      pending.complete(_volume());
      await tester.pump();
      expect(store.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('explicit chapter selection ignores saved resume position', (
    tester,
  ) async {
    await _seed(tester, store, _progress());
    await _mount(tester, repository, store, initialEntry: 2);
    expect(_location(tester).anchor.entryIndex, 2);
    expect(_location(tester).anchor.paragraphIndex, 0);
    await _remove(tester);
  });

  testWidgets('resume never applies another volume progress', (tester) async {
    await _seed(tester, store, _progress(volume: 'other'));
    await _mount(tester, repository, store, resume: true, initialEntry: 2);
    expect(_location(tester).anchor.entryIndex, 2);
    expect(_location(tester).anchor.paragraphIndex, 0);
    await _remove(tester);
  });

  testWidgets('long text builds only nearby paragraphs', (tester) async {
    repository = _Repository({'v1': _volume(entries: 1, paragraphs: 10000)});
    await _mount(tester, repository, store);
    expect(find.text('v1 entry 0 paragraph 9999'), findsNothing);
    final paragraphs = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          widget.key.toString().contains('novel-paragraph-'),
    );
    expect(paragraphs.evaluate().length, lessThan(100));
    await _slideTo(tester, 8000);
    expect(_location(tester).anchor.paragraphIndex, 8000);
    await _remove(tester);
  });

  testWidgets(
    'scroll position is debounced and lifecycle inactive flushes immediately',
    (tester) async {
      await _mount(tester, repository, store);
      await _flush(tester);
      store.writes.clear();
      await tester.drag(
        find.byKey(const ValueKey('novel-reader-surface')),
        const Offset(0, -360),
      );
      await tester.pump();
      final before = _location(tester).anchor;
      expect(before.paragraphIndex, greaterThan(0));
      expect(store.writes, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(store.writes.last.paragraphIndex, before.paragraphIndex);
      expect(
        store.writes.last.paragraphAlignment,
        closeTo(before.alignment, 0.005),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _remove(tester);
    },
  );

  testWidgets(
    'paused and dispose flush the latest paragraph without waiting for debounce',
    (tester) async {
      await _mount(tester, repository, store);
      await _slideTo(tester, 175);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(store.writes.last.entryIndex, 1);
      expect(store.writes.last.paragraphIndex, 75);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _slideTo(tester, 282);
      await _remove(tester);
      expect(store.writes.last.entryIndex, 2);
      expect(store.writes.last.paragraphIndex, 82);
    },
  );

  testWidgets('failed persistence is retried on next lifecycle flush', (
    tester,
  ) async {
    await _mount(tester, repository, store);
    await _flush(tester);
    store.writes.clear();
    store.failures = 1;
    await _slideTo(tester, 145);
    await _flush(tester);
    expect(store.writes.last.paragraphIndex, 45);
    final attempts = store.writes.length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(store.writes.length, greaterThan(attempts));
    expect((await _read(tester, store, 'book'))!.paragraphIndex, 45);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _remove(tester);
  });

  testWidgets(
    'scrolling and slider cross entries using original entry indexes',
    (tester) async {
      await _mount(tester, repository, store);
      await _slideTo(tester, 198);
      await tester.drag(
        find.byKey(const ValueKey('novel-reader-surface')),
        const Offset(0, -250),
      );
      await _settle(tester);
      expect(_location(tester).anchor.entryIndex, 2);
      await _flush(tester);
      expect(store.writes.last.entryIndex, 2);
      expect(repository.calls, ['book/v1/false']);
      await _remove(tester);
    },
  );

  testWidgets(
    'previous and next navigate entries and cross volume boundaries',
    (tester) async {
      repository = _Repository({
        'v1': _volume(next: 'v2'),
        'v2': _volume(id: 'v2', previous: 'v1'),
      });
      await _mount(tester, repository, store, initialEntry: 2);
      await tester.tap(find.byKey(const ValueKey('novel-reader-next')));
      await _settle(tester);
      expect(repository.calls, contains('book/v2/false'));
      expect(_location(tester).anchor.entryIndex, 0);
      await tester.tap(find.byKey(const ValueKey('novel-reader-next')));
      await _settle(tester);
      expect(_location(tester).anchor.entryIndex, 1);
      await tester.tap(find.byKey(const ValueKey('novel-reader-previous')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('novel-reader-previous')));
      await _settle(tester);
      expect(_location(tester).anchor.entryIndex, 2);
      await _flush(tester);
      expect(store.writes.last.volumeId, 'v1');
      await _remove(tester);
    },
  );

  testWidgets('a slower old volume response cannot replace a newer book', (
    tester,
  ) async {
    final pending = Completer<NovelVolumeContent>();
    repository.pending['v1'] = pending;
    repository.content['v2'] = _volume(book: 'another', id: 'v2');
    await _mount(tester, repository, store, settle: false);
    await tester.pump(const Duration(milliseconds: 30));
    await _mount(
      tester,
      repository,
      store,
      book: 'another',
      volume: 'v2',
      initialEntry: 2,
    );
    pending.complete(_volume());
    await _settle(tester);
    await _flush(tester);
    expect(find.text('another title'), findsOneWidget);
    expect(store.writes.last.pathWord, 'another');
    expect(store.writes.last.volumeId, 'v2');
    expect(store.writes.last.entryIndex, 2);
    await _remove(tester);
  });

  testWidgets(
    'changing books flushes old identity and does not reuse its anchor',
    (tester) async {
      repository.content['v2'] = _volume(book: 'another', id: 'v2');
      await _mount(tester, repository, store);
      await _slideTo(tester, 143);
      await _mount(
        tester,
        repository,
        store,
        book: 'another',
        volume: 'v2',
        resume: true,
      );
      await _flush(tester);
      final old = await _read(tester, store, 'book');
      final next = await _read(tester, store, 'another');
      expect(old!.volumeId, 'v1');
      expect(old.entryIndex, 1);
      expect(old.paragraphIndex, 43);
      expect(next!.volumeId, 'v2');
      expect(next.entryIndex, 0);
      expect(next.paragraphIndex, 0);
      await _remove(tester);
    },
  );

  test('reader palette updates icons when crossing light and dark themes', () {
    for (final (base, themeId) in [
      (ThemeData.dark(), 'white'),
      (ThemeData.light(), 'dark'),
    ]) {
      final palette = NovelReaderPalette.forThemeId(
        const NovelReaderSettings(),
        themeId,
      );
      expect(palette.applyTo(base).iconTheme.color, palette.foreground);
    }
  });

  testWidgets('custom colors and 48px text reach the reading surface', (
    tester,
  ) async {
    await tester.runAsync(
      () =>
          const NovelReaderSettings(
                lightThemeId: 'c1',
                darkThemeId: 'c1',
                fontSize: 48,
              )
              .upsertCustomTheme(
                const NovelReaderCustomTheme(
                  id: 'c1',
                  name: '深蓝',
                  backgroundColor: 0xFF102030,
                  textColor: 0xFFECDDBB,
                ),
              )
              .save(),
    );
    await _mount(tester, repository, store);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      const Color(0xFF102030),
    );
    final text = tester.widget<Text>(find.text('v1 entry 0 paragraph 0'));
    expect(text.style!.color, const Color(0xFFECDDBB));
    expect(text.style!.fontSize, 48);
    await _remove(tester);
  });

  for (final showStatus in [true, false]) {
    testWidgets(
      'shared status setting and percentage stay stable: $showStatus',
      (tester) async {
        final statusSettings = ReaderSettings();
        await tester.runAsync(() async {
          SharedPreferences.setMockInitialValues(
            showStatus ? {'reader_status_overlay': true} : {},
          );
          await statusSettings.initFromPrefs(
            await SharedPreferences.getInstance(),
          );
          await const NovelReaderSettings().save();
        });
        await _mount(tester, repository, store);
        await _slideTo(tester, 150);
        final surface = find.byKey(const ValueKey('novel-reader-surface'));
        final before = tester.getRect(surface);
        final location = _location(tester);
        expect(
          tester
              .widget<Slider>(
                find.byKey(const ValueKey('novel-reader-progress')),
              )
              .label,
          '50.00%',
        );
        for (var toggle = 0; toggle < 6; toggle++) {
          await tester.tapAt(before.center);
          await tester.pump();
          expect(tester.getRect(surface), before);
          expect(
            _location(tester).anchor.paragraphIndex,
            location.anchor.paragraphIndex,
          );
          await _settle(tester);
          expect(tester.getRect(surface), before);
          expect(_location(tester).progress, closeTo(location.progress, 1e-6));
        }
        // 工具栏显示时状态组件处于 Offstage，用 skipOffstage 找到它。
        expect(
          find.byType(ReaderStatusOverlay, skipOffstage: false),
          showStatus ? findsOneWidget : findsNothing,
        );
        if (showStatus) {
          final status = tester.widget<ReaderStatusOverlay>(
            find.byType(ReaderStatusOverlay, skipOffstage: false),
          );
          expect(status.progressLabel, '50.00%');
        }
        expect(tester.takeException(), isNull);
        await _remove(tester);
        await _mount(tester, repository, store);
        expect(
          find.byType(ReaderStatusOverlay, skipOffstage: false),
          showStatus ? findsOneWidget : findsNothing,
        );
        await _remove(tester);
        await tester.runAsync(() async {
          await statusSettings.setStatusOverlay(false);
        });
      },
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'bookmark button highlights on add and resets on removal without moving progress: ${brightness.name}',
      (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        await _seed(tester, store, _progress(alignment: -0.03));
        await _mount(tester, repository, store, resume: true);
        await _flush(tester);
        store.writes.clear();
        // 按钮书签以视口中点段落为参照，而不是顶部首段。
        final location = _centerLocation(tester);
        final button = find.byKey(const ValueKey('novel-reader-bookmark'));
        expect(Theme.of(tester.element(button)).brightness, brightness);
        final chrome = tester.widget<ColoredBox>(
          find.ancestor(of: button, matching: find.byType(ColoredBox)).first,
        );
        expect(chrome.color, ReaderChrome.surface);

        void expectBookmarkState(bool bookmarked) {
          final widget = tester.widget<IconButton>(button);
          expect(widget.onPressed, isNotNull);
          expect(widget.tooltip, bookmarked ? '取消书签' : '添加书签');
          final iconFinder = find.descendant(
            of: button,
            matching: find.byType(Icon),
          );
          final icon = tester.widget<Icon>(iconFinder);
          expect(
            icon.icon,
            bookmarked ? Icons.bookmark : Icons.bookmark_border,
          );
          expect(
            icon.color ?? IconTheme.of(tester.element(iconFinder)).color,
            bookmarked ? Colors.amberAccent : ReaderChrome.onSurface,
          );
        }

        expectBookmarkState(false);
        await tester.tap(button);
        await _settle(tester);
        final bookmark = _bookmarks.bookmarks.single;
        expect(bookmark.pathWord, 'book');
        expect(bookmark.volumeId, 'v1');
        expect(bookmark.entryIndex, location.anchor.entryIndex);
        expect(bookmark.paragraphIndex, location.anchor.paragraphIndex);
        expect(
          bookmark.paragraphAlignment,
          closeTo(location.anchor.alignment, 1e-6),
        );
        expect(bookmark.progress, closeTo(location.progress, 1e-6));
        expectBookmarkState(true);
        expect(store.writes, isEmpty);
        expect(_location(tester).anchor.paragraphIndex, 40);
        await tester.tap(button);
        await _settle(tester);
        expect(_bookmarks.bookmarks, isEmpty);
        expectBookmarkState(false);
        expect(store.writes, isEmpty);
        await _remove(tester);
      },
    );
  }

  testWidgets(
    'bookmark anchor is explicit and never replaced by last reading',
    (tester) async {
      await _seed(tester, store, _progress(entry: 2, paragraph: 80));
      await _mount(
        tester,
        repository,
        store,
        initialEntry: 1,
        initialParagraph: 25,
        initialAlignment: -0.03,
      );
      expect(_location(tester).anchor.entryIndex, 1);
      expect(_location(tester).anchor.paragraphIndex, 25);
      expect(_location(tester).anchor.alignment, closeTo(-0.03, 0.005));
      await _remove(tester);
    },
  );

  testWidgets('double-tap paragraph opens the action menu and copies text', (
    tester,
  ) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await _mount(tester, repository, store);
    await _doubleTap(tester, find.text('v1 entry 0 paragraph 0'));
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('书签'), findsOneWidget);

    await tester.tap(find.text('复制'));
    await _settle(tester);
    expect(clipboard, 'v1 entry 0 paragraph 0');
    expect(find.text('段落已复制到剪贴板'), findsOneWidget);
    // 复制不产生书签，也不闪光高亮。
    expect(_bookmarks.bookmarks, isEmpty);
    expect(highlightBand(), findsNothing);
    await _remove(tester);
  });

  testWidgets(
    'double-tap menu bookmark stores the tapped paragraph and flashes highlight',
    (tester) async {
      await _mount(tester, repository, store);
      await _doubleTap(tester, find.text('v1 entry 0 paragraph 2'));
      await tester.tap(find.text('书签'));
      await _settle(tester);
      final bookmark = _bookmarks.bookmarks.single;
      expect(bookmark.entryIndex, 0);
      expect(bookmark.paragraphIndex, 2);
      expect(bookmark.paragraphAlignment, 0);
      expect(bookmark.progress, closeTo(2 / 300, 1e-6));
      final paragraph = paragraphText('v1 entry 0 paragraph 2');
      expect(
        find.ancestor(
          of: paragraph,
          matching: highlightBand(paragraphForeground(tester, paragraph)),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(highlightBand(), findsNothing);
      await _remove(tester);
    },
  );

  testWidgets(
    'double-tap menu offers bookmark removal for an already bookmarked paragraph',
    (tester) async {
      await tester.runAsync(
        () => _bookmarks.toggle(progress: _progress(entry: 0, paragraph: 0)),
      );
      await _mount(tester, repository, store);
      // 已收藏段落带小书签标记，双击菜单文案仍为「书签」。
      expect(
        find.byKey(const ValueKey('novel-paragraph-marker-0-0')),
        findsOneWidget,
      );
      await _doubleTap(
        tester,
        paragraphText('v1 entry 0 paragraph 0'),
      );
      await tester.tap(find.text('书签'));
      await _settle(tester);
      expect(_bookmarks.bookmarks, isEmpty);
      expect(highlightBand(), findsNothing);
      await _remove(tester);
    },
  );

  testWidgets(
    'bookmarked paragraphs show a subtle marker that removes the bookmark',
    (tester) async {
      await tester.runAsync(
        () => _bookmarks.toggle(progress: _progress(entry: 0, paragraph: 0)),
      );
      await _mount(tester, repository, store);
      final marker = find.byKey(const ValueKey('novel-paragraph-marker-0-0'));
      expect(marker, findsOneWidget);
      // 未收藏的段落没有标记。
      expect(
        find.byKey(const ValueKey('novel-paragraph-marker-0-1')),
        findsNothing,
      );
      // 标记用正文同色、正常尺寸。
      final icon = tester.widget<Icon>(
        find.descendant(of: marker, matching: find.byType(Icon)),
      );
      final paragraph = paragraphText('v1 entry 0 paragraph 0');
      expect(icon.size, AppIconSize.md);
      expect(icon.color, paragraphForeground(tester, paragraph));
      await tester.tap(marker);
      await _settle(tester);
      expect(_bookmarks.bookmarks, isEmpty);
      expect(marker, findsNothing);
      await _remove(tester);
    },
  );

  testWidgets(
    'toolbar bookmark skips blank paragraphs for the nearest text paragraph',
    (tester) async {
      // 段落 3..40 为空行：屏幕中点必落在空行区间内，按钮书签应就近
      // 改选有文本的段落（可见项里最近的是段落 2），绝不给空行打书签。
      repository = _Repository({
        'v1': _volume(blanks: {for (var i = 3; i <= 40; i++) i}),
      });
      await _mount(tester, repository, store);
      await tester.tap(find.byKey(const ValueKey('novel-reader-bookmark')));
      await _settle(tester);
      final bookmark = _bookmarks.bookmarks.single;
      expect(bookmark.entryIndex, 0);
      expect(bookmark.paragraphIndex, 2);
      // 命中的段落带书签标记。
      expect(
        find.byKey(
          ValueKey('novel-paragraph-marker-0-${bookmark.paragraphIndex}'),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await _remove(tester);
    },
  );

  testWidgets('double-tap menu disables actions on blank paragraphs', (
    tester,
  ) async {
    repository = _Repository({
      'v1': _volume(blanks: {for (var i = 3; i <= 12; i++) i}),
    });
    await _mount(tester, repository, store);
    final blank = find
        .descendant(
          of: find.byKey(const ValueKey('novel-paragraph-0-6')),
          matching: find.byType(Text),
        )
        .first;
    await _doubleTap(tester, blank);
    expect(find.text('复制'), findsOneWidget);
    // PopupMenuItem 是泛型类，byType 匹配不到，用 is 谓词。
    Finder menuItem(Finder of) => find.ancestor(
      of: of,
      matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
    );
    final copyItem = tester.widget<PopupMenuItem>(menuItem(find.text('复制')));
    final bookmarkItem = tester.widget<PopupMenuItem>(
      menuItem(find.text('书签')),
    );
    expect(copyItem.enabled, isFalse);
    expect(bookmarkItem.enabled, isFalse);
    await _remove(tester);
  });

  testWidgets(
    'toolbar bookmark add flashes the paragraph highlight without moving text',
    (tester) async {
      await _mount(tester, repository, store);
      // 按钮打的是视口中点段落，不是顶部首段。
      final center = _centerLocation(tester).anchor;
      expect(center.paragraphIndex, greaterThan(0));
      final marked = paragraphText('v1 entry 0 paragraph ${center.paragraphIndex}');
      final foreground = paragraphForeground(tester, marked);
      final topBefore = tester.getTopLeft(marked).dy;
      await tester.tap(find.byKey(const ValueKey('novel-reader-bookmark')));
      await _settle(tester);
      expect(
        _bookmarks.bookmarks.single.paragraphIndex,
        center.paragraphIndex,
      );
      expect(
        find.ancestor(of: marked, matching: highlightBand(foreground)),
        findsOneWidget,
      );
      expect(tester.getTopLeft(marked).dy, topBefore);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(highlightBand(), findsNothing);
      expect(tester.getTopLeft(marked).dy, topBefore);
      await _remove(tester);
    },
  );

  testWidgets(
    'entering from a bookmark flashes the target paragraph until the user scrolls',
    (tester) async {
      await _mount(
        tester,
        repository,
        store,
        initialEntry: 1,
        initialParagraph: 25,
        initialAlignment: -0.03,
        highlightOnEntry: true,
      );
      final paragraph = paragraphText('v1 entry 1 paragraph 25');
      expect(
        find.ancestor(
          of: paragraph,
          matching: highlightBand(paragraphForeground(tester, paragraph)),
        ),
        findsOneWidget,
      );
      // 书签段落定位到视口中部（阅读习惯），绝不贴顶。
      final height =
          tester.getRect(
            find.byKey(const ValueKey('novel-reader-surface')),
          ).height;
      final top = tester.getTopLeft(paragraph).dy;
      expect(top, greaterThan(height * 0.25));
      expect(top, lessThan(height * 0.75));
      await tester.drag(
        find.byKey(const ValueKey('novel-reader-surface')),
        const Offset(0, -200),
      );
      await tester.pump();
      expect(highlightBand(), findsNothing);
      await _remove(tester);
    },
  );

  for (final (size, padding, textScale) in [
    (const Size(420, 820), const EdgeInsets.only(top: 24, bottom: 30), 1.0),
    (const Size(820, 420), const EdgeInsets.fromLTRB(32, 24, 28, 30), 1.8),
    (const Size(320, 720), const EdgeInsets.only(bottom: 24), 2.0),
  ]) {
    testWidgets('阅读设置含安全区不超过屏幕70%，底部设置仍可滚动操作：$size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await _mount(
        tester,
        repository,
        store,
        padding: padding,
        textScale: textScale,
      );
      await tester.tap(find.byKey(const ValueKey('novel-reader-settings')));
      await _settle(tester);

      final sheet = find.byType(AppSheet);
      final rect = tester.getRect(sheet);
      expect(rect.height, lessThanOrEqualTo(size.height * 0.7 + 0.01));
      expect(rect.bottom, closeTo(size.height, 0.01));
      final keepScreenOn = find.byKey(const ValueKey('novel-keep-screen-on'));
      await tester.ensureVisible(keepScreenOn);
      await _settle(tester);
      expect(keepScreenOn.hitTestable(), findsOneWidget);
      final previous = tester.widget<SwitchListTile>(keepScreenOn).value;
      await tester.tap(keepScreenOn);
      await _settle(tester);
      expect(tester.widget<SwitchListTile>(keepScreenOn).value, !previous);
      expect(tester.takeException(), isNull);

      Navigator.of(tester.element(sheet)).pop();
      await _settle(tester);
      await _remove(tester);
    });
  }

  testWidgets('font, line and paragraph spacing changes preserve the anchor', (
    tester,
  ) async {
    await _seed(tester, store, _progress(alignment: -0.03));
    await _mount(tester, repository, store, resume: true);
    await tester.tap(find.byKey(const ValueKey('novel-reader-settings')));
    await _settle(tester);
    expect(find.byType(AppSheet), findsOneWidget);
    for (final (key, value) in [
      ('novel-font-size', 28.0),
      ('novel-line-height', 2.2),
      ('novel-paragraph-spacing', 28.0),
    ]) {
      tester.widget<Slider>(find.byKey(ValueKey(key))).onChanged!(value);
      await _settle(tester);
      expect(_location(tester).anchor.entryIndex, 1);
      expect(_location(tester).anchor.paragraphIndex, 40);
    }
    Navigator.of(tester.element(find.byType(AppSheet))).pop();
    await _settle(tester);
    final settings = await _readSettings(tester);
    expect(settings.fontSize, 28);
    expect(settings.lineHeight, 2.2);
    expect(settings.paragraphSpacing, 28);
    await _remove(tester);
  });

  for (final (name, size, padding, textScale, alignment, longParagraph) in [
    (
      'portrait with system bars',
      const Size(420, 820),
      const EdgeInsets.only(top: 24, bottom: 30),
      1.0,
      -0.04,
      false,
    ),
    (
      'landscape with cutouts and large text',
      const Size(820, 420),
      const EdgeInsets.fromLTRB(32, 24, 28, 30),
      1.8,
      -0.04,
      false,
    ),
    (
      'fullscreen with a long paragraph',
      const Size(420, 820),
      EdgeInsets.zero,
      1.0,
      -1.25,
      true,
    ),
  ]) {
    testWidgets('toolbar toggles never move text or its viewport: $name', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      repository = _Repository({'v1': _volume(longParagraph: longParagraph)});
      await _seed(tester, store, _progress(alignment: alignment));
      await _mount(
        tester,
        repository,
        store,
        resume: true,
        padding: padding,
        textScale: textScale,
      );
      final surface = find.byKey(const ValueKey('novel-reader-surface'));
      await tester.drag(surface, const Offset(0, -137));
      await _settle(tester);
      await _flush(tester);
      // 用户滚动会自动隐藏工具栏；本用例专注几何稳定，先点回工具栏。
      expect(find.byKey(const ValueKey('novel-reader-settings')), findsNothing);
      // 点在页边空白（非段落文字），只切工具栏，不进入段落双击识别。
      await tester.tapAt(
        Offset(tester.getRect(surface).left + 8, tester.getRect(surface).center.dy),
      );
      await tester.pump();
      final before = _location(tester);
      final paragraph = find.byKey(
        ValueKey(
          'novel-paragraph-${before.anchor.entryIndex}-'
          '${before.anchor.paragraphIndex}',
        ),
      );
      final viewportRect = tester.getRect(surface);
      final paragraphRect = tester.getRect(paragraph);
      final viewportState = tester.state(find.byType(NovelReaderViewport));
      store.writes.clear();

      void expectStablePosition() {
        expect(tester.getRect(surface), viewportRect);
        expect(tester.getRect(paragraph), paragraphRect);
        expect(tester.state(find.byType(NovelReaderViewport)), viewportState);
        final current = _location(tester);
        expect(current.itemIndex, before.itemIndex);
        expect(
          current.anchor.alignment,
          closeTo(before.anchor.alignment, 1e-6),
        );
        expect(current.progress, closeTo(before.progress, 1e-6));
      }

      for (var toggle = 0; toggle < 6; toggle++) {
        // Use the reading surface gutter, not the removed top-right hide action.
        await tester.tapAt(Offset(viewportRect.left + 8, viewportRect.center.dy));
        await tester.pump();
        // A final settled anchor alone would miss the one-frame jump/restore.
        expectStablePosition();
        await _settle(tester);
        expectStablePosition();
        expect(
          find.byKey(const ValueKey('novel-reader-settings')),
          toggle.isEven ? findsNothing : findsOneWidget,
        );
      }
      expect(
        find.byKey(const ValueKey('novel-reader-hide-toolbar')),
        findsNothing,
      );
      await _flush(tester);
      expect(store.writes, isEmpty);
      final saved = (await _read(tester, store, 'book'))!;
      expect(saved.entryIndex, before.anchor.entryIndex);
      expect(saved.paragraphIndex, before.anchor.paragraphIndex);
      expect(saved.paragraphAlignment, closeTo(before.anchor.alignment, 1e-6));
      expect(tester.takeException(), isNull);
      await _remove(tester);
    });
  }

  testWidgets('orientation and toolbar changes retain paragraph position', (
    tester,
  ) async {
    await _seed(tester, store, _progress());
    await _mount(tester, repository, store, resume: true);
    await tester.binding.setSurfaceSize(const Size(420, 820));
    await _settle(tester);
    expect(_location(tester).anchor.paragraphIndex, 40);
    await tester.tapAt(
      Offset(
        tester.getRect(find.byKey(const ValueKey('novel-reader-surface'))).left +
            8,
        tester.getRect(find.byKey(const ValueKey('novel-reader-surface'))).center.dy,
      ),
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('novel-reader-settings')), findsNothing);
    expect(_location(tester).anchor.paragraphIndex, 40);
    await tester.binding.setSurfaceSize(const Size(820, 420));
    await _settle(tester);
    expect(_location(tester).anchor.paragraphIndex, 40);
    // 状态组件默认关闭时，点正文即可恢复工具栏。
    await tester.tapAt(
      Offset(
        tester.getRect(find.byKey(const ValueKey('novel-reader-surface'))).left +
            8,
        tester.getRect(find.byKey(const ValueKey('novel-reader-surface'))).center.dy,
      ),
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('novel-reader-settings')), findsOneWidget);
    expect(_location(tester).anchor.paragraphIndex, 40);
    expect(tester.takeException(), isNull);
    await _remove(tester);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
    'reader theme and screen preference are local and plugin failure is safe',
    (tester) async {
      await _mount(tester, repository, store);
      await tester.tap(find.byKey(const ValueKey('novel-reader-settings')));
      await _settle(tester);
      // 浅色模式下拉选择「纸张」。
      final lightTile = find.byKey(const ValueKey('novel-light-theme'));
      await tester.ensureVisible(lightTile);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: lightTile,
          matching: find.byType(SelectTile<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('纸张').last);
      await tester.pumpAndSettle();
      final keepSwitch = find.byKey(const ValueKey('novel-keep-screen-on'));
      await tester.ensureVisible(keepSwitch);
      await tester.pumpAndSettle();
      tester.widget<SwitchListTile>(keepSwitch).onChanged!(false);
      await _settle(tester);
      final settings = await _readSettings(tester);
      expect(settings.lightThemeId, 'paper');
      expect(settings.keepScreenOn, isFalse);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(
        scaffold.backgroundColor,
        NovelReaderPalette.forThemeId(settings, 'paper').background,
      );
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.byType(AppSheet))).pop();
      await _settle(tester);
      await _remove(tester);
    },
  );

  testWidgets('late startup history cannot replace an explicit volume choice', (
    tester,
  ) async {
    repository.content['v2'] = _volume(id: 'v2');
    store.pendingRead = Completer<NovelReadingProgress?>();
    await _mount(tester, repository, store, resume: true, settle: false);
    for (var frame = 0; frame < 8; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.tap(find.byKey(const ValueKey('novel-reader-contents')));
    await tester.pump(const Duration(milliseconds: 350));
    tester
        .widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>),
        )
        .onChanged!('v2');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(const ValueKey('novel-toc-entry-2')));
    await _settle(tester);
    expect(_location(tester).anchor.entryIndex, 2);
    store.pendingRead!.complete(_progress());
    await _settle(tester);
    expect(repository.calls, ['book/v2/false']);
    expect(_location(tester).anchor.entryIndex, 2);
    await _flush(tester);
    expect(store.writes.last.volumeId, 'v2');
    await _remove(tester);
  });

  testWidgets('directory switches volume and opens the chosen entry', (
    tester,
  ) async {
    repository.content['v2'] = _volume(id: 'v2');
    await _mount(tester, repository, store);
    await tester.tap(find.byKey(const ValueKey('novel-reader-contents')));
    await _settle(tester);
    tester
        .widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>),
        )
        .onChanged!('v2');
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('novel-toc-entry-2')));
    await _settle(tester);
    expect(repository.calls, contains('book/v2/false'));
    expect(_location(tester).anchor.entryIndex, 2);
    await _remove(tester);
  });

  testWidgets('empty volume uses retry without creating zero progress', (
    tester,
  ) async {
    repository = _Repository({'v1': _volume(entries: 0)});
    await _seed(tester, store, _progress());
    store.writes.clear();
    await _mount(tester, repository, store, resume: true);
    expect(find.byType(ErrorRetryView), findsOneWidget);
    expect(find.text('本卷暂无可阅读的正文'), findsOneWidget);
    await _flush(tester);
    expect(store.writes, isEmpty);
    await _remove(tester);
  });

  testWidgets('locked response offers COPY login and retry, not content', (
    tester,
  ) async {
    repository = _Repository({'v1': _volume(locked: true)});
    await _mount(tester, repository, store);
    expect(find.byKey(const ValueKey('novel-reader-login')), findsOneWidget);
    expect(find.byType(NovelReaderViewport), findsNothing);
    repository.content['v1'] = _volume();
    tester.widget<ErrorRetryView>(find.byType(ErrorRetryView)).onRetry();
    await _settle(tester);
    expect(find.byType(NovelReaderViewport), findsOneWidget);
    expect(repository.calls.last, 'book/v1/true');
    await _remove(tester);
  });

  testWidgets(
    'request failure opens cache explicitly without another API request',
    (tester) async {
      repository.errors['v1'] = const NovelApiException('offline');
      repository.cached['v1'] = _volume();
      await tester.runAsync(() => store.saveProgress(_progress()));
      await _mount(tester, repository, store, resume: true);
      await tester.tap(find.byKey(const ValueKey('novel-reader-open-cache')));
      await _settle(tester);
      expect(repository.calls, ['book/v1/false', 'cache/book/v1']);
      expect(_location(tester).anchor.paragraphIndex, 40);
      await _remove(tester);
    },
  );

  testWidgets('missing cache is actionable and never overwrites resume', (
    tester,
  ) async {
    repository.errors['v1'] = const NovelApiException('offline');
    await _seed(tester, store, _progress());
    store.writes.clear();
    await _mount(tester, repository, store, resume: true);
    await tester.tap(find.byKey(const ValueKey('novel-reader-open-cache')));
    await _settle(tester);
    expect(find.text('本卷没有可用的本地缓存'), findsOneWidget);
    expect(store.writes, isEmpty);
    await _remove(tester);
  });

  testWidgets('illustrations never enter text progress or chapter navigation', (
    tester,
  ) async {
    repository = _Repository({'v1': _volume(image: true, paragraphs: 3)});
    await _mount(tester, repository, store, initialEntry: 1);
    expect(find.byKey(const ValueKey('novel-image-1')), findsNothing);
    expect(_location(tester).anchor.entryIndex, 0);
    expect(_location(tester).anchor.paragraphIndex, 2);
    await tester.tap(find.byKey(const ValueKey('novel-reader-next')));
    await _settle(tester);
    expect(_location(tester).anchor.entryIndex, 2);
    expect(_location(tester).progress, closeTo(0.5, 1e-6));
    await _slideTo(tester, 5);
    expect(_location(tester).progress, 1);
    expect(find.text('v1 chapter 1'), findsNothing);
    expect(tester.takeException(), isNull);
    await _remove(tester);
  });

  testWidgets('return button flushes before route result is observed', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          novelRepositoryProvider.overrideWithValue(repository),
          novelReadingStoreProvider.overrideWithValue(store),
          novelApiProvider.overrideWithValue(_Api()),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SizedBox(),
        ),
      ),
    );
    final returned = navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => const NovelReaderPage(pathWord: 'book', volumeId: 'v1'),
      ),
    );
    await _settle(tester);
    await _slideTo(tester, 188);
    await tester.tap(find.byKey(const ValueKey('novel-reader-back')));
    await _settle(tester);
    await returned;
    expect((await _read(tester, store, 'book'))!.paragraphIndex, 88);
    await _remove(tester);
  });

  testWidgets(
    'short final chapter and final paragraph stay at requested anchors',
    (tester) async {
      repository = _Repository({'v1': _volume(paragraphs: 2, image: true)});
      await _mount(tester, repository, store, initialEntry: 2);
      expect(_location(tester).anchor.entryIndex, 2);
      expect(_location(tester).anchor.paragraphIndex, 0);
      await _slideTo(tester, 3);
      expect(_location(tester).anchor.entryIndex, 2);
      expect(_location(tester).anchor.paragraphIndex, 1);
      expect(_location(tester).progress, 1);
      await _remove(tester);
      await _mount(tester, repository, store, resume: true);
      expect(_location(tester).anchor.entryIndex, 2);
      expect(_location(tester).anchor.paragraphIndex, 1);
      await _remove(tester);
    },
  );

  testWidgets(
    'stale response from another volume of the same book is ignored',
    (tester) async {
      final stale = Completer<NovelVolumeContent>();
      repository.pending['v1'] = stale;
      repository.content['v2'] = _volume(id: 'v2');
      await _mount(tester, repository, store, settle: false);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.tap(find.byKey(const ValueKey('novel-reader-contents')));
      // The underlying loading spinner is intentional while the sheet is open.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .onChanged!('v2');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('novel-toc-entry-1')));
      await _settle(tester);
      stale.complete(_volume());
      await _settle(tester);
      await _flush(tester);
      expect(_location(tester).anchor.entryIndex, 1);
      expect(store.writes.last.volumeId, 'v2');
      expect(find.text('v1 chapter 0'), findsNothing);
      await _remove(tester);
    },
  );

  testWidgets('stale directory detail cannot replace a newer selection', (
    tester,
  ) async {
    repository.content['v2'] = _volume(id: 'v2');
    repository.content['v3'] = _volume(id: 'v3');
    final stale = Completer<NovelVolumeDetail>();
    repository.detailPending['v2'] = stale;
    await _mount(tester, repository, store);
    await tester.tap(find.byKey(const ValueKey('novel-reader-contents')));
    await _settle(tester);
    tester
        .widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>),
        )
        .onChanged!('v2');
    await tester.pump();
    tester
        .widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>),
        )
        .onChanged!('v3');
    await _settle(tester);
    stale.complete(repository.content['v2']!.detail);
    await _settle(tester);
    expect(find.text('v3 chapter 2'), findsOneWidget);
    expect(find.text('v2 chapter 2'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('novel-toc-entry-2')));
    await _settle(tester);
    await _flush(tester);
    expect(store.writes.last.volumeId, 'v3');
    await _remove(tester);
  });

  testWidgets(
    'corrupt oversized paragraph and alignment clamp without crashing',
    (tester) async {
      await _seed(
        tester,
        store,
        _progress(entry: 2, paragraph: 99999, alignment: -99999),
      );
      await _mount(tester, repository, store, resume: true);
      expect(_location(tester).anchor.entryIndex, 2);
      expect(_location(tester).anchor.paragraphIndex, 99);
      expect(_location(tester).anchor.alignment.isFinite, isTrue);
      expect(tester.takeException(), isNull);
      await _remove(tester);
    },
  );

  testWidgets(
    'system text scaling preserves paragraph and all safe-area insets',
    (tester) async {
      await _seed(tester, store, _progress());
      const padding = EdgeInsets.fromLTRB(32, 24, 28, 30);
      await _mount(tester, repository, store, resume: true, padding: padding);
      // viewport 铺满全屏（纸张延伸到屏幕顶/底），安全区由列表内容层承担。
      final surface = tester.getRect(
        find.byKey(const ValueKey('novel-reader-surface')),
      );
      expect(surface.left, 0);
      expect(surface.top, 0);
      expect(surface.right, 800);
      final location = _location(tester);
      final paragraph = tester.getRect(
        find.byKey(
          ValueKey(
            'novel-paragraph-${location.anchor.entryIndex}-'
            '${location.anchor.paragraphIndex}',
          ),
        ),
      );
      // 左右 = 安全区(32/28) + 限宽居中(740 宽下 720 限宽余量 10 → 取 24)。
      expect(paragraph.left, 56);
      expect(paragraph.right, 748);
      await _mount(
        tester,
        repository,
        store,
        resume: true,
        padding: padding,
        textScale: 1.8,
      );
      expect(_location(tester).anchor.entryIndex, 1);
      expect(_location(tester).anchor.paragraphIndex, 40);
      expect(tester.takeException(), isNull);
      await _remove(tester);
    },
  );

  testWidgets(
    'empty volume remains usable in short landscape with large text',
    (tester) async {
      repository = _Repository({'v1': _volume(entries: 0)});
      await tester.binding.setSurfaceSize(const Size(820, 360));
      await _mount(tester, repository, store, textScale: 1.8);
      expect(find.byType(ErrorRetryView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _remove(tester);
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets('system pop also flushes before caller reads history', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          novelRepositoryProvider.overrideWithValue(repository),
          novelReadingStoreProvider.overrideWithValue(store),
          novelApiProvider.overrideWithValue(_Api()),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SizedBox(),
        ),
      ),
    );
    final returned = navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => const NovelReaderPage(pathWord: 'book', volumeId: 'v1'),
      ),
    );
    await _settle(tester);
    await _slideTo(tester, 155);
    navigator.currentState!.pop();
    await _settle(tester);
    await returned;
    expect((await _read(tester, store, 'book'))!.paragraphIndex, 55);
    await _remove(tester);
  });

  testWidgets('real local preference store survives dispose and exact reopen', (
    tester,
  ) async {
    final real = (await tester.runAsync(() async {
      final preferences = await SharedPreferences.getInstance();
      return NovelReadingStore(prefs: Future.value(preferences));
    }))!;
    await _seed(tester, real, _progress());
    await _mount(tester, repository, real, resume: true);
    expect(_location(tester).anchor.paragraphIndex, 40);
    await tester.drag(
      find.byKey(const ValueKey('novel-reader-surface')),
      const Offset(0, -275),
    );
    await _settle(tester);
    final before = _location(tester).anchor;
    await _remove(tester);
    final saved = (await _read(tester, real, 'book'))!;
    expect(saved.entryIndex, before.entryIndex);
    expect(saved.paragraphIndex, before.paragraphIndex);
    expect(saved.paragraphAlignment, closeTo(before.alignment, 0.005));
    await _mount(tester, repository, real, resume: true);
    final restored = _location(tester).anchor;
    expect(restored.entryIndex, before.entryIndex);
    expect(restored.paragraphIndex, before.paragraphIndex);
    expect(restored.alignment, closeTo(before.alignment, 0.005));
    await _remove(tester);
  });

  testWidgets(
    'inactive during first layout cannot persist the temporary safe alignment',
    (tester) async {
      await _seed(tester, store, _progress());
      store.writes.clear();
      final pending = Completer<NovelVolumeContent>();
      repository.pending['v1'] = pending;
      await _mount(tester, repository, store, resume: true, settle: false);
      for (var frame = 0; frame < 5; frame++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 20));
      }
      pending.complete(_volume());
      await tester.pump();
      expect(find.byType(NovelReaderViewport), findsOneWidget);
      expect(
        tester
            .state<NovelReaderViewportState>(find.byType(NovelReaderViewport))
            .currentLocation,
        isNull,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(store.writes, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      await _flush(tester);
      expect(
        store.writes.every(
          (progress) =>
              progress.entryIndex == 1 &&
              progress.paragraphIndex == 40 &&
              progress.paragraphAlignment < 0,
        ),
        isTrue,
      );
      await _remove(tester);
    },
  );

  testWidgets(
    'COPY login route is scoped without logging out the main account',
    (tester) async {
      repository.errors['v1'] = const NovelApiException(
        'unauthorized',
        statusCode: 401,
      );
      String? scope;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                const NovelReaderPage(pathWord: 'book', volumeId: 'v1'),
          ),
          GoRoute(
            path: '/login',
            name: 'login',
            builder: (_, state) {
              scope = state.uri.queryParameters['copyOnly'];
              return const Scaffold(body: Text('mock login'));
            },
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            novelRepositoryProvider.overrideWithValue(repository),
            novelReadingStoreProvider.overrideWithValue(store),
            novelApiProvider.overrideWithValue(_Api()),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('novel-reader-login')));
      await _settle(tester);
      expect(scope, 'true');
      expect(find.text('mock login'), findsOneWidget);
      await _remove(tester);
      router.dispose();
    },
  );

  testWidgets('user scrolling hides the toolbar and tap restores it', (
    tester,
  ) async {
    await _mount(tester, repository, store);
    expect(find.byKey(const ValueKey('novel-reader-settings')), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('novel-reader-surface')),
      const Offset(0, -200),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('novel-reader-settings')), findsNothing);
    await _settle(tester);
    expect(find.byKey(const ValueKey('novel-reader-settings')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('novel-reader-surface')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('novel-reader-settings')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _remove(tester);
  });

  testWidgets(
    'toolbar expanded during an ongoing fling hides again on the next update',
    (tester) async {
      final statusSettings = ReaderSettings();
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({'reader_status_overlay': true});
        await statusSettings.initFromPrefs(
          await SharedPreferences.getInstance(),
        );
        await const NovelReaderSettings().save();
      });
      await _mount(tester, repository, store);
      final surface = find.byKey(const ValueKey('novel-reader-surface'));
      // 带速度的甩动模拟惯性滚动：松手后仍有 ballistic 更新流。
      await tester.fling(surface, const Offset(0, -600), 1000);
      await tester.pump();
      expect(find.byKey(const ValueKey('novel-reader-settings')), findsNothing);
      // 惯性尚未结束时，用户点状态组件展开工具栏；状态组件位于正文
      // 之上，点击不会让 Scrollable hold/结束惯性，更新流继续到来。
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(
        find.byKey(const ValueKey('novel-reader-show-toolbar')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('novel-reader-settings')),
        findsOneWidget,
      );
      // 后续惯性 ScrollUpdate 到来时再次隐藏。
      await tester.pump(const Duration(milliseconds: 100));
      await _settle(tester);
      expect(find.byKey(const ValueKey('novel-reader-settings')), findsNothing);
      expect(tester.takeException(), isNull);
      await _remove(tester);
      await tester.runAsync(() async {
        await statusSettings.setStatusOverlay(false);
      });
    },
  );

  testWidgets('slider jumps never hide the toolbar', (tester) async {
    await _mount(tester, repository, store);
    await _slideTo(tester, 150);
    await _settle(tester);
    // 程序化锚点恢复（滑杆跳转）不是用户滚动会话，工具栏保持可见。
    expect(find.byKey(const ValueKey('novel-reader-settings')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _remove(tester);
  });
}

// No socket is ever opened, including by Image.network. Any unexpected host
// fails here, so an accidental live business/CDN request cannot escape a test.
class _ImageOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _ImageClient();
}

class _ImageClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (url.host != 'images.invalid') {
      throw StateError('Network is forbidden: ${url.host}');
    }
    return _ImageRequest();
  }

  @override
  bool autoUncompress = true;

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageRequest implements HttpClientRequest {
  @override
  HttpHeaders get headers => _ImageHeaders();

  @override
  Future<HttpClientResponse> close() async => _ImageResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageHeaders implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  static final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5V8AAAAASUVORK5CYII=',
  );

  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => bytes.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

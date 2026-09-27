import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/novel_reader_settings.dart';
import 'package:kira/models/reader_settings.dart';
import 'package:kira/pages/novel_reader/novel_reader_settings_sheet.dart';
import 'package:kira/widgets/app_sheet.dart';
import 'package:kira/widgets/reader_status_settings.dart';
import 'package:kira/widgets/select_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _mount(
  WidgetTester tester, {
  NovelReaderSettings settings = const NovelReaderSettings(),
  required ValueChanged<NovelReaderSettings> onChanged,
  Size size = const Size(420, 850),
  double textScale = 1,
  Locale locale = const Locale('zh'),
  Brightness systemBrightness = Brightness.light,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          platformBrightness: systemBrightness,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAppSheet<void>(
              context,
              maxHeightFactor: 0.7,
              child: NovelReaderSettingsSheet(
                settings: settings,
                systemBrightness: systemBrightness,
                onChanged: onChanged,
              ),
            ),
            child: const Text('打开阅读设置'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开阅读设置'));
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final reader = ReaderSettings()..resetPrefsCache();
    await reader.initFromPrefs(await SharedPreferences.getInstance());
  });

  testWidgets(
    'font slider offers 10 to 48 with one-pixel steps and live preview',
    (tester) async {
      var latest = const NovelReaderSettings();
      await _mount(tester, onChanged: (value) => latest = value);
      final finder = find.byKey(const ValueKey('novel-font-size'));
      final slider = tester.widget<Slider>(finder);
      expect(slider.min, 10);
      expect(slider.max, 48);
      expect(slider.divisions, 38);
      for (final fontSize in [10.0, 11.0, 47.0, 48.0]) {
        tester.widget<Slider>(finder).onChanged!(fontSize);
        await tester.pumpAndSettle();
        expect(latest.fontSize, fontSize);
        expect(tester.widget<Slider>(finder).value, fontSize);
        final preview = tester.widget<Text>(
          find.byKey(const ValueKey('novel-settings-preview-text')),
        );
        expect(preview.style?.fontSize, fontSize);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('line height and paragraph spacing offer the wider ranges', (
    tester,
  ) async {
    var latest = const NovelReaderSettings();
    await _mount(tester, onChanged: (value) => latest = value);
    final line = tester.widget<Slider>(
      find.byKey(const ValueKey('novel-line-height')),
    );
    expect(line.min, 1.0);
    expect(line.max, 3.0);
    final spacing = tester.widget<Slider>(
      find.byKey(const ValueKey('novel-paragraph-spacing')),
    );
    expect(spacing.min, 0);
    expect(spacing.max, 64);
    tester
        .widget<Slider>(find.byKey(const ValueKey('novel-line-height')))
        .onChanged!(1.0);
    tester
        .widget<Slider>(find.byKey(const ValueKey('novel-paragraph-spacing')))
        .onChanged!(0.0);
    await tester.pumpAndSettle();
    expect(latest.lineHeight, 1.0);
    expect(latest.paragraphSpacing, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('light and dark mode bindings pick presets independently', (
    tester,
  ) async {
    var latest = const NovelReaderSettings();
    await _mount(tester, onChanged: (value) => latest = value);
    final lightTile = find.byKey(const ValueKey('novel-light-theme'));
    await tester.ensureVisible(lightTile);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: lightTile, matching: find.byType(SelectTile<String>)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('纸张').last);
    await tester.pumpAndSettle();
    expect(latest.lightThemeId, 'paper');
    expect(latest.darkThemeId, 'dark');
    final darkTile = find.byKey(const ValueKey('novel-dark-theme'));
    await tester.ensureVisible(darkTile);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: darkTile, matching: find.byType(SelectTile<String>)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('护眼绿').last);
    await tester.pumpAndSettle();
    expect(latest.lightThemeId, 'paper');
    expect(latest.darkThemeId, 'green');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'add dialog edits name and colors together, then binds to dark mode',
    (tester) async {
      var latest = const NovelReaderSettings();
      await _mount(tester, onChanged: (value) => latest = value);
      await _tapVisible(tester, 'novel-theme-add');
      // 新建直接弹出编辑对话框，名称为空时确认按钮禁用。
      FilledButton confirmButton() => tester.widget<FilledButton>(
        find.byKey(const ValueKey('novel-theme-edit-confirm')),
      );
      expect(confirmButton().onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('novel-theme-name-field')),
        '夜航',
      );
      await tester.pumpAndSettle();
      expect(confirmButton().onPressed, isNotNull);
      // 背景与文字两个颜色字段分别打开色轮并确认，色块/HEX 同步刷新。
      for (final (key, color) in [
        ('novel-theme-edit-background', const Color(0xFF152337)),
        ('novel-theme-edit-text', const Color(0xFFE8DDBA)),
      ]) {
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        expect(find.byType(ColorPicker), findsOneWidget);
        tester
            .widget<ColorPicker>(find.byType(ColorPicker))
            .onColorChanged(color);
        final context = tester.element(find.byType(ColorPicker));
        final okLabel = MaterialLocalizations.of(context).okButtonLabel;
        await tester.tap(find.text(okLabel).first);
        await tester.pumpAndSettle();
        final hex =
            '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
        expect(find.text(hex), findsOneWidget);
      }
      // 预览实时反映当前颜色。
      final preview = tester.widget<Container>(
        find.byKey(const ValueKey('novel-theme-edit-preview')),
      );
      expect(
        (preview.decoration! as BoxDecoration).color,
        const Color(0xFF152337),
      );
      final previewText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('novel-theme-edit-preview')),
          matching: find.byType(Text),
        ),
      );
      expect(previewText.style?.color, const Color(0xFFE8DDBA));
      await tester.tap(find.byKey(const ValueKey('novel-theme-edit-confirm')));
      await tester.pumpAndSettle();
      expect(latest.customThemes, hasLength(1));
      expect(latest.customThemes.single.name, '夜航');
      expect(latest.customThemes.single.backgroundColor, 0xFF152337);
      expect(latest.customThemes.single.textColor, 0xFFE8DDBA);
      final darkTile = find.byKey(const ValueKey('novel-dark-theme'));
      await tester.ensureVisible(darkTile);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: darkTile,
          matching: find.byType(SelectTile<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('夜航').last);
      await tester.pumpAndSettle();
      expect(latest.darkThemeId, latest.customThemes.single.id);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('edit dialog renames an existing theme and updates its colors', (
    tester,
  ) async {
    const theme = NovelReaderCustomTheme(
      id: 'c1',
      name: '米黄',
      backgroundColor: 0xFF182839,
      textColor: 0xFFEFDFC1,
    );
    var latest = const NovelReaderSettings().upsertCustomTheme(theme);
    await _mount(
      tester,
      settings: latest,
      onChanged: (value) => latest = value,
    );
    await _tapVisible(tester, 'novel-custom-theme-edit-c1');
    await tester.enterText(
      find.byKey(const ValueKey('novel-theme-name-field')),
      '暮色',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('novel-theme-edit-background')));
    await tester.pumpAndSettle();
    tester
        .widget<ColorPicker>(find.byType(ColorPicker))
        .onColorChanged(const Color(0xFF223344));
    final context = tester.element(find.byType(ColorPicker));
    await tester.tap(
      find.text(MaterialLocalizations.of(context).okButtonLabel).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('novel-theme-edit-confirm')));
    await tester.pumpAndSettle();
    expect(latest.customThemes.single.id, 'c1');
    expect(latest.customThemes.single.name, '暮色');
    expect(latest.customThemes.single.backgroundColor, 0xFF223344);
    expect(latest.customThemes.single.textColor, 0xFFEFDFC1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('delete a custom theme falls its binding back safely', (
    tester,
  ) async {
    const theme = NovelReaderCustomTheme(
      id: 'c1',
      name: '米黄',
      backgroundColor: 0xFF182839,
      textColor: 0xFFEFDFC1,
    );
    var latest = const NovelReaderSettings(
      darkThemeId: 'c1',
    ).upsertCustomTheme(theme);
    await _mount(
      tester,
      settings: latest,
      onChanged: (value) => latest = value,
    );
    await _tapVisible(tester, 'novel-custom-theme-delete-c1');
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    expect(latest.customThemes, isEmpty);
    // 绑定保留原 ID，展示时由 themeIdFor 兜底回退到深色默认。
    expect(latest.themeIdFor(dark: true), 'dark');
    expect(tester.takeException(), isNull);
  });

  testWidgets('screen-on preference is independent and persists', (
    tester,
  ) async {
    var latest = const NovelReaderSettings();
    await _mount(tester, onChanged: (value) => latest = value);
    await _tapVisible(tester, 'novel-keep-screen-on');
    expect(latest.keepScreenOn, isFalse);
    await tester.runAsync(() async {
      await latest.save();
      final saved = await NovelReaderSettings.load();
      expect(saved.keepScreenOn, isFalse);
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'novel settings embed global status settings and support first-to-last drag',
    (tester) async {
      var latest = const NovelReaderSettings();
      await _mount(tester, onChanged: (value) => latest = value);
      expect(find.byType(ReaderStatusSettingsSection), findsOneWidget);
      await _tapVisible(tester, 'reader-status-overlay-switch');
      expect(ReaderSettings().statusOverlay, isTrue);
      await tester.ensureVisible(find.byType(ReorderableListView));
      await tester.pumpAndSettle();
      final handles = find.byType(ReorderableDragStartListener);
      final target = tester.getCenter(handles.last) + const Offset(0, 100);
      final gesture = await tester.startGesture(
        tester.getCenter(handles.first),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveBy(const Offset(0, 1));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      const expected = ['network', 'battery', 'page', 'fps', 'time'];
      expect(ReaderSettings().statusOverlayOrder, expected);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('reader_status_overlay_order'), expected);
      expect(latest.fontSize, const NovelReaderSettings().fontSize);
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in [
    const Locale('zh'),
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  ]) {
    testWidgets(
      'settings remain scrollable at 320px and 2x text scale (${locale.toLanguageTag()})',
      (tester) async {
        var latest = const NovelReaderSettings(
          fontSize: 48,
          lineHeight: 3.0,
          paragraphSpacing: 64,
        );
        await _mount(
          tester,
          settings: latest,
          onChanged: (value) => latest = value,
          size: const Size(320, 640),
          textScale: 2,
          locale: locale,
        );
        expect(tester.takeException(), isNull);
        for (final key in [
          'novel-light-theme',
          'novel-dark-theme',
          'novel-theme-add',
          'novel-keep-screen-on',
          'reader-status-overlay-switch',
        ]) {
          final finder = find.byKey(ValueKey(key));
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          expect(finder, findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

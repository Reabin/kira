import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/novel_reader_settings.dart';
import 'package:kira/theme/novel_reader_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'reader_mode': 1,
      'theme_mode': 'system',
      'novel_reading_history_book': 'untouched history',
    });
    prefs = await SharedPreferences.getInstance();
  });

  test('idle queue does not retain a completed FakeAsync zone', () {
    for (var index = 0; index < 3; index++) {
      fakeAsync((async) {
        final settings = NovelReaderSettings(fontSize: 20.0 + index);
        var saved = false;
        var loaded = false;
        unawaited(
          settings.save(prefs: Future.value(prefs)).then((_) {
            saved = true;
          }),
        );
        unawaited(
          NovelReaderSettings.load(prefs: Future.value(prefs)).then((result) {
            expect(result, settings);
            loaded = true;
          }),
        );
        async.flushMicrotasks();
        expect(saved, isTrue, reason: 'save in FakeAsync zone $index');
        expect(loaded, isTrue, reason: 'load in FakeAsync zone $index');
      });
    }
  });

  test('defaults follow system light/dark bindings without any writes', () async {
    const defaults = NovelReaderSettings();
    expect(defaults.fontSize, 20);
    expect(defaults.lineHeight, 1.8);
    expect(defaults.paragraphSpacing, 16);
    expect(defaults.lightThemeId, 'white');
    expect(defaults.darkThemeId, 'dark');
    expect(defaults.customThemes, isEmpty);
    expect(defaults.keepScreenOn, isTrue);
    expect(
      await NovelReaderSettings.load(prefs: Future.value(prefs)),
      defaults,
    );
    expect(prefs.containsKey(NovelReaderSettings.storageKey), isFalse);
  });

  test('named themes, bindings, and false keepScreenOn round-trip', () async {
    final custom = NovelReaderCustomTheme(
      id: 'custom-1',
      name: '夜航',
      backgroundColor: 0xFF182331,
      textColor: 0xFFE8DFC7,
    );
    final settings = NovelReaderSettings(
      fontSize: 25,
      lineHeight: 1.05,
      paragraphSpacing: 3,
      lightThemeId: 'paper',
      darkThemeId: 'custom-1',
      keepScreenOn: false,
    ).upsertCustomTheme(custom);
    expect(NovelReaderSettings.fromJson(settings.toJson()), settings);
    await settings.save(prefs: Future.value(prefs));
    final restored = await NovelReaderSettings.load(
      prefs: Future.value(prefs),
    );
    expect(restored, settings);
    expect(restored.hashCode, settings.hashCode);
    expect(
      jsonDecode(prefs.getString(NovelReaderSettings.storageKey)!),
      settings.toJson(),
    );
  });

  test(
    'default persistence uses shared MockPrefs and touches only its key',
    () async {
      final settings = NovelReaderSettings(fontSize: 24).upsertCustomTheme(
        const NovelReaderCustomTheme(id: 'c9', name: '米黄'),
      );
      await settings.save();
      expect(await NovelReaderSettings.load(), settings);
      expect(NovelReaderSettings.storageKey, 'reader_novel_settings_v1');
      expect(prefs.get('reader_mode'), 1);
      expect(prefs.get('theme_mode'), 'system');
      expect(prefs.get('novel_reading_history_book'), 'untouched history');
      expect(prefs.getKeys(), {
        'reader_mode',
        'theme_mode',
        'novel_reading_history_book',
        NovelReaderSettings.storageKey,
      });
    },
  );

  test(
    'constructor and copyWith clamp values without modifying the original',
    () {
      const original = NovelReaderSettings(
        darkThemeId: 'green',
        keepScreenOn: false,
      );
      final lower = original.copyWith(
        fontSize: 1,
        lineHeight: 0.1,
        paragraphSpacing: -9,
      );
      expect(lower.fontSize, 10);
      expect(lower.lineHeight, 1.0);
      expect(lower.paragraphSpacing, 0);
      expect(lower.darkThemeId, 'green');
      expect(lower.keepScreenOn, isFalse);
      final upper = NovelReaderSettings(
        fontSize: 100,
        lineHeight: 4,
        paragraphSpacing: 1000,
      );
      expect(upper.fontSize, 48);
      expect(upper.lineHeight, 3.0);
      expect(upper.paragraphSpacing, 64);
      expect(original.fontSize, 20);
      expect(original.copyWith(), original);
      expect(original.copyWith(keepScreenOn: true).keepScreenOn, isTrue);
    },
  );

  test('valid range endpoints and fractional settings are retained', () {
    const min = NovelReaderSettings(
      fontSize: 10,
      lineHeight: 1.0,
      paragraphSpacing: 0,
    );
    const max = NovelReaderSettings(
      fontSize: 48,
      lineHeight: 3.0,
      paragraphSpacing: 64,
    );
    final fractional = NovelReaderSettings(
      fontSize: 20.5,
      lineHeight: 1.05,
      paragraphSpacing: 16.25,
    );
    for (final settings in [min, max, fractional]) {
      expect(NovelReaderSettings.fromJson(settings.toJson()), settings);
    }
    expect(fractional.fontSize, 20.5);
    expect(fractional.lineHeight, 1.05);
    expect(fractional.paragraphSpacing, 16.25);
  });

  test('light and dark bindings stay independent', () {
    final settings = NovelReaderSettings(
      lightThemeId: 'green',
      darkThemeId: 'paper',
    );
    final lightOnly = settings.copyWith(lightThemeId: 'white');
    expect(lightOnly.darkThemeId, 'paper');
    final darkOnly = settings.copyWith(darkThemeId: 'dark');
    expect(darkOnly.lightThemeId, 'green');
  });

  test('unknown or deleted theme ids fall back per mode', () {
    final settings = NovelReaderSettings(
      lightThemeId: 'missing',
      darkThemeId: 'paper',
    );
    expect(settings.themeIdFor(dark: false), 'white');
    expect(settings.themeIdFor(dark: true), 'paper');
    final removed = settings
        .upsertCustomTheme(
          const NovelReaderCustomTheme(id: 'gone', name: '临时'),
        )
        .copyWith(darkThemeId: 'gone')
        .removeCustomTheme('gone');
    expect(removed.themeIdFor(dark: true), 'dark');
  });

  test('rename keeps both bindings, upsert replaces by id, remove drops only one', () {
    const a = NovelReaderCustomTheme(id: 'a', name: 'A');
    const b = NovelReaderCustomTheme(id: 'b', name: 'B');
    final base = const NovelReaderSettings().upsertCustomTheme(a).upsertCustomTheme(b);
    final bound = base.copyWith(lightThemeId: 'a', darkThemeId: 'b');
    final renamed = bound.upsertCustomTheme(const NovelReaderCustomTheme(id: 'a', name: '甲'));
    expect(renamed.customThemes.map((t) => '${t.id}:${t.name}'), ['b:B', 'a:甲']);
    expect(renamed.lightThemeId, 'a');
    expect(renamed.darkThemeId, 'b');
    final removedA = renamed.removeCustomTheme('a');
    expect(removedA.customThemes.single.id, 'b');
    // 绑定保留原 ID，展示时由 themeIdFor 兜底回退。
    expect(removedA.themeIdFor(dark: false), 'white');
    expect(removedA.darkThemeId, 'b');
  });

  test('invalid custom theme entries are dropped on load', () async {
    await prefs.setString(
      NovelReaderSettings.storageKey,
      jsonEncode({
        'fontSize': 22,
        'customThemes': [
          {'id': '', 'name': '无 id'},
          {'id': 'ok', 'name': ''},
          {'id': 'ok', 'name': '有效', 'backgroundColor': 0xFF101820, 'textColor': 0xFFEAE7DC},
          {'id': 'ok', 'name': '重复'},
          'not-a-map',
        ],
      }),
    );
    final settings = await NovelReaderSettings.load(
      prefs: Future.value(prefs),
    );
    expect(settings.customThemes, hasLength(1));
    expect(settings.customThemes.single.id, 'ok');
    expect(settings.customThemes.single.name, '有效');
  });

  test('legacy single custom colors migrate into a named theme and both bindings', () async {
    await prefs.setString(
      NovelReaderSettings.storageKey,
      jsonEncode({
        'fontSize': 30,
        'theme': 'custom',
        'customBackgroundColor': 0xFF182331,
        'customTextColor': 0xFFE8DFC7,
        'keepScreenOn': false,
      }),
    );
    final settings = await NovelReaderSettings.load(
      prefs: Future.value(prefs),
    );
    expect(settings.fontSize, 30);
    expect(settings.customThemes, hasLength(1));
    expect(settings.customThemes.single.id, NovelReaderSettings.legacyCustomThemeId);
    expect(settings.customThemes.single.backgroundColor, 0xFF182331);
    expect(settings.customThemes.single.textColor, 0xFFE8DFC7);
    expect(settings.lightThemeId, NovelReaderSettings.legacyCustomThemeId);
    expect(settings.darkThemeId, NovelReaderSettings.legacyCustomThemeId);
    expect(settings.keepScreenOn, isFalse);
  });

  test('legacy preset theme seeds both bindings', () async {
    await prefs.setString(
      NovelReaderSettings.storageKey,
      jsonEncode({'theme': 'green'}),
    );
    final settings = await NovelReaderSettings.load(
      prefs: Future.value(prefs),
    );
    expect(settings.lightThemeId, 'green');
    expect(settings.darkThemeId, 'green');
    expect(settings.customThemes, isEmpty);
  });

  test(
    'legacy settings load new defaults without rewriting saved values',
    () async {
      final legacy = {
        'fontSize': 31.5,
        'lineHeight': 2.0,
        'paragraphSpacing': 20,
        'theme': 'paper',
        'keepScreenOn': false,
      };
      final raw = jsonEncode(legacy);
      await prefs.setString(NovelReaderSettings.storageKey, raw);
      final settings = await NovelReaderSettings.load(
        prefs: Future.value(prefs),
      );
      expect(settings.fontSize, 31.5);
      expect(settings.lineHeight, 2);
      expect(settings.paragraphSpacing, 20);
      expect(settings.lightThemeId, 'paper');
      expect(settings.darkThemeId, 'paper');
      expect(settings.keepScreenOn, isFalse);
      expect(prefs.getString(NovelReaderSettings.storageKey), raw);
    },
  );

  test('palette resolves by system brightness, not the app theme', () {
    final settings = NovelReaderSettings(
      lightThemeId: 'paper',
      darkThemeId: 'dark',
    );
    final light = NovelReaderPalette.resolve(
      settings,
      Brightness.light,
    );
    expect(
      light.background,
      const Color(NovelReaderSettings.defaultCustomBackgroundColor),
    );
    final dark = NovelReaderPalette.resolve(settings, Brightness.dark);
    expect(dark.background, const Color(0xFF000000));
    // 改浅色绑定为 white：浅色模式即用白底（深色绑定不受影响）。
    final lightWhite = NovelReaderPalette.resolve(
      settings.copyWith(lightThemeId: 'white'),
      Brightness.light,
    );
    expect(lightWhite.background, const Color(0xFFFFFFFF));
  });

  test('custom palette colors and brightness derivation', () {
    final settings = NovelReaderSettings(
      lightThemeId: 'custom-1',
      darkThemeId: 'custom-2',
    ).upsertCustomTheme(
      const NovelReaderCustomTheme(
        id: 'custom-1',
        name: '米色',
        backgroundColor: 0xFFF5F5E8,
        textColor: 0xFF202020,
      ),
    ).upsertCustomTheme(
      const NovelReaderCustomTheme(
        id: 'custom-2',
        name: '夜航',
        backgroundColor: 0xFF152337,
        textColor: 0xFFE8DDBA,
      ),
    );
    final light = NovelReaderPalette.resolve(settings, Brightness.light);
    expect(light.background, const Color(0xFFF5F5E8));
    expect(light.foreground, const Color(0xFF202020));
    expect(
      light.applyTo(ThemeData()).brightness,
      Brightness.light,
    );
    final dark = NovelReaderPalette.resolve(settings, Brightness.dark);
    expect(dark.background, const Color(0xFF152337));
    expect(
      dark.applyTo(ThemeData()).brightness,
      Brightness.dark,
    );
    expect(
      dark.applyTo(ThemeData()).textTheme.bodyLarge?.color,
      const Color(0xFFE8DDBA),
    );
  });

  test(
    'fromJson supports partial data and safely parses malformed field types',
    () {
      expect(NovelReaderSettings.fromJson({}), const NovelReaderSettings());
      final malformed = NovelReaderSettings.fromJson({
        'fontSize': '24.5',
        'lineHeight': [],
        'paragraphSpacing': {'unexpected': true},
        'lightThemeId': 9,
        'keepScreenOn': 'false',
      });
      expect(malformed.fontSize, 24.5);
      expect(malformed.lineHeight, 1.8);
      expect(malformed.paragraphSpacing, 16);
      expect(malformed.lightThemeId, '9');
      expect(
        malformed.themeIdFor(dark: false),
        NovelReaderSettings.defaultLightThemeId,
      );
      expect(malformed.keepScreenOn, isTrue);
      final clamped = NovelReaderSettings.fromJson({
        'fontSize': '-100',
        'lineHeight': 9000,
        'paragraphSpacing': -500,
      });
      expect(clamped.fontSize, 10);
      expect(clamped.lineHeight, 3.0);
      expect(clamped.paragraphSpacing, 0);
    },
  );

  test('NaN uses defaults and infinite values cannot escape valid ranges', () {
    const nan = NovelReaderSettings(
      fontSize: double.nan,
      lineHeight: double.nan,
      paragraphSpacing: double.nan,
    );
    expect(nan, const NovelReaderSettings());
    for (final value in [
      double.infinity,
      double.negativeInfinity,
      double.nan,
    ]) {
      final settings = NovelReaderSettings.fromJson({
        'fontSize': value,
        'lineHeight': value,
        'paragraphSpacing': value,
      });
      expect(settings.fontSize, inInclusiveRange(10, 48));
      expect(settings.lineHeight, inInclusiveRange(1.0, 3.0));
      expect(settings.paragraphSpacing, inInclusiveRange(0, 64));
      expect(() => jsonEncode(settings.toJson()), returnsNormally);
    }
  });

  test(
    'corrupt JSON and wrong root types load defaults without rewriting prefs',
    () async {
      for (final raw in ['{', '[]', 'null', '7', '"text"']) {
        await prefs.setString(NovelReaderSettings.storageKey, raw);
        expect(
          await NovelReaderSettings.load(prefs: Future.value(prefs)),
          const NovelReaderSettings(),
        );
        expect(prefs.get(NovelReaderSettings.storageKey), raw);
      }
      await prefs.setBool(NovelReaderSettings.storageKey, true);
      expect(
        await NovelReaderSettings.load(prefs: Future.value(prefs)),
        const NovelReaderSettings(),
      );
      expect(prefs.get(NovelReaderSettings.storageKey), isTrue);
    },
  );

  test(
    'external restoration and removal are visible on the next load',
    () async {
      const original = NovelReaderSettings(fontSize: 24);
      await original.save(prefs: Future.value(prefs));
      expect(
        await NovelReaderSettings.load(prefs: Future.value(prefs)),
        original,
      );
      final restored = NovelReaderSettings(
        fontSize: 29,
        darkThemeId: 'green',
      );
      await prefs.setString(
        NovelReaderSettings.storageKey,
        jsonEncode(restored.toJson()),
      );
      expect(
        await NovelReaderSettings.load(prefs: Future.value(prefs)),
        restored,
      );
      await prefs.remove(NovelReaderSettings.storageKey);
      expect(
        await NovelReaderSettings.load(prefs: Future.value(prefs)),
        const NovelReaderSettings(),
      );
    },
  );

  test(
    'rapid saves and a following load remain ordered with delayed prefs',
    () async {
      final delayed = Completer<SharedPreferences>();
      final first = const NovelReaderSettings(
        fontSize: 21,
      ).save(prefs: delayed.future);
      const latest = NovelReaderSettings(fontSize: 28);
      final second = latest.save(prefs: Future.value(prefs));
      final reading = NovelReaderSettings.load(prefs: Future.value(prefs));
      await Future<void>.delayed(Duration.zero);
      expect(prefs.containsKey(NovelReaderSettings.storageKey), isFalse);
      delayed.complete(prefs);
      await Future.wait([first, second]);
      expect(await reading, latest);
    },
  );

  test(
    'a failed save is reported but subsequent save and load still succeed',
    () async {
      final failure = Completer<SharedPreferences>();
      final saving = const NovelReaderSettings().save(prefs: failure.future);
      final expectation = expectLater(saving, throwsStateError);
      failure.completeError(StateError('MockPrefs unavailable'));
      await expectation;
      final settings = NovelReaderSettings(lightThemeId: 'paper');
      await settings.save(prefs: Future.value(prefs));
      expect(
        await NovelReaderSettings.load(prefs: Future.value(prefs)),
        settings,
      );
    },
  );
}

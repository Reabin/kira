import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/backup/backup_category.dart';
import 'package:kira/models/theme_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _ModePreferences extends SharedPreferencesStorePlatform {
  final values = <String, Object>{};
  bool failWrite = false;
  Object? writeError;
  Completer<void>? writeGate;
  final writeStarted = Completer<void>();

  @override
  Future<Map<String, Object>> getAll() async => {...values};

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await writeGate?.future;
    final error = writeError;
    if (error != null) throw error;
    if (failWrite) return false;
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    values.clear();
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ThemeSettings settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = ThemeSettings()..resetPrefsCache();
    await settings.initFromPrefs(await SharedPreferences.getInstance());
  });

  tearDown(() {
    settings.resetPrefsCache();
    SharedPreferences.setMockInitialValues({});
  });

  test('history defaults to online and portable backup registers the bool', () {
    expect(settings.browseHistoryLocal, isFalse);
    expect(BackupSchema.typeOf('nav_browse_history_local'), 'bool');
    expect(
      BackupSchema.categoryOf('nav_browse_history_local'),
      BackupCategory.settings,
    );
  });

  test(
    'mode survives recreated prefs and only notifies when changed',
    () async {
      final backend = _ModePreferences();
      SharedPreferencesStorePlatform.instance = backend;
      settings.resetPrefsCache();
      await settings.initFromPrefs(await SharedPreferences.getInstance());
      var notified = 0;
      void listener() => notified++;
      settings.addListener(listener);
      addTearDown(() => settings.removeListener(listener));

      await settings.setBrowseHistoryLocal(true);
      await settings.setBrowseHistoryLocal(true);
      expect(notified, 1);
      expect(backend.values['flutter.nav_browse_history_local'], isTrue);

      // 换掉插件的 prefs 实例，模拟冷启动重新读取相同持久化后端。
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesStorePlatform.instance = backend;
      settings.resetPrefsCache();
      await settings.initFromPrefs(await SharedPreferences.getInstance());
      expect(settings.browseHistoryLocal, isTrue);
      await settings.setBrowseHistoryLocal(false);
      expect(backend.values['flutter.nav_browse_history_local'], isFalse);
    },
  );

  test(
    'init binds subsequent mode writes to the loaded preferences backend',
    () async {
      final oldBackend = _ModePreferences();
      SharedPreferencesStorePlatform.instance = oldBackend;
      settings.resetPrefsCache();
      await settings.initFromPrefs(await SharedPreferences.getInstance());
      await settings.setBrowseHistoryLocal(true);

      SharedPreferences.setMockInitialValues({});
      final newBackend = _ModePreferences();
      SharedPreferencesStorePlatform.instance = newBackend;
      await settings.initFromPrefs(await SharedPreferences.getInstance());
      await settings.setBrowseHistoryLocal(true);

      expect(newBackend.values['flutter.nav_browse_history_local'], isTrue);
    },
  );

  test(
    'failed persistence does not update mode or notify and can be retried',
    () async {
      final backend = _ModePreferences()..failWrite = true;
      SharedPreferencesStorePlatform.instance = backend;
      settings.resetPrefsCache();
      final prefs = await SharedPreferences.getInstance();
      await settings.initFromPrefs(prefs);
      var notified = 0;
      void listener() => notified++;
      settings.addListener(listener);
      addTearDown(() => settings.removeListener(listener));

      await expectLater(settings.setBrowseHistoryLocal(true), throwsStateError);
      expect(settings.browseHistoryLocal, isFalse);
      expect(notified, 0);
      expect(prefs.getBool('nav_browse_history_local'), isNull);
      backend.failWrite = false;
      await settings.setBrowseHistoryLocal(true);
      expect(settings.browseHistoryLocal, isTrue);
      expect(notified, 1);
    },
  );

  test('mode serializes rapid switches so the last call persists', () async {
    final backend = _ModePreferences()..writeGate = Completer<void>();
    SharedPreferencesStorePlatform.instance = backend;
    settings.resetPrefsCache();
    await settings.initFromPrefs(await SharedPreferences.getInstance());

    final local = settings.setBrowseHistoryLocal(true);
    await backend.writeStarted.future;
    final online = settings.setBrowseHistoryLocal(false);
    backend.writeGate!.complete();
    await Future.wait([local, online]);

    expect(settings.browseHistoryLocal, isFalse);
    expect(backend.values['flutter.nav_browse_history_local'], isFalse);
  });

  test('mode persistence propagates the original exception', () async {
    final error = StateError('platform unavailable');
    final backend = _ModePreferences()..writeError = error;
    SharedPreferencesStorePlatform.instance = backend;
    settings.resetPrefsCache();
    await settings.initFromPrefs(await SharedPreferences.getInstance());

    await expectLater(
      settings.setBrowseHistoryLocal(true),
      throwsA(same(error)),
    );
    expect(settings.browseHistoryLocal, isFalse);
  });
}

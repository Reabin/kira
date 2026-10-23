import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/utils/app_icon_switcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.caolib.kira/app_icon');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final user = UserManager();
  final calls = <MethodCall>[];
  int? platformIndex;
  bool failRead = false;
  bool failWrite = false;
  Completer<void>? pendingWrite;

  setUp(() {
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({'app_logging_enabled': false});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    AppIconSwitcher.debugSupportedPlatformOverride = false;
    calls.clear();
    platformIndex = 0;
    failRead = false;
    failWrite = false;
    pendingWrite = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getAppIconIndex':
          if (failRead) throw PlatformException(code: 'read_icon_failed');
          return platformIndex;
        case 'setAppIcon':
          if (failWrite) throw PlatformException(code: 'write_icon_failed');
          await pendingWrite?.future;
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    AppIconSwitcher.debugSupportedPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
    teardownSecureCredentialStoreForTest();
  });

  test(
    'desktop logo defaults to 1 and shares both write paths without channel calls',
    () async {
      await user.init();
      expect(user.logoIndex, 1);
      expect(user.theme.logoIndex, 1);
      final snapshots = <(int, int, String)>[];
      void listener() => snapshots.add((
        user.logoIndex,
        user.theme.logoIndex,
        user.appLogoPath,
      ));
      user.addListener(listener);
      addTearDown(() => user.removeListener(listener));
      final prefs = await SharedPreferences.getInstance();

      await user.setLogoIndex(-10);
      expect(user.theme.logoIndex, 0);
      expect(prefs.getInt('logo_index'), 0);
      expect(snapshots, [(0, 0, UserManager.appLogoPaths[0])]);
      snapshots.clear();
      await user.theme.setLogoIndex(10);
      expect(user.logoIndex, 1);
      expect(prefs.getInt('logo_index'), 1);
      expect(snapshots, [(1, 1, UserManager.appLogoPaths[1])]);
      snapshots.clear();
      await user.setLogoIndex(10);
      expect(snapshots, isEmpty);
      expect(calls, isEmpty);

      teardownSecureCredentialStoreForTest();
      for (var boot = 0; boot < 3; boot++) {
        user.theme.resetPrefsCache();
        await user.init(persistMigrations: false);
        expect(user.logoIndex, 1);
        expect(user.theme.logoIndex, 1);
      }
      expect(calls, isEmpty);
    },
  );

  for (final target in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      '$target startup prefers the platform icon without rewriting the saved preference',
      () async {
        debugDefaultTargetPlatformOverride = target;
        AppIconSwitcher.debugSupportedPlatformOverride = true;
        SharedPreferences.setMockInitialValues({
          'logo_index': 1,
          'app_logging_enabled': false,
        });
        platformIndex = 0;
        await user.init(persistMigrations: false);
        expect(user.logoIndex, 0);
        expect(user.theme.logoIndex, 0);
        expect(user.appLogoPath, UserManager.appLogoPaths[0]);
        expect(calls.map((call) => call.method), ['getAppIconIndex']);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt('logo_index'), 1);
      },
    );

    test(
      '$target setter persists and notifies before the native switch finishes',
      () async {
        debugDefaultTargetPlatformOverride = target;
        AppIconSwitcher.debugSupportedPlatformOverride = true;
        platformIndex = 0;
        await user.init(persistMigrations: false);
        calls.clear();
        final prefs = await SharedPreferences.getInstance();
        final snapshots = <(int, int, int?)>[];
        final notified = Completer<void>();
        void listener() {
          snapshots.add((
            user.logoIndex,
            user.theme.logoIndex,
            prefs.getInt('logo_index'),
          ));
          if (!notified.isCompleted) notified.complete();
        }

        user.addListener(listener);
        addTearDown(() => user.removeListener(listener));
        final pending = Completer<void>();
        pendingWrite = pending;
        addTearDown(() {
          if (!pending.isCompleted) pending.complete();
        });
        var finished = false;
        final writing = user.setLogoIndex(1).then((_) => finished = true);
        await notified.future;
        expect(snapshots, [(1, 1, 1)]);
        expect(finished, isFalse);
        pending.complete();
        await writing;
        expect(calls.map((call) => call.method), ['setAppIcon']);
        expect(calls.single.arguments, {'index': 1});

        calls.clear();
        snapshots.clear();
        await user.theme.setLogoIndex(1);
        expect(calls, isEmpty);
        expect(snapshots, isEmpty);
        await user.theme.setLogoIndex(0);
        expect(user.logoIndex, 0);
        expect(calls.single.arguments, {'index': 0});
        expect(snapshots, [(0, 0, 0)]);
      },
    );
  }

  for (final index in [-5, 5]) {
    test('platform logo index $index is clamped without saving it', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppIconSwitcher.debugSupportedPlatformOverride = true;
      SharedPreferences.setMockInitialValues({
        'logo_index': 1,
        'app_logging_enabled': false,
      });
      platformIndex = index;
      await user.init(persistMigrations: false);
      final expected = index < 0 ? 0 : 1;
      expect(user.logoIndex, expected);
      expect(user.theme.logoIndex, expected);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('logo_index'), 1);
    });
  }

  test('null native icon retains the channel default of 0', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AppIconSwitcher.debugSupportedPlatformOverride = true;
    platformIndex = null;
    await user.init(persistMigrations: false);
    expect(user.logoIndex, 0);
    expect(user.theme.logoIndex, 0);
  });

  test(
    'native read failure retains the saved icon and does not fail initialization',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppIconSwitcher.debugSupportedPlatformOverride = true;
      failRead = true;
      SharedPreferences.setMockInitialValues({
        'logo_index': 1,
        'app_logging_enabled': false,
      });
      await user.init(persistMigrations: false);
      expect(user.logoIndex, 1);
      expect(user.theme.logoIndex, 1);
      expect(calls.single.method, 'getAppIconIndex');
    },
  );

  test(
    'native switch failure retains the committed preference and state',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppIconSwitcher.debugSupportedPlatformOverride = true;
      platformIndex = 0;
      await user.init(persistMigrations: false);
      calls.clear();
      failWrite = true;
      await user.setLogoIndex(1);
      expect(user.logoIndex, 1);
      expect(user.theme.logoIndex, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('logo_index'), 1);
      expect(calls.single.method, 'setAppIcon');
    },
  );

  test(
    'settings reload re-reads the actual icon without applying an imported icon',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppIconSwitcher.debugSupportedPlatformOverride = true;
      platformIndex = 1;
      await user.init(persistMigrations: false);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('logo_index', 0);
      calls.clear();
      await user.init(persistMigrations: false);
      expect(user.logoIndex, 1);
      expect(user.theme.logoIndex, 1);
      expect(prefs.getInt('logo_index'), 0);
      expect(calls.map((call) => call.method), ['getAppIconIndex']);
    },
  );
}

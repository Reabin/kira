import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/utils/display_mode_preference.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const displayChannel = MethodChannel('flutter_display_mode');
  const windowChannel = MethodChannel('io.github.caolib.kira/display_mode');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(displayChannel, null);
    messenger.setMockMethodCallHandler(windowChannel, null);
  });

  test('candidate pool is capped by the device maximum', () {
    expect(DisplayModePreference.refreshRates(const [60, 120]), [120, 90, 60]);
    expect(DisplayModePreference.refreshRates(const [60, 144]), [
      144,
      120,
      90,
      60,
    ]);
    expect(DisplayModePreference.refreshRates(const [60, 165]), [
      165,
      144,
      120,
      90,
      60,
    ]);
  });

  test('sub-60 rates are dropped and unusual rates keep their cap', () {
    expect(DisplayModePreference.refreshRates(const [15, 48, 90, 120]), [
      120,
      90,
      60,
    ]);
    expect(DisplayModePreference.refreshRates(const [240]), [
      240,
      165,
      144,
      120,
      90,
      60,
    ]);
  });

  test('empty device report keeps the full pool instead of collapsing', () {
    expect(DisplayModePreference.refreshRates(const []), [
      165,
      144,
      120,
      90,
      60,
    ]);
  });

  test('loadDeviceRefreshRates rounds and sorts the native report', () async {
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      expect(call.method, 'getSupportedRefreshRates');
      return [59.94, 60.0, 119.88, 144.0];
    });
    expect(await DisplayModePreference.loadDeviceRefreshRates(), [
      144,
      120,
      60,
    ]);
  });

  test('loadDeviceRefreshRates returns null when the native read fails', () {
    // No windowChannel handler: invoking throws, the getter swallows it.
    expect(DisplayModePreference.loadDeviceRefreshRates(), completion(isNull));
  });

  test('loadRefreshRates prefers the native report over enumeration', () async {
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'getSupportedRefreshRates') return [60.0, 144.0];
      return null;
    });
    messenger.setMockMethodCallHandler(displayChannel, (call) async {
      if (call.method == 'getSupportedModes') {
        return [
          {'id': 1, 'width': 1080, 'height': 2400, 'refreshRate': 60.0},
          {'id': 2, 'width': 1080, 'height': 2400, 'refreshRate': 120.0},
        ];
      }
      return null;
    });

    expect(await DisplayModePreference.loadRefreshRates(), [144, 120, 90, 60]);
  });

  test(
    'loadRefreshRates falls back to enumeration without the native report',
    () async {
      messenger.setMockMethodCallHandler(displayChannel, (call) async {
        if (call.method == 'getSupportedModes') {
          return [
            {'id': 1, 'width': 1080, 'height': 2400, 'refreshRate': 60.0},
            {'id': 2, 'width': 1080, 'height': 2400, 'refreshRate': 120.0},
          ];
        }
        return null;
      });

      expect(await DisplayModePreference.loadRefreshRates(), [120, 90, 60]);
    },
  );

  test(
    'a total read failure propagates so callers keep their last list',
    () async {
      messenger.setMockMethodCallHandler(displayChannel, (_) async {
        throw PlatformException(code: 'unavailable');
      });
      await expectLater(
        DisplayModePreference.loadRefreshRates(),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  for (final rate in [0.0, -1.0, 0.1, double.nan, double.infinity]) {
    test('unknown active rate $rate has no numeric label', () async {
      messenger.setMockMethodCallHandler(displayChannel, (_) async {
        return {'id': 0, 'width': 1080, 'height': 2400, 'refreshRate': rate};
      });
      expect(await DisplayModePreference.activeRefreshRate(), isNull);
    });
  }

  test('active refresh rate is rounded from the platform reading', () async {
    messenger.setMockMethodCallHandler(displayChannel, (call) async {
      expect(call.method, 'getActiveMode');
      return {'id': 2, 'width': 1080, 'height': 2400, 'refreshRate': 119.88};
    });
    expect(await DisplayModePreference.activeRefreshRate(), 120);
  });

  test(
    'a native 144Hz report stays requestable via the window fallback',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(displayChannel, (call) async {
        calls.add(call);
        if (call.method == 'getSupportedModes') {
          // Plugin enumeration omits 144Hz, as it does on some panels.
          return [
            {'id': 1, 'width': 1080, 'height': 2400, 'refreshRate': 60.0},
            {'id': 2, 'width': 1080, 'height': 2400, 'refreshRate': 120.0},
          ];
        }
        if (call.method == 'getActiveMode') {
          return {'id': 2, 'width': 1080, 'height': 2400, 'refreshRate': 120.0};
        }
        return null;
      });
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        calls.add(call);
        if (call.method == 'getSupportedRefreshRates') {
          return [60.0, 120.0, 144.0];
        }
        return null;
      });

      expect(await DisplayModePreference.loadRefreshRates(), [
        144,
        120,
        90,
        60,
      ]);
      expect(await DisplayModePreference.applyRefreshRate(144), isTrue);
      expect(calls[calls.length - 2].method, 'setPreferredMode');
      expect(calls[calls.length - 2].arguments, {'mode': 0});
      expect(calls.last.method, 'setPreferredRefreshRate');
      expect(calls.last.arguments, {'refreshRate': 144.0});
      // A successful request does not imply that Android adopted it.
      expect(await DisplayModePreference.activeRefreshRate(), 120);
    },
  );

  test('auto clears both preferences without requesting a maximum', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(displayChannel, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      calls.add(call);
      return null;
    });

    expect(await DisplayModePreference.applyRefreshRate(0), isTrue);
    expect(calls.map((call) => call.method), [
      'setPreferredMode',
      'setPreferredRefreshRate',
    ]);
    expect(calls.first.arguments, {'mode': 0});
    expect(calls.last.arguments, {'refreshRate': 0.0});
  });

  test(
    'enumerated 165Hz uses the mode matching the active resolution',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(displayChannel, (call) async {
        calls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        calls.add(call);
        return null;
      });

      expect(
        await DisplayModePreference.applyRefreshRate(
          165,
          modes: const [
            DisplayMode(id: 1, width: 1440, height: 3200, refreshRate: 165),
            DisplayMode(id: 2, width: 1080, height: 2400, refreshRate: 165),
          ],
          active: const DisplayMode(
            id: 3,
            width: 1080,
            height: 2400,
            refreshRate: 120,
          ),
        ),
        isTrue,
      );
      expect(calls.first.arguments, {'refreshRate': 0.0});
      expect(calls.last.arguments, {'mode': 2});
    },
  );

  test(
    'active read failures are not replaced with a requested value',
    () async {
      messenger.setMockMethodCallHandler(displayChannel, (_) async {
        throw PlatformException(code: 'unavailable');
      });
      await expectLater(
        DisplayModePreference.activeRefreshRate(),
        throwsA(isA<PlatformException>()),
      );
      expect(await DisplayModePreference.applyRefreshRate(165), isFalse);
    },
  );
}

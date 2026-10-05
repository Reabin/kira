import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/appearance_page.dart';
import 'package:kira/utils/font_manager.dart';
import 'package:kira/widgets/select_tile.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _Display {
  static const channel = MethodChannel('flutter_display_mode');
  static const windowChannel = MethodChannel(
    'io.github.caolib.kira/display_mode',
  );
  double active = 60;
  List<double> supportedRates = [60, 120];

  /// Native `getSupportedRefreshRates` payload; falls back to
  /// [supportedRates] when left null.
  List<double>? nativeRates;
  int reads = 0;
  bool failActive = false;
  bool failSupported = false;
  bool failNativeRates = false;
  Completer<Map<String, Object>>? pendingRead;
  final requests = <MethodCall>[];

  Map<String, Object> mode(double rate) => {
    'id': rate == 60 ? 1 : 2,
    'width': 1080,
    'height': 2400,
    'refreshRate': rate,
  };

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'getSupportedModes':
        if (failSupported) throw PlatformException(code: 'unavailable');
        return [for (final rate in supportedRates) mode(rate)];
      case 'getSupportedRefreshRates':
        if (failNativeRates) {
          throw PlatformException(
            code: 'display_mode_unavailable',
            message: 'NoSuchMethodError: display API unavailable',
          );
        }
        if (failSupported) throw PlatformException(code: 'unavailable');
        return nativeRates ?? supportedRates;
      case 'getActiveMode':
        reads++;
        if (failActive) throw PlatformException(code: 'unavailable');
        final pending = pendingRead;
        if (pending != null) {
          pendingRead = null;
          return pending.future;
        }
        return mode(active);
      case 'setPreferredMode':
      case 'setPreferredRefreshRate':
        requests.add(call);
        return null;
      default:
        throw MissingPluginException(call.method);
    }
  }
}

final _tile = find.widgetWithText(ListTile, '屏幕刷新率');
final _select = find.descendant(
  of: _tile,
  matching: find.byType(SelectTile<int>),
);

Future<void> _showPage(WidgetTester tester) async {
  await tester.pumpWidget(
    wrapWithApp(const AppearancePage(), wrapInScaffold: false),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    _tile,
    400,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  // Drain the font card's unrelated directory scan outside fake async.
  await tester.runAsync(() => FontManager().listDownloadedFonts());
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(_select);
  await tester.pumpAndSettle();
}

Future<void> _tick(WidgetTester tester, [int seconds = 1]) async {
  await tester.pump(Duration(seconds: seconds));
  await tester.pump();
  await tester.pump(); // SelectTile refreshes its open overlay after layout.
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  late _Display display;
  late Directory directory;
  late PathProviderPlatform oldPaths;

  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({});
    await UserManager().init();
    directory = await Directory.systemTemp.createTemp(
      'kira_refresh_rate_test_',
    );
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    FontManager().reloadFromPrefs();
    await FontManager().listDownloadedFonts();
    display = _Display();
    messenger.setMockMethodCallHandler(_Display.channel, display.handle);
    messenger.setMockMethodCallHandler(_Display.windowChannel, display.handle);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_Display.channel, null);
    messenger.setMockMethodCallHandler(_Display.windowChannel, null);
    teardownSecureCredentialStoreForTest();
    FontManager().reloadFromPrefs();
    PathProviderPlatform.instance = oldPaths;
    directory.deleteSync(recursive: true);
  });

  testWidgets('auto capsule reads 60/120Hz and keeps the open menu current', (
    tester,
  ) async {
    await _showPage(tester);
    expect(find.text('自动 · 60Hz'), findsOneWidget);
    expect(tester.widget<ListTile>(_tile).subtitle, isNull);
    final l10n = AppLocalizations.of(tester.element(_tile))!;
    expect(find.text(l10n.appearanceRefreshRateDesc), findsNothing);
    expect(display.requests, isEmpty);

    await _openMenu(tester);
    expect(find.text('60Hz（当前）'), findsOneWidget);
    expect(find.text('120 Hz'), findsOneWidget);
    expect(find.text('90 Hz'), findsOneWidget);
    expect(find.text('144 Hz'), findsNothing);
    expect(find.text('165 Hz'), findsNothing);
    display.active = 120;
    await _tick(tester);
    expect(find.text('自动 · 120Hz'), findsOneWidget);
    expect(find.text('120Hz（当前）'), findsOneWidget);
    expect(find.text('60Hz（当前）'), findsNothing);
    expect(display.requests, isEmpty);

    display.active = 60;
    await _tick(tester);
    expect(find.text('自动 · 60Hz'), findsOneWidget);
    expect(find.text('60Hz（当前）'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a rejected request is never marked active and auto clears it', (
    tester,
  ) async {
    // Native report knows the 144Hz panel; plugin enumeration omits 144.
    display.supportedRates = [60, 120];
    display.nativeRates = [60, 120, 144];
    display.active = 120;
    await _showPage(tester);
    await _openMenu(tester);
    final oldRead = Completer<Map<String, Object>>();
    display.pendingRead = oldRead;
    await _tick(tester);
    final before = display.reads;
    await tester.tap(find.text('144 Hz'));
    await tester.pumpAndSettle();
    expect(UserManager().displayModeRefreshRate, 144);
    expect(display.requests.last.arguments, {'refreshRate': 144.0});
    expect(display.reads, greaterThan(before + 1)); // apply + actual read-back
    expect(find.text('144Hz（当前）'), findsNothing);
    oldRead.complete(display.mode(60));
    await tester.pump();
    await _openMenu(tester);
    expect(find.text('120Hz（当前）'), findsOneWidget);
    expect(find.text('60Hz（当前）'), findsNothing);

    await tester.tap(find.text('自动（跟随系统）'));
    await tester.pumpAndSettle();
    expect(UserManager().displayModeRefreshRate, 0);
    expect(display.requests[display.requests.length - 2].arguments, {
      'mode': 0,
    });
    expect(display.requests.last.arguments, {'refreshRate': 0.0});
    expect(find.text('自动 · 120Hz'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'read-back observes a delayed native switch rather than assuming success',
    (tester) async {
      await _showPage(tester);
      await _openMenu(tester);
      await tester.tap(find.text('120 Hz'));
      await tester.pumpAndSettle();
      expect(find.text('120Hz（当前）'), findsNothing);
      await _openMenu(tester);
      expect(find.text('60Hz（当前）'), findsOneWidget);
      display.active = 120;
      await _tick(tester);
      expect(find.text('60Hz（当前）'), findsNothing);
      expect(find.text('120Hz（当前）'), findsNWidgets(2)); // capsule + menu
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unknown or failed reads fall back to auto and recover without a spinner',
    (tester) async {
      display.failSupported = true;
      display.failActive = true;
      await _showPage(tester);
      expect(
        find.descendant(of: _select, matching: find.text('自动')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _tile,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      await _openMenu(tester);
      // The device could not be inspected: keep the full pool, never a
      // collapsed list.
      expect(find.text('165 Hz'), findsOneWidget);
      expect(find.text('144 Hz'), findsOneWidget);
      expect(find.text('120 Hz'), findsOneWidget);
      expect(find.text('90 Hz'), findsOneWidget);
      expect(find.text('60 Hz'), findsOneWidget);
      await tester.tapAt(const Offset(10, 100));
      await tester.pumpAndSettle();

      display.failActive = false;
      display.active = 120;
      await _tick(tester, 5);
      expect(find.text('自动 · 120Hz'), findsOneWidget);
      display.active = 0;
      await _tick(tester);
      expect(
        find.descendant(of: _select, matching: find.text('自动')),
        findsOneWidget,
      );
      expect(find.textContaining('0Hz'), findsNothing);
      display.active = 60;
      await _tick(tester);
      expect(find.text('自动 · 60Hz'), findsOneWidget);
      display.failActive = true;
      await _tick(tester);
      expect(find.text('自动 · 60Hz'), findsNothing);
      expect(
        find.descendant(of: _select, matching: find.text('自动')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'native compatibility errors leave the page and refresh-rate picker usable',
    (tester) async {
      display.failNativeRates = true;
      await _showPage(tester);
      expect(find.text('自动 · 60Hz'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(display.requests, isEmpty);

      await _openMenu(tester);
      expect(find.text('120 Hz'), findsOneWidget);
      expect(find.text('90 Hz'), findsOneWidget);
      expect(find.text('60Hz（当前）'), findsOneWidget);
      expect(find.text('165 Hz'), findsNothing);
      await tester.tap(find.text('120 Hz'));
      await tester.pumpAndSettle();
      expect(UserManager().displayModeRefreshRate, 120);
      expect(display.requests.last.method, 'setPreferredMode');
      expect(display.requests.last.arguments, {'mode': 2});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('device cap keeps the right rates when enumeration is empty', (
    tester,
  ) async {
    // The plugin's mode list is empty (common on VRR panels) but the native
    // report knows the 120Hz panel — 144/165 must stay hidden.
    display.supportedRates = const [];
    display.nativeRates = [60, 90, 120];
    await _showPage(tester);
    await _openMenu(tester);
    expect(find.text('120 Hz'), findsOneWidget);
    expect(find.text('90 Hz'), findsOneWidget);
    expect(find.text('60Hz（当前）'), findsOneWidget);
    expect(find.text('144 Hz'), findsNothing);
    expect(find.text('165 Hz'), findsNothing);

    await tester.tap(find.text('90 Hz'));
    await tester.pumpAndSettle();
    expect(UserManager().displayModeRefreshRate, 90);
    expect(display.requests.last.arguments, {'refreshRate': 90.0});
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'polling stops in background and ignores stale responses after resuming',
    (tester) async {
      await _showPage(tester);
      final oldRead = Completer<Map<String, Object>>();
      display.pendingRead = oldRead;
      await _tick(tester);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final before = display.reads;
      display.active = 120;
      await _tick(tester, 5);
      expect(display.reads, before);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('自动 · 120Hz'), findsOneWidget);
      oldRead.complete(display.mode(60));
      await tester.pump();
      expect(find.text('自动 · 120Hz'), findsOneWidget);
      final resumedReads = display.reads;
      await _tick(tester);
      expect(display.reads, resumedReads + 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('covered routes stop polling and resume with a fresh reading', (
    tester,
  ) async {
    await _showPage(tester);
    final navigator = Navigator.of(tester.element(_tile));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('other')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = display.reads;
    display.active = 120;
    await _tick(tester, 5);
    expect(display.reads, before);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('自动 · 120Hz'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dispose cancels polling even with an in-flight platform read', (
    tester,
  ) async {
    await _showPage(tester);
    final pending = Completer<Map<String, Object>>();
    display.pendingRead = pending;
    await _tick(tester);
    final before = display.reads;
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(display.mode(120));
    await _tick(tester, 5);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _tick(tester, 5);
    expect(display.reads, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'auto label fits a 320px screen and has a Traditional Chinese label',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      display.active = 120;
      await _showPage(tester);
      final tileRect = tester.getRect(_tile);
      final selectRect = tester.getRect(_select);
      expect(selectRect.left, greaterThan(tileRect.left));
      expect(selectRect.right, lessThanOrEqualTo(tileRect.right));
      expect(find.text('自动 · 120Hz'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final traditional = await AppLocalizations.delegate.load(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      );
      expect(traditional.appearanceAutoRefreshRate(120), '自動 · 120Hz');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

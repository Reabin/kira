import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/about_page.dart';
import 'package:kira/utils/app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

Map<String, Object> _release({bool beta = false}) => {
  'tag_name': beta ? 'CI' : 'v1.1.0',
  'name': beta ? 'Beta build' : 'Stable release',
  'body': 'Release notes',
  'html_url': 'https://example.com/releases',
  'assets': [
    for (final suffix in [
      'windows.exe',
      'arm64-v8a.apk',
      'macos.dmg',
      'linux.AppImage',
      'ios.ipa',
    ])
      {
        'name': 'kira-1.1.0+2-$suffix',
        'browser_download_url': 'https://example.com/kira-1.1.0+2-$suffix',
        'size': 1024,
      },
  ],
};

void _setInstalledBuild(String build) {
  PackageInfo.setMockInitialValues(
    appName: 'Kira',
    packageName: 'com.example.kira',
    version: '1.0.0',
    buildNumber: build,
    buildSignature: '',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <(RequestOptions, RequestInterceptorHandler)>[];
  late Interceptor interceptor;

  setUp(() async {
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({});
    await UserManager().init();
    _setInstalledBuild('1');
    AppUpdateService.state.value = const AppUpdateState.idle();
    AppUpdateService.hasUnseenUpdate.value = false;
    requests.clear();
    interceptor = InterceptorsWrapper(
      onRequest: (options, handler) => requests.add((options, handler)),
    );
    AppUpdateService.dioForTesting.interceptors.insert(0, interceptor);
  });

  tearDown(() {
    AppUpdateService.dioForTesting.interceptors.remove(interceptor);
    AppUpdateService.state.value = const AppUpdateState.idle();
    AppUpdateService.hasUnseenUpdate.value = false;
    teardownSecureCredentialStoreForTest();
  });

  void respond(int index, {bool beta = false}) {
    final (options, handler) = requests[index];
    handler.resolve(
      Response<Object?>(
        requestOptions: options,
        statusCode: 200,
        data: _release(beta: beta),
      ),
    );
  }

  /// checkForUpdate 先等 PackageInfo.fromPlatform() 再发请求，单次 pump
  /// 不足以让请求到达拦截器；有界轮询直到第 index 个请求被捕获。
  /// 轮询用的是普通 pump（不能用 pumpAndSettle：checking 状态的
  /// CircularProgressIndicator 是常驻动画）。
  Future<void> waitForRequest(WidgetTester tester, int index) async {
    var attempts = 0;
    while (requests.length <= index) {
      await tester.pump(const Duration(milliseconds: 10));
      if (attempts++ > 200) {
        fail('update request #$index never reached the interceptor');
      }
    }
  }

  Future<void> pumpAbout(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrapWithApp(const AboutPage(), wrapInScaffold: false),
    );
    await tester.pump();
  }

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    const key = ValueKey('update-host');
    await tester.pumpWidget(wrapWithApp(const SizedBox(key: key)));
    return tester.element(find.byKey(key));
  }

  testWidgets('Beta cancel disables and persists startup checks', (
    tester,
  ) async {
    await UserManager().setUpdateChannel('beta');
    await pumpAbout(tester);
    await waitForRequest(tester, 0);
    respond(0, beta: true);
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消自动检查更新'));
    await tester.pumpAndSettle();

    expect(UserManager().autoCheckUpdate, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('auto_check_update'), isFalse);
    expect(prefs.getString('skipped_update_version'), isNull);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );

    // Turning off startup checks must not prevent an explicit manual check.
    await tester.tap(find.text('检查更新'));
    await waitForRequest(tester, 1);
    respond(1, beta: true);
    await tester.pumpAndSettle();
    expect(AppUpdateService.state.value.status, AppUpdateStatus.available);
    expect(UserManager().autoCheckUpdate, isFalse);
    expect(AppUpdateService.hasUnseenUpdate.value, isFalse);
  });

  testWidgets('stable skip persists only the selected version', (tester) async {
    await pumpAbout(tester);
    await waitForRequest(tester, 0);
    respond(0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳过此版本'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('skipped_update_version'), '1.1.0');
    expect(UserManager().autoCheckUpdate, isTrue);
    expect(AppUpdateService.state.value.status, AppUpdateStatus.latest);

    // Auto checks stay quiet for the skipped version…
    final context = tester.element(find.byType(AboutPage));
    final autoCheck = AppUpdateService.checkAndPrompt(context, auto: true);
    await waitForRequest(tester, 1);
    respond(1);
    await autoCheck;
    await tester.pumpAndSettle();
    expect(AppUpdateService.state.value.status, AppUpdateStatus.latest);

    // …while a manual check still surfaces the update.
    await tester.tap(find.text('检查更新'));
    await waitForRequest(tester, 2);
    respond(2);
    await tester.pumpAndSettle();
    expect(AppUpdateService.state.value.status, AppUpdateStatus.available);
  });

  testWidgets('Beta remains available across restart with legacy seen record', (
    tester,
  ) async {
    await UserManager().setUpdateChannel('beta');
    final context = await pumpHost(tester);
    final firstCheck = AppUpdateService.checkAndPrompt(context, auto: true);
    await waitForRequest(tester, 0);
    respond(0, beta: true);
    await firstCheck;
    final info = AppUpdateService.state.value.info!;
    expect(AppUpdateService.state.value.status, AppUpdateStatus.available);
    expect(AppUpdateService.hasUnseenUpdate.value, isTrue);

    // An old installation may still carry a "seen build" record; merely
    // discovering the build must never hide it before it is installed.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_beta_asset_name', info.assets.first.name);
    await UserManager().init();
    AppUpdateService.state.value = const AppUpdateState.idle();
    AppUpdateService.hasUnseenUpdate.value = false;
    final secondCheck = AppUpdateService.checkAndPrompt(context, auto: true);
    await waitForRequest(tester, 1);
    respond(1, beta: true);
    await secondCheck;
    expect(AppUpdateService.state.value.status, AppUpdateStatus.available);
    expect(AppUpdateService.hasUnseenUpdate.value, isTrue);

    // Only installing the new build clears the update.
    _setInstalledBuild('2');
    final installedCheck = AppUpdateService.checkAndPrompt(context, auto: true);
    await waitForRequest(tester, 2);
    respond(2, beta: true);
    await installedCheck;
    expect(AppUpdateService.state.value.status, AppUpdateStatus.latest);
    expect(AppUpdateService.hasUnseenUpdate.value, isFalse);
  });

  testWidgets('About silent check keeps the card without leaving a badge', (
    tester,
  ) async {
    await pumpAbout(tester);
    await waitForRequest(tester, 0);
    expect(requests.single.$1.path, endsWith('/releases/latest'));
    respond(0);
    await tester.pumpAndSettle();

    expect(find.text('跳过此版本'), findsOneWidget);
    expect(AppUpdateService.state.value.status, AppUpdateStatus.available);
    expect(AppUpdateService.hasUnseenUpdate.value, isFalse);
    await tester.pumpWidget(wrapWithApp(const SizedBox()));
    await tester.pumpAndSettle();
    expect(AppUpdateService.hasUnseenUpdate.value, isFalse);
  });

  testWidgets('startup result arriving after About opens is marked seen', (
    tester,
  ) async {
    final context = await pumpHost(tester);
    final check = AppUpdateService.checkAndPrompt(context, auto: true);
    await waitForRequest(tester, 0);
    await pumpAbout(tester);
    expect(requests, hasLength(1));
    respond(0);
    await tester.pumpAndSettle();
    await check;

    expect(AppUpdateService.state.value.status, AppUpdateStatus.available);
    expect(AppUpdateService.hasUnseenUpdate.value, isFalse);
  });

  testWidgets('result arriving after leaving About still lights the badge', (
    tester,
  ) async {
    await pumpAbout(tester);
    await waitForRequest(tester, 0);
    await tester.pumpWidget(wrapWithApp(const SizedBox()));
    await tester.pumpAndSettle();
    respond(0);
    await tester.pumpAndSettle();

    expect(AppUpdateService.state.value.status, AppUpdateStatus.available);
    expect(AppUpdateService.hasUnseenUpdate.value, isTrue);
  });

  for (final oldRequestFails in [false, true]) {
    testWidgets('channel switch refreshes immediately and ignores old '
        '${oldRequestFails ? 'failure' : 'success'}', (tester) async {
      await pumpAbout(tester);
      await waitForRequest(tester, 0);
      expect(requests.single.$1.path, endsWith('/releases/latest'));

      await tester.tap(find.text('稳定版'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('预览版（Beta）'));
      await tester.pump();
      await tester.tap(find.text('确认'));
      await tester.pump(const Duration(milliseconds: 400));
      await waitForRequest(tester, 1);
      expect(requests.last.$1.path, endsWith('/releases/tags/CI'));
      respond(1, beta: true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(AppUpdateService.state.value.info!.isBetaChannel, isTrue);

      // The stale stable-channel response completes late; it must not
      // replace the fresh beta result — success or failure alike.
      if (oldRequestFails) {
        final (options, handler) = requests.first;
        handler.reject(DioException(requestOptions: options, error: 'offline'));
      } else {
        respond(0);
      }
      await tester.pumpAndSettle();
      expect(AppUpdateService.state.value.status, AppUpdateStatus.available);
      expect(AppUpdateService.state.value.info!.isBetaChannel, isTrue);
      expect(AppUpdateService.hasUnseenUpdate.value, isFalse);

      // The reverse switch also replaces the old card and rechecks at once.
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('稳定版 (Stable)'));
      await tester.pump();
      await tester.tap(find.text('确认'));
      await tester.pump(const Duration(milliseconds: 400));
      await waitForRequest(tester, 2);
      expect(AppUpdateService.state.value.status, AppUpdateStatus.checking);
      expect(AppUpdateService.state.value.info, isNull);
      respond(2);
      await tester.pumpAndSettle();
      expect(AppUpdateService.state.value.info!.isBetaChannel, isFalse);
      expect(find.text('跳过此版本'), findsOneWidget);
    });
  }
}

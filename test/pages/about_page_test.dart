import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/about_page.dart';
import 'package:kira/theme/app_status_colors.dart';
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
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('beta'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('是否切换?'), findsOneWidget);
      expect(find.text('预览版更新更快，问题也可能更多'), findsOneWidget);
      // 测试宿主是 Windows(非 Android arm64),arm64 提示应标成警告色。
      final danger = AppStatusColors.danger(
        Theme.of(tester.element(find.byType(AboutPage))).colorScheme,
      );
      expect(
        tester.widget<Text>(find.text('仅限 Android arm64 设备。')).style?.color,
        danger,
      );
      // 探测到设备环境时补一行「当前设备：...」,同样是警示色。
      final deviceLine = find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith('当前设备：'),
      );
      expect(deviceLine, findsOneWidget);
      expect(tester.widget<Text>(deviceLine).style?.color, danger);
      await tester.tap(find.text('确认'));
      await tester.pump(const Duration(milliseconds: 300));
      await waitForRequest(tester, 1);
      expect(requests.last.$1.path, endsWith('/releases/tags/CI'));
      respond(1, beta: true);
      await tester.pumpAndSettle();
      expect(AppUpdateService.state.value.info!.isBetaChannel, isTrue);
      await tester.pumpAndSettle();
      expect(AppUpdateService.state.value.info!.isBetaChannel, isTrue);
      // 不支持的设备上,Beta 徽标换成警告图标(与红色提示一致)。
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);

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
      await tester.tap(find.text('beta'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('稳定版'));
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

  group('更新镜像源', () {
    // 页面打开后更新检查一直处于 checking（CircularProgressIndicator 常驻动画），
    // 因此这里一律用固定时长的 pump，不用 pumpAndSettle；弹出菜单的收起动画
    // 比 300ms 长，需要多给一轮才能等到菜单真正从树上移除。
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    testWidgets('自定义镜像在下拉里可删除，删除后回落默认', (tester) async {
      final user = UserManager();
      await user.addCustomUpdateMirrorPrefix('https://my.mirror');
      await user.setUpdateMirrorPrefix('https://my.mirror');

      await pumpAbout(tester);
      final mirrorRow = find.byTooltip('设置镜像源');
      await tester.ensureVisible(mirrorRow);
      await settle(tester);
      // 按钮上显示当前镜像的主机名。
      expect(find.text('my.mirror'), findsOneWidget);

      await tester.tap(mirrorRow);
      await settle(tester);
      expect(find.text('https://my.mirror/'), findsOneWidget);

      await tester.tap(find.byTooltip('删除'));
      await settle(tester);

      expect(user.customUpdateMirrorPrefixes, isEmpty);
      expect(user.updateMirrorPrefix, UserManager.defaultUpdateMirrorPrefix);
      // 删除后菜单立即收起，按钮回落到默认镜像主机名。
      expect(find.byType(AboutPage), findsOneWidget, reason: 'about 页不应被 pop');
      expect(find.byType(PopupMenuItem<String>), findsNothing);
      expect(find.text('gh-proxy.org'), findsOneWidget);
      // 再打开下拉，已删除的自定义项不再出现。
      await tester.tap(mirrorRow);
      await settle(tester);
      expect(find.text('https://my.mirror/'), findsNothing);
    });

    testWidgets('切换内置镜像后自定义项仍留在下拉里', (tester) async {
      final user = UserManager();
      await user.addCustomUpdateMirrorPrefix('https://my.mirror');

      await pumpAbout(tester);
      final mirrorRow = find.byTooltip('设置镜像源');
      await tester.ensureVisible(mirrorRow);
      await settle(tester);

      await tester.tap(mirrorRow);
      await settle(tester);
      await tester.tap(find.text('https://my.mirror/'));
      await settle(tester);
      expect(user.updateMirrorPrefix, 'https://my.mirror/');

      await tester.tap(mirrorRow);
      await settle(tester);
      await tester.tap(find.text('https://ghproxy.net/'));
      await settle(tester);

      expect(user.updateMirrorPrefix, 'https://ghproxy.net/');
      expect(user.customUpdateMirrorPrefixes, ['https://my.mirror/']);
      await tester.tap(mirrorRow);
      await settle(tester);
      expect(find.text('https://my.mirror/'), findsOneWidget);
    });
  });
}

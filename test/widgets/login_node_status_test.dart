import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/l10n/app_localizations.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/widgets/login_node_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _buildTestApp(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LoginNodeStatusCard.probeOverride = (hosts, {onHostResult}) async {
      final results = <String, int?>{for (final host in hosts) host: 120};
      for (final entry in results.entries) {
        onHostResult?.call(entry.key, entry.value);
      }
      return results;
    };
  });

  tearDown(() {
    LoginNodeStatusCard.probeOverride = null;
  });

  testWidgets('hot source shows one route node without copy row', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await UserManager().init();

    await tester.pumpWidget(
      _buildTestApp(const LoginNodeStatusCard(useCopyLogin: false)),
    );
    await tester.pumpAndSettle();

    expect(find.text('拷贝登录'), findsNothing);
    expect(find.text('120 ms'), findsOneWidget);
    expect(find.text('超时'), findsNothing);
    expect(find.text('当前延迟较大，建议开启代理'), findsNothing);
  });

  testWidgets('copy source shows only the copy login host', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await UserManager().init();

    await tester.pumpWidget(
      _buildTestApp(const LoginNodeStatusCard(useCopyLogin: true)),
    );
    await tester.pumpAndSettle();

    expect(find.text('拷贝登录'), findsOneWidget);
    expect(find.text('120 ms'), findsOneWidget);
  });

  testWidgets('shows timeout value on the host row when host is unreachable', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await UserManager().init();
    LoginNodeStatusCard.probeOverride = (hosts, {onHostResult}) async {
      final results = <String, int?>{for (final host in hosts) host: null};
      for (final entry in results.entries) {
        onHostResult?.call(entry.key, entry.value);
      }
      return results;
    };

    await tester.pumpWidget(
      _buildTestApp(const LoginNodeStatusCard(useCopyLogin: false)),
    );
    await tester.pumpAndSettle();

    // 右侧延迟值已显示「超时」，不再重复出现整行提示。
    expect(find.text('超时'), findsOneWidget);
    expect(find.text('超时，无法连接'), findsNothing);
  });

  testWidgets('refresh button re-runs the probe', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await UserManager().init();
    var calls = 0;
    LoginNodeStatusCard.probeOverride = (hosts, {onHostResult}) async {
      calls++;
      final results = <String, int?>{for (final host in hosts) host: 100};
      for (final entry in results.entries) {
        onHostResult?.call(entry.key, entry.value);
      }
      return results;
    };

    await tester.pumpWidget(
      _buildTestApp(const LoginNodeStatusCard(useCopyLogin: false)),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('100 ms'), findsOneWidget);
  });

  /// 探测返回指定延迟。
  void probeWith(int? latency) {
    LoginNodeStatusCard.probeOverride = (hosts, {onHostResult}) async {
      final results = <String, int?>{for (final host in hosts) host: latency};
      for (final entry in results.entries) {
        onHostResult?.call(entry.key, entry.value);
      }
      return results;
    };
  }

  Future<void> pumpCard(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await UserManager().init();
    await tester.pumpWidget(
      _buildTestApp(const LoginNodeStatusCard(useCopyLogin: false)),
    );
    await tester.pumpAndSettle();
  }

  /// 卡片外层容器的装饰（底色 / 描边）。
  BoxDecoration cardDecoration(WidgetTester tester) {
    final container = tester.widget<Container>(
      find.byType(Container).first,
    );
    return container.decoration! as BoxDecoration;
  }

  testWidgets('good latency keeps the plain dot and no border', (tester) async {
    probeWith(120);
    await pumpCard(tester);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(find.byIcon(Icons.cloud_off_rounded), findsNothing);
    expect(cardDecoration(tester).border, isNull);
  });

  testWidgets('moderate latency is emphasised but not alarmed', (tester) async {
    probeWith(1500);
    await pumpCard(tester);
    // 橙色已升级为胶囊底，但还不算「严重」，不换图标、不加描边。
    expect(find.text('1500 ms'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(cardDecoration(tester).border, isNull);
  });

  testWidgets('timeout swaps the dot for an icon and outlines the card', (
    tester,
  ) async {
    probeWith(null);
    await pumpCard(tester);
    // 文案不变，靠图标 + 整卡描边提示不可达。
    expect(find.text('超时'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
    expect(cardDecoration(tester).border, isNotNull);
  });

  testWidgets('very high latency is alarmed like a timeout', (tester) async {
    probeWith(3500);
    await pumpCard(tester);
    expect(find.text('3500 ms'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(cardDecoration(tester).border, isNotNull);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/reader_settings.dart';
import 'package:kira/theme/app_typography.dart';
import 'package:kira/widgets/reader_status_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = ReaderSettings();

  setUp(() async {
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({});
    await settings.initFromPrefs(await SharedPreferences.getInstance());
  });
  tearDown(teardownSecureCredentialStoreForTest);

  /// 模拟阅读页结构：测量发生在 Scaffold 之上（与 ReaderPage 的 build
  /// context 一致），组件本身渲染在 Scaffold body 的 Material 之下。
  Future<double> pumpMeasuredOverlay(
    WidgetTester tester, {
    TextScaler textScaler = TextScaler.noScaling,
    ThemeData? theme,
  }) async {
    await tester.runAsync(() => settings.setStatusOverlayPage(true));
    late double reserved;
    await tester.pumpWidget(
      wrapWithApp(
        Theme(
          data: theme ?? ThemeData(),
          child: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: Builder(
                builder: (context) {
                  reserved = ReaderStatusOverlay.reservedHeightFor(context);
                  return const Scaffold(
                    body: Stack(
                      children: [
                        Positioned(
                          top: 0,
                          left: 0,
                          child: ReaderStatusOverlay(progressLabel: '42%'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        wrapInScaffold: false,
      ),
    );
    await tester.pumpAndSettle();
    return reserved;
  }

  final scalers = <(String, TextScaler)>[
    ('1x', TextScaler.noScaling),
    ('platform 2x', const TextScaler.linear(2)),
    (
      'theme font 26/14',
      AppTypography.composeTextScaler(TextScaler.noScaling, 26 / 14),
    ),
    (
      'platform 1.3x + theme font 20/14',
      AppTypography.composeTextScaler(const TextScaler.linear(1.3), 20 / 14),
    ),
  ];
  for (final (label, scaler) in scalers) {
    testWidgets('reserved height matches rendered overlay at $label', (
      tester,
    ) async {
      final reserved = await pumpMeasuredOverlay(tester, textScaler: scaler);
      final rendered = tester.getSize(find.byType(ReaderStatusOverlay)).height;
      expect(rendered, closeTo(reserved, 0.01));
      // 正常字号外观不变：仍是 11 号文字。
      final label = tester.widget<Text>(find.text('42%'));
      expect(label.style?.fontSize, 11);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('reserved height follows inherited body text metrics', (
    tester,
  ) async {
    final theme = ThemeData(
      textTheme: ThemeData.light().textTheme.copyWith(
        bodyMedium: ThemeData.light().textTheme.bodyMedium?.copyWith(
          height: 2.2,
        ),
      ),
    );
    final reserved = await pumpMeasuredOverlay(tester, theme: theme);
    final rendered = tester.getSize(find.byType(ReaderStatusOverlay)).height;
    expect(rendered, closeTo(reserved, 0.01));
    // 行高倍率变化会真实抬高组件，预留必须随之变化而不是停在旧常量。
    expect(reserved, greaterThan(24));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('novel percentage follows the shared comic page toggle', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ReaderStatusOverlay(progressLabel: '42%')),
      ),
    );
    await tester.pumpAndSettle();
    // 默认页码段关闭：小说百分比与漫画页码一致，都不显示。
    expect(find.text('42%'), findsNothing);
    await tester.runAsync(() => settings.setStatusOverlayPage(true));
    await tester.pumpAndSettle();
    expect(find.text('42%'), findsOneWidget);
    expect(find.textContaining('FPS'), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.runAsync(() => settings.setStatusOverlayPage(false));
    await tester.pumpAndSettle();
    expect(find.text('42%'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('comic page labels still follow the existing setting', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReaderStatusOverlay(currentPage: 3, totalPages: 10),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('3/10'), findsNothing);
    await tester.runAsync(() => settings.setStatusOverlayPage(true));
    await tester.pumpAndSettle();
    expect(find.text('3/10'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('FPS ticker starts only when enabled and stops while hidden', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, enabled, child) =>
                TickerMode(enabled: enabled, child: child!),
            child: const ReaderStatusOverlay(progressLabel: '42%'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.runAsync(() => settings.setStatusOverlayFps(true));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isTrue);
    expect(find.textContaining('FPS'), findsOneWidget);
    visible.value = false;
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    visible.value = true;
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.runAsync(() => settings.setStatusOverlayFps(false));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
    visible.dispose();
  });
}

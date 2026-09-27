import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/reader_settings.dart';
import 'package:kira/widgets/reader_status_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = ReaderSettings();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.initFromPrefs(await SharedPreferences.getInstance());
  });

  testWidgets(
    'novel percentage follows the shared comic page toggle',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ReaderStatusOverlay(progressLabel: '42%'),
          ),
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
    },
  );

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

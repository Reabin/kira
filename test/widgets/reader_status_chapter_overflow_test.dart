import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/novel_reader_status_settings.dart';
import 'package:kira/widgets/reader_status_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final novelStatus = NovelReaderStatusSettings();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await novelStatus.initFromPrefs(await SharedPreferences.getInstance());
  });

  // 锚定右上角（漫画/小说阅读页角落位的真实摆放方式）。
  Future<void> mountOverlay(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(180, 100);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              const SizedBox.expand(),
              Positioned(
                top: 0,
                right: 0,
                child: ReaderStatusOverlay(
                  chapterLabel: '第一二三四五六七八九十章节名超长测试标题需要截断的情况末尾还有更多字',
                  prefs: novelStatus,
                  maxWidth: 180,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('long chapter label stays on screen and keeps the head', (
    tester,
  ) async {
    await mountOverlay(tester);
    final chapterFinder = find.byType(Flexible);
    expect(chapterFinder, findsOneWidget);
    final box = tester.renderObject<RenderBox>(chapterFinder);
    final left = box.localToGlobal(Offset.zero).dx;
    final right = left + box.size.width;
    // 截断必须发生在屏内：若 Row 按内容全宽排版，浮层锚右、文本向左
    // 溢出屏幕，用户只能看到章节名尾部。
    expect(left, greaterThanOrEqualTo(0),
        reason: '章节名向左溢出屏幕（$left < 0），布局未受约束');
    expect(right, lessThanOrEqualTo(180));
    await tester.pumpWidget(const SizedBox());
  });
}

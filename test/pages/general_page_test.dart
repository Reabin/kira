import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/general_page.dart';
import 'package:kira/widgets/setting_action_tile.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'user_token': 'token',
      'saved_username': 'alice',
      'saved_password': 'secret',
      'auto_login': true,
    });
  });

  testWidgets('reset app requires exact confirmation text', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await UserManager().init();

    await tester.pumpWidget(
      wrapWithApp(const GeneralPage(), wrapInScaffold: false),
    );
    await tester.pumpAndSettle();

    // 重置应用入口从红色卡片按钮改为普通 ListTile，点击弹出确认对话框。
    final resetTile = find.text('重置应用').first;
    await tester.scrollUntilVisible(resetTile, 100);
    await tester.tap(resetTile);
    await tester.pumpAndSettle();

    FilledButton button() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认重置'));

    expect(button().onPressed, isNull);

    await tester.enterText(find.byType(TextField).last, '重置');
    await tester.pump();
    expect(button().onPressed, isNull);

    await tester.enterText(find.byType(TextField).last, '重置应用');
    await tester.pump();
    expect(button().onPressed, isNotNull);
  });

  // 「导出设置 / 导入设置」入口已由新的备份页（本地/WebDAV、加密与定时备份）取代，
  // 原并排一行的断言不再适用；这里改为确认通用页只剩备份入口、不再有旧的导入导出按钮。
  testWidgets('general page links to backup instead of legacy export tiles', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await UserManager().init();

    await tester.pumpWidget(
      wrapWithApp(const GeneralPage(), wrapInScaffold: false),
    );
    await tester.pumpAndSettle();

    expect(
      find.ancestor(of: find.text('导出设置'), matching: find.byType(ListTile)),
      findsNothing,
    );
    expect(
      find.ancestor(of: find.text('导入设置'), matching: find.byType(ListTile)),
      findsNothing,
    );
    expect(find.byType(SettingActionTile), findsNothing);
    expect(find.textContaining('备份'), findsWidgets);
  });
}

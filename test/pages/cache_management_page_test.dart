import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/pages/cache_management_page.dart';
import 'package:kira/repositories/novel_repository.dart';
import 'package:kira/utils/font_manager.dart';
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

/// 缓存管理页的真实文件 IO（目录扫描、删除）在 widget 测试的 fake async
/// 时钟里不会完成，所以加载与清理链路都要在 [tester.runAsync] 里跑。
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform({
    required this.temporaryPath,
    required this.supportPath,
  });

  final String temporaryPath;
  final String supportPath;

  @override
  Future<String?> getTemporaryPath() async => temporaryPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

late Directory _root;
late Directory _tempDir;
late Directory _supportDir;
PathProviderPlatform? _originalPathProvider;

Future<void> _setUpPaths(WidgetTester tester) async {
  _originalPathProvider = PathProviderPlatform.instance;
  await tester.runAsync(() async {
    _root = await Directory.systemTemp.createTemp('kira_cache_mgmt_test');
    _tempDir = Directory('${_root.path}/tmp')..createSync();
    _supportDir = Directory('${_root.path}/support')..createSync();
  });
  PathProviderPlatform.instance = _FakePathProviderPlatform(
    temporaryPath: _tempDir.path,
    supportPath: _supportDir.path,
  );
  // FontManager 单例缓存着上一个测试临时目录里的字体路径，必须重置，
  // 否则页面扫描失效目录会整体进错误视图。
  FontManager().reloadFromPrefs();
}

void _tearDownPaths() {
  PathProviderPlatform.instance = _originalPathProvider!;
  if (_root.existsSync()) {
    _root.deleteSync(recursive: true);
  }
}

Future<void> _pumpPage(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(
      wrapWithApp(const CacheManagementPage(), wrapInScaffold: false),
    );
    // 轮询到 initState 里的真实目录扫描完成、页面退出加载态为止。
    // 加载链路 rooted 在 runAsync 的真实 zone 里，fake async 时钟推不动它，
    // 固定延时等待会有竞态。
    for (var i = 0; i < 250; i++) {
      if (find.byType(ExpressiveLoadingIndicator).evaluate().isEmpty) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 10),
  );
}

/// 展开数据缓存分组里的某个 ExpansionTile（必要时先滚动到可见）。
Future<void> _expandSection(WidgetTester tester, String title) async {
  final tile = find.widgetWithText(ExpansionTile, title);
  await tester.scrollUntilVisible(
    tile,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('轻小说正文缓存独立成节，不再挂在图片缓存分组下', (tester) async {
    await _setUpPaths(tester);
    addTearDown(_tearDownPaths);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    Directory(
      '${_supportDir.path}/${FileNovelCacheStore.directoryName}',
    ).createSync();
    File(
      '${_supportDir.path}/${FileNovelCacheStore.directoryName}/volume.json',
    ).writeAsStringSync('{"text":"hi"}');

    await _pumpPage(tester);

    expect(find.text('图片缓存'), findsOneWidget);
    // 旧组合标签「图片缓存 / xxx」不再出现。
    expect(find.textContaining('图片缓存 /'), findsNothing);
    expect(find.text('漫画阅读器'), findsOneWidget);
    expect(find.text('封面与头像'), findsOneWidget);

    expect(find.text('轻小说缓存'), findsOneWidget);
    expect(find.text('轻小说正文缓存'), findsOneWidget);
    expect(find.textContaining('1 个文件'), findsOneWidget);

    // 纵向顺序：图片缓存分组只含两个图片卡片，正文缓存紧跟其后独立成节。
    double dy(Finder finder) => tester.getTopLeft(finder).dy;
    final imageHeader = dy(find.text('图片缓存'));
    final readerCard = dy(find.text('漫画阅读器'));
    final coverCard = dy(find.text('封面与头像'));
    final novelHeader = dy(find.text('轻小说缓存'));
    final novelCard = dy(find.text('轻小说正文缓存'));
    expect(readerCard, greaterThan(imageHeader));
    expect(coverCard, greaterThan(readerCard));
    expect(novelHeader, greaterThan(coverCard));
    expect(novelCard, greaterThan(novelHeader));
  });

  testWidgets('轻小说书签归入轻小说阅读记录，而不是其他数据', (tester) async {
    await _setUpPaths(tester);
    addTearDown(_tearDownPaths);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'novel_bookmarks_v1': '{"items":[]}',
      'mystery_orphan_key': 'orphan-value',
    });

    await _pumpPage(tester);

    await _expandSection(tester, '轻小说阅读记录');
    expect(
      find.descendant(
        of: find.widgetWithText(ExpansionTile, '轻小说阅读记录'),
        matching: find.text('novel_bookmarks_v1'),
      ),
      findsOneWidget,
    );

    await _expandSection(tester, '其他数据');
    final otherTile = find.widgetWithText(ExpansionTile, '其他数据');
    expect(
      find.descendant(of: otherTile, matching: find.text('novel_bookmarks_v1')),
      findsNothing,
    );
    expect(
      find.descendant(of: otherTile, matching: find.text('mystery_orphan_key')),
      findsOneWidget,
    );
  });

  testWidgets('清除轻小说正文缓存只删除正文目录', (tester) async {
    await _setUpPaths(tester);
    addTearDown(_tearDownPaths);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final novelDir = Directory(
      '${_supportDir.path}/${FileNovelCacheStore.directoryName}',
    )..createSync();
    File('${novelDir.path}/volume.json').writeAsStringSync('{"text":"hi"}');

    await _pumpPage(tester);

    // 清空按钮和确认弹窗整段在 runAsync 内交互：弹窗由 fake zone 之外的
    // tap 打开，整条清理链路才 rooted 在真实 zone，目录 IO 才能完成。
    final novelCard = find
        .ancestor(of: find.text('轻小说正文缓存'), matching: find.byType(Card))
        .first;
    final cardClearButton = find.descendant(
      of: novelCard,
      matching: find.widgetWithText(FilledButton, '清空'),
    );
    final dialogClearButton = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, '清空'),
    );
    await tester.runAsync(() async {
      await tester.tap(cardClearButton);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('清除已缓存的轻小说正文'), findsOneWidget);
      await tester.tap(dialogClearButton);
      // 等 Navigator.pop 之后的真实目录删除与页面刷新完成。
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    expect(novelDir.existsSync(), isFalse);
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kira/routing/dismiss_keyboard_observer.dart';

class _FocusRig {
  _FocusRig({required bool dismissKeyboard}) {
    router = GoRouter(
      observers: [if (dismissKeyboard) DismissKeyboardObserver()],
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: TextField(focusNode: searchFocus, controller: text),
          ),
        ),
        GoRoute(
          path: '/detail',
          builder: (_, state) => Scaffold(
            body: state.uri.queryParameters['autofocus'] == 'true'
                ? TextField(focusNode: detailFocus, autofocus: true)
                : const Text('详情占位页'),
          ),
        ),
      ],
    );
  }

  final searchFocus = FocusNode();
  final detailFocus = FocusNode();
  final text = TextEditingController();
  late final GoRouter router;

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      searchFocus.dispose();
      detailFocus.dispose();
      text.dispose();
    });
  }
}

void main() {
  for (final dismissKeyboard in [false, true]) {
    testWidgets(dismissKeyboard ? '详情返回不会恢复旧输入焦点和键盘' : '对照：原始路由返回会恢复旧输入焦点和键盘', (
      tester,
    ) async {
      final rig = _FocusRig(dismissKeyboard: dismissKeyboard);
      await rig.mount(tester);
      await tester.enterText(find.byType(TextField), '未提交的关键词');
      expect(rig.searchFocus.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      // 模拟仅收起键盘而未退出输入框的情况。
      tester.testTextInput.hide();
      expect(rig.searchFocus.hasFocus, isTrue);

      for (var i = 0; i < 2; i++) {
        unawaited(rig.router.push<void>('/detail'));
        await tester.pumpAndSettle();
        expect(rig.searchFocus.hasFocus, isFalse);
        tester.testTextInput.log.clear();
        rig.router.pop();
        await tester.pumpAndSettle();

        expect(rig.searchFocus.hasFocus, !dismissKeyboard);
        expect(tester.testTextInput.isVisible, !dismissKeyboard);
        expect(
          tester.testTextInput.log.any(
            (call) => call.method == 'TextInput.show',
          ),
          !dismissKeyboard,
        );
        expect(rig.text.text, '未提交的关键词');
      }

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(rig.searchFocus.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });
  }

  testWidgets('目标页主动聚焦不受离页退焦影响', (tester) async {
    final rig = _FocusRig(dismissKeyboard: true);
    await rig.mount(tester);
    await tester.enterText(find.byType(TextField), '关键词');
    unawaited(rig.router.push<void>('/detail?autofocus=true'));
    await tester.pumpAndSettle();

    expect(rig.searchFocus.hasFocus, isFalse);
    expect(rig.detailFocus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    rig.router.pop();
    await tester.pumpAndSettle();
    expect(rig.searchFocus.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('对话框仍可自动聚焦，关闭后保留原页面输入焦点', (tester) async {
    final rig = _FocusRig(dismissKeyboard: true);
    await rig.mount(tester);
    await tester.enterText(find.byType(TextField), '关键词');
    final dialogFocus = FocusNode();
    addTearDown(dialogFocus.dispose);

    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(TextField)),
        builder: (_) => AlertDialog(
          content: TextField(focusNode: dialogFocus, autofocus: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(dialogFocus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    rig.router.pop();
    await tester.pumpAndSettle();
    expect(rig.searchFocus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  });
}

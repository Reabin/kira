import 'package:flutter/widgets.dart';

/// 离开页面时清除输入焦点历史，避免返回时重新弹出键盘。
class DismissKeyboardObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null && route is PageRoute) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null && newRoute is PageRoute) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }
}

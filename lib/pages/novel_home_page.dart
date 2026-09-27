import 'package:flutter/material.dart';

import 'novel_search_tab.dart';

/// 底部导航的「轻小说」分支。
///
/// 与其它分支一致：不加标题栏，内容区自己从状态栏下方开始。
/// 「浏览记录」「继续阅读」都收在「我的」里，这里不再重复放入口。
class NovelHomePage extends StatelessWidget {
  const NovelHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          SizedBox(height: MediaQuery.of(context).padding.top),
          const Expanded(child: NovelSearchTab()),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'browse_history_page.dart';

/// 兼容旧小说历史路由，使用与统一浏览记录相同的在线接口。
class NovelHistoryPage extends StatelessWidget {
  const NovelHistoryPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(AppLocalizations.of(context)!.novelHistory)),
    body: const NovelHistoryBody(),
  );
}

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'browse_history_page.dart';

/// 兼容旧小说历史路由，列表与统一浏览历史中的小说分页保持一致。
class NovelHistoryPage extends StatelessWidget {
  const NovelHistoryPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(AppLocalizations.of(context)!.novelHistory)),
    body: const NovelHistoryBody(),
  );
}

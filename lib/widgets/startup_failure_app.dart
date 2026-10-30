import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_spacing.dart';

/// 启动失败时的最后兜底界面。
///
/// 之前 `main()` 在 runApp 之前抛异常会让应用停在系统启动图的纯色窗口上，
/// 用户只能看到白屏、没有任何可操作的线索。这里把异常摘要显示出来，并提供
/// 重试入口，至少让故障可诊断、可恢复。
class StartupFailureApp extends StatefulWidget {
  final Object error;
  final Future<void> Function() onRetry;

  const StartupFailureApp({
    super.key,
    required this.error,
    required this.onRetry,
  });

  @override
  State<StartupFailureApp> createState() => _StartupFailureAppState();
}

class _StartupFailureAppState extends State<StartupFailureApp> {
  bool _busy = false;

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      await widget.onRetry();
    } catch (_) {
      // onRetry 成功后自身会替换整棵树；失败则留在本页，保持可重试。
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 只展示异常类型与首行摘要，避免把整段堆栈铺在屏幕上。
  String get _summary {
    final text = widget.error.toString().trim();
    final firstLine = text.split('\n').first;
    return firstLine.length > 300
        ? '${firstLine.substring(0, 300)}…'
        : firstLine;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        final textTheme = Theme.of(context).textTheme;
        return Scaffold(
          appBar: AppBar(title: Text(l10n.startupFailedTitle)),
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xxl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.startupFailedBody),
                  const SizedBox(height: AppSpacing.lg),
                  Text(l10n.startupFailedDetails, style: textTheme.labelLarge),
                  const SizedBox(height: AppSpacing.xs),
                  SelectableText(_summary, style: textTheme.bodySmall),
                  const SizedBox(height: AppSpacing.xl),
                  if (_busy)
                    const Center(child: CircularProgressIndicator())
                  else
                    FilledButton(
                      onPressed: _retry,
                      child: Text(l10n.retryButton),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

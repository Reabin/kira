part of '../license_page.dart';

/// 宽屏下把许可正文钳制在可读宽度内。
double _licenseHorizontalPadding(BoxConstraints constraints) {
  final contentWidth = constraints.maxWidth.clamp(
    0.0,
    ScreenLayout.wideBreakpoint,
  );
  return (constraints.maxWidth - contentWidth) / 2 + AppSpacing.lg;
}

/// 许可正文使用系统默认字体，不受应用自定义字体影响。
TextStyle _licenseTextStyle(BuildContext context) {
  final theme = Theme.of(context);
  final platformStyle = Typography.material2021(
    platform: theme.platform,
    colorScheme: theme.colorScheme,
  ).black.bodyMedium!;
  return theme.textTheme.bodyMedium!.copyWith(
    inherit: false,
    fontFamily: platformStyle.fontFamily,
    fontFamilyFallback: platformStyle.fontFamilyFallback ?? const [],
    height: 1.5,
  );
}

String _licenseErrorMessage(Object error, AppLocalizations l10n) {
  final message = error.toString().trim();
  return message.isEmpty ? l10n.loadingFailed : message;
}

/// 顶部 Kira 许可卡：折叠后仍保留正文状态，减少动画开启时直接跳变。
class _ProjectLicenseCard extends StatefulWidget {
  const _ProjectLicenseCard({
    super.key,
    required this.expanded,
    required this.onToggle,
  });

  final bool expanded;
  final VoidCallback onToggle;

  @override
  State<_ProjectLicenseCard> createState() => _ProjectLicenseCardState();
}

class _ProjectLicenseCardState extends State<_ProjectLicenseCard> {
  late bool _hasExpanded = widget.expanded;

  @override
  void didUpdateWidget(covariant _ProjectLicenseCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _hasExpanded |= widget.expanded;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: widget.expanded,
            child: ListTile(
              leading: Icon(
                Icons.copyright_outlined,
                color: cs.primary,
                size: AppIconSize.xl,
              ),
              title: const Text('Kira'),
              subtitle: Text(l10n.licenseMitSummary),
              trailing: AnimatedRotation(
                turns: widget.expanded ? 0.5 : 0,
                duration: adaptiveDuration(
                  context,
                  const Duration(milliseconds: 180),
                ),
                curve: Curves.easeOut,
                child: const Icon(Icons.expand_more, size: AppIconSize.xl),
              ),
              onTap: widget.onToggle,
            ),
          ),
          CollapsibleContent(
            expanded: widget.expanded,
            child: _hasExpanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      0,
                      AppSpacing.lg,
                      AppSpacing.lg,
                    ),
                    child: SelectableText(
                      projectLicenseText,
                      style: _licenseTextStyle(context),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// 详情页正文：按帧逐条解析段落，避免一次解析整包许可卡住首帧。
class _PackageLicenseBody extends StatefulWidget {
  const _PackageLicenseBody({super.key, required this.entries});

  final List<LicenseNotice> entries;

  @override
  State<_PackageLicenseBody> createState() => _PackageLicenseBodyState();
}

class _PackageLicenseBodyState extends State<_PackageLicenseBody> {
  late Future<List<List<LicenseParagraph>>> _paragraphs = _loadParagraphs();

  Future<List<List<LicenseParagraph>>> _loadParagraphs() async {
    try {
      final notices = <List<LicenseParagraph>>[];
      for (final entry in widget.entries) {
        final paragraphs = await SchedulerBinding.instance.scheduleTask(
          () => Future.sync(() => entry.paragraphs),
          Priority.animation,
        );
        notices.add(paragraphs);
      }
      return notices;
    } catch (error, stackTrace) {
      unawaited(
        AppLogger.instance.recordWarning(
          error,
          stackTrace: stackTrace,
          source: 'licenses',
        ),
      );
      rethrow;
    }
  }

  void _retry() {
    setState(() {
      _paragraphs = _loadParagraphs();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FutureBuilder<List<List<LicenseParagraph>>>(
      future: _paragraphs,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ErrorRetryView(
            icon: Icons.description_outlined,
            message: _licenseErrorMessage(snapshot.error!, l10n),
            onRetry: _retry,
          );
        }
        final notices = snapshot.data;
        if (notices == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < notices.length; index++) ...[
                if (index > 0) const Divider(height: AppSpacing.xxl),
                for (final paragraph in notices[index]) _paragraph(paragraph),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _paragraph(LicenseParagraph paragraph) {
    final centered = paragraph.indent == LicenseParagraph.centeredIndent;
    return Padding(
      padding: EdgeInsets.only(
        left: paragraph.indent > 0 ? paragraph.indent * AppSpacing.lg : 0,
        bottom: AppSpacing.md,
      ),
      child: Text(
        paragraph.text,
        textAlign: centered ? TextAlign.center : TextAlign.start,
        style: _licenseTextStyle(context),
      ),
    );
  }
}

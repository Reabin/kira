import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/app_localizations.dart';
import '../models/package_license.dart';
import '../providers/license_providers.dart';
import '../routing/app_router.dart';
import '../theme/app_icon_sizes.dart';
import '../theme/app_spacing.dart';
import '../utils/adaptive_motion.dart';
import '../utils/app_logger.dart';
import '../utils/font_licenses.dart';
import '../utils/project_license.dart';
import '../utils/screen_layout.dart';
import '../widgets/collapsible_content.dart';
import '../widgets/error_retry_view.dart';
import '../widgets/section_header.dart';

part 'license_page/font_license_page.dart';
part 'license_page/license_widgets.dart';
part 'license_page/package_license_page.dart';

/// 开源许可：顶部为 Kira 自身许可，下面是按包名排好序的第三方依赖列表。
class ProjectLicensePage extends ConsumerStatefulWidget {
  const ProjectLicensePage({super.key});

  @override
  ConsumerState<ProjectLicensePage> createState() => _ProjectLicensePageState();
}

class _ProjectLicensePageState extends ConsumerState<ProjectLicensePage> {
  /// 详情页压栈时列表页保持挂载，所以返回后折叠状态自然保留。
  bool _projectExpanded = true;

  void _toggleProject() {
    setState(() => _projectExpanded = !_projectExpanded);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final packages = ref.watch(packageLicensesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutLicenseTitle)),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = _licenseHorizontalPadding(constraints);
            return ListView.builder(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                AppSpacing.lg,
                horizontalPadding,
                AppSpacing.xxl,
              ),
              itemCount: _itemCount(packages),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _ProjectLicenseCard(
                    key: const PageStorageKey('project-license'),
                    expanded: _projectExpanded,
                    onToggle: _toggleProject,
                  );
                }
                if (index == 1) {
                  return _sectionHeader(
                    l10n.licenseFontsTitle,
                    Icons.font_download_outlined,
                  );
                }
                if (index < 2 + fontLicenses.length) {
                  return _fontItem(context, fontLicenses[index - 2]);
                }
                if (index == 2 + fontLicenses.length) {
                  return _sectionHeader(
                    l10n.licenseThirdPartyTitle,
                    Icons.extension_outlined,
                  );
                }
                return _dependencyItem(
                  context,
                  ref,
                  l10n,
                  packages,
                  index - 3 - fontLicenses.length,
                );
              },
            );
          },
        ),
      ),
    );
  }

  int _dependencyItemCount(AsyncValue<List<PackageLicense>> packages) {
    final list = packages.value;
    return list == null || list.isEmpty ? 1 : list.length;
  }

  int _itemCount(AsyncValue<List<PackageLicense>> packages) =>
      3 + _dependencyItemCount(packages) + fontLicenses.length;

  Widget _sectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSpacing.xxl,
        bottom: AppSpacing.md,
      ),
      child: SectionHeader(title: title, icon: icon),
    );
  }

  Widget _fontItem(BuildContext context, FontLicense font) {
    return ListTile(
      title: Text(font.name),
      subtitle: Text(font.licenseName),
      trailing: const Icon(Icons.chevron_right, size: AppIconSize.xl),
      onTap: () => context.pushNamed(
        AppRoutes.fontLicense,
        pathParameters: {'fontId': font.id},
      ),
    );
  }

  Widget _dependencyItem(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    AsyncValue<List<PackageLicense>> packages,
    int position,
  ) {
    if (packages.hasError && !packages.hasValue) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: ErrorRetryView(
          icon: Icons.description_outlined,
          message: _licenseErrorMessage(packages.error!, l10n),
          onRetry: () => ref.invalidate(packageLicensesProvider),
        ),
      );
    }
    final list = packages.value;
    if (list == null) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xxl),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (list.isEmpty) {
      return Text(
        l10n.licenseThirdPartyEmpty,
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }
    final package = list[position];
    return Column(
      children: [
        ListTile(
          title: Text(package.name),
          subtitle: Text(l10n.licenseCount(package.entries.length)),
          trailing: const Icon(Icons.chevron_right, size: AppIconSize.xl),
          onTap: () => context.pushNamed(
            AppRoutes.packageLicense,
            pathParameters: {'packageName': package.name},
          ),
        ),
        if (position < list.length - 1) const Divider(height: 1),
      ],
    );
  }
}

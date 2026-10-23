part of '../license_page.dart';

/// 单个依赖的许可全文页，由 `/license/:packageName` 进入。
///
/// 与列表页共用 [packageLicensesProvider]，因此直接深链接打开也能取到数据，
/// 不需要列表页通过路由 `extra` 传参。
class PackageLicensePage extends ConsumerWidget {
  const PackageLicensePage({super.key, required this.packageName});

  final String packageName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final packages = ref.watch(packageLicensesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(packageName)),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = _licenseHorizontalPadding(constraints);
            return packages.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: horizontalPadding,
                  vertical: AppSpacing.xxl,
                ),
                child: ErrorRetryView(
                  icon: Icons.description_outlined,
                  message: _licenseErrorMessage(error, l10n),
                  onRetry: () => ref.invalidate(packageLicensesProvider),
                ),
              ),
              data: (list) {
                final entries =
                    findPackageLicense(list, packageName)?.entries ??
                    const <LicenseNotice>[];
                return ListView(
                  key: PageStorageKey('license-detail-$packageName'),
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    AppSpacing.lg,
                    horizontalPadding,
                    AppSpacing.xxl,
                  ),
                  children: [
                    if (entries.isEmpty)
                      Text(l10n.licenseThirdPartyEmpty)
                    else
                      _PackageLicenseBody(
                        key: ValueKey(entries),
                        entries: entries,
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

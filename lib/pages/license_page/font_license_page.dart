part of '../license_page.dart';

/// 应用内提供下载的第三方字体的许可全文页。
class FontLicensePage extends StatelessWidget {
  const FontLicensePage({super.key, required this.fontId});

  final String fontId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final font = findFontLicense(fontId);

    return Scaffold(
      appBar: AppBar(title: Text(font?.name ?? l10n.licenseFontsTitle)),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = _licenseHorizontalPadding(constraints);
            if (font == null) {
              return Center(child: Text(l10n.licenseThirdPartyEmpty));
            }
            return ListView(
              key: PageStorageKey('font-license-$fontId'),
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                AppSpacing.lg,
                horizontalPadding,
                AppSpacing.xxl,
              ),
              children: [
                Text(
                  font.licenseName,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                SelectableText(font.text, style: _licenseTextStyle(context)),
              ],
            );
          },
        ),
      ),
    );
  }
}

import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/novel_reader_settings.dart';
import '../../theme/app_icon_sizes.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_spacing.dart';
import '../../theme/novel_reader_theme.dart';
import '../../widgets/reader_status_settings.dart';
import '../../widgets/section_header.dart';
import '../../widgets/select_tile.dart';

/// 小说阅读设置：排版、命名配色方案（内置 + 多个自定义）与常亮。
/// 阅读背景固定跟随系统亮暗，浅色/深色分别绑定方案；
/// 状态组件设置共享漫画阅读器的全局配置。
class NovelReaderSettingsSheet extends StatefulWidget {
  const NovelReaderSettingsSheet({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.systemBrightness,
  });

  final NovelReaderSettings settings;
  final ValueChanged<NovelReaderSettings> onChanged;

  /// 当前系统亮暗，用于实时预览当前生效配色。
  final Brightness systemBrightness;

  @override
  State<NovelReaderSettingsSheet> createState() =>
      _NovelReaderSettingsSheetState();
}

class _NovelReaderSettingsSheetState extends State<NovelReaderSettingsSheet> {
  late NovelReaderSettings _settings = widget.settings;

  @override
  void didUpdateWidget(covariant NovelReaderSettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings) _settings = widget.settings;
  }

  void _change(NovelReaderSettings settings) {
    setState(() => _settings = settings);
    widget.onChanged(settings);
  }

  String _themeName(String id) {
    final l10n = AppLocalizations.of(context)!;
    for (final theme in _settings.customThemes) {
      if (theme.id == id) return theme.name;
    }
    return switch (id) {
      'paper' => l10n.novelReaderThemePaper,
      'dark' => l10n.novelReaderThemeDark,
      'white' => l10n.novelReaderThemeWhite,
      'green' => l10n.novelReaderThemeGreen,
      _ => l10n.novelReaderThemeWhite,
    };
  }

  List<(String, NovelReaderPalette)> get _allThemes => [
    for (final name in ['paper', 'dark', 'white', 'green'])
      (name, NovelReaderPalette.forThemeId(_settings, name)),
    for (final theme in _settings.customThemes)
      (
        theme.id,
        NovelReaderPalette(
          Color(theme.backgroundColor),
          Color(theme.textColor),
        ),
      ),
  ];

  void _selectTheme(bool dark, String id) {
    _change(
      dark
          ? _settings.copyWith(darkThemeId: id)
          : _settings.copyWith(lightThemeId: id),
    );
  }

  Future<String?> _promptName(String initial) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.novelReaderThemeNameTitle),
        content: TextField(
          key: const ValueKey('novel-theme-name-field'),
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: InputDecoration(
            counterText: '',
            hintText: l10n.novelReaderThemeNameHint,
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('novel-theme-name-cancel'),
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            key: const ValueKey('novel-theme-name-confirm'),
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(l10n.confirmButton),
          ),
        ],
      ),
    );
    // 路由退出动画/焦点清理仍可能再读 controller，等一帧后释放。
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    return result;
  }

  Future<void> _editCustomTheme(NovelReaderCustomTheme theme) async {
    final l10n = AppLocalizations.of(context)!;
    var background = Color(theme.backgroundColor);
    var textColor = Color(theme.textColor);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _ThemeEditDialog(
        theme: theme,
        title: l10n.novelReaderThemeEditTitle(theme.name),
        initialBackground: background,
        initialText: textColor,
        onChanged: (bg, fg) {
          background = bg;
          textColor = fg;
        },
      ),
    );
    if (!mounted || confirmed != true) return;
    _change(
      _settings.upsertCustomTheme(
        theme.copyWith(
          backgroundColor: background.toARGB32(),
          textColor: textColor.toARGB32(),
        ),
      ),
    );
  }

  Future<void> _addCustomTheme() async {
    final l10n = AppLocalizations.of(context)!;
    final name = await _promptName('');
    if (!mounted || name == null || name.isEmpty) return;
    final id = _settings.newCustomThemeId();
    var background = const Color(
      NovelReaderSettings.defaultCustomBackgroundColor,
    );
    var textColor = const Color(NovelReaderSettings.defaultCustomTextColor);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _ThemeEditDialog(
        theme: NovelReaderCustomTheme(id: id, name: name),
        title: l10n.novelReaderThemeEditTitle(name),
        initialBackground: background,
        initialText: textColor,
        onChanged: (bg, fg) {
          background = bg;
          textColor = fg;
        },
      ),
    );
    if (!mounted || confirmed != true) return;
    _change(
      _settings.upsertCustomTheme(
        NovelReaderCustomTheme(
          id: id,
          name: name,
          backgroundColor: background.toARGB32(),
          textColor: textColor.toARGB32(),
        ),
      ),
    );
  }

  Future<void> _removeCustomTheme(NovelReaderCustomTheme theme) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.novelReaderThemeDeleteTitle),
        content: Text(l10n.novelReaderThemeDeleteContent(theme.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.deleteButton),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    _change(_settings.removeCustomTheme(theme.id));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tt = Theme.of(context).textTheme;
    final dark = widget.systemBrightness == Brightness.dark;
    final activeId = _settings.themeIdFor(dark: dark);
    final palette = NovelReaderPalette.forThemeId(_settings, activeId);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.novelReaderSettings,
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: AppSpacing.xl),
          _slider(
            key: const ValueKey('novel-font-size'),
            label: l10n.novelReaderFontSize,
            value: _settings.fontSize,
            min: NovelReaderSettings.minFontSize,
            max: NovelReaderSettings.maxFontSize,
            divisions:
                (NovelReaderSettings.maxFontSize -
                        NovelReaderSettings.minFontSize)
                    .round(),
            onChanged: (value) => _change(_settings.copyWith(fontSize: value)),
          ),
          _slider(
            key: const ValueKey('novel-line-height'),
            label: l10n.novelReaderLineHeight,
            value: _settings.lineHeight,
            min: NovelReaderSettings.minLineHeight,
            max: NovelReaderSettings.maxLineHeight,
            divisions: 20,
            onChanged: (value) =>
                _change(_settings.copyWith(lineHeight: value)),
          ),
          _slider(
            key: const ValueKey('novel-paragraph-spacing'),
            label: l10n.novelReaderParagraphSpacing,
            value: _settings.paragraphSpacing,
            min: NovelReaderSettings.minParagraphSpacing,
            max: NovelReaderSettings.maxParagraphSpacing,
            divisions: 32,
            onChanged: (value) =>
                _change(_settings.copyWith(paragraphSpacing: value)),
          ),
          const Divider(height: AppSpacing.xxl),
          SectionHeader(
            title: l10n.novelReaderTheme,
            icon: Icons.palette_outlined,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            l10n.novelReaderThemeFollowSystem,
            style: tt.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _modeTile(
            key: const ValueKey('novel-light-theme'),
            label: l10n.novelReaderThemeLightMode,
            value: _settings.lightThemeId,
            onChanged: (id) => _selectTheme(false, id),
          ),
          _modeTile(
            key: const ValueKey('novel-dark-theme'),
            label: l10n.novelReaderThemeDarkMode,
            value: _settings.darkThemeId,
            onChanged: (id) => _selectTheme(true, id),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              ActionChip(
                key: const ValueKey('novel-theme-add'),
                avatar: const Icon(Icons.add, size: AppIconSize.sm),
                label: Text(l10n.novelReaderThemeAdd),
                onPressed: _addCustomTheme,
              ),
            ],
          ),
          if (_settings.customThemes.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            for (final theme in _settings.customThemes) _customThemeTile(theme),
          ],
          const SizedBox(height: AppSpacing.lg),
          Container(
            key: const ValueKey('novel-settings-preview'),
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: palette.background,
              borderRadius: AppRadius.lgR,
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Text(
              l10n.novelReaderPreviewText,
              key: const ValueKey('novel-settings-preview-text'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: tt.bodyLarge?.copyWith(
                color: palette.foreground,
                fontSize: _settings.fontSize,
                height: _settings.lineHeight,
              ),
            ),
          ),
          const Divider(height: AppSpacing.xxl),
          SectionHeader(
            title: l10n.readerDisplaySection,
            icon: Icons.display_settings_outlined,
          ),
          SwitchListTile.adaptive(
            key: const ValueKey('novel-keep-screen-on'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.novelReaderKeepScreenOn),
            value: _settings.keepScreenOn,
            onChanged: (value) =>
                _change(_settings.copyWith(keepScreenOn: value)),
          ),
          ReaderStatusSettingsSection(
            onChanged: () => widget.onChanged(_settings),
          ),
        ],
      ),
    );
  }

  Widget _modeTile({
    required Key key,
    required String label,
    required String value,
    required ValueChanged<String> onChanged,
  }) => Builder(
    builder: (context) {
      final tt = Theme.of(context).textTheme;
      return Padding(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: [
            Text(label, style: tt.bodyMedium),
            const Spacer(),
            SelectTile<String>(
              value: _settings.hasTheme(value) ? value : 'white',
              items: [
                for (final (id, _) in _allThemes)
                  SelectItem(id, _themeName(id)),
              ],
              onChanged: onChanged,
            ),
          ],
        ),
      );
    },
  );

  Widget _customThemeTile(NovelReaderCustomTheme theme) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final boundTo = [
      if (_settings.lightThemeId == theme.id) l10n.novelReaderThemeLightMode,
      if (_settings.darkThemeId == theme.id) l10n.novelReaderThemeDarkMode,
    ].join(' / ');
    return Padding(
      key: ValueKey('novel-custom-theme-${theme.id}'),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Color(theme.backgroundColor),
              borderRadius: AppRadius.smR,
              border: Border.all(color: cs.outlineVariant),
            ),
            alignment: Alignment.center,
            child: Text(
              '文',
              style: tt.labelSmall?.copyWith(color: Color(theme.textColor)),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(theme.name, style: tt.bodyMedium),
                if (boundTo.isNotEmpty)
                  Text(
                    boundTo,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('novel-custom-theme-edit-${theme.id}'),
            tooltip: l10n.novelReaderThemeEdit,
            onPressed: () => _editCustomTheme(theme),
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            key: ValueKey('novel-custom-theme-delete-${theme.id}'),
            tooltip: l10n.deleteButton,
            onPressed: () => _removeCustomTheme(theme),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }

  Widget _slider({
    required Key key,
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    final display = value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('$label · $display'),
        Slider(
          key: key,
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: display,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// 单个自定义方案的背景/文字色编辑对话框（色轮 + HEX）。
class _ThemeEditDialog extends StatelessWidget {
  const _ThemeEditDialog({
    required this.theme,
    required this.title,
    required this.initialBackground,
    required this.initialText,
    required this.onChanged,
  });

  final NovelReaderCustomTheme theme;
  final String title;
  final Color initialBackground;
  final Color initialText;
  final void Function(Color background, Color text) onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    var background = initialBackground;
    var text = initialText;
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ColorField(
                label: l10n.novelReaderBackgroundColor,
                initial: initialBackground,
                onChanged: (color) {
                  background = color;
                  onChanged(background, text);
                },
              ),
              const SizedBox(height: AppSpacing.md),
              _ColorField(
                label: l10n.novelReaderTextColor,
                initial: initialText,
                onChanged: (color) {
                  text = color;
                  onChanged(background, text);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.confirmButton),
        ),
      ],
    );
  }
}

class _ColorField extends StatelessWidget {
  const _ColorField({
    required this.label,
    required this.initial,
    required this.onChanged,
  });

  final String label;
  final Color initial;
  final ValueChanged<Color> onChanged;

  Future<void> _pick(BuildContext context) async {
    var selected = initial;
    final didSelect =
        await ColorPicker(
          color: initial,
          onColorChanged: (color) => selected = color,
          pickersEnabled: const <ColorPickerType, bool>{
            ColorPickerType.both: false,
            ColorPickerType.primary: false,
            ColorPickerType.accent: false,
            ColorPickerType.bw: false,
            ColorPickerType.custom: false,
            ColorPickerType.wheel: true,
          },
          enableShadesSelection: false,
          showColorCode: true,
          colorCodeHasColor: true,
          showEditIconButton: true,
          wheelDiameter: (MediaQuery.sizeOf(context).width - AppSpacing.lg * 4)
              .clamp(120.0, 220.0)
              .toDouble(),
          wheelWidth: AppSpacing.xl,
          wheelSquareBorderRadius: AppRadius.md,
          wheelHasBorder: true,
          heading: Text(label),
          borderRadius: AppRadius.md,
        ).showPickerDialog(
          context,
          constraints: const BoxConstraints(maxWidth: 460),
          insetPadding: const EdgeInsets.all(AppSpacing.lg),
        );
    if (didSelect) onChanged(selected);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isBackground =
        label == AppLocalizations.of(context)!.novelReaderBackgroundColor;
    return ListTile(
      key: ValueKey(
        isBackground ? 'novel-theme-edit-background' : 'novel-theme-edit-text',
      ),
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: initial,
          borderRadius: AppRadius.smR,
          border: Border.all(color: cs.outlineVariant),
        ),
      ),
      title: Text(label, style: tt.bodyMedium),
      subtitle: Text(
        '#${(initial.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
      ),
      onTap: () => _pick(context),
    );
  }
}

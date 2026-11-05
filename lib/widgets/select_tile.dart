import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../utils/adaptive_motion.dart';

/// 「最多显示 N 个字符」对应的宽度上限。
///
/// 数字与全角汉字是两极：数字 ≈0.55em，CJK 全角 ≈1em，只按数字量会让中文
/// 标签的上限远小于「N 个字」的观感（真机上数字更窄，问题更明显）。取两者
/// 较大值，保证 N 个字符无论中英文都放得下。按字符数而非固定像素，是因为
/// 同一段文字在不同字体/字号下宽度差很多，而「最多显示几个字」才是要保证
/// 的观感。
double _maxCharactersWidth(
  BuildContext context,
  int characters,
  TextStyle? style,
) {
  final scaler = MediaQuery.textScalerOf(context);
  double widthOf(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    return painter.size.width;
  }

  return math.max(widthOf('0' * characters), widthOf('字' * characters));
}

/// 标签文本宽度（单行，不折行）。
double _labelTextWidth(BuildContext context, String text, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  return painter.size.width;
}

/// RikkaHub `Select` 的 Flutter 版：胶囊形触发器（tonal 叠色）+ 箭头随
/// 展开/收起上下翻转，点击弹出与触发器等宽的下拉菜单（Overlay 跟随
/// 锚点，点外部自动收起）。
///
/// 用法（放 ListTile 的 trailing）：
/// ```dart
/// trailing: SelectTile<String>(
///   value: _locale,
///   items: [
///     SelectItem('', l10n.languageSystem),
///     SelectItem('zh', l10n.languageSimplified),
///   ],
///   onChanged: _user.setLocale,
/// ),
/// ```
final class SelectTile<T> extends StatefulWidget {
  final T value;
  final List<SelectItem<T>> items;
  final ValueChanged<T> onChanged;

  /// 胶囊前景色;null 用默认正文色。
  final Color? foregroundColor;

  /// 胶囊背景色;null 用 tonal 叠色(容器色 + 8% primary)。
  final Color? backgroundColor;

  /// 胶囊描边;null 无边框。
  final BorderSide? borderSide;

  /// 胶囊左侧图标(可选),用于保留渠道徽标那种带图标的外观。
  final IconData? leadingIcon;

  /// 下拉菜单（以及胶囊标签）最多显示的字符数；null 表示不限，跟随触发器宽度。
  ///
  /// 菜单默认与触发器等宽，长账号名会把菜单撑得很宽，所以需要限制的场景（如
  /// 账号中心）传一个字符数，超出部分省略号截断。胶囊宽度按同一上限收窄，
  /// 菜单最多比它宽出左右内边距。
  final int? menuMaxCharacters;

  const SelectTile({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.foregroundColor,
    this.backgroundColor,
    this.borderSide,
    this.leadingIcon,
    this.menuMaxCharacters,
  });

  @override
  State<SelectTile<T>> createState() => _SelectTileState<T>();
}

final class SelectItem<T> {
  final T value;
  final String label;

  /// 胶囊里显示的短文本；缺省用 [label]（菜单项始终显示 [label]）。
  final String? compactLabel;

  /// 菜单项（及未指定 [SelectTile.leadingIcon] 时的胶囊）图标。
  final IconData? icon;

  /// 菜单项文本/图标颜色；缺省用主题色（选中项 primary、其余 onSurface）。
  final Color? color;

  const SelectItem(
    this.value,
    this.label, {
    this.compactLabel,
    this.icon,
    this.color,
  });

  String get pillLabel => compactLabel ?? label;
}

class _SelectTileState<T> extends State<SelectTile<T>> {
  final _layerLink = LayerLink();
  OverlayEntry? _menuEntry;
  double? _menuWidth;
  bool _expanded = false;

  /// 菜单里最长标签的实测宽度，作为菜单宽度上限；null 表示不限。
  double? _labelWidth;

  /// 量一次最长标签。不能用当前标签量：宽度会随选中项变化，切换账号时菜单
  /// 和胶囊会跟着忽宽忽窄。样式变化（字号/字体）也要重新量。
  void _measureLabelWidth() {
    final maxCharacters = widget.menuMaxCharacters;
    if (maxCharacters == null) {
      _labelWidth = null;
      return;
    }
    final style = Theme.of(context).textTheme.bodyMedium;
    var widest = 0.0;
    for (final item in widget.items) {
      final width = _labelTextWidth(context, item.label, style);
      if (width > widest) widest = width;
    }
    // 过长标签会被省略号截断，所以同时按「最多 N 个字符」封顶，保证胶囊和
    // 菜单都不会被超长账号名撑开。
    final cap = _maxCharactersWidth(context, maxCharacters, style);
    _labelWidth = widest < cap ? widest : cap;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _measureLabelWidth();
    _refreshMenuAfterLayout();
  }

  @override
  void didUpdateWidget(covariant SelectTile<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _measureLabelWidth();
    _refreshMenuAfterLayout();
  }

  void _refreshMenuAfterLayout() {
    if (_menuEntry == null) return;
    // Refresh labels/selection and measure the capsule after its new layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _menuEntry == null) return;
      _menuWidth = context.size?.width;
      _menuEntry?.markNeedsBuild();
    });
  }

  ({double width, double horizontalOffset}) _menuGeometry() {
    final preferredWidth = _labelWidth == null
        ? _menuWidth ?? 0
        : math.max(_menuWidth ?? 0, _labelWidth! + AppSpacing.lg * 2);
    final box = context.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) {
      return (width: preferredWidth, horizontalOffset: 0);
    }
    // 宽菜单向屏幕内平移；再宽也不能超出安全区两侧。
    final padding = MediaQuery.of(context).padding;
    final left = padding.left + AppSpacing.sm;
    final right = overlayBox.size.width - padding.right - AppSpacing.sm;
    final width = math.min(preferredWidth, math.max(0.0, right - left));
    final triggerLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox).dx;
    final menuLeft = triggerLeft.clamp(left, math.max(left, right - width));
    return (width: width, horizontalOffset: menuLeft - triggerLeft);
  }

  void _dismissMenu() {
    _menuEntry?.remove();
    _menuEntry = null;
    if (_expanded) setState(() => _expanded = false);
  }

  /// 菜单是否需要向上弹出。
  ///
  /// 触发器贴近屏幕底部时（如底部弹层里的设置项），向下展开会被裁掉，
  /// 这时把菜单贴在触发器上沿。
  bool _shouldOpenUpward(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return false;

    final triggerTop = box.localToGlobal(Offset.zero, ancestor: overlayBox).dy;
    final overlayHeight = overlayBox.size.height;
    final estimatedMenuHeight = widget.items.length * 44.0 + 16;
    final spaceBelow = overlayHeight - (triggerTop + box.size.height);

    return spaceBelow < estimatedMenuHeight && triggerTop > spaceBelow;
  }

  /// 菜单可用高度：触发器到屏幕安全区边缘的空间。
  ///
  /// 选项很多（如轻小说的分卷）时菜单不再无限长，超出该高度就在菜单内部
  /// 滚动；触发器贴边时保底一个选项高度，保证菜单仍然可用。
  double _menuMaxHeight(bool openUpward) {
    final box = context.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return double.infinity;
    final padding = MediaQuery.of(context).padding;
    final triggerTop = box.localToGlobal(Offset.zero, ancestor: overlayBox).dy;
    final available = openUpward
        ? triggerTop - padding.top - AppSpacing.sm
        : overlayBox.size.height -
              (triggerTop + box.size.height) -
              padding.bottom -
              AppSpacing.sm;
    return math.max(available, 48.0);
  }

  void _toggle() {
    if (_expanded) {
      _dismissMenu();
      return;
    }
    setState(() => _expanded = true);
    final overlay = Overlay.of(context);
    _menuWidth = context.size?.width;
    final openUpward = _shouldOpenUpward(context);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    _menuEntry = OverlayEntry(
      builder: (context) {
        final geometry = _menuGeometry();
        return Stack(
          children: [
            // 全屏透明捕获层：点外部收起（带方向性返回手势穿透）。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _dismissMenu,
                onPanStart: (_) => _dismissMenu(),
              ),
            ),
            CompositedTransformFollower(
              link: _layerLink,
              offset: Offset(geometry.horizontalOffset, 0),
              targetAnchor: openUpward
                  ? Alignment.topLeft
                  : Alignment.bottomLeft,
              followerAnchor: openUpward
                  ? Alignment.bottomLeft
                  : Alignment.topLeft,
              child: SizedBox(
                // 默认与触发器等宽；设了字符上限时按「最长标签（封顶后）」定宽，
                // 但不比触发器窄，短列表仍保持原有的等宽观感。
                width: geometry.width,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  color: cs.surfaceContainerHigh,
                  // 选项多时按触发器到屏幕边缘的可用空间封顶，菜单内部滚动。
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: _menuMaxHeight(openUpward),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final item in widget.items)
                            InkWell(
                              onTap: () {
                                widget.onChanged(item.value);
                                _dismissMenu();
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                child: Row(
                                  children: [
                                    if (item.icon != null) ...[
                                      Icon(
                                        item.icon,
                                        size: 18,
                                        color:
                                            item.color ??
                                            (item.value == widget.value
                                                ? cs.primary
                                                : cs.onSurfaceVariant),
                                      ),
                                      const SizedBox(width: 10),
                                    ],
                                    Expanded(
                                      child: Text(
                                        item.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: tt.bodyMedium?.copyWith(
                                          color:
                                              item.color ??
                                              (item.value == widget.value
                                                  ? cs.primary
                                                  : cs.onSurface),
                                          fontWeight: item.value == widget.value
                                              ? FontWeight.w600
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    overlay.insert(_menuEntry!);
  }

  @override
  void dispose() {
    _menuEntry?.remove();
    _menuEntry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final label =
        widget.items
            .where((i) => i.value == widget.value)
            .map((i) => i.pillLabel)
            .firstOrNull ??
        '';
    // 可选外观覆盖:默认仍是 tonal 叠色胶囊,调用方可换成带图标/描边的徽标样式。
    final background =
        widget.backgroundColor ??
        Color.alphaBlend(
          cs.primary.withValues(alpha: 0.08),
          cs.surfaceContainerHighest,
        );
    final foreground = widget.foregroundColor ?? tt.bodyMedium?.color;

    return CompositedTransformTarget(
      link: _layerLink,
      child: Material(
        // tonalElevation 4 的近似：容器色上叠一层低透明度 primary。
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.fullR,
          side: widget.borderSide ?? BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _toggle,
          borderRadius: AppRadius.fullR,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.leadingIcon != null) ...[
                  Icon(widget.leadingIcon, size: 18, color: foreground),
                  const SizedBox(width: 6),
                ],
                // 通用硬上限 168；设了字符上限时标签跟着收窄，否则超长账号
                // 名会把胶囊撑满 168，菜单宽度又被胶囊顶破上限。窄屏或大字号
                // 下外围图标与内边距会先吃掉宽度，Flexible 让标签继续收缩，
                // 而不是把整行撑破。
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: _labelWidth == null
                          ? 168
                          : math.min(168.0, _labelWidth!),
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodyMedium?.copyWith(color: foreground),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                AnimatedRotation(
                  key: ValueKey(prefersReducedMotion(context)),
                  turns: _expanded ? 0.5 : 0,
                  duration: adaptiveDuration(
                    context,
                    const Duration(milliseconds: 150),
                  ),
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: 18,
                    // 未传 foregroundColor 时保持改造前的 onSurfaceVariant,只
                    // 有显式覆盖(如渠道 Beta 徽标)才换成前景色。
                    color: widget.foregroundColor ?? cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

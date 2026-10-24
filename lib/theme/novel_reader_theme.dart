import 'package:flutter/material.dart';

import '../models/novel_reader_settings.dart';
import 'reader_chrome.dart';

/// 阅读纸张只根据系统亮暗选择方案，不受 App 的强制主题影响。
@immutable
class NovelReaderPalette {
  const NovelReaderPalette(this.background, this.foreground);

  final Color background;
  final Color foreground;

  ThemeData applyTo(ThemeData base) => base.copyWith(
    colorScheme: ColorScheme.fromSeed(
      seedColor: base.colorScheme.primary,
      brightness: ThemeData.estimateBrightnessForColor(background),
      surface: background,
      onSurface: foreground,
    ),
    iconTheme: base.iconTheme.copyWith(color: foreground),
    textTheme: base.textTheme.apply(
      bodyColor: foreground,
      displayColor: foreground,
    ),
  );

  static NovelReaderPalette resolve(
    NovelReaderSettings settings,
    Brightness systemBrightness,
  ) => forThemeId(
    settings,
    settings.themeIdFor(dark: systemBrightness == Brightness.dark),
  );

  static NovelReaderPalette forThemeId(
    NovelReaderSettings settings,
    String id,
  ) {
    for (final theme in settings.customThemes) {
      if (theme.id == id) {
        return NovelReaderPalette(
          Color(theme.backgroundColor),
          Color(theme.textColor),
        );
      }
    }
    return switch (id) {
      'paper' => const NovelReaderPalette(
        Color(NovelReaderSettings.defaultCustomBackgroundColor),
        Color(NovelReaderSettings.defaultCustomTextColor),
      ),
      'dark' => const NovelReaderPalette(
        ReaderChrome.surface,
        ReaderChrome.onSurfaceMuted,
      ),
      'green' => const NovelReaderPalette(Color(0xFFE0EAD7), Color(0xFF2F3A30)),
      _ => const NovelReaderPalette(Color(0xFFFFFFFF), Color(0xFF212121)),
    };
  }
}

/// 书签段落闪光高亮：浅底卡片。装饰画在段落矩形之外的留白里
/// （向外扩不参与布局），高亮出现/消失正文零位移；间距按 fontSize
/// 的比例计算，随字号缩放。纯静态平涂，无渐变，墨水屏友好。
/// [opacity] 挂淡入淡出动画，逐帧重绘，不触发整树 rebuild。
class NovelHighlightPainter extends CustomPainter {
  NovelHighlightPainter({
    required this.color,
    required this.fontSize,
    this.opacity,
    super.repaint,
  });

  final Color color;

  /// 字号，用于按比例推导外扩间距与圆角。
  final double fontSize;

  /// 整体透明度动画，null 或未动画时视为 1。
  final Animation<double>? opacity;

  double get _t => opacity?.value ?? 1;

  @override
  void paint(Canvas canvas, Size size) {
    final t = _t;
    if (t <= 0) return;
    final rect = Rect.fromLTWH(
      -fontSize * 0.6,
      -fontSize * 0.46,
      size.width + fontSize * 1.2,
      size.height + fontSize * 0.92,
    );
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(fontSize * 0.44),
    );
    canvas.drawRRect(
      rrect,
      Paint()..color = color.withValues(alpha: 0.12 * t),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = color.withValues(alpha: 0.3 * t)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(NovelHighlightPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.fontSize != fontSize;
}


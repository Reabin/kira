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
    textTheme: base.textTheme.apply(bodyColor: foreground, displayColor: foreground),
  );

  static NovelReaderPalette resolve(
    NovelReaderSettings settings,
    Brightness systemBrightness,
  ) => forThemeId(settings, settings.themeIdFor(dark: systemBrightness == Brightness.dark));

  static NovelReaderPalette forThemeId(NovelReaderSettings settings, String id) {
    for (final theme in settings.customThemes) {
      if (theme.id == id) {
        return NovelReaderPalette(Color(theme.backgroundColor), Color(theme.textColor));
      }
    }
    return switch (id) {
      'paper' => const NovelReaderPalette(
        Color(NovelReaderSettings.defaultCustomBackgroundColor),
        Color(NovelReaderSettings.defaultCustomTextColor),
      ),
      'dark' => const NovelReaderPalette(ReaderChrome.surface, ReaderChrome.onSurfaceMuted),
      'green' => const NovelReaderPalette(Color(0xFFE0EAD7), Color(0xFF2F3A30)),
      _ => const NovelReaderPalette(Color(0xFFFFFFFF), Color(0xFF212121)),
    };
  }
}

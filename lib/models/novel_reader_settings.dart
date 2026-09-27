import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_logger.dart';
import '../utils/json_helpers.dart';

enum NovelReaderTheme { paper, dark, white, green }

/// ID 与名称分离：重命名不会改变浅色/深色模式的选择。
@immutable
class NovelReaderCustomTheme {
  const NovelReaderCustomTheme({
    required this.id,
    required this.name,
    int backgroundColor = NovelReaderSettings.defaultCustomBackgroundColor,
    int textColor = NovelReaderSettings.defaultCustomTextColor,
  }) : backgroundColor = backgroundColor < 0 || backgroundColor > 0xFFFFFFFF
           ? NovelReaderSettings.defaultCustomBackgroundColor
           : backgroundColor | 0xFF000000,
       textColor = textColor < 0 || textColor > 0xFFFFFFFF
           ? NovelReaderSettings.defaultCustomTextColor
           : textColor | 0xFF000000;

  final String id;
  final String name;
  final int backgroundColor;
  final int textColor;

  factory NovelReaderCustomTheme.fromJson(Map<String, dynamic> json) =>
      NovelReaderCustomTheme(
        id: jsonString(json, 'id').trim(),
        name: jsonString(json, 'name').trim(),
        backgroundColor: jsonInt(json, 'backgroundColor',
            fallback: NovelReaderSettings.defaultCustomBackgroundColor),
        textColor: jsonInt(json, 'textColor',
            fallback: NovelReaderSettings.defaultCustomTextColor),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'backgroundColor': backgroundColor,
    'textColor': textColor,
  };

  NovelReaderCustomTheme copyWith({String? name, int? backgroundColor, int? textColor}) =>
      NovelReaderCustomTheme(
        id: id,
        name: name ?? this.name,
        backgroundColor: backgroundColor ?? this.backgroundColor,
        textColor: textColor ?? this.textColor,
      );

  @override
  bool operator ==(Object other) => other is NovelReaderCustomTheme &&
      id == other.id && name == other.name &&
      backgroundColor == other.backgroundColor && textColor == other.textColor;

  @override
  int get hashCode => Object.hash(id, name, backgroundColor, textColor);
}

/// 仅保存小说排版、配色与常亮偏好；状态组件直接使用 ReaderSettings。
@immutable
class NovelReaderSettings {
  const NovelReaderSettings({
    double fontSize = defaultFontSize,
    double lineHeight = defaultLineHeight,
    double paragraphSpacing = defaultParagraphSpacing,
    this.lightThemeId = defaultLightThemeId,
    this.darkThemeId = defaultDarkThemeId,
    this.keepScreenOn = true,
  }) : _customThemes = const [],
       fontSize = fontSize != fontSize
           ? defaultFontSize
           : fontSize < minFontSize
           ? minFontSize
           : fontSize > maxFontSize
           ? maxFontSize
           : fontSize,
       lineHeight = lineHeight != lineHeight
           ? defaultLineHeight
           : lineHeight < minLineHeight
           ? minLineHeight
           : lineHeight > maxLineHeight
           ? maxLineHeight
           : lineHeight,
       paragraphSpacing = paragraphSpacing != paragraphSpacing
           ? defaultParagraphSpacing
           : paragraphSpacing < minParagraphSpacing
           ? minParagraphSpacing
           : paragraphSpacing > maxParagraphSpacing
           ? maxParagraphSpacing
           : paragraphSpacing;

  NovelReaderSettings._withThemes(NovelReaderSettings base, List<NovelReaderCustomTheme> themes)
      : fontSize = base.fontSize,
        lineHeight = base.lineHeight,
        paragraphSpacing = base.paragraphSpacing,
        lightThemeId = base.lightThemeId,
        darkThemeId = base.darkThemeId,
        keepScreenOn = base.keepScreenOn,
        _customThemes = List.unmodifiable(themes);

  static const storageKey = 'reader_novel_settings_v1';
  static const minFontSize = 10.0;
  static const maxFontSize = 48.0;
  static const defaultFontSize = 20.0;
  // height < 1 时行盒小于字形高度，中文上下行会重叠，下限只能到 1。
  static const minLineHeight = 1.0;
  static const maxLineHeight = 3.0;
  static const defaultLineHeight = 1.8;
  static const minParagraphSpacing = 0.0;
  static const maxParagraphSpacing = 64.0;
  static const defaultParagraphSpacing = 16.0;
  static const defaultLightThemeId = 'white';
  static const defaultDarkThemeId = 'dark';
  static const legacyCustomThemeId = 'custom-legacy';
  static const defaultCustomBackgroundColor = 0xFFF3EEDC;
  static const defaultCustomTextColor = 0xFF38352D;

  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final String lightThemeId;
  final String darkThemeId;
  final bool keepScreenOn;
  final List<NovelReaderCustomTheme> _customThemes;
  List<NovelReaderCustomTheme> get customThemes => _customThemes;

  static Future<void>? _queue;

  bool hasTheme(String id) => NovelReaderTheme.values.any((theme) => theme.name == id) ||
      _customThemes.any((theme) => theme.id == id);

  /// 对未知/已删除 ID 的回退与存储分离，旧备份也能立即安全显示。
  String themeIdFor({required bool dark}) {
    final id = dark ? darkThemeId : lightThemeId;
    return hasTheme(id) ? id : (dark ? defaultDarkThemeId : defaultLightThemeId);
  }

  String newCustomThemeId() {
    final base = 'custom-${DateTime.now().microsecondsSinceEpoch}';
    var id = base;
    var suffix = 1;
    while (hasTheme(id)) {
      id = '$base-${suffix++}';
    }
    return id;
  }

  factory NovelReaderSettings.fromJson(Map<String, dynamic> json) {
    final legacyTheme = jsonString(json, 'theme');
    final themes = <NovelReaderCustomTheme>[];
    final seen = NovelReaderTheme.values.map((theme) => theme.name).toSet();
    final rawThemes = json['customThemes'];
    if (rawThemes is List) {
      for (final raw in rawThemes) {
        if (raw is! Map<String, dynamic>) continue;
        final theme = NovelReaderCustomTheme.fromJson(raw);
        if (theme.id.isEmpty || theme.name.isEmpty || !seen.add(theme.id)) continue;
        themes.add(theme);
      }
    } else if (legacyTheme == 'custom' ||
        json.containsKey('customBackgroundColor') || json.containsKey('customTextColor')) {
      themes.add(NovelReaderCustomTheme(
        id: legacyCustomThemeId,
        name: '自定义',
        backgroundColor: jsonInt(json, 'customBackgroundColor', fallback: defaultCustomBackgroundColor),
        textColor: jsonInt(json, 'customTextColor', fallback: defaultCustomTextColor),
      ));
    }
    final legacyId = legacyTheme == 'custom'
        ? legacyCustomThemeId
        : NovelReaderTheme.values.any((theme) => theme.name == legacyTheme)
        ? legacyTheme : null;
    return NovelReaderSettings(
      fontSize: jsonDouble(json, 'fontSize', fallback: defaultFontSize),
      lineHeight: jsonDouble(json, 'lineHeight', fallback: defaultLineHeight),
      paragraphSpacing: jsonDouble(json, 'paragraphSpacing', fallback: defaultParagraphSpacing),
      lightThemeId: jsonString(json, 'lightThemeId', fallback: legacyId ?? defaultLightThemeId),
      darkThemeId: jsonString(json, 'darkThemeId', fallback: legacyId ?? defaultDarkThemeId),
      keepScreenOn: jsonBool(json, 'keepScreenOn', fallback: true),
    ).copyWith(customThemes: themes);
  }

  Map<String, dynamic> toJson() => {
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'paragraphSpacing': paragraphSpacing,
    'lightThemeId': themeIdFor(dark: false),
    'darkThemeId': themeIdFor(dark: true),
    'customThemes': _customThemes.map((theme) => theme.toJson()).toList(),
    'keepScreenOn': keepScreenOn,
  };

  NovelReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    String? lightThemeId,
    String? darkThemeId,
    List<NovelReaderCustomTheme>? customThemes,
    bool? keepScreenOn,
  }) {
    final base = NovelReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      lightThemeId: lightThemeId ?? this.lightThemeId,
      darkThemeId: darkThemeId ?? this.darkThemeId,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    );
    final seen = NovelReaderTheme.values.map((theme) => theme.name).toSet();
    final themes = (customThemes ?? _customThemes).where((theme) =>
      theme.id.isNotEmpty && theme.name.trim().isNotEmpty && seen.add(theme.id)).toList();
    // 绑定 ID 原样保留：upsert 顺序上主题可能刚要进入列表，此时不能把
    // 绑定改写成回退值；未知 ID 的兜底只发生在 themeIdFor 展示时。
    return NovelReaderSettings._withThemes(base, themes);
  }

  NovelReaderSettings upsertCustomTheme(NovelReaderCustomTheme theme) => copyWith(
    customThemes: [
      for (final saved in _customThemes) if (saved.id != theme.id) saved,
      theme,
    ],
  );

  NovelReaderSettings removeCustomTheme(String id) => copyWith(
    customThemes: _customThemes.where((theme) => theme.id != id).toList(),
  );

  /// 每次读取当前 prefs，因此导入/重置后无需额外 reload 内存副本。
  static Future<NovelReaderSettings> load({
    Future<SharedPreferences>? prefs,
  }) => _enqueue(() async {
    final preferences = await (prefs ?? SharedPreferences.getInstance());
    try {
      final raw = preferences.get(storageKey);
      if (raw == null) return const NovelReaderSettings();
      if (raw is! String) {
        throw const FormatException('Novel reader settings must be JSON text');
      }
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Novel reader settings must be an object');
      }
      return NovelReaderSettings.fromJson(json);
    } catch (error, stack) {
      unawaited(AppLogger.instance.recordWarning(
        'Ignored invalid novel reader settings (${error.runtimeType})',
        stackTrace: stack,
        source: 'novel_reader_settings.load',
      ));
      return const NovelReaderSettings();
    }
  });

  Future<void> save({Future<SharedPreferences>? prefs}) => _enqueue(() async {
    final preferences = await (prefs ?? SharedPreferences.getInstance());
    if (!await preferences.setString(storageKey, jsonEncode(toJson()))) {
      throw StateError('Novel reader settings persistence failed');
    }
  });

  // 快速拖动字号滑块时，慢写入不能在较新设置之后才落盘。
  static Future<T> _enqueue<T>(Future<T> Function() action) {
    final operation = (_queue ?? Future<void>.value()).then((_) => action());
    late final Future<void> tail;
    void releaseIfIdle() {
      if (identical(_queue, tail)) _queue = null;
    }
    tail = operation.then<void>(
      (_) => releaseIfIdle(),
      onError: (Object error, StackTrace stack) {
        releaseIfIdle();
        unawaited(AppLogger.instance.recordWarning(
          error, stackTrace: stack, source: 'novel_reader_settings',
        ));
      },
    );
    _queue = tail;
    return operation;
  }

  @override
  bool operator ==(Object other) => other is NovelReaderSettings &&
      fontSize == other.fontSize && lineHeight == other.lineHeight &&
      paragraphSpacing == other.paragraphSpacing &&
      themeIdFor(dark: false) == other.themeIdFor(dark: false) &&
      themeIdFor(dark: true) == other.themeIdFor(dark: true) &&
      listEquals(_customThemes, other._customThemes) && keepScreenOn == other.keepScreenOn;

  @override
  int get hashCode => Object.hash(fontSize, lineHeight, paragraphSpacing,
      themeIdFor(dark: false), themeIdFor(dark: true), Object.hashAll(_customThemes), keepScreenOn);
}

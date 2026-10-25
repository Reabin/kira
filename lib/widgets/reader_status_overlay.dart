import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/reader_settings.dart';
import '../models/reader_status_prefs.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/reader_chrome.dart';
import '../utils/app_logger.dart';

/// 阅读器沉浸式状态显示：时间 / 电量 / 网络 / 章节名 / 页码 / 帧率。
///
/// 设计上刻意保持低调：小字号、半透明圆角底、不可点击，
/// 仅提供系统状态与阅读进度的一眼速览，不打扰阅读。
///
/// 配置经 [prefs] 注入：漫画侧默认 [ReaderSettings]（黑白配色），
/// 轻小说侧传入独立 store 并以 [defaultForeground]/[defaultBackground]
/// 给出跟随阅读主题的兜底配色；未手动指定颜色时使用兜底值。
class ReaderStatusOverlay extends StatefulWidget {
  static const double _topPadding = 2;
  static const double _bottomPadding = AppSpacing.xs;
  static const double _iconSize = 14;
  static const _textStyle = TextStyle(
    fontSize: 11,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// 首图避让高度，与状态文字的系统/全局缩放及字体行高保持一致。
  static double reservedHeightFor(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    // 宿主在 Scaffold 之上测量，组件实际继承其 Material 的 bodyMedium。
    var style =
        (Theme.of(context).textTheme.bodyMedium ??
                DefaultTextStyle.of(context).style)
            .merge(_textStyle);
    if (MediaQuery.boldTextOf(context)) {
      style = style.copyWith(fontWeight: FontWeight.bold);
    }
    if (MediaQuery.maybeLineHeightScaleFactorOverrideOf(context)
        case final height?) {
      style = style.copyWith(height: height);
    }
    final painter = TextPainter(
      text: TextSpan(text: '0:00', style: style),
      textDirection: Directionality.of(context),
      textScaler: textScaler,
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
      textHeightBehavior: DefaultTextHeightBehavior.maybeOf(context),
    )..layout();
    final textHeight = painter.height;
    painter.dispose();
    final iconHeight = (IconTheme.of(context).applyTextScaling ?? false)
        ? textScaler.scale(_iconSize)
        : _iconSize;
    return _topPadding +
        (textHeight > iconHeight ? textHeight : iconHeight) +
        _bottomPadding;
  }

  final int currentPage;
  final int totalPages;

  /// 小说等非分页阅读器传入进度文本，替换漫画页码段。
  final String? progressLabel;

  /// 轻小说章节名段位文本；漫画侧不传（段位不渲染）。
  final String? chapterLabel;
  final int? position;

  /// 配置来源；null 时用漫画侧全局 [ReaderSettings]。
  final ReaderStatusPrefs? prefs;

  /// 未手动指定前景色时的兜底（漫画白字、轻小说阅读主题文字色）。
  final Color defaultForeground;

  /// 未手动指定背景色时的兜底（漫画黑底、轻小说阅读主题纸张色）；
  /// 背景不透明度设置作用于该色的 alpha。
  final Color defaultBackground;

  /// 浮层最大宽度。角落位的 Positioned 只锚定一侧，传入的约束是无界的
  /// （maxWidth = infinity），Flexible 章节名拿不到有限约束就不截断，
  /// 整条浮层会按内容全宽排版并向屏幕外溢出。宿主（阅读页）应传入
  /// 屏幕宽度，让「撑满剩余宽度后放不下才省略」有界可依。
  final double? maxWidth;

  const ReaderStatusOverlay({
    super.key,
    this.currentPage = 0,
    this.totalPages = 0,
    this.progressLabel,
    this.chapterLabel,
    this.position,
    this.prefs,
    this.defaultForeground = ReaderChrome.onSurfaceMuted,
    this.defaultBackground = const Color(0xFF000000),
    this.maxWidth,
  });

  @override
  State<ReaderStatusOverlay> createState() => _ReaderStatusOverlayState();
}

class _ReaderStatusOverlayState extends State<ReaderStatusOverlay>
    with SingleTickerProviderStateMixin {
  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _batteryStateSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _clockTimer;
  Ticker? _fpsTicker;
  Timer? _fpsTimer;

  TimeOfDay _time = TimeOfDay.now();
  int? _batteryLevel;
  bool _charging = false;
  int _frameCount = 0;
  double _fps = 0;

  ReaderStatusPrefs get _prefs => widget.prefs ?? ReaderSettings();

  /// 桌面设备（Windows/Linux 无电池）可能返回 -1，此类设备直接隐藏电量段
  bool get _hasBattery => _batteryLevel != null && _batteryLevel! >= 0;
  List<ConnectivityResult> _connectivity = const [];

  bool _tickerEnabled = true;

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      final now = TimeOfDay.now();
      if (now != _time && mounted) setState(() => _time = now);
    });
    _prefs.addListener(_onSettingsChanged);
    _initBattery();
    _initConnectivity();
  }

  @override
  void didUpdateWidget(covariant ReaderStatusOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.prefs != widget.prefs) {
      (oldWidget.prefs ?? ReaderSettings()).removeListener(_onSettingsChanged);
      _prefs.addListener(_onSettingsChanged);
      _syncFps();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _syncFps();
  }

  void _onSettingsChanged() {
    _syncFps();
    if (mounted) setState(() {});
  }

  /// 仅在帧率段可见时驱动连续渲染，隐藏后不再空转。
  void _syncFps() {
    if (!_tickerEnabled || !_prefs.statusOverlayFps) {
      _fpsTicker?.stop();
      _fpsTimer?.cancel();
      _fpsTimer = null;
      _frameCount = 0;
      return;
    }
    _fpsTicker ??= createTicker((_) => _frameCount++);
    if (_fpsTicker!.isActive) return;
    _fpsTicker!.start();
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _fps = _frameCount.toDouble();
        _frameCount = 0;
      });
    });
  }

  void _applyBatteryState(BatteryState state, int level) {
    if (!mounted) return;
    setState(() {
      _batteryLevel = level;
      _charging = state == BatteryState.charging || state == BatteryState.full;
    });
  }

  Future<void> _initBattery() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      if (!mounted) return;
      _applyBatteryState(state, level);
      _batteryStateSub = _battery.onBatteryStateChanged.listen((state) async {
        try {
          _applyBatteryState(state, await _battery.batteryLevel);
        } catch (e, stack) {
          unawaited(
            AppLogger.instance.recordWarning(
              e,
              stackTrace: stack,
              source: 'reader_status_overlay.battery',
            ),
          );
        }
      });
    } catch (e, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: stack,
          source: 'reader_status_overlay.battery',
        ),
      );
    }
  }

  Future<void> _initConnectivity() async {
    try {
      _connectivity = await Connectivity().checkConnectivity();
      if (!mounted) return;
      setState(() {});
      _connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
        if (!mounted) return;
        setState(() => _connectivity = result);
      });
    } catch (e, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: stack,
          source: 'reader_status_overlay.connectivity',
        ),
      );
    }
  }

  @override
  void dispose() {
    _prefs.removeListener(_onSettingsChanged);
    _clockTimer?.cancel();
    _batteryStateSub?.cancel();
    _connectivitySub?.cancel();
    _fpsTicker?.dispose();
    _fpsTimer?.cancel();
    super.dispose();
  }

  IconData get _networkIcon {
    if (_connectivity.contains(ConnectivityResult.wifi) ||
        _connectivity.contains(ConnectivityResult.ethernet)) {
      return Icons.wifi;
    }
    if (_connectivity.contains(ConnectivityResult.mobile)) {
      return Icons.signal_cellular_alt;
    }
    if (_connectivity.isEmpty ||
        _connectivity.contains(ConnectivityResult.none)) {
      return Icons.wifi_off;
    }
    // vpn / bluetooth / other：按有网处理
    return Icons.wifi;
  }

  String get _timeLabel {
    final h = _time.hour.toString().padLeft(2, '0');
    final m = _time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// 电量段图标：随电量变化选型，充电时叠加闪电 —— 与阅读进度
  /// （同为百分比数字）的区分主要靠这个图标。
  IconData get _batteryIcon {
    if (_charging) return Icons.bolt;
    final level = _batteryLevel ?? 0;
    if (level >= 87) return Icons.battery_full;
    if (level >= 50) return Icons.battery_5_bar;
    if (level >= 30) return Icons.battery_3_bar;
    if (level >= 15) return Icons.battery_2_bar;
    return Icons.battery_1_bar;
  }

  @override
  Widget build(BuildContext context) {
    final settings = _prefs;
    // 跟随主题（仅小说侧支持）：忽略手动色，直接用宿主传入的主题兜底色。
    final followTheme = settings.statusOverlayFollowTheme;
    final foregroundOverride = followTheme
        ? null
        : settings.statusOverlayForeground;
    Color foreground = foregroundOverride == null
        ? widget.defaultForeground
        : Color(foregroundOverride);
    final backgroundOverride = followTheme
        ? null
        : settings.statusOverlayBackground;
    final background = backgroundOverride == null
        ? widget.defaultBackground
        : Color(backgroundOverride);
    if (followTheme) {
      // 完全同色会与正文混在一起难以区分：跟随主题时字色调淡一档
      // （前景 70% 混入背景），比正文退后一档但仍清晰可读。
      foreground = Color.alphaBlend(
        foreground.withValues(alpha: 0.7),
        background,
      );
    }
    const iconSize = ReaderStatusOverlay._iconSize;
    final textStyle = ReaderStatusOverlay._textStyle.copyWith(
      color: foreground,
    );

    final segments = <Widget>[];
    void add(Widget w) {
      if (segments.isNotEmpty) {
        segments.add(const SizedBox(width: AppSpacing.sm));
      }
      segments.add(w);
    }

    for (final id in settings.statusOverlayOrder) {
      switch (id) {
        case 'time':
          if (settings.statusOverlayTime) {
            add(Text(_timeLabel, style: textStyle));
          }
          break;
        case 'network':
          if (settings.statusOverlayNetwork) {
            add(Icon(_networkIcon, color: foreground, size: iconSize));
          }
          break;
        case 'battery':
          if (settings.statusOverlayBattery && _hasBattery) {
            add(
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_batteryIcon, color: foreground, size: iconSize),
                  Text('$_batteryLevel%', style: textStyle),
                ],
              ),
            );
          }
          break;
        case 'chapter':
          // 章节名仅在轻小说侧出现。Flexible + 整行 LayoutBuilder：
          // 章节名先吃满剩余宽度，确实放不下才开始省略截断。
          final label = widget.chapterLabel;
          if (settings.statusOverlayChapter &&
              label != null &&
              label.isNotEmpty) {
            add(
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle,
                ),
              ),
            );
          }
          break;
        case 'page':
          // 小说百分比与漫画页码共用同一段位开关：关掉页码段时两者都不显示。
          if (settings.statusOverlayPage) {
            if (widget.progressLabel case final label?) {
              add(Text(label, style: textStyle));
            } else if (widget.totalPages > 0) {
              add(
                Text(
                  '${widget.currentPage}/${widget.totalPages}',
                  style: textStyle,
                ),
              );
            }
          }
          break;
        case 'fps':
          if (settings.statusOverlayFps) {
            add(Text('${_fps.round()} FPS', style: textStyle));
          }
          break;
      }
    }

    // 真机上打孔/刘海状态栏高度可达 48+，组件用固定内边距保持轻薄，
    // 不随系统状态栏高度膨胀。
    // 圆角朝向屏幕中心：依位置选择对应角，其余三角保持直角。
    final pos = widget.position ?? settings.statusOverlayPosition;
    final corner = switch (pos) {
      0 => const BorderRadius.only(
        bottomRight: Radius.circular(AppRadius.md),
      ), // 左上
      1 => const BorderRadius.only(
        bottomLeft: Radius.circular(AppRadius.md),
        bottomRight: Radius.circular(AppRadius.md),
      ), // 顶部中间
      2 => const BorderRadius.only(
        bottomLeft: Radius.circular(AppRadius.md),
      ), // 右上（默认）
      3 => const BorderRadius.only(
        topLeft: Radius.circular(AppRadius.md),
      ), // 右下
      4 => const BorderRadius.only(
        topLeft: Radius.circular(AppRadius.md),
        topRight: Radius.circular(AppRadius.md),
      ), // 底部中间
      5 => const BorderRadius.only(
        topRight: Radius.circular(AppRadius.md),
      ), // 左下
      _ => const BorderRadius.only(bottomLeft: Radius.circular(AppRadius.md)),
    };
    // 角落位：靠屏幕一侧给较大边距（lg=16），内侧给较小边距（10）。
    // 中间位：紧凑居中浮动，左右对称给较大边距（lg=16）。
    final isLeft = pos == 0 || pos == 5;
    final isCenter = pos == 1 || pos == 4;
    Widget overlay = Container(
      padding: EdgeInsets.only(
        top: ReaderStatusOverlay._topPadding,
        right: isCenter ? AppSpacing.lg : (isLeft ? 10 : AppSpacing.lg),
        bottom: ReaderStatusOverlay._bottomPadding,
        left: isCenter ? AppSpacing.lg : (isLeft ? AppSpacing.lg : 10),
      ),
      decoration: BoxDecoration(
        // 背景色默认黑/纸张色，不透明度由设置控制（0=透明，1=不透明）
        color: background.withValues(alpha: settings.statusOverlayOpacity),
        borderRadius: corner,
      ),
      // LayoutBuilder 让 Flexible（章节名）拿到「最大宽 - 内边距 -
      // 其他段位」的剩余约束：短章节名浮层保持 min 收缩，长章节名先
      // 撑满剩余空间，放不下才省略。
      child: LayoutBuilder(
        builder: (context, constraints) =>
            Row(mainAxisSize: MainAxisSize.min, children: segments),
      ),
    );
    if (widget.maxWidth case final maxWidth?) {
      // 约束必须罩住整只浮层（含内边距），否则 padding 会被挤到限宽之外。
      overlay = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: overlay,
      );
    }
    return IgnorePointer(child: overlay);
  }
}

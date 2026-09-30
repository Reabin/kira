import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';

class DisplayModePreference {
  const DisplayModePreference._();

  static const MethodChannel _windowChannel = MethodChannel(
    'io.github.caolib.kira/display_mode',
  );

  /// Candidate rates offered to the user (descending). Each one is capped by
  /// the device maximum so panels never see options above what they report.
  static const _candidateRefreshRates = <int>[165, 144, 120, 90, 60];

  static bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// All refresh rates the device reports: every supported mode, the active
  /// mode and each mode's VRR alternative rates. Returns null when the native
  /// read is unavailable; callers then fall back to [FlutterDisplayMode].
  static Future<List<int>?> loadDeviceRefreshRates() async {
    if (!isSupportedPlatform) return null;
    try {
      final raw = await _windowChannel.invokeMethod<List<dynamic>>(
        'getSupportedRefreshRates',
      );
      if (raw == null) return null;
      final rates = <int>{};
      for (final value in raw) {
        if (value is num) {
          final rate = value.round();
          if (rate > 0) rates.add(rate);
        }
      }
      if (rates.isEmpty) return null;
      return rates.toList()..sort((a, b) => b.compareTo(a));
    } catch (error) {
      debugPrint(
        '[DisplayModePreference] Failed to read device refresh rates: $error',
      );
      return null;
    }
  }

  static Future<List<int>> loadRefreshRates() async {
    final deviceRates = await loadDeviceRefreshRates();
    if (deviceRates != null) return refreshRates(deviceRates);
    // Older builds or a failed native read: fall back to the plugin's mode
    // enumeration, which is less complete on VRR panels but better than none.
    final modes = await FlutterDisplayMode.supported;
    return refreshRates([for (final mode in modes) mode.refreshRate.round()]);
  }

  static Future<int?> activeRefreshRate() async {
    final rate = (await FlutterDisplayMode.active).refreshRate;
    if (!rate.isFinite || rate <= 0) return null;
    final rounded = rate.round();
    return rounded > 0 ? rounded : null;
  }

  /// Picker options for a device reporting [deviceRates]: the candidate pool
  /// capped by the device maximum, merged with the device's own rates.
  /// An empty [deviceRates] means the device could not be inspected at all —
  /// keep the full pool on offer instead of collapsing the list.
  static List<int> refreshRates(List<int> deviceRates) {
    if (deviceRates.isEmpty) return _candidateRefreshRates.toList();
    final rates = <int>{};
    var maxRate = 0;
    for (final rate in deviceRates) {
      if (rate > maxRate) maxRate = rate;
      // Sub-60Hz rates are usually VRR/LTPO power-saving targets, not useful
      // manual preferences for an app-wide setting.
      if (rate >= 60) rates.add(rate);
    }
    for (final rate in _candidateRefreshRates) {
      if (rate <= maxRate) rates.add(rate);
    }
    return rates.toList()..sort((a, b) => b.compareTo(a));
  }

  static Future<bool> applyRefreshRate(
    int refreshRate, {
    List<DisplayMode>? modes,
    DisplayMode? active,
  }) async {
    if (!isSupportedPlatform) return false;

    try {
      if (refreshRate == 0) {
        await FlutterDisplayMode.setPreferredMode(DisplayMode.auto);
        await _setWindowPreferredRefreshRate(0);
        return true;
      }

      final supportedModes = modes ?? await FlutterDisplayMode.supported;
      final activeMode = active ?? await FlutterDisplayMode.active;
      final matches = supportedModes
          .where((mode) => mode.refreshRate.round() == refreshRate)
          .toList();
      if (matches.isEmpty) {
        await FlutterDisplayMode.setPreferredMode(DisplayMode.auto);
        return _setWindowPreferredRefreshRate(refreshRate);
      }

      final picked = matches.firstWhere(
        (mode) =>
            mode.width == activeMode.width && mode.height == activeMode.height,
        orElse: () => matches.first,
      );
      await _setWindowPreferredRefreshRate(0);
      await FlutterDisplayMode.setPreferredMode(picked);
      return true;
    } catch (error) {
      debugPrint(
        '[DisplayModePreference] Failed to apply refresh rate: $error',
      );
      return false;
    }
  }

  static Future<bool> _setWindowPreferredRefreshRate(int refreshRate) async {
    if (!isSupportedPlatform) return false;

    try {
      await _windowChannel.invokeMethod<void>('setPreferredRefreshRate', {
        'refreshRate': refreshRate.toDouble(),
      });
      return true;
    } catch (error) {
      debugPrint(
        '[DisplayModePreference] Failed to set window refresh rate: $error',
      );
      return false;
    }
  }
}

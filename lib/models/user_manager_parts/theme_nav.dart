part of '../user_manager.dart';

extension UserManagerThemeNavPart on UserManager {
  Future<void> setThemeMode(ThemeMode mode) => theme.setThemeMode(mode);

  Future<void> setThemeColor(String themeColor) =>
      theme.setThemeColor(themeColor);

  Future<void> setThemeVariant(DynamicSchemeVariant variant) =>
      theme.setThemeVariant(variant);

  Future<void> setCustomThemeColor(Color color) =>
      theme.setCustomThemeColor(color);

  Future<void> setDarkModeCoverBrightness(
    double value, {
    bool persist = true,
  }) => theme.setDarkModeCoverBrightness(value, persist: persist);

  Future<void> setBottomNavShowLabels(bool enabled) =>
      theme.setBottomNavShowLabels(enabled);

  Future<void> setBottomNavLabelMode(BottomNavLabelMode mode) =>
      theme.setBottomNavLabelMode(mode);

  Future<void> setNavOrder(List<String> order) => theme.setNavOrder(order);

  Future<void> setLastNavKey(String key) => theme.setLastNavKey(key);

  Future<void> setDesktopFontFamily(String fontFamily) async {
    if (_desktopFontFamily == fontFamily) return;
    _desktopFontFamily = fontFamily;
    final prefs = await SharedPreferences.getInstance();
    if (fontFamily.isEmpty) {
      await prefs.remove(UserManager._keyDesktopFontFamily);
    } else {
      await prefs.setString(UserManager._keyDesktopFontFamily, fontFamily);
    }
    _notifyListeners();
  }

  Future<void> setDisplayModeRefreshRate(int refreshRate) =>
      theme.setDisplayModeRefreshRate(refreshRate);

  Future<void> setBookshelfOrdering(String ordering) async {
    _bookshelfOrdering = ordering;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(UserManager._keyBookshelfOrdering, ordering);
    _notifyListeners();
  }

  Future<void> setLogoIndex(int index) => theme.setLogoIndex(index);
}

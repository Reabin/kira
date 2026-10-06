import 'prefs_store.dart';

class RecentUpdatesSettings extends PrefsStore {
  static const preferenceKey = 'home_recent_updates_japanese_only';
  bool japaneseOnly = true;

  Future<void> load() async {
    japaneseOnly = await getBool(preferenceKey) ?? true;
  }

  Future<void> setJapaneseOnly(bool value) async {
    await setBool(preferenceKey, value, notify: false);
    japaneseOnly = value;
    notifyListeners();
  }
}

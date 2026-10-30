import 'prefs_store.dart';

class RecentUpdatesSettings extends PrefsStore {
  static const preferenceKey = 'home_recent_updates_regions_v1';
  static const legacyKey = 'home_recent_updates_japanese_only';
  static const allRegions = {0, 1, 2};
  Set<int> regions = {0};

  Future<void> load() async {
    final saved = await getStringList(preferenceKey);
    if (saved != null) {
      final valid = saved
          .map(int.tryParse)
          .whereType<int>()
          .where(allRegions.contains)
          .toSet();
      regions = valid.isEmpty ? {0} : valid;
    } else {
      regions = await getBool(legacyKey) == false ? {...allRegions} : {0};
    }
  }

  Future<void> setRegions(Set<int> value) async {
    final valid = value.where(allRegions.contains).toSet();
    if (valid.isEmpty) throw ArgumentError('Select at least one region');
    final sorted = valid.toList()..sort();
    await setStringList(
      preferenceKey,
      sorted.map((v) => '$v').toList(),
      notify: false,
    );
    regions = Set.unmodifiable(valid);
    notifyListeners();
  }
}

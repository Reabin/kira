import 'dart:convert';

import '../utils/novel_reading_store.dart';
import '../utils/reading_history.dart';
import 'progress_document.dart';

abstract interface class ProgressLocalStore {
  Future<Map<String, String>> snapshot();
  Future<bool> apply(String key, String? expected, Map<String, dynamic> data);
}

class SharedProgressLocalStore implements ProgressLocalStore {
  final NovelReadingStore novels = NovelReadingStore();

  @override
  Future<Map<String, String>> snapshot() async => {
    ...await ReadingHistory.syncSnapshot(),
    ...await novels.syncSnapshot(),
  };

  @override
  Future<bool> apply(
    String key,
    String? expected,
    Map<String, dynamic> data,
  ) async {
    final merged = Map<String, dynamic>.of(data);
    // Local stores reject timestamps from the future. Revision ordering belongs
    // to logical clocks; a remote device's incorrect clock must not block reading.
    merged['updatedAt'] = DateTime.now().toIso8601String();
    final previous = expected == null
        ? <String, dynamic>{}
        : jsonDecode(expected);
    if (previous is Map<String, dynamic>) {
      // Preserve device-specific text/cover addresses without exporting them.
      for (final field in ['txtAddr', 'cover']) {
        if (previous.containsKey(field)) merged[field] = previous[field];
      }
      final readKey = key.startsWith(NovelReadingStore.prefix)
          ? 'readVolumeIds'
          : 'readChapterUuids';
      final values = <String>{};
      for (final source in [previous[readKey], merged[readKey]]) {
        if (source is List) values.addAll(source.whereType<String>());
      }
      merged[readKey] = values.toList()..sort();
    }
    // Validate again at the storage boundary, not only at download time.
    progressData(key, merged);
    final raw = jsonEncode(merged);
    return key.startsWith(NovelReadingStore.prefix)
        ? novels.applySynced(key, expected, raw)
        : ReadingHistory.applySynced(key, expected, raw);
  }
}

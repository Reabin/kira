import 'dart:convert';

import '../models/novel_reading_progress.dart';
import '../utils/json_helpers.dart';

/// Logical clocks, rather than wall-clock time or maximum page, distinguish
/// continuing a book from concurrent offline reading and intentional rereading.
typedef ProgressClock = Map<String, int>;

bool clockIncludes(ProgressClock a, ProgressClock b) =>
    b.entries.every((entry) => (a[entry.key] ?? 0) >= entry.value);

ProgressClock mergeClocks(Iterable<ProgressClock> clocks) {
  final result = <String, int>{};
  for (final clock in clocks) {
    for (final entry in clock.entries) {
      if (entry.value > (result[entry.key] ?? 0)) {
        result[entry.key] = entry.value;
      }
    }
  }
  return result;
}

class ProgressEntry {
  ProgressEntry({required this.key, required this.data, required this.clock});

  final String key;
  final Map<String, dynamic> data;
  final ProgressClock clock;

  factory ProgressEntry.fromJson(Map<String, dynamic> json) {
    final key = jsonString(json, 'key');
    final data = progressData(key, jsonMap(json, 'data') ?? {});
    final clock = jsonMap(json, 'clock');
    if (clock == null ||
        clock.isEmpty ||
        clock.length > 100 ||
        clock.entries.any(
          (e) =>
              !validDevice(e.key) ||
              e.value is! int ||
              jsonInt(clock, e.key) <= 0,
        )) {
      throw const FormatException('Invalid progress revision');
    }
    return ProgressEntry(
      key: key,
      data: data,
      clock: {for (final e in clock.entries) e.key: jsonInt(clock, e.key)},
    );
  }

  Map<String, dynamic> toJson() => {'key': key, 'data': data, 'clock': clock};
  String get position => progressPosition(data);
  String get name {
    final comicName = jsonString(data, 'comicName').trim();
    final novelName = jsonString(data, 'name').trim();
    return comicName.isNotEmpty
        ? comicName
        : novelName.isNotEmpty
        ? novelName
        : key;
  }
}

bool validDevice(String value) => RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

/// A separate file per installation avoids last-writer-wins replacement of a
/// shared database. Never delete other devices' files or import arbitrary prefs.
class ProgressDocument {
  ProgressDocument({
    required this.device,
    required this.sequence,
    required this.entries,
  });
  final String device;
  final int sequence;
  final Map<String, ProgressEntry> entries;

  factory ProgressDocument.decode(String text) {
    if (utf8.encode(text).length > 8 * 1024 * 1024) {
      throw const FormatException('Progress file exceeds 8 MB');
    }
    final json = jsonDecode(text);
    if (json is! Map<String, dynamic> ||
        json['format'] != 'kira-progress' ||
        json['version'] != 1 ||
        !validDevice(jsonString(json, 'device')) ||
        json['sequence'] is! int ||
        jsonInt(json, 'sequence') < 0 ||
        json['entries'] is! List ||
        jsonList(json, 'entries').length > 20000) {
      throw const FormatException('Invalid or unsupported progress file');
    }
    final entries = <String, ProgressEntry>{};
    for (final raw in jsonList(json, 'entries')) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Invalid progress entry');
      }
      final entry = ProgressEntry.fromJson(raw);
      final ownCounter = entry.clock[jsonString(json, 'device')];
      if (ownCounter == null || ownCounter > jsonInt(json, 'sequence')) {
        throw const FormatException(
          'Progress revision exceeds device sequence',
        );
      }
      if (entries.containsKey(entry.key)) {
        throw const FormatException('Duplicate progress entry');
      }
      entries[entry.key] = entry;
    }
    return ProgressDocument(
      device: jsonString(json, 'device'),
      sequence: jsonInt(json, 'sequence'),
      entries: entries,
    );
  }

  String encode() => jsonEncode({
    'format': 'kira-progress',
    'version': 1,
    'device': device,
    'sequence': sequence,
    'entries': entries.values.map((e) => e.toJson()).toList(),
  });
}

Map<String, dynamic> progressData(String key, Map<String, dynamic> raw) {
  if (key.length > 1024 || key.contains(RegExp(r'[\x00-\x1f]'))) {
    throw const FormatException('Invalid progress key');
  }
  final novel = key.startsWith('novel_reading_history_');
  if (novel) {
    final progress = NovelReadingProgress.fromJson(raw);
    if (key != 'novel_reading_history_${progress.pathWord}') {
      throw const FormatException('Novel progress identity mismatch');
    }
    // Source URLs can carry signed credentials; only positions and labels sync.
    return progress.toJson()
      ..remove('txtAddr')
      ..remove('cover');
  }
  if (!key.startsWith('reading_history_') ||
      key.length <= 'reading_history_'.length ||
      jsonString(raw, 'chapterUuid').isEmpty ||
      raw['page'] is! int ||
      jsonInt(raw, 'page') < 1 ||
      DateTime.tryParse(jsonString(raw, 'updatedAt')) == null) {
    throw const FormatException('Invalid comic progress');
  }
  final marker = key.indexOf('_group_', 'reading_history_'.length);
  final group = marker < 0
      ? 'default'
      : Uri.decodeComponent(key.substring(marker + 7));
  return {
    'group': group,
    'comicName': jsonString(raw, 'comicName'),
    'chapterUuid': jsonString(raw, 'chapterUuid'),
    'chapterName': jsonString(raw, 'chapterName'),
    if (raw['chapterListPage'] is int)
      'chapterListPage': raw['chapterListPage'],
    'page': jsonInt(raw, 'page'),
    'totalPage': jsonInt(raw, 'totalPage'),
    'updatedAt': jsonString(raw, 'updatedAt'),
    'readChapterUuids':
        (jsonList(raw, 'readChapterUuids').whereType<String>().toSet()
              ..add(jsonString(raw, 'chapterUuid')))
            .toList()
          ..sort(),
  };
}

/// Merely opening a reader refreshes updatedAt; that is not a new reading event.
String progressPosition(Map<String, dynamic> data) => jsonEncode({
  for (final key in [
    'chapterUuid',
    'page',
    'volumeId',
    'entryIndex',
    'paragraphIndex',
    'paragraphAlignment',
  ])
    if (data.containsKey(key)) key: data[key],
});

String progressFingerprint(Map<String, dynamic> data) {
  final reads = {
    ...jsonList(data, 'readChapterUuids').whereType<String>(),
    ...jsonList(data, 'readVolumeIds').whereType<String>(),
  }.toList()..sort();
  return jsonEncode([progressPosition(data), reads]);
}

List<ProgressEntry> progressHeads(Iterable<ProgressEntry> entries) {
  final all = entries.toList();
  return all
      .where(
        (a) => !all.any(
          (b) =>
              !identical(a, b) &&
              clockIncludes(b.clock, a.clock) &&
              !clockIncludes(a.clock, b.clock),
        ),
      )
      .toList();
}

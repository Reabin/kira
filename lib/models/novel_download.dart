import '../utils/json_helpers.dart';
import 'novel.dart';

/// Stable origin only; credentials and token fingerprints must not be persisted.
class NovelDownloadIdentity {
  final String host;
  final String accountId;
  const NovelDownloadIdentity({required this.host, this.accountId = 'guest'});

  Map<String, dynamic> toJson() => {'host': host, 'account_id': accountId};

  factory NovelDownloadIdentity.fromJson(Map<String, dynamic> json) {
    final host = jsonString(json, 'host');
    final account = jsonString(json, 'account_id');
    if (host.isEmpty || account.isEmpty) {
      throw const FormatException('小说下载来源无效');
    }
    return NovelDownloadIdentity(host: host, accountId: account);
  }

  @override
  bool operator ==(Object other) =>
      other is NovelDownloadIdentity &&
      other.host == host &&
      other.accountId == accountId;

  @override
  int get hashCode => Object.hash(host, accountId);
}

enum NovelDownloadStatus {
  queued,
  downloading,
  paused,
  completed,
  partial,
  failed,
  unauthorized,
  locked,
  needsRepair,
}

class NovelDownloadTask {
  final NovelBook book;
  final NovelVolume volume;
  final List<NovelVolume> volumes;
  final NovelDownloadIdentity source;
  NovelDownloadStatus status;
  int completed;
  int total;
  int attempts;
  String? error;

  NovelDownloadTask({
    required this.book,
    required this.volume,
    required this.volumes,
    required this.source,
    this.status = NovelDownloadStatus.queued,
    this.completed = 0,
    this.total = 1,
    this.attempts = 0,
    this.error,
  });

  String get pathWord => book.pathWord;
  String get volumeId => volume.id;
  String get bookName => book.name;
  String get volumeName => volume.name;
  String get id => '$pathWord\n$volumeId';
  double get progress => total <= 0 ? 0 : completed / total;
  bool get isActive => status == NovelDownloadStatus.downloading;
  bool get isComplete => status == NovelDownloadStatus.completed;

  Map<String, dynamic> toJson() => {
    'book': book.toJson(),
    'volume': volume.toJson(),
    'volumes': volumes.map((e) => e.toJson()).toList(),
    'source': source.toJson(),
    'status': status.name,
    'completed': completed,
    'total': total,
    'attempts': attempts,
    // Error text is deliberately not persisted: remote diagnostics can contain
    // request data. Status is enough to restore the appropriate UI.
  };

  factory NovelDownloadTask.fromJson(Map<String, dynamic> json) {
    final book = NovelBook.fromJson(jsonMap(json, 'book') ?? {});
    final volume = NovelVolume.fromJson(jsonMap(json, 'volume') ?? {});
    if (book.pathWord.isEmpty || volume.id.isEmpty) {
      throw const FormatException('小说下载任务无效');
    }
    return NovelDownloadTask(
      book: book,
      volume: volume,
      volumes: [
        for (final value in jsonList(json, 'volumes'))
          if (jsonMap({'v': value}, 'v') case final value?)
            NovelVolume.fromJson(value),
      ],
      source: NovelDownloadIdentity.fromJson(jsonMap(json, 'source') ?? {}),
      status: NovelDownloadStatus.values.firstWhere(
        (value) => value.name == jsonString(json, 'status'),
        orElse: () => NovelDownloadStatus.paused,
      ),
      completed: jsonInt(json, 'completed').clamp(0, 1 << 30),
      total: jsonInt(json, 'total', fallback: 1).clamp(1, 1 << 30),
      attempts: jsonInt(json, 'attempts').clamp(0, 100),
    );
  }
}

class LocalNovelVolumeInfo {
  final NovelVolume volume;
  final NovelDownloadStatus status;
  final int completed;
  final int total;
  final String? error;
  const LocalNovelVolumeInfo({
    required this.volume,
    required this.status,
    this.completed = 0,
    this.total = 1,
    this.error,
  });

  String get volumeId => volume.id;
  bool get isDownloaded => status == NovelDownloadStatus.completed;
  bool get isReadable => isDownloaded || status == NovelDownloadStatus.partial;
  bool get needsRepair => status == NovelDownloadStatus.needsRepair;
}

class LocalNovelInfo {
  final NovelBook book;

  /// Full offline directory, including volumes not downloaded on this device.
  final List<NovelVolume> volumes;
  final Map<String, LocalNovelVolumeInfo> downloaded;
  final String? coverPath;
  const LocalNovelInfo({
    required this.book,
    required this.volumes,
    required this.downloaded,
    this.coverPath,
  });

  String get pathWord => book.pathWord;
  String get name => book.name;
  int get downloadedCount =>
      downloaded.values.where((v) => v.isDownloaded).length;
  Set<String> get downloadedVolumeIds => {
    for (final entry in downloaded.entries)
      if (entry.value.isDownloaded) entry.key,
  };
  bool get needsRepair => downloaded.values.any((v) => v.needsRepair);
}

class NovelDownloadMigrationProgress {
  final int completed;
  final int total;
  const NovelDownloadMigrationProgress(this.completed, this.total);
  double get fraction => total == 0 ? 1 : completed / total;
}

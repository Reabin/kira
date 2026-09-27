import '../models/novel.dart';
import '../utils/novel_download_store.dart';
import 'novel_repository.dart';

/// 阅读器和目录弹层共用同一个来源，避免本地阅读时仍请求远端目录或插图。
abstract interface class NovelReaderSource {
  bool get localOnly;

  Future<List<NovelVolume>> loadVolumes(String pathWord);

  Future<NovelVolumeDetail> loadVolumeDetail(String pathWord, String volumeId);

  Future<NovelVolumeContent?> loadContent(
    String pathWord,
    String volumeId, {
    bool refresh = false,
    bool cachedOnly = false,
  });

  Future<List<int>> loadImageBytes(
    String pathWord,
    String volumeId,
    String url,
  );
}

class RepositoryNovelReaderSource implements NovelReaderSource {
  const RepositoryNovelReaderSource(this.repository);

  final NovelRepository repository;

  @override
  bool get localOnly => false;

  @override
  Future<List<NovelVolume>> loadVolumes(String pathWord) =>
      repository.loadVolumes(pathWord);

  @override
  Future<NovelVolumeDetail> loadVolumeDetail(
    String pathWord,
    String volumeId,
  ) => repository.loadVolumeDetail(pathWord, volumeId);

  @override
  Future<NovelVolumeContent?> loadContent(
    String pathWord,
    String volumeId, {
    bool refresh = false,
    bool cachedOnly = false,
  }) => cachedOnly
      ? repository.getCachedVolumeContent(pathWord, volumeId)
      : repository.loadVolumeContent(pathWord, volumeId, refresh: refresh);

  @override
  Future<List<int>> loadImageBytes(
    String pathWord,
    String volumeId,
    String url,
  ) => repository.api.getContentBytes(url);
}

class NovelDownloadUnavailableException implements Exception {
  const NovelDownloadUnavailableException();

  @override
  String toString() => 'The downloaded novel volume or asset is unavailable';
}

/// 显式本地来源没有任何网络回退，退出账号或清理阅读缓存也不影响它。
class DownloadedNovelReaderSource implements NovelReaderSource {
  const DownloadedNovelReaderSource(this.store);

  final NovelDownloadStore store;

  @override
  bool get localOnly => true;

  @override
  Future<List<NovelVolume>> loadVolumes(String pathWord) async {
    await store.init();
    return store.getLocalNovelInfo(pathWord)?.volumes ?? const [];
  }

  @override
  Future<NovelVolumeDetail> loadVolumeDetail(
    String pathWord,
    String volumeId,
  ) async {
    await store.init();
    final snapshot = await store.readVolumeSnapshot(pathWord, volumeId);
    if (snapshot == null) throw const NovelDownloadUnavailableException();
    return snapshot.detail;
  }

  @override
  Future<NovelVolumeContent?> loadContent(
    String pathWord,
    String volumeId, {
    bool refresh = false,
    bool cachedOnly = false,
  }) async {
    await store.init();
    final snapshot = await store.readVolumeSnapshot(pathWord, volumeId);
    if (snapshot == null) throw const NovelDownloadUnavailableException();
    return snapshot.content;
  }

  @override
  Future<List<int>> loadImageBytes(
    String pathWord,
    String volumeId,
    String url,
  ) async {
    final bytes = await store.readImageBytes(pathWord, volumeId, url);
    if (bytes == null) throw const NovelDownloadUnavailableException();
    return bytes;
  }
}

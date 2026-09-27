import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/novel/novel_api.dart';
import '../repositories/novel_repository.dart';
import '../utils/novel_bookmark_store.dart';
import '../utils/novel_download_manager.dart';
import '../utils/novel_download_store.dart';
import '../utils/novel_reading_store.dart';
import 'app_providers.dart';

final novelApiProvider = Provider<NovelApi>(
  (ref) => ref.read(apiClientProvider).novel,
);

final novelRepositoryProvider = Provider<NovelRepository>(
  (ref) => NovelRepository(api: ref.read(novelApiProvider)),
);

final novelShelfRepoProvider = Provider<NovelBookshelfRepository>((ref) {
  final repository = NovelBookshelfRepository(api: ref.read(novelApiProvider));
  ref.onDispose(repository.dispose);
  return repository;
});

final novelDownloadStoreProvider = Provider<NovelDownloadStore>(
  (ref) => NovelDownloadStore(),
);

final novelDownloadManagerProvider = Provider<NovelDownloadManager>(
  (ref) => NovelDownloadManager(),
);

final novelReadingStoreProvider = Provider<NovelReadingStore>(
  (ref) => NovelReadingStore(),
);

final novelBookmarkStoreProvider = Provider<NovelBookmarkStore>(
  (ref) => NovelBookmarkStore(),
);

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/bookshelf_repository.dart';
import '../repositories/copy_topic_repository.dart';
import '../repositories/manga_home_repository.dart';
import '../repositories/search_init_repository.dart';

/// Provides a [MangaHomeRepository] instance.
final mangaHomeRepositoryProvider = Provider<MangaHomeRepository>((ref) {
  return MangaHomeRepository();
});

/// Provides a [CopyTopicRepository] instance.
final copyTopicRepositoryProvider = Provider<CopyTopicRepository>((ref) {
  return CopyTopicRepository();
});

/// Provides a [SearchInitRepository] instance.
final searchInitRepositoryProvider = Provider<SearchInitRepository>((ref) {
  return SearchInitRepository();
});

/// Provides a [ComicBookshelfRepository] instance.
final comicBookshelfRepoProvider = Provider<ComicBookshelfRepository>((ref) {
  return ComicBookshelfRepository();
});

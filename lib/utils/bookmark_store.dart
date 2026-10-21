import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 漫画书签：记录阅读器中用户手动标记的位置（漫画 + 章节 + 页码）。
///
/// 与 `ReadingHistory`（自动记录阅读进度）不同，书签由用户主动添加。
/// 全量列表存储在单个 `comic_bookmarks_v1` 键下（不带 cache_ 前缀，
/// 因此会随设置备份导出，也不会被缓存清理误删）。
class ComicBookmark {
  final String pathWord;
  final String comicName;

  /// 封面 URL，打书签时从漫画详情本地缓存读取（无网络请求）。
  /// 旧版本书签可能为空，列表页退化为占位图。
  final String cover;

  /// 打书签时所在的章节分组，从详情缓存读取。
  /// 旧版本书签可能为空，进入阅读器时回退到默认分组键。
  final String group;
  final String chapterUuid;
  final String chapterName;
  final int page;
  final DateTime? updatedAt;

  const ComicBookmark({
    required this.pathWord,
    required this.comicName,
    this.cover = '',
    this.group = '',
    required this.chapterUuid,
    required this.chapterName,
    required this.page,
    this.updatedAt,
  });

  /// 同一章节同一页视为同一书签。
  String get id => '$chapterUuid:$page';

  factory ComicBookmark.fromJson(Map<String, dynamic> json) {
    return ComicBookmark(
      pathWord: json['pathWord']?.toString() ?? '',
      comicName: json['comicName']?.toString() ?? '',
      cover: json['cover']?.toString() ?? '',
      group: json['group']?.toString() ?? '',
      chapterUuid: json['chapterUuid']?.toString() ?? '',
      chapterName: json['chapterName']?.toString() ?? '',
      page: _readInt(json['page']) ?? 1,
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
    );
  }

  Map<String, dynamic> toJson() => {
    'pathWord': pathWord,
    'comicName': comicName,
    if (cover.isNotEmpty) 'cover': cover,
    if (group.isNotEmpty) 'group': group,
    'chapterUuid': chapterUuid,
    'chapterName': chapterName,
    'page': page,
    'updatedAt': ?updatedAt?.toIso8601String(),
  };

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// 书签组的元数据：书签被删光后组头仍要保留（封面、书名、继续阅读入口），
/// 因此在加书签时单独记一份，删除书签时不动它。
@immutable
class ComicBookmarkGroup {
  const ComicBookmarkGroup({
    required this.pathWord,
    required this.comicName,
    this.cover = '',
    required this.updatedAt,
  });

  final String pathWord;
  final String comicName;
  final String cover;
  final DateTime updatedAt;

  factory ComicBookmarkGroup.fromJson(Map<String, dynamic> json) =>
      ComicBookmarkGroup(
        pathWord: json['pathWord']?.toString() ?? '',
        comicName: json['comicName']?.toString() ?? '',
        cover: json['cover']?.toString() ?? '',
        updatedAt:
            DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  Map<String, dynamic> toJson() => {
    'pathWord': pathWord,
    'comicName': comicName,
    if (cover.isNotEmpty) 'cover': cover,
    'updatedAt': updatedAt.toIso8601String(),
  };
}

/// 书签 store：`ChangeNotifier` 单例，内存持有全量列表（按标记时间倒序，
/// 最新在前），变更时持久化到 SharedPreferences 并通知监听者。
class BookmarkStore extends ChangeNotifier {
  BookmarkStore._();

  static final BookmarkStore _instance = BookmarkStore._();
  factory BookmarkStore() => _instance;

  static const _key = 'comic_bookmarks_v1';

  /// 组元数据单独存一个键：清空书签时保留，组头才不会跟着消失。
  static const groupsStorageKey = 'comic_bookmark_groups_v1';

  /// 数量上限，超出时淘汰最旧的书签。
  @visibleForTesting
  static const maxBookmarks = 500;

  final List<ComicBookmark> _bookmarks = [];
  final List<ComicBookmarkGroup> _groups = [];
  bool _loaded = false;
  bool _restoring = false;
  final Set<Future<void>> _writes = {};

  List<ComicBookmark> get bookmarks => List.unmodifiable(_bookmarks);

  /// 曾收藏过的漫画（含书签已删光的），按最近一次加书签的时间倒序。
  List<ComicBookmarkGroup> get groups => List.unmodifiable(_groups);

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          _bookmarks
            ..clear()
            ..addAll(
              list
                  .whereType<Map>()
                  .map(
                    (e) => ComicBookmark.fromJson(Map<String, dynamic>.from(e)),
                  )
                  .where(
                    (b) => b.pathWord.isNotEmpty && b.chapterUuid.isNotEmpty,
                  ),
            );
        }
      } catch (_) {
        // 数据损坏时视为空列表，下次写入自动覆盖。
      }
    }
    final rawGroups = prefs.getString(groupsStorageKey);
    if (rawGroups != null) {
      try {
        final list = jsonDecode(rawGroups);
        if (list is List) {
          _groups
            ..clear()
            ..addAll(
              list
                  .whereType<Map>()
                  .map(
                    (e) => ComicBookmarkGroup.fromJson(
                      Map<String, dynamic>.from(e),
                    ),
                  )
                  .where((g) => g.pathWord.isNotEmpty),
            );
        }
      } catch (_) {
        // 同上：损坏时视为空，下次写入覆盖。
      }
    }
    _syncGroupsFromBookmarks();
  }

  /// 补上「有书签但还没有组元数据」的作品：组元数据是后加的功能，
  /// 老书签没有对应记录，否则详情页书签按钮会显示成未添加、删光书签后组也会消失。
  /// 只改内存，不在这里写盘——读取路径保持只读，下次任何写入会带上补齐的组。
  void _syncGroupsFromBookmarks() {
    var added = false;
    for (final bookmark in _bookmarks) {
      if (hasGroup(bookmark.pathWord)) continue;
      _groups.add(
        ComicBookmarkGroup(
          pathWord: bookmark.pathWord,
          comicName: bookmark.comicName,
          cover: bookmark.cover,
          updatedAt:
              bookmark.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
        ),
      );
      added = true;
    }
    if (added) _groups.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  bool isBookmarked(String chapterUuid, int page) =>
      _bookmarks.any((b) => b.chapterUuid == chapterUuid && b.page == page);

  /// 该漫画是否已在书签页占有一个分组（不论组内是否还有书签）。
  bool hasGroup(String pathWord) {
    for (final group in _groups) {
      if (group.pathWord == pathWord) return true;
    }
    return false;
  }

  /// 只登记分组、不加具体书签：详情页的「加入书签」入口。
  Future<void> addGroup({
    required String pathWord,
    required String comicName,
    String cover = '',
  }) async {
    await ensureLoaded();
    if (_restoring || hasGroup(pathWord)) return;
    _upsertGroup(
      ComicBookmarkGroup(
        pathWord: pathWord,
        comicName: comicName,
        cover: cover,
        updatedAt: DateTime.now(),
      ),
    );
    await _persist();
  }

  /// 取消收藏：分组连同该漫画的书签一起移除，返回被删除的书签。
  Future<List<ComicBookmark>> removeGroup(String pathWord) async {
    await ensureLoaded();
    if (_restoring) return const [];
    final removed = _bookmarks.where((b) => b.pathWord == pathWord).toList();
    final hadGroup = hasGroup(pathWord);
    if (removed.isEmpty && !hadGroup) return const [];
    _bookmarks.removeWhere((b) => b.pathWord == pathWord);
    _groups.removeWhere((g) => g.pathWord == pathWord);
    await _persist();
    return removed;
  }

  /// 切换指定位置的书签状态，返回 true 表示新增、false 表示移除。
  Future<bool> toggle({
    required String pathWord,
    required String comicName,
    String cover = '',
    String group = '',
    required String chapterUuid,
    required String chapterName,
    required int page,
  }) async {
    await ensureLoaded();
    if (_restoring) return isBookmarked(chapterUuid, page);
    final index = _bookmarks.indexWhere(
      (b) => b.chapterUuid == chapterUuid && b.page == page,
    );
    if (index >= 0) {
      _bookmarks.removeAt(index);
      await _persist();
      return false;
    }
    _bookmarks.insert(
      0,
      ComicBookmark(
        pathWord: pathWord,
        comicName: comicName,
        cover: cover,
        group: group,
        chapterUuid: chapterUuid,
        chapterName: chapterName,
        page: page,
        updatedAt: DateTime.now(),
      ),
    );
    if (_bookmarks.length > maxBookmarks) {
      _bookmarks.removeRange(maxBookmarks, _bookmarks.length);
    }
    // 记下组元数据：这之后即使书签被删光，书签页也保留该组。
    _upsertGroup(
      ComicBookmarkGroup(
        pathWord: pathWord,
        comicName: comicName,
        cover: cover,
        updatedAt: DateTime.now(),
      ),
    );
    await _persist();
    return true;
  }

  /// 同一部漫画只留一条组元数据，最新在前；空字段沿用旧值。
  void _upsertGroup(ComicBookmarkGroup group) {
    ComicBookmarkGroup? previous;
    for (final existing in _groups) {
      if (existing.pathWord == group.pathWord) {
        previous = existing;
        break;
      }
    }
    _groups.removeWhere((g) => g.pathWord == group.pathWord);
    _groups.insert(
      0,
      ComicBookmarkGroup(
        pathWord: group.pathWord,
        comicName: group.comicName.isEmpty
            ? previous?.comicName ?? ''
            : group.comicName,
        cover: group.cover.isEmpty ? previous?.cover ?? '' : group.cover,
        updatedAt: group.updatedAt,
      ),
    );
    if (_groups.length > maxBookmarks) {
      _groups.removeRange(maxBookmarks, _groups.length);
    }
  }

  Future<void> remove(String id) async {
    await ensureLoaded();
    if (_restoring) return;
    final index = _bookmarks.indexWhere((b) => b.id == id);
    if (index < 0) return;
    _bookmarks.removeAt(index);
    await _persist();
  }

  /// 删除某部漫画的全部书签，返回被删除的书签（用于撤销）。
  Future<List<ComicBookmark>> removeForComic(String pathWord) async {
    await ensureLoaded();
    if (_restoring) return const [];
    final removed = _bookmarks.where((b) => b.pathWord == pathWord).toList();
    if (removed.isEmpty) return const [];
    _bookmarks.removeWhere((b) => b.pathWord == pathWord);
    await _persist();
    return removed;
  }

  /// 清空全部书签，返回被删除的书签（用于撤销）。
  Future<List<ComicBookmark>> clear() async {
    await ensureLoaded();
    if (_restoring) return const [];
    if (_bookmarks.isEmpty) return const [];
    final removed = List<ComicBookmark>.of(_bookmarks);
    _bookmarks.clear();
    await _persist();
    return removed;
  }

  /// 批量恢复书签（撤销删除），按标记时间倒序归并。
  Future<void> restoreAll(
    List<ComicBookmark> items, {
    List<ComicBookmarkGroup> groups = const [],
  }) async {
    await ensureLoaded();
    if (_restoring) return;
    final existing = _bookmarks.map((b) => b.id).toSet();
    _bookmarks.addAll(items.where((b) => !existing.contains(b.id)));
    _bookmarks.sort(_byNewest);
    if (_bookmarks.length > maxBookmarks) {
      _bookmarks.removeRange(maxBookmarks, _bookmarks.length);
    }
    final knownGroups = _groups.map((group) => group.pathWord).toSet();
    _groups.addAll(groups.where((group) => knownGroups.add(group.pathWord)));
    _groups.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (_groups.length > maxBookmarks) {
      _groups.removeRange(maxBookmarks, _groups.length);
    }
    await _persist();
  }

  static int _byNewest(ComicBookmark a, ComicBookmark b) {
    final at = a.updatedAt;
    final bt = b.updatedAt;
    if (at == null && bt == null) return 0;
    if (at == null) return 1;
    if (bt == null) return -1;
    return bt.compareTo(at);
  }

  Future<void> _persist() async {
    final writing = _write();
    _writes.add(writing);
    try {
      await writing;
    } finally {
      _writes.remove(writing);
    }
  }

  Future<void> _write() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_bookmarks.map((b) => b.toJson()).toList()),
    );
    await prefs.setString(
      groupsStorageKey,
      jsonEncode(_groups.map((g) => g.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<void> pauseForRestore() async {
    _restoring = true;
    await flush();
  }

  Future<void> flush() => Future.wait(_writes.toList());

  void resumeAfterRestore() => _restoring = false;

  /// 从磁盘重新加载。导入备份或重置应用覆写了 SharedPreferences 后调用，
  /// 使内存副本与磁盘一致。
  Future<void> reload() async {
    _loaded = false;
    _bookmarks.clear();
    _groups.clear();
    await ensureLoaded();
    notifyListeners();
  }

  /// 清空内存状态，供测试隔离使用。
  @visibleForTesting
  void debugReset() {
    _bookmarks.clear();
    _groups.clear();
    _loaded = false;
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/novel_reading_progress.dart';
import 'app_logger.dart';
import 'json_helpers.dart';

/// 用户主动标记的轻小说段落，与自动更新的最后阅读进度相互独立。
@immutable
class NovelBookmark {
  NovelBookmark({required NovelReadingProgress position})
    : position = position.copyWith(txtAddr: '') {
    if (pathWord.trim().isEmpty || volumeId.trim().isEmpty) {
      throw ArgumentError('Novel bookmark requires book and volume IDs');
    }
  }

  /// 保存原始目录索引和段落锚点，不保存正文地址、账号或鉴权数据。
  final NovelReadingProgress position;

  String get pathWord => position.pathWord;
  String get name => position.name;
  String get cover => position.cover;
  String get volumeId => position.volumeId;
  String get volumeName => position.volumeName;
  String get chapterName => position.chapterName;
  int get entryIndex => position.entryIndex;
  int get paragraphIndex => position.paragraphIndex;
  double get paragraphAlignment => position.paragraphAlignment;
  double get progress => position.progress;
  DateTime get updatedAt => position.updatedAt;

  /// 同一段落只有一个书签；浮点对齐值不参与身份，避免滚动微移产生重复项。
  String get id => positionId(
    pathWord: pathWord,
    volumeId: volumeId,
    entryIndex: entryIndex,
    paragraphIndex: paragraphIndex,
  );

  static String positionId({
    required String pathWord,
    required String volumeId,
    required int entryIndex,
    required int paragraphIndex,
  }) => jsonEncode([pathWord, volumeId, entryIndex, paragraphIndex]);

  factory NovelBookmark.fromJson(Map<String, dynamic> json) {
    for (final key in ['pathWord', 'volumeId', 'updatedAt']) {
      if (json[key] is! String || jsonString(json, key).trim().isEmpty) {
        throw const FormatException('Invalid novel bookmark identity/date');
      }
    }
    for (final key in ['entryIndex', 'paragraphIndex']) {
      final value = json[key];
      if (value is! int || value < 0) {
        throw const FormatException('Invalid novel bookmark index');
      }
    }
    for (final key in ['name', 'cover', 'volumeName', 'chapterName']) {
      if (json[key] != null && json[key] is! String) {
        throw const FormatException('Invalid novel bookmark label');
      }
    }
    for (final key in ['paragraphAlignment', 'progress']) {
      final value = json[key];
      if (value != null && (value is! num || !value.isFinite)) {
        throw const FormatException('Invalid novel bookmark position');
      }
    }
    final progress = jsonDouble(json, 'progress');
    final updatedAt = DateTime.tryParse(jsonString(json, 'updatedAt'));
    if (updatedAt == null || progress < 0 || progress > 1) {
      throw const FormatException('Invalid novel bookmark progress/date');
    }
    return NovelBookmark(
      position: NovelReadingProgress(
        pathWord: jsonString(json, 'pathWord'),
        name: jsonString(json, 'name'),
        cover: jsonString(json, 'cover'),
        volumeId: jsonString(json, 'volumeId'),
        volumeName: jsonString(json, 'volumeName'),
        chapterName: jsonString(json, 'chapterName'),
        entryIndex: jsonInt(json, 'entryIndex'),
        paragraphIndex: jsonInt(json, 'paragraphIndex'),
        paragraphAlignment: jsonDouble(json, 'paragraphAlignment'),
        progress: progress,
        updatedAt: updatedAt,
      ),
    );
  }

  Map<String, dynamic> toJson() => position.toJson()..remove('txtAddr');
}

/// 书签组的元数据：书签被删光后组头仍要保留（封面、书名、继续阅读入口），
/// 因此在加书签时单独记一份，删除书签时不动它。
@immutable
class NovelBookmarkGroup {
  const NovelBookmarkGroup({
    required this.pathWord,
    required this.name,
    this.cover = '',
    required this.updatedAt,
  });

  final String pathWord;
  final String name;
  final String cover;
  final DateTime updatedAt;

  factory NovelBookmarkGroup.fromJson(Map<String, dynamic> json) =>
      NovelBookmarkGroup(
        pathWord: jsonString(json, 'pathWord'),
        name: jsonString(json, 'name'),
        cover: jsonString(json, 'cover'),
        updatedAt:
            DateTime.tryParse(jsonString(json, 'updatedAt')) ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  Map<String, dynamic> toJson() => {
    'pathWord': pathWord,
    'name': name,
    if (cover.isNotEmpty) 'cover': cover,
    'updatedAt': updatedAt.toIso8601String(),
  };
}

/// 单键持久化、串行读写的书签单例。写入成功才发布内存快照及变更通知。
class NovelBookmarkStore extends ChangeNotifier {
  NovelBookmarkStore._({Future<SharedPreferences>? prefs}) : _prefs = prefs;

  static final NovelBookmarkStore _instance = NovelBookmarkStore._();
  factory NovelBookmarkStore() => _instance;

  @visibleForTesting
  NovelBookmarkStore.forTesting({required Future<SharedPreferences> prefs})
    : _prefs = prefs;

  // 不使用 novel_reading_history_ 前缀，避免被自动阅读历史枚举/清理。
  static const storageKey = 'novel_bookmarks_v1';

  /// 组元数据单独存一个键：清空书签时保留，组头才不会跟着消失。
  static const groupsStorageKey = 'novel_bookmark_groups_v1';
  static const maxBookmarks = 500;

  final Future<SharedPreferences>? _prefs;
  Future<SharedPreferences> get _preferences =>
      _prefs ?? SharedPreferences.getInstance();
  List<NovelBookmark> _bookmarks = const [];
  List<NovelBookmarkGroup> _groups = const [];
  Future<void>? _queue;
  bool _loaded = false;
  bool _restoring = false;
  int _restoreEpoch = 0;

  List<NovelBookmark> get bookmarks => _bookmarks;

  /// 曾收藏过的轻小说（含书签已删光的），按最近一次加书签的时间倒序。
  List<NovelBookmarkGroup> get groups => _groups;

  Future<void> ensureLoaded() => _enqueue(_load);

  bool isBookmarked({
    required String pathWord,
    required String volumeId,
    required int entryIndex,
    required int paragraphIndex,
  }) {
    final id = NovelBookmark.positionId(
      pathWord: pathWord,
      volumeId: volumeId,
      entryIndex: entryIndex,
      paragraphIndex: paragraphIndex,
    );
    return _bookmarks.any((bookmark) => bookmark.id == id);
  }

  /// 返回 true 表示新增，false 表示取消；Future 完成时已持久化。
  Future<bool> toggle({required NovelReadingProgress progress}) {
    final bookmark = NovelBookmark(
      position: progress.copyWith(updatedAt: DateTime.now()),
    );
    return _mutate(
      blocked: () => _bookmarks.any((item) => item.id == bookmark.id),
      action: () async {
        final exists = _bookmarks.any((item) => item.id == bookmark.id);
        // 记下组元数据：这之后即使书签被删光，书签页也保留该组。
        if (!exists) {
          _upsertGroup(
            pathWord: bookmark.pathWord,
            name: bookmark.name,
            cover: bookmark.cover,
          );
        }
        await _commit(
          exists
              ? _bookmarks.where((item) => item.id != bookmark.id)
              : [bookmark, ..._bookmarks],
        );
        return !exists;
      },
    );
  }

  Future<NovelBookmark?> remove(String id) => _mutate(
    blocked: () => null,
    action: () async {
      final index = _bookmarks.indexWhere((item) => item.id == id);
      if (index < 0) return null;
      final removed = _bookmarks[index];
      await _commit(_bookmarks.where((item) => item.id != id));
      return removed;
    },
  );

  Future<List<NovelBookmark>> removeForNovel(String pathWord) => _mutate(
    blocked: () => const <NovelBookmark>[],
    action: () async {
      final removed = _bookmarks
          .where((item) => item.pathWord == pathWord)
          .toList();
      if (removed.isNotEmpty) {
        await _commit(_bookmarks.where((item) => item.pathWord != pathWord));
      }
      return removed;
    },
  );

  Future<List<NovelBookmark>> clear() => _mutate(
    blocked: () => const <NovelBookmark>[],
    action: () async {
      final removed = _bookmarks;
      if (removed.isNotEmpty) await _commit(const []);
      return removed;
    },
  );

  /// 该轻小说是否已在书签页占有一个分组（不论组内是否还有书签）。
  bool hasGroup(String pathWord) =>
      _groups.any((group) => group.pathWord == pathWord);

  /// 只登记分组、不加具体书签：详情页的「加入书签」入口。
  Future<void> addGroup({
    required String pathWord,
    required String name,
    String cover = '',
  }) => _mutate<void>(
    blocked: () {},
    action: () async {
      if (hasGroup(pathWord)) return;
      _upsertGroup(pathWord: pathWord, name: name, cover: cover);
      await _commit(_bookmarks);
    },
  );

  /// 取消收藏：分组连同该轻小说的书签一起移除，返回被删除的书签。
  Future<List<NovelBookmark>> removeGroup(String pathWord) => _mutate(
    blocked: () => const <NovelBookmark>[],
    action: () async {
      final removed = _bookmarks
          .where((item) => item.pathWord == pathWord)
          .toList();
      if (removed.isEmpty && !hasGroup(pathWord)) {
        return const <NovelBookmark>[];
      }
      _groups = List.unmodifiable(
        _groups.where((group) => group.pathWord != pathWord),
      );
      await _commit(_bookmarks.where((item) => item.pathWord != pathWord));
      return removed;
    },
  );

  /// 撤销只补回缺失的书签，不覆盖用户随后重新标记的位置。
  Future<void> restoreAll(List<NovelBookmark> items) {
    final snapshot = List<NovelBookmark>.of(items);
    return _mutate<void>(
      blocked: () {},
      action: () async {
        final ids = _bookmarks.map((item) => item.id).toSet();
        final added = snapshot.where((item) => ids.add(item.id)).toList();
        if (added.isNotEmpty) await _commit([..._bookmarks, ...added]);
      },
    );
  }

  Future<T> _mutate<T>({
    required T Function() blocked,
    required Future<T> Function() action,
  }) {
    final epoch = _restoreEpoch;
    final allowed = !_restoring;
    return _enqueue(() async {
      await _load();
      if (!allowed || _restoring || epoch != _restoreEpoch) return blocked();
      return action();
    });
  }

  /// 记录/更新该轻小说的组元数据，空字段沿用旧值。
  /// 只改内存，落盘由 [_commit] 一并完成（书签与分组同一次提交）。
  void _upsertGroup({
    required String pathWord,
    required String name,
    required String cover,
  }) {
    NovelBookmarkGroup? previous;
    for (final existing in _groups) {
      if (existing.pathWord == pathWord) {
        previous = existing;
        break;
      }
    }
    final merged = NovelBookmarkGroup(
      pathWord: pathWord,
      name: name.isEmpty ? previous?.name ?? '' : name,
      cover: cover.isEmpty ? previous?.cover ?? '' : cover,
      updatedAt: DateTime.now(),
    );
    _groups = List.unmodifiable(
      [
        merged,
        ..._groups.where((group) => group.pathWord != pathWord),
      ].take(maxBookmarks),
    );
  }

  Future<void> _load() async {
    if (_loaded) return;
    final prefs = await _preferences;
    final items = <NovelBookmark>[];
    try {
      final raw = prefs.get(storageKey);
      if (raw != null) {
        if (raw is! String) {
          throw const FormatException('Novel bookmarks must be JSON text');
        }
        final decoded = jsonDecode(raw);
        if (decoded is! List) {
          throw const FormatException('Novel bookmarks must be a list');
        }
        for (final value in decoded) {
          try {
            if (value is! Map<String, dynamic>) {
              throw const FormatException('Novel bookmark must be an object');
            }
            items.add(NovelBookmark.fromJson(value));
          } catch (error, stack) {
            _logFailure('read_item', error, stack);
          }
        }
      }
    } catch (error, stack) {
      _logFailure('read', error, stack);
    }
    final bookmarks = _normalize(items);
    _groups = _withGroupsFromBookmarks(_readGroups(prefs), bookmarks);
    _bookmarks = bookmarks;
    _loaded = true;
  }

  /// 补上「有书签但还没有组元数据」的作品：组元数据是后加的功能，
  /// 老书签没有对应记录，否则详情页书签按钮会显示成未添加、删光书签后组也会消失。
  /// 只改内存，不在这里写盘——读取路径保持只读，下次任何写入会带上补齐的组。
  static List<NovelBookmarkGroup> _withGroupsFromBookmarks(
    List<NovelBookmarkGroup> groups,
    List<NovelBookmark> bookmarks,
  ) {
    final known = groups.map((group) => group.pathWord).toSet();
    final added = <NovelBookmarkGroup>[];
    for (final bookmark in bookmarks) {
      if (!known.add(bookmark.pathWord)) continue;
      added.add(
        NovelBookmarkGroup(
          pathWord: bookmark.pathWord,
          name: bookmark.name,
          cover: bookmark.cover,
          updatedAt: bookmark.updatedAt,
        ),
      );
    }
    if (added.isEmpty) return groups;
    final merged = [...groups, ...added]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(merged);
  }

  /// 组元数据读失败时按空处理，不影响书签本身。
  static List<NovelBookmarkGroup> _readGroups(SharedPreferences prefs) {
    try {
      final raw = prefs.get(groupsStorageKey);
      if (raw is! String) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final groups = <NovelBookmarkGroup>[];
      for (final value in decoded) {
        try {
          if (value is! Map<String, dynamic>) {
            throw const FormatException('Novel bookmark group must be object');
          }
          final group = NovelBookmarkGroup.fromJson(value);
          if (group.pathWord.isNotEmpty) groups.add(group);
        } catch (error, stack) {
          _logFailure('read_group', error, stack);
        }
      }
      return List.unmodifiable(groups.take(maxBookmarks));
    } catch (error, stack) {
      _logFailure('read_groups', error, stack);
      return const [];
    }
  }

  static List<NovelBookmark> _normalize(Iterable<NovelBookmark> items) {
    final sorted = items.toList()
      ..sort((a, b) {
        final byDate = b.updatedAt.compareTo(a.updatedAt);
        return byDate != 0 ? byDate : a.id.compareTo(b.id);
      });
    final ids = <String>{};
    return List<NovelBookmark>.unmodifiable(
      sorted.where((item) => ids.add(item.id)).take(maxBookmarks),
    );
  }

  Future<void> _commit(Iterable<NovelBookmark> items) async {
    final next = _normalize(items);
    final encoded = jsonEncode(next.map((item) => item.toJson()).toList());
    final prefs = await _preferences;
    if (!await prefs.setString(storageKey, encoded)) {
      throw StateError('Novel bookmark persistence failed');
    }
    // 分组元数据与书签同一次提交落盘：书签被删光后组头仍要保留。
    await prefs.setString(
      groupsStorageKey,
      jsonEncode(_groups.map((group) => group.toJson()).toList()),
    );
    _bookmarks = next;
    notifyListeners();
  }

  Future<T> _enqueue<T>(FutureOr<T> Function() action) {
    final operation = (_queue ?? Future<void>.value()).then((_) => action());
    late final Future<void> tail;
    void releaseIfIdle() {
      if (identical(_queue, tail)) _queue = null;
    }

    tail = operation.then<void>(
      (_) => releaseIfIdle(),
      onError: (Object error, StackTrace stack) {
        releaseIfIdle();
        _logFailure('operation', error, stack);
      },
    );
    _queue = tail;
    return operation;
  }

  static void _logFailure(String action, Object error, StackTrace stack) {
    // 不把损坏 JSON、正文地址或签名查询参数写入日志。
    unawaited(
      AppLogger.instance.recordWarning(
        'Novel bookmark $action failed (${error.runtimeType})',
        stackTrace: stack,
        source: 'novel_bookmark_store',
      ),
    );
  }

  /// 先关写闸再排空队列，阻止慢加载或旧撤销在恢复完成后写回旧数据。
  Future<void> pauseForRestore() {
    _restoring = true;
    _restoreEpoch++;
    return flush();
  }

  Future<void> flush() async {
    while (_queue != null) {
      await _queue;
    }
  }

  void resumeAfterRestore() => _restoring = false;

  /// 导入备份/清除偏好后重载；与加载和写入使用同一队列。
  Future<void> reload() => _enqueue(() async {
    _loaded = false;
    await _load();
    notifyListeners();
  });

  /// 必须先 await flush()，避免测试间残留未完成写入。
  @visibleForTesting
  void debugReset() {
    assert(_queue == null, 'Flush pending novel bookmark operations first');
    _bookmarks = const [];
    _groups = const [];
    _loaded = false;
    _restoring = false;
    _restoreEpoch++;
  }
}

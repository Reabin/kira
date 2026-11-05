part of '../download_manager.dart';

class DownloadedChapterSummary {
  final String chapterUuid;
  final String chapterName;
  final String chapterGroup;
  final int chapterIndex;
  final int chapterOrder;
  final int pageCount;
  final DateTime savedAt;
  // 0-based 页索引：下载失败的页。空表示完整下载。
  final List<int> failedIndices;

  const DownloadedChapterSummary({
    required this.chapterUuid,
    required this.chapterName,
    this.chapterGroup = 'default',
    this.chapterIndex = 0,
    this.chapterOrder = 0,
    required this.pageCount,
    required this.savedAt,
    this.failedIndices = const [],
  });

  int get sortOrder => chapterOrder > 0 ? chapterOrder : chapterIndex;

  /// 是否为部分失败（仍有未下载页）。
  bool get isPartial => failedIndices.isNotEmpty;

  factory DownloadedChapterSummary.fromJson(Map<String, dynamic> json) =>
      DownloadedChapterSummary(
        chapterUuid: json['chapter_uuid']?.toString() ?? '',
        chapterName: json['chapter_name']?.toString() ?? '',
        chapterGroup: json['chapter_group']?.toString().trim().isEmpty ?? true
            ? 'default'
            : json['chapter_group'].toString(),
        chapterIndex: json['chapter_index'] is int
            ? json['chapter_index'] as int
            : int.tryParse(json['chapter_index']?.toString() ?? '') ?? 0,
        chapterOrder: json['chapter_order'] is int
            ? json['chapter_order'] as int
            : int.tryParse(json['chapter_order']?.toString() ?? '') ?? 0,
        pageCount: json['page_count'] is int
            ? json['page_count'] as int
            : int.tryParse(json['page_count']?.toString() ?? '') ?? 0,
        savedAt:
            DateTime.tryParse(json['saved_at']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        failedIndices:
            (json['failed_indices'] as List?)
                ?.map((e) => int.tryParse(e.toString()) ?? 0)
                .where((v) => v >= 0)
                .toList() ??
            const [],
      );

  Map<String, dynamic> toJson() => {
    'chapter_uuid': chapterUuid,
    'chapter_name': chapterName,
    'chapter_group': chapterGroup,
    'chapter_index': chapterIndex,
    'chapter_order': chapterOrder,
    'page_count': pageCount,
    'saved_at': savedAt.toIso8601String(),
    'failed_indices': failedIndices,
  };
}

class ChapterDownloadProgress {
  final int completed;
  final int total;
  final int failed;

  const ChapterDownloadProgress({
    required this.completed,
    required this.total,
    this.failed = 0,
  });

  double get ratio => total <= 0 ? 0 : completed / total;
}

/// 下载目录迁移进度：已迁移 [current] / 共 [total] 部漫画。
class DownloadMigrationProgress {
  final int current;
  final int total;

  /// 刚完成迁移的漫画 pathWord。
  final String pathWord;

  const DownloadMigrationProgress({
    required this.current,
    required this.total,
    required this.pathWord,
  });

  double get ratio => total <= 0 ? 0 : current / total;
}

class _DownloadTask {
  final String pathWord;
  final String group;
  final Chapter chapter;
  // true 表示这是对已有部分下载的"补全重试"：不清空目录、不重复下载成功页。
  final bool isRetry;
  // 已执行的尝试次数（含当前，从 1 起）；用于整章失败后的自动重试退避。
  final int attempt;
  // 自动重试的退避到期时间；早于该时刻的任务不会被领取。
  final DateTime? notBefore;

  const _DownloadTask({
    required this.pathWord,
    required this.group,
    required this.chapter,
    this.isRetry = false,
    this.attempt = 1,
    this.notBefore,
  });

  /// 是否已到可领取时间（自动重试退避窗口已过）。
  bool isEligibleAt(DateTime now) =>
      notBefore == null || !notBefore!.isAfter(now);

  /// 生成下一次自动重试的任务副本：尝试次数 +1、退避到期时间为 [retryAt]。
  _DownloadTask copyWithRetry(DateTime retryAt) => _DownloadTask(
    pathWord: pathWord,
    group: group,
    chapter: chapter,
    isRetry: isRetry,
    attempt: attempt + 1,
    notBefore: retryAt,
  );
}

/// 在飞章节的运行态：详情拉取、页结果收集与进度上报。
class _ChapterRun {
  final _DownloadTask task;
  final String key;

  ChapterDetail? detail;

  // 各页本地路径；null 表示该页未下载成功（含尚未处理）。
  List<String?> result = const [];

  int total = 0;

  // 成功页数（含复用的已下载页）。
  int completed = 0;
  int failed = 0;

  // 尚未完成的页任务数；归零时触发章节收尾。
  int remaining = 0;

  // 用户删除了该任务：不再收尾保存，等待清理。
  bool cancelled = false;

  // 图片任务已经全部放入全局队列；之后的取消由 worker/删除流程收尾。
  bool imageJobsDispatched = false;

  // 章节正在等待评论或写入本地文件。
  bool finalizing = false;

  // run 已经从管理器的活动集合中终结。
  bool terminated = false;

  final Completer<void> _done = Completer<void>();

  Future<void> get done => _done.future;

  void complete() {
    if (!_done.isCompleted) _done.complete();
  }

  Future<({List<ChapterComment> list, int total})> commentsFuture =
      Future.value((list: const <ChapterComment>[], total: 0));

  _ChapterRun({required this.task, required this.key});
}

/// 全局图片队列的单元：跨章节共享 worker 池，章节尾部不再闲置并发额度。
class _ImageJob {
  final _ChapterRun run;
  final int index;
  final String url;

  const _ImageJob({required this.run, required this.index, required this.url});
}

class LocalComicInfo {
  final Comic comic;
  final String? coverPath;
  final DateTime updatedAt;

  const LocalComicInfo({
    required this.comic,
    required this.coverPath,
    required this.updatedAt,
  });

  factory LocalComicInfo.fallback(String pathWord, {DateTime? updatedAt}) =>
      LocalComicInfo(
        comic: Comic(name: pathWord, pathWord: pathWord, cover: ''),
        coverPath: null,
        updatedAt: updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      );

  factory LocalComicInfo.fromJson(Map<String, dynamic> json) => LocalComicInfo(
    comic: Comic.fromJson(Map<String, dynamic>.from(json['comic'] as Map)),
    coverPath: json['cover_path']?.toString(),
    updatedAt:
        DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  Map<String, dynamic> toJson() => {
    'comic': comic.toJson(),
    'cover_path': coverPath,
    'updated_at': updatedAt.toIso8601String(),
  };
}

class LocalComicEntry {
  final LocalComicInfo info;
  final int downloadedCount;

  const LocalComicEntry({required this.info, required this.downloadedCount});
}

/// 漫画下载队列任务状态
enum ComicDownloadTaskStatus {
  /// 下载中
  downloading,

  /// 等待中
  pending,

  /// 已暂停（全局暂停或单独暂停）
  paused,
}

/// 漫画下载队列中的任务信息，供 UI 展示。
class ComicDownloadTaskInfo {
  final String pathWord;
  final String chapterUuid;
  final String chapterName;
  final String comicName;
  final String? cover;
  final ComicDownloadTaskStatus status;
  final ChapterDownloadProgress? progress;

  const ComicDownloadTaskInfo({
    required this.pathWord,
    required this.chapterUuid,
    required this.chapterName,
    required this.comicName,
    this.cover,
    required this.status,
    this.progress,
  });
}

/// 批次内单章失败记录，保留原任务以便"重试失败章节"重新入队。
class _BatchChapterFailure {
  final _DownloadTask task;
  final String comicName;
  final String? cover;

  const _BatchChapterFailure({
    required this.task,
    required this.comicName,
    this.cover,
  });
}

/// 批量下载中单章失败的记录，供 UI 展示。
class DownloadBatchFailure {
  final String pathWord;
  final String chapterUuid;
  final String chapterName;
  final String comicName;
  final String? cover;

  /// 是否为手动补全（partial 重试）失败；false 表示全新下载失败。
  final bool isRetry;

  const DownloadBatchFailure({
    required this.pathWord,
    required this.chapterUuid,
    required this.chapterName,
    required this.comicName,
    this.cover,
    this.isRetry = false,
  });
}

/// 队列清空后的批次下载汇总：成功章数与失败章清单。
class DownloadBatchSummary {
  final int succeeded;
  final List<DownloadBatchFailure> failures;
  final DateTime finishedAt;

  const DownloadBatchSummary({
    required this.succeeded,
    required this.failures,
    required this.finishedAt,
  });
}

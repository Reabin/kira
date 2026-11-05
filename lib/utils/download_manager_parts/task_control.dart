part of '../download_manager.dart';

extension DownloadManagerTaskControlPart on DownloadManager {
  /// 清除批次失败汇总（用户关闭提示条后调用）。
  Future<void> _deleteQueuedChapter(
    String pathWord,
    String chapterUuid,
    String key, {
    required Future<void> previous,
  }) async {
    final run = _activeRuns[key];

    _pausedTaskKeys.remove(key);
    // 先从 UI 队列移除；活动 run 保留 queued key，阻止删除完成前同 key 重入。
    _queue.removeWhere(
      (task) => _taskKey(task.pathWord, task.chapter.uuid) == key,
    );
    if (run != null) {
      // 在飞：标记取消并丢弃尚未领取的页任务；删除流程会等待 run 终止。
      _cancelledTaskKeys.add(key);
      run.cancelled = true;
      final removedJobs = _imageJobs
          .where((job) => identical(job.run, run))
          .length;
      if (removedJobs > 0) {
        _imageJobs.removeWhere((job) => identical(job.run, run));
        run.remaining -= removedJobs;
        if (run.remaining < 0) run.remaining = 0;
      }
      if (run.imageJobsDispatched && run.remaining <= 0 && !run.finalizing) {
        _completeCancelledRun(run);
      }
    } else {
      _queuedKeys.remove(key);
    }

    _batchFailures = _batchFailures
        .where((f) => _taskKey(f.task.pathWord, f.task.chapter.uuid) != key)
        .toList();
    _batchRunFailures = _batchRunFailures
        .where((f) => _taskKey(f.task.pathWord, f.task.chapter.uuid) != key)
        .toList();
    final summary = _lastBatchSummary;
    if (summary != null &&
        summary.failures.any(
          (f) => f.pathWord == pathWord && f.chapterUuid == chapterUuid,
        )) {
      final remaining = summary.failures
          .where(
            (f) => !(f.pathWord == pathWord && f.chapterUuid == chapterUuid),
          )
          .toList();
      _lastBatchSummary = remaining.isEmpty
          ? null
          : DownloadBatchSummary(
              succeeded: summary.succeeded,
              finishedAt: summary.finishedAt,
              failures: remaining,
            );
    }

    // 先落盘不含该任务的快照，避免进程在等待活动请求时把任务恢复回来。
    _notifyListeners();
    await _persistQueueState();

    if (run != null && !run.terminated) {
      await run.done;
    }

    // 文件和 manifest 的清理按删除请求顺序执行；队列状态已经在上面立即反映。
    await previous;

    // 删除该章节已下载的文件与清单记录（无记录时不报错）。
    await _removeDownloadedChapter(pathWord, chapterUuid, deleteFiles: true);
    if (!_hasQueuedOrActiveTaskForComic(pathWord, excludingKey: key) &&
        (_manifest[pathWord]?.isEmpty ?? true)) {
      final prepare = _comicPrepares[pathWord];
      if (prepare != null) {
        try {
          await prepare;
        } catch (e, st) {
          unawaited(AppLogger.instance.recordWarning(e, stackTrace: st));
        }
      }
      if (!_hasQueuedOrActiveTaskForComic(pathWord, excludingKey: key) &&
          (_manifest[pathWord]?.isEmpty ?? true)) {
        await _removeLocalComic(pathWord);
      }
    }
    await _persistQueueState();
    _notifyListeners();
    _signalScheduler();
    _wakeImageWorkers();
  }
}

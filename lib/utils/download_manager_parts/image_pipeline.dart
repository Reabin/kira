part of '../download_manager.dart';

extension DownloadManagerImagePipelinePart on DownloadManager {
  /// 全局图片 worker：跨章节领取页任务；队列排空且调度器收尾后退出。
  /// 暂停（全局或所属章节）的任务留在队列中，恢复后继续。
  Future<void> _imageWorker() async {
    while (true) {
      final job = _nextImageJob();
      if (job != null) {
        try {
          await _processImageJob(job);
        } catch (e, st) {
          if (_isCancelledRun(job.run)) {
            _completeCancelledRun(job.run);
          } else {
            await _handleChapterFailure(job.run, e, st);
          }
        }
        continue;
      }
      if (_schedulerDone) return;
      // 队列无可领取任务（已排空、全局暂停或章节暂停）：等待唤醒。
      final wake = _jobWake ??= Completer<void>();
      await wake.future;
      continue;
    }
  }

  /// 取出下一个可领取的页任务；全局暂停或所属章节被暂停时返回 null。
  _ImageJob? _nextImageJob() {
    if (_paused) return null;
    for (var i = 0; i < _imageJobs.length; i++) {
      if (_pausedTaskKeys.contains(_imageJobs[i].run.key)) continue;
      return _imageJobs.removeAt(i);
    }
    return null;
  }

  void _wakeImageWorkers() {
    final wake = _jobWake;
    if (wake != null && !wake.isCompleted) wake.complete();
    _jobWake = null;
  }

  /// 处理单个页任务：下载并记录结果与进度；章节最后一页完成时触发收尾。
  /// 任务被删除（取消）时跳过收尾，由删除流程清理文件。
  Future<void> _processImageJob(_ImageJob job) async {
    final run = job.run;
    if (_isCancelledRun(run)) {
      run.cancelled = true;
      run.remaining--;
      if (run.remaining <= 0 && !run.finalizing) _completeCancelledRun(run);
      return;
    }
    String? path;
    try {
      final file = await _downloadImage(
        job.url,
        _chapterDirectory(run.task.pathWord, run.task.chapter.uuid),
        job.index + 1,
      );
      path = file.path;
      run.completed++;
    } catch (e, st) {
      // 单张失败不中断整章；记为 null，由收尾阶段收集为 failedIndices。
      run.failed++;
      unawaited(
        AppLogger.instance.recordWarning(
          'Image #${job.index} download failed: $e',
          stackTrace: st,
        ),
      );
    }
    if (_isCancelledRun(run)) {
      run.cancelled = true;
      run.remaining--;
      if (run.remaining <= 0 && !run.finalizing) _completeCancelledRun(run);
      return;
    }
    run.result[job.index] = path;
    run.remaining--;
    _activeProgress[run.key] = ChapterDownloadProgress(
      completed: run.completed,
      total: run.total,
      failed: run.failed,
    );
    _notifyListeners();
    if (run.remaining <= 0) {
      await _finalizeChapter(run);
    }
  }

  /// 注册一个调度器等待点；[_signalScheduler] 唤醒所有等待点。
  Completer<void> _newSchedulerWait() {
    final wake = Completer<void>();
    _schedulerWaits.add(wake);
    return wake;
  }

  /// 唤醒章节调度器（章节完成、失败或新任务入队时调用）。
  void _signalScheduler() {
    if (_schedulerWaits.isEmpty) return;
    final waits = List.of(_schedulerWaits);
    _schedulerWaits.clear();
    for (final wake in waits) {
      if (!wake.isCompleted) wake.complete();
    }
  }
}

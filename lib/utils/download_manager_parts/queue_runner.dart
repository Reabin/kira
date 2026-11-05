part of '../download_manager.dart';

extension DownloadManagerQueueRunnerPart on DownloadManager {
  /// 队列主循环：启动全局图片 worker 池与章节流水线调度，直到队列排空。
  Future<void> _processQueue() async {
    if (_processing) return;
    _processing = true;
    _batchSucceeded = 0;
    _batchRunFailures = [];

    try {
      _schedulerDone = false;
      final workers = List.generate(
        _imageDownloadConcurrency,
        (_) => _imageWorker(),
      );
      await _runChapterScheduler();
      _schedulerDone = true;
      _wakeImageWorkers();
      await Future.wait(workers);

      if (_batchRunFailures.isNotEmpty) {
        final failures = List<_BatchChapterFailure>.of(_batchRunFailures);
        _batchFailures = failures;
        _lastBatchSummary = DownloadBatchSummary(
          succeeded: _batchSucceeded,
          finishedAt: DateTime.now(),
          failures: [
            for (final failure in failures)
              DownloadBatchFailure(
                pathWord: failure.task.pathWord,
                chapterUuid: failure.task.chapter.uuid,
                chapterName: failure.task.chapter.name,
                comicName: failure.comicName,
                cover: failure.cover,
                isRetry: failure.task.isRetry,
              ),
          ],
        );
      }
      _batchRunFailures = [];
      await _persistQueueState();
    } finally {
      _processing = false;
      _notifyListeners();
      // 新任务可能在 scheduler/worker 收尾窗口内入队；启动一个新的处理器，
      // 避免入队调用恰好撞上旧处理器仍标记为 busy 而被吞掉。
      _ensureProcessing();
    }
  }

  /// 章节流水线调度：维持最多 [_maxChaptersInFlight] 个在飞章节。
  /// 任务在下载期间保留在队列中供 UI 展示；全局或单独暂停的章节不会被领取。
  Future<void> _runChapterScheduler() async {
    while (true) {
      // 领取新任务，跳过已在飞、已暂停与未出退避窗口的任务。
      while (!_paused &&
          _activeRuns.length < DownloadManager._maxChaptersInFlight) {
        final now = DateTime.now();
        final index = _queue.indexWhere((task) {
          if (!task.isEligibleAt(now)) return false;
          final key = _taskKey(task.pathWord, task.chapter.uuid);
          return !_activeRuns.containsKey(key) &&
              !_pausedTaskKeys.contains(key);
        });
        if (index < 0) break;

        final task = _queue[index];
        final key = _taskKey(task.pathWord, task.chapter.uuid);
        _cancelledTaskKeys.remove(key);
        final run = _ChapterRun(task: task, key: key);
        _activeRuns[key] = run;
        _activeKeys.add(key);
        _notifyListeners();
        unawaited(_startChapter(run));
      }

      if (_activeRuns.isEmpty) {
        if (_queue.isEmpty) return;
        // 剩余任务均不可领取（全局暂停、单独暂停或退避窗口内）：挂起等待。
        await _waitForNextEligible();
        continue;
      }

      // 等待任一章节完成（收尾或失败处理后唤醒）。
      final wake = _newSchedulerWait();
      try {
        await wake.future;
      } finally {
        _schedulerWaits.remove(wake);
      }
    }
  }

  /// 启动单个在飞章节：拉取详情 → 准备目录/复用已下载页 →
  /// 把待下载页推入全局图片队列。详情或准备阶段失败转入失败路径。
  Future<void> _startChapter(_ChapterRun run) async {
    final task = run.task;
    try {
      if (_isCancelledRun(run)) {
        run.cancelled = true;
        return;
      }
      final detail = _chapterDetailLoader == null
          ? await _api.manga.getChapterDetail(task.pathWord, task.chapter.uuid)
          : await _chapterDetailLoader(task.pathWord, task.chapter.uuid);
      if (_isCancelledRun(run)) return;
      if (detail.contents.isEmpty) {
        throw const HttpException('Chapter has no images');
      }
      run.detail = detail;
      run.total = detail.contents.length;
      run.result = List<String?>.filled(run.total, null);

      final chapterDir = _chapterDirectory(task.pathWord, task.chapter.uuid);
      // 重试时保留已下载的文件，仅补全失败页；全新下载则清空目录。
      if (!task.isRetry) {
        await _resetDirectory(chapterDir);
      }
      if (_isCancelledRun(run)) return;

      // 复用已下载页的本地路径，避免重复下载成功页（重试或崩溃恢复）。
      final existing = await _loadExistingPaths(
        task.pathWord,
        task.chapter.uuid,
        run.total,
      );
      if (_isCancelledRun(run)) return;

      // 重试时复用已保存的评论；全新下载且开关开启时才拉取评论。
      // 评论与图片互不依赖，与图片下载并行执行，避免拖慢进度显示。
      run.commentsFuture = (task.isRetry || !_downloadCommentsEnabled)
          ? _loadExistingComments(task.pathWord, task.chapter.uuid)
          : _downloadComments(task.chapter.uuid);

      for (var i = 0; i < run.total; i++) {
        final existingPath = i < existing.length ? existing[i] : null;
        if (existingPath != null && existingPath.isNotEmpty) {
          run.result[i] = existingPath;
          run.completed++;
        }
      }
      run.remaining = run.total - run.completed;
      _activeProgress[run.key] = ChapterDownloadProgress(
        completed: run.completed,
        total: run.total,
      );
      _notifyListeners();

      if (run.remaining == 0) {
        await _finalizeChapter(run);
        return;
      }

      // 页任务按章节顺序进入全局队列：前面的章节优先占用 worker，
      // 有剩余的 worker 立即领取后面章节的页，不闲置并发额度。
      if (_isCancelledRun(run)) return;
      run.imageJobsDispatched = true;
      for (var i = 0; i < run.total; i++) {
        if (run.result[i] != null) continue;
        _imageJobs.add(_ImageJob(run: run, index: i, url: detail.contents[i]));
      }
      _wakeImageWorkers();
    } catch (e, st) {
      if (_isCancelledRun(run)) {
        _completeCancelledRun(run);
      } else {
        await _handleChapterFailure(run, e, st);
      }
    } finally {
      // 详情/准备阶段可能在取消后才返回，确保没有 image job 时也能释放 run。
      if (_isCancelledRun(run) && !run.imageJobsDispatched && !run.finalizing) {
        _completeCancelledRun(run);
      }
    }
  }

  /// 章节收尾：等评论结果（失败降级）、写 chapter.json 与 manifest。
  /// 全部页成功则记成功；写盘失败转入失败路径。任务被删除（取消）时
  /// 跳过保存，由删除流程清理文件。
  Future<void> _finalizeChapter(_ChapterRun run) async {
    final task = run.task;
    if (run.terminated || run.finalizing) return;
    run.finalizing = true;
    try {
      if (_isCancelledRun(run)) return;
      // 评论拉取失败不连累整章：降级为已有评论或空评论，图片照常保存。
      var comments = (list: const <ChapterComment>[], total: 0);
      try {
        comments = await run.commentsFuture;
      } catch (e, st) {
        unawaited(
          AppLogger.instance.recordWarning(
            'Download chapter comments failed: ${task.chapter.uuid}: $e',
            stackTrace: st,
          ),
        );
        comments = await _loadExistingComments(
          task.pathWord,
          task.chapter.uuid,
        );
      }
      if (_isCancelledRun(run)) return;

      // 处理结果：失败页记为空串，收集失败索引。
      final failedIndices = <int>[];
      final completedPaths = List<String>.filled(run.total, '');
      for (var i = 0; i < run.total; i++) {
        final path = run.result[i];
        if (path == null) {
          failedIndices.add(i);
        } else {
          completedPaths[i] = path;
        }
      }

      final localDetail = run.detail!.copyWith(
        contents: completedPaths,
        isDownloaded: true,
        comments: comments.list,
        commentTotal: comments.total,
      );
      await _writeChapterMetadata(
        task.pathWord,
        task.chapter.uuid,
        localDetail,
      );
      if (_isCancelledRun(run)) return;

      _manifest.putIfAbsent(task.pathWord, () => {});
      _manifest[task.pathWord]![task.chapter.uuid] = DownloadedChapterSummary(
        chapterUuid: task.chapter.uuid,
        chapterName: task.chapter.name,
        chapterGroup: task.group,
        chapterIndex: task.chapter.index,
        chapterOrder: task.chapter.ordered,
        pageCount: completedPaths.length,
        savedAt: DateTime.now(),
        failedIndices: failedIndices,
      );
      await _persistManifest();
      if (_isCancelledRun(run)) return;
      await _touchLocalComic(task.pathWord);
      if (_isCancelledRun(run)) return;
      // 注意：部分图片失败不抛错，章节以 partial 状态持久化，用户可重试补全。

      _queue.remove(task);
      _queuedKeys.remove(run.key);
      _batchSucceeded++;
      await _persistQueueState();
    } catch (e, st) {
      if (_isCancelledRun(run)) {
        _completeCancelledRun(run);
      } else {
        await _handleChapterFailure(run, e, st);
      }
    } finally {
      run.finalizing = false;
      if (_isCancelledRun(run)) {
        _completeCancelledRun(run);
      } else {
        _completeRun(run);
      }
    }
  }

  /// 整章失败处理：尝试次数未耗尽则带退避重新入队（排到队尾，先放行
  /// 后续章节）；耗尽后全新下载清理目录、记入批次失败。任务被删除
  /// （取消）时直接退出，由删除流程清理文件。
  Future<void> _handleChapterFailure(
    _ChapterRun run,
    Object error,
    StackTrace st,
  ) async {
    if (_isCancelledRun(run)) {
      _completeCancelledRun(run);
      return;
    }

    unawaited(
      AppLogger.instance.recordWarning(
        'Download chapter failed (attempt ${run.task.attempt}): '
        '${run.task.pathWord}/${run.task.chapter.uuid}: $error',
        stackTrace: st,
      ),
    );

    _queue.remove(run.task);
    _notifyListeners();

    var requeued = false;
    try {
      if (run.task.attempt < DownloadManager._chapterMaxAttempts) {
        final retryAt = DateTime.now().add(
          DownloadManager.chapterRetryDelay(run.task.attempt),
        );
        if (_isCancelledRun(run)) return;
        _queue.add(run.task.copyWithRetry(retryAt));
        _queuedKeys.add(run.key);
        requeued = true;
        _notifyListeners();
      } else {
        // 手动补全(isRetry)失败保留 partial 记录，全新下载失败才清理。
        if (!run.task.isRetry) {
          await _removeDownloadedChapter(
            run.task.pathWord,
            run.task.chapter.uuid,
            deleteFiles: true,
          );
        }
        if (_isCancelledRun(run)) return;
        final info = getLocalComicInfo(run.task.pathWord);
        _batchRunFailures.add(
          _BatchChapterFailure(
            task: run.task,
            comicName: info?.comic.name ?? run.task.pathWord,
            cover: info?.comic.cover,
          ),
        );
      }
      await _persistQueueState();
    } finally {
      if (_isCancelledRun(run)) {
        _completeCancelledRun(run);
      } else {
        if (!requeued) _queuedKeys.remove(run.key);
        _completeRun(run);
      }
    }
  }
}

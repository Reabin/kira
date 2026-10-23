part of '../novel_download_manager.dart';

extension NovelDownloadManagerRunLoopPart on NovelDownloadManager {
  void _pump() {
    if (!_initialized || _paused || _disposed || isMigrating) return;
    refreshIdentity();
    for (final task in _tasks.values) {
      if (_runs.length >= _concurrency) break;
      if (task.status != NovelDownloadStatus.queued ||
          _runs.containsKey(task.id) ||
          _deleting.contains(task.id) ||
          _deletingBooks.contains(task.pathWord)) {
        continue;
      }
      if (!_matchesSource(task.source)) {
        task.status = NovelDownloadStatus.paused;
        continue;
      }
      final run = _NovelRun(_epochs[task.id] ?? 0, _readEpoch());
      _runs[task.id] = run;
      task.status = NovelDownloadStatus.downloading;
      unawaited(
        _run(task, run).whenComplete(() {
          if (identical(_runs[task.id], run)) _runs.remove(task.id);
          _changed();
          _pump();
        }),
      );
    }
    _changed();
  }

  bool _isCurrent(NovelDownloadTask task, _NovelRun run) =>
      !_disposed &&
      identical(_tasks[task.id], task) &&
      identical(_runs[task.id], run) &&
      !run.cancelToken.isCancelled &&
      run.epoch == (_epochs[task.id] ?? 0) &&
      _matchesSource(task.source) &&
      run.identityEpoch == _readEpoch();
  void _assertCurrent(NovelDownloadTask task, _NovelRun run) {
    if (!_isCurrent(task, run)) throw const NovelDownloadWriteCancelled();
  }

  Future<T> _owned<T>(Future<T> future, _NovelRun run) => Future.any<T>([
    future,
    run.cancelled.future.then<T>(
      (_) => throw const NovelDownloadWriteCancelled(),
    ),
  ]);

  Future<void> _run(NovelDownloadTask task, _NovelRun run) async {
    try {
      while (task.attempts < maxAttempts) {
        _assertCurrent(task, run);
        task.attempts++;
        _changed();
        try {
          var snapshot = await _owned(
            store.readVolumeSnapshot(task.pathWord, task.volumeId),
            run,
          );
          _assertCurrent(task, run);
          if (snapshot == null) {
            snapshot = await _owned<NovelVolumeSnapshot>(
              _snapshotLoader != null
                  ? _snapshotLoader(
                      task.pathWord,
                      task.volumeId,
                      cancelToken: run.cancelToken,
                    )
                  : _repository.loadVolumeSnapshot(
                      task.pathWord,
                      task.volumeId,
                      cancelToken: run.cancelToken,
                    ),
              run,
            );
            _assertCurrent(task, run);
            await store.saveSnapshot(
              book: task.book,
              volumes: task.volumes,
              snapshot: snapshot,
              isCurrent: () => _isCurrent(task, run),
            );
          }
          _assertCurrent(task, run);
          task.total = 1 + snapshot.imageUrls.length;
          task.completed =
              store
                  .getLocalNovelInfo(task.pathWord)
                  ?.downloaded[task.volumeId]
                  ?.completed ??
              1;
          _changed();
          for (final url in snapshot.imageUrls) {
            _assertCurrent(task, run);
            final existing = await store.readImageBytes(
              task.pathWord,
              task.volumeId,
              url,
            );
            _assertCurrent(task, run);
            if (existing != null) continue;
            final bytes = await _owned(_loadImage(url, run.cancelToken), run);
            _assertCurrent(task, run);
            await store.saveImage(
              task.pathWord,
              task.volumeId,
              url,
              bytes,
              isCurrent: () => _isCurrent(task, run),
            );
            _assertCurrent(task, run);
            task.completed = store
                .getLocalNovelInfo(task.pathWord)!
                .downloaded[task.volumeId]!
                .completed;
            _changed();
          }
          if (task.book.cover.isNotEmpty &&
              store.coverPath(task.pathWord) == null) {
            try {
              final bytes = await _owned(
                _loadImage(task.book.cover, run.cancelToken),
                run,
              );
              _assertCurrent(task, run);
              await store.saveCover(
                task.pathWord,
                bytes,
                isCurrent: () => _isCurrent(task, run),
              );
            } catch (error, stack) {
              _assertCurrent(task, run);
              NovelDownloadManager._log(
                error,
                stack,
              ); // Cover is strictly best-effort.
            }
          }
          _assertCurrent(task, run);
          task.completed = task.total;
          task.status = NovelDownloadStatus.completed;
          task.error = null;
          // Only retire this run's task after its files have been committed.
          // _pump's finalizer persists the queue and starts the next volume.
          _tasks.remove(task.id);
          return;
        } catch (error, stack) {
          _assertCurrent(task, run);
          if (error is NovelIdentityChangedException) {
            task.status = NovelDownloadStatus.paused;
            task.error = '拷贝账号或线路已变更，请恢复下载';
            return;
          }
          if (error is NovelApiException && error.isUnauthorized) {
            task.status = NovelDownloadStatus.unauthorized;
            task.error = '登录已失效，请重新登录后重试';
            return;
          }
          if (error is NovelAccessException) {
            task.status = error.detail.isLocked
                ? NovelDownloadStatus.locked
                : NovelDownloadStatus.failed;
            task.error = error.detail.isLocked ? '该卷暂不可访问' : '该卷尚未提供正文或目录';
            return;
          }
          NovelDownloadManager._log(error, stack);
          if (task.attempts >= maxAttempts) {
            final local = store
                .getLocalNovelInfo(task.pathWord)
                ?.downloaded[task.volumeId];
            task.status = local?.isReadable == true
                ? NovelDownloadStatus.partial
                : NovelDownloadStatus.failed;
            task.error = local?.isReadable == true
                ? '正文可读，部分插图下载失败：${NetworkError.describe(error)}'
                : '小说下载失败：${NetworkError.describe(error)}';
            return;
          }
          await _owned(Future<void>.delayed(retryDelay * task.attempts), run);
        }
      }
    } on NovelDownloadWriteCancelled {
      // The command which invalidated this run already owns its public state.
      if (identical(_tasks[task.id], task) &&
          task.status == NovelDownloadStatus.downloading) {
        task.status = NovelDownloadStatus.paused;
      }
    } catch (error, stack) {
      NovelDownloadManager._log(error, stack);
      if (_isCurrent(task, run)) {
        task.status = NovelDownloadStatus.failed;
        task.error = '小说下载失败：${NetworkError.describe(error)}';
      }
    }
  }

  Future<List<int>> _loadImage(String url, CancelToken token) =>
      _imageLoader != null
      ? _imageLoader(url, cancelToken: token)
      : ApiClient().novel.withCancellation(
          token,
          () => ApiClient().novel.getContentBytes(url),
        );
  void _invalidate(String key) {
    _epochs[key] = (_epochs[key] ?? 0) + 1;
    _runs[key]?.cancel();
  }
}

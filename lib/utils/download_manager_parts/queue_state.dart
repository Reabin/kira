part of '../download_manager.dart';

extension DownloadManagerQueueStatePart on DownloadManager {
  /// 当前队列状态快照：任务、全局/单独暂停状态与批次失败记录。
  Map<String, dynamic> _encodeQueueState() => {
    'version': DownloadManager._queueStateVersion,
    'paused': _paused,
    'paused_tasks': _pausedTaskKeys.toList(),
    'tasks': [for (final task in _queue) DownloadManager._encodeTask(task)],
    'succeeded': _batchSucceeded,
    'batch_failures': [
      for (final failure
          in (_batchRunFailures.isNotEmpty
              ? _batchRunFailures
              : _batchFailures))
        {
          ...DownloadManager._encodeTask(failure.task),
          'comic_name': failure.comicName,
          'cover': failure.cover,
        },
    ],
  };

  /// 将队列快照写入 SharedPreferences。快照同步生成、写入异步，
  /// 各状态变更点触发，最后一次写入生效。
  Future<void> _persistQueueState() {
    final payload = jsonEncode(_encodeQueueState());
    final previous = _queueStateWriteTail;
    final completed = Completer<void>();
    _queueStateWriteTail = completed.future;
    return () async {
      try {
        await previous;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(DownloadManager._keyQueueState, payload);
      } catch (e, st) {
        unawaited(
          AppLogger.instance.recordWarning(
            'Persist download queue failed: $e',
            stackTrace: st,
          ),
        );
      } finally {
        if (!completed.isCompleted) completed.complete();
      }
    }();
  }

  /// 从持久化恢复队列、暂停状态与批次失败记录（App 重启后续传）。
  Future<void> _restoreQueueState(SharedPreferences prefs) async {
    final raw = prefs.getString(DownloadManager._keyQueueState);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final version = decoded['version'];
      if (version is int && version != DownloadManager._queueStateVersion) {
        return;
      }

      _paused = decoded['paused'] == true;
      final pausedTasks = decoded['paused_tasks'];
      if (pausedTasks is List) {
        _pausedTaskKeys.addAll(pausedTasks.map((e) => e.toString()));
      }

      final tasks = decoded['tasks'];
      if (tasks is List) {
        for (final item in tasks) {
          final restored = DownloadManager.decodeQueueTaskJson(item);
          if (restored == null) continue;
          // 崩溃窗口内可能已完成下载：清单中已完整存在的全新任务不再重下。
          final summary = _manifest[restored.pathWord]?[restored.chapter.uuid];
          if (summary != null && !summary.isPartial && !restored.isRetry) {
            continue;
          }
          final task = DownloadManager._taskFromRestored(
            restored,
            isRetry:
                restored.isRetry ||
                (_manifest[restored.pathWord]?[restored.chapter.uuid]
                        ?.isPartial ??
                    false),
          );
          final key = _taskKey(task.pathWord, task.chapter.uuid);
          if (_queuedKeys.contains(key)) continue;
          _queue.add(task);
          _queuedKeys.add(key);
        }
      }

      _pausedTaskKeys.removeWhere((key) => !_queuedKeys.contains(key));
      _batchSucceeded = decoded['succeeded'] is int
          ? decoded['succeeded'] as int
          : 0;

      final failures = decoded['batch_failures'];
      final restoredFailures = <_BatchChapterFailure>[];
      if (failures is List) {
        for (final item in failures) {
          if (item is! Map) continue;
          final restored = DownloadManager.decodeQueueTaskJson(item);
          if (restored == null) continue;
          restoredFailures.add(
            _BatchChapterFailure(
              task: DownloadManager._taskFromRestored(restored),
              comicName: item['comic_name']?.toString() ?? restored.pathWord,
              cover: item['cover']?.toString(),
            ),
          );
        }
      }
      if (restoredFailures.isNotEmpty) {
        _batchFailures = restoredFailures;
        _lastBatchSummary = DownloadBatchSummary(
          succeeded: decoded['succeeded'] is int
              ? decoded['succeeded'] as int
              : 0,
          finishedAt: DateTime.now(),
          failures: [
            for (final failure in restoredFailures)
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
    } catch (e, st) {
      unawaited(
        AppLogger.instance.recordWarning(
          'Restore download queue failed: $e',
          stackTrace: st,
        ),
      );
    }
  }
}

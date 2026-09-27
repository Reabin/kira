import 'package:flutter/foundation.dart';

/// 两种下载队列共享的前台服务快照，不包含内容类型或账号凭据。
@immutable
class DownloadActivitySnapshot {
  const DownloadActivitySnapshot({
    this.active = 0,
    this.pending = 0,
    this.completed = 0,
    this.total = 0,
  }) : assert(active >= 0),
       assert(pending >= 0),
       assert(completed >= 0),
       assert(total >= completed);

  final int active;
  final int pending;
  final int completed;
  final int total;

  bool get hasRunnableWork => active > 0 || pending > 0;

  DownloadActivitySnapshot operator +(DownloadActivitySnapshot other) =>
      DownloadActivitySnapshot(
        active: active + other.active,
        pending: pending + other.pending,
        completed: completed + other.completed,
        total: total + other.total,
      );
}

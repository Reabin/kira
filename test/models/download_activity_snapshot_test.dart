import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/download_activity_snapshot.dart';

void main() {
  test('空队列不需要前台服务', () {
    expect(const DownloadActivitySnapshot().hasRunnableWork, isFalse);
  });

  test('合并两类队列时保留仍可运行的任务', () {
    const comics = DownloadActivitySnapshot();
    const novels = DownloadActivitySnapshot(
      active: 1,
      pending: 2,
      completed: 3,
      total: 5,
    );
    final combined = comics + novels;
    expect(combined.hasRunnableWork, isTrue);
    expect(combined.active, 1);
    expect(combined.pending, 2);
    expect(combined.completed, 3);
    expect(combined.total, 5);
  });

  test('合并进度只统计快照中的可运行任务', () {
    const comics = DownloadActivitySnapshot(active: 2, completed: 8, total: 16);
    const novels = DownloadActivitySnapshot(active: 1, completed: 2, total: 4);
    final combined = comics + novels;
    expect(combined.active, 3);
    expect(combined.completed, 10);
    expect(combined.total, 20);
  });
}

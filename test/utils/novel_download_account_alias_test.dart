import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/novel.dart';
import 'package:kira/models/novel_volume_snapshot.dart';
import 'package:kira/utils/json_helpers.dart';
import 'package:kira/utils/novel_download_manager.dart';
import 'package:kira/utils/novel_download_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'novel_download_store_test.dart'
    show
        downloadBook,
        downloadVolume,
        downloadSnapshot,
        filesUnder,
        saveFixture;

const _oldIdentity = NovelDownloadIdentity(
  host: 'copy.invalid',
  accountId: 'local:b',
);
const _canonicalIdentity = NovelDownloadIdentity(
  host: 'copy.invalid',
  accountId: 'local:a',
);

class _AliasIdentity extends ChangeNotifier {
  NovelDownloadIdentity value = _oldIdentity;
  int epoch = 0;
  final accounts = {'local:a', 'local:b', 'local:other'};
  final aliases = <String, String>{};

  String? resolve(String? id) {
    if (accounts.contains(id)) return id;
    final canonical = aliases[id];
    return accounts.contains(canonical) ? canonical : null;
  }

  void merge({bool notify = true}) {
    accounts.remove('local:b');
    aliases['local:b'] = 'local:a';
    value = _canonicalIdentity;
    epoch++;
    if (notify) notifyListeners();
  }
}

NovelVolume _volume(String id) => id == 'v1'
    ? downloadVolume
    : NovelVolume(
        id: id,
        name: '测试卷 $id',
        bookPathWord: 'book',
        txtAddr: 'https://cdn.invalid/$id.txt',
        contents: downloadVolume.contents,
      );

NovelVolumeSnapshot _snapshot(String id) => NovelVolumeSnapshot(
  detail: NovelVolumeDetail(book: downloadBook, volume: _volume(id)),
  text: downloadSnapshot.text,
);

NovelDownloadTask _task({
  String id = 'v1',
  NovelDownloadIdentity source = _oldIdentity,
  NovelDownloadStatus status = NovelDownloadStatus.paused,
}) => NovelDownloadTask(
  book: downloadBook,
  volume: _volume(id),
  volumes: [_volume(id)],
  source: source,
  status: status,
  attempts: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory parent;
  late Directory root;
  late NovelDownloadStore store;
  late NovelDownloadManager manager;
  late _AliasIdentity identity;
  late NovelSnapshotLoader snapshotLoader;
  late Future<void> Function(String) beforeWrite;
  late List<String> snapshotCalls;
  late List<NovelDownloadIdentity> requestIdentities;
  late List<int> requestEpochs;
  late List<String> imageCalls;

  NovelDownloadStore createStore() => NovelDownloadStore.forTesting(
    rootDirectory: root,
    beforeWrite: (path) => beforeWrite(path),
  );

  NovelDownloadManager create({bool resolveAliases = true}) =>
      NovelDownloadManager.forTesting(
        store: store,
        snapshotLoader: (path, id, {required cancelToken}) {
          snapshotCalls.add(id);
          requestIdentities.add(identity.value);
          requestEpochs.add(identity.epoch);
          return snapshotLoader(path, id, cancelToken: cancelToken);
        },
        imageLoader: (url, {required cancelToken}) async {
          imageCalls.add(url);
          return [1, 2, 3];
        },
        identityProvider: () => identity.value,
        accountIdResolver: resolveAliases ? identity.resolve : null,
        identityEpochProvider: () => identity.epoch,
        identityChanges: identity,
        defaultRoot: () async => root.path,
      );

  Future<void> restoreQueue(
    List<NovelDownloadTask> tasks, {
    bool paused = false,
    bool resolveAliases = true,
    void Function()? beforeInit,
  }) async {
    manager.dispose();
    await manager.waitForIdle();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      NovelDownloadManager.queueStateKey,
      jsonEncode({
        'version': 1,
        'paused': paused,
        'tasks': tasks.map((task) => task.toJson()).toList(),
      }),
    );
    beforeInit?.call();
    store = createStore();
    manager = create(resolveAliases: resolveAliases);
    await manager.init();
  }

  Future<void> enqueue() => manager.enqueueVolumes(
    book: downloadBook,
    volumes: [downloadVolume],
    selected: [downloadVolume],
  );

  Future<void> expectCompleted(String id) async {
    expect(manager.taskFor('book', id), isNull);
    expect(manager.isVolumeDownloaded('book', id), isTrue);
    expect(
      (await store.readVolumeSnapshot('book', id))!.text,
      downloadSnapshot.text,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    parent = await Directory.systemTemp.createTemp('novel_account_alias_test_');
    root = Directory(p.join(parent.path, 'downloads'));
    identity = _AliasIdentity();
    snapshotCalls = [];
    requestIdentities = [];
    requestEpochs = [];
    imageCalls = [];
    beforeWrite = (_) async {};
    snapshotLoader = (_, id, {required cancelToken}) async => _snapshot(id);
    store = createStore();
    manager = create();
    await manager.init();
  });

  tearDown(() async {
    manager.dispose();
    await manager.waitForIdle();
    identity.dispose();
    await parent.delete(recursive: true);
  });

  for (final status in [
    NovelDownloadStatus.queued,
    NovelDownloadStatus.downloading,
  ]) {
    test('冷启动恢复旧 ID 的 ${status.name} 队列并复用已下载内容', () async {
      await saveFixture(store);
      final firstImage = downloadSnapshot.imageUrls.first;
      await store.saveImage('book', 'v1', firstImage, [1, 2, 3]);
      await restoreQueue([_task(status: status)], beforeInit: identity.merge);
      await manager.waitForIdle();

      await expectCompleted('v1');
      expect(snapshotCalls, isEmpty);
      expect(imageCalls, [downloadSnapshot.imageUrls.last, downloadBook.cover]);
      expect(await store.readImageBytes('book', 'v1', firstImage), [1, 2, 3]);
      final prefs = await SharedPreferences.getInstance();
      final queue = jsonMap({
        'v': jsonDecode(prefs.getString(NovelDownloadManager.queueStateKey)!),
      }, 'v')!;
      expect(jsonList(queue, 'tasks'), isEmpty);
    });
  }

  test('冷启动保留暂停任务的旧来源，显式单卷恢复使用 canonical 会话', () async {
    await restoreQueue([_task()], beforeInit: identity.merge);
    await manager.waitForIdle();
    expect(manager.tasks.single.source, _oldIdentity);
    expect(manager.tasks.single.status, NovelDownloadStatus.paused);
    expect(snapshotCalls, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(NovelDownloadManager.queueStateKey)!;
    expect(raw, contains('local:b'));
    expect(raw, isNot(contains('token')));

    await manager.resumeVolume('book', 'v1');
    await manager.waitForIdle();
    await expectCompleted('v1');
    expect(requestIdentities, [_canonicalIdentity]);
    expect(requestEpochs, [1]);
  });

  test('归并取消旧运行，显式恢复后旧迟到结果不能覆盖新会话', () async {
    final firstEntered = Completer<CancelToken>();
    final nextEntered = Completer<CancelToken>();
    final oldResult = Completer<NovelVolumeSnapshot>();
    final nextResult = Completer<NovelVolumeSnapshot>();
    snapshotLoader = (_, _, {required cancelToken}) {
      if (!firstEntered.isCompleted) {
        firstEntered.complete(cancelToken);
        return oldResult.future;
      }
      nextEntered.complete(cancelToken);
      return nextResult.future;
    };
    await enqueue();
    final oldToken = await firstEntered.future;
    identity.merge();
    await manager.waitForIdle();
    expect(oldToken.isCancelled, isTrue);
    expect(manager.tasks.single.status, NovelDownloadStatus.paused);
    expect(await store.readVolumeSnapshot('book', 'v1'), isNull);

    await manager.resumeVolume('book', 'v1');
    final nextToken = await nextEntered.future;
    expect(nextToken.isCancelled, isFalse);
    expect(identical(oldToken, nextToken), isFalse);
    oldResult.complete(
      const NovelVolumeSnapshot(
        detail: NovelVolumeDetail(book: downloadBook, volume: downloadVolume),
        text: '旧会话迟到正文\n',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(manager.tasks.single.status, NovelDownloadStatus.downloading);
    expect(await store.readVolumeSnapshot('book', 'v1'), isNull);
    nextResult.complete(downloadSnapshot);
    await manager.waitForIdle();
    await expectCompleted('v1');
    expect(requestIdentities, [_oldIdentity, _canonicalIdentity]);
    expect(requestEpochs, [0, 1]);
  });

  test('归并尚未通知监听器时仍按 epoch 拒绝旧请求写入', () async {
    final entered = Completer<void>();
    final result = Completer<NovelVolumeSnapshot>();
    snapshotLoader = (_, _, {required cancelToken}) {
      entered.complete();
      return result.future;
    };
    await enqueue();
    await entered.future;
    identity.merge(notify: false);
    result.complete(downloadSnapshot);
    await manager.waitForIdle();
    expect(manager.tasks.single.status, NovelDownloadStatus.paused);
    expect(await store.readVolumeSnapshot('book', 'v1'), isNull);
    expect(imageCalls, isEmpty);

    snapshotLoader = (_, id, {required cancelToken}) async => _snapshot(id);
    await manager.resumeVolume('book', 'v1');
    await manager.waitForIdle();
    await expectCompleted('v1');
  });

  final rejectedSources = <String, NovelDownloadIdentity>{
    '跨 host': const NovelDownloadIdentity(
      host: 'other.invalid',
      accountId: 'local:b',
    ),
    '另一个独立账号': const NovelDownloadIdentity(
      host: 'copy.invalid',
      accountId: 'local:other',
    ),
    '未知 alias': const NovelDownloadIdentity(
      host: 'copy.invalid',
      accountId: 'local:unknown',
    ),
    'alias 的目标已删除': const NovelDownloadIdentity(
      host: 'copy.invalid',
      accountId: 'local:deleted',
    ),
    '游客任务': const NovelDownloadIdentity(host: 'copy.invalid'),
  };

  for (final entry in rejectedSources.entries) {
    test('${entry.key} 不可通过冷启动、单卷或全部恢复越权执行', () async {
      await restoreQueue(
        [_task(source: entry.value, status: NovelDownloadStatus.queued)],
        beforeInit: () {
          identity.merge();
          identity.aliases['local:deleted'] = 'local:removed';
          // Even a bad guest alias cannot turn a guest task into account work.
          identity.aliases['guest'] = 'local:a';
        },
      );
      await manager.waitForIdle();
      expect(manager.tasks.single.status, NovelDownloadStatus.paused);
      await manager.resumeVolume('book', 'v1');
      await manager.resumeDownloads();
      await manager.waitForIdle();
      expect(manager.tasks.single.status, NovelDownloadStatus.paused);
      expect(snapshotCalls, isEmpty);
      expect(imageCalls, isEmpty);
      expect(await store.readVolumeSnapshot('book', 'v1'), isNull);
    });
  }

  for (final currentId in ['guest', 'local:unknown']) {
    test('当前身份为 $currentId 时拒绝账号任务，null 解析不能视为相等', () async {
      await restoreQueue(
        [
          _task(status: NovelDownloadStatus.queued),
          if (currentId != 'guest')
            _task(
              id: 'v2',
              source: NovelDownloadIdentity(
                host: 'copy.invalid',
                accountId: currentId,
              ),
              status: NovelDownloadStatus.queued,
            ),
        ],
        beforeInit: () {
          identity.merge();
          identity.value = NovelDownloadIdentity(
            host: 'copy.invalid',
            accountId: currentId,
          );
        },
      );
      await manager.waitForIdle();
      await manager.resumeVolumes(
        'book',
        manager.tasks.map((task) => task.volumeId),
      );
      await manager.resumeDownloads();
      await manager.waitForIdle();
      expect(
        manager.tasks.every(
          (task) => task.status == NovelDownloadStatus.paused,
        ),
        isTrue,
      );
      expect(snapshotCalls, isEmpty);
      expect(imageCalls, isEmpty);
    });
  }

  test('游客只能恢复同 host 的游客来源，无需账号解析', () async {
    const guest = NovelDownloadIdentity(host: 'copy.invalid');
    await restoreQueue([
      _task(source: guest, status: NovelDownloadStatus.queued),
    ], beforeInit: () => identity.value = guest);
    await manager.waitForIdle();
    await expectCompleted('v1');
    expect(requestIdentities, [guest]);
  });

  test('全部恢复仅接受可信 alias 和当前 canonical ID', () async {
    await restoreQueue(
      [
        _task(id: 'alias'),
        _task(id: 'canonical', source: _canonicalIdentity),
        for (final entry in rejectedSources.entries)
          _task(id: 'rejected-${entry.key}', source: entry.value),
      ],
      paused: true,
      beforeInit: () {
        identity.merge();
        identity.aliases['local:deleted'] = 'local:removed';
      },
    );
    expect(snapshotCalls, isEmpty);
    await manager.resumeDownloads();
    await manager.waitForIdle();
    await expectCompleted('alias');
    await expectCompleted('canonical');
    expect(snapshotCalls, unorderedEquals(['alias', 'canonical']));
    expect(manager.tasks, hasLength(rejectedSources.length));
    expect(
      manager.tasks.every((task) => task.status == NovelDownloadStatus.paused),
      isTrue,
    );
    expect(requestIdentities, everyElement(_canonicalIdentity));
  });

  test('排队后撤销 alias，调度下一卷前必须重新校验来源', () async {
    await manager.setConcurrency(1);
    final entered = Completer<void>();
    final first = Completer<NovelVolumeSnapshot>();
    snapshotLoader = (_, id, {required cancelToken}) {
      if (id == 'v1') {
        entered.complete();
        return first.future;
      }
      return Future.value(_snapshot(id));
    };
    await restoreQueue(
      [_task(source: _canonicalIdentity), _task(id: 'v2')],
      paused: true,
      beforeInit: identity.merge,
    );
    await manager.resumeDownloads();
    await entered.future;
    expect(manager.taskFor('book', 'v2')!.status, NovelDownloadStatus.queued);
    identity.aliases.remove(
      'local:b',
    ); // Isolate the scheduling check, no epoch event.
    first.complete(downloadSnapshot);
    await manager.waitForIdle();
    await expectCompleted('v1');
    expect(snapshotCalls, ['v1']);
    expect(manager.taskFor('book', 'v2')!.status, NovelDownloadStatus.paused);

    identity.aliases['local:b'] = 'local:a';
    await manager.resumeVolume('book', 'v2');
    await manager.waitForIdle();
    await expectCompleted('v2');
  });

  for (final stage in ['snapshot', 'image', 'cover']) {
    for (final revokeAlias in [true, false]) {
      test(
        '$stage 提交前${revokeAlias ? '撤销 alias' : 'epoch 更新'}必须阻止旧写入',
        () async {
          await restoreQueue([_task()], beforeInit: identity.merge);
          final entered = Completer<void>();
          final release = Completer<void>();
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          bool matchesStage(String path) => switch (stage) {
            'snapshot' => p.basename(path).startsWith('snapshot_'),
            'image' => p.basename(p.dirname(path)) == 'images',
            _ => p.basename(path).startsWith('cover_'),
          };
          beforeWrite = (path) async {
            if (matchesStage(path) && !entered.isCompleted) {
              entered.complete();
              await release.future;
            }
          };
          await manager.resumeVolume('book', 'v1');
          await entered.future;
          if (revokeAlias) {
            identity.aliases.remove('local:b');
          } else {
            identity
                .epoch++; // No listener event: the write guard must read it.
          }
          release.complete();
          await manager.waitForIdle();
          expect(manager.tasks.single.status, NovelDownloadStatus.paused);
          expect(
            (await filesUnder(root)).where((file) => matchesStage(file.path)),
            isEmpty,
          );
          if (stage == 'snapshot') {
            expect(await store.readVolumeSnapshot('book', 'v1'), isNull);
            expect(imageCalls, isEmpty);
          } else if (stage == 'image') {
            expect(await store.readVolumeSnapshot('book', 'v1'), isNotNull);
            expect(
              await store.readImageBytes(
                'book',
                'v1',
                downloadSnapshot.imageUrls.first,
              ),
              isNull,
            );
          } else {
            expect(store.coverPath('book'), isNull);
          }

          if (revokeAlias) {
            await manager.resumeVolume('book', 'v1');
            await manager.waitForIdle();
            expect(manager.tasks.single.status, NovelDownloadStatus.paused);
            identity.aliases['local:b'] = 'local:a';
          }
          await manager.resumeVolume('book', 'v1');
          await manager.waitForIdle();
          await expectCompleted('v1');
          expect(store.coverPath('book'), isNotNull);
        },
      );
    }
  }

  test('未注入 resolver 的 fake manager 仍使用隔离身份，不读取真实账号', () async {
    const fake = NovelDownloadIdentity(
      host: 'isolated.invalid',
      accountId: 'test-only:not-in-account-store',
    );
    await restoreQueue(
      [_task(source: fake, status: NovelDownloadStatus.queued)],
      resolveAliases: false,
      beforeInit: () => identity.value = fake,
    );
    await manager.waitForIdle();
    await expectCompleted('v1');
    expect(requestIdentities, [fake]);
  });
}

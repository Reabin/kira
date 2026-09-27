import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/novel/novel_api.dart';
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

class _Identity extends ChangeNotifier {
  NovelDownloadIdentity value = const NovelDownloadIdentity(
    host: 'copy.invalid',
    accountId: 'u:A',
  );
  int epoch = 0;
  void change(String id) {
    value = NovelDownloadIdentity(host: 'copy.invalid', accountId: id);
    epoch++;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory parent;
  late Directory root;
  late NovelDownloadStore store;
  late NovelDownloadManager manager;
  late _Identity identity;
  late NovelSnapshotLoader snapshotLoader;
  late NovelImageLoader imageLoader;
  var snapshots = 0;
  var imageCalls = <String, int>{};

  NovelDownloadManager create({
    int attempts = 3,
    List<String> protectedRoots = const [],
  }) => NovelDownloadManager.forTesting(
    store: store,
    snapshotLoader: (path, id, {required cancelToken}) =>
        snapshotLoader(path, id, cancelToken: cancelToken),
    imageLoader: (url, {required cancelToken}) =>
        imageLoader(url, cancelToken: cancelToken),
    identityProvider: () => identity.value,
    identityEpochProvider: () => identity.epoch,
    identityChanges: identity,
    protectedRoots: () async => protectedRoots,
    defaultRoot: () async => root.path,
    maxAttempts: attempts,
  );
  Future<void> enqueue() => manager.enqueueVolumes(
    book: downloadBook,
    volumes: [downloadVolume],
    selected: [downloadVolume],
  );

  Future<void> restart() async {
    manager.dispose();
    await manager.waitForIdle();
    store = NovelDownloadStore.forTesting(rootDirectory: root);
    manager = create();
    await manager.init();
    await manager.waitForIdle();
  }

  Future<Map<String, dynamic>> persistedQueue() async {
    final prefs = await SharedPreferences.getInstance();
    return jsonMap({
      'queue': jsonDecode(prefs.getString(NovelDownloadManager.queueStateKey)!),
    }, 'queue')!;
  }

  Future<void> seedQueue(
    List<NovelDownloadTask> tasks, {
    bool paused = true,
  }) async {
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
  }

  NovelDownloadTask savedTask(
    NovelDownloadStatus status, {
    NovelVolume volume = downloadVolume,
  }) => NovelDownloadTask(
    book: downloadBook,
    volume: volume,
    volumes: [volume],
    source: identity.value,
    status: status,
    completed: status == NovelDownloadStatus.completed ? 3 : 0,
    total: 3,
    attempts: 1,
  );

  Future<Map<String, List<int>>> downloadedFiles() async => {
    for (final file in await filesUnder(root))
      file.path: await file.readAsBytes(),
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    parent = await Directory.systemTemp.createTemp('novel_queue_test_');
    root = Directory(p.join(parent.path, 'downloads'));
    store = NovelDownloadStore.forTesting(rootDirectory: root);
    identity = _Identity();
    snapshots = 0;
    imageCalls = {};
    snapshotLoader = (_, _, {required cancelToken}) async {
      snapshots++;
      return downloadSnapshot;
    };
    imageLoader = (url, {required cancelToken}) async {
      imageCalls.update(url, (v) => v + 1, ifAbsent: () => 1);
      return [1, 2, 3];
    };
    manager = create();
    await manager.init();
  });
  tearDown(() async {
    manager.dispose();
    await manager.waitForIdle();
    identity.dispose();
    await parent.delete(recursive: true);
  });

  test(
    'duplicate enqueue is deduplicated and completed files are skipped',
    () async {
      await Future.wait([enqueue(), enqueue(), enqueue()]);
      await manager.waitForIdle();
      expect(manager.tasks, isEmpty);
      expect(manager.statusOf('book', 'v1'), NovelDownloadStatus.completed);
      expect(snapshots, 1);
      await enqueue();
      await manager.waitForIdle();
      expect(snapshots, 1);
      expect(store.downloadedVolumes('book'), {'v1'});
      expect(manager.taskFor('book', 'v1'), isNull);
      expect(manager.isVolumeQueued('book', 'v1'), isFalse);
      expect(manager.isVolumeDownloaded('book', 'v1'), isTrue);
      expect(manager.localNovels.single.downloadedCount, 1);
      expect(manager.localInfo('book')!.volumes.single.id, 'v1');
      expect(
        (await store.readVolumeSnapshot('book', 'v1'))!.toJson(),
        downloadSnapshot.toJson(),
      );
      for (final url in downloadSnapshot.imageUrls) {
        expect(await store.readImageBytes('book', 'v1', url), [1, 2, 3]);
      }
      expect(await File(store.coverPath('book')!).readAsBytes(), [1, 2, 3]);
      expect(manager.activeCount, 0);
      expect(manager.queuedCount, 0);
      expect(manager.activity.hasRunnableWork, isFalse);
      expect(manager.activity.total, 0);
      expect(jsonList(await persistedQueue(), 'tasks'), isEmpty);
    },
  );

  for (final keepSecondInDirectory in [true, false]) {
    test('本地卷按目录而非下载顺序排列，并保留目录外的旧卷：$keepSecondInDirectory', () async {
      const second = NovelVolume(
        id: 'v2',
        name: '第二卷',
        bookPathWord: 'book',
        txtAddr: 'https://cdn.invalid/v2.txt',
        contents: [NovelContentEntry(name: '正文', contentType: 1, endLines: 1)],
      );
      final volumes = [
        downloadVolume,
        if (keepSecondInDirectory) second,
        const NovelVolume(id: 'v3', name: '未下载卷', bookPathWord: 'book'),
      ];
      await store.saveSnapshot(
        book: downloadBook,
        volumes: volumes,
        snapshot: const NovelVolumeSnapshot(
          detail: NovelVolumeDetail(book: downloadBook, volume: second),
          text: '第二卷正文\n',
        ),
      );
      await store.saveSnapshot(
        book: downloadBook,
        volumes: volumes,
        snapshot: downloadSnapshot,
      );
      expect(manager.localInfo('book')!.downloaded.keys, ['v2', 'v1']);
      expect(manager.localVolumes('book').map((v) => v.id), ['v1', 'v2']);
      await restart();
      expect(manager.localVolumes('book').map((v) => v.id), ['v1', 'v2']);
      expect(manager.localVolumes('unknown'), isEmpty);
      expect(snapshots, 0);
      expect(imageCalls, isEmpty);
    });
  }

  test(
    'pause cancels only the owned token and ignores a late uncancellable result',
    () async {
      final entered = Completer<CancelToken>();
      final late = Completer<NovelVolumeSnapshot>();
      snapshotLoader = (_, _, {required cancelToken}) {
        entered.complete(cancelToken);
        return late.future;
      };
      await enqueue();
      final token = await entered.future;
      await manager.pauseVolume('book', 'v1');
      expect(token.isCancelled, isTrue);
      await manager.waitForIdle();
      late.complete(downloadSnapshot);
      await Future<void>.delayed(Duration.zero);
      expect(manager.tasks.single.status, NovelDownloadStatus.paused);
      expect(await store.readVolumeSnapshot('book', 'v1'), isNull);
      snapshotLoader = (_, _, {required cancelToken}) async => downloadSnapshot;
      await manager.resumeVolume('book', 'v1');
      await manager.waitForIdle();
      expect(manager.tasks, isEmpty);
      expect(manager.statusOf('book', 'v1'), NovelDownloadStatus.completed);
    },
  );

  test('delete blocks late image response from recreating volume', () async {
    final entered = Completer<CancelToken>();
    final late = Completer<List<int>>();
    imageLoader = (_, {required cancelToken}) {
      entered.complete(cancelToken);
      return late.future;
    };
    await enqueue();
    final token = await entered.future;
    await manager.deleteVolume('book', 'v1');
    expect(token.isCancelled, isTrue);
    late.complete([1, 2, 3]);
    await manager.waitForIdle();
    expect(manager.tasks, isEmpty);
    expect(await store.readVolumeSnapshot('book', 'v1'), isNull);
    final restarted = NovelDownloadStore.forTesting(rootDirectory: root);
    await restarted.init();
    expect(restarted.downloadedVolumes('book'), isEmpty);
  });

  test(
    'retry attempts are finite and 401/locked failures never auto-retry',
    () async {
      snapshotLoader = (_, _, {required cancelToken}) async {
        snapshots++;
        throw StateError('offline');
      };
      await enqueue();
      await manager.waitForIdle();
      expect(snapshots, 3);
      expect(manager.tasks.single.status, NovelDownloadStatus.failed);
      snapshots = 0;
      snapshotLoader = (_, _, {required cancelToken}) async {
        snapshots++;
        throw const NovelApiException('denied', statusCode: 401);
      };
      await manager.retry('book', 'v1');
      await manager.waitForIdle();
      expect(snapshots, 1);
      expect(manager.tasks.single.status, NovelDownloadStatus.unauthorized);
      snapshots = 0;
      snapshotLoader = (_, _, {required cancelToken}) async {
        snapshots++;
        throw NovelAccessException(
          const NovelVolumeDetail(
            book: downloadBook,
            volume: downloadVolume,
            isLocked: true,
          ),
        );
      };
      await manager.retry('book', 'v1');
      await manager.waitForIdle();
      expect(snapshots, 1);
      expect(manager.tasks.single.status, NovelDownloadStatus.locked);
    },
  );

  test(
    'partial retry reuses text and complete illustrations, downloads only missing assets',
    () async {
      var fail = true;
      imageLoader = (url, {required cancelToken}) async {
        imageCalls.update(url, (v) => v + 1, ifAbsent: () => 1);
        if (url.endsWith('image2') && fail) {
          throw StateError('image unavailable');
        }
        return [1, 2, 3];
      };
      await enqueue();
      await manager.waitForIdle();
      expect(manager.tasks.single.status, NovelDownloadStatus.partial);
      expect(await store.readVolumeSnapshot('book', 'v1'), isNotNull);
      expect(snapshots, 1);
      expect(imageCalls['https://cdn.invalid/image1'], 1);
      expect(imageCalls['https://cdn.invalid/image2'], 3);
      expect(
        jsonList(await persistedQueue(), 'tasks').single,
        containsPair('status', NovelDownloadStatus.partial.name),
      );
      await restart();
      expect(manager.tasks.single.status, NovelDownloadStatus.partial);
      expect(await store.readVolumeSnapshot('book', 'v1'), isNotNull);
      expect(snapshots, 1);
      fail = false;
      await manager.retry('book', 'v1');
      await manager.waitForIdle();
      expect(snapshots, 1);
      expect(imageCalls['https://cdn.invalid/image1'], 1);
      expect(manager.tasks, isEmpty);
      expect(manager.statusOf('book', 'v1'), NovelDownloadStatus.completed);
    },
  );

  test(
    'cover failure is best-effort and does not fail complete volume',
    () async {
      imageLoader = (url, {required cancelToken}) async {
        if (url.endsWith('cover')) throw StateError('missing cover');
        return [1, 2, 3];
      };
      await enqueue();
      await manager.waitForIdle();
      expect(manager.tasks, isEmpty);
      expect(manager.statusOf('book', 'v1'), NovelDownloadStatus.completed);
      expect(store.coverPath('book'), isNull);
    },
  );

  test(
    'restart restores paused queue and complete local data without network',
    () async {
      await manager.pauseDownloads();
      await enqueue();
      manager.dispose();
      store = NovelDownloadStore.forTesting(rootDirectory: root);
      manager = create();
      await manager.init();
      expect(manager.paused, isTrue);
      expect(manager.tasks.single.status, NovelDownloadStatus.paused);
      final persisted = jsonEncode(await persistedQueue());
      expect(persisted, contains('u:A'));
      expect(persisted, isNot(contains('token')));
      expect(snapshots, 0);
      await manager.resumeDownloads();
      await manager.waitForIdle();
      expect(snapshots, 1);
      manager.dispose();
      store = NovelDownloadStore.forTesting(rootDirectory: root);
      manager = create();
      await manager.init();
      await manager.waitForIdle();
      expect(manager.tasks, isEmpty);
      expect(manager.statusOf('book', 'v1'), NovelDownloadStatus.completed);
      expect(snapshots, 1);
    },
  );

  for (final status in [
    NovelDownloadStatus.completed,
    NovelDownloadStatus.downloading,
  ]) {
    test(
      'restart retires ${status.name} with verified files and preserves unfinished tasks',
      () async {
        await saveFixture(store, complete: true);
        await store.saveCover('book', [3, 2, 1]);
        final filesBefore = await downloadedFiles();
        final unfinished = [
          for (final status in [
            NovelDownloadStatus.paused,
            NovelDownloadStatus.partial,
            NovelDownloadStatus.failed,
            NovelDownloadStatus.unauthorized,
            NovelDownloadStatus.locked,
            NovelDownloadStatus.needsRepair,
          ])
            savedTask(
              status,
              volume: NovelVolume(id: status.name, name: status.name),
            ),
        ];
        final paused = status == NovelDownloadStatus.completed;
        await seedQueue([savedTask(status), ...unfinished], paused: paused);

        await restart();
        expect(manager.paused, paused);
        expect(manager.taskFor('book', 'v1'), isNull);
        expect(manager.statusOf('book', 'v1'), NovelDownloadStatus.completed);
        expect(
          manager.tasks.map((task) => task.toJson()),
          unfinished.map((task) => task.toJson()),
        );
        expect(
          jsonList(await persistedQueue(), 'tasks'),
          unfinished.map((task) => task.toJson()).toList(),
        );
        expect(jsonBool(await persistedQueue(), 'paused'), paused);
        expect(
          (await store.readVolumeSnapshot('book', 'v1'))!.toJson(),
          downloadSnapshot.toJson(),
        );
        expect(manager.localInfo('book')!.volumes.map((v) => v.id), [
          'v1',
          'v2',
        ]);
        expect(await downloadedFiles(), filesBefore);

        await restart();
        expect(manager.tasks, hasLength(unfinished.length));
        expect(manager.isVolumeDownloaded('book', 'v1'), isTrue);
        expect(snapshots, 0);
        expect(imageCalls, isEmpty);
        expect(await downloadedFiles(), filesBefore);
      },
    );
  }

  for (final missingSnapshot in [true, false]) {
    test(
      'completed task with missing ${missingSnapshot ? 'snapshot' : 'image'} stays repairable',
      () async {
        await saveFixture(store, complete: true);
        await store.saveCover('book', [3, 2, 1]);
        final missing = (await filesUnder(root)).firstWhere(
          (file) => missingSnapshot
              ? p.basename(file.path).startsWith('snapshot_')
              : p.basename(p.dirname(file.path)) == 'images',
        );
        await missing.delete();
        final remainingFiles = await downloadedFiles();
        await seedQueue([savedTask(NovelDownloadStatus.completed)]);

        await restart();
        expect(manager.tasks.single.status, NovelDownloadStatus.needsRepair);
        expect(manager.isVolumeDownloaded('book', 'v1'), isFalse);
        expect(manager.localVolumeIds('book'), {'v1'});
        expect(
          await store.readVolumeSnapshot('book', 'v1'),
          missingSnapshot ? isNull : isNotNull,
        );
        expect(
          jsonList(await persistedQueue(), 'tasks').single,
          containsPair('status', NovelDownloadStatus.needsRepair.name),
        );
        expect(await downloadedFiles(), remainingFiles);
        expect(snapshots, 0);
        expect(imageCalls, isEmpty);
      },
    );
  }

  test(
    'completion retires only its task and pumps the next queued volume',
    () async {
      final volumes = [
        for (var i = 1; i <= 3; i++)
          NovelVolume(
            id: 'v$i',
            name: '卷$i',
            txtAddr: downloadVolume.txtAddr,
            contents: downloadVolume.contents,
          ),
      ];
      final results = {
        for (final volume in volumes)
          volume.id: Completer<NovelVolumeSnapshot>(),
      };
      final entered = {
        for (final volume in volumes) volume.id: Completer<void>(),
      };
      snapshotLoader = (_, id, {required cancelToken}) {
        snapshots++;
        entered[id]!.complete();
        return results[id]!.future;
      };
      void complete(NovelVolume volume) {
        results[volume.id]!.complete(
          NovelVolumeSnapshot(
            detail: NovelVolumeDetail(book: downloadBook, volume: volume),
            text: downloadSnapshot.text,
          ),
        );
      }

      await manager.enqueueVolumes(
        book: downloadBook,
        volumes: volumes,
        selected: volumes,
      );
      await Future.wait([entered['v1']!.future, entered['v2']!.future]);
      expect(manager.activity.active, 2);
      expect(manager.activity.pending, 1);
      complete(volumes[1]);
      await entered['v3']!.future;
      expect(manager.taskFor('book', 'v2'), isNull);
      expect(manager.statusOf('book', 'v2'), NovelDownloadStatus.completed);
      expect(manager.tasks.map((task) => task.volumeId), ['v1', 'v3']);
      expect(manager.activity.active, 2);
      expect(manager.activity.pending, 0);
      complete(volumes[0]);
      complete(volumes[2]);
      await manager.waitForIdle();
      expect(manager.tasks, isEmpty);
      expect(store.downloadedVolumes('book'), {'v1', 'v2', 'v3'});
      expect(jsonList(await persistedQueue(), 'tasks'), isEmpty);
      expect(manager.activity.hasRunnableWork, isFalse);
      expect(snapshots, 3);
    },
  );

  test(
    'deleted task late result cannot retire or overwrite its replacement',
    () async {
      final entered = Completer<void>();
      final late = Completer<NovelVolumeSnapshot>();
      snapshotLoader = (_, _, {required cancelToken}) {
        entered.complete();
        return late.future;
      };
      await enqueue();
      await entered.future;
      await manager.deleteVolume('book', 'v1');
      final replacementEntered = Completer<void>();
      final replacement = Completer<NovelVolumeSnapshot>();
      snapshotLoader = (_, _, {required cancelToken}) {
        replacementEntered.complete();
        return replacement.future;
      };
      await enqueue();
      await replacementEntered.future;
      final task = manager.tasks.single;
      late.complete(downloadSnapshot);
      await Future<void>.delayed(Duration.zero);
      expect(identical(manager.tasks.single, task), isTrue);
      expect(task.status, NovelDownloadStatus.downloading);
      expect(await store.readVolumeSnapshot('book', 'v1'), isNull);
      replacement.complete(downloadSnapshot);
      await manager.waitForIdle();
      expect(manager.tasks, isEmpty);
      expect(manager.isVolumeDownloaded('book', 'v1'), isTrue);
      expect(jsonList(await persistedQueue(), 'tasks'), isEmpty);
    },
  );

  test(
    'identity changes pause unfinished tasks; same stable source can resume and logout retains books',
    () async {
      final entered = Completer<void>();
      final late = Completer<NovelVolumeSnapshot>();
      snapshotLoader = (_, _, {required cancelToken}) {
        entered.complete();
        return late.future;
      };
      await enqueue();
      await entered.future;
      identity.change('u:B');
      await manager.waitForIdle();
      expect(manager.tasks.single.status, NovelDownloadStatus.paused);
      await manager.resumeVolume('book', 'v1');
      expect(manager.tasks.single.status, NovelDownloadStatus.paused);
      identity.change('u:A');
      late.complete(downloadSnapshot);
      await Future<void>.delayed(Duration.zero);
      expect(await store.readVolumeSnapshot('book', 'v1'), isNull);
      snapshotLoader = (_, _, {required cancelToken}) async => downloadSnapshot;
      await manager.resumeVolume('book', 'v1');
      await manager.waitForIdle();
      identity.change('guest');
      expect(manager.tasks, isEmpty);
      expect(manager.statusOf('book', 'v1'), NovelDownloadStatus.completed);
      expect(manager.localNovels.single.downloadedCount, 1);
      expect(await store.readVolumeSnapshot('book', 'v1'), isNotNull);
    },
  );

  test(
    'scalar reload preserves queue and never reloads save directory',
    () async {
      await manager.pauseDownloads();
      await enqueue();
      final task = manager.tasks.single;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(NovelDownloadManager.concurrencyKey, 4);
      await prefs.setString(NovelDownloadManager.saveDirectoryKey, 'unrelated');
      await prefs.setString(NovelDownloadManager.queueStateKey, '{bad');
      await manager.reloadScalarSettings();
      expect(identical(manager.tasks.single, task), isTrue);
      expect(manager.concurrency, 4);
      expect(manager.rootPath, root.path);
    },
  );

  test(
    'directory rejects comic overlap and busy queue, migrates safely when paused',
    () async {
      manager.dispose();
      final comic = p.join(parent.path, 'comic_downloads');
      manager = create(protectedRoots: [comic]);
      await manager.init();
      await expectLater(manager.setSaveDirectory(comic), throwsArgumentError);
      await expectLater(
        manager.setSaveDirectory(p.join(comic, 'nested')),
        throwsArgumentError,
      );
      await expectLater(
        manager.setSaveDirectory(parent.path),
        throwsArgumentError,
      );
      final entered = Completer<void>();
      final late = Completer<NovelVolumeSnapshot>();
      snapshotLoader = (_, _, {required cancelToken}) {
        entered.complete();
        return late.future;
      };
      await enqueue();
      await entered.future;
      await expectLater(
        manager.setSaveDirectory(p.join(parent.path, 'new-root')),
        throwsStateError,
      );
      await manager.pauseDownloads();
      await manager.waitForIdle();
      late.complete(downloadSnapshot);
      await manager.setSaveDirectory(p.join(parent.path, 'new-root'));
      expect(manager.rootPath, p.join(parent.path, 'new-root'));
      expect(
        (await SharedPreferences.getInstance()).getString(
          NovelDownloadManager.saveDirectoryKey,
        ),
        manager.rootPath,
      );
    },
  );
}

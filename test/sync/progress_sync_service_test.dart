import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/sync/progress_local_store.dart';
import 'package:kira/sync/progress_sync_service.dart';
import 'package:kira/sync/progress_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

const book = 'reading_history_book_group_default';

Map<String, dynamic> comic(
  int page, {
  String chapter = 'chapter',
  String? time,
}) => {
  'chapterUuid': chapter,
  'chapterName': chapter,
  'comicName': '漫画',
  'page': page,
  'totalPage': 100,
  'updatedAt': time ?? '2026-10-01T00:00:00Z',
  'readChapterUuids': [chapter],
};

class MemoryLocal implements ProgressLocalStore {
  final Map<String, String> values = {};
  Future<void> Function()? beforeApply;
  void turn(int page, {String key = book, String? time}) {
    values[key] = jsonEncode(comic(page, time: time));
  }

  int? page([String key = book]) =>
      values[key] == null ? null : jsonDecode(values[key]!)['page'];
  @override
  Future<Map<String, String>> snapshot() async => Map.of(values);
  @override
  Future<bool> apply(
    String key,
    String? expected,
    Map<String, dynamic> data,
  ) async {
    await beforeApply?.call();
    if (values[key] != expected) return false;
    values[key] = jsonEncode(data);
    return true;
  }
}

class MemoryCloud implements ProgressTransport {
  final Map<String, String> files = {};
  bool failRead = false;
  bool failWrite = false;
  int writes = 0;
  Future<void> Function()? onRead;
  @override
  Future<Map<String, String>> readDevices() async {
    await onRead?.call();
    if (failRead) throw StateError('offline read');
    return Map.of(files);
  }

  @override
  Future<void> writeDevice(String device, String document) async {
    if (failWrite) throw StateError('offline write');
    writes++;
    files['kira-progress-$device.json'] = document;
  }

  @override
  void close() {}
}

/// Separate preference backends simulate independent installations, while the
/// real prefs-backed sync state persists across recreated service instances.
class Device {
  Device(this.cloud, {this.target = 'same-cloud'});
  final MemoryCloud cloud;
  final String target;
  final local = MemoryLocal();
  Map<String, Object> prefs = {'progress_sync_enabled': true};
  late ProgressSyncService service = create();
  ProgressSyncService create() => ProgressSyncService(
    local: local,
    endpointFactory: () async => (identity: target, transport: cloud),
  );

  Future<void> run([Future<void> Function()? operation]) async {
    SharedPreferences.setMockInitialValues(prefs);
    await (operation?.call() ?? service.sync());
    final store = await SharedPreferences.getInstance();
    prefs = {
      for (final k in store.getKeys())
        if (store.get(k) != null) k: store.get(k)!,
    };
  }

  void restart() {
    service.dispose();
    service = create();
  }

  void dispose() => service.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryCloud cloud;
  late Device a;
  late Device b;
  setUp(() {
    cloud = MemoryCloud();
    a = Device(cloud);
    b = Device(cloud);
  });
  tearDown(() {
    a.dispose();
    b.dispose();
  });

  test(
    'pulls pages and intentional backwards rereading; clocks ignore device time',
    () async {
      a.local.turn(80, time: '2099-01-01T00:00:00Z');
      await a.run();
      await b.run();
      expect(b.local.page(), 80);
      b.local.turn(3, time: '2000-01-01T00:00:00Z');
      await b.run();
      await a.run();
      expect(a.local.page(), 3);
      expect(a.service.conflicts, isEmpty);
    },
  );

  test(
    'independent books and chapter groups merge without replacing a library',
    () async {
      a.local.turn(20);
      b.local.turn(7, key: 'reading_history_other_group_default');
      b.local.turn(9, key: 'reading_history_book_group_extra');
      await a.run();
      await b.run();
      await a.run();
      expect(a.local.page(), 20);
      expect(a.local.page('reading_history_other_group_default'), 7);
      expect(a.local.page('reading_history_book_group_extra'), 9);
      expect(a.service.conflicts, isEmpty);
    },
  );

  test(
    'offline edits preserve both positions until explicit resolution',
    () async {
      a.local.turn(1);
      await a.run();
      await b.run();
      a.local.turn(5);
      b.local.turn(9);
      await a.run();
      await b.run();
      await a.run();
      expect(a.local.page(), 5);
      expect(b.local.page(), 9);
      expect(
        a.service.conflicts.single.choices.map((e) => e.data['page']),
        unorderedEquals([5, 9]),
      );
      final conflict = b.service.conflicts.single;
      final selected = conflict.choices.firstWhere((e) => e.data['page'] == 5);
      await b.run(() => b.service.resolve(conflict, selected));
      await a.run();
      await b.run();
      expect(a.local.page(), 5);
      expect(b.local.page(), 5);
      expect(a.service.conflicts, isEmpty);
      expect(b.service.conflicts, isEmpty);
    },
  );

  test(
    'first setup with differing existing histories asks instead of overwriting',
    () async {
      a.local.turn(10);
      await a.run();
      b.local.turn(2);
      await b.run();
      expect(b.local.page(), 2);
      expect(b.service.conflicts, hasLength(1));
    },
  );

  test(
    'opening same page with refreshed timestamp does not create an edit or upload',
    () async {
      a.local.turn(10);
      await a.run();
      final files = Map.of(cloud.files);
      final writes = cloud.writes;
      a.local.turn(10, time: '2026-11-02T12:00:00Z');
      await a.run();
      expect(cloud.files, files);
      expect(cloud.writes, writes);
    },
  );

  test('outbox survives read/write failure and a recreated service', () async {
    a.local.turn(4);
    cloud.failRead = true;
    await a.run();
    expect(a.service.error, isNotNull);
    a.restart();
    cloud.failRead = false;
    cloud.failWrite = true;
    await a.run();
    expect(a.service.error, isNotNull);
    a.restart();
    cloud.failWrite = false;
    await a.run();
    await b.run();
    expect(b.local.page(), 4);
    expect(a.service.error, isNull);
  });

  test(
    'active reader uploads but defers remote application until it is left',
    () async {
      a.local.turn(1);
      await a.run();
      await b.run();
      a.local.turn(4);
      await a.run();
      b.service.canApplyRemote = () => false;
      await b.run();
      expect(b.local.page(), 1);
      b.service.canApplyRemote = () => true;
      await b.run();
      expect(b.local.page(), 4);
    },
  );

  test(
    'page turn during cloud read becomes a conflict rather than being overwritten',
    () async {
      a.local.turn(1);
      await a.run();
      await b.run();
      a.local.turn(4);
      await a.run();
      cloud.onRead = () async {
        b.local.turn(7);
      };
      await b.run();
      cloud.onRead = null;
      expect(b.local.page(), 7);
      expect(b.service.conflicts, hasLength(1));
    },
  );

  test(
    'local compare-and-apply rejects a turn made after the network snapshot',
    () async {
      a.local.turn(1);
      await a.run();
      await b.run();
      a.local.turn(4);
      await a.run();
      b.local.beforeApply = () async {
        b.local.turn(8);
      };
      await b.run();
      b.local.beforeApply = null;
      expect(b.local.page(), 8);
      await b.run();
      expect(b.service.conflicts, hasLength(1));
    },
  );

  test(
    'temporary missing or older provider files cannot roll back known progress',
    () async {
      a.local.turn(1);
      await a.run();
      final old = Map.of(cloud.files);
      await b.run();
      a.local.turn(4);
      await a.run();
      await b.run();
      cloud.files
        ..clear()
        ..addAll(old);
      await b.run();
      expect(b.local.page(), 4);
      cloud.files.clear();
      await b.run();
      expect(b.local.page(), 4);
    },
  );

  test(
    'clearing local history stays local and is not immediately resurrected',
    () async {
      a.local.turn(2);
      await a.run();
      await b.run();
      b.local.values.clear();
      await b.run();
      await b.run();
      expect(b.local.page(), isNull);
      expect(a.local.page(), 2);
      a.local.turn(3);
      await a.run();
      await b.run();
      expect(b.local.page(), 3);
    },
  );

  test(
    'malformed remote data fails without writing or clearing local history',
    () async {
      a.local.turn(2);
      cloud.files['kira-progress-${'b' * 32}.json'] = '{broken';
      await a.run();
      expect(a.service.error, isNotNull);
      expect(a.local.page(), 2);
      expect(cloud.writes, 0);
      cloud.files.clear();
      await a.run();
      expect(a.service.error, isNull);
    },
  );

  test('filename identity mismatch is rejected', () async {
    a.local.turn(2);
    await a.run();
    cloud.files['kira-progress-${'c' * 32}.json'] = cloud.files.values.first;
    await b.run();
    expect(b.service.error, isNotNull);
    expect(b.local.values, isEmpty);
  });

  test('novel sync strips signed text and cover URLs', () async {
    const key = 'novel_reading_history_novel';
    a.local.values[key] = jsonEncode({
      'pathWord': 'novel',
      'name': '书',
      'volumeId': 'v1',
      'volumeName': '卷一',
      'chapterName': '第一章',
      'entryIndex': 3,
      'paragraphIndex': 8,
      'paragraphAlignment': -0.2,
      'updatedAt': '2026-11-01T00:00:00Z',
      'txtAddr': 'https://example.com/txt?token=secret',
      'cover': 'https://example.com/cover?token=secret',
    });
    await a.run();
    await b.run();
    expect(cloud.files.values.single, isNot(contains('secret')));
    expect(jsonDecode(b.local.values[key]!)['entryIndex'], 3);
    expect(jsonDecode(b.local.values[key]!)['paragraphIndex'], 8);
  });

  test('disabled sync performs no local or remote changes', () async {
    a.prefs['progress_sync_enabled'] = false;
    a.local.turn(5);
    await a.run();
    expect(cloud.files, isEmpty);
    expect(a.prefs.keys, isNot(contains(startsWith('progress_sync_state_'))));
  });

  test(
    'same-position concurrent histories merge read marks without a conflict',
    () async {
      final data = comic(2);
      a.local.values[book] = jsonEncode({
        ...data,
        'readChapterUuids': ['chapter', 'one'],
      });
      b.local.values[book] = jsonEncode({
        ...data,
        'readChapterUuids': ['chapter', 'two'],
      });
      await a.run();
      await b.run();
      await a.run();
      expect(a.service.conflicts, isEmpty);
      expect(b.service.conflicts, isEmpty);
      expect(
        jsonDecode(a.local.values[book]!)['readChapterUuids'],
        containsAll(['one', 'two']),
      );
    },
  );
}

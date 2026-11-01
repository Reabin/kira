import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/sync/progress_sync_service.dart';
import 'package:kira/utils/reading_history.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';
import 'progress_sync_service_test.dart' show MemoryCloud;

void main() {
  setUp(() {
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({'progress_sync_enabled': true});
  });
  tearDown(teardownSecureCredentialStoreForTest);

  testWidgets(
    'startup, saved page and resume exchange automatically; disable preserves immediate reads',
    (tester) async {
      await tester.pumpWidget(wrapWithApp(const SizedBox()));
      final cloud = MemoryCloud();
      final service = ProgressSyncService(
        endpointFactory: () async => (identity: 'lifecycle', transport: cloud),
      );
      service.start();
      await tester.pumpAndSettle();
      expect(service.lastExchange, isNotNull);
      await ReadingHistory.save(
        pathWord: 'book',
        chapterUuid: 'chapter',
        chapterName: 'chapter',
        page: 6,
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
        jsonDecode(cloud.files.values.single)['entries'].single['data']['page'],
        6,
      );
      final writes = cloud.writes;
      service.setForeground(false);
      await tester.pumpAndSettle();
      service.setForeground(true);
      await tester.pumpAndSettle();
      expect(
        cloud.writes,
        writes,
      ); // Unchanged resumes do not rewrite cloud files.
      await service.settings.save(
        enabled: false,
        backend: service.settings.backend,
      );
      expect(service.beforeRead(), isNull);
      service.dispose();
      await ReadingHistory.flush();
      expect(ReadingHistory.beforeRead, isNull);
    },
  );
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/pages/progress_sync_page.dart';
import 'package:kira/providers/backup_providers.dart';
import 'package:kira/sync/progress_sync_service.dart';
import 'package:kira/sync/progress_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sync/progress_sync_service_test.dart' show MemoryCloud, MemoryLocal;
import '../test_helpers.dart';

void main() {
  late ProgressSyncService service;
  late List<String> calls;
  setUp(() {
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({});
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ICloudProgressFolder.channel, (
          MethodCall call,
        ) async {
          calls.add(call.method);
          if (call.method == 'status') return {'configured': false};
          if (call.method == 'choose') return true;
          return null;
        });
    final cloud = MemoryCloud();
    service = ProgressSyncService(
      local: MemoryLocal(),
      endpointFactory: () async => (identity: 'test', transport: cloud),
    );
  });
  tearDown(() {
    service.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ICloudProgressFolder.channel, null);
    teardownSecureCredentialStoreForTest();
  });

  Widget page() => ProviderScope(
    overrides: [progressSyncServiceProvider.overrideWithValue(service)],
    child: wrapWithApp(const ProgressSyncPage(), wrapInScaffold: false),
  );

  testWidgets(
    'iPad offers both backends and persists WebDAV selection and switch',
    (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('iCloud Drive'), findsOneWidget);
      expect(find.text('WebDAV'), findsOneWidget);
      expect(find.text('选择同步文件夹'), findsOneWidget);
      await tester.tap(find.text('WebDAV'));
      await tester.pumpAndSettle();
      expect(find.text('配置 WebDAV'), findsOneWidget);
      expect(find.text('选择同步文件夹'), findsNothing);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('progress_sync_backend'), 'webDav');
      expect(prefs.getBool('progress_sync_enabled'), isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'folder selection requests native authorization without silently enabling sync',
    (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择同步文件夹'));
      await tester.pumpAndSettle();
      expect(calls, contains('choose'));
      expect(find.textContaining('已选择。'), findsOneWidget);
      expect(service.settings.enabled, isFalse);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'slow folder authorization shows progress and a timeout remains retryable',
    (tester) async {
      final selected = Completer<bool>();
      var attempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ICloudProgressFolder.channel, (call) async {
            if (call.method == 'status') return {'configured': false};
            if (call.method == 'choose') {
              attempts++;
              if (attempts == 1) return selected.future;
              return true;
            }
            return null;
          });
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择同步文件夹'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      selected.completeError(
        PlatformException(
          code: 'progress_folder_timeout',
          message: '文件夹授权处理超时，请确认 iCloud Drive 可用后重试',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('文件夹授权处理超时'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('已选择。'), findsNothing);
      await tester.tap(find.text('选择同步文件夹'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已选择。'), findsOneWidget);
      expect(attempts, 2);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'cancelled folder selection leaves settings usable',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            ICloudProgressFolder.channel,
            (call) async =>
                call.method == 'status' ? {'configured': false} : false,
          );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择同步文件夹'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已选择。'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byType(SwitchListTile), findsOneWidget);
      expect(service.settings.enabled, isFalse);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/backup/webdav_client.dart';
import 'package:kira/backup/webdav_config.dart';
import 'package:kira/sync/progress_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backup/fake_webdav_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'iCloud reads and writes bind to the selected folder identity',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ICloudProgressFolder.channel, (call) async {
            calls.add(call);
            return call.method == 'read' ? <String, String>{} : null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ICloudProgressFolder.channel, null),
      );
      final folder = ICloudProgressFolder(identity: 'folder-a');
      await folder.readDevices();
      await folder.writeDevice('a' * 32, '{}');
      expect(calls.map((call) => call.arguments['identity']), [
        'folder-a',
        'folder-a',
      ]);
    },
  );
  test(
    'WebDAV replaces only its device file atomically in the separate directory',
    () async {
      SharedPreferences.setMockInitialValues({});
      final adapter = FakeWebDavAdapter();
      final config = WebDavConfig(
        serverUrl: 'https://dav.example/dav/',
        directory: 'kira-progress-v1',
      );
      final client = WebDavClient(
        config: config,
        credentials: const WebDavCredentials(
          username: 'user',
          password: 'secret',
        ),
        adapter: adapter,
      );
      final transport = WebDavProgressTransport(client);
      final first = 'a' * 32;
      final second = 'b' * 32;
      await transport.writeDevice(first, 'first');
      await transport.writeDevice(second, 'other device');
      await transport.writeDevice(first, 'new');
      final files = await transport.readDevices();
      expect(files, {
        'kira-progress-$first.json': 'new',
        'kira-progress-$second.json': 'other device',
      });
      expect(
        adapter.requests
            .where((r) => r.method == 'MOVE')
            .every((r) => r.headers['Overwrite'] == 'T'),
        isTrue,
      );
      expect(adapter.files.keys.any((k) => k.endsWith('.uploading')), isFalse);
      expect(
        adapter.requests.any(
          (r) => r.method == 'DELETE' && r.uri.path.endsWith('.json'),
        ),
        isFalse,
      );
      expect(
        adapter.requests.every((r) => !r.headers.containsKey('Cookie')),
        isTrue,
      );
      transport.close();
    },
  );

  test('an interrupted replacement preserves old device contents', () async {
    SharedPreferences.setMockInitialValues({});
    final adapter = FakeWebDavAdapter();
    final config = WebDavConfig(
      serverUrl: 'https://dav.example/dav/',
      directory: 'kira-progress-v1',
    );
    final client = WebDavClient(
      config: config,
      credentials: const WebDavCredentials(
        username: 'user',
        password: 'secret',
      ),
      adapter: adapter,
    );
    final transport = WebDavProgressTransport(client);
    final device = 'a' * 32;
    await transport.writeDevice(device, 'original');
    adapter.beforeResponse = (request) async {
      if (request.method == 'MOVE') {
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
        );
      }
    };
    await expectLater(
      transport.writeDevice(device, 'replacement'),
      throwsA(isA<WebDavException>()),
    );
    expect(
      utf8.decode(
        adapter.files[config.fileUri('kira-progress-$device.json').path]!,
      ),
      'original',
    );
    expect(adapter.files.length, 1);
    transport.close();
  });
}

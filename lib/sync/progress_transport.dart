import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../backup/webdav_client.dart';

abstract interface class ProgressTransport {
  Future<Map<String, String>> readDevices();
  Future<void> writeDevice(String device, String document);
  void close();
}

class ICloudProgressFolder implements ProgressTransport {
  ICloudProgressFolder({required this.identity});
  final String identity;
  static const channel = MethodChannel('io.github.reabin.kira/progress_folder');

  static Future<Map<String, dynamic>> status() async {
    final result = await channel.invokeMapMethod<String, dynamic>('status');
    return result ?? {};
  }

  static Future<bool> choose() async =>
      await channel.invokeMethod<bool>('choose') ?? false;

  @override
  Future<Map<String, String>> readDevices() async {
    final result = await channel.invokeMapMethod<String, String>('read', {
      'identity': identity,
    });
    return result ?? {};
  }

  @override
  Future<void> writeDevice(String device, String document) async {
    await channel.invokeMethod<void>('write', {
      'identity': identity,
      'device': device,
      'document': document,
    });
  }

  @override
  void close() {}
}

class WebDavProgressTransport implements ProgressTransport {
  WebDavProgressTransport(this.client);
  final WebDavClient client;
  final _cancel = CancelToken();

  @override
  Future<Map<String, String>> readDevices() async {
    final files = (await client.list(cancel: _cancel))
        .where(
          (entry) => RegExp(
            r'^kira-progress-[a-f0-9]{32}\.json$',
          ).hasMatch(entry.name),
        )
        .toList();
    if (files.length > 100) throw StateError('同步设备文件超过 100 个');
    final result = <String, String>{};
    var total = 0;
    for (final file in files) {
      final bytes = await client.download(file, cancel: _cancel);
      total += bytes.length;
      if (bytes.length > 8 * 1024 * 1024 || total > 16 * 1024 * 1024) {
        throw StateError('阅读进度同步文件过大');
      }
      result[file.name] = utf8.decode(bytes);
    }
    return result;
  }

  @override
  Future<void> writeDevice(String device, String document) =>
      client.writeDeviceProgress(
        'kira-progress-$device.json',
        Uint8List.fromList(utf8.encode(document)),
        cancel: _cancel,
      );

  @override
  void close() {
    _cancel.cancel();
    client.close();
  }
}

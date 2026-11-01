import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ProgressSyncBackend { iCloud, webDav }

/// Device-local preferences. Folder grants and service credentials are never
/// exported by the portable backup whitelist.
class ProgressSyncSettings {
  bool enabled = false;
  ProgressSyncBackend backend = defaultTargetPlatform == TargetPlatform.iOS
      ? ProgressSyncBackend.iCloud
      : ProgressSyncBackend.webDav;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool('progress_sync_enabled') ?? false;
    final name = prefs.getString('progress_sync_backend');
    backend =
        defaultTargetPlatform == TargetPlatform.iOS &&
            (name == 'iCloud' || name == null)
        ? ProgressSyncBackend.iCloud
        : ProgressSyncBackend.webDav;
  }

  Future<void> save({
    required bool enabled,
    required ProgressSyncBackend backend,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString('progress_sync_backend', backend.name) ||
        !await prefs.setBool('progress_sync_enabled', enabled)) {
      throw StateError('无法保存阅读进度同步设置');
    }
    this.enabled = enabled;
    this.backend = backend;
  }
}

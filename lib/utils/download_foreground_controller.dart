import 'dart:async';
import 'dart:io' show Platform;

import 'package:clock/clock.dart' show clock;
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../l10n/app_localizations.dart';
import '../models/download_activity_snapshot.dart';
import '../models/user_manager.dart';
import 'app_logger.dart';
import 'download_manager.dart';

/// 漫画与轻小说下载共享同一个 Android 前台服务。
class DownloadForegroundController {
  DownloadForegroundController({
    Listenable? listenable,
    List<ComicDownloadTaskInfo> Function()? tasks,
    DownloadActivitySnapshot Function()? activity,
    String Function(AppLocalizations)? title,
    String Function(AppLocalizations)? channelName,
    DownloadForegroundGateway? gateway,
    bool? supported,
  }) : _listenable = listenable ?? DownloadManager(),
       _activityOf =
           activity ?? (() => comicActivity((tasks ?? _defaultTasks)())),
       _genericActivity = activity != null,
       _titleOf = title ?? ((l10n) => l10n.downloadForegroundTitle),
       _channelNameOf =
           channelName ?? ((l10n) => l10n.downloadForegroundChannel),
       _gateway = gateway ?? FlutterForegroundTaskGateway(),
       _supported = supported ?? Platform.isAndroid;

  static List<ComicDownloadTaskInfo> _defaultTasks() => DownloadManager().tasks;
  static const Duration _minUpdateInterval = Duration(milliseconds: 800);

  final Listenable _listenable;
  final DownloadActivitySnapshot Function() _activityOf;
  final bool _genericActivity;
  final String Function(AppLocalizations) _titleOf;
  final String Function(AppLocalizations) _channelNameOf;
  final DownloadForegroundGateway _gateway;
  final bool _supported;
  bool _attached = false;
  bool _alignChecked = false;
  bool _serviceWanted = false;
  bool _serviceRunning = false;
  String? _lastText;
  String? _pendingText;
  DateTime _lastUpdateAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _trailing;
  Future<void> _tail = Future<void>.value();

  @visibleForTesting
  static bool serviceShouldRun(List<ComicDownloadTaskInfo> tasks) =>
      comicActivity(tasks).hasRunnableWork;

  static DownloadActivitySnapshot comicActivity(
    List<ComicDownloadTaskInfo> tasks,
  ) {
    var active = 0, pending = 0, done = 0, total = 0;
    for (final task in tasks) {
      switch (task.status) {
        case ComicDownloadTaskStatus.downloading:
          active++;
          final progress = task.progress;
          if (progress != null) {
            done += progress.completed;
            total += progress.total;
          }
        case ComicDownloadTaskStatus.pending:
          pending++;
        case ComicDownloadTaskStatus.paused:
          break;
      }
    }
    return DownloadActivitySnapshot(
      active: active,
      pending: pending,
      completed: done,
      total: total,
    );
  }

  @visibleForTesting
  static String composeText(
    AppLocalizations l10n,
    List<ComicDownloadTaskInfo> tasks,
  ) => _composeComicText(l10n, comicActivity(tasks));

  static String _composeComicText(
    AppLocalizations l10n,
    DownloadActivitySnapshot activity,
  ) {
    final body = l10n.downloadForegroundBody(activity.active, activity.pending);
    final files = l10n.downloadForegroundImages(
      activity.completed,
      activity.total,
    );
    return activity.total > 0 ? '$body · $files' : body;
  }

  /// 中立快照用于合并漫画与轻小说；保留 [composeText] 的旧漫画文案兼容性。
  static String composeActivityText(
    AppLocalizations l10n,
    DownloadActivitySnapshot activity,
  ) {
    final body = l10n.downloadForegroundGenericBody(
      activity.active,
      activity.pending,
    );
    final files = l10n.downloadForegroundFiles(
      activity.completed,
      activity.total,
    );
    return activity.total > 0 ? '$body · $files' : body;
  }

  String _composeActivityText(
    AppLocalizations l10n,
    DownloadActivitySnapshot activity,
  ) => _genericActivity
      ? composeActivityText(l10n, activity)
      : _composeComicText(l10n, activity);

  void attach() {
    if (_attached || !_supported) return;
    _attached = true;
    _listenable.addListener(_onChanged);
    unawaited(sync());
  }

  @visibleForTesting
  void detach() {
    if (!_attached) return;
    _attached = false;
    _trailing?.cancel();
    _trailing = null;
    _listenable.removeListener(_onChanged);
  }

  @visibleForTesting
  Future<void> flush() => _tail;
  void _onChanged() => unawaited(sync());

  @visibleForTesting
  Future<void> sync() async {
    if (!_supported) return;
    final activity = _activityOf();
    final l10n = _resolveL10n();
    final title = _titleOf(l10n);
    final channel = _channelNameOf(l10n);
    if (activity.hasRunnableWork) {
      final text = _composeActivityText(l10n, activity);
      if (!_serviceWanted) {
        _serviceWanted = true;
        _pendingText = null;
        _trailing?.cancel();
        _trailing = null;
        _enqueue(() => _start(title, channel, text));
      } else {
        _pendingText = text;
        _scheduleUpdate();
      }
      return;
    }
    if (_serviceWanted) {
      _serviceWanted = false;
      _pendingText = null;
      _trailing?.cancel();
      _trailing = null;
      _enqueue(_stop);
    } else if (!_alignChecked) {
      _alignChecked = true;
      _enqueue(_stopZombie);
    }
  }

  Future<void> _start(String title, String channel, String text) async {
    if (!_serviceWanted) return;
    try {
      if (await _gateway.isRunning()) {
        _serviceRunning = true;
        _lastText = text;
        await _gateway.update(title: title, text: text);
      } else {
        await _gateway.ensureNotificationPermission();
        if (!_serviceWanted) return;
        await _gateway.start(title: title, text: text, channelName: channel);
        _serviceRunning = true;
        _lastText = text;
      }
      _lastUpdateAt = clock.now();
    } catch (error, stack) {
      _serviceRunning = false;
      _log('启动失败', error, stack);
    }
  }

  void _scheduleUpdate() {
    final sinceLast = clock.now().difference(_lastUpdateAt);
    if (sinceLast >= _minUpdateInterval) {
      _flushUpdate();
      return;
    }
    _trailing ??= Timer(_minUpdateInterval - sinceLast, () {
      _trailing = null;
      _flushUpdate();
    });
  }

  void _flushUpdate() {
    final text = _pendingText;
    _pendingText = null;
    if (text == null ||
        !_serviceWanted ||
        !_serviceRunning ||
        text == _lastText) {
      return;
    }
    _lastText = text;
    _lastUpdateAt = clock.now();
    final title = _titleOf(_resolveL10n());
    _enqueue(() async {
      if (_serviceWanted && _serviceRunning) {
        await _gateway.update(title: title, text: text);
      }
    });
  }

  Future<void> _stop() async {
    _serviceRunning = false;
    try {
      if (await _gateway.isRunning()) await _gateway.stop();
    } catch (error, stack) {
      _log('停止失败', error, stack);
    }
  }

  Future<void> _stopZombie() async {
    try {
      if (await _gateway.isRunning()) await _gateway.stop();
    } catch (error, stack) {
      _log('清理残留服务失败', error, stack);
    }
  }

  void _enqueue(Future<void> Function() operation) {
    _tail = _tail.then((_) async {
      try {
        await operation();
      } catch (error, stack) {
        _log('服务操作失败', error, stack);
      }
    });
  }

  void _log(String operation, Object error, StackTrace stack) {
    unawaited(
      AppLogger.instance.recordWarning(
        '下载前台服务$operation: $error',
        stackTrace: stack,
        source: 'download_foreground',
      ),
    );
  }

  AppLocalizations _resolveL10n() {
    final configured = UserManager().locale;
    final Locale locale = switch (configured) {
      'zh' => const Locale('zh'),
      'zh-Hant' => const Locale.fromSubtags(
        languageCode: 'zh',
        scriptCode: 'Hant',
      ),
      _ => _systemLocale(),
    };
    return lookupAppLocalizations(locale);
  }

  static Locale _systemLocale() {
    final system = WidgetsBinding.instance.platformDispatcher.locale;
    if (system.languageCode == 'zh') {
      final country = system.countryCode?.toUpperCase();
      if (system.scriptCode == 'Hant' ||
          country == 'TW' ||
          country == 'HK' ||
          country == 'MO') {
        return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
      }
    }
    return const Locale('zh');
  }
}

abstract interface class DownloadForegroundGateway {
  Future<bool> isRunning();
  Future<void> ensureNotificationPermission();
  Future<void> start({
    required String title,
    required String text,
    required String channelName,
  });
  Future<void> update({required String title, required String text});
  Future<void> stop();
}

class FlutterForegroundTaskGateway implements DownloadForegroundGateway {
  static const int _serviceId = 420435;
  bool _optionsReady = false;

  void _ensureOptions(String channelName) {
    if (_optionsReady) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'kira_comic_download',
        channelName: channelName,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWifiLock: true,
      ),
    );
    _optionsReady = true;
  }

  @override
  Future<bool> isRunning() => FlutterForegroundTask.isRunningService;

  @override
  Future<void> ensureNotificationPermission() async {
    if (await FlutterForegroundTask.checkNotificationPermission() ==
        NotificationPermission.granted) {
      return;
    }
    await FlutterForegroundTask.requestNotificationPermission();
  }

  @override
  Future<void> start({
    required String title,
    required String text,
    required String channelName,
  }) async {
    _ensureOptions(channelName);
    final result = await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: title,
      notificationText: text,
    );
    if (result is ServiceRequestFailure) throw result.error;
  }

  @override
  Future<void> update({required String title, required String text}) async {
    final result = await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
    if (result is ServiceRequestFailure) throw result.error;
  }

  @override
  Future<void> stop() async {
    final result = await FlutterForegroundTask.stopService();
    if (result is ServiceRequestFailure) throw result.error;
  }
}

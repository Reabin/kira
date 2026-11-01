import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backup/backup_settings.dart';
import '../backup/webdav_client.dart';
import '../backup/webdav_config.dart';
import '../utils/app_logger.dart';
import '../utils/json_helpers.dart';
import '../utils/novel_reading_store.dart';
import '../utils/reading_history.dart';
import 'progress_document.dart';
import 'progress_local_store.dart';
import 'progress_sync_settings.dart';
import 'progress_transport.dart';

typedef ProgressEndpoint = ({String identity, ProgressTransport transport});

class ProgressConflict {
  ProgressConflict(this.key, this.choices);
  final String key;
  final List<ProgressEntry> choices;
}

class ProgressSyncService extends ChangeNotifier {
  static ProgressSyncService? _active;
  bool _restoring = false;

  static Future<void> pauseForRestore() async {
    final active = _active;
    if (active == null) return;
    active._restoring = true;
    await active._operation;
  }

  static void resumeAfterRestore() {
    final active = _active;
    if (active == null) return;
    active._restoring = false;
    active._changed();
  }

  ProgressSyncService({
    ProgressSyncSettings? settings,
    ProgressLocalStore? local,
    this.endpointFactory,
    bool Function()? canApplyRemote,
  }) : settings = settings ?? ProgressSyncSettings(),
       local = local ?? SharedProgressLocalStore(),
       canApplyRemote = canApplyRemote ?? (() => true);

  final ProgressSyncSettings settings;
  final ProgressLocalStore local;
  final Future<ProgressEndpoint> Function()? endpointFactory;
  bool Function() canApplyRemote;
  bool busy = false;
  Object? error;
  DateTime? lastExchange;
  List<ProgressConflict> conflicts = [];
  Map<String, String> localPositions = {};
  bool _started = false;
  bool _disposed = false;
  bool _foreground = true;
  Timer? _debounce;
  Timer? _poll;
  Future<void>? _operation;
  Future<void>? Function()? _readHook;
  final Map<String, ProgressEntry> _resolutions = {};
  String? _resolutionTarget;

  void start() {
    if (_started) return;
    _started = true;
    _active = this;
    ReadingHistory.changes.addListener(_changed);
    NovelReadingStore.changes.addListener(_changed);
    _readHook = beforeRead;
    ReadingHistory.beforeRead = _readHook;
    NovelReadingStore.beforeRead = _readHook;
    setForeground(true);
  }

  void _changed() {
    if (_disposed) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 5), () => unawaited(sync()));
  }

  void setForeground(bool value) {
    _foreground = value;
    _poll?.cancel();
    _debounce?.cancel();
    if (value) {
      _poll = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(sync()),
      );
    }
    // Leaving the app is best effort; iOS may suspend it before cloud exchange.
    unawaited(sync());
  }

  Future<void>? beforeRead() {
    if (!canApplyRemote()) return null;
    if (_operation != null) {
      return _operation;
    }
    if (!settings.enabled ||
        (lastExchange != null &&
            DateTime.now().difference(lastExchange!) <
                const Duration(seconds: 3))) {
      return null;
    }
    return sync();
  }

  Future<ProgressEndpoint> _endpoint() async {
    if (endpointFactory != null) return endpointFactory!();
    final native = defaultTargetPlatform == TargetPlatform.iOS
        ? await ICloudProgressFolder.status()
        : <String, dynamic>{};
    final installation = jsonString(native, 'installation');
    if (defaultTargetPlatform == TargetPlatform.iOS && installation.isEmpty) {
      throw StateError('尚未取得设备标识，请解锁设备后重试');
    }
    if (settings.backend == ProgressSyncBackend.iCloud) {
      if (defaultTargetPlatform != TargetPlatform.iOS) {
        throw StateError('iCloud Drive 文件夹同步仅适用于 iPhone 和 iPad');
      }
      final status = native;
      if (status['configured'] != true ||
          jsonString(status, 'identity').isEmpty) {
        throw StateError('请先选择 iCloud Drive 同步文件夹');
      }
      return (
        identity: 'icloud:${jsonString(status, 'identity')}:$installation',
        transport: ICloudProgressFolder(
          identity: jsonString(status, 'identity'),
        ),
      );
    }
    final data = await BackupSettings().load();
    if (!data.webDavEnabled || data.connection == null) {
      throw StateError('请先在备份设置中启用并配置 WebDAV');
    }
    final connection = data.connection!;
    final config = WebDavConfig(
      serverUrl: connection.server.toString(),
      directory: '${connection.directory}kira-progress-v1',
      allowHttp: connection.allowHttp,
    );
    return (
      identity:
          'webdav:${config.root}:${data.credentials.username}:$installation',
      transport: WebDavProgressTransport(
        WebDavClient(
          config: config,
          credentials: data.credentials,
          timeout: const Duration(seconds: 8),
        ),
      ),
    );
  }

  Future<void> sync() {
    if (_disposed) return Future.value();
    return _operation ??= _run().whenComplete(() => _operation = null);
  }

  Future<void> _run() async {
    ProgressTransport? transport;
    try {
      await settings.load();
      if (!settings.enabled || _disposed || _restoring) return;
      busy = true;
      error = null;
      notifyListeners();
      final endpoint = await _endpoint();
      transport = endpoint.transport;
      final target = sha256.convert(utf8.encode(endpoint.identity)).toString();
      if (_resolutionTarget != target) {
        _resolutions.clear();
        _resolutionTarget = target;
      }
      final prefs = await SharedPreferences.getInstance();
      final stateKey = 'progress_sync_state_v1_$target';
      final rawState = prefs.getString(stateKey);
      final state = rawState == null
          ? <String, dynamic>{}
          : jsonDecode(rawState);
      if (state is! Map<String, dynamic>) throw StateError('本机同步状态已损坏');
      var device = jsonString(state, 'device');
      if (device.isEmpty) {
        final random = Random.secure();
        device = List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
      }
      if (!validDevice(device)) throw StateError('本机同步设备标识无效');
      var sequence = jsonInt(state, 'sequence');
      final bases = jsonMap(state, 'bases') ?? {};
      var published = jsonString(state, 'published');
      final documents = <String, ProgressDocument>{};
      for (final entry in (jsonMap(state, 'documents') ?? {}).entries) {
        if (entry.value is! String) throw StateError('本机同步文件状态无效');
        documents[entry.key] = ProgressDocument.decode(entry.value);
      }
      final own = <String, ProgressEntry>{...?documents[device]?.entries};
      var snapshot = await local.snapshot();
      void capture() {
        localPositions = {};
        for (final item in snapshot.entries) {
          final decoded = jsonDecode(item.value);
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException('Invalid local reading progress');
          }
          if (item.key.startsWith('reading_history_')) {
            // Older local records accepted numeric strings and omitted dates.
            // Normalize the local format without relaxing the cloud protocol.
            decoded['page'] = jsonInt(decoded, 'page', fallback: 1);
            decoded['totalPage'] = jsonInt(decoded, 'totalPage');
            if (DateTime.tryParse(jsonString(decoded, 'updatedAt')) == null) {
              decoded['updatedAt'] = '1970-01-01T00:00:00Z';
            }
          }
          final data = progressData(item.key, decoded);
          final position = progressPosition(data);
          localPositions[item.key] = position;
          final base = jsonMap(bases, item.key);
          if (base != null &&
              base['fingerprint'] == progressFingerprint(data)) {
            continue;
          }
          // A local page turn is based only on revisions actually applied here.
          // Observing another device's unaccepted progress never acknowledges it.
          final clock = <String, int>{};
          final baseClock = jsonMap(base, 'clock') ?? {};
          for (final key in baseClock.keys) {
            clock[key] = jsonInt(baseClock, key);
          }
          sequence++;
          clock[device] = sequence;
          final event = ProgressEntry(key: item.key, data: data, clock: clock);
          own[item.key] = event;
          bases[item.key] = {
            'position': position,
            'clock': clock,
            'fingerprint': progressFingerprint(data),
          };
        }
        // Clearing local history is local-only. Do not resurrect an unchanged
        // cloud position or erase another device's history as a side effect.
        for (final key in bases.keys.toList()) {
          if (!snapshot.containsKey(key)) {
            final base = jsonMap(bases, key) ?? {};
            base['position'] = null;
            base['fingerprint'] = null;
            bases[key] = base;
          }
        }
      }

      Future<void> persist() async {
        documents[device] = ProgressDocument(
          device: device,
          sequence: sequence,
          entries: own,
        );
        if (documents.length > 100 || own.length > 20000) {
          throw StateError('本机保存的同步设备或阅读记录超过协议上限');
        }
        final encoded = documents.map(
          (key, doc) => MapEntry(key, doc.encode()),
        );
        if (encoded.values.fold<int>(
              0,
              (sum, text) => sum + utf8.encode(text).length,
            ) >
            16 * 1024 * 1024) {
          throw StateError('本机阅读进度同步状态超过 16 MB');
        }
        if (!await prefs.setString(
          stateKey,
          jsonEncode({
            'device': device,
            'sequence': sequence,
            'bases': bases,
            'published': published,
            'documents': encoded,
          }),
        )) {
          throw StateError('无法保存离线同步队列');
        }
      }

      capture();
      await persist(); // Durable outbox before any network or File Provider call.
      final downloaded = await transport.readDevices().timeout(
        const Duration(seconds: 20),
      );
      for (final file in downloaded.entries) {
        final doc = ProgressDocument.decode(file.value);
        if (file.key != 'kira-progress-${doc.device}.json') {
          throw const FormatException('Progress filename/device mismatch');
        }
        final previous = documents[doc.device];
        if (previous == null || doc.sequence > previous.sequence) {
          documents[doc.device] = doc;
        } else if (doc.sequence == previous.sequence &&
            doc.encode() != previous.encode()) {
          throw StateError('同一设备出现了相同版本但不同内容的同步文件');
        }
        if (doc.device == device && doc.sequence > sequence) {
          throw StateError('设备标识重复，请重新选择同步位置');
        }
      }
      if (_disposed || !settings.enabled || _restoring) return;
      // Capture turns made while waiting for the cloud before considering pulls.
      snapshot = await local.snapshot();
      capture();
      documents[device] = ProgressDocument(
        device: device,
        sequence: sequence,
        entries: own,
      );
      final all = <String, List<ProgressEntry>>{};
      for (final doc in documents.values) {
        for (final event in doc.entries.values) {
          all.putIfAbsent(event.key, () => []).add(event);
        }
      }
      final pending = <ProgressConflict>[];
      for (final item in all.entries) {
        final heads = progressHeads(item.value);
        final positions = heads.map((e) => e.position).toSet();
        final resolution = _resolutions[item.key];
        ProgressEntry? chosen;
        if (positions.length > 1) {
          // Resolution is tied to exactly the set shown to the user. A newly
          // arrived revision must be reviewed again, never silently discarded.
          final clocks = mergeClocks(heads.map((e) => e.clock));
          if (resolution != null &&
              clockIncludes(resolution.clock, clocks) &&
              clockIncludes(clocks, resolution.clock)) {
            chosen = resolution;
          } else {
            pending.add(ProgressConflict(item.key, heads));
            continue;
          }
        } else {
          chosen = heads.first;
        }
        if (!_foreground || !canApplyRemote()) continue;
        final clock = mergeClocks(heads.map((e) => e.clock));
        final base = jsonMap(bases, item.key);
        final known = jsonMap(base, 'clock') ?? {};
        final knownClock = {for (final k in known.keys) k: jsonInt(known, k)};
        final hasResolution =
            resolution != null && identical(chosen, resolution);
        if (!hasResolution && clockIncludes(knownClock, clock)) continue;
        final data = Map<String, dynamic>.of(chosen.data);
        final readKey = data.containsKey('volumeId')
            ? 'readVolumeIds'
            : 'readChapterUuids';
        data[readKey] =
            item.value
                .expand((e) => jsonList(e.data, readKey).whereType<String>())
                .toSet()
                .toList()
              ..sort();
        final applied = await local.apply(item.key, snapshot[item.key], data);
        if (!applied) continue;
        if (hasResolution) {
          sequence++;
          clock[device] = sequence;
          own[item.key] = ProgressEntry(
            key: item.key,
            data: data,
            clock: clock,
          );
          _resolutions.remove(item.key);
        }
        bases[item.key] = {
          'position': chosen.position,
          'clock': clock,
          'fingerprint': progressFingerprint(data),
        };
      }
      conflicts = pending;
      await persist();
      if (_disposed || !settings.enabled) return;
      final outgoing = documents[device]!.encode();
      if (own.isNotEmpty &&
          (published != outgoing ||
              !downloaded.containsKey('kira-progress-$device.json'))) {
        await transport
            .writeDevice(device, outgoing)
            .timeout(const Duration(seconds: 20));
        published = outgoing;
        await persist();
      }
      lastExchange = DateTime.now();
    } catch (failure, stack) {
      error = failure;
      // Never log server URLs, credentials, book payloads or signed text URLs.
      unawaited(
        AppLogger.instance.recordWarning(
          'Progress sync failed (${failure.runtimeType})',
          stackTrace: stack,
          source: 'progress_sync',
        ),
      );
    } finally {
      transport?.close();
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> resolve(ProgressConflict conflict, ProgressEntry choice) async {
    if (busy ||
        !conflicts.contains(conflict) ||
        !conflict.choices.contains(choice)) {
      return;
    }
    _resolutions[conflict.key] = ProgressEntry(
      key: choice.key,
      data: choice.data,
      clock: mergeClocks(conflict.choices.map((e) => e.clock)),
    );
    await sync();
  }

  @override
  void dispose() {
    _disposed = true;
    if (identical(_active, this)) _active = null;
    _poll?.cancel();
    _debounce?.cancel();
    if (_started) {
      ReadingHistory.changes.removeListener(_changed);
      NovelReadingStore.changes.removeListener(_changed);
      if (identical(ReadingHistory.beforeRead, _readHook)) {
        ReadingHistory.beforeRead = null;
      }
      if (identical(NovelReadingStore.beforeRead, _readHook)) {
        NovelReadingStore.beforeRead = null;
      }
    }
    super.dispose();
  }
}

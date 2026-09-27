import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api/novel/novel_api.dart';
import '../l10n/app_localizations.dart';
import '../models/novel.dart';
import '../models/novel_reader_settings.dart';
import '../models/novel_reading_progress.dart';
import '../models/reader_settings.dart';
import '../providers/novel_providers.dart';
import '../repositories/novel_reader_source.dart';
import '../repositories/novel_repository.dart';
import '../routing/app_router.dart';
import '../theme/app_spacing.dart';
import '../theme/novel_reader_theme.dart';
import '../theme/reader_chrome.dart';
import '../utils/app_logger.dart';
import '../utils/novel_bookmark_store.dart';
import '../utils/novel_reading_store.dart';
import '../utils/toast.dart';
import '../widgets/app_sheet.dart';
import '../widgets/error_retry_view.dart';
import '../widgets/reader_status_overlay.dart';
import 'novel_reader/novel_reader_contents_sheet.dart';
import 'novel_reader/novel_reader_document.dart';
import 'novel_reader/novel_reader_settings_sheet.dart';
import 'novel_reader/novel_reader_viewport.dart';

class NovelReaderPage extends ConsumerStatefulWidget {
  const NovelReaderPage({
    super.key,
    required this.pathWord,
    required this.volumeId,
    this.name = '',
    this.cover = '',
    this.initialEntryIndex = 0,
    this.initialParagraphIndex = 0,
    this.initialParagraphAlignment = 0,
    this.resume = false,
    this.localOnly = false,
    this.source,
  });

  final String pathWord;
  final String volumeId;
  final String name;
  final String cover;
  final int initialEntryIndex;
  final int initialParagraphIndex;
  final double initialParagraphAlignment;
  final bool resume;
  final bool localOnly;
  final NovelReaderSource? source;

  @override
  ConsumerState<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends ConsumerState<NovelReaderPage>
    with WidgetsBindingObserver {
  late final NovelRepository _repository;
  late NovelReaderSource _source;
  late final NovelApi _api;
  late final NovelReadingStore _store;
  late final NovelBookmarkStore _bookmarks;
  // 状态组件直接共享漫画阅读器的全局配置（开关/位置/段位/不透明度）。
  late final ReaderSettings _statusSettings = ReaderSettings()
    ..addListener(_onStatusSettingsChanged);
  bool _bookmarksLoaded = false;
  bool _bookmarking = false;
  GlobalKey<NovelReaderViewportState> _viewportKey = GlobalKey();
  NovelReaderSettings _settings = const NovelReaderSettings();
  NovelVolumeContent? _content;
  NovelVolumeDetail? _accessDetail;
  NovelReaderDocument? _document;
  NovelReaderLocation? _location;
  NovelReaderAnchor _target = const NovelReaderAnchor(entryIndex: 0);
  NovelReadingProgress? _pendingProgress;
  List<NovelVolume> _volumes = [];
  Object? _error;
  Timer? _saveTimer;
  Future<void> _lastWrite = Future<void>.value();
  static Future<void>? _wakeQueue;
  DateTime _lastTimestamp = DateTime.fromMillisecondsSinceEpoch(0);
  late String _pathWord;
  late String _volumeId;
  late String _fallbackName;
  late String _fallbackCover;
  int _session = 0;
  int _request = 0;
  int _jumpRevision = 0;
  bool _loading = true;
  bool _toolbarVisible = true;
  bool _disposed = false;
  bool _offline = false;
  double? _sliderValue;

  @override
  void initState() {
    super.initState();
    _repository = ref.read(novelRepositoryProvider);
    _api = ref.read(novelApiProvider);
    _store = ref.read(novelReadingStoreProvider);
    _bookmarks = ref.read(novelBookmarkStoreProvider)
      ..addListener(_onBookmarksChanged);
    unawaited(_loadBookmarks());
    WidgetsBinding.instance.addObserver(this);
    _beginSession();
  }

  @override
  void didUpdateWidget(NovelReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pathWord != widget.pathWord ||
        oldWidget.volumeId != widget.volumeId ||
        oldWidget.initialEntryIndex != widget.initialEntryIndex ||
        oldWidget.initialParagraphIndex != widget.initialParagraphIndex ||
        oldWidget.initialParagraphAlignment !=
            widget.initialParagraphAlignment ||
        oldWidget.resume != widget.resume ||
        oldWidget.localOnly != widget.localOnly ||
        oldWidget.source != widget.source) {
      // Capture against the old book's identity, not the new widget fields.
      unawaited(_flush());
      _beginSession();
    }
  }

  Future<void> _loadBookmarks() async {
    try {
      await _bookmarks.ensureLoaded();
      if (mounted) setState(() => _bookmarksLoaded = true);
    } catch (error, stack) {
      _warn(error, stack, 'bookmarks.load');
    }
  }

  void _onBookmarksChanged() {
    if (mounted) setState(() {});
  }

  void _onStatusSettingsChanged() {
    if (mounted) setState(() {});
  }

  bool get _isBookmarked {
    final anchor = _location?.anchor;
    return anchor != null &&
        _bookmarks.isBookmarked(
          pathWord: _pathWord,
          volumeId: _volumeId,
          entryIndex: anchor.entryIndex,
          paragraphIndex: anchor.paragraphIndex,
        );
  }

  Future<void> _toggleBookmark() async {
    if (_loading || _bookmarking) return;
    final location = _viewportKey.currentState?.currentLocation;
    if (location == null || _content == null || _document == null) return;
    final progress = _progressAt(location, DateTime.now());
    final session = _session;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _bookmarking = true);
    try {
      final added = await _bookmarks.toggle(progress: progress);
      if (!mounted || !_active(session)) return;
      setState(() => _bookmarksLoaded = true);
      showToast(context, added ? l10n.bookmarkAdded : l10n.bookmarkRemoved);
    } catch (error, stack) {
      _warn(error, stack, 'bookmarks.toggle');
      if (mounted && _active(session)) {
        showToast(context, l10n.bookmarksUpdateFailed, isError: true);
      }
    } finally {
      if (mounted) setState(() => _bookmarking = false);
    }
  }

  void _beginSession() {
    final session = ++_session;
    ++_request;
    _pathWord = widget.pathWord;
    _volumeId = widget.volumeId;
    _source = widget.source ?? RepositoryNovelReaderSource(_repository);
    _fallbackName = widget.name;
    _fallbackCover = widget.cover;
    _loading = true;
    _content = null;
    _document = null;
    _accessDetail = null;
    _location = null;
    _pendingProgress = null;
    _error = null;
    _volumes = [];
    _saveTimer?.cancel();
    final initial = NovelReaderAnchor(
      entryIndex: widget.initialEntryIndex,
      paragraphIndex: widget.initialParagraphIndex,
      alignment: widget.initialParagraphAlignment,
    );
    unawaited(_initialize(session, widget.resume, initial));
  }

  bool _active(int session) => mounted && !_disposed && session == _session;

  Future<void> _initialize(
    int session,
    bool resume,
    NovelReaderAnchor initial,
  ) async {
    final path = _pathWord;
    final volume = _volumeId;
    final request = _request;
    var anchor = initial;
    try {
      final settings = await NovelReaderSettings.load();
      if (!_active(session)) return;
      _settings = settings;
      _setScreenOn(settings.keepScreenOn);
    } catch (error, stack) {
      _warn(error, stack, 'settings.load');
    }
    if (!_active(session)) return;
    if (resume) {
      try {
        final progress = await _store.readProgress(path);
        if (!_active(session) || request != _request) return;
        // Resume is deliberately scoped to the requested book AND volume.
        // Explicit navigation to a different volume must not be hijacked.
        if (progress != null &&
            progress.pathWord == path &&
            progress.volumeId == volume) {
          anchor = NovelReaderAnchor(
            entryIndex: progress.entryIndex,
            paragraphIndex: progress.paragraphIndex,
            alignment: progress.paragraphAlignment,
          );
          if (progress.updatedAt.isAfter(_lastTimestamp)) {
            _lastTimestamp = progress.updatedAt;
          }
        }
      } catch (error, stack) {
        _warn(error, stack, 'progress.load');
      }
    }
    if (!_active(session) || request != _request) return;
    if (widget.source == null) {
      final downloads = ref.read(novelDownloadStoreProvider);
      try {
        if (widget.localOnly) {
          await downloads.init();
          if (!_active(session) || request != _request) return;
          _source = DownloadedNovelReaderSource(downloads);
        } else if (downloads.rootPath != null) {
          // 生产启动时已初始化下载目录；普通在线测试或未启用下载时不触发平台 I/O。
          final snapshot = await downloads.readVolumeSnapshot(path, volume);
          if (!_active(session) || request != _request) return;
          if (snapshot != null) {
            _source = DownloadedNovelReaderSource(downloads);
          }
        }
      } catch (error, stack) {
        _warn(error, stack, 'downloads.resolve');
        if (!_active(session) || request != _request) return;
        if (widget.localOnly) {
          setState(() {
            _offline = true;
            _loading = false;
            _error = const NovelDownloadUnavailableException();
          });
          return;
        }
      }
    }
    if (!_active(session) || request != _request) return;
    unawaited(_loadVolumes(session, path));
    await _loadVolume(volume, anchor: anchor);
  }

  Future<void> _loadVolumes(int session, String path) async {
    try {
      final volumes = await _source.loadVolumes(path);
      if (_active(session)) setState(() => _volumes = volumes);
    } catch (error, stack) {
      // A missing remote directory must not prevent cached text from opening.
      _warn(error, stack, 'volumes.load');
    }
  }

  Future<void> _loadVolume(
    String volume, {
    required NovelReaderAnchor anchor,
    bool refresh = false,
    bool cachedOnly = false,
    bool lastEntry = false,
  }) async {
    unawaited(_flush());
    final session = _session;
    final request = ++_request;
    final path = _pathWord;
    setState(() {
      _volumeId = volume;
      _target = anchor;
      _loading = true;
      _content = null;
      _document = null;
      _location = null;
      _accessDetail = null;
      _error = null;
      _sliderValue = null;
      _offline = cachedOnly || _source.localOnly;
      _viewportKey = GlobalKey();
    });
    try {
      final content = await _source.loadContent(
        path,
        volume,
        refresh: refresh,
        cachedOnly: cachedOnly,
      );
      if (!_active(session) || request != _request) return;
      if (content == null) {
        setState(() => _error = const _NoCachedVolume());
        return;
      }
      if (content.detail.isLocked) throw NovelAccessException(content.detail);
      final document = NovelReaderDocument(content.entries);
      setState(() {
        _content = content;
        _document = document;
        _accessDetail = content.detail;
        if (document.itemCount > 0) {
          _target = lastEntry
              ? NovelReaderAnchor(entryIndex: document.entries.last.entryIndex)
              : document.anchorFor(
                  document.itemFor(anchor),
                  alignment: anchor.alignment,
                );
        }
      });
    } catch (error, stack) {
      _warn(error, stack, 'volume.load');
      if (_active(session) && request == _request) {
        setState(() {
          _error = error;
          if (error is NovelAccessException) _accessDetail = error.detail;
        });
      }
    } finally {
      if (_active(session) && request == _request) {
        setState(() => _loading = false);
      }
    }
  }

  NovelReadingProgress _progressAt(
    NovelReaderLocation location,
    DateTime updatedAt,
  ) {
    final content = _content!;
    final book = content.detail.book;
    final volume = content.detail.volume;
    return NovelReadingProgress(
      pathWord: _pathWord,
      name: book.name.isEmpty ? _fallbackName : book.name,
      cover: book.cover.isEmpty ? _fallbackCover : book.cover,
      volumeId: _volumeId,
      volumeName: volume.name,
      chapterName: _document!.paragraphAt(location.itemIndex).entry.name,
      entryIndex: location.anchor.entryIndex,
      paragraphIndex: location.anchor.paragraphIndex,
      paragraphAlignment: location.anchor.alignment,
      progress: location.progress,
      txtAddr: volume.txtAddr,
      updatedAt: updatedAt,
    );
  }

  void _recordLocation(
    NovelReaderLocation location, {
    bool rebuild = true,
    bool debounce = true,
  }) {
    final content = _content;
    final document = _document;
    if (_disposed || content == null || document == null || _loading) return;
    final previous = _location;
    _location = location;
    final changed =
        previous == null ||
        previous.anchor.entryIndex != location.anchor.entryIndex ||
        previous.anchor.paragraphIndex != location.anchor.paragraphIndex ||
        (previous.anchor.alignment - location.anchor.alignment).abs() > 0.0001;
    if (!changed) return;
    final now = DateTime.now();
    _lastTimestamp = now.isAfter(_lastTimestamp)
        ? now
        : _lastTimestamp.add(const Duration(microseconds: 1));
    _pendingProgress = _progressAt(location, _lastTimestamp);
    if (debounce) {
      _saveTimer?.cancel();
      _saveTimer = Timer(
        const Duration(milliseconds: 350),
        () => unawaited(_flush()),
      );
    }
    if (rebuild &&
        mounted &&
        (previous == null ||
            previous.itemIndex != location.itemIndex ||
            (previous.progress * 100).round() !=
                (location.progress * 100).round())) {
      setState(() {});
    }
  }

  /// Enqueue synchronously, before the route's returned Future is completed.
  /// The store serializes reads/writes; every operation owns an immutable book /
  /// volume snapshot, so slow saves never acquire a newer volume's metadata.
  Future<void> _flush() {
    _saveTimer?.cancel();
    final current = _viewportKey.currentState?.currentLocation;
    if (current != null) {
      _recordLocation(current, rebuild: false, debounce: false);
    }
    final progress = _pendingProgress;
    if (progress == null) return _lastWrite;
    _pendingProgress = null;
    final request = _request;
    _lastWrite = _store.saveProgress(progress).catchError((
      Object error,
      StackTrace stack,
    ) {
      _warn(error, stack, 'progress.save');
      // Retry on the next lifecycle/navigation flush, but never resurrect a
      // failed old-volume write after the reader has already moved elsewhere.
      if (!_disposed && request == _request && _pendingProgress == null) {
        _pendingProgress = progress;
      }
    });
    return _lastWrite;
  }

  void _jumpTo(NovelReaderAnchor anchor) {
    final document = _document;
    if (document == null || document.itemCount == 0) return;
    unawaited(_flush());
    setState(() {
      _target = document.anchorFor(
        document.itemFor(anchor),
        alignment: anchor.alignment,
      );
      ++_jumpRevision;
      _sliderValue = null;
    });
  }

  String? _adjacentVolume(int direction) {
    final volume = _content?.detail.volume;
    final linked = direction < 0 ? volume?.prev : volume?.next;
    if (linked != null && linked.isNotEmpty && linked != _volumeId) {
      return linked;
    }
    final index = _volumes.indexWhere((volume) => volume.id == _volumeId);
    final next = index + direction;
    return index >= 0 && next >= 0 && next < _volumes.length
        ? _volumes[next].id
        : null;
  }

  int get _entrySlot =>
      _document?.entries.indexWhere(
        (entry) =>
            entry.entryIndex ==
            (_location?.anchor.entryIndex ?? _target.entryIndex),
      ) ??
      -1;

  bool _canStep(int direction) {
    final entries = _document?.entries ?? [];
    final next = _entrySlot + direction;
    return !_loading &&
        ((next >= 0 && next < entries.length) ||
            _adjacentVolume(direction) != null);
  }

  void _step(int direction) {
    final entries = _document?.entries ?? [];
    final next = _entrySlot + direction;
    if (next >= 0 && next < entries.length) {
      _jumpTo(NovelReaderAnchor(entryIndex: entries[next].entryIndex));
    } else {
      final volume = _adjacentVolume(direction);
      if (volume != null) {
        unawaited(
          _loadVolume(
            volume,
            anchor: const NovelReaderAnchor(entryIndex: 0),
            lastEntry: direction < 0,
          ),
        );
      }
    }
  }

  Future<void> _showContents() async {
    final session = _session;
    final selection = await showAppSheet<(String, int)>(
      context,
      heightFactor: 0.85,
      child: NovelReaderContentsSheet(
        repository: _repository,
        source: _source,
        pathWord: _pathWord,
        volumeId: _volumeId,
        entryIndex: _location?.anchor.entryIndex ?? _target.entryIndex,
        detail: _accessDetail,
      ),
    );
    if (!_active(session) || selection == null) return;
    final (volume, entry) = selection;
    if (volume == _volumeId && _document != null) {
      _jumpTo(NovelReaderAnchor(entryIndex: entry));
    } else {
      await _loadVolume(volume, anchor: NovelReaderAnchor(entryIndex: entry));
    }
  }

  void _changeSettings(NovelReaderSettings settings) {
    if (!mounted || _disposed) return;
    unawaited(_flush());
    setState(() => _settings = settings);
    _setScreenOn(settings.keepScreenOn);
    unawaited(
      settings.save().catchError((Object error, StackTrace stack) {
        _warn(error, stack, 'settings.save');
      }),
    );
  }

  Future<void> _showSettings() => showAppSheet<void>(
    context,
    maxHeightFactor: 0.7,
    child: NovelReaderSettingsSheet(
      settings: _settings,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
      onChanged: _changeSettings,
    ),
  );

  void _setScreenOn(bool enabled) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final shouldEnable =
        enabled &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
    Future<void> toggle() async {
      try {
        await WakelockPlus.toggle(enable: shouldEnable);
      } catch (error, stack) {
        // Desktop/tests may not provide this plugin. Reading must still work.
        _warn(error, stack, 'screen_on');
      }
    }

    final operation = _wakeQueue?.then((_) => toggle()) ?? toggle();
    late final Future<void> tail;
    tail = operation.whenComplete(() {
      if (identical(_wakeQueue, tail)) _wakeQueue = null;
    });
    _wakeQueue = tail;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_flush());
      _setScreenOn(false);
    } else if (state == AppLifecycleState.resumed) {
      _setScreenOn(_settings.keepScreenOn);
    }
  }

  Future<void> _back() async {
    await _flush();
    if (mounted) await Navigator.of(context).maybePop();
  }

  Future<void> _login() async {
    final session = _session;
    final request = _request;
    await context.pushNamed(
      AppRoutes.login,
      queryParameters: {'copyOnly': 'true'},
    );
    if (_active(session) && request == _request) {
      await _loadVolume(_volumeId, anchor: _target, refresh: true);
    }
  }

  void _warn(Object error, StackTrace stack, String action) {
    unawaited(
      AppLogger.instance.recordWarning(
        error,
        stackTrace: stack,
        source: 'novel_reader.$action',
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_flush());
    _disposed = true;
    ++_session;
    ++_request;
    _saveTimer?.cancel();
    _bookmarks.removeListener(_onBookmarksChanged);
    _statusSettings.removeListener(_onStatusSettingsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _setScreenOn(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 阅读纸张固定跟随系统亮暗选择配色方案，不受 App 强制主题影响。
    final palette = NovelReaderPalette.resolve(
      _settings,
      MediaQuery.platformBrightnessOf(context),
    );
    final document = _document;
    final reading =
        !_loading &&
        _error == null &&
        document != null &&
        document.itemCount > 0;
    final header = _buildHeader();
    final body = _buildBody();
    final toolbar = _buildToolbar();
    return Theme(
      data: palette.applyTo(Theme.of(context)),
      child: PopScope(
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) unawaited(_flush());
        },
        child: Scaffold(
          backgroundColor: palette.background,
          body: SafeArea(
            // Toolbars only cover the reading surface. In particular, toggling
            // them must not resize the viewport and trigger anchor restoration.
            // Keep system bars / SafeArea independent of toolbar visibility too.
            child: reading
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      body,
                      if (_statusSettings.statusOverlay) _buildStatusOverlay(),
                      if (_toolbarVisible) ...[
                        Positioned(top: 0, left: 0, right: 0, child: header),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: toolbar,
                        ),
                      ],
                    ],
                  )
                // Loading / retry actions remain outside the chrome so they
                // are reachable even in a short viewport with large text.
                : Column(
                    children: [
                      if (_toolbarVisible) header,
                      Expanded(child: body),
                      if (_toolbarVisible) toolbar,
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  /// 状态组件：与漫画阅读器同一套摆放规则（六位 + 中间对齐），
  /// 工具栏隐藏时显示；点按唤出工具栏。
  Widget _buildStatusOverlay() {
    // 0左上 1顶中 2右上 3右下 4底中 5左下
    final position = _statusSettings.statusOverlayPosition;
    final isTop = position < 3;
    final isLeft = {0: true, 5: true}[position] ?? false;
    final isCenter = position == 1 || position == 4;
    return Positioned(
      top: isTop ? 0 : null,
      bottom: isTop ? null : 0,
      left: isCenter || isLeft ? 0 : null,
      right: isCenter || !isLeft ? 0 : null,
      child: Visibility(
        visible: !_toolbarVisible,
        maintainState: true,
        child: TickerMode(
          enabled: !_toolbarVisible,
          child: Semantics(
            button: true,
            label: AppLocalizations.of(context)!.novelReaderShowToolbar,
            child: InkWell(
              key: const ValueKey('novel-reader-show-toolbar'),
              onTap: () => setState(() => _toolbarVisible = true),
              child: isCenter
                  ? Align(
                      alignment: isTop
                          ? Alignment.topCenter
                          : Alignment.bottomCenter,
                      child: _statusOverlayChild(),
                    )
                  : _statusOverlayChild(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusOverlayChild() => ReaderStatusOverlay(
    progressLabel: _progressLabel(_location?.progress ?? 0),
  );

  Widget _buildHeader() {
    final l10n = AppLocalizations.of(context)!;
    final bookName = _content?.detail.book.name ?? _fallbackName;
    final isBookmarked = _bookmarksLoaded && _isBookmarked;
    return ColoredBox(
      color: ReaderChrome.surface,
      child: SizedBox(
        height: kToolbarHeight,
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('novel-reader-back'),
              tooltip: l10n.novelReaderBack,
              color: ReaderChrome.onSurface,
              onPressed: _back,
              icon: const Icon(Icons.arrow_back),
            ),
            Expanded(
              child: Text(
                bookName.isEmpty ? l10n.novelReaderTitle : bookName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: ReaderChrome.onSurface,
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('novel-reader-bookmark'),
              tooltip: isBookmarked ? l10n.bookmarkRemove : l10n.bookmarkAdd,
              // 与漫画阅读器一致，书签高亮不随正文配色改变。
              color: isBookmarked ? Colors.amberAccent : ReaderChrome.onSurface,
              onPressed: _loading || _bookmarking || _location == null
                  ? null
                  : _toggleBookmark,
              icon: Icon(isBookmarked ? Icons.bookmark : Icons.bookmark_border),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final l10n = AppLocalizations.of(context)!;
    final document = _document;
    final request = _request;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _buildError();
    if (document == null || document.itemCount == 0) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: ErrorRetryView(
            icon: Icons.menu_book_outlined,
            message: l10n.novelReaderEmptyVolume,
            onRetry: () => unawaited(
              _loadVolume(_volumeId, anchor: _target, refresh: true),
            ),
          ),
        ),
      );
    }
    return NovelReaderViewport(
      key: _viewportKey,
      document: document,
      settings: _settings,
      palette: NovelReaderPalette.resolve(
        _settings,
        MediaQuery.platformBrightnessOf(context),
      ),
      target: _target,
      jumpRevision: _jumpRevision,
      onPosition: (location) {
        if (_request == request && identical(_document, document)) {
          _recordLocation(location);
        }
      },
      onTap: () => setState(() => _toolbarVisible = !_toolbarVisible),
      onScroll: () {
        if (_toolbarVisible) setState(() => _toolbarVisible = false);
      },
    );
  }

  String _progressLabel(double progress) {
    final percent = progress * 100;
    // 四舍五入到两位小数，但未到结尾不得显示成 100%。
    final capped = progress >= 1
        ? 100.0
        : percent > 99.99
        ? 99.99
        : percent;
    return '${capped.toStringAsFixed(2)}%';
  }

  String _chapterName(AppLocalizations l10n) {
    final slot = _entrySlot;
    final entries = _document?.entries ?? [];
    if (slot < 0 || slot >= entries.length) {
      return _accessDetail?.volume.name ?? l10n.novelReaderTitle;
    }
    return entries[slot].name.isEmpty
        ? l10n.novelReaderUnnamedChapter(slot + 1)
        : entries[slot].name;
  }

  Widget _buildToolbar() {
    final l10n = AppLocalizations.of(context)!;
    final document = _document;
    final count = document?.itemCount ?? 0;
    final current =
        _location?.itemIndex ?? (count > 0 ? document!.itemFor(_target) : 0);
    final value = _sliderValue ?? current.toDouble();
    final progress = _sliderValue != null
        ? (count > 1 ? value.round() / (count - 1) : 0.0)
        : (_location?.progress ?? (count > 1 ? current / (count - 1) : 0.0));
    final progressLabel = _progressLabel(progress);
    return ColoredBox(
      color: ReaderChrome.surface,
      child: IconTheme(
        data: const IconThemeData(color: ReaderChrome.onSurface),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Row(
                  children: [
                    if (_offline)
                      const Padding(
                        padding: EdgeInsets.only(right: AppSpacing.xs),
                        child: Icon(Icons.offline_pin_outlined, size: 16),
                      ),
                    Expanded(
                      child: Text(
                        _chapterName(l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: ReaderChrome.onSurfaceMuted,
                        ),
                      ),
                    ),
                    Text(
                      progressLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: ReaderChrome.onSurfaceMuted,
                      ),
                    ),
                  ],
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  activeTrackColor: ReaderChrome.onSurface,
                  inactiveTrackColor: ReaderChrome.trackInactive,
                  thumbColor: ReaderChrome.onSurface,
                ),
                child: Slider(
                  key: const ValueKey('novel-reader-progress'),
                  value: value.clamp(0, count > 1 ? count - 1.0 : 1.0),
                  max: count > 1 ? count - 1.0 : 1,
                  label: progressLabel,
                  onChanged: count > 1 && !_loading
                      ? (value) => setState(() => _sliderValue = value)
                      : null,
                  onChangeEnd: count > 1 && !_loading
                      ? (value) => _jumpTo(document!.anchorFor(value.round()))
                      : null,
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    key: const ValueKey('novel-reader-previous'),
                    tooltip: l10n.novelReaderPrevious,
                    onPressed: _canStep(-1) ? () => _step(-1) : null,
                    // 与漫画阅读器底栏一致：颜色显式指定，禁用态仍可见。
                    icon: Icon(
                      Icons.skip_previous,
                      color: _canStep(-1)
                          ? ReaderChrome.onSurface
                          : ReaderChrome.onSurfaceFaint,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('novel-reader-contents'),
                    tooltip: l10n.novelReaderContents,
                    onPressed: _showContents,
                    icon: const Icon(Icons.format_list_bulleted),
                  ),
                  IconButton(
                    key: const ValueKey('novel-reader-settings'),
                    tooltip: l10n.novelReaderSettings,
                    onPressed: _loading ? null : _showSettings,
                    icon: const Icon(Icons.text_fields),
                  ),
                  IconButton(
                    key: const ValueKey('novel-reader-next'),
                    tooltip: l10n.novelReaderNext,
                    onPressed: _canStep(1) ? () => _step(1) : null,
                    icon: Icon(
                      Icons.skip_next,
                      color: _canStep(1)
                          ? ReaderChrome.onSurface
                          : ReaderChrome.onSurfaceFaint,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    final l10n = AppLocalizations.of(context)!;
    final error = _error;
    final locked = _accessDetail?.isLocked ?? false;
    final unauthorized = error is NovelApiException && error.isUnauthorized;
    final canLogin =
        unauthorized ||
        (error is NovelAccessException &&
            (!error.detail.isLoggedIn || !_api.hasCopyToken));
    final message = error is NovelDownloadUnavailableException
        ? l10n.novelDownloadUnavailable
        : locked
        ? l10n.novelReaderLocked
        : error is _NoCachedVolume
        ? l10n.novelReaderNoCache
        : error is NovelAccessException
        ? l10n.novelReaderEmptyVolume
        : unauthorized
        ? l10n.novelReaderLoginRequired
        : l10n.novelReaderLoadFailed;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ErrorRetryView(
            icon: locked ? Icons.lock_outline : Icons.cloud_off_outlined,
            message: message,
            onRetry: () => unawaited(
              _loadVolume(_volumeId, anchor: _target, refresh: true),
            ),
          ),
          if (canLogin)
            TextButton.icon(
              key: const ValueKey('novel-reader-login'),
              onPressed: _login,
              icon: const Icon(Icons.login),
              label: Text(l10n.novelReaderCopyLogin),
            ),
          if (_source.localOnly || widget.localOnly)
            TextButton.icon(
              key: const ValueKey('novel-reader-open-downloads'),
              onPressed: () async {
                final session = _session;
                await context.pushNamed(
                  AppRoutes.downloadCenter,
                  queryParameters: {'tab': '2'},
                );
                if (_active(session)) {
                  await _loadVolume(_volumeId, anchor: _target);
                }
              },
              icon: const Icon(Icons.download_outlined),
              label: Text(l10n.downloadCenterTitle),
            )
          else
            TextButton.icon(
              key: const ValueKey('novel-reader-open-cache'),
              onPressed: () => unawaited(
                _loadVolume(_volumeId, anchor: _target, cachedOnly: true),
              ),
              icon: const Icon(Icons.offline_pin_outlined),
              label: Text(l10n.novelReaderOpenCache),
            ),
        ],
      ),
    );
  }
}

class _NoCachedVolume {
  const _NoCachedVolume();
}

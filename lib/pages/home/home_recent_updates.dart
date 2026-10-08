part of '../home_page.dart';

class _RecentUpdatesSection extends StatefulWidget {
  const _RecentUpdatesSection({
    super.key,
    required this.isCopy,
    required this.revision,
    required this.onTap,
  });
  final bool isCopy;
  final int revision;
  final void Function(Comic, String) onTap;

  @override
  State<_RecentUpdatesSection> createState() => _RecentUpdatesSectionState();
}

class _RecentUpdatesSectionState extends State<_RecentUpdatesSection> {
  final _settings = RecentUpdatesSettings();
  List<Comic> _comics = [];
  bool _loading = true;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _settings.load();
      if (!mounted) return;
      await _reload();
    } catch (error, stack) {
      await AppLogger.instance.recordWarning(
        error,
        stackTrace: stack,
        source: 'home.recent_settings',
      );
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  @override
  void didUpdateWidget(_RecentUpdatesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      unawaited(_reload(refresh: true));
    }
  }

  @override
  void dispose() {
    _generation++;
    _settings.dispose();
    super.dispose();
  }

  Future<void> _reload({bool refresh = false}) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
      if (!refresh) _comics = [];
    });
    try {
      final repository = RecentUpdatesRepository(
        isCopy: widget.isCopy,
        regions: _settings.regions,
        onProgress: (comics) {
          if (!mounted || generation != _generation) return;
          setState(() => _comics = comics.take(12).toList());
        },
      );
      final cached = await repository.loadPreviewFromCache();
      if (!mounted || generation != _generation) return;
      if (cached != null) {
        setState(() => _comics = cached.comics.take(12).toList());
      }
      if (refresh) await repository.invalidateCache();
      final data = await repository.load();
      if (!mounted || generation != _generation) return;
      setState(() {
        _comics = data.comics.take(12).toList();
        _loading = false;
      });
    } catch (error, stack) {
      await AppLogger.instance.recordWarning(
        error,
        stackTrace: stack,
        source: 'home.recent_updates',
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _select(Set<int> value) async {
    try {
      await _settings.setRegions(value);
      if (!mounted) return;
      await _reload();
    } catch (error, stack) {
      await AppLogger.instance.recordWarning(
        error,
        stackTrace: stack,
        source: 'home.recent_filter',
      );
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Future<void> openMore() async {
      await context.pushNamed(
        AppRoutes.recentUpdates,
        queryParameters: {'source': widget.isCopy ? 'copy' : 'hot'},
      );
      if (!mounted) return;
      await _settings.load();
      if (mounted) await _reload();
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RecentRegionFilter(
          regions: _settings.regions,
          onChanged: _select,
          enabled: !_loading,
        ),
        if (_loading && _comics.isNotEmpty)
          const LinearProgressIndicator(minHeight: 2),
        const SizedBox(height: AppSpacing.sm),
        if (_loading && _comics.isEmpty)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Center(child: ExpressiveLoadingIndicator()),
          )
        else if (_comics.isNotEmpty)
          widget.isCopy
              ? _CopyTwoRowComicGrid(
                  items: _comics,
                  onTap: widget.onTap,
                  scope: 'copy-recent',
                )
              : _MangaHorizontalList(
                  showUpdateTime: true,
                  items: _comics,
                  onTap: widget.onTap,
                  scope: 'hot-recent',
                ),
        if (_failed)
          ErrorRetryView(onRetry: () => _reload(refresh: true))
        else if (!_loading && _comics.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Text(l10n.homeRecentEmpty),
          ),
      ],
    );
    if (widget.isCopy) {
      return _CopyCollapsibleSection(
        storageKey: 'copy-recent',
        title: l10n.homeRecentUpdates,
        icon: Icons.update,
        hp: 16,
        topPadding: 8,
        onMore: openMore,
        child: content,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SectionHeader(
            title: l10n.homeRecentUpdates,
            icon: Icons.update,
            onMore: openMore,
          ),
        ),
        content,
        const SizedBox(height: 12),
      ],
    );
  }
}

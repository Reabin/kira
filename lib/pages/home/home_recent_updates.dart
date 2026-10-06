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
      _comics = [];
    });
    try {
      final repository = RecentUpdatesRepository(
        isCopy: widget.isCopy,
        japaneseOnly: _settings.japaneseOnly,
      );
      if (refresh) await repository.invalidateCache();
      final data = await repository.load();
      if (!mounted || generation != _generation) return;
      setState(() {
        _comics = data.comics;
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

  Future<void> _select(bool value) async {
    try {
      await _settings.setJapaneseOnly(value);
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: SectionHeader(
              title: l10n.homeRecentUpdates,
              icon: Icons.update,
              trailing: IconButton(
                tooltip: l10n.retryButton,
                onPressed: _loading ? null : () => _reload(refresh: true),
                icon: const Icon(Icons.refresh),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: true,
                  label: Text(l10n.homeRecentJapaneseOnly),
                ),
                ButtonSegment(value: false, label: Text(l10n.homeRecentAll)),
              ],
              selected: {_settings.japaneseOnly},
              onSelectionChanged: _loading
                  ? null
                  : (values) => _select(values.first),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_settings.japaneseOnly)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Text(
                l10n.homeRecentJapaneseHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Center(child: ExpressiveLoadingIndicator()),
            )
          else if (_failed)
            ErrorRetryView(onRetry: () => _reload(refresh: true))
          else if (_comics.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text(l10n.homeRecentEmpty),
            )
          else
            _MangaHorizontalList(
              showUpdateTime: true,
              items: _comics,
              onTap: widget.onTap,
              scope: 'home-recent-${widget.isCopy}',
            ),
        ],
      ),
    );
  }
}

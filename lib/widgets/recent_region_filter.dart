import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/recent_updates_settings.dart';

class RecentRegionFilter extends StatelessWidget {
  const RecentRegionFilter({
    super.key,
    required this.regions,
    required this.onChanged,
    this.enabled = true,
  });
  final Set<int> regions;
  final ValueChanged<Set<int>> onChanged;
  final bool enabled;

  static String label(AppLocalizations l10n, int region) => switch (region) {
    0 => l10n.homeRecentJapan,
    1 => l10n.homeRecentKorea,
    _ => l10n.homeRecentWestern,
  };

  Future<void> _configure(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final selected = {...regions};
    final result = await showDialog<Set<int>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l10n.homeRecentRegions),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final region in RecentUpdatesSettings.allRegions)
                CheckboxListTile(
                  title: Text(label(l10n, region)),
                  value: selected.contains(region),
                  onChanged: (checked) => update(() {
                    if (checked == true) {
                      selected.add(region);
                    } else {
                      selected.remove(region);
                    }
                  }),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.cancelButton),
            ),
            TextButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, selected),
              child: Text(l10n.confirmButton),
            ),
          ],
        ),
      ),
    );
    if (result != null) onChanged(Set.unmodifiable(result));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sorted = regions.toList()..sort();
    return TextButton.icon(
      onPressed: enabled ? () => _configure(context) : null,
      icon: const Icon(Icons.tune),
      label: Text(
        '${l10n.homeRecentRegions}: ${sorted.map((r) => label(l10n, r)).join('、')}',
      ),
    );
  }
}

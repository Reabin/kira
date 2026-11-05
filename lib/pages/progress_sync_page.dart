import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/app_localizations.dart';
import '../providers/backup_providers.dart';
import '../routing/app_router.dart';
import '../sync/progress_document.dart';
import '../sync/progress_sync_service.dart';
import '../sync/progress_sync_settings.dart';
import '../sync/progress_transport.dart';
import '../theme/app_spacing.dart';
import '../widgets/setting_tile_group.dart';
import 'backup/backup_labels.dart';

class ProgressSyncPage extends ConsumerStatefulWidget {
  const ProgressSyncPage({super.key});
  @override
  ConsumerState<ProgressSyncPage> createState() => _ProgressSyncPageState();
}

class _ProgressSyncPageState extends ConsumerState<ProgressSyncPage> {
  late final ProgressSyncService _service;
  bool _loading = true;
  bool _folder = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _service = ref.read(progressSyncServiceProvider)..addListener(_changed);
    unawaited(
      _perform(() async {
        await _service.settings.load();
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          _folder = (await ICloudProgressFolder.status())['configured'] == true;
        }
      }),
    );
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _perform(Future<void> Function() action) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      _error = error;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save({bool? enabled, ProgressSyncBackend? backend}) =>
      _perform(() async {
        await _service.settings.save(
          enabled: enabled ?? _service.settings.enabled,
          backend: backend ?? _service.settings.backend,
        );
        if (_service.settings.enabled) await _service.sync();
      });

  String _message(Object error, AppLocalizations l10n) =>
      error is PlatformException
      ? error.message ?? error.code
      : backupErrorMessage(error, l10n);

  String _position(ProgressEntry entry, AppLocalizations l10n) {
    final data = entry.data;
    if (data.containsKey('volumeId')) {
      return l10n.progressSyncNovelPosition(
        '${data['volumeName'] ?? ''} · ${data['chapterName'] ?? ''}',
        (data['paragraphIndex'] is int ? data['paragraphIndex'] + 1 : 1)
            .toString(),
      );
    }
    return l10n.progressSyncComicPosition(
      '${data['chapterName'] ?? ''}',
      '${data['page']}',
    );
  }

  @override
  void dispose() {
    _service.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = _service.settings;
    final busy = _loading || _service.busy;
    final last = _service.lastExchange;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.progressSyncTitle)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              SettingTileGroup(
                children: [
                  SwitchListTile(
                    title: Text(l10n.progressSyncAutomatic),
                    subtitle: Text(l10n.progressSyncAutomaticHint),
                    value: settings.enabled,
                    onChanged: busy ? null : (value) => _save(enabled: value),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: SegmentedButton<ProgressSyncBackend>(
                      segments: [
                        if (defaultTargetPlatform == TargetPlatform.iOS)
                          ButtonSegment(
                            value: ProgressSyncBackend.iCloud,
                            label: Text(l10n.progressSyncICloud),
                            icon: const Icon(Icons.cloud_outlined),
                          ),
                        ButtonSegment(
                          value: ProgressSyncBackend.webDav,
                          label: Text(l10n.backupWebDav),
                          icon: const Icon(Icons.dns_outlined),
                        ),
                      ],
                      selected: {settings.backend},
                      onSelectionChanged: busy
                          ? null
                          : (selection) => _save(backend: selection.single),
                    ),
                  ),
                  if (settings.backend == ProgressSyncBackend.iCloud)
                    ListTile(
                      title: Text(l10n.progressSyncChooseFolder),
                      subtitle: Text(
                        _folder
                            ? l10n.progressSyncFolderReady
                            : l10n.progressSyncFolderRequired,
                      ),
                      trailing: const Icon(Icons.folder_open_outlined),
                      onTap: busy
                          ? null
                          : () => _perform(() async {
                              if (await ICloudProgressFolder.choose()) {
                                _folder = true;
                                if (settings.enabled) await _service.sync();
                              }
                            }),
                    )
                  else
                    ListTile(
                      title: Text(l10n.progressSyncWebDavSettings),
                      subtitle: Text(l10n.progressSyncWebDavHint),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: busy
                          ? null
                          : () async {
                              await context.pushNamed(AppRoutes.backup);
                              if (mounted && settings.enabled) {
                                await _service.sync();
                              }
                            },
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                settings.backend == ProgressSyncBackend.iCloud
                    ? l10n.progressSyncICloudHint
                    : l10n.progressSyncBackupHint,
              ),
              const SizedBox(height: AppSpacing.lg),
              if (_service.busy || _loading) const LinearProgressIndicator(),
              if (last != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                  child: Text(
                    l10n.progressSyncLastExchange(
                      MaterialLocalizations.of(
                        context,
                      ).formatTimeOfDay(TimeOfDay.fromDateTime(last)),
                    ),
                  ),
                ),
              if (_error != null || _service.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                  child: SelectableText(
                    _message(_error ?? _service.error!, l10n),
                  ),
                ),
              FilledButton.icon(
                onPressed: busy || !settings.enabled
                    ? null
                    : () => _perform(_service.sync),
                icon: const Icon(Icons.sync),
                label: Text(l10n.progressSyncNow),
              ),
              if (_service.conflicts.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xxl),
                Text(
                  l10n.progressSyncConflicts,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(l10n.progressSyncConflictHint),
                for (final conflict in _service.conflicts)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            conflict.choices.first.name,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          for (final entry in {
                            for (final e in conflict.choices) e.position: e,
                          }.values)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(_position(entry, l10n)),
                              subtitle: Text(
                                entry.position ==
                                        _service.localPositions[conflict.key]
                                    ? l10n.progressSyncThisDevice
                                    : l10n.progressSyncOtherDevice,
                              ),
                              trailing: TextButton(
                                onPressed: busy
                                    ? null
                                    : () => _perform(
                                        () => _service.resolve(conflict, entry),
                                      ),
                                child: Text(l10n.progressSyncUsePosition),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

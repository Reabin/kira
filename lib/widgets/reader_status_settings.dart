import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/reader_settings.dart';
import '../theme/app_icon_sizes.dart';
import '../theme/app_spacing.dart';
import '../utils/adaptive_motion.dart';
import 'collapsible_content.dart';

/// 漫画与轻小说阅读器共享的状态组件设置区：开关、六位摆放、不透明度
/// 与段位顺序。直接读写全局 [ReaderSettings]，修改即持久化并通过
/// store 通知所有监听者；宿主只需在 [onChanged] 里刷新自己的其余 UI。
class ReaderStatusSettingsSection extends StatefulWidget {
  const ReaderStatusSettingsSection({super.key, required this.onChanged});

  /// 任意设置变化后的回调。
  final VoidCallback onChanged;

  @override
  State<ReaderStatusSettingsSection> createState() =>
      _ReaderStatusSettingsSectionState();
}

class _ReaderStatusSettingsSectionState
    extends State<ReaderStatusSettingsSection> {
  final _reader = ReaderSettings();
  bool _expanded = false;

  void _changed() {
    if (mounted) setState(() {});
    widget.onChanged();
  }

  /// 当前状态显示段位顺序（由持久化配置决定）。
  List<String> get _segments => _reader.statusOverlayOrder;

  /// 拖动调整状态显示段位的显示顺序。
  void _onSegmentReorder(int oldIndex, int newIndex) {
    setState(() {
      final order = [..._reader.statusOverlayOrder];
      final item = order.removeAt(oldIndex);
      order.insert(newIndex, item);
      _reader.setStatusOverlayOrder(order);
    });
    widget.onChanged();
  }

  Widget _buildSegmentRow(AppLocalizations l10n, String id, int index) {
    final (title, value, onChanged) = switch (id) {
      'time' => (
        l10n.readerStatusTime,
        _reader.statusOverlayTime,
        _reader.setStatusOverlayTime,
      ),
      'network' => (
        l10n.readerStatusNetwork,
        _reader.statusOverlayNetwork,
        _reader.setStatusOverlayNetwork,
      ),
      'battery' => (
        l10n.readerStatusBattery,
        _reader.statusOverlayBattery,
        _reader.setStatusOverlayBattery,
      ),
      'page' => (
        l10n.readerStatusPage,
        _reader.statusOverlayPage,
        _reader.setStatusOverlayPage,
      ),
      'fps' => (
        l10n.readerStatusFps,
        _reader.statusOverlayFps,
        _reader.setStatusOverlayFps,
      ),
      _ => (l10n.readerStatusTime, false, _reader.setStatusOverlayTime),
    };
    return Row(
      key: ValueKey(id),
      children: [
        ReorderableDragStartListener(
          index: index,
          child: const SizedBox.square(
            dimension: 48,
            child: Icon(Icons.drag_handle, size: AppIconSize.md),
          ),
        ),
        Expanded(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(title),
            value: value,
            onChanged: (v) {
              onChanged(v);
              setState(() {});
              widget.onChanged();
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: SwitchListTile(
                key: const ValueKey('reader-status-overlay-switch'),
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.readerStatusOverlay),
                value: _reader.statusOverlay,
                onChanged: (v) {
                  _reader.setStatusOverlay(v);
                  if (!v) _expanded = false;
                  _changed();
                },
              ),
            ),
            if (_reader.statusOverlay)
              Semantics(
                expanded: _expanded,
                child: IconButton(
                  key: const ValueKey('reader-status-details-toggle'),
                  tooltip: _expanded
                      ? l10n.chapterCommentsCollapse
                      : l10n.chapterCommentsExpand,
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: AnimatedRotation(
                    key: ValueKey(prefersReducedMotion(context)),
                    turns: _expanded ? 0.5 : 0,
                    duration: adaptiveDuration(
                      context,
                      const Duration(milliseconds: 180),
                    ),
                    child: const Icon(Icons.expand_more, size: AppIconSize.xl),
                  ),
                ),
              ),
          ],
        ),
        if (_reader.statusOverlay)
          CollapsibleContent(
            expanded: _expanded,
            child: _buildDetails(context, l10n),
          ),
      ],
    );
  }

  Widget _buildDetails(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final metaStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final positionLabels = [
      l10n.readerStatusOverlayTopLeft,
      l10n.readerStatusOverlayTopCenter,
      l10n.readerStatusOverlayTopRight,
      l10n.readerStatusOverlayBottomRight,
      l10n.readerStatusOverlayBottomCenter,
      l10n.readerStatusOverlayBottomLeft,
    ];
    const positionIcons = [
      Icons.north_west,
      Icons.north,
      Icons.north_east,
      Icons.south_east,
      Icons.south,
      Icons.south_west,
    ];
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(l10n.readerStatusOverlayPosition)),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  positionLabels[_reader.statusOverlayPosition],
                  style: metaStyle,
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),
          LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: constraints.maxWidth.clamp(288, double.infinity),
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: [
                    for (var i = 0; i < positionIcons.length; i++)
                      ButtonSegment(
                        value: i,
                        icon: Icon(positionIcons[i]),
                        tooltip: positionLabels[i],
                      ),
                  ],
                  selected: {_reader.statusOverlayPosition},
                  onSelectionChanged: (v) {
                    _reader.setStatusOverlayPosition(v.first);
                    _changed();
                  },
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(child: Text(l10n.readerStatusOverlayOpacity)),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${(_reader.statusOverlayOpacity * 100).round()}%',
                style: metaStyle,
              ),
            ],
          ),
          Slider(
            value: _reader.statusOverlayOpacity,
            divisions: 10,
            label: '${(_reader.statusOverlayOpacity * 100).round()}%',
            onChanged: (v) {
              _reader.setStatusOverlayOpacity(v);
              setState(() {});
              widget.onChanged();
            },
          ),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            // 新回调给出删除旧条目后的最终索引，可直接插入（含末尾）。
            onReorderItem: _onSegmentReorder,
            children: [
              for (var i = 0; i < _segments.length; i++)
                _buildSegmentRow(l10n, _segments[i], i),
            ],
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/reader_settings.dart';
import '../theme/app_spacing.dart';

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
    return Padding(
      key: ValueKey(id),
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Icon(Icons.drag_handle, size: 18),
            ),
          ),
          Expanded(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const ValueKey('reader-status-overlay-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.readerStatusOverlay),
          value: _reader.statusOverlay,
          onChanged: (v) {
            _reader.setStatusOverlay(v);
            _changed();
          },
        ),
        if (_reader.statusOverlay) ...[
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.lg),
            child: Row(
              children: [
                Text(l10n.readerStatusOverlayPosition),
                const Spacer(),
                Text(switch (_reader.statusOverlayPosition) {
                  0 => l10n.readerStatusOverlayTopLeft,
                  1 => l10n.readerStatusOverlayTopCenter,
                  2 => l10n.readerStatusOverlayTopRight,
                  3 => l10n.readerStatusOverlayBottomRight,
                  4 => l10n.readerStatusOverlayBottomCenter,
                  5 => l10n.readerStatusOverlayBottomLeft,
                  _ => l10n.readerStatusOverlayTopRight,
                }, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.lg),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 0, icon: Icon(Icons.north_west)),
                  ButtonSegment(value: 1, icon: Icon(Icons.north)),
                  ButtonSegment(value: 2, icon: Icon(Icons.north_east)),
                  ButtonSegment(value: 3, icon: Icon(Icons.south_east)),
                  ButtonSegment(value: 4, icon: Icon(Icons.south)),
                  ButtonSegment(value: 5, icon: Icon(Icons.south_west)),
                ],
                selected: {_reader.statusOverlayPosition},
                onSelectionChanged: (v) {
                  _reader.setStatusOverlayPosition(v.first);
                  _changed();
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.lg),
            child: Row(
              children: [
                Text(l10n.readerStatusOverlayOpacity),
                const Spacer(),
                Text(
                  '${(_reader.statusOverlayOpacity * 100).round()}%',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.lg),
            child: Slider(
              value: _reader.statusOverlayOpacity,
              divisions: 10,
              label: '${(_reader.statusOverlayOpacity * 100).round()}%',
              onChanged: (v) {
                _reader.setStatusOverlayOpacity(v);
                setState(() {});
                widget.onChanged();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.lg),
            child: ReorderableListView(
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
          ),
        ],
      ],
    );
  }
}

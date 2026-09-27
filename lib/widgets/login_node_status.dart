import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_transport.dart' show routes;
import '../l10n/app_localizations.dart';
import '../models/user_manager.dart';
import '../theme/app_radius.dart';
import '../theme/app_shadows.dart';
import '../theme/app_spacing.dart';
import '../theme/app_status_colors.dart';

/// 一批登录节点的探测函数：返回 {host: 延迟毫秒}，超时为 null。
/// 探测遵循应用代理设置（见 NetworkApi.testHostsConnectivity）。
typedef LoginHostProbe =
    Future<Map<String, int?>> Function(
      List<String> hosts, {
      void Function(String host, int? latency)? onHostResult,
    });

/// 登录页顶部的登录节点状态卡。
///
/// 只显示当前所选登录来源对应的一个节点：热辣来源显示下一次请求将使用
/// 的线路节点（与实际登录请求同一选择逻辑，见 ApiTransport.previewNextHost），
/// 拷贝来源显示当前拷贝登录域名。进入页面即后台探测（切换来源时结果
/// 立即可用），让用户在登录前就能看出当前网络是否可达。
/// 延迟阈值与配色与网络诊断页保持一致（≤800 绿、≤2000 橙、其余红、超时红）。
class LoginNodeStatusCard extends StatefulWidget {
  const LoginNodeStatusCard({super.key, required this.useCopyLogin});

  /// 当前是否选中拷贝漫画登录；false 表示热辣漫画。
  final bool useCopyLogin;

  /// 测试注入的探测函数；null 时走 NetworkApi.testHostsConnectivity。
  /// widget 测试必须覆盖它，否则会发起真实网络请求。
  static LoginHostProbe? probeOverride;

  /// 测试注入的热辣节点选择函数；null 时走 NetworkApi.previewRouteHost。
  /// 离线 fake 测试必须覆盖它，否则会触碰真实 ApiClient。
  static String Function()? hotHostOverride;

  @override
  State<LoginNodeStatusCard> createState() => _LoginNodeStatusCardState();
}

class _LoginNodeStatusCardState extends State<LoginNodeStatusCard> {
  final _api = ApiClient();
  final _user = UserManager();

  /// host → 延迟毫秒；null 表示超时；不在 map 中表示检测中。
  final Map<String, int?> _results = {};
  bool _testing = false;

  /// 本次探测选中的热辣节点（探测时确定，展示与探测保持一致）。
  String? _hotHost;

  /// 选定本次探测的域名：两个来源都测，切换来源时无需重新等待。
  /// 热辣节点在探测时确定一次，展示与探测保持一致。
  List<String> _collectProbeHosts() {
    _hotHost =
        LoginNodeStatusCard.hotHostOverride?.call() ??
        _api.network.previewRouteHost();
    final hosts = <String>[_hotHost!];
    final copy = _user.copyLoginHost;
    if (copy.isNotEmpty && !hosts.contains(copy)) hosts.add(copy);
    return hosts;
  }

  /// 节点全局编号，与网络诊断页 `_nodeNumber` 一致；host 不在路由表中
  /// （异常配置）时返回 null，展示层回退为直接显示 host。
  int? _nodeNumberOf(String host) {
    var index = 0;
    for (final route in routes) {
      final local = route.indexOf(host);
      if (local >= 0) return index + local + 1;
      index += route.length;
    }
    return null;
  }

  /// 当前展示的行（标签, host）。
  (String, String) _displayRow(AppLocalizations l10n) {
    if (widget.useCopyLogin) {
      final copy = _user.copyLoginHost;
      if (copy.isNotEmpty) return (l10n.networkCopyLoginHost, copy);
    }
    final host = _hotHost ?? _api.network.previewRouteHost();
    final nodeNumber = _nodeNumberOf(host);
    return (
      nodeNumber != null ? l10n.networkNodeLabel(nodeNumber) : host,
      host,
    );
  }

  @override
  void initState() {
    super.initState();
    _testing = true;
    unawaited(_probe());
  }

  Future<void> _probe() async {
    final probe =
        LoginNodeStatusCard.probeOverride ?? _api.network.testHostsConnectivity;
    try {
      await probe(_collectProbeHosts(), onHostResult: _onHostResult);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _test() async {
    if (_testing) return;
    setState(() => _testing = true);
    await _probe();
  }

  void _onHostResult(String host, int? latency) {
    if (!mounted) return;
    setState(() => _results[host] = latency);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        // 与网络诊断页节点卡同款底色
        color: Color.alphaBlend(
          cs.surfaceContainerHighest.withValues(alpha: 0.35),
          cs.surface,
        ),
        borderRadius: AppRadius.mdR,
        // 与登录页其余卡片（已保存账号卡）同款阴影。
        boxShadow: AppShadows.md(cs),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Icon(Icons.lan_outlined, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: AppSpacing.xs),
            Expanded(child: _buildHostRow(_displayRow(l10n), l10n, cs)),
            // 探测中/空闲占同一 48x48 槽位，行高恒定，卡片不跳动。
            IconButton(
              tooltip: l10n.networkTestLatencyShort,
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHostRow(
    (String, String) row,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    final (label, host) = row;
    final tt = Theme.of(context).textTheme;
    final pending = !_results.containsKey(host);
    final latency = _results[host];
    final Color color;
    if (pending) {
      color = AppStatusColors.neutral(cs);
    } else if (latency == null) {
      color = AppStatusColors.danger(cs);
    } else if (latency <= 800) {
      color = AppStatusColors.success(cs);
    } else if (latency <= 2000) {
      color = AppStatusColors.warning(cs);
    } else {
      color = AppStatusColors.danger(cs);
    }

    final valueText = pending
        ? l10n.networkTesting
        : (latency == null ? l10n.networkTimeout : '$latency ms');

    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        Text(
          valueText,
          style: tt.bodyMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

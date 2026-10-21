import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_transport.dart' show routes;
import '../l10n/app_localizations.dart';
import '../models/user_manager.dart';
import '../pages/login_page.dart' show CopyLoginChannel;
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
/// 只显示当前所选登录通道实际会打的那个节点：热辣来源显示下一次请求将
/// 使用的线路节点（与实际登录请求同一选择逻辑，见
/// ApiTransport.previewNextHost）；拷贝来源按登录通道区分——网页通道打的是
/// `copyLoginHost`（官网），接口通道打的是 `copyApiHost`（COPY API 节点），
/// 两者是不同域名，探测与展示都必须跟着通道走，否则显示的是绿的、真正
/// 发请求的那个却超时。进入页面即后台探测（切换来源/通道时结果立即可用），
/// 让用户在登录前就能看出当前网络是否可达。
///
/// 延迟阈值与配色与网络诊断页保持一致（≤800 绿、≤2000 橙、其余红、超时红）。
///
/// 延迟较差时只有小字变红不够醒目，所以分级强调（不新增文案，仍用
/// 「超时」/「N ms」）：较差（>800ms）给数值加状态色胶囊底；严重（超时或
/// >2000ms）再加描边，并把行首圆点换成警示图标。
class LoginNodeStatusCard extends StatefulWidget {
  const LoginNodeStatusCard({
    super.key,
    required this.useCopyLogin,
    this.copyChannel = CopyLoginChannel.web,
  });

  /// 当前是否选中拷贝漫画登录；false 表示热辣漫画。
  final bool useCopyLogin;

  /// 拷贝登录通道：决定探测与展示哪个域名（官网 vs COPY API 节点）。
  final CopyLoginChannel copyChannel;

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

  /// host → 延迟毫秒；null 表示超时；不在 map 中表示尚未测过或正在测。
  final Map<String, int?> _results = {};

  /// 当前这一轮要覆盖的域名。探测期间据此判断是否已覆盖当前展示的域名，
  /// 以及结束后要不要补一轮（用户中途改了域名/通道时）。
  final Set<String> _inflight = {};

  /// 本次探测选中的热辣节点（探测时确定，展示与探测保持一致）。
  String? _hotHost;

  /// 当前拷贝通道实际会打的主机：网页通道是官网登录域名，接口通道是
  /// COPY API 节点。
  String get _copyHost => widget.copyChannel == CopyLoginChannel.app
      ? _user.copyApiHost
      : _user.copyLoginHost;

  /// 选定本次探测的域名：热辣节点与拷贝通道的域名都测，切换来源/通道时
  /// 无需重新等待。热辣节点在探测时确定一次，展示与探测保持一致。
  ///
  /// 用户改了拷贝域名（高级设置）时，新域名不在 `_results` 里，本轮一并补测。
  List<String> _collectProbeHosts() {
    _hotHost =
        LoginNodeStatusCard.hotHostOverride?.call() ??
        _api.network.previewRouteHost();
    final hosts = <String>[_hotHost!];
    for (final copy in [_copyHost, _user.copyLoginHost]) {
      if (copy.isNotEmpty && !hosts.contains(copy)) hosts.add(copy);
    }
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
      final copy = _copyHost;
      if (copy.isNotEmpty) {
        return (
          widget.copyChannel == CopyLoginChannel.app
              ? l10n.networkCopyApiHost
              : l10n.networkCopyLoginHost,
          copy,
        );
      }
    }
    final host = _hotHost ?? _api.network.previewRouteHost();
    final nodeNumber = _nodeNumberOf(host);
    return (
      nodeNumber != null ? l10n.networkNodeLabel(nodeNumber) : host,
      host,
    );
  }

  /// 当前展示的域名。切换登录通道会换成另一个域名，此时必须补测，否则
  /// 新域名永远停在没有结果的状态（显示「检测中」）。
  String get _displayHost => widget.useCopyLogin
      ? _copyHost
      : (_hotHost ?? _api.network.previewRouteHost());

  /// 本卡片是否有探测在跑（按钮转圈用）。
  bool get _testing => _inflight.isNotEmpty;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  @override
  void didUpdateWidget(LoginNodeStatusCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只在真正换了登录来源或拷贝通道时测；UserManager 的通知会让父级重建，
    // 但 widget 的这两个字段没变，不能因此反复发探测请求。
    final switched =
        oldWidget.useCopyLogin != widget.useCopyLogin ||
        oldWidget.copyChannel != widget.copyChannel;
    if (switched) unawaited(_probe());
  }

  /// 探测当前展示的域名。切换登录来源/通道后重测一次，让数值跟着刷新；
  /// 已有探测覆盖了当前域名时不重复发请求。
  Future<void> _probe() async {
    if (!mounted) return;
    // 先收集（顺带确定本轮的热辣节点），再判断当前展示的域名。
    final hosts = _collectProbeHosts();
    final host = _displayHost;
    if (host.isEmpty || _inflight.contains(host)) return;
    setState(() => _inflight.addAll(hosts));
    try {
      final probe =
          LoginNodeStatusCard.probeOverride ??
          _api.network.testHostsConnectivity;
      await probe(hosts, onHostResult: _onHostResult);
    } finally {
      if (mounted) setState(() => _inflight.removeAll(hosts));
    }
  }

  /// 手动刷新：丢掉当前域名的旧结果重测。
  Future<void> _retest() async {
    if (_testing) return;
    setState(() => _results.remove(_displayHost));
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
    final row = _displayRow(l10n);
    final tone = _toneFor(row.$2, cs);

    return Container(
      decoration: BoxDecoration(
        // 与网络诊断页节点卡同款底色
        color: Color.alphaBlend(
          cs.surfaceContainerHighest.withValues(alpha: 0.35),
          cs.surface,
        ),
        borderRadius: AppRadius.mdR,
        // 严重级别时给整卡加一道状态色描边，卡片本身就是警示信号。
        border: tone.alert
            ? Border.all(color: tone.color.withValues(alpha: 0.7), width: 1.5)
            : null,
        // 与登录页其余卡片（已保存账号卡）同款阴影。
        boxShadow: AppShadows.md(cs),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Icon(Icons.lan_outlined, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: AppSpacing.xs),
            Expanded(child: _buildHostRow(row, tone, l10n, cs)),
            // 探测中/空闲占同一 48x48 槽位，行高恒定，卡片不跳动。
            // 按钮重新测当前展示的域名（会覆盖已有结果）。
            IconButton(
              tooltip: l10n.networkTestLatencyShort,
              onPressed: _testing ? null : _retest,
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

  /// 当前展示节点的状态色与强调级别。未探测时中性、无强调。
  ({Color color, bool emphasize, bool alert}) _toneFor(
    String host,
    ColorScheme cs,
  ) {
    if (!_results.containsKey(host)) {
      return (
        color: AppStatusColors.neutral(cs),
        emphasize: false,
        alert: false,
      );
    }
    final latency = _results[host];
    // 超时：无法连接，最严重。
    if (latency == null) {
      return (color: AppStatusColors.danger(cs), emphasize: true, alert: true);
    }
    if (latency <= 800) {
      return (
        color: AppStatusColors.success(cs),
        emphasize: false,
        alert: false,
      );
    }
    if (latency <= 2000) {
      return (
        color: AppStatusColors.warning(cs),
        emphasize: true,
        alert: false,
      );
    }
    return (color: AppStatusColors.danger(cs), emphasize: true, alert: true);
  }

  Widget _buildHostRow(
    (String, String) row,
    ({Color color, bool emphasize, bool alert}) tone,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    final (label, host) = row;
    final tt = Theme.of(context).textTheme;
    final pending = !_results.containsKey(host);
    final latency = _results[host];
    final valueText = pending
        ? l10n.networkTesting
        : (latency == null ? l10n.networkTimeout : '$latency ms');
    // 严重级别用警示图标替换行首圆点：圆点太小，超时只靠变红容易被忽略。
    final badgeIcon = tone.alert
        ? (latency == null
              ? Icons.cloud_off_rounded
              : Icons.warning_amber_rounded)
        : null;

    return Row(
      children: [
        if (badgeIcon == null)
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: tone.color,
              shape: BoxShape.circle,
            ),
          )
        else
          Icon(badgeIcon, size: 16, color: tone.color),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: tone.emphasize
                ? AppStatusColors.fill(tone.color, alpha: 0.16)
                : null,
            borderRadius: AppRadius.xsR,
          ),
          child: Text(
            valueText,
            style: tt.bodyMedium?.copyWith(
              color: tone.color,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

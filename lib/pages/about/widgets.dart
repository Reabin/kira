part of '../about_page.dart';

class SettingIcon extends StatelessWidget {
  final IconData icon;
  final Color color;

  const SettingIcon({super.key, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: AppRadius.mdR,
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }
}

// ── 关于页 ──

/// Inline update card rendered on the About page. Replaces the old modal
/// update dialog — listens to [AppUpdateService.state] and surfaces an
/// available update as an embedded card.
class _UpdateCard extends StatefulWidget {
  const _UpdateCard({required this.onCheckUpdate});

  final VoidCallback onCheckUpdate;

  @override
  State<_UpdateCard> createState() => _UpdateCardState();
}

/// 关于页底部的一言（漫画类），低调展示；进入页面时请求，失败则不显示。
class _HitokotoFooter extends StatefulWidget {
  const _HitokotoFooter();

  @override
  State<_HitokotoFooter> createState() => _HitokotoFooterState();
}

class _HitokotoFooterState extends State<_HitokotoFooter> {
  HitokotoSentence? _sentence;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sentence = await HitokotoApi().fetchSentence();
    if (!mounted || sentence == null) return;
    setState(() => _sentence = sentence);
  }

  @override
  Widget build(BuildContext context) {
    final sentence = _sentence;
    if (sentence == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final text = sentence.from.isEmpty
        ? sentence.text
        : '${sentence.text} ——${sentence.from}';
    // 一言官方请求使用时附带跳转链接；视觉保持低调，仅整块可点。
    final url = sentence.uuid.isEmpty
        ? null
        : Uri.parse('https://hitokoto.cn?uuid=${sentence.uuid}');
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, AppSpacing.sm, 24, AppSpacing.lg),
      child: InkWell(
        onTap: url == null
            ? null
            : () => launchUrl(url, mode: LaunchMode.externalApplication),
        borderRadius: AppRadius.smR,
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

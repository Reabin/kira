import 'package:flutter/material.dart';

/// 排序方式选择 sheet 的单行选项，漫画/小说书架共用。
class OrderingTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const OrderingTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: selected ? cs.primary : null),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: selected ? Icon(Icons.check, color: cs.primary) : null,
      selected: selected,
      onTap: onTap,
    );
  }
}

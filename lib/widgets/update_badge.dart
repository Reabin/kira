import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_status_colors.dart';
import '../theme/app_typography.dart';

/// 书架封面卡右上角的「更新」角标，漫画/小说共用。
class UpdateBadge extends StatelessWidget {
  const UpdateBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: const BoxDecoration(
          color: AppStatusColors.updateAccent,
          borderRadius: BorderRadius.only(
            topRight: Radius.circular(12),
            bottomLeft: Radius.circular(10),
          ),
        ),
        child: Text(
          AppLocalizations.of(context)!.updateBadge,
          style: AppTypography.meta(Theme.of(context).textTheme)?.copyWith(
            color: AppStatusColors.onUpdateAccent,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

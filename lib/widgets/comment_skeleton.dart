import 'package:flutter/material.dart';

import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';

class CommentSkeleton extends StatelessWidget {
  const CommentSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: AppRadius.lgR,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Container(
                  height: 14,
                  decoration: BoxDecoration(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.2),
                    borderRadius: AppRadius.xsR,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Container(
                width: 48,
                height: 12,
                decoration: BoxDecoration(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.2),
                  borderRadius: AppRadius.xsR,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Container(
            width: double.infinity,
            height: 14,
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withValues(alpha: 0.2),
              borderRadius: AppRadius.xsR,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: MediaQuery.sizeOf(context).width * 0.55,
            height: 14,
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withValues(alpha: 0.2),
              borderRadius: AppRadius.xsR,
            ),
          ),
        ],
      ),
    );
  }
}

class CommentReplySkeleton extends StatelessWidget {
  const CommentReplySkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholderColor = cs.surfaceContainerHighest.withValues(alpha: 0.2);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: placeholderColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 86,
                    height: 12,
                    decoration: BoxDecoration(
                      color: placeholderColor,
                      borderRadius: AppRadius.xsR,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 40,
                    height: 10,
                    decoration: BoxDecoration(
                      color: placeholderColor,
                      borderRadius: AppRadius.xsR,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Container(
                width: double.infinity,
                height: 12,
                decoration: BoxDecoration(
                  color: placeholderColor,
                  borderRadius: AppRadius.xsR,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: MediaQuery.sizeOf(context).width * 0.36,
                height: 12,
                decoration: BoxDecoration(
                  color: placeholderColor,
                  borderRadius: AppRadius.xsR,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

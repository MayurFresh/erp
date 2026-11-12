import 'package:flutter/material.dart';

import '../core/app_colors.dart';
import '../core/design_tokens.dart';
import 'icon_badge.dart';
import 'status_chip.dart';

/// A single headline figure: small label, large tabular value, optional hint.
/// Flat with a hairline border; no icon badge.
class KpiTile extends StatelessWidget {
  const KpiTile({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.tone = StatusTone.neutral,
    this.onTap,
    this.icon,
    this.accent = Accent.teal,
  });

  /// Optional tinted badge beside the label.
  final IconData? icon;
  final Accent accent;

  final String label;
  final String value;

  /// One short line under the value, e.g. `3 invoices`.
  final String? hint;

  /// Colours the value and hint for warning/danger figures.
  final StatusTone tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final emphasised = tone == StatusTone.warning || tone == StatusTone.danger;
    final valueColor = emphasised
        ? colors.toneForeground(tone)
        : theme.colorScheme.onSurface;
    final child = Padding(
      padding: const EdgeInsets.all(Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                IconBadge(icon!, tone: accent, size: 24),
                const SizedBox(width: Space.sm),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.xs + 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: valueColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: Space.xs),
            Text(
              hint!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: emphasised
                    ? colors.toneAccent(tone)
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? child : InkWell(onTap: onTap, child: child),
    );
  }
}

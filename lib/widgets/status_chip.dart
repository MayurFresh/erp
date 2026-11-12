import 'package:flutter/material.dart';

import '../core/app_colors.dart';
import '../core/design_tokens.dart';

enum StatusTone { neutral, info, success, warning, danger }

/// Tone for a document or workflow status word (case-insensitive;
/// `-`, `_` and spaces are ignored).
StatusTone toneForStatus(String status) {
  final key = status.toLowerCase().replaceAll(RegExp(r'[\s_\-]'), '');
  return switch (key) {
    'posted' ||
    'paid' ||
    'approved' ||
    'accepted' ||
    'filed' ||
    'active' ||
    'completed' ||
    'complete' ||
    'received' ||
    'delivered' ||
    'matched' ||
    'valid' ||
    'ok' ||
    'done' ||
    'reconciled' ||
    'closed' => StatusTone.success,
    'pending' ||
    'partial' ||
    'partiallypaid' ||
    'partiallyreceived' ||
    'due' ||
    'open' ||
    'inprogress' ||
    'expiring' ||
    'warn' ||
    'unpaid' ||
    'submitted' ||
    'awaitingapproval' => StatusTone.warning,
    'overdue' ||
    'cancelled' ||
    'canceled' ||
    'rejected' ||
    'failed' ||
    'expired' ||
    'void' ||
    'reject' ||
    'mismatch' ||
    'blocked' => StatusTone.danger,
    'sent' || 'info' || 'confirmed' || 'issued' => StatusTone.info,
    _ => StatusTone.neutral,
  };
}

extension StatusToneColors on AppColors {
  Color toneForeground(StatusTone tone) => switch (tone) {
    StatusTone.neutral => onNeutralContainer,
    StatusTone.info => onInfoContainer,
    StatusTone.success => onSuccessContainer,
    StatusTone.warning => onWarningContainer,
    StatusTone.danger => onDangerContainer,
  };

  Color toneBackground(StatusTone tone) => switch (tone) {
    StatusTone.neutral => neutralContainer,
    StatusTone.info => infoContainer,
    StatusTone.success => successContainer,
    StatusTone.warning => warningContainer,
    StatusTone.danger => dangerContainer,
  };

  /// Saturated colour for dots, bars and large figures.
  Color toneAccent(StatusTone tone) => switch (tone) {
    StatusTone.neutral => onNeutralContainer,
    StatusTone.info => info,
    StatusTone.success => success,
    StatusTone.warning => warning,
    StatusTone.danger => danger,
  };
}

/// Small status label: tinted fill, dark text, a dot for the tone.
/// `StatusChip('posted')`, `StatusChip('overdue', label: '12 days late')`.
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.label, this.tone});

  final String status;

  /// Text shown; defaults to [status] with the first letter capitalised.
  final String? label;

  /// Overrides the tone derived from [status].
  final StatusTone? tone;

  static String _sentence(String s) {
    final t = s.replaceAll('_', ' ');
    return t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final t = tone ?? toneForStatus(status);
    final fg = colors.toneForeground(t);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.toneBackground(t),
        borderRadius: Radii.smallAll,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: colors.toneAccent(t),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label ?? _sentence(status),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

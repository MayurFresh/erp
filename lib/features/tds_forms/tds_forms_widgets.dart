import 'package:flutter/material.dart';

import '../../core/app_colors.dart';
import '../../core/json.dart';
import '../compliance/compliance_widgets.dart' show recentFys;

/// Marks anything taken from the Income-tax Act 2025 that has not been
/// checked against the official text.
class UnconfirmedBadge extends StatelessWidget {
  const UnconfirmedBadge({super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
    message:
        'Taken from secondary reports of the Income-tax Rules 2026. Check it '
        'against the official text before filing.',
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: context.colors.warning.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('Unconfirmed', style: Theme.of(context).textTheme.labelSmall),
    ),
  );
}

/// Financial year and (optionally) quarter pickers on one wrapping row.
class PeriodBar extends StatelessWidget {
  const PeriodBar({
    super.key,
    required this.fy,
    required this.onFy,
    this.quarter,
    this.onQuarter,
    this.trailing = const [],
  });

  final String fy;
  final ValueChanged<String> onFy;
  final int? quarter;
  final ValueChanged<int>? onQuarter;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final fys = recentFys();
    if (!fys.contains(fy)) fys.add(fy);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 150,
            child: DropdownButtonFormField<String>(
              initialValue: fy,
              decoration: const InputDecoration(labelText: 'Financial year'),
              items: [
                for (final f in fys) DropdownMenuItem(value: f, child: Text(f)),
              ],
              onChanged: (v) => v == null ? null : onFy(v),
            ),
          ),
          if (quarter != null)
            SizedBox(
              width: 130,
              child: DropdownButtonFormField<int>(
                initialValue: quarter,
                decoration: const InputDecoration(labelText: 'Quarter'),
                items: [
                  for (var q = 1; q <= 4; q++)
                    DropdownMenuItem(value: q, child: Text('Q$q')),
                ],
                onChanged: (v) => v == null ? null : onQuarter?.call(v),
              ),
            ),
          ...trailing,
        ],
      ),
    );
  }
}

Color checkColor(BuildContext context, String status) => switch (status) {
  'pass' => context.colors.success,
  'warn' => context.colors.warning,
  'fail' => context.colors.danger,
  _ => Theme.of(context).colorScheme.onSurfaceVariant,
};

/// One validation result: a coloured word, the title and the detail.
class CheckTile extends StatelessWidget {
  const CheckTile({super.key, required this.check});

  final Json check;

  @override
  Widget build(BuildContext context) {
    final status = asString(check['status']);
    final label = switch (status) {
      'pass' => 'Pass',
      'warn' => 'Check',
      'fail' => 'Fix',
      _ => status,
    };
    return ListTile(
      minVerticalPadding: 8,
      title: Text(asString(check['title'])),
      subtitle: Text(asString(check['detail'])),
      trailing: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: checkColor(context, status),
        ),
      ),
    );
  }
}

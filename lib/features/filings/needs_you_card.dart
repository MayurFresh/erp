import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../compliance/compliance_widgets.dart';
import 'filing_models.dart';
import 'filings_repository.dart';

/// Returns that are due or overdue, from `/filings/calendar`. Hidden while
/// loading, on any error (including 403) and when nothing needs doing.
class NeedsYouCard extends ConsumerWidget {
  const NeedsYouCard({super.key, this.now});

  /// For tests.
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fy = contractFy(now ?? DateTime.now());
    final rows = (ref.watch(filingCalendarProvider(fy)).value ?? const [])
        .where((r) => r.needsYou)
        .toList();
    if (rows.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'Needs you',
      child: Column(
        children: [
          for (final r in rows.take(6))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                r.status == 'overdue'
                    ? Icons.error_outline
                    : Icons.event_available_outlined,
                color: statusColor(context, r.status),
              ),
              title: Text(r.label),
              subtitle: Text(
                [
                  'due ${formatDate(r.dueDate)}',
                  if (r.status == 'overdue' && r.daysLate != null)
                    '${r.daysLate} days late',
                ].join(' · '),
              ),
              trailing: filingRoute(r.returnType, r.period) == null
                  ? null
                  : const Icon(Icons.chevron_right),
              onTap: filingRoute(r.returnType, r.period) == null
                  ? null
                  : () => context.go(filingRoute(r.returnType, r.period)!),
            ),
          if (rows.length > 6)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => context.go('/filings/calendar'),
                child: Text('+ ${rows.length - 6} more'),
              ),
            ),
        ],
      ),
    );
  }
}

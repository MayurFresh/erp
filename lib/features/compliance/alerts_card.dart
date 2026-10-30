import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import 'compliance_models.dart';
import 'compliance_repository.dart';
import 'compliance_widgets.dart';

/// Due dates and expiries for the dashboard. Hidden while loading, on any
/// error (including 403) and when there is nothing to show.
class AlertsCard extends ConsumerWidget {
  const AlertsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(alertsProvider).value ?? const <Alert>[];
    if (alerts.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'Alerts',
      child: Column(
        children: [
          for (final a in alerts.take(8))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                a.severity == 'info'
                    ? Icons.info_outline
                    : Icons.warning_amber_outlined,
                color: statusColor(context, a.severity),
              ),
              title: Text(a.title),
              subtitle: Text(
                [
                  if (a.detail.isNotEmpty) a.detail,
                  if (a.dueDate != null) 'due ${formatDate(a.dueDate)}',
                ].join(' · '),
              ),
              trailing: a.link.isEmpty ? null : const Icon(Icons.chevron_right),
              onTap: a.link.isEmpty ? null : () => context.go(a.link),
            ),
          if (alerts.length > 8)
            Align(
              alignment: Alignment.centerLeft,
              child: Text('+ ${alerts.length - 8} more'),
            ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'timesheet_models.dart';
import 'timesheet_repository.dart';

/// `/timesheets/utilisation`: billable against total hours, last 30 days.
class UtilisationScreen extends ConsumerWidget {
  const UtilisationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(utilisationProvider);
    final gutter = pageGutter(context);
    return CGate(
      anyOf: const [Perm.timesheetsView],
      child: AsyncValueView<Json>(
        value: async,
        onRetry: () => ref.invalidate(utilisationProvider),
        data: (r) {
          final t = asJson(r['totals']);
          final users = asJsonList(r['users']);
          return ListView(
            padding: EdgeInsets.all(gutter),
            children: [
              Text(
                'Utilisation, ${r['from']} to ${r['to']}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'Everyone',
                child: Text(
                  '${hoursText(asDouble(t['billableHours']))} billable of '
                  '${hoursText(asDouble(t['totalHours']))} h, '
                  '${asDouble(t['utilisationPct']).toStringAsFixed(1)}% utilised. '
                  'Billed ${hoursText(asDouble(t['billedHours']))} h, '
                  'unbilled ${formatMoney(asDouble(t['unbilledAmount']))}.',
                ),
              ),
              SectionCard(
                title: 'By person',
                child: users.isEmpty
                    ? const Text('No hours logged in this period.')
                    : Column(
                        children: [
                          for (final u in users)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(asString(u['name'])),
                              subtitle: Text(
                                '${hoursText(asDouble(u['billableHours']))} billable of '
                                '${hoursText(asDouble(u['totalHours']))} h '
                                '(target ${hoursText(asDouble(u['targetHours']))} h)',
                              ),
                              trailing: Text(
                                '${asDouble(u['utilisationPct']).toStringAsFixed(0)}%',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                        ],
                      ),
              ),
              SectionCard(
                title: 'By customer',
                child: Column(
                  children: [
                    for (final c in asJsonList(r['customers']))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(asString(c['name'])),
                        subtitle: Text('${hoursText(asDouble(c['hours']))} h'),
                        trailing: Text(formatMoney(asDouble(c['amount']))),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'helpdesk_repository.dart';
import '../construction/common/c_widgets.dart' show CGate, bigOutlinedButton;

String _hours(Object? v) {
  final d = asDoubleOrNull(v);
  return d == null ? 'No data' : '${d.toStringAsFixed(1)} h';
}

/// `/helpdesk/reports`: open by age, breaches, averages, by category and agent.
class HelpdeskReportsScreen extends ConsumerWidget {
  const HelpdeskReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(helpdeskSummaryProvider);
    final canSet = ref.watch(permissionsProvider).can(Perm.helpdeskSettings);
    final gutter = pageGutter(context);
    final theme = Theme.of(context);
    return CGate(
      anyOf: const [Perm.helpdeskView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Helpdesk reports',
            subtitle: 'Tickets raised in the last 30 days',
            actions: [
              if (canSet)
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: () => context.go('/helpdesk/settings'),
                  icon: const Icon(Icons.tune),
                  label: const Text('Hours and SLA'),
                ),
            ],
          ),
          Expanded(
            child: AsyncValueView<Json>(
              value: async,
              onRetry: () => ref.invalidate(helpdeskSummaryProvider),
              data: (s) {
                final br = asJson(s['breaches']);
                return ListView(
                  padding: EdgeInsets.all(gutter),
                  children: [
                    SectionCard(
                      title: 'Service levels',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Average first response ${_hours(s['avgFirstResponseHours'])}',
                          ),
                          Text(
                            'Average resolution ${_hours(s['avgResolutionHours'])}',
                          ),
                          Text(
                            'Breaches: ${asInt(br['response'])} first response, '
                            '${asInt(br['resolution'])} resolution',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SectionCard(
                      title: 'Open tickets by age',
                      child: Column(
                        children: [
                          for (final b in asJsonList(s['openByAge']))
                            _row(asString(b['bucket']), '${asInt(b['count'])}'),
                        ],
                      ),
                    ),
                    SectionCard(
                      title: 'By category',
                      child: Column(
                        children: [
                          for (final c in asJsonList(s['byCategory']))
                            _row(
                              asString(c['category']),
                              '${asInt(c['total'])} total, ${asInt(c['open'])} open, '
                              '${asInt(c['breached'])} breached',
                            ),
                        ],
                      ),
                    ),
                    SectionCard(
                      title: 'By agent',
                      child: Column(
                        children: [
                          for (final a in asJsonList(s['byAgent']))
                            _row(
                              asString(a['name']),
                              '${asInt(a['total'])} total, ${asInt(a['open'])} open, '
                              'avg ${_hours(a['avgResolutionHours'])}',
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String l, String r) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(l)),
        const SizedBox(width: 12),
        Flexible(child: Text(r, textAlign: TextAlign.end)),
      ],
    ),
  );
}

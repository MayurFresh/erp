import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'helpdesk_models.dart';
import 'helpdesk_repository.dart';

final _visitMonthProvider = FutureProvider.autoDispose
    .family<List<Visit>, DateTime>((ref, month) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(helpdeskRevisionProvider);
      final last = DateTime(month.year, month.month + 1, 0);
      return ref
          .watch(helpdeskRepositoryProvider)
          .visits(from: apiDate(month), to: apiDate(last));
    });

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// `/service-contracts/visits`: preventive visits of the month, by day.
class VisitCalendarScreen extends ConsumerStatefulWidget {
  const VisitCalendarScreen({super.key});

  @override
  ConsumerState<VisitCalendarScreen> createState() => _VisitCalendarState();
}

class _VisitCalendarState extends ConsumerState<VisitCalendarScreen> {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  void _shift(int by) =>
      setState(() => _month = DateTime(_month.year, _month.month + by));

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_visitMonthProvider(_month));
    final gutter = pageGutter(context);
    return CGate(
      anyOf: const [Perm.serviceContractsView, Perm.serviceContractsManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Visit calendar'),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Previous month',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: () => _shift(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    '${_months[_month.month - 1]} ${_month.year}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Next month',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: () => _shift(1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
          Expanded(
            child: AsyncValueView<List<Visit>>(
              value: data,
              onRetry: () => ref.invalidate(_visitMonthProvider),
              data: (list) {
                if (list.isEmpty) {
                  return const EmptyView(
                    message: 'No visits are planned this month.',
                    icon: Icons.event_available_outlined,
                  );
                }
                return ListView(
                  padding: EdgeInsets.all(gutter),
                  children: [
                    for (final v in list)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          minVerticalPadding: 10,
                          onTap: () =>
                              context.go('/service-contracts/${v.contractId}'),
                          title: Text('${v.dueDate}  ${v.partyName}'),
                          subtitle: Text(v.contractNumber),
                          trailing: StatusChip(
                            v.status,
                            label: v.overdue ? 'Overdue' : sentence(v.status),
                            tone: v.status == 'done'
                                ? StatusTone.success
                                : v.overdue
                                ? StatusTone.danger
                                : StatusTone.info,
                          ),
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
}

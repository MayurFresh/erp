import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../compliance/compliance_widgets.dart';
import 'gst_compliance_repository.dart';

/// `/msme-43bh`: dues to micro and small vendors beyond the time limit at 31 March.
class Msme43bhScreen extends ConsumerStatefulWidget {
  const Msme43bhScreen({super.key});

  @override
  ConsumerState<Msme43bhScreen> createState() => _Msme43bhScreenState();
}

class _Msme43bhScreenState extends ConsumerState<Msme43bhScreen> {
  late String _year = recentFys()[1];

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(msme43bhProvider(_year));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'MSME dues at year end',
          subtitle: 'Section 43B(h): owed beyond the time limit on 31 March',
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Tax year',
              value: _year,
              options: {for (final f in recentFys()) f: f},
              anyLabel: _year,
              width: 180,
              onChanged: (v) => setState(() => _year = v ?? _year),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView<MsmeBh>(
            value: value,
            onRetry: () => ref.invalidate(msme43bhProvider(_year)),
            data: (d) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                SectionCard(
                  title: 'Added to income in the ITR pack',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatMoney(d.total),
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Unpaid on ${formatDate(d.asOf)} to micro and small '
                        'vendors after 15 days, or after the agreed period of '
                        'up to 45 days. Allowed as a deduction in the year it '
                        'is paid. Medium vendors are not covered.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (d.rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('Nothing was overdue.')),
                  ),
                for (final r in d.rows)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      minTileHeight: 56,
                      title: Text('${r.number} · ${r.partyName}'),
                      subtitle: Text(
                        'Bill ${formatDate(r.billDate)} · due '
                        '${formatDate(r.dueDate)} · ${r.daysOverdue} days late',
                      ),
                      trailing: Text(formatMoney(r.outstanding)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

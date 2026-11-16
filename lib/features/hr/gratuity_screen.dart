import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'hr_form.dart';
import 'hr_repository.dart';
import 'hr_widgets.dart';
import 'statutory_repository.dart';
import 'statutory_settings_screen.dart' show AsyncBlock, monthLabelOf;
import 'statutory_widgets.dart';

/// `/hr/gratuity`: monthly gratuity liability for each employee.
class GratuityScreen extends ConsumerStatefulWidget {
  const GratuityScreen({super.key});

  @override
  ConsumerState<GratuityScreen> createState() => _State();
}

class _State extends ConsumerState<GratuityScreen> {
  String _month = currentMonth();

  @override
  Widget build(BuildContext context) => CGate(
    anyOf: const [Perm.payrollView],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(title: 'Gratuity liability'),
        Expanded(
          child: HrPad(
            children: [
              StepperBar(
                label: 'As at the end of ${monthLabelOf(_month)}',
                onPrev: () => setState(() => _month = shiftMonth(_month, -1)),
                onNext: () => setState(() => _month = shiftMonth(_month, 1)),
              ),
              AsyncBlock<Json>(
                value: ref.watch(gratuityProvider(_month)),
                data: (g) {
                  final rows = asJsonList(g['data']);
                  final t = asJson(g['totals']);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      HrCard(
                        child: Column(
                          children: [
                            StatRow('Accrued to date', t['accrued'] as num?),
                            StatRow('Payable now (eligible staff)', t['payable'] as num?),
                            StatRow('Change this month', t['movement'] as num?, bold: true),
                          ],
                        ),
                      ),
                      Text(
                        '15/26 of last drawn wages for each counted year. A part year over six months counts as a year. '
                        'Payable after ${asJson(g['rules'])['years']} years (fixed-term staff after ${asJson(g['rules'])['fixedTermYears']}).',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const HrSection('Employees'),
                      if (rows.isEmpty) const Text('No employees with a salary structure.'),
                      for (final r in rows)
                        HrCard(
                          onTap: () async {
                            final ok = await showHrForm(
                              context,
                              title: r['name'] as String,
                              intro: 'Fixed-term staff are eligible after one year of service.',
                              fields: [HrField('fixedTerm', 'Fixed-term employee', kind: HrFieldKind.toggle, initial: r['fixedTerm'] == true)],
                              onSubmit: (v) => ref.read(statutoryRepositoryProvider).setFixedTerm('${r['employeeId']}', v['fixedTerm'] == true),
                            );
                            if (ok) ref.bumpHr();
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${r['name']} (${r['code']})', style: const TextStyle(fontWeight: FontWeight.w600)),
                              Text(
                                'Joined ${formatDate(r['joiningDate'])}, ${r['completedYears']} years completed, ${r['countedYears']} counted'
                                '${r['fixedTerm'] == true ? ', fixed-term' : ''}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              StatRow('Wages', r['wages'] as num?),
                              StatRow('Accrued', r['accrued'] as num?),
                              StatRow(r['eligible'] == true ? 'Payable' : 'Not yet eligible', r['payable'] as num?, bold: r['eligible'] == true),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

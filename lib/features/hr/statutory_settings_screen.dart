import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/json.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'hr_form.dart';
import 'hr_repository.dart';
import 'hr_widgets.dart';
import 'statutory_repository.dart';
import 'statutory_widgets.dart';

/// `/hr/statutory`: dated rates, Labour Code wages rule, bonus, gratuity and overtime settings.
class StatutorySettingsScreen extends ConsumerStatefulWidget {
  const StatutorySettingsScreen({super.key});

  @override
  ConsumerState<StatutorySettingsScreen> createState() => _State();
}

class _State extends ConsumerState<StatutorySettingsScreen> {
  String _month = currentMonth();

  static const _kinds = [('epf', 'Provident fund (EPF)'), ('esi', 'ESI'), ('pt', 'Professional tax'), ('lwf', 'Labour welfare fund')];

  List<HrField> _settingFields(Json s) => [
    HrField('wagesRuleEnabled', 'Use the Labour Code wages rule', kind: HrFieldKind.toggle, initial: s['wagesRuleEnabled'] == true),
    HrField('wagesRuleFrom', 'Rule applies from', kind: HrFieldKind.date, required: true, initial: s['wagesRuleFrom']),
    HrField('wagesRulePercent', 'Share of pay counted as wages (%)', kind: HrFieldKind.number, required: true, initial: s['wagesRulePercent']),
    HrField('minimumWage', 'State minimum wage a month', kind: HrFieldKind.number, initial: s['minimumWage']),
    HrField('bonusPct', 'Bonus rate (8.33 to 20 %)', kind: HrFieldKind.number, required: true, initial: s['bonusPct']),
    HrField('bonusEligibilityCeiling', 'Bonus eligibility wage ceiling', kind: HrFieldKind.number, initial: s['bonusEligibilityCeiling']),
    HrField('bonusCalcCeiling', 'Bonus calculation ceiling', kind: HrFieldKind.number, initial: s['bonusCalcCeiling']),
    HrField('gratuityYears', 'Years of service for gratuity', kind: HrFieldKind.number, initial: s['gratuityYears']),
    HrField('gratuityFixedTermYears', 'Years for fixed-term staff', kind: HrFieldKind.number, initial: s['gratuityFixedTermYears']),
    HrField('gratuityCap', 'Tax-free gratuity limit', kind: HrFieldKind.number, initial: s['gratuityCap']),
    HrField('otMultiplier', 'Overtime rate (times the hourly rate)', kind: HrFieldKind.number, initial: s['otMultiplier']),
    HrField('hoursPerDay', 'Working hours in a day', kind: HrFieldKind.number, initial: s['hoursPerDay']),
  ];

  String _summary(Json r) {
    final c = asJson(r['config']);
    switch (r['kind']) {
      case 'epf':
        return 'Wage ceiling ${c['ceiling']}';
      case 'esi':
        return 'Wage ceiling ${c['ceiling']}, employee ${(num.tryParse('${c['employeeBps']}') ?? 0) / 100}%, employer ${(num.tryParse('${c['employerBps']}') ?? 0) / 100}%';
      case 'pt':
        return '${(c['slabs'] as List?)?.length ?? 0} slabs, ${c['periodicity']}';
      default:
        return 'Employee ${c['employee']}, employer ${c['employer']}';
    }
  }

  Future<void> _addRate() async {
    final repo = ref.read(statutoryRepositoryProvider);
    final ok = await showHrForm(
      context,
      title: 'Add a rate row',
      intro: 'The row applies from its date. Payroll uses the latest row on or before the pay month.',
      fields: const [
        HrField('kind', 'Rate', kind: HrFieldKind.choice, required: true, options: _kinds),
        HrField('stateCode', 'State code (professional tax and LWF)'),
        HrField('effectiveFrom', 'Effective from', kind: HrFieldKind.date, required: true),
        HrField('ceiling', 'Wage ceiling (EPF and ESI)', kind: HrFieldKind.number),
        HrField('employee', 'Employee amount (LWF)', kind: HrFieldKind.number),
        HrField('employer', 'Employer amount (LWF)', kind: HrFieldKind.number),
        HrField('months', 'LWF months, for example 6,12'),
        HrField('slabs', 'PT slabs as from-to:amount, for example 0-14999:0, 15000-:200'),
        HrField('note', 'Source or note'),
      ],
      onSubmit: (v) async {
        final kind = v['kind'] as String;
        final Json config;
        if (kind == 'epf' || kind == 'esi') {
          if (v['ceiling'] == null) throw ApiException(400, 'VALIDATION', 'Enter the wage ceiling.');
          config = {'ceiling': v['ceiling']};
        } else if (kind == 'lwf') {
          final months = '${v['months'] ?? ''}'.split(',').map((e) => int.tryParse(e.trim())).whereType<int>().toList();
          if (v['employee'] == null || v['employer'] == null || months.isEmpty) throw ApiException(400, 'VALIDATION', 'Enter both amounts and the months.');
          config = {'employee': v['employee'], 'employer': v['employer'], 'months': months};
        } else {
          final slabs = <Json>[];
          for (final part in '${v['slabs'] ?? ''}'.split(',')) {
            final m = RegExp(r'^\s*(\d+)\s*-\s*(\d*)\s*:\s*(\d+(?:\.\d+)?)\s*$').firstMatch(part);
            if (m == null) throw ApiException(400, 'VALIDATION', 'Write slabs like 0-14999:0, 15000-:200.');
            slabs.add({'from': int.parse(m[1]!), 'to': m[2]!.isEmpty ? null : int.parse(m[2]!), 'amount': num.parse(m[3]!)});
          }
          config = {'periodicity': 'monthly', 'slabs': slabs};
        }
        final state = '${v['stateCode'] ?? ''}'.trim();
        if ((kind == 'pt' || kind == 'lwf') && state.isEmpty) throw ApiException(400, 'VALIDATION', 'Enter the 2-digit state code.');
        await repo.addRate({'kind': kind, if (state.isNotEmpty) 'stateCode': state, 'effectiveFrom': v['effectiveFrom'], 'config': config, 'note': v['note']});
      },
    );
    if (ok) ref.bumpHr();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(statSettingsProvider);
    final rates = ref.watch(statRatesProvider(_month));
    return CGate(
      anyOf: const [Perm.payrollEmployees],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Statutory settings'),
          Expanded(
            child: HrPad(
              children: [
                HrSection('Rules and limits'),
                AsyncBlock<Json>(
                  value: settings,
                  data: (s) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      HrCard(
                        child: Column(
                          children: [
                            StatRow('Labour Code wages rule', null, text: s['wagesRuleEnabled'] == true ? 'On from ${s['wagesRuleFrom']}' : 'Off'),
                            StatRow('Bonus rate', null, text: '${s['bonusPct']}%'),
                            StatRow('Bonus wage ceiling', s['bonusEligibilityCeiling'] as num?),
                            StatRow('Gratuity tax-free limit', s['gratuityCap'] as num?),
                            StatRow('Overtime', null, text: '${s['otMultiplier']} times the hourly rate'),
                          ],
                        ),
                      ),
                      if (asJsonOrNull(s['notes']) != null) Text('${asJson(s['notes'])['wagesRule']}', style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: () async {
                          final ok = await showHrForm(
                            context,
                            title: 'Statutory settings',
                            fields: _settingFields(s),
                            onSubmit: (v) => ref.read(statutoryRepositoryProvider).saveSettings(v),
                          );
                          if (ok) ref.bumpHr();
                        },
                        child: const Text('Change settings'),
                      ),
                    ],
                  ),
                ),
                HrSection('Rates in force', trailing: TextButton.icon(icon: const Icon(Icons.add), label: const Text('Add row'), onPressed: _addRate)),
                StepperBar(
                  label: monthLabelOf(_month),
                  onPrev: () => setState(() => _month = shiftMonth(_month, -1)),
                  onNext: () => setState(() => _month = shiftMonth(_month, 1)),
                ),
                AsyncBlock<Json>(
                  value: rates,
                  data: (r) {
                    final inForce = asJson(r['inForce']);
                    final epf = asJson(inForce['epf']), esi = asJson(inForce['esi']);
                    final rows = asJsonList(r['data']).where((x) => x['source'] == 'company').toList();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        HrCard(
                          child: Column(
                            children: [
                              StatRow('EPF wage ceiling', epf['ceiling'] as num?),
                              StatRow('ESI wage ceiling', esi['ceiling'] as num?),
                            ],
                          ),
                        ),
                        const HrSection('Rows you added'),
                        if (rows.isEmpty) const Text('None. The built-in rows are used.'),
                        for (final row in rows)
                          HrCard(
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('${row['kind'].toString().toUpperCase()}${row['stateCode'] != null ? ' state ${row['stateCode']}' : ''} from ${row['effectiveFrom']}'),
                                      Text(_summary(row), style: Theme.of(context).textTheme.bodySmall),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Remove',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    await ref.read(statutoryRepositoryProvider).deleteRate('${row['id']}');
                                    ref.bumpHr();
                                  },
                                ),
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
}

String monthLabelOf(String ym) {
  const names = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  return '${names[int.parse(ym.substring(5, 7)) - 1]} ${ym.substring(0, 4)}';
}

/// Inline loading, error and data for one value inside a scrolling page.
class AsyncBlock<T> extends StatelessWidget {
  const AsyncBlock({super.key, required this.value, required this.data});

  final AsyncValue<T> value;
  final Widget Function(T d) data;

  @override
  Widget build(BuildContext context) => value.when(
    data: data,
    loading: () => const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
    error: (e, _) => Padding(padding: const EdgeInsets.all(8), child: Text(errorMessage(e))),
  );
}

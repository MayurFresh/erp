import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'hr_form.dart';
import 'hr_repository.dart';
import 'hr_widgets.dart';
import 'statutory_repository.dart';
import 'statutory_settings_screen.dart' show AsyncBlock;
import 'statutory_widgets.dart';

/// `/hr/bonus`: yearly statutory bonus run.
class BonusScreen extends ConsumerStatefulWidget {
  const BonusScreen({super.key});

  @override
  ConsumerState<BonusScreen> createState() => _State();
}

class _State extends ConsumerState<BonusScreen> {
  int _fy = currentFy();
  String? _run;
  bool _busy = false;

  Future<void> _post() async {
    final runId = _run;
    if (runId == null || _busy) return;
    final ok = await hrConfirm(context, 'Add bonus to the run', 'Each eligible employee gets one bonus line in the chosen run. This cannot be added twice for the same year.', 'Add');
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final r = await ref.read(statutoryRepositoryProvider).bonusRun(_fy, runId);
      ref.bumpHr();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bonus added for ${r['posted']} employees.')));
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => CGate(
    anyOf: const [Perm.payrollView],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(title: 'Statutory bonus'),
        Expanded(
          child: HrPad(
            children: [
              StepperBar(
                label: 'Year ${fyLabel(_fy)}',
                onPrev: () => setState(() => _fy--),
                onNext: () => setState(() => _fy++),
              ),
              AsyncBlock<Json>(
                value: ref.watch(bonusPreviewProvider(_fy)),
                data: (p) {
                  final rows = asJsonList(p['data']);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      HrCard(
                        child: Column(
                          children: [
                            StatRow('Rate', null, text: '${p['pct']}%'),
                            StatRow('Total to pay', p['total'] as num?, bold: true),
                          ],
                        ),
                      ),
                      Text(
                        'Worked out on wages up to the calculation ceiling, for the months paid in the year. '
                        'Staff above the wage ceiling or with fewer than the minimum days are left out.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const HrSection('Employees'),
                      if (rows.isEmpty) const Text('No payroll lines in this year yet.'),
                      for (final r in rows)
                        HrCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${r['name']} (${r['code']})', style: const TextStyle(fontWeight: FontWeight.w600)),
                              StatRow(
                                r['alreadyPaid'] == true
                                    ? 'Already paid'
                                    : r['eligible'] == true
                                    ? 'Bonus'
                                    : '${r['reason'] ?? 'Not eligible'}',
                                r['eligible'] == true ? r['amount'] as num? : null,
                                text: r['eligible'] == true ? null : '-',
                              ),
                              Text('Wage ${r['monthlyWage']}, ${r['monthsPaid']} months paid', style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                      const HrSection('Post to payroll'),
                      OpenRunPicker(value: _run, onChanged: (v) => setState(() => _run = v)),
                      const SizedBox(height: 8),
                      FilledButton(onPressed: _run == null || _busy ? null : _post, child: const Text('Add bonus to the run')),
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

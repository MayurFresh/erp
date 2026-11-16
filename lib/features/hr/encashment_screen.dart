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

/// `/hr/encashment`: which leave can be encashed, and the yearly encashment run.
class EncashmentScreen extends ConsumerStatefulWidget {
  const EncashmentScreen({super.key});

  @override
  ConsumerState<EncashmentScreen> createState() => _State();
}

class _State extends ConsumerState<EncashmentScreen> {
  int _fy = currentFy();
  String? _run;
  bool _busy = false;

  Future<void> _post() async {
    final runId = _run;
    if (runId == null || _busy) return;
    if (!await hrConfirm(context, 'Add encashment to the run', 'The days are taken off each leave balance and the amount is added to the chosen run.', 'Add')) return;
    setState(() => _busy = true);
    try {
      final r = await ref.read(statutoryRepositoryProvider).encRun(_fy, runId);
      ref.bumpHr();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Encashment added for ${r['employees']} employees.')));
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => CGate(
    anyOf: const [Perm.payrollView, Perm.payrollEmployees],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(title: 'Leave encashment'),
        Expanded(
          child: HrPad(
            children: [
              const HrSection('Leave types that can be encashed'),
              InlineAsyncList<Json>(
                value: ref.watch(encTypesProvider),
                empty: 'No leave types yet.',
                item: (t) => HrCard(
                  onTap: t['isPaid'] != true
                      ? null
                      : () async {
                          final ok = await showHrForm(
                            context,
                            title: '${t['name']}',
                            fields: [
                              HrField('encashable', 'Can be encashed', kind: HrFieldKind.toggle, initial: t['encashable'] == true),
                              HrField('maxDays', 'Most days a year', kind: HrFieldKind.number, initial: t['maxDays']),
                            ],
                            onSubmit: (v) => ref.read(statutoryRepositoryProvider).saveEncType('${t['leaveTypeId']}', v['encashable'] == true, (v['maxDays'] as num?) ?? 0),
                          );
                          if (ok) ref.bumpHr();
                        },
                  child: StatRow(
                    '${t['name']}${t['isPaid'] == true ? '' : ' (unpaid)'}',
                    null,
                    text: t['encashable'] == true ? 'Up to ${t['maxDays']} days' : 'Not encashable',
                  ),
                ),
              ),
              const HrSection('Yearly run'),
              StepperBar(label: 'Year ${fyLabel(_fy)}', onPrev: () => setState(() => _fy--), onNext: () => setState(() => _fy++)),
              AsyncBlock<Json>(
                value: ref.watch(encPreviewProvider(_fy)),
                data: (p) {
                  final rows = asJsonList(p['data']);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      StatRow('Total', p['total'] as num?, bold: true),
                      Text('Amount is wages divided by 30, times the days. Wages follow the Labour Code rule when it is on.', style: Theme.of(context).textTheme.bodySmall),
                      if (rows.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Nothing to encash.')),
                      for (final r in rows)
                        HrCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${r['name']} (${r['code']})', style: const TextStyle(fontWeight: FontWeight.w600)),
                              StatRow('${r['leaveType']}, ${r['days']} of ${r['balance']} days', r['amount'] as num?),
                            ],
                          ),
                        ),
                      if (rows.isNotEmpty) ...[
                        OpenRunPicker(value: _run, onChanged: (v) => setState(() => _run = v)),
                        const SizedBox(height: 8),
                        FilledButton(onPressed: _run == null || _busy ? null : _post, child: const Text('Add encashment to the run')),
                      ],
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

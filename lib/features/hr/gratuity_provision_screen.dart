import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../auth/session.dart';
import '../claims/claims_widgets.dart' show guarded;
import '../construction/common/c_widgets.dart' show CGate;
import 'hr_form.dart';
import 'hr_repository.dart';
import 'hr_widgets.dart';
import 'statutory_repository.dart';
import 'statutory_settings_screen.dart' show AsyncBlock, monthLabelOf;
import 'statutory_widgets.dart';

/// The date a month's provision is worked out for: today for the current month, else the last day.
String provisionDateOf(String month, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final cur = '${n.year}-${n.month.toString().padLeft(2, '0')}';
  if (month == cur) return '$cur-${n.day.toString().padLeft(2, '0')}';
  final y = int.parse(month.substring(0, 4)),
      m = int.parse(month.substring(5, 7));
  return '$month-${DateTime(y, m + 1, 0).day.toString().padLeft(2, '0')}';
}

/// `/hr/gratuity-provision`: what is owed to each employee as at a date, and a button that books the difference.
class GratuityProvisionScreen extends ConsumerStatefulWidget {
  const GratuityProvisionScreen({super.key});

  @override
  ConsumerState<GratuityProvisionScreen> createState() => _State();
}

class _State extends ConsumerState<GratuityProvisionScreen> {
  String _month = currentMonth();

  Future<void> _post(String asOf, num toPost) async {
    final sign = toPost < 0 ? 'reduces' : 'adds';
    final ok = await hrConfirm(
      context,
      'Post provision as at ${formatDate(asOf)}',
      'This $sign the gratuity provision by ${formatMoney(toPost.abs())} in the books. A date can be posted once.',
      'Post',
    );
    if (!ok || !mounted) return;
    if (await guarded(
      context,
      () => ref.read(statutoryRepositoryProvider).postGratuityProvision(asOf),
    )) {
      ref.bumpHr();
    }
  }

  @override
  Widget build(BuildContext context) {
    final asOf = provisionDateOf(_month);
    final canPost = ref.watch(permissionsProvider).can(Perm.payrollApprove);
    return CGate(
      anyOf: const [Perm.payrollView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Gratuity provision'),
          Expanded(
            child: HrPad(
              children: [
                StepperBar(
                  label: 'As at ${formatDate(asOf)}',
                  onPrev: () => setState(() => _month = shiftMonth(_month, -1)),
                  onNext: () => setState(() => _month = shiftMonth(_month, 1)),
                ),
                AsyncBlock<Json>(
                  value: ref.watch(gratuityProvisionProvider(asOf)),
                  data: (g) {
                    final rows = asJsonList(g['data']);
                    final t = asJson(g['totals']);
                    final posted = g['posted'] != null;
                    final toPost = (t['toPost'] as num?) ?? 0;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        HrCard(
                          child: Column(
                            children: [
                              StatRow(
                                'Provision needed',
                                t['provision'] as num?,
                                bold: true,
                              ),
                              StatRow(
                                'Booked in the accounts',
                                t['balance'] as num?,
                              ),
                              StatRow('To post', toPost),
                              if (t['lastPostedOn'] != null)
                                StatRow(
                                  'Change since ${formatDate(t['lastPostedOn'])}',
                                  t['changeSinceLast'] as num?,
                                ),
                              StatRow(
                                'Of this, staff under ${g['eligibleYears']} years',
                                t['underYears'] as num?,
                              ),
                            ],
                          ),
                        ),
                        if (canPost)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: FilledButton(
                                onPressed: posted
                                    ? null
                                    : () => _post(asOf, toPost),
                                child: Text(
                                  posted
                                      ? 'Already posted for this date'
                                      : 'Post',
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          '15/26 of monthly wages (basic and DA) for each counted year, a part year over six months counted as one, '
                          'at most ${formatMoney(g['cap'] as num?)} a person. Everyone is provided for, including staff who are not yet '
                          'eligible to be paid. ${monthLabelOf(_month)}.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (asJsonList(g['skipped']).isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'Left out, no salary structure: ${asJsonList(g['skipped']).map((s) => s['name']).join(', ')}.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        const HrSection('Employees'),
                        if (rows.isEmpty)
                          const Text('No employees with a salary structure.'),
                        for (final r in rows)
                          HrCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${r['name']} (${r['code']})',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  'Joined ${formatDate(r['joiningDate'])}, ${r['completedYears']} years completed, ${r['countedYears']} counted'
                                  '${r['underYears'] == true ? ', under ${g['eligibleYears']} years' : ''}'
                                  '${r['capped'] == true ? ', capped' : ''}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                StatRow('Monthly wages', r['wages'] as num?),
                                StatRow(
                                  'Provision',
                                  r['provision'] as num?,
                                  bold: true,
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

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_fonts.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'fnf_pdf.dart';
import 'hr_form.dart';
import 'hr_repository.dart';
import 'hr_widgets.dart';
import 'statutory_repository.dart';
import 'statutory_widgets.dart';

const _statusText = {'draft': 'Draft', 'approved': 'Approved', 'paid': 'Paid', 'cancelled': 'Cancelled'};

/// `/hr/fnf`: full and final settlements.
class FnfListScreen extends ConsumerWidget {
  const FnfListScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final emps = ref.read(employeesProvider((q: '', status: 'active'))).value ?? const [];
    String? newId;
    final ok = await showHrForm(
      context,
      title: 'New settlement',
      intro: 'The settlement is worked out from the salary structure, leave balance and years of service.',
      fields: [
        HrField('employeeId', 'Employee', kind: HrFieldKind.choice, required: true, options: [for (final e in emps) (e.id, '${e.name} (${e.code})')]),
        const HrField('exitDate', 'Last working day', kind: HrFieldKind.date, required: true),
        const HrField('noticeRequiredDays', 'Notice period in days', kind: HrFieldKind.number, initial: 0),
        const HrField('noticeServedDays', 'Notice days served', kind: HrFieldKind.number, initial: 0),
        const HrField('noticeMode', 'Short notice', kind: HrFieldKind.choice, initial: 'none', options: [
          ('none', 'No recovery or payment'),
          ('recover', 'Recover from the employee'),
          ('payout', 'Pay in lieu of notice'),
        ]),
        const HrField('lopDays', 'Loss of pay days this month', kind: HrFieldKind.number, initial: 0),
        const HrField('includeGratuity', 'Pay gratuity', kind: HrFieldKind.toggle, initial: true),
        const HrField('includeLeave', 'Encash leave', kind: HrFieldKind.toggle, initial: true),
        const HrField('includeBonus', 'Pay pro-rata bonus', kind: HrFieldKind.toggle),
        const HrField('leaveExempt', 'Leave encashment is tax free (retirement)', kind: HrFieldKind.toggle),
        const HrField('notes', 'Notes', kind: HrFieldKind.multiline),
      ],
      onSubmit: (v) async {
        final r = await ref.read(statutoryRepositoryProvider).fnfCreate({
          ...v,
          'noticeRequiredDays': ((v['noticeRequiredDays'] as num?) ?? 0).toInt(),
          'noticeServedDays': ((v['noticeServedDays'] as num?) ?? 0).toInt(),
        });
        newId = '${r['id']}';
      },
    );
    if (ok) {
      ref.bumpHr();
      if (newId != null && context.mounted) context.go('/hr/fnf/$newId');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => CGate(
    anyOf: const [Perm.payrollView],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Full and final settlement',
          actions: [
            if (ref.watch(permissionsProvider).can(Perm.payrollRun))
              FilledButton.icon(onPressed: () => _create(context, ref), icon: const Icon(Icons.add), label: const Text('New settlement')),
          ],
        ),
        Expanded(
          child: HrPad(
            children: [
              InlineAsyncList<Json>(
                value: ref.watch(fnfListProvider),
                empty: 'No settlements yet.',
                item: (f) => HrCard(
                  onTap: () => context.go('/hr/fnf/${f['id']}'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${f['employeeName']} (${f['employeeCode']})', style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('${f['number']}, last day ${formatDate(f['exitDate'])}, ${_statusText[f['status']] ?? f['status']}', style: Theme.of(context).textTheme.bodySmall),
                      StatRow('Net payable', f['net'] as num?, bold: true),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// `/hr/fnf/:id`
class FnfScreen extends ConsumerWidget {
  const FnfScreen({super.key, required this.id});

  final String id;

  Future<void> _act(BuildContext context, WidgetRef ref, String action, String title, String body) async {
    if (!await hrConfirm(context, title, body, title)) return;
    try {
      await ref.read(statutoryRepositoryProvider).fnfAction(id, action);
      ref.bumpHr();
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _addLine(BuildContext context, WidgetRef ref, Json d) async {
    final existing = asJsonList(asJson(d['input'])['extraLines']);
    final ok = await showHrForm(
      context,
      title: 'Other payment or deduction',
      fields: const [
        HrField('kind', 'Type', kind: HrFieldKind.choice, required: true, initial: 'earning', options: [('earning', 'Payment'), ('deduction', 'Deduction')]),
        HrField('label', 'Description', required: true),
        HrField('amount', 'Amount', kind: HrFieldKind.number, required: true),
        HrField('taxable', 'Taxable', kind: HrFieldKind.toggle),
      ],
      onSubmit: (v) => ref.read(statutoryRepositoryProvider).fnfUpdate(id, {
        'extraLines': [...existing, v],
      }),
    );
    if (ok) ref.bumpHr();
  }

  Future<void> _print(BuildContext context, WidgetRef ref, Json d) async {
    try {
      Company? co;
      try {
        co = await ref.read(companyRepositoryProvider).get();
      } catch (_) {
        co = ref.read(sessionProvider).value?.company;
      }
      co ??= const Company(id: '', name: 'Company', stateCode: '');
      final bytes = await buildFnfPdf(d, co, brand: await loadPdfBrand(ref.read(apiClientProvider), co), theme: await pdfTheme());
      await Printing.layoutPdf(onLayout: (_) async => Uint8List.fromList(bytes), name: fnfFileName(d));
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final can = ref.watch(permissionsProvider);
    return CGate(
      anyOf: const [Perm.payrollView],
      child: AsyncValueView(
        value: ref.watch(fnfProvider(id)),
        onRetry: () => ref.invalidate(fnfProvider(id)),
        data: (d) {
          final result = asJson(d['result']);
          final line = asJson(result['line']);
          final lines = fnfLines(d);
          final g = asJson(result['gratuity']);
          final status = '${d['status']}';
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageHeader(
                title: '${d['employeeName']}',
                actions: [
                  OutlinedButton.icon(onPressed: () => _print(context, ref, d), icon: const Icon(Icons.print_outlined), label: const Text('Print or save PDF')),
                ],
              ),
              Expanded(
                child: HrPad(
                  children: [
                    HrCard(
                      child: Column(
                        children: [
                          StatRow('Settlement', null, text: '${d['number']} (${_statusText[status] ?? status})'),
                          StatRow('Last working day', null, text: formatDate(d['exitDate'])),
                          if (result['pendingSalaryPaid'] == true) const StatRow('Salary for the exit month', null, text: 'Already paid in a payroll run'),
                        ],
                      ),
                    ),
                    const HrSection('Payments'),
                    for (final e in lines.earnings) StatRow(e.$1, e.$2),
                    StatRow('Total payments', d['gross'] as num?, bold: true),
                    const HrSection('Deductions'),
                    if (lines.deductions.isEmpty) const Text('None.'),
                    for (final e in lines.deductions) StatRow(e.$1, e.$2),
                    StatRow('Total deductions', d['deductions'] as num?, bold: true),
                    const HrSection('Net payable'),
                    StatRow('Net amount', d['net'] as num?, bold: true),
                    const HrSection('Working'),
                    StatRow('Years of service counted', null, text: '${g['countedYears'] ?? 0} (${g['completedYears'] ?? 0} completed)'),
                    StatRow('Gratuity', null, text: g['eligible'] == true ? 'Eligible' : 'Not yet eligible'),
                    for (final l in asJsonList(result['leave'])) StatRow('${l['leaveType']}: ${l['days']} days', l['amount'] as num?),
                    if (result['bonusNote'] != null) Text('${result['bonusNote']}', style: Theme.of(context).textTheme.bodySmall),
                    if (line['warnings'] is List)
                      for (final w in (line['warnings'] as List)) Text('$w', style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                    if (status == 'draft' && can.can(Perm.payrollRun))
                      OutlinedButton(onPressed: () => _addLine(context, ref, d), child: const Text('Add another payment or deduction')),
                    if (status == 'draft' && can.can(Perm.payrollApprove)) ...[
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: () => _act(context, ref, 'approve', 'Approve', 'This posts the settlement to the books and marks the employee as left. Someone other than the preparer must approve.'),
                        child: const Text('Approve and mark as left'),
                      ),
                    ],
                    if (status == 'draft' && can.can(Perm.payrollRun)) ...[
                      const SizedBox(height: 8),
                      TextButton(onPressed: () => _act(context, ref, 'cancel', 'Cancel settlement', 'The draft is cancelled.'), child: const Text('Cancel this draft')),
                    ],
                    if (status == 'approved' && can.can(Perm.payrollApprove))
                      FilledButton(
                        onPressed: () => _act(context, ref, 'pay', 'Mark as paid', 'This records the payment from the bank account.'),
                        child: const Text('Mark as paid'),
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

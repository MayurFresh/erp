import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

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
import 'hr_models.dart';
import 'hr_repository.dart';
import 'hr_widgets.dart';
import 'payslip_pdf.dart';

/// `/payslip/:id`
class PayslipScreen extends ConsumerWidget {
  const PayslipScreen({super.key, required this.payslipId});

  final String payslipId;

  Future<void> _print(BuildContext context, WidgetRef ref, Payslip p) async {
    try {
      Company? co;
      try {
        co = await ref.read(companyRepositoryProvider).get();
      } catch (_) {
        co = ref.read(sessionProvider).value?.company;
      }
      co ??= const Company(id: '', name: 'Company', stateCode: '');
      final bytes = await buildPayslipPdf(
        p,
        co,
        brand: await loadPdfBrand(ref.read(apiClientProvider), co),
        theme: await pdfTheme(),
      );
      await Printing.layoutPdf(onLayout: (_) async => Uint8List.fromList(bytes), name: payslipFileName(p));
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => CGate(
    anyOf: const [Perm.payrollView, Perm.payrollSelf],
    child: AsyncValueView(
      value: ref.watch(payslipProvider(payslipId)),
      onRetry: () => ref.invalidate(payslipProvider(payslipId)),
      data: (p) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Payslip ${monthLabel(p.month)}',
            actions: [
              OutlinedButton.icon(
                onPressed: () => _print(context, ref, p),
                icon: const Icon(Icons.print_outlined),
                label: const Text('Print or save PDF'),
              ),
            ],
          ),
          Expanded(
            child: HrPad(
              children: [
                HrCard(
                  child: Column(
                    children: [
                      HrAmountRow('Employee', null, text: '${p.employee['name'] ?? ''}'),
                      HrAmountRow('Paid days', null, text: '${dayText(p.paidDays)} of ${dayText(p.workingDays)}'),
                    ],
                  ),
                ),
                const HrSection('Earnings'),
                for (final e in p.earnings) HrAmountRow('${e['name'] ?? e['label']}', (e['amount'] as num?) ?? 0),
                HrAmountRow('Gross pay', p.gross, bold: true),
                const HrSection('Deductions'),
                for (final d in p.deductions) HrAmountRow('${d['name'] ?? d['label']}', (d['amount'] as num?) ?? 0),
                HrAmountRow('Total deductions', p.totalDeductions, bold: true),
                const HrSection('Take home'),
                HrAmountRow('Net pay', p.net, bold: true),
                if (p.employer.isNotEmpty) ...[
                  const HrSection('Paid by the employer on top'),
                  for (final d in p.employer) HrAmountRow('${d['name'] ?? d['label']}', (d['amount'] as num?) ?? 0),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

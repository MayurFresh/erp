import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'dart:typed_data';

import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_fonts.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import 'clinic_repository.dart';
import 'clinic_widgets.dart';
import 'ipd_forms.dart';
import 'ipd_models.dart';
import 'ipd_pdf.dart';

/// `/clinic/ipd/stays/:id`: one admission with its charges, deposits and
/// the discharge flow.
class IpdStayScreen extends ConsumerWidget {
  const IpdStayScreen({super.key, required this.admissionId});

  final String admissionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CGate(
    anyOf: const [Perm.clinicIpd, Perm.clinicIpdManage],
    child: AsyncValueView<Admission>(
      value: ref.watch(ipdAdmissionProvider(admissionId)),
      onRetry: () => ref.invalidate(ipdAdmissionProvider(admissionId)),
      data: (a) => _StayBody(admission: a),
    ),
  );
}

class _StayBody extends ConsumerStatefulWidget {
  const _StayBody({required this.admission});

  final Admission admission;

  @override
  ConsumerState<_StayBody> createState() => _StayBodyState();
}

class _StayBodyState extends ConsumerState<_StayBody> {
  bool _busy = false;

  Admission get a => widget.admission;

  void _refresh({bool money = false}) =>
      ref.bumpClinic(const [ClinicKind.ipd], money: money);

  Future<void> _dialog(
    Widget Function(BuildContext) builder, {
    bool money = false,
    String? done,
  }) async {
    final r = await showFormDialog<Object>(context: context, builder: builder);
    if (r == null || !mounted) return;
    _refresh(money: money);
    if (done != null) showSuccess(context, done);
  }

  Future<void> _void(IpdCharge c) async {
    final reason = await showReasonDialog(
      context,
      title: 'Remove charge',
      message: 'Remove "${c.description}" from the stay?',
      confirmLabel: 'Remove',
    );
    if (reason == null || !mounted) return;
    try {
      await ref
          .read(clinicRepositoryProvider)
          .voidCharge(a.brief.id, c.id, reason);
      _refresh();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _postBed() async {
    setState(() => _busy = true);
    try {
      await ref.read(clinicRepositoryProvider).postBedCharges(a.brief.id);
      _refresh();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _summary() async {
    final saved = await showFormDialog<Admission>(
      context: context,
      builder: (_) => _SummaryDialog(admission: a),
    );
    if (saved != null && mounted) {
      _refresh();
      showSuccess(context, 'Discharge summary saved');
    }
  }

  Future<void> _discharge() async {
    final r = await showFormDialog<DischargeResult>(
      context: context,
      builder: (_) => DischargeDialog(admission: a),
    );
    if (r == null || !mounted) return;
    _refresh(money: true);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discharged'),
        content: Text(
          'Bill ${r.invoice.number} for ${formatMoney(r.invoice.total)}.\n'
          'Deposits set against it: ${formatMoney(r.depositsApplied)}.\n'
          '${r.balanceDue > 0 ? 'Balance on credit: ${formatMoney(r.balanceDue)}.\n' : ''}'
          '${r.refundDue > 0 ? 'Deposit left over: ${formatMoney(r.refundDue)}.' : ''}',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _pdf() async {
    setState(() => _busy = true);
    try {
      final data = await ref
          .read(clinicRepositoryProvider)
          .dischargeSummary(a.brief.id);
      Company? company;
      try {
        company = await ref.read(companyRepositoryProvider).get();
      } catch (_) {
        company = ref.read(sessionProvider).value?.company;
      }
      final brand = company == null
          ? null
          : await loadPdfBrand(ref.read(apiClientProvider), company);
      final bytes = await buildDischargeSummaryPdf(
        data,
        brand: brand,
        theme: await pdfTheme(),
      );
      await Printing.layoutPdf(
        onLayout: (_) async => Uint8List.fromList(bytes),
        name: dischargeFileName(data),
        format: PdfPageFormat.a4,
      );
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final manage = perms.can(Perm.clinicIpdManage);
    final consult = perms.can(Perm.clinicConsult);
    final theme = Theme.of(context);
    final gutter = pageGutter(context);
    final b = a.brief;
    final t = a.totals;
    final live = a.admitted;
    return ListView(
      padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 32),
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Back to beds',
              onPressed: () => context.go('/clinic/ipd'),
              icon: const Icon(Icons.arrow_back),
            ),
            Expanded(
              child: Text(
                b.patientName,
                style: theme.textTheme.headlineSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Pill(live ? 'Admitted' : 'Discharged'),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Fact('Admission', '${b.number}  |  ${b.uhid}'),
              Fact('Doctor', b.doctorName),
              Fact('Bed', b.bedLabel),
              Fact(
                'Stay',
                '${formatDate(b.admitDate)}'
                    '${b.dischargeDate == null ? '' : ' to ${formatDate(b.dischargeDate)}'}'
                    '  |  ${b.days} day${b.days == 1 ? '' : 's'}',
              ),
              if (a.clinical) Fact('Provisional', a.provisionalDiagnosis),
            ],
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (live) ...[
              FilledButton.icon(
                style: bigButton,
                onPressed: () => _dialog(
                  (_) => ChargeDialog(admissionId: b.id),
                  done: 'Charge added',
                ),
                icon: const Icon(Icons.add),
                label: const Text('Add charge'),
              ),
              if (manage && perms.can(Perm.paymentsCreate))
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: () => _dialog(
                    (_) => DepositDialog(admissionId: b.id),
                    money: true,
                    done: 'Deposit saved',
                  ),
                  icon: const Icon(Icons.payments_outlined),
                  label: const Text('Take deposit'),
                ),
              if (manage)
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: () => _dialog(
                    (_) => TransferDialog(admission: a),
                    done: 'Moved',
                  ),
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Change bed'),
                ),
              OutlinedButton.icon(
                style: bigOutlinedButton,
                onPressed: _busy ? null : _postBed,
                icon: const Icon(Icons.event_available_outlined),
                label: const Text('Post bed charges'),
              ),
              if (consult)
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: _summary,
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Discharge summary'),
                ),
              if (manage && perms.can(Perm.invoicesCreate))
                FilledButton.icon(
                  style: bigButton,
                  onPressed: _discharge,
                  icon: const Icon(Icons.logout),
                  label: const Text('Discharge and bill'),
                ),
            ] else ...[
              if (consult)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: _busy ? null : _pdf,
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Discharge summary PDF'),
                ),
              if (manage &&
                  a.refundDue > 0.005 &&
                  perms.can(Perm.paymentsCreate))
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: () => _dialog(
                    (_) => RefundDialog(admission: a),
                    money: true,
                    done: 'Refund recorded',
                  ),
                  icon: const Icon(Icons.undo),
                  label: Text('Refund ${formatMoney(a.refundDue)}'),
                ),
              if (a.invoice != null)
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: () => context.push('/invoices/${a.invoice!.id}'),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: Text('Bill ${a.invoice!.number}'),
                ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                _TotalRow('Bed charges', t.bed),
                _TotalRow('Services', t.service),
                _TotalRow('Medicines', t.medicine),
                const Divider(),
                _TotalRow('Total before tax', t.total, bold: true),
                _TotalRow('Deposits taken', t.deposits),
                if (live)
                  _TotalRow(
                    t.balance > 0 ? 'Balance to pay' : 'Deposit in hand',
                    t.balance.abs(),
                    bold: true,
                  ),
                if (a.invoice != null)
                  _TotalRow(
                    'Final bill (with tax)',
                    a.invoice!.total,
                    bold: true,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Charges', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        if (a.charges.isEmpty) const Text('Nothing charged yet.'),
        for (final c in a.charges.reversed)
          Card(
            key: ValueKey('charge-${c.id}'),
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              title: Text(
                c.description,
                style: c.isVoid
                    ? const TextStyle(decoration: TextDecoration.lineThrough)
                    : null,
              ),
              subtitle: Text(
                '${formatDate(c.date)}  |  ${c.kind == 'bed'
                    ? 'Bed'
                    : c.kind == 'medicine'
                    ? 'Medicine'
                    : 'Service'}'
                '  |  ${formatPlain(c.qty)} x ${formatMoney(c.rate)}',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(formatMoney(c.amount)),
                  if (live && manage && c.kind != 'bed' && !c.isVoid)
                    IconButton(
                      tooltip: 'Remove ${c.description}',
                      onPressed: () => _void(c),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            ),
          ),
        if (a.deposits.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Deposits', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          for (final d in a.deposits)
            Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                title: Text(d.number),
                subtitle: Text('${formatDate(d.date)}  |  ${d.mode}'),
                trailing: Text(formatMoney(d.amount)),
              ),
            ),
        ],
      ],
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow(this.label, this.amount, {this.bold = false});

  final String label;
  final double amount;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold
        ? Theme.of(context).textTheme.titleSmall
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(formatMoney(amount), style: style),
        ],
      ),
    );
  }
}

/// The doctor's discharge summary, saved before billing. Pops the [Admission].
class _SummaryDialog extends ConsumerStatefulWidget {
  const _SummaryDialog({required this.admission});

  final Admission admission;

  @override
  ConsumerState<_SummaryDialog> createState() => _SummaryDialogState();
}

class _SummaryDialogState extends ConsumerState<_SummaryDialog> {
  late final _dx = TextEditingController(
    text: widget.admission.notes.diagnosis,
  );
  late final _tx = TextEditingController(
    text: widget.admission.notes.treatment,
  );
  late final _cond = TextEditingController(
    text: widget.admission.notes.condition,
  );
  late final _advice = TextEditingController(
    text: widget.admission.notes.advice,
  );
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_dx, _tx, _cond, _advice]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(clinicRepositoryProvider)
          .saveSummary(widget.admission.brief.id, {
            'diagnosis': trimmedOrNull(_dx.text),
            'treatment': trimmedOrNull(_tx.text),
            'condition': trimmedOrNull(_cond.text),
            'advice': trimmedOrNull(_advice.text),
            'expectedUpdatedAt': widget.admission.updatedAt,
          });
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Discharge summary'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _dx,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Final diagnosis'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tx,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Treatment given'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _cond,
              decoration: const InputDecoration(
                labelText: 'Condition at discharge',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _advice,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Advice'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      BusyButton(busy: _saving, onPressed: _save, label: 'Save'),
    ],
  );
}

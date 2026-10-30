import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/busy.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../compliance/compliance_repository.dart' show AccountOption;
import '../compliance/compliance_widgets.dart' show pickAccount, recentFys;
import '../compliance/tax_perms.dart';
import '../reports/report_widgets.dart' show tabularFigures;
import 'it_models.dart';
import 'it_repository.dart';
import 'it_widgets.dart';

/// `/tax-payments`: advance and self-assessment tax paid by challan.
class TaxPaymentsScreen extends ConsumerStatefulWidget {
  const TaxPaymentsScreen({super.key});

  @override
  ConsumerState<TaxPaymentsScreen> createState() => _TaxPaymentsScreenState();
}

class _TaxPaymentsScreenState extends ConsumerState<TaxPaymentsScreen> {
  late final PagedController<TaxPayment> _c;
  String? _taxYear = recentFys().first;

  @override
  void initState() {
    super.initState();
    _c = PagedController<TaxPayment>((offset, limit) async {
      final list = await ref
          .read(incomeTaxRepositoryProvider)
          .payments(_taxYear ?? '');
      return Paged(list, list.length);
    })..refresh();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _record() async {
    final p = await showDialog<TaxPayment>(
      context: context,
      builder: (_) => TaxPaymentDialog(initialTaxYear: _taxYear),
    );
    if (p == null || !mounted) return;
    ref.read(taxRevisionProvider.notifier).bump();
    ref.bump(const [DataKind.accounts]);
    showInfoSnackBar(context, '${p.number} recorded');
  }

  Future<void> _cancel(TaxPayment p) async {
    final reason = await askReasonDialog(
      context,
      title: 'Cancel ${p.number}?',
      helper: 'The journal is reversed.',
      confirmLabel: 'Cancel payment',
    );
    if (reason == null || !mounted) return;
    try {
      await runBlocking(
        context,
        () => ref.read(incomeTaxRepositoryProvider).cancelPayment(p.id, reason),
      );
      ref.read(taxRevisionProvider.notifier).bump();
      ref.bump(const [DataKind.accounts]);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(taxRevisionProvider, (_, _) => _c.refresh());
    final manage = ref.watch(permissionsProvider).can(TaxPerm.taxManage);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Income-tax payments',
          subtitle: 'Advance tax and self-assessment tax paid by challan',
          actions: [
            if (manage)
              FilledButton.icon(
                onPressed: _record,
                icon: const Icon(Icons.add),
                label: const Text('Record payment'),
              ),
          ],
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Tax year',
              value: _taxYear,
              options: {for (final f in recentFys()) f: f},
              anyLabel: 'All years',
              width: 170,
              onChanged: (v) {
                _taxYear = v;
                _c.refresh();
              },
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<TaxPayment>(
            controller: _c,
            emptyMessage: 'No tax payments recorded.',
            emptyIcon: Icons.payments_outlined,
            columns: [
              TableColumnSpec('Number', (p) => Text(p.number)),
              TableColumnSpec('Date', (p) => Text(formatDate(p.date))),
              TableColumnSpec('Kind', (p) => Text(p.kindLabel)),
              TableColumnSpec('Tax year', (p) => Text(p.taxYear)),
              TableColumnSpec(
                'BSR / serial',
                (p) => Text('${p.bsrCode} / ${p.challanSerial}'),
              ),
              TableColumnSpec(
                'Paid from',
                (p) => Text(p.paidFromAccountName),
                maxWidth: 200,
              ),
              TableColumnSpec(
                'Amount',
                (p) => Text(formatAmount(p.amount), style: tabularFigures),
                numeric: true,
              ),
              TableColumnSpec(
                'Status',
                (p) => manage && !p.cancelled
                    ? TextButton(
                        onPressed: () => _cancel(p),
                        child: const Text('Cancel'),
                      )
                    : Pill(
                        p.cancelled ? 'Cancelled' : 'Posted',
                        color: p.cancelled
                            ? Colors.red.shade700
                            : Colors.green.shade700,
                      ),
              ),
            ],
            cardBuilder: (context, p) => ListCard(
              title: Text('${p.kindLabel} · ${p.taxYear}'),
              subtitle: Text(
                '${p.number} · ${formatDate(p.date)}\n'
                'BSR ${p.bsrCode} · serial ${p.challanSerial}'
                '${p.cancelled ? '\nCancelled' : ''}',
              ),
              trailing: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(formatMoney(p.amount), style: tabularFigures),
                  if (manage && !p.cancelled)
                    TextButton(
                      onPressed: () => _cancel(p),
                      child: const Text('Cancel'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Record one challan: kind, tax year, date, amount, BSR, serial, paid-from.
class TaxPaymentDialog extends ConsumerStatefulWidget {
  const TaxPaymentDialog({super.key, this.initialTaxYear});

  final String? initialTaxYear;

  @override
  ConsumerState<TaxPaymentDialog> createState() => _TaxPaymentDialogState();
}

class _TaxPaymentDialogState extends ConsumerState<TaxPaymentDialog>
    with ServerFieldErrors, DirtyTracking<TaxPaymentDialog> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _bsr = TextEditingController();
  final _serial = TextEditingController();
  String _kind = 'advance_tax';
  late String _taxYear = widget.initialTaxYear ?? recentFys().first;
  DateTime _date = DateTime.now();
  AccountOption? _account;
  String? _accountError;

  @override
  void dispose() {
    _amount.dispose();
    _bsr.dispose();
    _serial.dispose();
    super.dispose();
  }

  String? _digits(String? v, int n, String what) =>
      RegExp('^\\d{$n}\$').hasMatch((v ?? '').trim())
      ? null
      : '$what must be $n digits';

  Future<void> _submit() async {
    setState(() => serverErrors = const {});
    final ok = _form.currentState!.validate();
    setState(
      () => _accountError = _account == null ? 'Choose cash or bank' : null,
    );
    if (!ok || _account == null) return;
    try {
      final p = await ref.read(incomeTaxRepositoryProvider).recordPayment({
        'kind': _kind,
        'taxYear': _taxYear,
        'date': apiDate(_date),
        'amount': parseIndianNumber(_amount.text),
        'bsrCode': _bsr.text.trim(),
        'challanSerial': _serial.text.trim(),
        'paidFromAccountId': _account!.id,
      });
      markSaved();
      if (mounted) Navigator.pop(context, p);
    } catch (e) {
      if (mounted) showSubmitError(e);
    }
  }

  @override
  Widget build(BuildContext context) => track(
    AlertDialog(
      title: const Text('Record tax payment'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            onChanged: markDirty,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _kind,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Kind'),
                  items: [
                    for (final e in taxKindLabels.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() => _kind = v ?? _kind),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _taxYear,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Tax year'),
                  items: [
                    for (final f in recentFys())
                      DropdownMenuItem(value: f, child: Text(f)),
                  ],
                  onChanged: (v) => setState(() => _taxYear = v ?? _taxYear),
                ),
                const SizedBox(height: 12),
                DateButton(
                  label: 'Payment date',
                  value: _date,
                  last: DateTime.now().add(const Duration(days: 1)),
                  onChanged: (d) => setState(() {
                    _date = d;
                    markDirty();
                  }),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _amount,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [moneyInput()],
                  decoration: InputDecoration(
                    labelText: 'Amount',
                    prefixText: '₹ ',
                    errorText: serverError('amount'),
                  ),
                  validator: (v) => validateMoney(v, min: 0.01),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _bsr,
                  keyboardType: TextInputType.number,
                  maxLength: 7,
                  decoration: InputDecoration(
                    labelText: 'BSR code (7 digits)',
                    errorText: serverError('bsrCode'),
                  ),
                  validator: (v) => _digits(v, 7, 'BSR code'),
                ),
                TextFormField(
                  controller: _serial,
                  keyboardType: TextInputType.number,
                  maxLength: 5,
                  decoration: InputDecoration(
                    labelText: 'Challan serial (5 digits)',
                    errorText: serverError('challanSerial'),
                  ),
                  validator: (v) => _digits(v, 5, 'Challan serial'),
                ),
                PickerField(
                  label: 'Paid from (cash or bank)',
                  value: _account?.label,
                  errorText: _accountError,
                  onTap: () async {
                    final a = await pickAccount(
                      context,
                      ref,
                      title: 'Paid from',
                      where: (a) => a.subtype == 'bank' || a.subtype == 'cash',
                    );
                    if (a != null) {
                      setState(() {
                        _account = a;
                        _accountError = null;
                        markDirty();
                      });
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.maybePop(context),
          child: const Text('Cancel'),
        ),
        BusyButton(onPressed: _submit, label: 'Record payment'),
      ],
    ),
  );
}

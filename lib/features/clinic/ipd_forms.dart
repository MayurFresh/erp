import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../accounts/accounts_repository.dart';
import '../auth/session.dart';
import 'clinic_models.dart';
import 'clinic_repository.dart';
import 'clinic_widgets.dart';
import 'ipd_models.dart';

const _modes = {
  'cash': 'Cash',
  'upi': 'UPI',
  'card': 'Card',
  'bank': 'Bank transfer',
  'cheque': 'Cheque',
};

/// Amount, mode and account for a deposit or a payment at discharge.
class PayFields {
  final amount = TextEditingController();
  final reference = TextEditingController();
  String mode = 'cash';
  String? accountId;

  void dispose() {
    amount.dispose();
    reference.dispose();
  }

  double get value => parseNumber(amount.text) ?? 0;

  Map<String, Object?> body() => {
    'accountId': accountId,
    'mode': mode,
    'amount': value,
    'reference': trimmedOrNull(reference.text),
  };
}

class PayFieldsView extends ConsumerWidget {
  const PayFieldsView({
    super.key,
    required this.fields,
    required this.onChanged,
    this.amountLabel = 'Amount',
    this.helper,
  });

  final PayFields fields;
  final VoidCallback onChanged;
  final String amountLabel;
  final String? helper;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(cashBankAccountsProvider).value ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormRow(
          minCellWidth: 160,
          children: [
            TextField(
              controller: fields.amount,
              keyboardType: decimalKeyboard,
              inputFormatters: [decimalInput()],
              decoration: InputDecoration(
                labelText: amountLabel,
                helperText: helper,
              ),
              onChanged: (_) => onChanged(),
            ),
            DropdownButtonFormField<String>(
              initialValue: fields.mode,
              decoration: const InputDecoration(labelText: 'Mode'),
              items: [
                for (final e in _modes.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) {
                fields.mode = v ?? 'cash';
                onChanged();
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: fields.accountId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Deposit to'),
          items: [
            for (final a in accounts)
              DropdownMenuItem(
                value: a.id,
                child: Text(a.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) {
            fields.accountId = v;
            onChanged();
          },
        ),
      ],
    );
  }
}

String bedLabel(IpdWard w, IpdBed b) =>
    '${w.name}, ${b.bedNo}  (${formatMoney(b.dailyRate)} a day)';

/// Dropdown of free beds. Keyed so a reload re-reads the value.
class FreeBedDropdown extends StatelessWidget {
  const FreeBedDropdown({
    super.key,
    required this.board,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final IpdBoard board;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final free = board.freeBeds;
    return DropdownButtonFormField<String>(
      key: ValueKey('bed-$value-${free.length}'),
      initialValue: free.any((e) => e.$2.id == value) ? value : null,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Bed'),
      validator: (v) => v == null ? 'Choose a bed' : null,
      items: [
        for (final (w, b) in free)
          DropdownMenuItem(
            value: b.id,
            child: Text(bedLabel(w, b), overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }
}

/// Admit a patient. Pops the new [Admission].
class AdmitDialog extends ConsumerStatefulWidget {
  const AdmitDialog({super.key, this.bedId});

  final String? bedId;

  @override
  ConsumerState<AdmitDialog> createState() => _AdmitDialogState();
}

class _AdmitDialogState extends ConsumerState<AdmitDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _days = TextEditingController();
  final _dx = TextEditingController();
  final _deposit = PayFields();
  PatientBrief? _patient;
  String? _doctorId;
  late String? _bedId = widget.bedId;
  bool _saving = false;

  @override
  void dispose() {
    _days.dispose();
    _dx.dispose();
    _deposit.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!validateAndReveal(_formKey)) return;
    final dep = _deposit.value;
    if (dep > 0 && _deposit.accountId == null) {
      showErrorSnackBar(context, 'Choose the account for the deposit.');
      return;
    }
    setState(() => _saving = true);
    try {
      final a = await ref.read(clinicRepositoryProvider).admit({
        'patientId': _patient!.id,
        'doctorId': _doctorId,
        'bedId': _bedId,
        'expectedDays': int.tryParse(_days.text.trim()),
        if (trimmedOrNull(_dx.text) != null)
          'provisionalDiagnosis': trimmedOrNull(_dx.text),
        if (dep > 0) 'deposit': _deposit.body(),
      });
      if (mounted) Navigator.of(context).pop(a);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(ipdBoardProvider).value;
    final perms = ref.watch(permissionsProvider);
    return AlertDialog(
      title: const Text('Admit patient'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PatientPickerField(
                  value: _patient,
                  onChanged: (p) => setState(() => _patient = p),
                ),
                const SizedBox(height: 12),
                DoctorDropdown(
                  value: _doctorId,
                  onChanged: (v) => setState(() => _doctorId = v),
                ),
                const SizedBox(height: 12),
                if (board == null)
                  const LinearProgressIndicator()
                else
                  FreeBedDropdown(
                    board: board,
                    value: _bedId,
                    onChanged: (v) => setState(() => _bedId = v),
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _days,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Expected stay (days, optional)',
                  ),
                ),
                if (perms.can(Perm.clinicConsult)) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _dx,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Provisional diagnosis (optional)',
                    ),
                  ),
                ],
                if (perms.can(Perm.paymentsCreate)) ...[
                  const Divider(height: 28),
                  Text(
                    'Deposit (optional)',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  PayFieldsView(
                    fields: _deposit,
                    onChanged: () => setState(() {}),
                    amountLabel: 'Advance received',
                    helper: 'Leave empty to admit without a deposit',
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        BusyButton(busy: _saving, onPressed: _save, label: 'Admit'),
      ],
    );
  }
}

/// Move the patient to another free bed. Pops the updated [Admission].
class TransferDialog extends ConsumerStatefulWidget {
  const TransferDialog({super.key, required this.admission});

  final Admission admission;

  @override
  ConsumerState<TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends ConsumerState<TransferDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();
  String? _bedId;
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      final a = await ref
          .read(clinicRepositoryProvider)
          .transfer(
            widget.admission.brief.id,
            _bedId!,
            trimmedOrNull(_reason.text),
          );
      if (mounted) Navigator.of(context).pop(a);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(ipdBoardProvider).value;
    return AlertDialog(
      title: const Text('Move to another bed'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Now in ${widget.admission.brief.bedLabel ?? 'no bed'}. '
                  'Today is charged to the new bed.',
                ),
                const SizedBox(height: 12),
                if (board == null)
                  const LinearProgressIndicator()
                else
                  FreeBedDropdown(
                    board: board,
                    value: _bedId,
                    onChanged: (v) => setState(() => _bedId = v),
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _reason,
                  decoration: const InputDecoration(
                    labelText: 'Reason (optional)',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        BusyButton(busy: _saving, onPressed: _save, label: 'Move'),
      ],
    );
  }
}

/// Take a deposit. Pops the updated [Admission].
class DepositDialog extends ConsumerStatefulWidget {
  const DepositDialog({super.key, required this.admissionId});

  final String admissionId;

  @override
  ConsumerState<DepositDialog> createState() => _DepositDialogState();
}

class _DepositDialogState extends ConsumerState<DepositDialog> {
  final _pay = PayFields();
  bool _saving = false;

  @override
  void dispose() {
    _pay.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_pay.value <= 0) {
      showErrorSnackBar(context, 'Enter the amount received.');
      return;
    }
    if (_pay.accountId == null) {
      showErrorSnackBar(context, 'Choose the account for the deposit.');
      return;
    }
    setState(() => _saving = true);
    try {
      final a = await ref
          .read(clinicRepositoryProvider)
          .deposit(widget.admissionId, _pay.body());
      if (mounted) Navigator.of(context).pop(a);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Take a deposit'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: PayFieldsView(
          fields: _pay,
          onChanged: () => setState(() {}),
          amountLabel: 'Amount received',
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      BusyButton(busy: _saving, onPressed: _save, label: 'Save deposit'),
    ],
  );
}

/// Add a service or medicine to the stay. Pops the updated [Admission].
class ChargeDialog extends ConsumerStatefulWidget {
  const ChargeDialog({super.key, required this.admissionId});

  final String admissionId;

  @override
  ConsumerState<ChargeDialog> createState() => _ChargeDialogState();
}

class _ChargeDialogState extends ConsumerState<ChargeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _desc = TextEditingController();
  final _qty = TextEditingController(text: '1');
  final _rate = TextEditingController();
  String _kind = 'service';
  String? _itemId;
  bool _saving = false;

  @override
  void dispose() {
    _desc.dispose();
    _qty.dispose();
    _rate.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final item = await pickItem(context, ref);
    if (item == null) return;
    setState(() {
      _itemId = item.id;
      _desc.text = item.name;
      _rate.text = formatPlain(item.salePrice);
    });
  }

  Future<void> _save() async {
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      final a = await ref
          .read(clinicRepositoryProvider)
          .addCharge(widget.admissionId, {
            'kind': _kind,
            'itemId': _itemId,
            'description': trimmedOrNull(_desc.text),
            'qty': parseNumber(_qty.text),
            'rate': parseNumber(_rate.text),
          });
      if (mounted) Navigator.of(context).pop(a);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add to the stay'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'service', label: Text('Service')),
                  ButtonSegment(value: 'medicine', label: Text('Medicine')),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : _pick,
                  icon: const Icon(Icons.search),
                  label: Text(
                    _itemId == null ? 'Pick from items' : 'Change item',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _desc,
                decoration: const InputDecoration(labelText: 'Description'),
                validator: (v) => requiredField(v, 'Description'),
              ),
              const SizedBox(height: 12),
              FormRow(
                minCellWidth: 120,
                children: [
                  TextFormField(
                    controller: _qty,
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput(decimals: 3)],
                    decoration: const InputDecoration(labelText: 'Qty'),
                    validator: (v) => (parseNumber(v ?? '') ?? 0) <= 0
                        ? 'Enter a quantity'
                        : null,
                  ),
                  TextFormField(
                    controller: _rate,
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput()],
                    decoration: const InputDecoration(labelText: 'Rate'),
                    validator: (v) =>
                        parseNumber(v ?? '') == null ? 'Enter a rate' : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      BusyButton(busy: _saving, onPressed: _save, label: 'Add'),
    ],
  );
}

/// Discharge summary and final bill. Pops the [DischargeResult].
class DischargeDialog extends ConsumerStatefulWidget {
  const DischargeDialog({super.key, required this.admission});

  final Admission admission;

  @override
  ConsumerState<DischargeDialog> createState() => _DischargeDialogState();
}

class _DischargeDialogState extends ConsumerState<DischargeDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _dx = TextEditingController(
    text: widget.admission.notes.diagnosis,
  );
  late final _tx = TextEditingController(
    text: widget.admission.notes.treatment,
  );
  late final _advice = TextEditingController(
    text: widget.admission.notes.advice,
  );
  late final _cond = TextEditingController(
    text: widget.admission.notes.condition,
  );
  late DateTime? _follow = parseApiDate(widget.admission.notes.followupDate);
  final _pay = PayFields();
  bool _credit = false;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_dx, _tx, _advice, _cond]) {
      c.dispose();
    }
    _pay.dispose();
    super.dispose();
  }

  double get _due {
    final t = widget.admission.totals;
    return t.total - t.deposits;
  }

  Future<void> _save() async {
    if (!validateAndReveal(_formKey)) return;
    final paid = _pay.value;
    if (paid > 0 && _pay.accountId == null) {
      showErrorSnackBar(context, 'Choose the account for the payment.');
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await ref
          .read(clinicRepositoryProvider)
          .discharge(widget.admission.brief.id, {
            'diagnosis': trimmedOrNull(_dx.text),
            'treatment': trimmedOrNull(_tx.text),
            'advice': trimmedOrNull(_advice.text),
            'condition': trimmedOrNull(_cond.text),
            'followupDate': _follow == null ? null : apiDate(_follow!),
            if (paid > 0) 'payment': _pay.body(),
            if (_credit) 'allowCredit': true,
          });
      if (mounted) Navigator.of(context).pop(r);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.admission.totals;
    final perms = ref.watch(permissionsProvider);
    final canNotes = perms.can(Perm.clinicConsult);
    return AlertDialog(
      title: const Text('Discharge and bill'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (canNotes) ...[
                  TextFormField(
                    controller: _dx,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Final diagnosis',
                    ),
                    validator: (v) => requiredField(v, 'Diagnosis'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _tx,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Treatment given',
                    ),
                    validator: (v) => requiredField(v, 'Treatment'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _cond,
                    decoration: const InputDecoration(
                      labelText: 'Condition at discharge',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _advice,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Advice'),
                  ),
                  const SizedBox(height: 12),
                  DateField(
                    label: 'Follow-up on (optional)',
                    value: _follow,
                    onChanged: (d) => setState(() => _follow = d),
                    onCleared: () => setState(() => _follow = null),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  ),
                ] else
                  const Text(
                    'The doctor writes the discharge summary. It must be '
                    'saved before the patient can be discharged.',
                  ),
                const Divider(height: 28),
                Text(
                  'Charges ${formatMoney(t.total)} before tax. Deposits '
                  '${formatMoney(t.deposits)} are set against the bill.',
                ),
                if (_due > 0) ...[
                  const SizedBox(height: 12),
                  PayFieldsView(
                    fields: _pay,
                    onChanged: () => setState(() {}),
                    amountLabel: 'Pay now (optional)',
                    helper:
                        'About ${formatMoney(_due)} is still to pay '
                        'before tax',
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Leave any balance on credit'),
                    value: _credit,
                    onChanged: (v) => setState(() => _credit = v),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        BusyButton(
          busy: _saving,
          onPressed: _save,
          label: 'Discharge and bill',
        ),
      ],
    );
  }
}

/// Pay back the deposit left after the final bill. Pops the [Admission].
class RefundDialog extends ConsumerStatefulWidget {
  const RefundDialog({super.key, required this.admission});

  final Admission admission;

  @override
  ConsumerState<RefundDialog> createState() => _RefundDialogState();
}

class _RefundDialogState extends ConsumerState<RefundDialog> {
  late final _pay = PayFields()
    ..amount.text = formatPlain(widget.admission.refundDue);
  bool _saving = false;

  @override
  void dispose() {
    _pay.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final due = widget.admission.refundDue;
    if (_pay.value <= 0 || _pay.value > due + 0.005) {
      showErrorSnackBar(context, 'Enter an amount up to ${formatMoney(due)}.');
      return;
    }
    if (_pay.accountId == null) {
      showErrorSnackBar(context, 'Choose the account the refund is paid from.');
      return;
    }
    setState(() => _saving = true);
    try {
      final a = await ref
          .read(clinicRepositoryProvider)
          .refund(widget.admission.brief.id, _pay.body());
      if (mounted) Navigator.of(context).pop(a);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Refund deposit'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Refund due ${formatMoney(widget.admission.refundDue)}.'),
            const SizedBox(height: 12),
            PayFieldsView(
              fields: _pay,
              onChanged: () => setState(() {}),
              amountLabel: 'Amount refunded',
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
      BusyButton(busy: _saving, onPressed: _save, label: 'Refund'),
    ],
  );
}

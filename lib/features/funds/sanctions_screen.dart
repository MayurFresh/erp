import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show CGate, DateField, bigButton, showSuccess;
import 'funds_models.dart';
import 'funds_repository.dart';
import 'funds_widgets.dart';

/// `/funds/sanctions`: administrative and financial sanctions against a head and fund.
class SanctionsScreen extends ConsumerStatefulWidget {
  const SanctionsScreen({super.key});

  @override
  ConsumerState<SanctionsScreen> createState() => _SanctionsScreenState();
}

class _SanctionsScreenState extends ConsumerState<SanctionsScreen> {
  String? _status;

  Future<void> _create() async {
    final warnings = await showFormDialog<List<String>>(
      context: context,
      builder: (_) => const SanctionDialog(),
    );
    if (warnings != null && mounted) {
      ref.bumpFunds();
      showSuccess(
        context,
        'Sanction saved. It needs approval before it counts.',
      );
      showWarnings(context, warnings);
    }
  }

  Future<void> _approve(Sanction s) async {
    final warnings = await showFormDialog<List<String>>(
      context: context,
      builder: (_) => ApproveDialog(sanction: s),
    );
    if (warnings != null && mounted) {
      ref.bumpFunds();
      showSuccess(context, '${s.number} approved');
      showWarnings(context, warnings);
    }
  }

  Future<void> _act(Sanction s, String action) async {
    try {
      await ref.read(fundsRepositoryProvider).sanctionAction(s.id, action);
      ref.bumpFunds();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final manage = perms.can(Perm.fundsManage);
    final entry = manage || perms.can(Perm.fundsEntry);
    return CGate(
      anyOf: const [Perm.fundsView, Perm.fundsEntry, Perm.fundsManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Sanctions',
            actions: [
              if (entry)
                FilledButton.icon(
                  key: const ValueKey('add-sanction'),
                  style: bigButton,
                  onPressed: _create,
                  icon: const Icon(Icons.add),
                  label: const Text('New sanction'),
                ),
            ],
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
            child: Wrap(
              spacing: 8,
              children: [
                for (final (v, label) in const [
                  (null, 'All'),
                  ('pending', 'Waiting'),
                  ('approved', 'Approved'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _status == v,
                    onSelected: (_) => setState(() => _status = v),
                  ),
              ],
            ),
          ),
          Expanded(
            child: AsyncValueView<List<Sanction>>(
              value: ref.watch(sanctionsProvider(_status)),
              onRetry: () => ref.invalidate(sanctionsProvider(_status)),
              data: (list) => list.isEmpty
                  ? const EmptyNote('No sanctions here.')
                  : Gutter(
                      children: [
                        for (final s in list)
                          Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                key: ValueKey('sanction-${s.id}'),
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          s.number,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
                                        ),
                                      ),
                                      StatusChip(s.status),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(s.purpose),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${s.headCode} ${s.headName}  |  ${s.fundName}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: 6),
                                  FigureRow([
                                    Figure('Amount', formatAmount(s.amount)),
                                    if (s.status == 'approved') ...[
                                      Figure('Spent', formatAmount(s.spent)),
                                      Figure(
                                        'Committed',
                                        formatAmount(s.committed),
                                      ),
                                    ],
                                  ]),
                                  if (s.status == 'approved' &&
                                      (s.adminOrderNo ?? '').isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(
                                        'Admin approval ${s.adminOrderNo}  |  Financial approval ${s.financialOrderNo}',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ),
                                  if (s.status == 'pending' ||
                                      (s.status == 'approved' && manage))
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Wrap(
                                        spacing: 8,
                                        runSpacing: 4,
                                        children: [
                                          if (s.status == 'pending' &&
                                              manage) ...[
                                            FilledButton(
                                              key: ValueKey('approve-${s.id}'),
                                              onPressed: () => _approve(s),
                                              child: const Text('Approve'),
                                            ),
                                            OutlinedButton(
                                              onPressed: () =>
                                                  _act(s, 'reject'),
                                              child: const Text('Reject'),
                                            ),
                                          ],
                                          if (entry)
                                            TextButton(
                                              onPressed: () =>
                                                  _act(s, 'cancel'),
                                              child: const Text(
                                                'Cancel sanction',
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class SanctionDialog extends ConsumerStatefulWidget {
  const SanctionDialog({super.key});

  @override
  ConsumerState<SanctionDialog> createState() => _SanctionDialogState();
}

class _SanctionDialogState extends ConsumerState<SanctionDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  String? _head;
  String? _fund;
  final _purpose = TextEditingController();
  final _amount = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _purpose.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      final r = await ref.read(fundsRepositoryProvider).createSanction({
        'headId': _head,
        'fundId': _fund,
        'purpose': _purpose.text.trim(),
        'amount': parseNumber(_amount.text),
      });
      if (mounted) Navigator.of(context).pop(warningsOf(r));
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final heads =
        (ref.watch(headsProvider(null)).value?.leaves) ?? const <HeadRow>[];
    final funds = (ref.watch(fundsListProvider).value ?? const <FundRow>[])
        .where((f) => f.status == 'active')
        .toList();
    return AlertDialog(
      title: const Text('New sanction'),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  key: const ValueKey('sanction-head'),
                  initialValue: _head,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Budget head',
                    errorText: serverError('headId'),
                  ),
                  items: [
                    for (final h in heads)
                      DropdownMenuItem(
                        value: h.id,
                        child: Text(
                          '${h.label}  (available ${formatAmount(h.available)})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  validator: (v) => v == null ? 'Choose a head' : null,
                  onChanged: (v) => setState(() => _head = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const ValueKey('sanction-fund'),
                  initialValue: _fund,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Fund or scheme',
                    errorText: serverError('fundId'),
                  ),
                  items: [
                    for (final f in funds)
                      DropdownMenuItem(
                        value: f.id,
                        child: Text(f.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  validator: (v) => v == null ? 'Choose a fund' : null,
                  onChanged: (v) => setState(() => _fund = v),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _purpose,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: 'Purpose',
                    errorText: serverError('purpose'),
                  ),
                  validator: (v) => requiredField(v, 'Purpose'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _amount,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  decoration: InputDecoration(
                    labelText: 'Amount',
                    errorText: serverError('amount'),
                  ),
                  validator: (v) => (parseNumber(v ?? '') ?? 0) <= 0
                      ? 'Enter an amount'
                      : null,
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
        BusyButton(
          busy: _saving,
          onPressed: _saving ? null : _save,
          label: 'Save',
        ),
      ],
    );
  }
}

/// Administrative and financial approval order numbers.
class ApproveDialog extends ConsumerStatefulWidget {
  const ApproveDialog({super.key, required this.sanction});

  final Sanction sanction;

  @override
  ConsumerState<ApproveDialog> createState() => _ApproveDialogState();
}

class _ApproveDialogState extends ConsumerState<ApproveDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _admin = TextEditingController();
  final _fin = TextEditingController();
  DateTime _adminDate = DateUtils.dateOnly(DateTime.now());
  DateTime _finDate = DateUtils.dateOnly(DateTime.now());
  bool _saving = false;

  @override
  void dispose() {
    _admin.dispose();
    _fin.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      final r = await ref
          .read(fundsRepositoryProvider)
          .approveSanction(widget.sanction.id, {
            'adminOrderNo': _admin.text.trim(),
            'adminOrderDate': apiDate(_adminDate),
            'financialOrderNo': _fin.text.trim(),
            'financialOrderDate': apiDate(_finDate),
          });
      if (mounted) Navigator.of(context).pop(warningsOf(r));
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Approve ${widget.sanction.number}'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${formatAmount(widget.sanction.amount)} for ${widget.sanction.purpose}',
              ),
              const SizedBox(height: 12),
              FormRow(
                minCellWidth: 200,
                children: [
                  TextFormField(
                    controller: _admin,
                    decoration: InputDecoration(
                      labelText: 'Administrative approval order no.',
                      errorText: serverError('adminOrderNo'),
                    ),
                    validator: (v) => requiredField(v, 'Order number'),
                  ),
                  DateField(
                    label: 'Date',
                    value: _adminDate,
                    onChanged: (d) => setState(() => _adminDate = d),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FormRow(
                minCellWidth: 200,
                children: [
                  TextFormField(
                    controller: _fin,
                    decoration: InputDecoration(
                      labelText: 'Financial approval order no.',
                      errorText: serverError('financialOrderNo'),
                    ),
                    validator: (v) => requiredField(v, 'Order number'),
                  ),
                  DateField(
                    label: 'Date',
                    value: _finDate,
                    onChanged: (d) => setState(() => _finDate = d),
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
      BusyButton(
        busy: _saving,
        onPressed: _saving ? null : _save,
        label: 'Approve',
      ),
    ],
  );
}

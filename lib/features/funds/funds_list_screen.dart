import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../accounts/accounts_repository.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show CGate, DateField, bigButton, showSuccess;
import 'funds_models.dart';
import 'funds_repository.dart';
import 'funds_widgets.dart';

/// `/funds/funds`: funds and schemes with their balances, grants received and the overspend rule.
class FundsListScreen extends ConsumerWidget {
  const FundsListScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [FundRow? f]) async {
    final saved = await showFormDialog<FundRow>(
      context: context,
      builder: (_) => FundDialog(fund: f),
    );
    if (saved != null && context.mounted) {
      ref.bumpFunds();
      showSuccess(context, '${saved.name} saved');
    }
  }

  Future<void> _grant(BuildContext context, WidgetRef ref, FundRow f) async {
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (_) => GrantDialog(fund: f),
    );
    if (ok == true && context.mounted) {
      ref.bumpFunds();
      showSuccess(context, 'Grant recorded');
    }
  }

  Future<void> _rule(BuildContext context, WidgetRef ref) async {
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (_) => const OverspendDialog(),
    );
    if (ok == true && context.mounted) {
      ref.bumpFunds();
      showSuccess(context, 'Rule saved');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final manage = perms.can(Perm.fundsManage);
    final entry = manage || perms.can(Perm.fundsEntry);
    return CGate(
      anyOf: const [Perm.fundsView, Perm.fundsEntry, Perm.fundsManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Funds and grants',
            actions: [
              if (manage)
                OutlinedButton(
                  style: bigButton,
                  onPressed: () => _rule(context, ref),
                  child: const Text('Overspend rule'),
                ),
              if (manage)
                FilledButton.icon(
                  key: const ValueKey('add-fund'),
                  style: bigButton,
                  onPressed: () => _edit(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('Add fund'),
                ),
            ],
          ),
          Expanded(
            child: AsyncValueView<List<FundRow>>(
              value: ref.watch(fundsListProvider),
              onRetry: () => ref.invalidate(fundsListProvider),
              data: (list) => list.isEmpty
                  ? const EmptyNote(
                      'No funds yet. Add the first grant or scheme.',
                    )
                  : Gutter(
                      children: [
                        for (final f in list)
                          Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                key: ValueKey('fund-${f.id}'),
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          f.name,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
                                        ),
                                      ),
                                      if (f.status != 'active')
                                        StatusChip(f.status),
                                    ],
                                  ),
                                  Text(
                                    [
                                      fundKinds[f.kind] ?? f.kind,
                                      if ((f.sponsor ?? '').isNotEmpty)
                                        f.sponsor!,
                                      if ((f.sanctionNo ?? '').isNotEmpty)
                                        'Order ${f.sanctionNo}',
                                    ].join('  |  '),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: 8),
                                  FigureRow([
                                    if (f.totalAmount > 0)
                                      Figure(
                                        'Sanctioned',
                                        formatAmount(f.totalAmount),
                                      ),
                                    Figure(
                                      'Received',
                                      formatAmount(f.received),
                                    ),
                                    Figure('Spent', formatAmount(f.spent)),
                                    Figure(
                                      'Balance',
                                      formatAmount(f.balance),
                                      warn: f.balance < 0,
                                    ),
                                  ]),
                                  if (f.returnUnspent)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(
                                        'Unspent balance must be returned.',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ),
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: [
                                        if (entry && f.status == 'active')
                                          FilledButton(
                                            key: ValueKey('grant-${f.id}'),
                                            onPressed: () =>
                                                _grant(context, ref, f),
                                            child: const Text('Grant received'),
                                          ),
                                        if (manage)
                                          OutlinedButton(
                                            onPressed: () =>
                                                _edit(context, ref, f),
                                            child: const Text('Edit'),
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

class FundDialog extends ConsumerStatefulWidget {
  const FundDialog({super.key, this.fund});

  final FundRow? fund;

  @override
  ConsumerState<FundDialog> createState() => _FundDialogState();
}

class _FundDialogState extends ConsumerState<FundDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.fund?.name);
  late final _sponsor = TextEditingController(text: widget.fund?.sponsor);
  late final _order = TextEditingController(text: widget.fund?.sanctionNo);
  late final _total = TextEditingController(
    text: widget.fund == null ? null : formatPlain(widget.fund!.totalAmount),
  );
  late String _kind = widget.fund?.kind ?? 'grant';
  late bool _return = widget.fund?.returnUnspent ?? false;
  late String _status = widget.fund?.status ?? 'active';
  DateTime? _orderDate;
  DateTime? _from;
  DateTime? _to;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _orderDate = DateTime.tryParse(widget.fund?.sanctionDate ?? '');
    _from = DateTime.tryParse(widget.fund?.periodFrom ?? '');
    _to = DateTime.tryParse(widget.fund?.periodTo ?? '');
  }

  @override
  void dispose() {
    for (final c in [_name, _sponsor, _order, _total]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _d(DateTime? d) => d == null ? null : apiDate(d);

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      final saved = await ref.read(fundsRepositoryProvider).saveFund(
        widget.fund?.id,
        {
          'name': _name.text.trim(),
          'kind': _kind,
          'sponsor': trimmedOrNull(_sponsor.text),
          'sanctionNo': trimmedOrNull(_order.text),
          'sanctionDate': _d(_orderDate),
          'totalAmount': parseNumber(_total.text) ?? 0,
          'periodFrom': _d(_from),
          'periodTo': _d(_to),
          'returnUnspent': _return,
          if (widget.fund != null) ...{
            'status': _status,
            'expectedUpdatedAt': widget.fund!.updatedAt,
          },
        },
      );
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.fund == null ? 'Add fund or scheme' : 'Edit fund'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Name',
                  errorText: serverError('name'),
                ),
                validator: (v) => requiredField(v, 'Name'),
              ),
              const SizedBox(height: 12),
              FormRow(
                minCellWidth: 200,
                children: [
                  DropdownButtonFormField<String>(
                    key: const ValueKey('fund-kind'),
                    initialValue: _kind,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Kind'),
                    items: [
                      for (final e in fundKinds.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => setState(() => _kind = v ?? 'grant'),
                  ),
                  TextFormField(
                    controller: _sponsor,
                    decoration: const InputDecoration(labelText: 'Sponsor'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FormRow(
                minCellWidth: 200,
                children: [
                  TextFormField(
                    controller: _order,
                    decoration: const InputDecoration(
                      labelText: 'Sanction order number',
                    ),
                  ),
                  DateField(
                    label: 'Order date',
                    value: _orderDate,
                    onChanged: (d) => setState(() => _orderDate = d),
                    onCleared: () => setState(() => _orderDate = null),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FormRow(
                minCellWidth: 200,
                children: [
                  TextFormField(
                    controller: _total,
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput()],
                    decoration: InputDecoration(
                      labelText: 'Total sanctioned amount',
                      errorText: serverError('totalAmount'),
                    ),
                  ),
                  DateField(
                    label: 'Period from',
                    value: _from,
                    onChanged: (d) => setState(() => _from = d),
                    onCleared: () => setState(() => _from = null),
                  ),
                  DateField(
                    label: 'Period to',
                    value: _to,
                    errorText: serverError('periodTo'),
                    onChanged: (d) => setState(() => _to = d),
                    onCleared: () => setState(() => _to = null),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Unspent balance must be returned'),
                value: _return,
                onChanged: (v) => setState(() => _return = v),
              ),
              if (widget.fund != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Fund is open'),
                  value: _status == 'active',
                  onChanged: (v) =>
                      setState(() => _status = v ? 'active' : 'closed'),
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

class GrantDialog extends ConsumerStatefulWidget {
  const GrantDialog({super.key, required this.fund});

  final FundRow fund;

  @override
  ConsumerState<GrantDialog> createState() => _GrantDialogState();
}

class _GrantDialogState extends ConsumerState<GrantDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _ref = TextEditingController();
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  String? _account;
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    _ref.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      await ref.read(fundsRepositoryProvider).grantReceived(widget.fund.id, {
        'amount': parseNumber(_amount.text),
        'date': apiDate(_date),
        'accountId': _account,
        'reference': trimmedOrNull(_ref.text),
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(cashBankAccountsProvider).value ?? const [];
    return AlertDialog(
      title: Text('Grant received: ${widget.fund.name}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  minCellWidth: 180,
                  children: [
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
                    DateField(
                      label: 'Date',
                      value: _date,
                      onChanged: (d) => setState(() => _date = d),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const ValueKey('grant-account'),
                  initialValue: accounts.any((a) => a.id == _account)
                      ? _account
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Received in (default: bank)',
                    errorText: serverError('accountId'),
                  ),
                  items: [
                    for (final a in accounts)
                      DropdownMenuItem(
                        value: a.id,
                        child: Text(
                          '${a.code}  ${a.name}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _account = v),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _ref,
                  decoration: const InputDecoration(
                    labelText: 'Reference (UTR or order)',
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
        BusyButton(
          busy: _saving,
          onPressed: _saving ? null : _save,
          label: 'Save',
        ),
      ],
    );
  }
}

class OverspendDialog extends ConsumerStatefulWidget {
  const OverspendDialog({super.key});

  @override
  ConsumerState<OverspendDialog> createState() => _OverspendDialogState();
}

class _OverspendDialogState extends ConsumerState<OverspendDialog> {
  String? _mode;
  bool _saving = false;

  Future<void> _save(String mode) async {
    setState(() => _saving = true);
    try {
      await ref.read(fundsRepositoryProvider).saveSettings({
        'overspendMode': mode,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = ref.watch(fundsSettingsProvider).value?.overspendMode ?? 'warn';
    final mode = _mode ?? cur;
    return AlertDialog(
      title: const Text('When spending would exceed a budget'),
      content: SizedBox(
        width: 420,
        child: RadioGroup<String>(
          groupValue: mode,
          onChanged: (v) => setState(() => _mode = v),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                value: 'warn',
                title: Text('Warn and allow'),
                subtitle: Text('The entry is saved and a warning is shown.'),
              ),
              RadioListTile<String>(
                value: 'block',
                title: Text('Block'),
                subtitle: Text(
                  'The entry is refused until the budget is increased.',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        BusyButton(
          busy: _saving,
          onPressed: _saving ? null : () => _save(mode),
          label: 'Save',
        ),
      ],
    );
  }
}

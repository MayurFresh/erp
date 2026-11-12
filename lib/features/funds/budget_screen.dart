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

/// `/funds/budget`: budget heads of a year and re-appropriation between them.
class BudgetScreen extends ConsumerStatefulWidget {
  const BudgetScreen({super.key});

  @override
  ConsumerState<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends ConsumerState<BudgetScreen> {
  late String _fy = currentFy();

  Future<void> _editHead(HeadsData data, [HeadRow? head]) async {
    final saved = await showFormDialog<HeadRow>(
      context: context,
      builder: (_) => HeadDialog(fy: _fy, all: data.data, head: head),
    );
    if (saved != null && mounted) {
      ref.bumpFunds();
      showSuccess(context, '${saved.code} saved');
    }
  }

  Future<void> _reapp(HeadsData data) async {
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (_) => ReappDialog(leaves: data.leaves),
    );
    if (ok == true && mounted) {
      ref.bumpFunds();
      showSuccess(context, 'Re-appropriation saved');
    }
  }

  Future<void> _decide(Reapp r, bool approve) async {
    try {
      await ref.read(fundsRepositoryProvider).decideReapp(r.id, approve);
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
    final heads = ref.watch(headsProvider(_fy));
    final data = heads.value;
    return CGate(
      anyOf: const [Perm.fundsView, Perm.fundsEntry, Perm.fundsManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Budget heads',
            actions: [
              FySelector(
                value: _fy,
                onChanged: (v) => setState(() => _fy = v),
                extra: data?.years ?? const [],
              ),
              if (entry && data != null)
                OutlinedButton(
                  key: const ValueKey('reappropriate'),
                  style: bigButton,
                  onPressed: () => _reapp(data),
                  child: const Text('Re-appropriate'),
                ),
              if (manage && data != null)
                FilledButton.icon(
                  key: const ValueKey('add-head'),
                  style: bigButton,
                  onPressed: () => _editHead(data),
                  icon: const Icon(Icons.add),
                  label: const Text('Add head'),
                ),
            ],
          ),
          Expanded(
            child: AsyncValueView<HeadsData>(
              value: heads,
              onRetry: () => ref.invalidate(headsProvider(_fy)),
              data: (d) => Gutter(
                children: [
                  if (d.data.isEmpty)
                    const EmptyNote(
                      'No budget heads for this year. Add a major head first.',
                    )
                  else
                    SectionCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (final h in d.data)
                            ListTile(
                              key: ValueKey('head-${h.code}'),
                              dense: true,
                              contentPadding: EdgeInsets.only(
                                left: 14.0 + h.depth * 18,
                                right: 14,
                              ),
                              onTap: manage ? () => _editHead(d, h) : null,
                              title: Text(
                                h.label,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: h.isLeaf
                                    ? null
                                    : const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                              ),
                              subtitle: Text(
                                'Budget ${formatAmount(h.budget)}  |  Spent ${formatAmount(h.actual)}'
                                '${h.committed > 0 ? '  |  Committed ${formatAmount(h.committed)}' : ''}',
                              ),
                              trailing: Text(
                                formatAmount(h.available),
                                style: TextStyle(
                                  color: h.available < 0
                                      ? Theme.of(context).colorScheme.error
                                      : null,
                                ),
                              ),
                            ),
                          const Divider(height: 1),
                          Padding(
                            padding: const EdgeInsets.all(14),
                            child: FigureRow([
                              Figure(
                                'Total budget',
                                formatAmount(d.totals.budget),
                              ),
                              Figure('Spent', formatAmount(d.totals.actual)),
                              Figure(
                                'Available',
                                formatAmount(d.totals.available),
                                warn: d.totals.available < 0,
                              ),
                            ]),
                          ),
                        ],
                      ),
                    ),
                  _ReappList(fy: _fy, manage: manage, onDecide: _decide),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReappList extends ConsumerWidget {
  const _ReappList({
    required this.fy,
    required this.manage,
    required this.onDecide,
  });

  final String fy;
  final bool manage;
  final Future<void> Function(Reapp, bool) onDecide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(reappsProvider(fy)).value ?? const <Reapp>[];
    if (list.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'Re-appropriation orders',
      child: Column(
        children: [
          for (final r in list)
            ListTile(
              key: ValueKey('reapp-${r.id}'),
              contentPadding: EdgeInsets.zero,
              title: Text('${formatAmount(r.amount)} from ${r.fromLabel}'),
              subtitle: Text(
                'to ${r.toLabel}\nOrder ${r.orderNo}, ${formatDate(r.orderDate)}. ${r.reason}',
              ),
              isThreeLine: true,
              trailing: r.status == 'pending' && manage
                  ? Wrap(
                      spacing: 4,
                      children: [
                        TextButton(
                          onPressed: () => onDecide(r, false),
                          child: const Text('Reject'),
                        ),
                        FilledButton(
                          onPressed: () => onDecide(r, true),
                          child: const Text('Approve'),
                        ),
                      ],
                    )
                  : StatusChip(r.status),
            ),
        ],
      ),
    );
  }
}

/// Add or edit a budget head. Pops the saved [HeadRow].
class HeadDialog extends ConsumerStatefulWidget {
  const HeadDialog({super.key, required this.fy, required this.all, this.head});

  final String fy;
  final List<HeadRow> all;
  final HeadRow? head;

  @override
  ConsumerState<HeadDialog> createState() => _HeadDialogState();
}

class _HeadDialogState extends ConsumerState<HeadDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late String _level = widget.head?.level ?? 'major';
  String? _parent;
  String? _account;
  late final _code = TextEditingController(text: widget.head?.code);
  late final _name = TextEditingController(text: widget.head?.name);
  late final _estimate = TextEditingController(
    text: widget.head == null || !widget.head!.isLeaf
        ? null
        : formatPlain(widget.head!.estimate),
  );
  late final _revised = TextEditingController(
    text: widget.head?.revised == null
        ? null
        : formatPlain(widget.head!.revised),
  );
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _account = widget.head?.accountId;
    _parent = widget.head?.parentId;
  }

  @override
  void dispose() {
    for (final c in [_code, _name, _estimate, _revised]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _editing => widget.head != null;
  bool get _takesAmount => _editing ? widget.head!.isLeaf : _level == 'object';

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      final body = <String, Object?>{
        'code': _code.text.trim(),
        'name': _name.text.trim(),
        if (_level == 'object' || _editing) 'accountId': _account,
        if (_takesAmount) 'budgetEstimate': parseNumber(_estimate.text) ?? 0,
        if (_takesAmount && (_editing || _revised.text.trim().isNotEmpty))
          'revisedEstimate': parseNumber(_revised.text),
        if (_editing) 'expectedUpdatedAt': widget.head!.updatedAt,
        if (!_editing) ...{
          'fy': widget.fy,
          'level': _level,
          if (_level != 'major') 'parentId': _parent,
        },
      };
      final saved = await ref
          .read(fundsRepositoryProvider)
          .saveHead(widget.head?.id, body);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final parentLevel = _level == 'minor' ? 'major' : 'minor';
    final parents = widget.all.where((h) => h.level == parentLevel).toList();
    final accounts = ref.watch(expenseHeadsProvider).value ?? const [];
    return AlertDialog(
      title: Text(_editing ? 'Edit head' : 'Add budget head'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_editing) ...[
                  DropdownButtonFormField<String>(
                    key: const ValueKey('head-level'),
                    initialValue: _level,
                    decoration: const InputDecoration(labelText: 'Level'),
                    items: const [
                      DropdownMenuItem(
                        value: 'major',
                        child: Text('Major head'),
                      ),
                      DropdownMenuItem(
                        value: 'minor',
                        child: Text('Minor head'),
                      ),
                      DropdownMenuItem(
                        value: 'object',
                        child: Text('Object head (holds the budget)'),
                      ),
                    ],
                    onChanged: (v) => setState(() {
                      _level = v ?? 'major';
                      _parent = null;
                    }),
                  ),
                  const SizedBox(height: 12),
                  if (_level != 'major') ...[
                    DropdownButtonFormField<String>(
                      key: ValueKey('head-parent-$_level'),
                      initialValue: _parent,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Under ($parentLevel head)',
                        errorText: serverError('parentId'),
                      ),
                      items: [
                        for (final p in parents)
                          DropdownMenuItem(
                            value: p.id,
                            child: Text(
                              p.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      validator: (v) =>
                          v == null ? 'Choose a $parentLevel head' : null,
                      onChanged: (v) => setState(() => _parent = v),
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
                FormRow(
                  minCellWidth: 160,
                  children: [
                    TextFormField(
                      controller: _code,
                      decoration: InputDecoration(
                        labelText: 'Head code',
                        errorText: serverError('code'),
                      ),
                      validator: (v) => requiredField(v, 'Head code'),
                    ),
                    TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: 'Name',
                        errorText: serverError('name'),
                      ),
                      validator: (v) => requiredField(v, 'Name'),
                    ),
                  ],
                ),
                if (_level == 'object' ||
                    (_editing && widget.head!.isLeaf)) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const ValueKey('head-account'),
                    initialValue: accounts.any((a) => a.id == _account)
                        ? _account
                        : null,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Expense account',
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
                ],
                if (_takesAmount) ...[
                  const SizedBox(height: 12),
                  FormRow(
                    minCellWidth: 160,
                    children: [
                      TextFormField(
                        controller: _estimate,
                        keyboardType: decimalKeyboard,
                        inputFormatters: [decimalInput()],
                        decoration: InputDecoration(
                          labelText: 'Budget estimate',
                          errorText: serverError('budgetEstimate'),
                        ),
                      ),
                      TextFormField(
                        controller: _revised,
                        keyboardType: decimalKeyboard,
                        inputFormatters: [decimalInput()],
                        decoration: InputDecoration(
                          labelText: 'Revised estimate',
                          errorText: serverError('revisedEstimate'),
                        ),
                      ),
                    ],
                  ),
                ] else if (_editing)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'This head adds up the heads under it. Change the amounts on the lowest heads.',
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

/// Move budget from one lowest head to another with an order number and reason.
class ReappDialog extends ConsumerStatefulWidget {
  const ReappDialog({super.key, required this.leaves});

  final List<HeadRow> leaves;

  @override
  ConsumerState<ReappDialog> createState() => _ReappDialogState();
}

class _ReappDialogState extends ConsumerState<ReappDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  String? _from;
  String? _to;
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  final _amount = TextEditingController();
  final _order = TextEditingController();
  final _reason = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_amount, _order, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      await ref.read(fundsRepositoryProvider).createReapp({
        'fromHeadId': _from,
        'toHeadId': _to,
        'amount': parseNumber(_amount.text),
        'orderNo': _order.text.trim(),
        'orderDate': apiDate(_date),
        'reason': _reason.text.trim(),
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
    DropdownButtonFormField<String> pick(
      String label,
      String key,
      String? value,
      ValueChanged<String?> on, {
      bool showAvailable = false,
    }) => DropdownButtonFormField<String>(
      key: ValueKey(key),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        errorText: serverError(key == 'from' ? 'fromHeadId' : 'toHeadId'),
      ),
      items: [
        for (final h in widget.leaves)
          DropdownMenuItem(
            value: h.id,
            child: Text(
              showAvailable
                  ? '${h.label}  (available ${formatAmount(h.available)})'
                  : h.label,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      validator: (v) => v == null ? 'Choose a head' : null,
      onChanged: on,
    );
    return AlertDialog(
      title: const Text('Re-appropriate budget'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                pick(
                  'From head',
                  'from',
                  _from,
                  (v) => setState(() => _from = v),
                  showAvailable: true,
                ),
                const SizedBox(height: 12),
                pick('To head', 'to', _to, (v) => setState(() => _to = v)),
                const SizedBox(height: 12),
                FormRow(
                  minCellWidth: 160,
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
                    TextFormField(
                      controller: _order,
                      decoration: InputDecoration(
                        labelText: 'Order number',
                        errorText: serverError('orderNo'),
                      ),
                      validator: (v) => requiredField(v, 'Order number'),
                    ),
                    DateField(
                      label: 'Order date',
                      value: _date,
                      onChanged: (d) => setState(() => _date = d),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _reason,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: 'Reason',
                    errorText: serverError('reason'),
                  ),
                  validator: (v) => requiredField(v, 'Reason'),
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

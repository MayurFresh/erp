import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../widgets/form_support.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../data/subcontract_repository.dart';
import '../../../widgets/busy.dart';

/// Pays a labour advance to a worker from a cash or bank account.
class AdvanceFormScreen extends ConsumerStatefulWidget {
  const AdvanceFormScreen({super.key, this.initialWorkerId});

  final String? initialWorkerId;

  @override
  ConsumerState<AdvanceFormScreen> createState() => _AdvanceFormScreenState();
}

class _AdvanceFormScreenState extends ConsumerState<AdvanceFormScreen>
    with DirtyTracking<AdvanceFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _notes = TextEditingController();
  String? _workerId;
  String? _accountId;
  DateTime _date = today();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _workerId = widget.initialWorkerId;
  }

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final advance = await ref
          .read(subcontractRepositoryProvider)
          .createLabourAdvance(
            workerId: _workerId!,
            amount: double.parse(_amount.text.trim()),
            paidFromAccountId: _accountId!,
            date: apiDate(_date),
            notes: trimmedOrNull(_notes.text),
          );
      ref.bumpC(const [CKind.labourAdvances, CKind.workers]);
      if (!mounted) return;
      showSuccess(context, '${advance.number} paid');
      markSaved();
      context.go('/labour-advances/${advance.id}');
    } catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final workers = ref.watch(workersLookupProvider);
    final accounts = ref.watch(payAccountsProvider);
    final options = [
      for (final w in workers.value ?? const [])
        if (w.isActive) w,
    ];
    final accountOptions = accounts.value ?? const [];
    if (_accountId == null && accountOptions.isNotEmpty) {
      _accountId = accountOptions.first.id;
    }
    final selected = options.where((w) => w.id == _workerId).firstOrNull;
    return CGate(
      anyOf: const [CPerm.wagesPay],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'New labour advance'),
          Expanded(
            child: BottomBarLayout(
              bar: Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    style: bigOutlinedButton,
                    onPressed: _busy
                        ? null
                        : () => context.go('/labour-advances'),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    style: bigButton,
                    onPressed: _busy ? null : _save,
                    child: const Text('Pay advance'),
                  ),
                ],
              ),
              child: CPage(
                maxWidth: 680,
                children: [
                  Form(
                    key: _formKey,
                    onChanged: markDirty,
                    child: SectionCard(
                      title: 'Advance',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DropdownButtonFormField<String>(
                            key: ValueKey(
                              'worker-$_workerId-${options.length}',
                            ),
                            initialValue: options.any((w) => w.id == _workerId)
                                ? _workerId
                                : null,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: 'Worker',
                              prefixIcon: const Icon(
                                Icons.engineering_outlined,
                              ),
                              helperText: selected == null
                                  ? null
                                  : 'Open advances: '
                                        '${formatMoney(selected.advanceBalance)}'
                                        '${selected.siteName == null ? '' : ' · ${selected.siteName}'}',
                            ),
                            items: [
                              for (final w in options)
                                DropdownMenuItem(
                                  value: w.id,
                                  child: Text(
                                    w.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (v) => setState(() => _workerId = v),
                            validator: (v) =>
                                v == null ? 'Choose a worker' : null,
                          ),
                          const SizedBox(height: 16),
                          FormRow(
                            children: [
                              TextFormField(
                                controller: _amount,
                                keyboardType: decimalKeyboard,
                                inputFormatters: [decimalInput()],
                                decoration: const InputDecoration(
                                  labelText: 'Amount',
                                  prefixText: '₹ ',
                                ),
                                validator: (v) => requiredNumber(
                                  v,
                                  label: 'Amount',
                                  min: 0.01,
                                ),
                              ),
                              DateField(
                                label: 'Date',
                                value: _date,
                                lastDate: today(),
                                onChanged: (v) => setState(() => _date = v),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            key: ValueKey(
                              'acct-$_accountId-${accountOptions.length}',
                            ),
                            initialValue: _accountId,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Pay from (cash or bank)',
                            ),
                            items: [
                              for (final a in accountOptions)
                                DropdownMenuItem(
                                  value: a.id,
                                  child: Text(
                                    a.displayName,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (v) => setState(() => _accountId = v),
                            validator: (v) =>
                                v == null ? 'Choose an account' : null,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _notes,
                            maxLength: 300,
                            maxLines: 2,
                            decoration: const InputDecoration(
                              labelText: 'Notes (optional)',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SectionCard(
                    title: 'How it is recovered',
                    child: Text(
                      'Wage sheets recover the advance automatically, oldest '
                      'advance first. Each worker’s recovery is capped at the '
                      'lower of the open balance and 50% of gross wages.',
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

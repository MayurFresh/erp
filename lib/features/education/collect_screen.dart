import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../accounts/accounts_repository.dart';
import 'education_models.dart';
import 'education_repository.dart';
import 'education_widgets.dart';

/// `/education/collect`: find a student, see what is due and take a payment.
/// A part payment clears the oldest instalment first.
class CollectScreen extends ConsumerStatefulWidget {
  const CollectScreen({super.key, this.studentId});

  final String? studentId;

  @override
  ConsumerState<CollectScreen> createState() => _CollectScreenState();
}

class _CollectScreenState extends ConsumerState<CollectScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  late String? _studentId = widget.studentId;
  StudentBrief? _picked;
  String _mode = 'cash';
  String? _accountId;
  bool _saving = false;
  String? _filledFor;

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  void _pick(StudentBrief s) => setState(() {
    _picked = s;
    _studentId = s.id;
    _filledFor = null;
    _amount.clear();
  });

  Future<void> _collect(Ledger ledger, String name) async {
    if (_saving || !validateAndReveal(_formKey)) return;
    final amount = parseNumber(_amount.text) ?? 0;
    if (amount > ledger.due + 0.004) {
      showErrorSnackBar(context, 'Only ${formatMoney(ledger.due)} is due.');
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await ref.read(eduRepositoryProvider).collect(_studentId!, {
        'accountId': _accountId,
        'mode': _mode,
        'amount': amount,
        'reference': trimmedOrNull(_reference.text),
      });
      if (!mounted) return;
      ref.bumpEdu(const [EduKind.fees], money: true);
      setState(() {
        _saving = false;
        _filledFor = null;
        _amount.clear();
        _reference.clear();
      });
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Fee received'),
          content: Text(
            '${formatMoney(amount)} received from $name.\n'
            '${r.balance > 0.004 ? 'Balance due ${formatMoney(r.balance)}.' : 'No balance due.'}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(),
              child: const Text('Done'),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(dialog).pop();
                printFeeReceipt(context, ref, r.paymentId);
              },
              icon: const Icon(Icons.print_outlined),
              label: const Text('Print receipt'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = ref.watch(cashBankAccountsProvider).value ?? const [];
    _accountId ??= accounts.isEmpty ? null : accounts.first.id;
    final id = _studentId;
    final student = id == null ? null : ref.watch(eduStudentProvider(id));
    final ledger = id == null ? null : ref.watch(eduLedgerProvider(id));
    final name = _picked?.name ?? student?.value?.name ?? '';
    return CGate(
      anyOf: const [Perm.educationFees, Perm.educationManage],
      child: FormPage(
        maxWidth: 720,
        children: [
          Text('Collect fee', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          StudentPickerField(
            label: 'Student',
            value: _picked ?? (student?.value?.brief),
            onChanged: _pick,
          ),
          const SizedBox(height: 16),
          if (id != null && ledger != null)
            AsyncValueView<Ledger>(
              value: ledger,
              onRetry: () => ref.invalidate(eduLedgerProvider(id)),
              data: (l) {
                if (_filledFor != id && l.due > 0.004) {
                  _filledFor = id;
                  _amount.text = formatPlain(l.due);
                }
                final open = [
                  for (final b in l.bills)
                    if (b.due > 0.004) b,
                ];
                return Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SectionCard(
                        title: 'Dues',
                        child: open.isEmpty
                            ? const Text('Nothing is due for this student.')
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final b in open)
                                    ListTile(
                                      key: ValueKey('due-${b.number}'),
                                      contentPadding: EdgeInsets.zero,
                                      dense: true,
                                      title: Text('${b.label}  ${b.number}'),
                                      subtitle: Text(
                                        'Due ${formatDate(b.dueDate)}',
                                      ),
                                      trailing: Text(
                                        formatMoney(b.due),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: b.overdue
                                              ? theme.colorScheme.error
                                              : null,
                                        ),
                                      ),
                                    ),
                                  const Divider(),
                                  Text(
                                    'Total due ${formatMoney(l.due)}',
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ],
                              ),
                      ),
                      if (open.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        FormRow(
                          children: [
                            TextFormField(
                              controller: _amount,
                              keyboardType: decimalKeyboard,
                              inputFormatters: [decimalInput()],
                              decoration: const InputDecoration(
                                labelText: 'Amount received',
                                helperText: 'A part payment is fine',
                              ),
                              validator: (v) {
                                final n = parseNumber(v ?? '');
                                if (n == null || n <= 0) {
                                  return 'Enter an amount';
                                }
                                if (n > l.due + 0.004) {
                                  return 'More than is due';
                                }
                                return null;
                              },
                            ),
                            DropdownButtonFormField<String>(
                              initialValue: _mode,
                              decoration: const InputDecoration(
                                labelText: 'Mode',
                              ),
                              items: modeItems,
                              onChanged: (v) =>
                                  setState(() => _mode = v ?? 'cash'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        FormRow(
                          children: [
                            DropdownButtonFormField<String>(
                              initialValue: _accountId,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Deposit to',
                              ),
                              validator: (v) =>
                                  v == null ? 'Choose an account' : null,
                              items: [
                                for (final a in accounts)
                                  DropdownMenuItem(
                                    value: a.id,
                                    child: Text(
                                      a.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) => setState(() => _accountId = v),
                            ),
                            TextFormField(
                              controller: _reference,
                              decoration: const InputDecoration(
                                labelText: 'Reference',
                                hintText: 'UPI id or cheque no.',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.icon(
                            style: bigButton,
                            onPressed: _saving ? null : () => _collect(l, name),
                            icon: _saving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.check),
                            label: const Text('Receive payment'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => context.go('/education/students/$id'),
                        child: const Text('Open student file'),
                      ),
                    ],
                  ),
                );
              },
            )
          else
            const Text(
              'Search for a student by name, admission number or parent phone.',
            ),
        ],
      ),
    );
  }
}

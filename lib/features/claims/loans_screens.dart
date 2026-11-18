import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/key_value_list.dart';
import '../../widgets/layout.dart';
import '../../widgets/money_text.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import 'claims_models.dart';
import 'claims_repository.dart';
import 'claims_widgets.dart';

/// `/loans`
class LoansScreen extends ConsumerWidget {
  const LoansScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(loansListProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Advances and loans',
          actions: [
            FilledButton.icon(
              onPressed: () => context.go('/loans/new'),
              icon: const Icon(Icons.add),
              label: const Text('New advance or loan'),
            ),
          ],
        ),
        Expanded(
          child: async.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(loansListProvider)),
            data: (loans) => loans.isEmpty
                ? const EmptyView(message: 'No advances or loans yet.')
                : ListView(
                    padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
                    children: [
                      for (final l in loans)
                        Card(
                          margin: const EdgeInsets.only(bottom: Space.sm),
                          child: ListTile(
                            minVerticalPadding: Space.md,
                            title: Text('${l.employeeName}: ${l.kindLabel.toLowerCase()} ${l.number}'),
                            subtitle: Wrap(
                              spacing: Space.sm,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                StatusChip(l.status),
                                Text('Left to recover ${formatMoney(l.outstanding)}'),
                              ],
                            ),
                            trailing: MoneyText(l.amount),
                            onTap: () => context.go('/loans/${l.id}'),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// `/loans/new`
class LoanFormScreen extends ConsumerStatefulWidget {
  const LoanFormScreen({super.key});

  @override
  ConsumerState<LoanFormScreen> createState() => _LoanFormState();
}

class _LoanFormState extends ConsumerState<LoanFormScreen> {
  final _amount = TextEditingController();
  final _emi = TextEditingController();
  final _rate = TextEditingController();
  final _purpose = TextEditingController();
  String? _employee;
  String? _account;
  String _kind = 'advance';
  DateTime _start = DateTime(DateTime.now().year, DateTime.now().month + 1);
  bool _busy = false;
  String? _error;
  List<(String, String)> _employees = const [];
  List<(String, String)> _accounts = const [];

  @override
  void initState() {
    super.initState();
    final repo = ref.read(claimsRepositoryProvider);
    repo.employees().then((v) => mounted ? setState(() => _employees = v) : null);
    repo.cashAccounts().then((v) => mounted ? setState(() => _accounts = v) : null);
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.trim());
    final emi = double.tryParse(_emi.text.trim());
    if (_employee == null || amount == null || amount <= 0 || emi == null || emi <= 0 || _purpose.text.trim().length < 2) {
      setState(() => _error = 'Choose the employee and fill in the purpose, amount and monthly instalment.');
      return;
    }
    final Json body = {
      'employeeId': _employee,
      'kind': _kind,
      'purpose': _purpose.text.trim(),
      'amount': amount,
      'instalment': emi,
      'interestRate': double.tryParse(_rate.text.trim()) ?? 0,
      'startMonth': '${_start.year}-${_start.month.toString().padLeft(2, '0')}',
      if (_account != null) 'accountId': _account,
    };
    setState(() { _busy = true; _error = null; });
    Loan? made;
    final ok = await guarded(context, () async => made = await ref.read(claimsRepositoryProvider).createLoan(body));
    if (!mounted) return;
    if (ok) {
      ref.read(claimsRevisionProvider.notifier).bump();
      context.go('/loans/${made!.id}');
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final big = _kind == 'loan' && (double.tryParse(_amount.text) ?? 0) > 20000;
    return FormPage(
      bottomBar: FormActionBar(children: [
        TextButton(onPressed: _busy ? null : () => context.go('/loans'), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Give and record payment')),
      ]),
      children: [
        const PageHeader(title: 'New advance or loan'),
        FormRow(children: [
          DropdownButtonFormField<String>(
            initialValue: _employee,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Employee'),
            items: [for (final e in _employees) DropdownMenuItem(value: e.$1, child: Text(e.$2))],
            onChanged: (v) => setState(() => _employee = v),
          ),
          DropdownButtonFormField<String>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: 'Type'),
            items: const [
              DropdownMenuItem(value: 'advance', child: Text('Salary advance')),
              DropdownMenuItem(value: 'loan', child: Text('Loan')),
            ],
            onChanged: (v) => setState(() => _kind = v ?? 'advance'),
          ),
          TextField(controller: _purpose, decoration: const InputDecoration(labelText: 'Purpose')),
          TextField(
            controller: _amount,
            onChanged: (_) => setState(() {}),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount'),
          ),
          TextField(
            controller: _emi,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Monthly instalment'),
          ),
          TextField(
            controller: _rate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Yearly interest percent (blank for none)'),
          ),
          InputDecorator(
            decoration: const InputDecoration(labelText: 'Recovery starts with payroll of'),
            child: InkWell(
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: _start,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(DateTime.now().year + 5),
                );
                if (d != null) setState(() => _start = DateTime(d.year, d.month));
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.sm),
                child: Text('${_start.month.toString().padLeft(2, '0')}/${_start.year}'),
              ),
            ),
          ),
          DropdownButtonFormField<String>(
            initialValue: _account,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Paid from (default: bank)'),
            items: [for (final a in _accounts) DropdownMenuItem(value: a.$1, child: Text(a.$2))],
            onChanged: (v) => setState(() => _account = v),
          ),
        ]),
        if (big)
          Padding(
            padding: const EdgeInsets.only(top: Space.md),
            child: Text(
              'A loan above 20,000 may be a taxable perquisite for the employee. '
              'Tax treatment is not confirmed here; it is marked for CA review.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.md),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
      ],
    );
  }
}

/// `/loans/:id`: figures, schedule and pause, resume or foreclose.
class LoanDetailScreen extends ConsumerWidget {
  const LoanDetailScreen({super.key, required this.loanId});

  final String loanId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(loanProvider(loanId));
    final repo = ref.read(claimsRepositoryProvider);
    void bump() => ref.read(claimsRevisionProvider.notifier).bump();
    return async.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(loanProvider(loanId))),
      data: (l) => ListView(
        padding: EdgeInsets.symmetric(horizontal: pageGutter(context), vertical: Space.md),
        children: [
          PageHeader(
            title: '${l.kindLabel} ${l.number}',
            subtitle: l.employeeName,
            actions: [
              if (l.status == 'active')
                OutlinedButton(
                  onPressed: () async { if (await guarded(context, () => repo.loanAction(l.id, 'pause'))) bump(); },
                  child: const Text('Pause recovery'),
                ),
              if (l.status == 'paused')
                OutlinedButton(
                  onPressed: () async { if (await guarded(context, () => repo.loanAction(l.id, 'resume'))) bump(); },
                  child: const Text('Resume recovery'),
                ),
              if (l.status == 'active' || l.status == 'paused')
                OutlinedButton(
                  onPressed: () async {
                    final accounts = await repo.cashAccounts();
                    if (!context.mounted) return;
                    final id = await pickAccount(context, accounts);
                    if (id == null || !context.mounted) return;
                    final quote = await repo.foreclosureQuote(l.id);
                    if (!context.mounted) return;
                    if (!await confirmForeclosure(context, quote)) return;
                    if (!context.mounted) return;
                    if (await guarded(context, () => repo.loanAction(l.id, 'foreclose', {'accountId': id, 'payDate': quote['payDate']}))) bump();
                  },
                  child: const Text('Foreclose'),
                ),
            ],
          ),
          SectionCard(
            child: KeyValueList(items: [
              KeyValue('Status', '', widget: Align(alignment: Alignment.centerLeft, child: StatusChip(l.status))),
              KeyValue('Purpose', l.purpose),
              KeyValue('Amount given', formatMoney(l.amount)),
              KeyValue('Monthly instalment', formatMoney(l.instalment)),
              if (l.interestRate > 0) KeyValue('Yearly interest', '${l.interestRate}%'),
              KeyValue('Left to recover', formatMoney(l.outstanding)),
              if (l.nextDueMonth != null) KeyValue('Next recovery', l.nextDueMonth!),
            ]),
          ),
          if (l.perquisiteNote != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.md),
              child: Text(l.perquisiteNote!, style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: Space.md),
          Text('Schedule', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Space.sm),
          for (final r in l.schedule)
            ListTile(
              dense: true,
              title: Text('${r.seq}. ${r.dueMonth}'),
              subtitle: Text(
                'Principal ${formatMoney(r.principal)}, interest ${formatMoney(r.interest)}'
                '${r.paidAmount > 0 ? ', ${formatMoney(r.paidAmount)} already recovered' : ''}',
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [MoneyText(r.amount), Text(r.status.replaceAll('_', ' '), style: Theme.of(context).textTheme.bodySmall)],
              ),
            ),
        ],
      ),
    );
  }
}

/// Shows what closing the loan costs, split into principal and interest to the payment date. True when accepted.
Future<bool> confirmForeclosure(BuildContext context, Map<String, Object?> q) async {
  Widget row(String label, Object? v, {bool bold = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null))),
        MoneyText(asDouble(v)),
      ],
    ),
  );
  return await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Foreclose on ${formatDate(q['payDate'])}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              row('Principal', q['principal']),
              row('Interest to date', q['interest']),
              const Divider(),
              row('To collect', q['total'], bold: true),
              const SizedBox(height: Space.sm),
              Text(
                'Interest is worked out on the reducing balance up to this date. Later instalments are cancelled.',
                style: Theme.of(c).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Foreclose')),
          ],
        ),
      ) ??
      false;
}

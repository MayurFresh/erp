import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../accounts/account_model.dart';
import '../accounts/accounts_repository.dart';
import '../documents/document_widgets.dart';
import '../documents/line_editor.dart';
import '../items/item_model.dart';
import '../locations/location_filter.dart';
import '../locations/locations_repository.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'expense_model.dart';
import 'expenses_repository.dart';

/// `POST /expenses`: an expense head, an amount before GST and the cash or
/// bank account it was paid from. GST shown here is an estimate.
class ExpenseCreateScreen extends ConsumerStatefulWidget {
  const ExpenseCreateScreen({super.key});

  @override
  ConsumerState<ExpenseCreateScreen> createState() =>
      _ExpenseCreateScreenState();
}

class _ExpenseCreateScreenState extends ConsumerState<ExpenseCreateScreen>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _amount = TextEditingController();
  String? _locationId;
  String? _accountId;
  String? _paidFromId;
  double _gstRate = 0;
  Party? _vendor;
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  bool _saving = false;
  Object? _error;

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _pickVendor() async {
    final vendor = await pickParty(context, ref, type: PartyType.vendor);
    if (vendor != null) setState(() => _vendor = vendor);
  }

  Future<void> _pickDate() async {
    final picked = await pickDocDate(context, _date);
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    setState(() {
      serverErrors = const {};
      _error = null;
    });
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final expense = await ref
          .read(expensesRepositoryProvider)
          .create(
            ExpenseDraft(
              expenseDate: apiDate(_date),
              locationId: _locationId!,
              accountId: _accountId!,
              description: _description.text.trim(),
              amount: parseNumber(_amount.text)!,
              gstRate: _gstRate,
              partyId: _vendor?.id,
              paidFromAccountId: _paidFromId!,
            ),
          );
      ref.bump(const [DataKind.expenses, DataKind.accounts]);
      if (!mounted) return;
      showInfoSnackBar(context, 'Expense ${expense.number} saved');
      context.go('/expenses/${expense.id}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _accountDropdown({
    required AsyncValue<List<Account>> accounts,
    required String label,
    required String field,
    required String? value,
    required ValueChanged<String?> onChanged,
    required VoidCallback onReload,
  }) {
    final list = accounts.value ?? const <Account>[];
    return DropdownButtonFormField<String>(
      initialValue: list.any((a) => a.id == value) ? value : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        helperText: accounts.isLoading && !accounts.hasValue
            ? 'Loading…'
            : null,
        suffixIcon: accounts.hasError
            ? IconButton(
                tooltip: 'Reload',
                icon: const Icon(Icons.refresh),
                onPressed: onReload,
              )
            : null,
      ),
      forceErrorText:
          serverError(field) ??
          (accounts.hasError ? 'Could not load accounts' : null),
      items: [
        for (final account in list)
          DropdownMenuItem(
            value: account.id,
            child: Text(account.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) {
        clearServerError(field);
        onChanged(v);
      },
      validator: (v) => v == null ? '$label is required' : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final locations = ref.watch(locationsLookupProvider).value;
    if (_locationId == null && locations != null) {
      final active = locations.where((l) => l.isActive).toList();
      if (active.length == 1) _locationId = active.single.id;
    }
    final heads = ref.watch(expenseHeadsProvider);
    final cashBank = ref.watch(cashBankAccountsProvider);
    if (_paidFromId == null && (cashBank.value?.isNotEmpty ?? false)) {
      _paidFromId =
          cashBank.value!.where((a) => a.subtype == 'cash').firstOrNull?.id ??
          cashBank.value!.first.id;
    }

    // Intra-state when there is no vendor or the vendor is in the
    // location's state (the server decides; this is only an estimate).
    final locationState = locations
        ?.where((l) => l.id == _locationId)
        .firstOrNull
        ?.stateCode;
    final vendorState = _vendor?.stateCode;
    final inter =
        vendorState != null &&
        locationState != null &&
        vendorState != locationState;
    final amount = parseNumber(_amount.text) ?? 0;
    final tax = estimateExpenseTax(amount, _gstRate, interState: inter);
    final rates = {...gstRates, _gstRate}.toList()..sort();

    return Form(
      key: _formKey,
      child: FormPage(
        children: [
          Text('New expense', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  children: [
                    LocationField(
                      value: _locationId,
                      errorText: serverError('locationId'),
                      onChanged: (v) {
                        clearServerError('locationId');
                        setState(() => _locationId = v);
                      },
                    ),
                    PickerField(
                      label: 'Date',
                      value: formatDate(_date),
                      icon: Icons.calendar_today_outlined,
                      errorText: serverError('expenseDate'),
                      onTap: _pickDate,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    _accountDropdown(
                      accounts: heads,
                      label: 'Expense head',
                      field: 'accountId',
                      value: _accountId,
                      onChanged: (v) => setState(() => _accountId = v),
                      onReload: () => ref.invalidate(expenseHeadsProvider),
                    ),
                    _accountDropdown(
                      accounts: cashBank,
                      label: 'Paid from',
                      field: 'paidFromAccountId',
                      value: _paidFromId,
                      onChanged: (v) => setState(() => _paidFromId = v),
                      onReload: () => ref.invalidate(cashBankAccountsProvider),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    hintText: 'e.g. Diesel for generator',
                  ),
                  forceErrorText: serverError('description'),
                  onChanged: (_) => clearServerError('description'),
                  validator: (v) => requiredField(v, 'Description'),
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _amount,
                      decoration: const InputDecoration(
                        labelText: 'Amount before GST',
                        prefixText: '₹ ',
                      ),
                      keyboardType: decimalKeyboard,
                      inputFormatters: [decimalInput()],
                      forceErrorText: serverError('amount'),
                      onChanged: (_) {
                        clearServerError('amount');
                        setState(() {});
                      },
                      validator: (v) {
                        final error = requiredNumber(v, label: 'Amount');
                        if (error != null) return error;
                        return parseNumber(v!)! > 0
                            ? null
                            : 'Must be more than 0';
                      },
                    ),
                    DropdownButtonFormField<double>(
                      initialValue: _gstRate,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'GST rate'),
                      forceErrorText: serverError('gstRate'),
                      items: [
                        for (final rate in rates)
                          DropdownMenuItem(
                            value: rate,
                            child: Text(formatPercent(rate)),
                          ),
                      ],
                      onChanged: (v) => setState(() => _gstRate = v ?? 0),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                PickerField(
                  label: 'Vendor (optional, for GST input credit)',
                  value: _vendor?.name,
                  onTap: _pickVendor,
                  errorText: serverError('partyId'),
                ),
                if (_vendor != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() => _vendor = null),
                      icon: const Icon(Icons.clear),
                      label: const Text('Remove vendor'),
                    ),
                  ),
              ],
            ),
          ),
          SectionCard(
            title: 'Amount',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AmountRow('Amount', amount),
                if (inter)
                  AmountRow('IGST', tax.igst)
                else ...[
                  AmountRow('CGST', tax.cgst),
                  AmountRow('SGST', tax.sgst),
                ],
                const Divider(),
                AmountRow('Total paid', tax.total, emphasize: true),
                Text(
                  'Estimated here; the server calculates the final GST.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            ApiErrorBox(error: _error!, subject: 'the expense'),
            const SizedBox(height: 16),
          ],
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _saving ? null : () => context.go('/expenses'),
                child: const Text('Cancel'),
              ),
              BusyButton(
                busy: _saving,
                onPressed: _save,
                label: 'Save expense',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

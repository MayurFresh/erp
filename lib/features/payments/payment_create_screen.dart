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
import '../parties/parties_repository.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'allocation.dart';
import 'payment_model.dart';
import 'payments_repository.dart';

/// Records a receipt or a payment and allocates it to open documents.
class PaymentCreateScreen extends ConsumerStatefulWidget {
  const PaymentCreateScreen({
    super.key,
    required this.kind,
    this.initialPartyId,
    this.initialDocId,
    this.initialAmount,
  });

  final PaymentKind kind;
  final String? initialPartyId;

  /// Invoice or bill to settle first (e.g. "Record receipt" on an invoice).
  final String? initialDocId;
  final String? initialAmount;

  @override
  ConsumerState<PaymentCreateScreen> createState() =>
      _PaymentCreateScreenState();
}

class _PaymentCreateScreenState extends ConsumerState<PaymentCreateScreen>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount = TextEditingController(
    text: widget.initialAmount,
  );
  final _reference = TextEditingController();
  final _notes = TextEditingController();
  Party? _party;
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  PaymentMode _mode = PaymentMode.cash;
  String? _accountId;
  bool _accountTouched = false;

  List<OpenDoc>? _docs;
  Object? _docsError;
  bool _docsLoading = false;
  int _docsGeneration = 0;
  final Map<String, TextEditingController> _alloc = {};
  bool _allocTouched = false;
  late final String? _preferredDocId = widget.initialDocId;

  bool _saving = false;
  Object? _saveError;

  PaymentKind get _kind => widget.kind;

  @override
  void initState() {
    super.initState();
    final partyId = widget.initialPartyId;
    if (partyId != null) _loadParty(partyId);
  }

  @override
  void dispose() {
    for (final c in [_amount, _reference, _notes, ..._alloc.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadParty(String id) async {
    try {
      final party = await ref.read(partiesRepositoryProvider).get(id);
      if (!mounted) return;
      setState(() => _party = party);
      _loadDocs(party.id);
    } catch (_) {
      // The user can still pick the party by hand.
    }
  }

  double get _amountValue => parseNumber(_amount.text) ?? 0;

  Map<String, double> get _allocations => {
    for (final MapEntry(:key, value: c) in _alloc.entries)
      if ((parseNumber(c.text) ?? 0) > 0) key: parseNumber(c.text)!,
  };

  Future<void> _loadDocs(String partyId) async {
    final generation = ++_docsGeneration;
    setState(() {
      _docsLoading = true;
      _docsError = null;
      _docs = null;
      for (final c in _alloc.values) {
        c.dispose();
      }
      _alloc.clear();
    });
    try {
      final outstanding = await ref
          .read(paymentsRepositoryProvider)
          .outstanding(partyId);
      if (!mounted || generation != _docsGeneration) return;
      final docs = outstanding.docsFor(_kind);
      setState(() {
        _docs = docs;
        _docsLoading = false;
        for (final doc in docs) {
          _alloc[doc.id] = TextEditingController();
        }
        _allocTouched = false;
        _autoFill(preferred: _preferredDocId);
      });
    } catch (e) {
      if (!mounted || generation != _docsGeneration) return;
      setState(() {
        _docsError = e;
        _docsLoading = false;
      });
    }
  }

  /// Fills allocations oldest first up to the amount.
  void _autoFill({String? preferred}) {
    final docs = _docs;
    if (docs == null) return;
    final result = autoAllocate(docs, _amountValue, firstId: preferred);
    for (final doc in docs) {
      final value = result[doc.id];
      _alloc[doc.id]!.text = value == null ? '' : formatPlain(value);
    }
  }

  void _amountChanged(String _) {
    clearServerError('amount');
    setState(() {
      if (!_allocTouched) _autoFill(preferred: _preferredDocId);
    });
  }

  Future<void> _pickParty() async {
    final party = await pickParty(
      context,
      ref,
      type: _kind == PaymentKind.receipt
          ? PartyType.customer
          : PartyType.vendor,
    );
    if (party == null) return;
    clearServerError('partyId');
    setState(() => _party = party);
    _loadDocs(party.id);
  }

  Future<void> _pickDate() async {
    final picked = await pickDocDate(context, _date);
    if (picked != null) setState(() => _date = picked);
  }

  String? _defaultAccount(List<Account> accounts) {
    final wanted = _mode == PaymentMode.cash ? 'cash' : 'bank';
    return accounts.where((a) => a.subtype == wanted).firstOrNull?.id ??
        accounts.firstOrNull?.id;
  }

  Future<void> _save() async {
    setState(() {
      serverErrors = const {};
      _saveError = null;
    });
    final valid = _formKey.currentState!.validate();
    final docs = _docs;
    final allocations = _allocations;
    final allocError = docs == null
        ? null
        : allocationsError(docs, allocations, _amountValue);
    if (!valid || allocError != null || _party == null) return;
    setState(() => _saving = true);
    try {
      final payment = await ref
          .read(paymentsRepositoryProvider)
          .create(
            PaymentDraft(
              kind: _kind,
              partyId: _party!.id,
              date: apiDate(_date),
              accountId: _accountId!,
              mode: _mode,
              reference: trimmedOrNull(_reference.text),
              amount: _amountValue,
              notes: trimmedOrNull(_notes.text),
              // Without the open documents, let the server allocate.
              allocations: docs == null ? null : allocations,
            ),
          );
      ref.bump(moneyKinds);
      if (!mounted) return;
      showInfoSnackBar(context, '${_kind.label} ${payment.number} saved');
      context.go('${_kind.basePath}/${payment.id}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saveError = e);
      showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(cashBankAccountsProvider);
    final accountList = accounts.value;
    if (!_accountTouched && accountList != null && accountList.isNotEmpty) {
      _accountId = _defaultAccount(accountList);
    }
    final receipt = _kind == PaymentKind.receipt;
    final docs = _docs;
    final allocations = _allocations;
    final allocError = docs == null
        ? null
        : allocationsError(docs, allocations, _amountValue);

    final details = SectionCard(
      title: 'Details',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormRow(
            children: [
              PickerField(
                label: _kind.partyLabel,
                value: _party?.name,
                onTap: _pickParty,
                errorText: serverError('partyId'),
                validator: () => _party == null
                    ? 'Choose a ${_kind.partyLabel.toLowerCase()}'
                    : null,
              ),
              PickerField(
                label: 'Date',
                value: formatDate(_date),
                icon: Icons.calendar_today_outlined,
                errorText: serverError('date'),
                onTap: _pickDate,
              ),
            ],
          ),
          const SizedBox(height: 16),
          FormRow(
            children: [
              TextFormField(
                controller: _amount,
                decoration: InputDecoration(
                  labelText: receipt ? 'Amount received' : 'Amount paid',
                  prefixText: '₹ ',
                ),
                keyboardType: decimalKeyboard,
                inputFormatters: [decimalInput()],
                forceErrorText: serverError('amount'),
                onChanged: _amountChanged,
                validator: (v) {
                  final error = requiredNumber(v, label: 'Amount');
                  if (error != null) return error;
                  return parseNumber(v!)! > 0 ? null : 'Must be more than 0';
                },
              ),
              DropdownButtonFormField<PaymentMode>(
                initialValue: _mode,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Mode'),
                forceErrorText: serverError('mode'),
                items: [
                  for (final mode in PaymentMode.values)
                    DropdownMenuItem(value: mode, child: Text(mode.label)),
                ],
                onChanged: (v) => setState(() => _mode = v ?? _mode),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FormRow(
            children: [
              DropdownButtonFormField<String>(
                initialValue:
                    (accountList ?? const <Account>[]).any(
                      (a) => a.id == _accountId,
                    )
                    ? _accountId
                    : null,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: receipt ? 'Deposit to' : 'Pay from',
                  helperText: accounts.isLoading && !accounts.hasValue
                      ? 'Loading…'
                      : null,
                  suffixIcon: accounts.hasError
                      ? IconButton(
                          tooltip: 'Reload accounts',
                          icon: const Icon(Icons.refresh),
                          onPressed: () =>
                              ref.invalidate(cashBankAccountsProvider),
                        )
                      : null,
                ),
                forceErrorText:
                    serverError('accountId') ??
                    (accounts.hasError ? 'Could not load accounts' : null),
                items: [
                  for (final account in accountList ?? const <Account>[])
                    DropdownMenuItem(
                      value: account.id,
                      child: Text(
                        '${account.name} (${account.subtype})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _accountId = v;
                  _accountTouched = true;
                }),
                validator: (v) => v == null ? 'Choose an account' : null,
              ),
              TextFormField(
                controller: _reference,
                decoration: const InputDecoration(
                  labelText: 'Reference (optional)',
                  hintText: 'UTR, cheque no., …',
                ),
                forceErrorText: serverError('reference'),
                onChanged: (_) => clearServerError('reference'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _notes,
            decoration: const InputDecoration(labelText: 'Notes (optional)'),
            forceErrorText: serverError('notes'),
          ),
        ],
      ),
    );

    final allocationCard = SectionCard(
      title: receipt ? 'Settle invoices' : 'Settle bills',
      child: _allocationBody(docs, allocError),
    );

    final allocated = allocatedTotal(allocations);
    final summary = SectionCard(
      title: 'Summary',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AmountRow('Amount', _amountValue, bold: true),
          AmountRow('Allocated', allocated),
          AmountRow(
            'Unallocated (advance)',
            unallocatedAmount(_amountValue, allocations),
          ),
          if (_saveError != null) ...[
            const SizedBox(height: 12),
            ApiErrorBox(error: _saveError!, subject: 'the form'),
          ],
          const SizedBox(height: 16),
          BusyButton(
            busy: _saving,
            onPressed: _save,
            icon: Icons.save_outlined,
            label: 'Save ${_kind.label.toLowerCase()}',
          ),
        ],
      ),
    );

    return Form(
      key: _formKey,
      child: DocFormLayout(
        title: 'Record ${_kind.label.toLowerCase()}',
        main: [details, allocationCard],
        summary: summary,
      ),
    );
  }

  Widget _allocationBody(List<OpenDoc>? docs, String? allocError) {
    final theme = Theme.of(context);
    if (_party == null) {
      return Text(
        'Choose a ${_kind.partyLabel.toLowerCase()} to see their open '
        '${_kind.docLabel}s.',
      );
    }
    if (_docsLoading) return const LinearProgressIndicator();
    if (_docsError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Could not load open ${_kind.docLabel}s: '
            '${errorMessage(_docsError!)}\n'
            'If you save now, the amount is allocated to the oldest open '
            '${_kind.docLabel}s automatically.',
          ),
          TextButton.icon(
            onPressed: () => _loadDocs(_party!.id),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      );
    }
    if (docs == null) return const SizedBox.shrink();
    if (docs.isEmpty) {
      return Text(
        'No open ${_kind.docLabel}s. The whole amount is kept as an advance.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => setState(() {
                _allocTouched = false;
                _autoFill();
              }),
              icon: const Icon(Icons.auto_fix_high_outlined),
              label: const Text('Auto-allocate'),
            ),
            TextButton(
              onPressed: () => setState(() {
                _allocTouched = true;
                for (final c in _alloc.values) {
                  c.clear();
                }
              }),
              child: const Text('Clear'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final doc in docs)
          _AllocationRow(
            key: ValueKey(doc.id),
            doc: doc,
            controller: _alloc[doc.id]!,
            onChanged: () => setState(() => _allocTouched = true),
          ),
        if (allocError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              allocError,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

/// One open document with its allocation field: a row on wide screens,
/// stacked on phones.
class _AllocationRow extends StatelessWidget {
  const _AllocationRow({
    super.key,
    required this.doc,
    required this.controller,
    required this.onChanged,
  });

  final OpenDoc doc;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final overdue = doc.isOverdue(DateTime.now());
    final field = TextFormField(
      controller: controller,
      decoration: const InputDecoration(
        labelText: 'Allocate ₹',
        isDense: true,
        errorMaxLines: 2,
      ),
      keyboardType: decimalKeyboard,
      inputFormatters: [decimalInput()],
      onChanged: (_) => onChanged(),
      validator: (v) => allocationError(doc, parseNumber(v ?? '')),
    );
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          doc.number,
          style: theme.textTheme.titleSmall,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          [
            formatDate(doc.date),
            if (doc.dueDate != null)
              'due ${formatDate(doc.dueDate)}${overdue ? ' (overdue)' : ''}',
          ].join(' · '),
          style: overdue
              ? small?.copyWith(color: theme.colorScheme.error)
              : small,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
    final amounts = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('Due ${formatMoney(doc.amountDue)}'),
        Text('of ${formatMoney(doc.total)}', style: small),
      ],
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 560) {
              return Row(
                children: [
                  Expanded(child: info),
                  const SizedBox(width: 12),
                  amounts,
                  const SizedBox(width: 16),
                  SizedBox(width: 150, child: field),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: info),
                    const SizedBox(width: 8),
                    amounts,
                  ],
                ),
                const SizedBox(height: 8),
                field,
              ],
            );
          },
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../accounts/accounts_repository.dart';
import '../auth/session.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'export_models.dart';
import 'export_repository.dart';

/// Currencies, exchange rates, the letter of undertaking, foreign receipts and
/// period-end revaluation. Rates are typed by hand: the notes field records
/// where a rate came from.
class CurrencyScreen extends ConsumerWidget {
  const CurrencyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = ref.watch(permissionsProvider).can(Perm.fxManage);
    return DefaultTabController(
      length: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Currencies and export',
            subtitle: 'Exchange rates, letter of undertaking and foreign receipts',
          ),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Rates'),
              Tab(text: 'Currencies'),
              Tab(text: 'LUT'),
              Tab(text: 'Foreign receipts'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _RatesTab(manage: manage),
                _CurrenciesTab(manage: manage),
                _LutTab(manage: manage),
                _ReceiptsTab(manage: manage),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget _pad(BuildContext context, List<Widget> children) => ListView(
  padding: EdgeInsets.symmetric(horizontal: pageGutter(context), vertical: 12),
  children: children,
);

class _RatesTab extends ConsumerWidget {
  const _RatesTab({required this.manage});
  final bool manage;

  Future<void> _add(BuildContext context, WidgetRef ref, List<Currency> cur) async {
    var code = cur.isEmpty ? null : cur.first.code;
    final rate = TextEditingController();
    final note = TextEditingController();
    var date = DateUtils.dateOnly(DateTime.now());
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: const Text('Add exchange rate'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: code,
                decoration: const InputDecoration(labelText: 'Currency'),
                items: [for (final c in cur) DropdownMenuItem(value: c.code, child: Text(c.code))],
                onChanged: (v) => code = v,
              ),
              const SizedBox(height: 12),
              PickerField(
                label: 'Date',
                value: formatDate(date),
                icon: Icons.calendar_today_outlined,
                onTap: () async {
                  final p = await showDatePicker(
                    context: d,
                    initialDate: date,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (p != null) set(() => date = p);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: rate,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Rupees for 1 unit'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: note,
                decoration: const InputDecoration(labelText: 'Where the rate came from (optional)'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(d).maybePop(), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(d).pop(true), child: const Text('Save rate')),
          ],
        ),
      ),
    );
    final r = parseNumber(rate.text);
    if (ok != true || code == null || r == null || r <= 0 || !context.mounted) return;
    try {
      await ref.read(exportRepositoryProvider).addRate(
        code: code!,
        date: apiDate(date),
        rate: r,
        note: trimmedOrNull(note.text),
      );
      ref.read(exportRevisionProvider.notifier).bump();
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cur = ref.watch(currenciesProvider).value ?? const <Currency>[];
    return AsyncValueView(
      value: ref.watch(ratesProvider),
      onRetry: () => ref.invalidate(ratesProvider),
      data: (rates) => _pad(context, [
        if (manage)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => _add(context, ref, cur),
              icon: const Icon(Icons.add),
              label: const Text('Add rate'),
            ),
          ),
        const SizedBox(height: 12),
        if (rates.isEmpty)
          const Text('No rates yet. Add the rate you use on the invoice date.')
        else
          for (final r in rates)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${r.code}  ${formatPlain(r.rate)}'),
              subtitle: Text([formatDate(r.date), if (r.note != null) r.note!].join(' · ')),
            ),
      ]),
    );
  }
}

class _CurrenciesTab extends ConsumerWidget {
  const _CurrenciesTab({required this.manage});
  final bool manage;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final code = TextEditingController();
    final name = TextEditingController();
    final symbol = TextEditingController();
    final decimals = TextEditingController(text: '2');
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Add currency'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: code, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Code, three letters')),
            const SizedBox(height: 12),
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 12),
            TextField(controller: symbol, decoration: const InputDecoration(labelText: 'Symbol')),
            const SizedBox(height: 12),
            TextField(controller: decimals, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Decimals')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).maybePop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(d).pop(true), child: const Text('Add currency')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(exportRepositoryProvider).addCurrency(
        code: code.text.trim().toUpperCase(),
        name: name.text.trim(),
        symbol: symbol.text.trim(),
        decimals: int.tryParse(decimals.text.trim()) ?? 2,
      );
      ref.read(exportRevisionProvider.notifier).bump();
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncValueView(
    value: ref.watch(currenciesProvider),
    onRetry: () => ref.invalidate(currenciesProvider),
    data: (list) => _pad(context, [
      Text('Books are kept in rupees (INR).', style: Theme.of(context).textTheme.bodySmall),
      if (manage)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: FilledButton.icon(
              onPressed: () => _add(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Add currency'),
            ),
          ),
        ),
      for (final c in list)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${c.code}  ${c.name}'),
          subtitle: Text('Symbol ${c.symbol}, ${c.decimals} decimals'),
        ),
    ]),
  );
}

class _LutTab extends ConsumerWidget {
  const _LutTab({required this.manage});
  final bool manage;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final fy = TextEditingController();
    final no = TextEditingController();
    final arn = TextEditingController();
    final from = TextEditingController();
    final to = TextEditingController();
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Add letter of undertaking'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: fy, decoration: const InputDecoration(labelText: 'Financial year, like 2026-27')),
            const SizedBox(height: 12),
            TextField(controller: no, decoration: const InputDecoration(labelText: 'LUT number')),
            const SizedBox(height: 12),
            TextField(controller: arn, decoration: const InputDecoration(labelText: 'ARN (optional)')),
            const SizedBox(height: 12),
            TextField(controller: from, decoration: const InputDecoration(labelText: 'Valid from, YYYY-MM-DD')),
            const SizedBox(height: 12),
            TextField(controller: to, decoration: const InputDecoration(labelText: 'Valid to, YYYY-MM-DD')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).maybePop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(d).pop(true), child: const Text('Save LUT')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(exportRepositoryProvider).addLut(
        fy: fy.text.trim(),
        lutNo: no.text.trim(),
        arn: trimmedOrNull(arn.text),
        validFrom: from.text.trim(),
        validTo: to.text.trim(),
      );
      ref.read(exportRevisionProvider.notifier).bump();
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncValueView(
    value: ref.watch(lutsProvider),
    onRetry: () => ref.invalidate(lutsProvider),
    data: (list) => _pad(context, [
      Text(
        'An export without tax needs a letter of undertaking (FORM GST RFD-11) '
        'that covers the invoice date. Invoices are refused without one.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (manage)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: FilledButton.icon(
              onPressed: () => _add(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Add LUT'),
            ),
          ),
        ),
      if (list.isEmpty) const Text('No LUT added yet.'),
      for (final l in list)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${l.fy}  ${l.lutNo}'),
          subtitle: Text('${formatDate(l.validFrom)} to ${formatDate(l.validTo)}${l.arn == null ? '' : ' · ARN ${l.arn}'}'),
        ),
    ]),
  );
}

class _ReceiptsTab extends ConsumerStatefulWidget {
  const _ReceiptsTab({required this.manage});
  final bool manage;

  @override
  ConsumerState<_ReceiptsTab> createState() => _ReceiptsTabState();
}

class _ReceiptsTabState extends ConsumerState<_ReceiptsTab> {
  Party? _party;
  String? _currency;
  String? _accountId;
  final _fc = TextEditingController();
  final _rate = TextEditingController();
  final _ref = TextEditingController();
  List<Json> _open = const [];
  Json? _result;
  String? _asOf;
  Json? _reval;
  final _closing = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_fc, _rate, _ref, _closing]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadOpen() async {
    if (_party == null || _currency == null) return;
    try {
      final o = await ref.read(exportRepositoryProvider).outstanding(_party!.id, _currency!);
      if (mounted) setState(() => _open = o);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _post() async {
    final fc = parseNumber(_fc.text);
    final rate = parseNumber(_rate.text);
    if (_party == null || _currency == null || _accountId == null || fc == null || rate == null) {
      showErrorSnackBar(context, 'Fill customer, currency, account, amount and rate.');
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await ref.read(exportRepositoryProvider).foreignReceipt(
        partyId: _party!.id,
        accountId: _accountId!,
        currency: _currency!,
        fcAmount: fc,
        rate: rate,
        reference: trimmedOrNull(_ref.text),
      );
      if (mounted) setState(() => _result = asJson(r['fx']));
      await _loadOpen();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revalue(bool post) async {
    final asOf = _asOf ?? apiDate(DateTime.now());
    final rate = parseNumber(_closing.text);
    try {
      final r = await ref.read(exportRepositoryProvider).revalue(
        asOf,
        post: post,
        rates: rate != null && _currency != null ? {_currency!: rate} : null,
      );
      if (mounted) setState(() => _reval = r);
      if (post && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Revaluation posted. It reverses the next day.')),
        );
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currencies = ref.watch(currenciesProvider).value ?? const <Currency>[];
    final accounts = ref.watch(cashBankAccountsProvider).value ?? const [];
    final theme = Theme.of(context);
    return _pad(context, [
      SectionCard(
        title: 'Receive in a foreign currency',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormRow(
              children: [
                PickerField(
                  label: 'Customer',
                  value: _party?.name,
                  onTap: () async {
                    final p = await pickParty(context, ref, type: PartyType.customer);
                    if (p != null) {
                      setState(() => _party = p);
                      await _loadOpen();
                    }
                  },
                ),
                DropdownButtonFormField<String>(
                  initialValue: _currency,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Currency'),
                  items: [for (final c in currencies) DropdownMenuItem(value: c.code, child: Text(c.code))],
                  onChanged: (v) {
                    setState(() => _currency = v);
                    _loadOpen();
                  },
                ),
                DropdownButtonFormField<String>(
                  initialValue: _accountId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Bank or cash account'),
                  items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
                  onChanged: (v) => setState(() => _accountId = v),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FormRow(
              children: [
                TextField(controller: _fc, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount received in currency')),
                TextField(controller: _rate, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Rate on the receipt date')),
                TextField(controller: _ref, decoration: const InputDecoration(labelText: 'Reference (optional)')),
              ],
            ),
            if (_open.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Open invoices, oldest first', style: theme.textTheme.titleSmall),
              for (final o in _open)
                Text('${asString(o['number'])}: ${formatPlain(asDouble(o['fcOutstanding']))} ${asString(o['currency'])} due'),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: widget.manage && !_busy ? _post : null,
                child: Text(_busy ? 'Posting' : 'Post receipt'),
              ),
            ),
            if (_result != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Received ${formatMoney(asDouble(_result!['inrReceived']))}, '
                  'cleared ${formatMoney(asDouble(_result!['inrCleared']))}. '
                  '${asDouble(_result!['gainLoss']) >= 0 ? 'Exchange gain' : 'Exchange loss'} '
                  '${formatMoney(asDouble(_result!['gainLoss']).abs())}.',
                ),
              ),
          ],
        ),
      ),
      SectionCard(
        title: 'Period-end revaluation',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Restates open foreign invoices at the closing rate. The journal '
              'is reversed the next day. Optional.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FormRow(
              children: [
                PickerField(
                  label: 'As of',
                  value: formatDate(_asOf ?? apiDate(DateTime.now())),
                  icon: Icons.calendar_today_outlined,
                  onTap: () async {
                    final p = await showDatePicker(
                      context: context,
                      initialDate: DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                    );
                    if (p != null) setState(() => _asOf = apiDate(p));
                  },
                ),
                TextField(
                  controller: _closing,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _currency == null ? 'Closing rate (choose a currency above)' : 'Closing rate for $_currency',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(onPressed: () => _revalue(false), child: const Text('Preview')),
                FilledButton(onPressed: widget.manage ? () => _revalue(true) : null, child: const Text('Post revaluation')),
              ],
            ),
            if (_reval != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('Adjustment ${formatMoney(asDouble(_reval!['total'] ?? _reval!['totalAdjustment']))}'),
              ),
          ],
        ),
      ),
    ]);
  }
}

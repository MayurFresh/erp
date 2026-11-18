import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_picker.dart';
import '../../widgets/states.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'landed_cost_models.dart';
import 'landed_cost_repository.dart';
import 'landed_cost_widgets.dart';

/// New landed cost voucher: pick bills or receipts, add charges, preview the
/// allocation, then post.
class LandedCostFormScreen extends ConsumerStatefulWidget {
  const LandedCostFormScreen({super.key});

  @override
  ConsumerState<LandedCostFormScreen> createState() => _State();
}

class _State extends ConsumerState<LandedCostFormScreen> {
  final List<({String type, String id, String number})> _docs = [];
  final List<ChargeDraft> _charges = [ChargeDraft()];
  final Map<String, TextEditingController> _weightCtl = {};
  final _notes = TextEditingController();
  String _basis = 'value';
  LandedCost? _preview;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _notes.dispose();
    for (final c in _weightCtl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, double> _weights() => {
    for (final e in _weightCtl.entries)
      if (double.tryParse(e.value.text) != null)
        e.key: double.parse(e.value.text),
  };

  Json? _body() => buildLandedCostBody(
    docs: [for (final d in _docs) (type: d.type, id: d.id)],
    basis: _basis,
    charges: _charges,
    weights: _weights(),
    notes: _notes.text,
  );

  Future<void> _addDoc(String type) async {
    final repo = ref.read(landedCostRepositoryProvider);
    final picked = await showSearchPicker<Json>(
      context: context,
      title: type == 'grn' ? 'Choose a goods receipt' : 'Choose a purchase bill',
      hintText: 'Search number',
      emptyMessage: 'Nothing found.',
      search: (q) => repo.documents(type, q),
      titleBuilder: (_, d) => Text(asString(d['number'])),
      subtitleBuilder: (_, d) => Text(
        [
          asString(d['partyName']),
          formatDate(d['billDate'] ?? d['receiptDate']),
        ].join(' · '),
      ),
    );
    if (picked == null) return;
    final id = asString(picked['id']);
    if (_docs.any((d) => d.id == id)) return;
    setState(() {
      _docs.add((type: type, id: id, number: asString(picked['number'])));
      _preview = null;
    });
  }

  Future<void> _pickAccount(ChargeDraft c) async {
    final repo = ref.read(landedCostRepositoryProvider);
    final all = await repo.accounts();
    if (!mounted) return;
    final picked = await showSearchPicker<Json>(
      context: context,
      title: 'Where was the cost booked',
      hintText: 'Search account',
      emptyMessage: 'No account matches.',
      search: (q) async => all
          .where(
            (a) => '${a['code']} ${a['name']}'.toLowerCase().contains(
              q.toLowerCase(),
            ),
          )
          .take(50)
          .toList(),
      titleBuilder: (_, a) => Text('${a['code']} ${a['name']}'),
    );
    if (picked == null) return;
    setState(() {
      c.clearSource();
      c.creditAccountId = asString(picked['id']);
      c.creditAccountName = '${picked['code']} ${picked['name']}';
      c.partyId = null;
      c.partyName = null;
      _preview = null;
    });
  }

  /// Takes the charge from an expense entry or a vendor bill that has not
  /// been allocated yet. The source supplies the credit side and the amount.
  Future<void> _pickSource(ChargeDraft c, String type) async {
    final repo = ref.read(landedCostRepositoryProvider);
    final isExpense = type == 'expense';
    final picked = await showSearchPicker<Json>(
      context: context,
      title: isExpense ? 'Choose an expense' : 'Choose a vendor bill',
      hintText: 'Search number or name',
      emptyMessage: 'No unused ${isExpense ? 'expense' : 'vendor bill'} found.',
      search: (q) => repo.sources(type, q),
      titleBuilder: (_, d) => Text(
        '${asString(d['number'])} · ${formatMoney(asDouble(d['amount']))}',
      ),
      subtitleBuilder: (_, d) => Text(
        [formatDate(d['date']), asString(d['description'])]
            .where((x) => x.isNotEmpty)
            .join(' · '),
      ),
    );
    if (picked == null) return;
    setState(() {
      c.sourceType = type;
      c.sourceId = asString(picked['id']);
      c.sourceLabel = asString(picked['number']);
      c.sourceAmount = asDouble(picked['amount']);
      c.amount = c.sourceAmount!;
      c.creditAccountId = null;
      c.creditAccountName = null;
      c.partyId = null;
      c.partyName = null;
      _preview = null;
    });
  }

  Future<void> _pickVendor(ChargeDraft c) async {
    final p = await pickParty(context, ref, type: PartyType.vendor);
    if (p == null) return;
    setState(() {
      c.clearSource();
      c.partyId = p.id;
      c.partyName = p.name;
      c.creditAccountId = null;
      c.creditAccountName = null;
      _preview = null;
    });
  }

  void _syncWeightFields(LandedCost p) {
    for (final l in p.lines) {
      _weightCtl.putIfAbsent(
        l.docLineId,
        () => TextEditingController(text: l.weight > 0 ? '${l.weight}' : ''),
      );
    }
  }

  Future<void> _run({required bool save}) async {
    final body = _body();
    if (body == null) {
      setState(
        () => _error = 'Add a bill or receipt and a charge with an amount '
            'and where it was booked.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(landedCostRepositoryProvider);
      if (save) {
        final made = await repo.create(body);
        ref.bump(const [DataKind.purchases, DataKind.stock]);
        if (!mounted) return;
        showInfoSnackBar(context, 'Landed cost ${made.number} posted');
        context.go('/landed-costs/${made.id}');
      } else {
        final p = await repo.preview(body);
        if (!mounted) return;
        setState(() {
          _preview = p;
          if (_basis == 'weight') _syncWeightFields(p);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _chargeRow(int i) {
    final c = _charges[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormRow(
            children: [
              DropdownButtonFormField<String>(
                initialValue: c.kind,
                decoration: const InputDecoration(labelText: 'Charge'),
                items: [
                  for (final e in lcKinds.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() {
                  c.kind = v ?? c.kind;
                  _preview = null;
                }),
              ),
              TextFormField(
                key: ValueKey('amount-${c.sourceId}'),
                initialValue: c.amount > 0 ? '${c.amount}' : '',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Added to cost',
                  helperText: c.sourceAmount == null
                      ? 'Without GST'
                      : 'Without GST, at most ${formatMoney(c.sourceAmount!)}',
                ),
                onChanged: (v) {
                  c.amount = double.tryParse(v) ?? 0;
                  _preview = null;
                },
              ),
            ],
          ),
          if (c.kind == 'customs_duty')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextFormField(
                initialValue: c.igstAmount > 0 ? '${c.igstAmount}' : '',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'IGST paid on import',
                  helperText: 'Claimed as input credit, not added to cost',
                ),
                onChanged: (v) {
                  c.igstAmount = double.tryParse(v) ?? 0;
                  _preview = null;
                },
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => _pickSource(c, 'expense'),
                child: Text(
                  c.sourceType == 'expense'
                      ? 'Expense ${c.sourceLabel}'
                      : 'From an expense',
                ),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => _pickSource(c, 'vendor_bill'),
                child: Text(
                  c.sourceType == 'vendor_bill'
                      ? 'Bill ${c.sourceLabel}'
                      : 'From a vendor bill',
                ),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => _pickAccount(c),
                child: Text(c.creditAccountName ?? 'Booked in account'),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => _pickVendor(c),
                child: Text(c.partyName ?? 'Owed to vendor'),
              ),
              if (_charges.length > 1)
                IconButton(
                  tooltip: 'Remove charge',
                  onPressed: () => setState(() {
                    _charges.removeAt(i);
                    _preview = null;
                  }),
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    return FormPage(
      children: [
        const PageHeader(title: 'New landed cost'),
        SectionCard(
          title: 'Bills and receipts',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final d in _docs)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(d.number),
                  subtitle: Text(d.type == 'grn' ? 'Goods receipt' : 'Purchase bill'),
                  trailing: IconButton(
                    tooltip: 'Remove ${d.number}',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _docs.remove(d);
                      _preview = null;
                    }),
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _addDoc('purchase'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add purchase bill'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _addDoc('grn'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add goods receipt'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Charges',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < _charges.length; i++) _chargeRow(i),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _charges.add(ChargeDraft())),
                  icon: const Icon(Icons.add),
                  label: const Text('Add charge'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Share the cost',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                segments: [
                  for (final e in lcBases.entries)
                    ButtonSegment(value: e.key, label: Text(e.value)),
                ],
                selected: {_basis},
                onSelectionChanged: (s) => setState(() {
                  _basis = s.first;
                  _preview = null;
                }),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(labelText: 'Notes (optional)'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy ? null : () => _run(save: false),
              child: Text(p == null ? 'Show allocation' : 'Refresh allocation'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy || p == null ? null : () => _run(save: true),
              child: const Text('Post landed cost'),
            ),
          ],
        ),
        if (p != null) ...[
          const SizedBox(height: 12),
          SectionCard(
            title: 'Allocation',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Cost added ${formatMoney(p.chargesTotal)}: '
                  '${formatMoney(p.inventoryTotal)} to stock, '
                  '${formatMoney(p.cogsTotal)} to cost of sales'
                  '${p.igstTotal > 0 ? ', IGST credit ${formatMoney(p.igstTotal)}' : ''}.',
                ),
                const SizedBox(height: 8),
                LcLinesView(
                  lines: p.lines,
                  weightFields: _basis == 'weight' ? _weightCtl : null,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

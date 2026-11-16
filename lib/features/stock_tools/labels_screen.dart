import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../core/pdf_fonts.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_picker.dart';
import '../items/item_model.dart';
import '../items/item_picker.dart';
import '../items/items_repository.dart';
import '../purchases/purchase_model.dart';
import '../purchases/purchases_repository.dart';
import 'label_pdf.dart';

class _Pick {
  _Pick(this.item, int copies) : copies = TextEditingController(text: '$copies');

  final Item item;
  final TextEditingController copies;

  int get count => int.tryParse(copies.text.trim()) ?? 0;

  /// The barcode, or the SKU when the item has none; null when it has neither.
  String? get code {
    final b = item.barcode?.trim();
    if (b != null && b.isNotEmpty) return b;
    final s = item.sku?.trim();
    return s == null || s.isEmpty ? null : s;
  }
}

/// Barcode and price labels for chosen items or the lines of a purchase bill. Opens at `/labels`.
class LabelsScreen extends ConsumerStatefulWidget {
  const LabelsScreen({super.key});

  @override
  ConsumerState<LabelsScreen> createState() => _LabelsState();
}

class _LabelsState extends ConsumerState<LabelsScreen> {
  final List<_Pick> _picks = [];
  String _layoutId = labelLayouts.first.id;
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    for (final p in _picks) {
      p.copies.dispose();
    }
    super.dispose();
  }

  Future<void> _addItem() async {
    final item = await pickItem(context, ref);
    if (item == null || !mounted) return;
    setState(() => _picks.add(_Pick(item, 1)));
  }

  Future<void> _addFromBill() async {
    final repo = ref.read(purchasesRepositoryProvider);
    final bill = await showSearchPicker<Purchase>(
      context: context,
      title: 'Choose a purchase bill',
      hintText: 'Search bill number or supplier',
      emptyMessage: 'No bills match.',
      search: (q) async => (await repo.list(q: q, limit: 30)).data,
      titleBuilder: (c, p) => Text(p.number ?? 'Bill'),
      subtitleBuilder: (c, p) => Text('${p.partyName} · ${p.billDate ?? ''}'),
    );
    if (bill == null || bill.id == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final full = await repo.get(bill.id!);
      final items = ref.read(itemsRepositoryProvider);
      final added = <_Pick>[];
      for (final line in full.lines ?? const <PurchaseLine>[]) {
        final item = await items.get(line.itemId);
        added.add(_Pick(item, line.qty.ceil().clamp(1, 9999)));
      }
      if (mounted) setState(() => _picks.addAll(added));
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not load that bill: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<LabelEntry> get _entries => [
    for (final p in _picks)
      if (p.code != null && p.count > 0)
        LabelEntry(name: p.item.name, price: p.item.salePrice, code: p.code!, copies: p.count),
  ];

  Future<void> _print() async {
    final entries = _entries;
    if (entries.isEmpty) {
      setState(() => _message = 'Add at least one item with a barcode or SKU and a number of labels.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final bytes = await buildLabelsPdf(entries, labelLayoutById(_layoutId), theme: await pdfTheme());
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'Labels');
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not make the labels: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final layout = labelLayoutById(_layoutId);
    final entries = _entries;
    final total = entries.fold<int>(0, (s, e) => s + e.copies);
    final skipped = _picks.where((p) => p.code == null).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Barcode labels',
          subtitle: 'Name, price and barcode for shelves and packs',
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.all(pageGutter(context)),
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add an item'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _busy ? null : _addItem,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('Add from a purchase bill'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _busy ? null : _addFromBill,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _layoutId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Layout'),
                items: [
                  for (final l in labelLayouts) DropdownMenuItem(value: l.id, child: Text(l.name)),
                ],
                onChanged: (v) => setState(() => _layoutId = v ?? _layoutId),
              ),
              const SizedBox(height: 16),
              if (_picks.isEmpty)
                const Text('No items yet. Add items, or every line of a purchase bill.')
              else
                for (final (i, p) in _picks.indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(p.item.name),
                    subtitle: Text(p.code == null ? 'No barcode or SKU, so no label' : 'Code ${p.code}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 72,
                          child: TextField(
                            controller: p.copies,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'Labels'),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Remove',
                          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _picks.removeAt(i)),
                        ),
                      ],
                    ),
                  ),
              if (skipped > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('$skipped item${skipped == 1 ? '' : 's'} left out: no barcode or SKU.'),
                ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: 16),
              Text(
                total == 0
                    ? ''
                    : '$total label${total == 1 ? '' : 's'}, ${labelPages(layout, total)} ${layout.thermal ? 'on the roll' : 'sheet${labelPages(layout, total) == 1 ? '' : 's'}'}',
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('Print or save PDF'),
                  onPressed: _busy ? null : _print,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import 'rfq_models.dart';

/// Entry of one vendor's quote for every line. Returns the quotes to save.
Future<List<Json>?> showQuoteDialog(
  BuildContext context,
  Rfq rfq,
  RfqVendor vendor,
) => showDialog<List<Json>>(
  context: context,
  builder: (_) => _QuoteDialog(rfq: rfq, vendor: vendor),
);

class _Row {
  _Row(this.line, RfqQuote? q)
    : rate = TextEditingController(text: q == null ? '' : '${q.rate}'),
      discount = TextEditingController(
        text: q == null || q.discountPct == 0 ? '' : '${q.discountPct}',
      ),
      gst = TextEditingController(text: q == null ? '' : '${q.gstRate}'),
      lead = TextEditingController(text: q?.leadDays == null ? '' : '${q!.leadDays}');
  final RfqLine line;
  final TextEditingController rate;
  final TextEditingController discount;
  final TextEditingController gst;
  final TextEditingController lead;
}

class _QuoteDialog extends StatefulWidget {
  const _QuoteDialog({required this.rfq, required this.vendor});
  final Rfq rfq;
  final RfqVendor vendor;

  @override
  State<_QuoteDialog> createState() => _QuoteDialogState();
}

class _QuoteDialogState extends State<_QuoteDialog> {
  late final List<_Row> _rows;
  final _terms = TextEditingController();
  final _notes = TextEditingController();
  DateTime? _valid;
  String? _error;

  @override
  void initState() {
    super.initState();
    _rows = [
      for (final l in widget.rfq.lines)
        _Row(l, l.quoteBy(widget.vendor.partyId)),
    ];
    for (final l in widget.rfq.lines) {
      final q = l.quoteBy(widget.vendor.partyId);
      if (q == null) continue;
      if (_terms.text.isEmpty) _terms.text = q.paymentTerms ?? '';
      if (_notes.text.isEmpty) _notes.text = q.notes ?? '';
      _valid ??= q.validUntil == null ? null : DateTime.tryParse(q.validUntil!);
    }
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.rate.dispose();
      r.discount.dispose();
      r.gst.dispose();
      r.lead.dispose();
    }
    _terms.dispose();
    _notes.dispose();
    super.dispose();
  }

  Widget _num(TextEditingController c, String label) => Expanded(
    child: Padding(
      padding: const EdgeInsets.only(right: 6),
      child: TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, isDense: true),
      ),
    ),
  );

  void _save() {
    final out = <Json>[];
    for (final r in _rows) {
      if (r.rate.text.trim().isEmpty) continue;
      final rate = double.tryParse(r.rate.text);
      if (rate == null || rate < 0) {
        setState(() => _error = 'Check the rate for ${r.line.itemName}.');
        return;
      }
      out.add({
        'lineId': r.line.id,
        'rate': rate,
        'discountPct': double.tryParse(r.discount.text) ?? 0,
        'gstRate': double.tryParse(r.gst.text) ?? 0,
        if (int.tryParse(r.lead.text) != null) 'leadDays': int.parse(r.lead.text),
        if (_terms.text.trim().isNotEmpty) 'paymentTerms': _terms.text.trim(),
        if (_valid != null) 'validUntil': apiDate(_valid!),
        if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
      });
    }
    Navigator.pop(context, out);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Quote from ${widget.vendor.partyName}'),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final r in _rows) ...[
              Text(
                '${r.line.itemName}, ${formatQty(r.line.qty)} ${r.line.unit}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _num(r.rate, 'Rate'),
                  _num(r.discount, 'Disc %'),
                  _num(r.gst, 'GST %'),
                  _num(r.lead, 'Days'),
                ],
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _terms,
              decoration: const InputDecoration(labelText: 'Payment terms'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () async {
                final now = DateTime.now();
                final d = await showDatePicker(
                  context: context,
                  initialDate: _valid ?? now.add(const Duration(days: 15)),
                  firstDate: now,
                  lastDate: now.add(const Duration(days: 730)),
                );
                if (d != null) setState(() => _valid = d);
              },
              child: Text(
                _valid == null ? 'Valid until' : 'Valid until ${formatDate(_valid)}',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(labelText: 'Notes'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save quote')),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import 'export_models.dart';
import 'export_repository.dart';

/// Optional block on the invoice form: export or SEZ supply, foreign currency
/// and TCS. Collapsed by default. Reports each change as an [ExportChoice];
/// the invoice form merges `choice.toJson()` into its body.
class ExportFieldsCard extends ConsumerStatefulWidget {
  const ExportFieldsCard({
    super.key,
    required this.onChanged,
    this.invoiceDate,
    this.partyCurrency,
  });

  final ValueChanged<ExportChoice> onChanged;

  /// `YYYY-MM-DD`, to look up the exchange rate.
  final String? invoiceDate;

  /// The customer's default currency, offered as the starting choice.
  final String? partyCurrency;

  @override
  ConsumerState<ExportFieldsCard> createState() => _ExportFieldsCardState();
}

class _ExportFieldsCardState extends ConsumerState<ExportFieldsCard> {
  String? _category;
  String? _currency;
  bool _tcsOff = false;
  final _sbNo = TextEditingController();
  final _port = TextEditingController();
  final _country = TextEditingController();
  final _rate = TextEditingController();
  String? _rateHint;

  @override
  void dispose() {
    for (final c in [_sbNo, _port, _country, _rate]) {
      c.dispose();
    }
    super.dispose();
  }

  void _emit() => widget.onChanged(
    ExportChoice(
      category: _category,
      shippingBillNo: trimmedOrNull(_sbNo.text),
      portCode: trimmedOrNull(_port.text),
      country: trimmedOrNull(_country.text),
      currencyCode: _currency,
      rate: parseNumber(_rate.text),
      tcsOff: _tcsOff,
    ),
  );

  Future<void> _pickCurrency(String? code) async {
    setState(() {
      _currency = code;
      _rate.clear();
      _rateHint = null;
    });
    if (code != null && widget.invoiceDate != null) {
      final r = await ref.read(exportRepositoryProvider).latestRate(code, widget.invoiceDate!);
      if (mounted) {
        setState(() => _rateHint = r == null
            ? 'No rate entered for $code. Type one.'
            : 'Rate on ${formatDate(r.date)}: ${formatPlain(r.rate)}. Leave blank to use it.');
      }
    }
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final currencies = ref.watch(currenciesProvider).value ?? const <Currency>[];
    return SectionCard(
      title: 'Export, currency and TCS',
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          _category == null && _currency == null
              ? 'Domestic sale in rupees'
              : [
                  if (_category != null) exportCategories[_category],
                  if (_currency != null) _currency,
                ].join(', '),
        ),
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FormRow(
                children: [
                  DropdownButtonFormField<String?>(
                    initialValue: _category,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Supply type'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Domestic')),
                      for (final e in exportCategories.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) {
                      setState(() => _category = v);
                      _emit();
                    },
                  ),
                  DropdownButtonFormField<String?>(
                    initialValue: _currency,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Currency'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Rupees (INR)')),
                      for (final c in currencies.where((c) => c.isActive))
                        DropdownMenuItem(value: c.code, child: Text('${c.code}  ${c.name}')),
                    ],
                    onChanged: _pickCurrency,
                  ),
                  if (_currency != null)
                    TextFormField(
                      controller: _rate,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Rupees per 1 $_currency',
                        helperText: _rateHint,
                        helperMaxLines: 2,
                      ),
                      onChanged: (_) => _emit(),
                    ),
                ],
              ),
              if (_currency != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Line rates are in $_currency. GST, the ledger and the total are in rupees.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (_category != null && _category != 'deemed') ...[
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _sbNo,
                      decoration: const InputDecoration(labelText: 'Shipping bill number'),
                      onChanged: (_) => _emit(),
                    ),
                    TextFormField(
                      controller: _port,
                      decoration: const InputDecoration(labelText: 'Port code'),
                      onChanged: (_) => _emit(),
                    ),
                    TextFormField(
                      controller: _country,
                      decoration: const InputDecoration(labelText: 'Country of destination'),
                      onChanged: (_) => _emit(),
                    ),
                  ],
                ),
              ],
              CheckboxListTile(
                value: _tcsOff,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Do not collect TCS on this invoice'),
                onChanged: (v) {
                  setState(() => _tcsOff = v ?? false);
                  _emit();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Facts of an export, foreign-currency or TCS invoice for the detail page.
List<(String, String)> invoiceExtFacts(InvoiceExt e) => [
  if (e.category != null) ('Supply type', exportCategories[e.category] ?? e.category!),
  if (e.lutNo != null) ('LUT number', e.lutNo!),
  if (e.shippingBillNo != null) ('Shipping bill', e.shippingBillNo!),
  if (e.portCode != null) ('Port code', e.portCode!),
  if (e.country != null) ('Country', e.country!),
  if (e.currencyCode != null)
    ('Currency', '${e.currencyCode} at ${formatPlain(e.exchangeRate)}, ${formatPlain(e.fcTotal)} ${e.currencyCode} in all'),
  if (e.tcsAmount > 0)
    ('TCS', '${formatMoney(e.tcsAmount)} under ${e.tcsSection ?? ''} at ${formatPlain(e.tcsRate)}%'),
];

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/form_support.dart';
import 'pricing_models.dart';
import 'pricing_repository.dart';

/// State a document line keeps so prices can be refilled without overwriting
/// what the person typed. [autoRate] is the rate the form filled in; if the
/// rate field still shows it, a new price may replace it. Lines loaded from a
/// saved document have no [autoRate] and are never touched.
mixin PricedLine {
  TextEditingController get priceRateField;
  TextEditingController get priceDiscountField;
  String get priceItemId;
  double get priceQty;

  /// False when the line's discount field holds rupees, not a percent.
  bool get priceDiscountIsPercent => true;

  double? autoRate;
  double? autoDiscount;
  ResolvedPrice? resolved;
}

bool _same(double a, double? b) => b != null && (a - b).abs() < 0.005;

/// Puts [prices] (one per line, same order) onto the lines.
void applyResolved(List<PricedLine> lines, List<ResolvedPrice> prices) {
  if (prices.length != lines.length) return;
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    final p = prices[i];
    l.resolved = p;
    if (l.autoRate == null) continue;
    final rate = parseNumber(l.priceRateField.text);
    if (rate == null || _same(rate, l.autoRate)) {
      l.priceRateField.text = formatPlain(p.rate);
      l.autoRate = p.rate;
    }
    if (l.priceDiscountIsPercent) {
      final d = parseNumber(l.priceDiscountField.text) ?? 0;
      if (d == 0 || _same(d, l.autoDiscount)) {
        l.priceDiscountField.text = p.discountPct > 0 ? formatPlain(p.discountPct) : '';
        l.autoDiscount = p.discountPct;
      }
    }
  }
}

/// Asks the server for the price of every line and applies it. Returns true
/// when something came back.
Future<bool> repriceLines(
  WidgetRef ref,
  String? partyId,
  List<PricedLine> lines,
) async {
  if (lines.isEmpty) return false;
  final prices = await ref.read(pricingRepositoryProvider).resolve(partyId, [
    for (final l in lines) (itemId: l.priceItemId, qty: l.priceQty),
  ]);
  if (prices.length != lines.length) return false;
  applyResolved(lines, prices);
  return true;
}

/// Under a line: the scheme the line earns and a button that adds the free
/// goods as a separate zero-rate line.
class SchemeHint extends StatelessWidget {
  const SchemeHint({super.key, required this.price, this.onAddFree, this.freeAdded = false});

  final ResolvedPrice price;
  final VoidCallback? onAddFree;
  final bool freeAdded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bits = <String>[
      if (price.priceListName != null) 'Price list ${price.priceListName}',
      if (price.source == 'customer') 'Customer price',
      if (price.discountPct > 0) 'Scheme discount ${formatPercent(price.discountPct)}',
      if (price.freeQty > 0) 'Scheme: ${formatQty(price.freeQty)} free',
    ];
    if (bits.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(bits.join(' · '), style: theme.textTheme.bodySmall),
          if (price.freeQty > 0 && onAddFree != null && !freeAdded)
            TextButton(
              onPressed: onAddFree,
              child: Text('Add ${formatQty(price.freeQty)} free'),
            ),
        ],
      ),
    );
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pos_models.dart';

class CartState {
  const CartState({
    this.lines = const [],
    this.discount,
    this.partyId,
    this.partyName,
    this.inclusive = false,
  });

  /// Prices include GST (company setting).
  final bool inclusive;
  final List<CartLine> lines;
  final BillDiscount? discount;
  final String? partyId;
  final String? partyName;

  bool get isEmpty => lines.isEmpty;
  CartTotals get totals => computeTotals(lines, discount, inclusive: inclusive);

  CartState copyWith({
    List<CartLine>? lines,
    BillDiscount? discount,
    bool clearDiscount = false,
    String? partyId,
    String? partyName,
    bool clearParty = false,
    bool? inclusive,
  }) => CartState(
    inclusive: inclusive ?? this.inclusive,
    lines: lines ?? this.lines,
    discount: clearDiscount ? null : (discount ?? this.discount),
    partyId: clearParty ? null : (partyId ?? this.partyId),
    partyName: clearParty ? null : (partyName ?? this.partyName),
  );
}

/// The bill being made at this counter. Adding an item already on the bill
/// raises its quantity, so scanning the same barcode twice gives qty 2.
class CartNotifier extends Notifier<CartState> {
  @override
  CartState build() => const CartState();

  void add(PosItem item, {double qty = 1}) {
    final i = state.lines.indexWhere((l) => l.item.id == item.id);
    if (i < 0) {
      state = state.copyWith(
        lines: [
          ...state.lines,
          CartLine(item: item, qty: qty),
        ],
      );
      return;
    }
    setQty(i, state.lines[i].qty + qty);
  }

  void setQty(int index, double qty) {
    if (index < 0 || index >= state.lines.length) return;
    final next = [...state.lines];
    if (qty <= 0) {
      next.removeAt(index);
    } else {
      next[index] = next[index].copyWith(qty: qty);
    }
    state = state.copyWith(lines: next);
  }

  void setLineDiscount(int index, double pct) {
    if (index < 0 || index >= state.lines.length) return;
    final next = [...state.lines];
    next[index] = next[index].copyWith(
      discountPct: pct.clamp(0, 100).toDouble(),
    );
    state = state.copyWith(lines: next);
  }

  void remove(int index) => setQty(index, 0);

  void setDiscount(BillDiscount? d) => state = d == null || d.value <= 0
      ? state.copyWith(clearDiscount: true)
      : state.copyWith(discount: d);

  void setParty(String? id, String? name) => state = id == null
      ? state.copyWith(clearParty: true)
      : state.copyWith(partyId: id, partyName: name);

  void setInclusive(bool v) {
    if (v != state.inclusive) state = state.copyWith(inclusive: v);
  }

  void clear() => state = CartState(inclusive: state.inclusive);

  /// Replaces the bill with a held one.
  void load(CartState next) => state = next;
}

final cartProvider = NotifierProvider<CartNotifier, CartState>(
  CartNotifier.new,
);

/// What the pay sheet shows for the amounts typed so far. Pure so it can be tested.
class PayCalc {
  const PayCalc({
    required this.total,
    required this.cashTendered,
    required this.nonCash,
    required this.cashApplied,
    required this.change,
    required this.short,
    required this.nonCashOver,
  });

  final double total;
  final double cashTendered;
  final double nonCash;
  final double cashApplied;
  final double change;
  final double short;
  final bool nonCashOver;

  bool get covered => short <= 0.004 && !nonCashOver;
}

PayCalc computePay(
  double total, {
  double cash = 0,
  double upi = 0,
  double card = 0,
  double other = 0,
}) {
  final nonCash = roundMoney(upi + card + other);
  final cashDue = roundMoney(total - nonCash);
  final applied = roundMoney(
    cash.clamp(0, cashDue < 0 ? 0 : cashDue).toDouble(),
  );
  final change = roundMoney(cash - applied);
  final short = roundMoney(total - nonCash - applied);
  return PayCalc(
    total: total,
    cashTendered: cash,
    nonCash: nonCash,
    cashApplied: applied,
    change: change,
    short: short < 0 ? 0 : short,
    nonCashOver: nonCash > total + 0.004,
  );
}

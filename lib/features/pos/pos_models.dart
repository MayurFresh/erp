import '../../core/json.dart';

const List<String> posModes = ['cash', 'upi', 'card', 'other'];

String posModeLabel(String mode) => switch (mode) {
  'cash' => 'Cash',
  'upi' => 'UPI',
  'card' => 'Card',
  _ => 'Other',
};

double roundMoney(double v) => (v * 100).roundToDouble() / 100;

/// An item as the counter sees it: price, tax rate and stock at the location.
class PosItem {
  const PosItem({
    required this.id,
    required this.name,
    required this.price,
    required this.gstRate,
    this.sku,
    this.barcode,
    this.unit = 'nos',
    this.trackStock = true,
    this.stock,
  });

  factory PosItem.fromJson(Json json) => PosItem(
    id: asString(json['id']),
    name: asString(json['name']),
    sku: asStringOrNull(json['sku']),
    barcode: asStringOrNull(json['barcode']),
    unit: asString(json['unit'], 'nos'),
    price: asDouble(json['price']),
    gstRate: asDouble(json['gstRate']),
    trackStock: json['trackStock'] != false,
    stock: asDoubleOrNull(json['stock']),
  );

  final String id;
  final String name;
  final String? sku;
  final String? barcode;
  final String unit;
  final double price;
  final double gstRate;
  final bool trackStock;
  final double? stock;
}

/// One line of the bill being made. Immutable; the cart replaces it.
class CartLine {
  const CartLine({
    required this.item,
    this.qty = 1,
    this.discountPct = 0,
    double? rate,
  }) : rateOverride = rate;

  final PosItem item;
  final double qty;
  final double discountPct;
  final double? rateOverride;

  double get rate => rateOverride ?? item.price;
  double get gross => qty * rate;
  double get taxable => gross * (1 - discountPct / 100);

  CartLine copyWith({double? qty, double? discountPct}) => CartLine(
    item: item,
    qty: qty ?? this.qty,
    discountPct: discountPct ?? this.discountPct,
    rate: rateOverride,
  );

  Map<String, Object?> toApi() => {
    'itemId': item.id,
    'qty': qty,
    if (rateOverride != null) 'rate': rateOverride,
    if (discountPct > 0) 'discountPct': discountPct,
  };
}

class BillDiscount {
  const BillDiscount.pct(this.value) : isPct = true;
  const BillDiscount.amount(this.value) : isPct = false;

  final bool isPct;
  final double value;

  Map<String, Object?> toApi() => {
    'type': isPct ? 'pct' : 'amount',
    'value': value,
  };
}

/// Totals shown while billing. The server recomputes and is the authority.
class CartTotals {
  const CartTotals({
    required this.subtotal,
    required this.tax,
    required this.discount,
    required this.roundOff,
    required this.total,
    required this.itemCount,
  });

  final double subtotal;
  final double tax;
  final double discount;
  final double roundOff;
  final double total;
  final double itemCount;

  static const empty = CartTotals(
    subtotal: 0,
    tax: 0,
    discount: 0,
    roundOff: 0,
    total: 0,
    itemCount: 0,
  );
}

/// [inclusive]: prices already include GST (MRP). Line amounts then sum to the
/// bill, the tax is the part inside them, and only the whole-rupee rounding is added.
CartTotals computeTotals(
  List<CartLine> lines,
  BillDiscount? bill, {
  bool inclusive = false,
}) {
  if (lines.isEmpty) return CartTotals.empty;
  final afterLine = lines.fold<double>(0, (s, l) => s + l.taxable);
  var billPct = 0.0;
  if (bill != null && bill.value > 0 && afterLine > 0) {
    billPct = bill.isPct
        ? bill.value.clamp(0, 100).toDouble()
        : (bill.value.clamp(0, afterLine) / afterLine) * 100;
  }
  if (inclusive) {
    var sum = 0.0, base = 0.0, gross = 0.0, qty = 0.0;
    for (final l in lines) {
      final amount = roundMoney(l.taxable * (1 - billPct / 100));
      sum += amount;
      base += roundMoney(amount / (1 + l.item.gstRate / 100));
      gross += l.gross;
      qty += l.qty;
    }
    sum = roundMoney(sum);
    final total = (sum + 0.5).floorToDouble();
    return CartTotals(
      subtotal: roundMoney(base),
      tax: roundMoney(sum - base),
      discount: roundMoney(gross - sum),
      roundOff: roundMoney(total - sum),
      total: total,
      itemCount: qty,
    );
  }
  var taxable = 0.0, tax = 0.0, gross = 0.0, qty = 0.0;
  for (final l in lines) {
    final t = roundMoney(l.taxable * (1 - billPct / 100));
    taxable += t;
    tax += roundMoney(t * l.item.gstRate / 100);
    gross += l.gross;
    qty += l.qty;
  }
  final raw = taxable + tax;
  final total = (raw + 0.5).floorToDouble();
  return CartTotals(
    subtotal: roundMoney(taxable),
    tax: roundMoney(tax),
    discount: roundMoney(gross - taxable),
    roundOff: roundMoney(total - raw),
    total: total,
    itemCount: qty,
  );
}

class PaymentInput {
  const PaymentInput(this.mode, this.amount, {this.reference});

  final String mode;
  final double amount;
  final String? reference;

  Map<String, Object?> toApi() => {
    'mode': mode,
    'amount': amount,
    if (reference != null && reference!.isNotEmpty) 'reference': reference,
  };
}

class PosSession {
  const PosSession({
    required this.id,
    required this.locationId,
    required this.locationName,
    required this.userName,
    required this.status,
    required this.openingFloat,
    this.openedAt,
    this.closedAt,
  });

  factory PosSession.fromJson(Json json) => PosSession(
    id: asString(json['id']),
    locationId: asString(json['locationId']),
    locationName: asString(json['locationName']),
    userName: asString(json['userName']),
    status: asString(json['status']),
    openingFloat: asDouble(json['openingFloat']),
    openedAt: DateTime.tryParse(asString(json['openedAt']))?.toLocal(),
    closedAt: DateTime.tryParse(asString(json['closedAt']))?.toLocal(),
  );

  final String id;
  final String locationId;
  final String locationName;
  final String userName;
  final String status;
  final double openingFloat;
  final DateTime? openedAt;
  final DateTime? closedAt;

  bool get isOpen => status == 'open';
}

Map<String, double> _modeMap(Object? v) {
  final j = asJsonOrNull(v) ?? const <String, dynamic>{};
  return {for (final m in posModes) m: asDouble(j[m])};
}

class SessionReport {
  const SessionReport({
    required this.kind,
    required this.session,
    required this.salesCount,
    required this.salesTotal,
    required this.taxTotal,
    required this.discountTotal,
    required this.itemsSold,
    required this.creditGiven,
    required this.payments,
    required this.refunds,
    required this.returnsCount,
    required this.returnsTotal,
    required this.cashIn,
    required this.cashOut,
    required this.expected,
    required this.counted,
    required this.difference,
    required this.cashMoves,
    this.heldCount = 0,
  });

  factory SessionReport.fromJson(Json json) {
    final sales = asJson(json['sales']);
    final returns = asJson(json['returns']);
    Map<String, double>? optional(Object? v) => v is Map
        ? {for (final e in v.entries) '${e.key}': asDouble(e.value)}
        : null;
    return SessionReport(
      kind: asString(json['kind'], 'X'),
      session: PosSession.fromJson(asJson(json['session'])),
      salesCount: asInt(sales['count']),
      salesTotal: asDouble(sales['total']),
      taxTotal: asDouble(sales['taxTotal']),
      discountTotal: asDouble(sales['discountTotal']),
      itemsSold: asDouble(sales['itemsSold']),
      creditGiven: asDouble(sales['creditGiven']),
      payments: _modeMap(json['payments']),
      refunds: _modeMap(json['refunds']),
      returnsCount: asInt(returns['count']),
      returnsTotal: asDouble(returns['total']),
      cashIn: asDouble(json['cashIn']),
      cashOut: asDouble(json['cashOut']),
      expected: _modeMap(json['expected']),
      counted: optional(json['counted']),
      difference: optional(json['difference']),
      cashMoves: asJsonList(json['cashMoves']),
      heldCount: asInt(json['heldCount']),
    );
  }

  final String kind;
  final PosSession session;
  final int salesCount;
  final double salesTotal;
  final double taxTotal;
  final double discountTotal;
  final double itemsSold;
  final double creditGiven;
  final Map<String, double> payments;
  final Map<String, double> refunds;
  final int returnsCount;
  final double returnsTotal;
  final double cashIn;
  final double cashOut;
  final Map<String, double> expected;
  final Map<String, double>? counted;
  final Map<String, double>? difference;
  final List<Json> cashMoves;
  final int heldCount;
}

class SaleLine {
  const SaleLine({
    required this.invoiceLineId,
    required this.description,
    required this.qty,
    required this.unit,
    required this.rate,
    required this.discountPct,
    required this.gstRate,
    required this.taxableValue,
    required this.lineTotal,
    required this.returnedQty,
    this.hsnCode,
  });

  factory SaleLine.fromJson(Json json) => SaleLine(
    invoiceLineId: asString(json['invoiceLineId']),
    description: asString(json['description']),
    hsnCode: asStringOrNull(json['hsnCode']),
    qty: asDouble(json['qty']),
    unit: asString(json['unit']),
    rate: asDouble(json['rate']),
    discountPct: asDouble(json['discountPct']),
    gstRate: asDouble(json['gstRate']),
    taxableValue: asDouble(json['taxableValue']),
    lineTotal: asDouble(json['lineTotal']),
    returnedQty: asDouble(json['returnedQty']),
  );

  final String invoiceLineId;
  final String description;
  final String? hsnCode;
  final double qty;
  final String unit;
  final double rate;
  final double discountPct;
  final double gstRate;
  final double taxableValue;
  final double lineTotal;
  final double returnedQty;

  double get returnable => qty - returnedQty;
}

/// A saved counter bill with everything the receipt prints.
class PosSale {
  const PosSale({
    required this.id,
    required this.number,
    required this.date,
    required this.createdAt,
    required this.locationName,
    required this.cashier,
    required this.companyName,
    required this.lines,
    required this.taxSummary,
    required this.subtotal,
    required this.taxTotal,
    required this.roundOff,
    required this.discountTotal,
    required this.total,
    required this.payments,
    required this.tenderedCash,
    required this.changeDue,
    required this.creditAmount,
    required this.customerName,
    required this.isWalkIn,
    this.companyGstin,
    this.companyAddress,
    this.companyPhone,
    this.footer,
    this.customerGstin,
  });

  factory PosSale.fromJson(Json json) {
    final company = asJson(json['company']);
    final customer = asJson(json['customer']);
    return PosSale(
      id: asString(json['id']),
      number: asString(json['number']),
      date: asString(json['date']),
      createdAt: DateTime.tryParse(asString(json['createdAt']))?.toLocal(),
      locationName: asString(json['locationName']),
      cashier: asString(json['cashier']),
      companyName: asString(
        company['legalName'] ?? company['name'],
        asString(company['name']),
      ),
      companyGstin: asStringOrNull(company['gstin']),
      companyAddress: asStringOrNull(company['address']),
      companyPhone: asStringOrNull(company['phone']),
      footer: asStringOrNull(company['footer']),
      lines: asJsonList(json['lines']).map(SaleLine.fromJson).toList(),
      taxSummary: asJsonList(json['taxSummary']),
      subtotal: asDouble(json['subtotal']),
      taxTotal: asDouble(json['taxTotal']),
      roundOff: asDouble(json['roundOff']),
      discountTotal: asDouble(json['discountTotal']),
      total: asDouble(json['total']),
      payments: asJsonList(json['payments']),
      tenderedCash: asDouble(json['tenderedCash']),
      changeDue: asDouble(json['changeDue']),
      creditAmount: asDouble(json['creditAmount']),
      customerName: asString(customer['name']),
      customerGstin: asStringOrNull(customer['gstin']),
      isWalkIn: customer['isWalkIn'] == true,
    );
  }

  final String id;
  final String number;
  final String date;
  final DateTime? createdAt;
  final String locationName;
  final String cashier;
  final String companyName;
  final String? companyGstin;
  final String? companyAddress;
  final String? companyPhone;
  final String? footer;
  final List<SaleLine> lines;
  final List<Json> taxSummary;
  final double subtotal;
  final double taxTotal;
  final double roundOff;
  final double discountTotal;
  final double total;
  final List<Json> payments;
  final double tenderedCash;
  final double changeDue;
  final double creditAmount;
  final String customerName;
  final String? customerGstin;
  final bool isWalkIn;
}

class HeldBill {
  const HeldBill({
    required this.id,
    required this.label,
    required this.total,
    required this.createdBy,
    required this.payload,
    this.createdAt,
  });

  factory HeldBill.fromJson(Json json) => HeldBill(
    id: asString(json['id']),
    label: asString(json['label']),
    total: asDouble(json['total']),
    createdBy: asString(json['createdBy']),
    createdAt: DateTime.tryParse(asString(json['createdAt']))?.toLocal(),
    payload: asJson(json['payload']),
  );

  final String id;
  final String label;
  final double total;
  final String createdBy;
  final DateTime? createdAt;
  final Json payload;

  int get lineCount => asJsonList(payload['lines']).length;
}

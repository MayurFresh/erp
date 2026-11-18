import '../../core/json.dart';

/// Cost kinds a charge can have, in menu order.
const Map<String, String> lcKinds = {
  'freight': 'Freight',
  'customs_duty': 'Customs duty',
  'insurance': 'Insurance',
  'clearing': 'Clearing',
  'handling': 'Handling',
  'other': 'Other',
};

/// How the charges are shared over the lines.
const Map<String, String> lcBases = {
  'value': 'By value',
  'qty': 'By quantity',
  'weight': 'By weight',
};

class LcLine {
  const LcLine({
    required this.docType,
    required this.docId,
    required this.docLineId,
    required this.docNumber,
    required this.itemName,
    required this.qty,
    required this.baseValue,
    required this.weight,
    required this.onHandPct,
    required this.allocated,
    required this.toInventory,
    required this.toCogs,
    required this.landedUnitCost,
  });

  factory LcLine.fromJson(Json j) => LcLine(
    docType: asString(j['docType']),
    docId: asString(j['docId']),
    docLineId: asString(j['docLineId']),
    docNumber: asString(j['docNumber']),
    itemName: asString(j['itemName']),
    qty: asDouble(j['qty']),
    baseValue: asDouble(j['baseValue']),
    weight: asDouble(j['weight']),
    onHandPct: asDouble(j['onHandPct']),
    allocated: asDouble(j['allocated']),
    toInventory: asDouble(j['toInventory']),
    toCogs: asDouble(j['toCogs']),
    landedUnitCost: asDouble(j['landedUnitCost']),
  );

  final String docType;
  final String docId;
  final String docLineId;
  final String docNumber;
  final String itemName;
  final double qty;
  final double baseValue;
  final double weight;
  final double onHandPct;
  final double allocated;
  final double toInventory;
  final double toCogs;
  final double landedUnitCost;
}

class LcCharge {
  const LcCharge({
    required this.kind,
    required this.amount,
    required this.igstAmount,
    this.description,
  });

  factory LcCharge.fromJson(Json j) => LcCharge(
    kind: asString(j['kind']),
    amount: asDouble(j['amount']),
    igstAmount: asDouble(j['igstAmount']),
    description: asStringOrNull(j['description']),
  );

  final String kind;
  final double amount;
  final double igstAmount;
  final String? description;
}

class LandedCost {
  const LandedCost({
    required this.id,
    required this.number,
    required this.status,
    required this.voucherDate,
    required this.basis,
    required this.chargesTotal,
    required this.igstTotal,
    required this.inventoryTotal,
    required this.cogsTotal,
    required this.charges,
    required this.lines,
    this.notes,
    this.cancelReason,
  });

  factory LandedCost.fromJson(Json j) => LandedCost(
    id: asStringOrNull(j['id']),
    number: asStringOrNull(j['number']),
    status: asString(j['status'], 'posted'),
    voucherDate: asString(j['voucherDate']),
    basis: asString(j['basis'], 'value'),
    chargesTotal: asDouble(j['chargesTotal']),
    igstTotal: asDouble(j['igstTotal']),
    inventoryTotal: asDouble(j['inventoryTotal']),
    cogsTotal: asDouble(j['cogsTotal']),
    notes: asStringOrNull(j['notes']),
    cancelReason: asStringOrNull(j['cancelReason']),
    charges: asJsonList(j['charges']).map(LcCharge.fromJson).toList(),
    lines: asJsonList(j['lines']).map(LcLine.fromJson).toList(),
  );

  final String? id;
  final String? number;
  final String status;
  final String voucherDate;
  final String basis;
  final double chargesTotal;
  final double igstTotal;
  final double inventoryTotal;
  final double cogsTotal;
  final String? notes;
  final String? cancelReason;
  final List<LcCharge> charges;
  final List<LcLine> lines;

  bool get cancelled => status == 'cancelled';
}

/// One charge being typed on the form.
class ChargeDraft {
  ChargeDraft({
    this.kind = 'freight',
    this.amount = 0,
    this.igstAmount = 0,
    this.creditAccountId,
    this.creditAccountName,
    this.partyId,
    this.partyName,
    this.sourceType = 'direct',
    this.sourceId,
    this.sourceLabel,
    this.sourceAmount,
  });

  String kind;
  /// `direct`, `expense` or `vendor_bill`. A source supplies the credit side.
  String sourceType;
  String? sourceId;
  String? sourceLabel;
  /// Largest amount the source can give (its value before GST).
  double? sourceAmount;
  double amount;
  double igstAmount;
  String? creditAccountId;
  String? creditAccountName;
  String? partyId;
  String? partyName;

  bool get hasSource => sourceId != null && sourceType != 'direct';

  bool get hasCreditSide =>
      hasSource || creditAccountId != null || partyId != null;

  void clearSource() {
    sourceType = 'direct';
    sourceId = null;
    sourceLabel = null;
    sourceAmount = null;
  }

  Json toJson() => {
    'kind': kind,
    'amount': amount,
    if (igstAmount > 0) 'igstAmount': igstAmount,
    if (hasSource) ...{'sourceType': sourceType, 'sourceId': sourceId}
    else if (partyId != null) 'partyId': partyId
    else 'creditAccountId': creditAccountId,
  };
}

/// Body of `POST /landed-costs` and its preview. Returns null until there is a
/// document, and at least one charge with an amount and a credit side.
Json? buildLandedCostBody({
  required List<({String type, String id})> docs,
  required String basis,
  required List<ChargeDraft> charges,
  required Map<String, double> weights,
  String? notes,
}) {
  final usable = charges
      .where((c) => c.amount + c.igstAmount > 0 && c.hasCreditSide)
      .toList();
  if (docs.isEmpty || usable.isEmpty) return null;
  return {
    'basis': basis,
    'docs': [
      for (final d in docs) {'docType': d.type, 'docId': d.id},
    ],
    'charges': [for (final c in usable) c.toJson()],
    if (basis == 'weight' && weights.isNotEmpty)
      'weights': [
        for (final e in weights.entries) {'docLineId': e.key, 'weight': e.value},
      ],
    if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
  };
}

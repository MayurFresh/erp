import '../../core/json.dart';

const whBinKinds = <(String, String)>[
  ('storage', 'Storage'),
  ('receiving', 'Receiving'),
  ('dispatch', 'Dispatch'),
  ('quarantine', 'Quarantine'),
];

String whKindLabel(String kind) =>
    whBinKinds.where((k) => k.$1 == kind).map((k) => k.$2).firstOrNull ?? kind;

class WhBin {
  const WhBin({
    required this.id,
    required this.locationId,
    required this.code,
    this.name,
    this.zone,
    required this.kind,
    this.capacityQty,
    required this.isActive,
    required this.heldQty,
    this.updatedAt,
  });

  factory WhBin.fromJson(Json j) => WhBin(
    id: asString(j['id']),
    locationId: asString(j['locationId']),
    code: asString(j['code']),
    name: asStringOrNull(j['name']),
    zone: asStringOrNull(j['zone']),
    kind: asString(j['kind'], 'storage'),
    capacityQty: asDoubleOrNull(j['capacityQty']),
    isActive: asBool(j['isActive'], true),
    heldQty: asDouble(j['heldQty']),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id, locationId, code, kind;
  final String? name, zone, updatedAt;
  final double? capacityQty;
  final bool isActive;
  final double heldQty;

  bool get isQuarantine => kind == 'quarantine';
  String get label => name == null || name!.isEmpty ? code : '$code · $name';
}

class WhStockRow {
  const WhStockRow({
    required this.itemId,
    required this.itemName,
    this.sku,
    required this.unit,
    this.binId,
    this.binCode,
    this.batchId,
    this.batchNo,
    this.expiryDate,
    required this.expired,
    required this.qty,
  });

  factory WhStockRow.fromJson(Json j) => WhStockRow(
    itemId: asString(j['itemId']),
    itemName: asString(j['itemName']),
    sku: asStringOrNull(j['sku']),
    unit: asString(j['unit']),
    binId: asStringOrNull(j['binId']),
    binCode: asStringOrNull(j['binCode']),
    batchId: asStringOrNull(j['batchId']),
    batchNo: asStringOrNull(j['batchNo']),
    expiryDate: asStringOrNull(j['expiryDate']),
    expired: asBool(j['expired']),
    qty: asDouble(j['qty']),
  );

  final String itemId, itemName, unit;
  final String? sku, binId, binCode, batchId, batchNo, expiryDate;
  final bool expired;
  final double qty;
}

class WhSummary {
  const WhSummary({
    required this.onHand,
    required this.tagged,
    required this.unassigned,
  });

  factory WhSummary.fromJson(Json j) => WhSummary(
    onHand: asDouble(j['onHand']),
    tagged: asDouble(j['tagged']),
    unassigned: asDouble(j['unassigned']),
  );

  final double onHand, tagged, unassigned;
}

class WhStock {
  const WhStock(this.rows, this.summary);

  factory WhStock.fromJson(Json j) => WhStock(
    asJsonList(j['data']).map(WhStockRow.fromJson).toList(),
    j['summary'] is Map ? WhSummary.fromJson(asJson(j['summary'])) : null,
  );

  final List<WhStockRow> rows;
  final WhSummary? summary;
}

class WhCandidate {
  const WhCandidate({
    this.binId,
    this.binCode,
    this.batchId,
    this.batchNo,
    this.expiryDate,
    required this.qty,
  });

  factory WhCandidate.fromJson(Json j) => WhCandidate(
    binId: asStringOrNull(j['binId']),
    binCode: asStringOrNull(j['binCode']),
    batchId: asStringOrNull(j['batchId']),
    batchNo: asStringOrNull(j['batchNo']),
    expiryDate: asStringOrNull(j['expiryDate']),
    qty: asDouble(j['qty']),
  );

  final String? binId, binCode, batchId, batchNo, expiryDate;
  final double qty;
}

class WhFefo {
  const WhFefo({
    required this.fefo,
    required this.candidates,
    this.plan,
    this.enough,
  });

  factory WhFefo.fromJson(Json j) => WhFefo(
    fefo: asBool(j['fefo'], true),
    candidates: asJsonList(j['candidates']).map(WhCandidate.fromJson).toList(),
    plan: j['plan'] is List
        ? asJsonList(j['plan']).map(WhCandidate.fromJson).toList()
        : null,
    enough: j['enough'] is bool ? j['enough'] as bool : null,
  );

  final bool fefo;
  final List<WhCandidate> candidates;
  final List<WhCandidate>? plan;
  final bool? enough;
}

class WhSerial {
  const WhSerial({
    required this.serialNo,
    required this.itemName,
    this.binId,
    required this.status,
    this.warrantyUntil,
    this.issuedRef,
  });

  factory WhSerial.fromJson(Json j) => WhSerial(
    serialNo: asString(j['serialNo']),
    itemName: asString(j['itemName']),
    binId: asStringOrNull(j['binId']),
    status: asString(j['status']),
    warrantyUntil: asStringOrNull(j['warrantyUntil']),
    issuedRef: asStringOrNull(j['issuedRef']),
  );

  final String serialNo, itemName, status;
  final String? binId, warrantyUntil, issuedRef;
}

class WhExpiryRow {
  const WhExpiryRow({
    required this.itemName,
    required this.locationName,
    required this.batchNo,
    this.expiryDate,
    required this.qty,
    required this.expired,
  });

  factory WhExpiryRow.fromJson(Json j) => WhExpiryRow(
    itemName: asString(j['itemName']),
    locationName: asString(j['locationName']),
    batchNo: asString(j['batchNo']),
    expiryDate: asStringOrNull(j['expiryDate']),
    qty: asDouble(j['qty']),
    expired: asBool(j['expired']),
  );

  final String itemName, locationName, batchNo;
  final String? expiryDate;
  final double qty;
  final bool expired;
}

class WhSettings {
  const WhSettings({
    required this.fefo,
    required this.blockExpired,
    required this.expiryWarnDays,
  });

  factory WhSettings.fromJson(Json j) => WhSettings(
    fefo: asBool(j['fefo'], true),
    blockExpired: asBool(j['blockExpired'], true),
    expiryWarnDays: asInt(j['expiryWarnDays'], 90),
  );

  final bool fefo, blockExpired;
  final int expiryWarnDays;
}

/// Tracking rule of one item: batch or serial tracking and the bin that
/// receives purchased stock.
class WhItemRule {
  const WhItemRule({
    required this.itemId,
    required this.itemName,
    required this.tracking,
    this.shelfLifeDays,
    this.defaultBinId,
  });

  factory WhItemRule.fromJson(Json j) => WhItemRule(
    itemId: asString(j['itemId']),
    itemName: asString(j['itemName']),
    tracking: asString(j['tracking'], 'none'),
    shelfLifeDays: j['shelfLifeDays'] == null
        ? null
        : asInt(j['shelfLifeDays']),
    defaultBinId: asStringOrNull(j['defaultBinId']),
  );

  final String itemId, itemName, tracking;
  final int? shelfLifeDays;
  final String? defaultBinId;
}

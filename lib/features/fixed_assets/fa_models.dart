import '../../core/json.dart';

/// `ItBlock`: one income-tax depreciation block (API v1.6 §7).
class ItBlock {
  const ItBlock({
    required this.code,
    required this.name,
    required this.rate,
    this.effectiveFrom = '',
    this.verified = false,
  });

  factory ItBlock.fromJson(Json j) => ItBlock(
    code: asString(j['code']),
    name: asString(j['name']),
    rate: asDouble(j['rate']),
    effectiveFrom: asString(j['effectiveFrom']),
    verified: asBool(j['verified']),
  );

  final String code;
  final String name;
  final double rate;
  final String effectiveFrom;
  final bool verified;
}

class AssetDisposal {
  const AssetDisposal({
    required this.date,
    required this.saleValue,
    required this.gainLoss,
    this.entryId,
  });

  factory AssetDisposal.fromJson(Json j) => AssetDisposal(
    date: asString(j['date']),
    saleValue: asDouble(j['saleValue']),
    gainLoss: asDouble(j['gainLoss']),
    entryId: asStringOrNull(j['entryId']),
  );

  final String date;
  final double saleValue;
  final double gainLoss;
  final String? entryId;
}

class AssetHistoryRow {
  const AssetHistoryRow({
    required this.date,
    required this.kind,
    required this.amount,
    this.entryId,
  });

  factory AssetHistoryRow.fromJson(Json j) => AssetHistoryRow(
    date: asString(j['date']),
    kind: asString(j['kind']),
    amount: asDouble(j['amount']),
    entryId: asStringOrNull(j['entryId']),
  );

  final String date;
  final String kind;
  final double amount;
  final String? entryId;
}

/// `FixedAsset`; [history] is filled by `GET /fixed-assets/:id`.
class FixedAsset {
  const FixedAsset({
    required this.id,
    required this.number,
    required this.name,
    required this.blockCode,
    required this.blockName,
    required this.bookMethod,
    required this.usefulLifeYears,
    required this.residualPct,
    required this.cost,
    required this.purchaseDate,
    required this.putToUseDate,
    required this.accumulatedDep,
    required this.bookValue,
    required this.status,
    this.gstItc = 0,
    this.locationId,
    this.locationName = '',
    this.supplierName = '',
    this.billNo = '',
    this.serialNo = '',
    this.tagNo = '',
    this.custodian = '',
    this.notes = '',
    this.openingAccDep = 0,
    this.depreciatedUntil,
    this.disposal,
    this.history = const [],
  });

  factory FixedAsset.fromJson(Json j) => FixedAsset(
    id: asString(j['id']),
    number: asString(j['number']),
    name: asString(j['name']),
    blockCode: asString(j['blockCode']),
    blockName: asString(j['blockName']),
    bookMethod: asString(j['bookMethod'], 'slm'),
    usefulLifeYears: asInt(j['usefulLifeYears']),
    residualPct: asDouble(j['residualPct']),
    cost: asDouble(j['cost']),
    gstItc: asDouble(j['gstItc']),
    purchaseDate: asString(j['purchaseDate']),
    putToUseDate: asString(j['putToUseDate']),
    locationId: asStringOrNull(j['locationId']),
    locationName: asString(j['locationName']),
    supplierName: asString(j['supplierName']),
    billNo: asString(j['billNo']),
    serialNo: asString(j['serialNo']),
    tagNo: asString(j['tagNo']),
    custodian: asString(j['custodian']),
    notes: asString(j['notes']),
    openingAccDep: asDouble(j['openingAccDep']),
    accumulatedDep: asDouble(j['accumulatedDep']),
    bookValue: asDouble(j['bookValue']),
    depreciatedUntil: asStringOrNull(j['depreciatedUntil']),
    status: asString(j['status'], 'active'),
    disposal: asJsonOrNull(j['disposal']) == null
        ? null
        : AssetDisposal.fromJson(asJson(j['disposal'])),
    history: asJsonList(j['history']).map(AssetHistoryRow.fromJson).toList(),
  );

  final String id;
  final String number;
  final String name;
  final String blockCode;
  final String blockName;

  /// `slm` or `wdv`.
  final String bookMethod;
  final int usefulLifeYears;
  final double residualPct;
  final double cost;
  final double gstItc;
  final String purchaseDate;
  final String putToUseDate;
  final String? locationId;
  final String locationName;
  final String supplierName;
  final String billNo;
  final String serialNo;
  final String tagNo;
  final String custodian;
  final String notes;
  final double openingAccDep;
  final double accumulatedDep;
  final double bookValue;
  final String? depreciatedUntil;

  /// `active` or `disposed`.
  final String status;
  final AssetDisposal? disposal;
  final List<AssetHistoryRow> history;

  bool get disposed => status == 'disposed';
  String get methodLabel =>
      bookMethod == 'wdv' ? 'Written down value' : 'Straight line';
}

class AssetTotals {
  const AssetTotals({
    this.cost = 0,
    this.accumulatedDep = 0,
    this.bookValue = 0,
  });

  factory AssetTotals.fromJson(Json j) => AssetTotals(
    cost: asDouble(j['cost']),
    accumulatedDep: asDouble(j['accumulatedDep']),
    bookValue: asDouble(j['bookValue']),
  );

  final double cost;
  final double accumulatedDep;
  final double bookValue;
}

class AssetPage {
  const AssetPage({
    required this.data,
    required this.total,
    required this.totals,
  });

  final List<FixedAsset> data;
  final int total;
  final AssetTotals totals;
}

class DepLine {
  const DepLine({
    required this.assetId,
    required this.number,
    required this.name,
    required this.from,
    required this.to,
    required this.days,
    required this.amount,
  });

  factory DepLine.fromJson(Json j) => DepLine(
    assetId: asString(j['assetId']),
    number: asString(j['number']),
    name: asString(j['name']),
    from: asString(j['from']),
    to: asString(j['to']),
    days: asInt(j['days']),
    amount: asDouble(j['amount']),
  );

  final String assetId;
  final String number;
  final String name;
  final String from;
  final String to;
  final int days;
  final double amount;
}

/// A depreciation run, or its preview (`id` and `entryId` null).
class DepRun {
  const DepRun({
    required this.toDate,
    required this.total,
    this.id,
    this.number = '',
    this.lines = const [],
    this.entryId,
    this.status = 'posted',
    this.fromDates = const [],
  });

  factory DepRun.fromJson(Json j) => DepRun(
    id: asStringOrNull(j['id']),
    number: asString(j['number']),
    toDate: asString(j['toDate']),
    total: asDouble(j['total']),
    lines: asJsonList(j['lines']).map(DepLine.fromJson).toList(),
    entryId: asStringOrNull(j['entryId']),
    status: asString(j['status'], 'posted'),
    fromDates: asStringList(j['fromDates']),
  );

  final String? id;
  final String number;
  final String toDate;
  final double total;
  final List<DepLine> lines;
  final String? entryId;
  final String status;
  final List<String> fromDates;

  bool get cancelled => status == 'cancelled';
}

class ItBlockRow {
  const ItBlockRow({
    required this.blockCode,
    required this.blockName,
    required this.rate,
    required this.openingWdv,
    required this.additionsFull,
    required this.additionsHalf,
    required this.saleValue,
    required this.depreciation,
    required this.closingWdv,
    required this.shortTermGain,
  });

  factory ItBlockRow.fromJson(Json j) => ItBlockRow(
    blockCode: asString(j['blockCode']),
    blockName: asString(j['blockName']),
    rate: asDouble(j['rate']),
    openingWdv: asDouble(j['openingWdv']),
    additionsFull: asDouble(j['additionsFull']),
    additionsHalf: asDouble(j['additionsHalf']),
    saleValue: asDouble(j['saleValue']),
    depreciation: asDouble(j['depreciation']),
    closingWdv: asDouble(j['closingWdv']),
    shortTermGain: asDouble(j['shortTermGain']),
  );

  final String blockCode;
  final String blockName;
  final double rate;
  final double openingWdv;
  final double additionsFull;
  final double additionsHalf;
  final double saleValue;
  final double depreciation;
  final double closingWdv;
  final double shortTermGain;
}

class ItSchedule {
  const ItSchedule({
    required this.fy,
    required this.rows,
    this.totals,
    this.unverified = const [],
  });

  factory ItSchedule.fromJson(Json j) => ItSchedule(
    fy: asString(j['fy']),
    rows: asJsonList(j['rows']).map(ItBlockRow.fromJson).toList(),
    totals: asJsonOrNull(j['totals']) == null
        ? null
        : ItBlockRow.fromJson(asJson(j['totals'])),
    unverified: asStringList(j['unverified']),
  );

  final String fy;
  final List<ItBlockRow> rows;
  final ItBlockRow? totals;
  final List<String> unverified;
}

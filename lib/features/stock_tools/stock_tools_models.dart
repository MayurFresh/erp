import '../../core/json.dart';

/// One alternate unit of an item: one of it holds [factor] base units.
class UnitDef {
  const UnitDef({required this.name, required this.factor});

  factory UnitDef.fromJson(Json json) => UnitDef(
    name: asString(json['name']),
    factor: asDouble(json['factor'], 1),
  );

  final String name;
  final double factor;

  Json toJson() => {'name': name, 'factor': factor};
}

/// `GET /items/:id/units`.
class ItemUnits {
  const ItemUnits({
    required this.baseUnit,
    this.units = const [],
    this.defaultPurchaseUnit,
    this.defaultSaleUnit,
  });

  factory ItemUnits.fromJson(Json json) => ItemUnits(
    baseUnit: asString(json['baseUnit']),
    units: [for (final u in asJsonList(json['units'])) UnitDef.fromJson(u)],
    defaultPurchaseUnit: asStringOrNull(json['defaultPurchaseUnit']),
    defaultSaleUnit: asStringOrNull(json['defaultSaleUnit']),
  );

  final String baseUnit;
  final List<UnitDef> units;
  final String? defaultPurchaseUnit;
  final String? defaultSaleUnit;

  /// The base unit first, then the alternates.
  List<String> get names => [baseUnit, ...units.map((u) => u.name)];

  /// Base units in one [unit]; 1 for the base unit or a name not listed.
  double factorOf(String? unit) {
    if (unit == null) return 1;
    for (final u in units) {
      if (u.name.toLowerCase() == unit.toLowerCase()) return u.factor;
    }
    return 1;
  }

  /// The quantity entered in [unit] as base units.
  double toBaseQty(double qty, String? unit) =>
      (qty * factorOf(unit) * 1000).round() / 1000;

  /// The rate per [unit] as a rate per base unit (four decimals, like the server).
  double toBaseRate(double rate, String? unit) =>
      (rate / factorOf(unit) * 10000).round() / 10000;
}

class ValuationSetting {
  const ValuationSetting({required this.method, this.effectiveFrom});

  factory ValuationSetting.fromJson(Json json) => ValuationSetting(
    method: asString(json['method'], 'average'),
    effectiveFrom: asStringOrNull(json['effectiveFrom']),
  );

  final String method;
  final String? effectiveFrom;

  bool get isFifo => method == 'fifo';
}

/// Total of `GET /reports/stock-valuation?method=`.
class ValuationTotal {
  const ValuationTotal({
    required this.method,
    required this.comparison,
    required this.totalValue,
  });

  factory ValuationTotal.fromJson(Json json) => ValuationTotal(
    method: asString(json['method'], 'average'),
    comparison: asBool(json['comparison']),
    totalValue: asDouble(json['totalValue']),
  );

  final String method;
  final bool comparison;
  final double totalValue;
}

class AgeingCell {
  const AgeingCell({required this.qty, this.value});

  factory AgeingCell.fromJson(Json json) =>
      AgeingCell(qty: asDouble(json['qty']), value: asDoubleOrNull(json['value']));

  final double qty;
  final double? value;
}

class AgeingRow {
  const AgeingRow({
    required this.itemId,
    required this.name,
    required this.unit,
    required this.locationName,
    required this.qty,
    required this.buckets,
    this.sku,
    this.value,
  });

  factory AgeingRow.fromJson(Json json) => AgeingRow(
    itemId: asString(json['itemId']),
    name: asString(json['name']),
    sku: asStringOrNull(json['sku']),
    unit: asString(json['unit']),
    locationName: asString(json['locationName']),
    qty: asDouble(json['qty']),
    value: asDoubleOrNull(json['value']),
    buckets: [for (final b in asJsonList(json['buckets'])) AgeingCell.fromJson(b)],
  );

  final String itemId;
  final String name;
  final String? sku;
  final String unit;
  final String locationName;
  final double qty;
  final double? value;
  final List<AgeingCell> buckets;
}

class AgeingReport {
  const AgeingReport({
    required this.asOf,
    required this.bucketLabels,
    required this.rows,
    required this.totalQty,
    required this.totals,
    this.totalValue,
  });

  factory AgeingReport.fromJson(Json json) {
    final totals = asJson(json['totals']);
    return AgeingReport(
      asOf: asString(json['asOf']),
      bucketLabels: [for (final b in (json['buckets'] as List? ?? const [])) '$b'],
      rows: [for (final r in asJsonList(json['rows'])) AgeingRow.fromJson(r)],
      totalQty: asDouble(totals['qty']),
      totalValue: asDoubleOrNull(totals['value']),
      totals: [for (final b in asJsonList(totals['buckets'])) AgeingCell.fromJson(b)],
    );
  }

  final String asOf;
  final List<String> bucketLabels;
  final List<AgeingRow> rows;
  final double totalQty;
  final double? totalValue;
  final List<AgeingCell> totals;
}

class MovementRow {
  const MovementRow({
    required this.itemId,
    required this.name,
    required this.unit,
    required this.qty,
    required this.soldQty,
    this.sku,
    this.value,
    this.lastSaleDate,
    this.daysSinceSale,
    this.coverDays,
  });

  factory MovementRow.fromJson(Json json) => MovementRow(
    itemId: asString(json['itemId']),
    name: asString(json['name']),
    sku: asStringOrNull(json['sku']),
    unit: asString(json['unit']),
    qty: asDouble(json['qty']),
    value: asDoubleOrNull(json['value']),
    lastSaleDate: asStringOrNull(json['lastSaleDate']),
    daysSinceSale: json['daysSinceSale'] == null ? null : asInt(json['daysSinceSale']),
    soldQty: asDouble(json['soldQty']),
    coverDays: json['coverDays'] == null ? null : asInt(json['coverDays']),
  );

  final String itemId;
  final String name;
  final String? sku;
  final String unit;
  final double qty;
  final double? value;
  final String? lastSaleDate;
  final int? daysSinceSale;
  final double soldQty;
  final int? coverDays;
}

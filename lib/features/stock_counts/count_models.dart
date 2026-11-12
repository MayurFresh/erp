import '../../core/json.dart';
import '../documents/document_models.dart';

class CountLine {
  const CountLine({
    required this.itemId,
    required this.itemName,
    required this.unit,
    this.sku,
    this.barcode,
    this.expectedQty = 0,
    this.movedSince = 0,
    this.expectedNow = 0,
    this.countedQty,
    this.varianceQty,
    this.varianceValue,
  });

  factory CountLine.fromJson(Json json) => CountLine(
    itemId: asString(json['itemId']),
    itemName: asString(json['itemName']),
    sku: asStringOrNull(json['sku']),
    barcode: asStringOrNull(json['barcode']),
    unit: asString(json['unit']),
    expectedQty: asDouble(json['expectedQty']),
    movedSince: asDouble(json['movedSince']),
    expectedNow: asDouble(json['expectedNow']),
    countedQty: asDoubleOrNull(json['countedQty']),
    varianceQty: asDoubleOrNull(json['varianceQty']),
    varianceValue: asDoubleOrNull(json['varianceValue']),
  );

  final String itemId;
  final String itemName;
  final String? sku;
  final String? barcode;
  final String unit;
  final double expectedQty;

  /// Stock moves at the location after the snapshot.
  final double movedSince;
  final double expectedNow;

  /// `null` until counted.
  final double? countedQty;
  final double? varianceQty;

  /// Absent without the cost permission.
  final double? varianceValue;

  bool get counted => countedQty != null;
  bool get hasVariance => (varianceQty ?? 0).abs() > 0.0000001;
}

class CountSummary {
  const CountSummary({
    this.lines = 0,
    this.counted = 0,
    this.uncounted = 0,
    this.withVariance = 0,
  });

  factory CountSummary.fromJson(Object? value) {
    final j = asJson(value);
    return CountSummary(
      lines: asInt(j['lines']),
      counted: asInt(j['counted']),
      uncounted: asInt(j['uncounted']),
      withVariance: asInt(j['withVariance']),
    );
  }

  final int lines;
  final int counted;
  final int uncounted;
  final int withVariance;
}

class StockCount {
  const StockCount({
    required this.id,
    required this.number,
    required this.status,
    required this.locationId,
    this.locationName = '',
    this.scope = 'all',
    this.snapshotAt,
    this.notes,
    this.varianceValue,
    this.thresholdValue,
    this.needsApproval = false,
    this.postedAt,
    this.createdAt,
    this.createdBy,
    this.lineCount = 0,
    this.countedCount = 0,
    this.summary = const CountSummary(),
    this.lines = const [],
  });

  /// Both the list row and the detail share this parser.
  factory StockCount.fromJson(Json json) => StockCount(
    id: asString(json['id']),
    number: asString(json['number']),
    status: asString(json['status'], 'open'),
    locationId: asString(json['locationId']),
    locationName: asString(json['locationName']),
    scope: asString(json['scope'], 'all'),
    snapshotAt: asDateTimeOrNull(json['snapshotAt']),
    notes: asStringOrNull(json['notes']),
    varianceValue: asDoubleOrNull(json['varianceValue']),
    thresholdValue: asDoubleOrNull(json['thresholdValue']),
    needsApproval: asBool(json['needsApproval']),
    postedAt: asDateTimeOrNull(json['postedAt']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: UserRef.maybe(json['createdBy']),
    lineCount: asInt(json['lineCount']),
    countedCount: asInt(json['countedCount']),
    summary: CountSummary.fromJson(json['summary']),
    lines: asJsonList(json['lines']).map(CountLine.fromJson).toList(),
  );

  final String id;
  final String number;

  /// `open`, `posted` or `cancelled`.
  final String status;
  final String locationId;
  final String locationName;

  /// `all` or `selected`.
  final String scope;
  final DateTime? snapshotAt;
  final String? notes;
  final double? varianceValue;
  final double? thresholdValue;
  final bool needsApproval;
  final DateTime? postedAt;
  final DateTime? createdAt;
  final UserRef? createdBy;

  /// List rows only.
  final int lineCount;
  final int countedCount;

  /// Detail only.
  final CountSummary summary;
  final List<CountLine> lines;

  bool get isOpen => status == 'open';
}

/// Result of one scan: the updated line and whether it was a repeat.
class ScanResult {
  const ScanResult({required this.line, required this.duplicate});

  factory ScanResult.fromJson(Json json) => ScanResult(
    line: CountLine.fromJson(asJson(json['line'])),
    duplicate: asBool(json['duplicate']),
  );

  final CountLine line;
  final bool duplicate;
}

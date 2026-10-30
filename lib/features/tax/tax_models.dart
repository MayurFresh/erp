import '../../core/json.dart';

/// A GST rate master row (API v1.4 §1).
class GstRate {
  const GstRate({
    required this.id,
    required this.rate,
    required this.kind,
    required this.label,
    required this.effectiveFrom,
    this.effectiveTo,
    this.isLegacy = false,
    this.isSystem = false,
  });

  factory GstRate.fromJson(Json json) => GstRate(
    id: asString(json['id']),
    rate: asDouble(json['rate']),
    kind: asString(json['kind'], 'any'),
    label: asString(json['label']),
    effectiveFrom: asString(json['effectiveFrom']),
    effectiveTo: asStringOrNull(json['effectiveTo']),
    isLegacy: asBool(json['isLegacy']),
    isSystem: asBool(json['isSystem']),
  );

  final String id;
  final double rate;

  /// `any`, `goods` or `services`.
  final String kind;
  final String label;
  final String effectiveFrom;
  final String? effectiveTo;
  final bool isLegacy;
  final bool isSystem;
}

/// A TDS section master row (API v1.4 §2).
class TdsSection {
  const TdsSection({
    required this.id,
    required this.code,
    required this.name,
    this.newRef,
    this.rateIndividual = 0,
    this.rateOther = 0,
    this.rateNoPan = 0,
    this.thresholdSingle,
    this.thresholdAggregate,
    this.aggregateMode = 'whole',
    this.effectiveFrom = '',
    this.effectiveTo,
    this.verified = true,
    this.isActive = true,
    this.isSystem = false,
  });

  factory TdsSection.fromJson(Json json) => TdsSection(
    id: asString(json['id']),
    code: asString(json['code']),
    newRef: asStringOrNull(json['newRef']),
    name: asString(json['name']),
    rateIndividual: asDouble(json['rateIndividual']),
    rateOther: asDouble(json['rateOther']),
    rateNoPan: asDouble(json['rateNoPan']),
    thresholdSingle: asDoubleOrNull(json['thresholdSingle']),
    thresholdAggregate: asDoubleOrNull(json['thresholdAggregate']),
    aggregateMode: asString(json['aggregateMode'], 'whole'),
    effectiveFrom: asString(json['effectiveFrom']),
    effectiveTo: asStringOrNull(json['effectiveTo']),
    verified: asBool(json['verified'], true),
    isActive: asBool(json['isActive'], true),
    isSystem: asBool(json['isSystem']),
  );

  final String id;
  final String code;
  final String? newRef;
  final String name;
  final double rateIndividual;
  final double rateOther;
  final double rateNoPan;
  final double? thresholdSingle;
  final double? thresholdAggregate;
  final String aggregateMode;
  final String effectiveFrom;
  final String? effectiveTo;
  final bool verified;
  final bool isActive;
  final bool isSystem;

  String get display => '$code · $name';
}

/// Result of `POST /tds/preview`.
class TdsCalc {
  const TdsCalc({
    required this.sectionId,
    required this.sectionCode,
    required this.rate,
    required this.gross,
    required this.base,
    required this.amount,
    required this.fyGross,
    required this.reason,
    this.threshold,
  });

  factory TdsCalc.fromJson(Json json) => TdsCalc(
    sectionId: asString(json['sectionId']),
    sectionCode: asString(json['sectionCode']),
    rate: asDouble(json['rate']),
    gross: asDouble(json['gross']),
    base: asDouble(json['base']),
    amount: asDouble(json['amount']),
    fyGross: asDouble(json['fyGross']),
    threshold: asDoubleOrNull(json['threshold']),
    reason: asString(json['reason']),
  );

  final String sectionId;
  final String sectionCode;
  final double rate;
  final double gross;
  final double base;
  final double amount;
  final double fyGross;
  final double? threshold;
  final String reason;

  /// Plain-language explanation of [reason].
  String get reasonText => switch (reason) {
    'below_threshold' => 'Below the threshold, so no TDS',
    'single' => 'Single payment above the threshold',
    'aggregate' => 'Yearly total crossed the threshold',
    'excess' => 'On the excess over the yearly threshold',
    'no_pan' => 'Higher rate: supplier has no PAN',
    'lower_rate' => 'Lower rate applied',
    _ => reason,
  };
}

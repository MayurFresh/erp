import 'dart:math' as math;

import '../../../core/json.dart';
import 'common_models.dart';

enum IndentStatus {
  draft('Draft'),
  submitted('Submitted'),
  approved('Approved'),
  rejected('Rejected'),
  closed('Closed');

  const IndentStatus(this.label);

  final String label;

  static IndentStatus parse(Object? value) => IndentStatus.values.firstWhere(
    (s) => s.name == value,
    orElse: () => IndentStatus.draft,
  );
}

class IndentLine {
  const IndentLine({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.qty,
    this.approvedQty,
    this.fulfilledQty = 0,
    this.boqLineId,
  });

  factory IndentLine.fromJson(Json json) => IndentLine(
    id: asString(json['id']),
    itemId: asString(json['itemId']),
    itemName: asString(json['itemName']),
    unit: asString(json['unit']),
    qty: asDouble(json['qty']),
    approvedQty: asDoubleOrNull(json['approvedQty']),
    fulfilledQty: asDouble(json['fulfilledQty']),
    boqLineId: asStringOrNull(json['boqLineId']),
  );

  final String id;
  final String itemId;
  final String itemName;
  final String unit;

  /// Requested.
  final double qty;
  final double? approvedQty;
  final double fulfilledQty;
  final String? boqLineId;

  /// What fulfilment is measured against: approved qty once approved.
  double get target => approvedQty ?? qty;

  double get fulfilmentPct =>
      target <= 0 ? 0 : clampPct(fulfilledQty / target * 100);

  bool get isFulfilled => target > 0 && fulfilledQty >= target;
}

class Indent {
  const Indent({
    required this.id,
    required this.number,
    required this.locationId,
    required this.locationName,
    this.projectId,
    this.requiredBy,
    this.status = IndentStatus.draft,
    this.notes,
    this.createdAt,
    this.createdBy,
    this.approvedAt,
    this.approvedBy,
    this.rejectReason,
    this.lines = const [],
  });

  factory Indent.fromJson(Json json) => Indent(
    id: asString(json['id']),
    number: asString(json['number']),
    projectId: asStringOrNull(json['projectId']),
    locationId: asString(json['locationId']),
    locationName: asString(json['locationName']),
    requiredBy: asStringOrNull(json['requiredBy']),
    status: IndentStatus.parse(json['status']),
    notes: asStringOrNull(json['notes']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: NamedRef.fromJsonOrNull(json['createdBy']),
    approvedAt: asDateTimeOrNull(json['approvedAt']),
    approvedBy: NamedRef.fromJsonOrNull(json['approvedBy']),
    rejectReason: asStringOrNull(json['rejectReason']),
    lines: asJsonList(json['lines']).map(IndentLine.fromJson).toList(),
  );

  final String id;
  final String number;
  final String? projectId;
  final String locationId;
  final String locationName;
  final String? requiredBy;
  final IndentStatus status;
  final String? notes;
  final DateTime? createdAt;
  final NamedRef? createdBy;
  final DateTime? approvedAt;
  final NamedRef? approvedBy;
  final String? rejectReason;
  final List<IndentLine> lines;

  /// Overall fulfilment, 0–100: Σ min(fulfilled, target) ÷ Σ target.
  double get fulfilmentPct {
    var target = 0.0;
    var done = 0.0;
    for (final line in lines) {
      target += line.target;
      done += math.min(line.fulfilledQty, line.target);
    }
    return target <= 0 ? 0 : clampPct(done / target * 100);
  }

  bool get isFulfilled =>
      lines.isNotEmpty && lines.every((l) => l.isFulfilled);
}

/// Body of `POST /indents`.
class IndentDraft {
  const IndentDraft({
    required this.locationId,
    required this.lines,
    this.requiredBy,
    this.notes,
    this.submit = false,
  });

  final String locationId;
  final String? requiredBy;
  final String? notes;
  final bool submit;
  final List<IndentLineDraft> lines;

  Json toJson() => withoutNulls({
    'locationId': locationId,
    'requiredBy': requiredBy,
    'notes': notes,
    'submit': submit,
    'lines': [for (final line in lines) line.toJson()],
  });
}

class IndentLineDraft {
  const IndentLineDraft({
    required this.itemId,
    required this.qty,
    this.boqLineId,
  });

  final String itemId;
  final double qty;
  final String? boqLineId;

  Json toJson() =>
      withoutNulls({'itemId': itemId, 'qty': qty, 'boqLineId': boqLineId});
}

enum IssueStatus {
  posted('Posted'),
  cancelled('Cancelled');

  const IssueStatus(this.label);

  final String label;

  static IssueStatus parse(Object? value) => value == 'cancelled'
      ? IssueStatus.cancelled
      : IssueStatus.posted;
}

class IssueLine {
  const IssueLine({
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.qty,
    this.costRate,
    this.value,
  });

  factory IssueLine.fromJson(Json json) => IssueLine(
    itemId: asString(json['itemId']),
    itemName: asString(json['itemName']),
    unit: asString(json['unit']),
    qty: asDouble(json['qty']),
    costRate: asDoubleOrNull(json['costRate']),
    value: asDoubleOrNull(json['value']),
  );

  final String itemId;
  final String itemName;
  final String unit;
  final double qty;

  /// Only with `items.view_cost`.
  final double? costRate;
  final double? value;
}

/// Material issued to work at a site.
class Issue {
  const Issue({
    required this.id,
    required this.number,
    required this.locationId,
    required this.locationName,
    required this.date,
    this.projectId,
    this.boqLineId,
    this.boqCode,
    this.notes,
    this.status = IssueStatus.posted,
    this.createdAt,
    this.createdBy,
    this.totalValue,
    this.lines = const [],
  });

  factory Issue.fromJson(Json json) => Issue(
    id: asString(json['id']),
    number: asString(json['number']),
    locationId: asString(json['locationId']),
    locationName: asString(json['locationName']),
    projectId: asStringOrNull(json['projectId']),
    boqLineId: asStringOrNull(json['boqLineId']),
    boqCode: asStringOrNull(json['boqCode']),
    date: asString(json['date']),
    notes: asStringOrNull(json['notes']),
    status: IssueStatus.parse(json['status']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: NamedRef.fromJsonOrNull(json['createdBy']),
    totalValue: asDoubleOrNull(json['totalValue']),
    lines: asJsonList(json['lines']).map(IssueLine.fromJson).toList(),
  );

  final String id;
  final String number;
  final String locationId;
  final String locationName;
  final String? projectId;
  final String? boqLineId;
  final String? boqCode;
  final String date;
  final String? notes;
  final IssueStatus status;
  final DateTime? createdAt;
  final NamedRef? createdBy;

  /// Only with `items.view_cost`.
  final double? totalValue;
  final List<IssueLine> lines;

  bool get isCancelled => status == IssueStatus.cancelled;
}

/// Body of `POST /issues`.
class IssueDraft {
  const IssueDraft({
    required this.locationId,
    required this.lines,
    this.boqLineId,
    this.date,
    this.notes,
  });

  final String locationId;
  final String? boqLineId;
  final String? date;
  final String? notes;
  final List<({String itemId, double qty})> lines;

  Json toJson() => withoutNulls({
    'locationId': locationId,
    'boqLineId': boqLineId,
    'date': date,
    'notes': notes,
    'lines': [
      for (final line in lines) {'itemId': line.itemId, 'qty': line.qty},
    ],
  });
}

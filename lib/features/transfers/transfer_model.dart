import '../../core/json.dart';
import '../documents/document_models.dart';

enum TransferStatus {
  inTransit('in_transit', 'In transit'),
  received('received', 'Received'),
  cancelled('cancelled', 'Cancelled');

  const TransferStatus(this.value, this.label);

  /// Wire value.
  final String value;
  final String label;

  static TransferStatus parse(Object? value) => TransferStatus.values
      .firstWhere((s) => s.value == value, orElse: () => inTransit);
}

class TransferLine {
  const TransferLine({
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.qty,
    this.sku,
  });

  factory TransferLine.fromJson(Json json) => TransferLine(
    itemId: asString(json['itemId']),
    itemName: asString(json['itemName']),
    sku: asStringOrNull(json['sku']),
    unit: asString(json['unit']),
    qty: asDouble(json['qty']),
  );

  final String itemId;
  final String itemName;
  final String? sku;
  final String unit;
  final double qty;
}

class Transfer {
  const Transfer({
    required this.id,
    required this.number,
    required this.fromLocationId,
    required this.toLocationId,
    required this.status,
    this.companyId = '',
    this.fromLocationName = '',
    this.toLocationName = '',
    this.transferDate,
    this.notes,
    this.totalValue,
    this.createdAt,
    this.createdBy,
    this.receivedAt,
    this.receivedBy,
    this.cancelledAt,
    this.cancelReason,
    this.lines = const [],
  });

  factory Transfer.fromJson(Json json) => Transfer(
    id: asString(json['id']),
    companyId: asString(json['companyId']),
    number: asString(json['number']),
    fromLocationId: asString(json['fromLocationId']),
    fromLocationName: asString(json['fromLocationName']),
    toLocationId: asString(json['toLocationId']),
    toLocationName: asString(json['toLocationName']),
    status: TransferStatus.parse(json['status']),
    transferDate: asStringOrNull(json['transferDate']),
    notes: asStringOrNull(json['notes']),
    totalValue: asDoubleOrNull(json['totalValue']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: UserRef.maybe(json['createdBy']),
    receivedAt: asDateTimeOrNull(json['receivedAt']),
    receivedBy: UserRef.maybe(json['receivedBy']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
    lines: asJsonList(json['lines']).map(TransferLine.fromJson).toList(),
  );

  final String id;
  final String companyId;

  /// `TRF/26-27/00001`.
  final String number;
  final String fromLocationId;
  final String fromLocationName;
  final String toLocationId;
  final String toLocationName;
  final TransferStatus status;
  final String? transferDate;
  final String? notes;

  /// Only with `items.view_cost`.
  final double? totalValue;
  final DateTime? createdAt;
  final UserRef? createdBy;
  final DateTime? receivedAt;
  final UserRef? receivedBy;
  final DateTime? cancelledAt;
  final String? cancelReason;
  final List<TransferLine> lines;

  bool get isInTransit => status == TransferStatus.inTransit;
}

/// Body of `POST /transfers`.
class TransferDraft {
  const TransferDraft({
    required this.fromLocationId,
    required this.toLocationId,
    required this.lines,
    this.transferDate,
    this.notes,
  });

  final String fromLocationId;
  final String toLocationId;
  final String? transferDate;
  final String? notes;

  /// itemId → qty.
  final Map<String, double> lines;

  Json toJson() => withoutNulls({
    'fromLocationId': fromLocationId,
    'toLocationId': toLocationId,
    'transferDate': transferDate,
    'notes': notes,
    'lines': [
      for (final MapEntry(:key, :value) in lines.entries)
        {'itemId': key, 'qty': value},
    ],
  });
}

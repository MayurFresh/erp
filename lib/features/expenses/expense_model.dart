import '../../core/json.dart';
import '../documents/document_models.dart';

class Expense {
  const Expense({
    required this.id,
    required this.number,
    required this.locationId,
    required this.accountId,
    required this.description,
    required this.amount,
    required this.status,
    this.companyId = '',
    this.expenseDate,
    this.locationName = '',
    this.accountName = '',
    this.partyId,
    this.partyName,
    this.gstRate = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.total = 0,
    this.paidFromAccountId = '',
    this.paidFromAccountName = '',
    this.createdAt,
    this.createdBy,
    this.cancelledAt,
    this.cancelReason,
  });

  factory Expense.fromJson(Json json) => Expense(
    id: asString(json['id']),
    companyId: asString(json['companyId']),
    number: asString(json['number']),
    expenseDate: asStringOrNull(json['expenseDate']),
    locationId: asString(json['locationId']),
    locationName: asString(json['locationName']),
    accountId: asString(json['accountId']),
    accountName: asString(json['accountName']),
    partyId: asStringOrNull(json['partyId']),
    partyName: asStringOrNull(json['partyName']),
    description: asString(json['description']),
    amount: asDouble(json['amount']),
    gstRate: asDouble(json['gstRate']),
    cgst: asDouble(json['cgst']),
    sgst: asDouble(json['sgst']),
    igst: asDouble(json['igst']),
    total: asDouble(json['total']),
    paidFromAccountId: asString(json['paidFromAccountId']),
    paidFromAccountName: asString(json['paidFromAccountName']),
    status: DocStatus.parse(json['status']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: UserRef.maybe(json['createdBy']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
  );

  final String id;
  final String companyId;

  /// `EXP/26-27/00001`.
  final String number;
  final String? expenseDate;
  final String locationId;
  final String locationName;

  /// The expense head.
  final String accountId;
  final String accountName;
  final String? partyId;
  final String? partyName;
  final String description;

  /// Before GST.
  final double amount;
  final double gstRate;
  final double cgst;
  final double sgst;
  final double igst;
  final double total;
  final String paidFromAccountId;
  final String paidFromAccountName;
  final DocStatus status;
  final DateTime? createdAt;
  final UserRef? createdBy;
  final DateTime? cancelledAt;
  final String? cancelReason;

  double get taxTotal => cgst + sgst + igst;
  bool get isCancelled => status == DocStatus.cancelled;
}

/// Body of `POST /expenses`.
class ExpenseDraft {
  const ExpenseDraft({
    required this.locationId,
    required this.accountId,
    required this.description,
    required this.amount,
    required this.paidFromAccountId,
    this.expenseDate,
    this.gstRate,
    this.partyId,
  });

  final String locationId;
  final String accountId;
  final String description;
  final double amount;
  final String paidFromAccountId;
  final String? expenseDate;
  final double? gstRate;
  final String? partyId;

  Json toJson() => withoutNulls({
    'expenseDate': expenseDate,
    'locationId': locationId,
    'accountId': accountId,
    'description': description,
    'amount': amount,
    'gstRate': gstRate,
    'partyId': partyId,
    'paidFromAccountId': paidFromAccountId,
  });
}

/// Client-side estimate of an expense's GST (the server is authoritative):
/// CGST + SGST within a state, IGST across states, each rounded to paise.
({double cgst, double sgst, double igst, double total}) estimateExpenseTax(
  double amount,
  double gstRate, {
  required bool interState,
}) {
  final base = (amount * 100).round();
  final tax = (base * gstRate / 100).round();
  if (interState) {
    return (cgst: 0, sgst: 0, igst: tax / 100, total: (base + tax) / 100);
  }
  final half = (base * gstRate / 200).round();
  return (
    cgst: half / 100,
    sgst: half / 100,
    igst: 0,
    total: (base + 2 * half) / 100,
  );
}

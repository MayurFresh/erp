import '../../core/json.dart';
import '../documents/document_models.dart';

/// `receipt` = money in from a customer (allocates to invoices);
/// `payment` = money out to a vendor (allocates to purchases).
enum PaymentKind {
  receipt('Receipt', 'Receipts', '/receipts'),
  payment('Payment', 'Payments', '/payments');

  const PaymentKind(this.label, this.plural, this.basePath);

  final String label;
  final String plural;

  /// App route of the list, e.g. `/receipts`.
  final String basePath;

  static PaymentKind parse(Object? value) =>
      value == 'payment' ? PaymentKind.payment : PaymentKind.receipt;

  /// What the allocations settle.
  String get docLabel => this == receipt ? 'invoice' : 'bill';
  String get partyLabel => this == receipt ? 'Customer' : 'Vendor';
}

enum PaymentMode {
  cash('Cash'),
  bank('Bank transfer'),
  upi('UPI'),
  cheque('Cheque'),
  card('Card');

  const PaymentMode(this.label);

  final String label;

  static PaymentMode parse(Object? value) => PaymentMode.values.firstWhere(
    (m) => m.name == value,
    orElse: () => PaymentMode.cash,
  );
}

class PaymentAllocation {
  const PaymentAllocation({
    required this.docType,
    required this.docId,
    required this.docNumber,
    required this.amount,
    this.docDate,
    this.docTotal = 0,
  });

  factory PaymentAllocation.fromJson(Json json) => PaymentAllocation(
    docType: asString(json['docType']),
    docId: asString(json['docId']),
    docNumber: asString(json['docNumber']),
    docDate: asStringOrNull(json['docDate']),
    docTotal: asDouble(json['docTotal']),
    amount: asDouble(json['amount']),
  );

  /// `invoice` or `purchase`.
  final String docType;
  final String docId;
  final String docNumber;
  final String? docDate;
  final double docTotal;
  final double amount;

  String get route =>
      docType == 'purchase' ? '/purchases/$docId' : '/invoices/$docId';
}

class Payment {
  const Payment({
    required this.id,
    required this.kind,
    required this.number,
    required this.partyId,
    required this.partyName,
    required this.amount,
    required this.status,
    this.companyId = '',
    this.date,
    this.accountId = '',
    this.accountName = '',
    this.mode = PaymentMode.cash,
    this.reference,
    this.allocated = 0,
    this.unallocated = 0,
    this.notes,
    this.createdAt,
    this.createdBy,
    this.cancelledAt,
    this.cancelReason,
    this.allocations = const [],
  });

  factory Payment.fromJson(Json json) => Payment(
    id: asString(json['id']),
    companyId: asString(json['companyId']),
    kind: PaymentKind.parse(json['kind']),
    number: asString(json['number']),
    date: asStringOrNull(json['date']),
    partyId: asString(json['partyId']),
    partyName: asString(json['partyName']),
    accountId: asString(json['accountId']),
    accountName: asString(json['accountName']),
    mode: PaymentMode.parse(json['mode']),
    reference: asStringOrNull(json['reference']),
    amount: asDouble(json['amount']),
    allocated: asDouble(json['allocated']),
    unallocated: asDouble(json['unallocated']),
    notes: asStringOrNull(json['notes']),
    status: DocStatus.parse(json['status']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: UserRef.maybe(json['createdBy']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
    allocations: asJsonList(
      json['allocations'],
    ).map(PaymentAllocation.fromJson).toList(),
  );

  final String id;
  final String companyId;
  final PaymentKind kind;
  final String number;
  final String? date;
  final String partyId;
  final String partyName;

  /// The cash or bank account.
  final String accountId;
  final String accountName;
  final PaymentMode mode;
  final String? reference;
  final double amount;
  final double allocated;

  /// Advance left after allocations.
  final double unallocated;
  final String? notes;
  final DocStatus status;
  final DateTime? createdAt;
  final UserRef? createdBy;
  final DateTime? cancelledAt;
  final String? cancelReason;
  final List<PaymentAllocation> allocations;

  bool get isCancelled => status == DocStatus.cancelled;
}

/// Body of `POST /payments`.
class PaymentDraft {
  const PaymentDraft({
    required this.kind,
    required this.partyId,
    required this.accountId,
    required this.mode,
    required this.amount,
    this.date,
    this.reference,
    this.notes,
    this.allocations,
  });

  final PaymentKind kind;
  final String partyId;
  final String accountId;
  final PaymentMode mode;
  final double amount;
  final String? date;
  final String? reference;
  final String? notes;

  /// docId → amount. `null` lets the server allocate oldest first; an empty
  /// map keeps the whole amount as an advance.
  final Map<String, double>? allocations;

  Json toJson() => withoutNulls({
    'kind': kind.name,
    'partyId': partyId,
    'date': date,
    'accountId': accountId,
    'mode': mode.name,
    'reference': reference,
    'amount': amount,
    'notes': notes,
    'allocations': allocations == null
        ? null
        : [
            for (final MapEntry(:key, :value) in allocations!.entries)
              if (value > 0) {'docId': key, 'amount': value},
          ],
  });
}

/// An open invoice or purchase from `GET /parties/:id/outstanding`.
class OpenDoc {
  const OpenDoc({
    required this.id,
    required this.number,
    required this.total,
    required this.amountDue,
    this.date,
    this.dueDate,
  });

  factory OpenDoc.fromJson(Json json) => OpenDoc(
    id: asString(json['id']),
    number: asString(json['number']),
    date: asStringOrNull(json['date']),
    dueDate: asStringOrNull(json['dueDate']),
    total: asDouble(json['total']),
    amountDue: asDouble(json['amountDue']),
  );

  final String id;
  final String number;
  final String? date;
  final String? dueDate;
  final double total;
  final double amountDue;

  bool isOverdue(DateTime today) {
    final due = DateTime.tryParse(dueDate ?? '');
    return due != null &&
        due.isBefore(DateTime(today.year, today.month, today.day));
  }
}

class Outstanding {
  const Outstanding({
    this.balance = 0,
    this.invoices = const [],
    this.purchases = const [],
  });

  factory Outstanding.fromJson(Json json) => Outstanding(
    balance: asDouble(json['balance']),
    invoices: asJsonList(json['invoices']).map(OpenDoc.fromJson).toList(),
    purchases: asJsonList(json['purchases']).map(OpenDoc.fromJson).toList(),
  );

  /// `+` they owe us, `−` we owe them.
  final double balance;

  /// Oldest first.
  final List<OpenDoc> invoices;
  final List<OpenDoc> purchases;

  List<OpenDoc> docsFor(PaymentKind kind) =>
      kind == PaymentKind.receipt ? invoices : purchases;
}

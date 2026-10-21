import '../../core/json.dart';

class Account {
  const Account({
    required this.id,
    required this.code,
    required this.name,
    required this.type,
    required this.subtype,
    this.systemKey,
    this.isSystem = false,
    this.isActive = true,
    this.balance = 0,
  });

  factory Account.fromJson(Json json) => Account(
    id: asString(json['id']),
    code: asString(json['code']),
    name: asString(json['name']),
    type: asString(json['type']),
    subtype: asString(json['subtype'], 'other'),
    systemKey: asStringOrNull(json['systemKey']),
    isSystem: asBool(json['isSystem']),
    isActive: asBool(json['isActive'], true),
    balance: asDouble(json['balance']),
  );

  final String id;
  final String code;
  final String name;

  /// `asset`, `liability`, `equity`, `income` or `expense`.
  final String type;

  /// `cash`, `bank`, `receivables`, `payables`, `inventory`, `tax`, `other`.
  final String subtype;
  final String? systemKey;
  final bool isSystem;
  final bool isActive;

  /// Debit-positive.
  final double balance;

  bool get isCashOrBank => subtype == 'cash' || subtype == 'bank';

  /// Expense accounts users post to directly (not COGS, round off, …).
  bool get isExpenseHead => type == 'expense' && systemKey == null;

  String get displayName => code.isEmpty ? name : '$code · $name';
}

class LedgerLine {
  const LedgerLine({
    required this.entryId,
    required this.voucherType,
    this.date,
    this.voucherId,
    this.number,
    this.narration,
    this.partyName,
    this.debit = 0,
    this.credit = 0,
    this.balance = 0,
  });

  factory LedgerLine.fromJson(Json json) => LedgerLine(
    entryId: asString(json['entryId']),
    date: asStringOrNull(json['date']),
    voucherType: asString(json['voucherType']),
    voucherId: asStringOrNull(json['voucherId']),
    number: asStringOrNull(json['number']),
    narration: asStringOrNull(json['narration']),
    partyName: asStringOrNull(json['partyName']),
    debit: asDouble(json['debit']),
    credit: asDouble(json['credit']),
    balance: asDouble(json['balance']),
  );

  final String entryId;
  final String? date;

  /// `sales`, `purchase`, `receipt`, `payment`, `credit_note`, `expense`,
  /// `stock`, `transfer` or `journal`.
  final String voucherType;
  final String? voucherId;
  final String? number;
  final String? narration;
  final String? partyName;
  final double debit;
  final double credit;

  /// Running balance, debit-positive.
  final double balance;

  String get voucherLabel => voucherTypeLabel(voucherType);

  /// App route of the source document, if the app has a screen for it.
  String? get route {
    final id = voucherId;
    if (id == null) return null;
    return switch (voucherType) {
      'sales' => '/invoices/$id',
      'purchase' => '/purchases/$id',
      'receipt' => '/receipts/$id',
      'payment' => '/payments/$id',
      'credit_note' => '/credit-notes/$id',
      'expense' => '/expenses/$id',
      'transfer' => '/transfers/$id',
      _ => null,
    };
  }
}

String voucherTypeLabel(String type) => switch (type) {
  'sales' => 'Sales',
  'purchase' => 'Purchase',
  'receipt' => 'Receipt',
  'payment' => 'Payment',
  'credit_note' => 'Credit note',
  'expense' => 'Expense',
  'stock' => 'Stock',
  'transfer' => 'Transfer',
  'journal' => 'Journal',
  _ => type,
};

class Ledger {
  const Ledger({
    required this.accountId,
    required this.accountName,
    this.from,
    this.to,
    this.openingBalance = 0,
    this.closingBalance = 0,
    this.totalDebit = 0,
    this.totalCredit = 0,
    this.lines = const [],
  });

  factory Ledger.fromJson(Json json) => Ledger(
    accountId: asString(json['accountId']),
    accountName: asString(json['accountName']),
    from: asStringOrNull(json['from']),
    to: asStringOrNull(json['to']),
    openingBalance: asDouble(json['openingBalance']),
    closingBalance: asDouble(json['closingBalance']),
    totalDebit: asDouble(json['totalDebit']),
    totalCredit: asDouble(json['totalCredit']),
    lines: asJsonList(json['lines']).map(LedgerLine.fromJson).toList(),
  );

  final String accountId;
  final String accountName;
  final String? from;
  final String? to;
  final double openingBalance;
  final double closingBalance;
  final double totalDebit;
  final double totalCredit;
  final List<LedgerLine> lines;
}

/// `1500` → `₹1,500.00 Dr`, `-200` → `₹200.00 Cr` (debit-positive balances).
String drCr(double balance, String Function(num) format) {
  if (balance.abs() < 0.005) return format(0);
  return '${format(balance.abs())} ${balance > 0 ? 'Dr' : 'Cr'}';
}

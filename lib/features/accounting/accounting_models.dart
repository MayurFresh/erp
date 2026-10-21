/// Chart of accounts helpers, journal entries (day book) and the manual
/// journal draft with its balance rules. Pure Dart.
library;

import '../../core/json.dart';
import '../../core/money.dart';
import '../accounts/account_model.dart';
import '../documents/document_models.dart' show UserRef;

export '../accounts/account_model.dart'
    show Account, Ledger, LedgerLine, drCr, voucherTypeLabel;

// ------------------------------------------------------------ Account types

/// Account types in chart-of-accounts order.
const List<String> accountTypes = [
  'asset',
  'liability',
  'equity',
  'income',
  'expense',
];

/// `asset` → `Asset`.
String accountTypeLabel(String type) => switch (type) {
  'asset' => 'Asset',
  'liability' => 'Liability',
  'equity' => 'Equity',
  'income' => 'Income',
  'expense' => 'Expense',
  _ => type,
};

/// `asset` → `Assets` (group headings).
String accountGroupLabel(String type) => switch (type) {
  'asset' => 'Assets',
  'liability' => 'Liabilities',
  'equity' => 'Equity',
  'income' => 'Income',
  'expense' => 'Expenses',
  _ => type,
};

String accountSubtypeLabel(String subtype) => switch (subtype) {
  'cash' => 'Cash',
  'bank' => 'Bank',
  'receivables' => 'Receivables',
  'payables' => 'Payables',
  'inventory' => 'Inventory',
  'tax' => 'Tax',
  'other' => 'Other',
  _ => subtype,
};

/// Subtypes a user may choose when creating an account.
const List<String> creatableSubtypes = ['other', 'cash', 'bank'];

/// Assets and expenses normally carry a debit balance.
bool isDebitNature(String type) => type == 'asset' || type == 'expense';

/// Whether a journal line on [account] may name a party.
bool accountTakesParty(Account? account) =>
    account != null &&
    (account.subtype == 'receivables' || account.subtype == 'payables');

class AccountGroup {
  const AccountGroup(this.type, this.accounts);

  final String type;
  final List<Account> accounts;

  String get label => accountGroupLabel(type);

  /// Σ balances, debit-positive.
  double get total => accounts.fold(0, (sum, a) => sum + a.balance);
}

/// [accounts] grouped by type in chart order, each group by code; empty
/// groups are left out.
List<AccountGroup> groupAccounts(Iterable<Account> accounts) {
  final byType = <String, List<Account>>{};
  for (final account in accounts) {
    byType.putIfAbsent(account.type, () => []).add(account);
  }
  final order = [
    ...accountTypes,
    ...byType.keys.where((t) => !accountTypes.contains(t)),
  ];
  return [
    for (final type in order)
      if (byType[type]?.isNotEmpty ?? false)
        AccountGroup(type, byType[type]!..sort(_byCode)),
  ];
}

int _byCode(Account a, Account b) {
  final x = int.tryParse(a.code);
  final y = int.tryParse(b.code);
  if (x != null && y != null) return x.compareTo(y);
  return a.code.compareTo(b.code);
}

/// Code prefix or a case-insensitive part of the name.
bool accountMatches(Account account, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return account.code.toLowerCase().startsWith(q) ||
      account.name.toLowerCase().contains(q);
}

/// Body for `POST /accounts`.
class NewAccount {
  const NewAccount({
    required this.name,
    required this.type,
    this.subtype = 'other',
    this.code,
  });

  final String name;
  final String type;

  /// `cash`, `bank` (assets only) or `other`.
  final String subtype;
  final String? code;

  Json toJson() => withoutNulls({
    'name': name,
    'code': code,
    'type': type,
    'subtype': subtype,
  });
}

// ----------------------------------------------------------- Journal entries

const List<String> voucherTypes = [
  'sales',
  'purchase',
  'receipt',
  'payment',
  'credit_note',
  'expense',
  'stock',
  'transfer',
  'journal',
];

class JournalLine {
  const JournalLine({
    required this.accountId,
    required this.accountName,
    this.accountCode = '',
    this.partyId,
    this.partyName,
    this.debit = 0,
    this.credit = 0,
  });

  factory JournalLine.fromJson(Json json) => JournalLine(
    accountId: asString(json['accountId']),
    accountCode: asString(json['accountCode']),
    accountName: asString(json['accountName']),
    partyId: asStringOrNull(json['partyId']),
    partyName: asStringOrNull(json['partyName']),
    debit: asDouble(json['debit']),
    credit: asDouble(json['credit']),
  );

  final String accountId;
  final String accountCode;
  final String accountName;
  final String? partyId;
  final String? partyName;
  final double debit;
  final double credit;

  String get accountLabel =>
      accountCode.isEmpty ? accountName : '$accountCode · $accountName';
}

class JournalEntry {
  const JournalEntry({
    required this.id,
    required this.voucherType,
    this.date,
    this.voucherId,
    this.number,
    this.narration,
    this.isReversal = false,
    this.createdAt,
    this.createdBy,
    this.lines = const [],
  });

  factory JournalEntry.fromJson(Json json) => JournalEntry(
    id: asString(json['id']),
    date: asStringOrNull(json['date']),
    voucherType: asString(json['voucherType'], 'journal'),
    voucherId: asStringOrNull(json['voucherId']),
    number: asStringOrNull(json['number']),
    narration: asStringOrNull(json['narration']),
    isReversal: asBool(json['isReversal']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: UserRef.maybe(json['createdBy']),
    lines: asJsonList(json['lines']).map(JournalLine.fromJson).toList(),
  );

  final String id;
  final String? date;
  final String voucherType;
  final String? voucherId;

  /// The source document's number (`JV/..` for manual journals).
  final String? number;
  final String? narration;
  final bool isReversal;
  final DateTime? createdAt;
  final UserRef? createdBy;
  final List<JournalLine> lines;

  double get totalDebit => lines.fold(0, (s, l) => s + l.debit);
  double get totalCredit => lines.fold(0, (s, l) => s + l.credit);

  String get voucherLabel => voucherTypeLabel(voucherType);

  bool get isManual => voucherType == 'journal';

  /// Only manual journals (not their reversals) are cancelled from the day
  /// book; other entries are cancelled through their source document.
  bool get canCancel => isManual && !isReversal;

  /// App route of the source document, if the app has a screen for it.
  String? get documentRoute => LedgerLine(
    entryId: id,
    voucherType: voucherType,
    voucherId: voucherId,
  ).route;
}

// ------------------------------------------------------------ Manual journal

/// One row of the manual journal grid. Amounts are rupees; blank rows are
/// ignored.
class JournalDraftLine {
  const JournalDraftLine({
    this.accountId,
    this.accountSubtype,
    this.partyId,
    this.debit = 0,
    this.credit = 0,
  });

  final String? accountId;

  /// The chosen account's subtype (decides whether a party is allowed).
  final String? accountSubtype;
  final String? partyId;
  final double debit;
  final double credit;

  bool get isBlank =>
      accountId == null && debit == 0 && credit == 0 && partyId == null;

  bool get allowsParty =>
      accountSubtype == 'receivables' || accountSubtype == 'payables';

  int get debitPaise => (debit * 100).round();
  int get creditPaise => (credit * 100).round();

  /// Why this row cannot be posted, or `null`.
  String? get error {
    if (isBlank) return null;
    if (accountId == null) return 'Choose an account';
    if (debit < 0 || credit < 0) return 'Amounts cannot be negative';
    if (debitPaise > 0 && creditPaise > 0) {
      return 'Enter a debit or a credit, not both';
    }
    if (debitPaise <= 0 && creditPaise <= 0) return 'Enter a debit or credit';
    if (partyId != null && !allowsParty) {
      return 'A party can only be set on receivable or payable accounts';
    }
    return null;
  }

  Json toJson() => {
    'accountId': accountId,
    if (partyId != null && allowsParty) 'partyId': partyId,
    if (debitPaise > 0) 'debit': debitPaise / 100 else 'credit': creditPaise / 100,
  };
}

class JournalDraft {
  const JournalDraft({required this.lines, this.date, this.narration = ''});

  static const int minLines = 2;
  static const int maxLines = 50;

  final DateTime? date;
  final String narration;
  final List<JournalDraftLine> lines;

  List<JournalDraftLine> get filledLines =>
      lines.where((l) => !l.isBlank).toList();

  int get totalDebitPaise => filledLines.fold(0, (s, l) => s + l.debitPaise);
  int get totalCreditPaise => filledLines.fold(0, (s, l) => s + l.creditPaise);

  double get totalDebit => totalDebitPaise / 100;
  double get totalCredit => totalCreditPaise / 100;

  /// Debit minus credit; zero when balanced.
  double get difference => (totalDebitPaise - totalCreditPaise) / 100;

  bool get isBalanced =>
      totalDebitPaise == totalCreditPaise && totalDebitPaise > 0;

  /// Reasons the journal cannot be saved yet, in display order.
  List<String> get problems {
    final filled = filledLines;
    return [
      if (narration.trim().length < 3) 'Add a narration (at least 3 letters)',
      if (filled.length < minLines) 'Add at least $minLines lines',
      if (filled.length > maxLines) 'Use at most $maxLines lines',
      if (filled.any((l) => l.error != null)) 'Fix the highlighted lines',
      if (!isBalanced && filled.length >= minLines)
        totalDebitPaise == 0 && totalCreditPaise == 0
            ? 'Enter the amounts'
            : 'Debits and credits must be equal',
    ];
  }

  bool get canSave => problems.isEmpty;

  /// Body for `POST /journals`.
  Json toJson() => {
    if (date != null) 'date': apiDate(date!),
    'narration': narration.trim(),
    'lines': [for (final l in filledLines) l.toJson()],
  };
}

/// `Balanced`, `Debit exceeds credit by ₹50.00` or the credit equivalent.
String journalDifferenceLabel(double difference) {
  if (difference.abs() < 0.005) return 'Balanced';
  final amount = formatMoney(difference.abs());
  return difference > 0
      ? 'Debit exceeds credit by $amount'
      : 'Credit exceeds debit by $amount';
}

/// `lines.3.debit` → `3` (validation details from `POST /journals`).
int? journalLineIndex(String field) {
  final match = RegExp(r'^lines\.(\d+)\.').firstMatch(field);
  return match == null ? null : int.parse(match.group(1)!);
}

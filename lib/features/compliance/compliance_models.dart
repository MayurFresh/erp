/// Models of the statutory core (API v1.4 sections 5 to 8).
library;

import '../../core/json.dart';

double _d(Object? v) => asDouble(v);

class Tax {
  const Tax({this.taxable = 0, this.igst = 0, this.cgst = 0, this.sgst = 0});

  factory Tax.fromJson(Object? v) {
    final j = asJsonOrNull(v);
    if (j == null) return const Tax();
    return Tax(
      taxable: _d(j['taxable']),
      igst: _d(j['igst']),
      cgst: _d(j['cgst']),
      sgst: _d(j['sgst']),
    );
  }

  final double taxable;
  final double igst;
  final double cgst;
  final double sgst;

  double get tax => igst + cgst + sgst;
}

class RateRow {
  const RateRow({required this.rate, required this.tax});

  factory RateRow.fromJson(Json j) =>
      RateRow(rate: _d(j['rate']), tax: Tax.fromJson(j));

  final double rate;
  final Tax tax;
}

/// One invoice, credit note or summary line of a GSTR-1 section.
class Gstr1Row {
  const Gstr1Row({
    required this.id,
    required this.number,
    required this.date,
    required this.party,
    required this.gstin,
    required this.pos,
    required this.value,
    required this.tax,
    this.ref = '',
  });

  final String id;
  final String number;
  final String date;
  final String party;
  final String gstin;
  final String pos;
  final double value;
  final Tax tax;

  /// Original invoice number (credit notes) or a description.
  final String ref;
}

Tax _sumRates(Object? rates) {
  var t = const Tax();
  for (final r in asJsonList(rates)) {
    final x = Tax.fromJson(r);
    t = Tax(
      taxable: t.taxable + x.taxable,
      igst: t.igst + x.igst,
      cgst: t.cgst + x.cgst,
      sgst: t.sgst + x.sgst,
    );
  }
  return t;
}

class Gstr1Section {
  const Gstr1Section(this.key, this.title, this.rows);

  final String key;
  final String title;
  final List<Gstr1Row> rows;

  int get count => rows.length;

  Tax get total => rows.fold(
    const Tax(),
    (a, r) => Tax(
      taxable: a.taxable + r.tax.taxable,
      igst: a.igst + r.tax.igst,
      cgst: a.cgst + r.tax.cgst,
      sgst: a.sgst + r.tax.sgst,
    ),
  );
}

class DocRange {
  const DocRange({
    required this.kind,
    required this.from,
    required this.to,
    required this.total,
    required this.cancelled,
  });

  factory DocRange.fromJson(Json j) => DocRange(
    kind: asString(j['kind']),
    from: asString(j['from']),
    to: asString(j['to']),
    total: asInt(j['total']),
    cancelled: asInt(j['cancelled']),
  );

  final String kind;
  final String from;
  final String to;
  final int total;
  final int cancelled;
}

class HsnRow {
  const HsnRow({
    required this.segment,
    required this.hsnCode,
    required this.description,
    required this.unit,
    required this.qty,
    required this.rate,
    required this.tax,
  });

  factory HsnRow.fromJson(Json j) => HsnRow(
    segment: asString(j['segment']),
    hsnCode: asString(j['hsnCode']),
    description: asString(j['description']),
    unit: asString(j['unit']),
    qty: _d(j['qty']),
    rate: _d(j['rate']),
    tax: Tax.fromJson(j),
  );

  final String segment;
  final String hsnCode;
  final String description;
  final String unit;
  final double qty;
  final double rate;
  final Tax tax;
}

class Gstr1 {
  const Gstr1({
    required this.period,
    required this.gstin,
    required this.filing,
    required this.sections,
    required this.hsn,
    required this.docs,
    required this.nil,
    required this.totals,
    required this.ledger,
    required this.variance,
    required this.warnings,
  });

  factory Gstr1.fromJson(Json j) {
    List<Gstr1Row> invoices(Object? list, String idKey, String valueKey) => [
      for (final r in asJsonList(list))
        Gstr1Row(
          id: asString(r[idKey]),
          number: asString(r['number']),
          date: asString(r['date']),
          party: asString(r['partyName']),
          gstin: asString(r['gstin']),
          pos: asString(r['placeOfSupply']),
          value: _d(r[valueKey]),
          tax: _sumRates(r['rates']),
          ref: asString(r['invoiceNumber']),
        ),
    ];
    final b2cs = <Gstr1Row>[
      for (final r in asJsonList(j['b2cs']))
        Gstr1Row(
          id: '',
          number: '${asString(r['supplyType'])} @ ${asString(r['rate'])}%',
          date: '',
          party: '',
          gstin: '',
          pos: asString(r['placeOfSupply']),
          value:
              _d(r['taxable']) + _d(r['igst']) + _d(r['cgst']) + _d(r['sgst']),
          tax: Tax.fromJson(r),
        ),
    ];
    final nil = asJsonOrNull(j['nil']) ?? const {};
    return Gstr1(
      period: asString(j['period']),
      gstin: asString(j['gstin']),
      filing: asString(j['filing'], 'monthly'),
      sections: [
        Gstr1Section(
          'b2b',
          'B2B invoices',
          invoices(j['b2b'], 'invoiceId', 'invoiceValue'),
        ),
        Gstr1Section(
          'b2cl',
          'B2C large invoices',
          invoices(j['b2cl'], 'invoiceId', 'invoiceValue'),
        ),
        Gstr1Section('b2cs', 'B2C small (summary)', b2cs),
        Gstr1Section(
          'cdnr',
          'Credit notes (registered)',
          invoices(j['cdnr'], 'creditNoteId', 'noteValue'),
        ),
        Gstr1Section(
          'cdnur',
          'Credit notes (unregistered)',
          invoices(j['cdnur'], 'creditNoteId', 'noteValue'),
        ),
      ],
      hsn: asJsonList(j['hsn']).map(HsnRow.fromJson).toList(),
      docs: asJsonList(j['docs']).map(DocRange.fromJson).toList(),
      nil: {for (final e in nil.entries) e.key: _d(e.value)},
      totals: Tax.fromJson(j['totals']),
      ledger: Tax.fromJson(j['ledger']),
      variance: Tax.fromJson(j['variance']),
      warnings: asStringList(j['warnings']),
    );
  }

  final String period;
  final String gstin;
  final String filing;
  final List<Gstr1Section> sections;
  final List<HsnRow> hsn;
  final List<DocRange> docs;
  final Map<String, double> nil;
  final Tax totals;
  final Tax ledger;
  final Tax variance;
  final List<String> warnings;

  bool get hasVariance =>
      variance.igst.abs() >= 1 ||
      variance.cgst.abs() >= 1 ||
      variance.sgst.abs() >= 1;
}

class Gstr3b {
  const Gstr3b({
    required this.period,
    required this.outward,
    required this.zeroNil,
    required this.inwardRcm,
    required this.interState,
    required this.itcRcm,
    required this.itcOthers,
    required this.itcReversed,
    required this.itcNet,
    required this.payable,
    required this.rcmCash,
    required this.warnings,
  });

  factory Gstr3b.fromJson(Json j) {
    final itc = asJsonOrNull(j['itc']) ?? const {};
    return Gstr3b(
      period: asString(j['period']),
      outward: Tax.fromJson(j['outward']),
      zeroNil: _d(asJsonOrNull(j['zeroNil'])?['taxable']),
      inwardRcm: Tax.fromJson(j['inwardRcm']),
      interState: asJsonList(j['interStateUnregistered'])
          .map(
            (r) => (
              pos: asString(r['placeOfSupply']),
              taxable: _d(r['taxable']),
              igst: _d(r['igst']),
            ),
          )
          .toList(),
      itcRcm: Tax.fromJson(itc['rcm']),
      itcOthers: Tax.fromJson(itc['others']),
      itcReversed: Tax.fromJson(itc['reversed']),
      itcNet: Tax.fromJson(itc['net']),
      payable: Tax.fromJson(j['payable']),
      rcmCash: Tax.fromJson(j['rcmCash']),
      warnings: asStringList(j['warnings']),
    );
  }

  final String period;
  final Tax outward;
  final double zeroNil;
  final Tax inwardRcm;
  final List<({String pos, double taxable, double igst})> interState;
  final Tax itcRcm;
  final Tax itcOthers;
  final Tax itcReversed;
  final Tax itcNet;
  final Tax payable;
  final Tax rcmCash;
  final List<String> warnings;
}

enum ReconStatus {
  matched('Matched'),
  mismatch('Mismatch'),
  missingInBooks('Missing in books'),
  missingIn2b('Missing in 2B');

  const ReconStatus(this.label);
  final String label;

  String get wire => switch (this) {
    matched => 'matched',
    mismatch => 'mismatch',
    missingInBooks => 'missing_in_books',
    missingIn2b => 'missing_in_2b',
  };

  static ReconStatus parse(Object? v) =>
      values.firstWhere((s) => s.wire == v, orElse: () => ReconStatus.mismatch);
}

class ReconRow {
  const ReconRow({
    required this.id,
    required this.status,
    required this.supplierGstin,
    required this.supplierName,
    required this.docType,
    required this.docNo,
    required this.docDate,
    required this.tax,
    required this.purchaseId,
    required this.purchaseNumber,
    required this.book,
    required this.diff,
    required this.imsAction,
    required this.note,
  });

  factory ReconRow.fromJson(Json j) => ReconRow(
    id: asStringOrNull(j['id']),
    status: ReconStatus.parse(j['status']),
    supplierGstin: asString(j['supplierGstin']),
    supplierName: asString(j['supplierName']),
    docType: asString(j['docType']),
    docNo: asString(j['docNo']),
    docDate: asString(j['docDate']),
    tax: Tax.fromJson(j),
    purchaseId: asStringOrNull(j['purchaseId']),
    purchaseNumber: asStringOrNull(j['purchaseNumber']),
    book: j['book'] == null ? null : Tax.fromJson(j['book']),
    diff: j['diff'] == null ? null : Tax.fromJson(j['diff']),
    imsAction: asString(j['imsAction'], 'none'),
    note: asString(j['note']),
  );

  final String? id;
  final ReconStatus status;
  final String supplierGstin;
  final String supplierName;
  final String docType;
  final String docNo;
  final String docDate;
  final Tax tax;
  final String? purchaseId;
  final String? purchaseNumber;
  final Tax? book;
  final Tax? diff;
  final String imsAction;
  final String note;
}

class ReconSummary {
  const ReconSummary({
    this.matched = 0,
    this.mismatch = 0,
    this.missingInBooks = 0,
    this.missingIn2b = 0,
    this.itcMatched = const Tax(),
    this.itcAtRisk = const Tax(),
  });

  factory ReconSummary.fromJson(Object? v) {
    final j = asJsonOrNull(v) ?? const {};
    return ReconSummary(
      matched: asInt(j['matched']),
      mismatch: asInt(j['mismatch']),
      missingInBooks: asInt(j['missingInBooks']),
      missingIn2b: asInt(j['missingIn2b']),
      itcMatched: Tax.fromJson(j['itcMatched']),
      itcAtRisk: Tax.fromJson(j['itcAtRisk']),
    );
  }

  final int matched;
  final int mismatch;
  final int missingInBooks;
  final int missingIn2b;
  final Tax itcMatched;
  final Tax itcAtRisk;
}

class Recon {
  const Recon({
    required this.period,
    this.importedAt,
    required this.summary,
    required this.rows,
  });

  factory Recon.fromJson(Json j) => Recon(
    period: asString(j['period']),
    importedAt: asStringOrNull(j['importedAt']),
    summary: ReconSummary.fromJson(j['summary']),
    rows: asJsonList(j['rows']).map(ReconRow.fromJson).toList(),
  );

  final String period;
  final String? importedAt;
  final ReconSummary summary;
  final List<ReconRow> rows;
}

class ItcRow {
  const ItcRow({
    required this.purchaseId,
    required this.number,
    required this.partyName,
    required this.billDate,
    required this.day180,
    required this.daysLeft,
    required this.total,
    required this.unpaid,
    required this.itc,
    required this.reversal,
    required this.status,
  });

  factory ItcRow.fromJson(Json j) => ItcRow(
    purchaseId: asString(j['purchaseId']),
    number: asString(j['number']),
    partyName: asString(j['partyName']),
    billDate: asString(j['billDate']),
    day180: asString(j['day180']),
    daysLeft: asInt(j['daysLeft']),
    total: _d(j['total']),
    unpaid: _d(j['unpaid']),
    itc: _d(j['itc']),
    reversal: _d(j['reversal']),
    status: asString(j['status'], 'ok'),
  );

  final String purchaseId;
  final String number;
  final String partyName;
  final String billDate;
  final String day180;
  final int daysLeft;
  final double total;
  final double unpaid;
  final double itc;
  final double reversal;
  final String status;
}

class ItcAgeing {
  const ItcAgeing({
    required this.asOf,
    required this.rows,
    required this.unpaid,
    required this.itc,
    required this.reversal,
  });

  factory ItcAgeing.fromJson(Json j) {
    final t = asJsonOrNull(j['totals']) ?? const {};
    return ItcAgeing(
      asOf: asString(j['asOf']),
      rows: asJsonList(j['rows']).map(ItcRow.fromJson).toList(),
      unpaid: _d(t['unpaid']),
      itc: _d(t['itc']),
      reversal: _d(t['reversal']),
    );
  }

  final String asOf;
  final List<ItcRow> rows;
  final double unpaid;
  final double itc;
  final double reversal;
}

// ---------------------------------------------------------------------- TDS

class TdsDeduction {
  const TdsDeduction({
    required this.id,
    required this.sourceType,
    required this.sourceId,
    required this.number,
    required this.date,
    required this.partyName,
    required this.pan,
    required this.sectionCode,
    required this.gross,
    required this.base,
    required this.rate,
    required this.amount,
    required this.status,
    required this.challanId,
    required this.challanNumber,
  });

  factory TdsDeduction.fromJson(Json j) => TdsDeduction(
    id: asString(j['id']),
    sourceType: asString(j['sourceType']),
    sourceId: asString(j['sourceId']),
    number: asString(j['number']),
    date: asString(j['date']),
    partyName: asString(j['partyName']),
    pan: asStringOrNull(j['pan']),
    sectionCode: asString(j['sectionCode']),
    gross: _d(j['gross']),
    base: _d(j['base']),
    rate: _d(j['rate']),
    amount: _d(j['amount']),
    status: asString(j['status'], 'active'),
    challanId: asStringOrNull(j['challanId']),
    challanNumber: asStringOrNull(j['challanNumber']),
  );

  final String id;
  final String sourceType;
  final String sourceId;
  final String number;
  final String date;
  final String partyName;
  final String? pan;
  final String sectionCode;
  final double gross;
  final double base;
  final double rate;
  final double amount;
  final String status;
  final String? challanId;
  final String? challanNumber;

  bool get depositable => status == 'active' && challanId == null && amount > 0;

  /// App route of the source document, when there is one.
  String? get sourcePath => switch (sourceType) {
    'purchase' => '/purchases/$sourceId',
    'expense' => '/expenses/$sourceId',
    _ => null,
  };
}

class TdsChallan {
  const TdsChallan({
    required this.id,
    required this.number,
    required this.depositDate,
    required this.bsrCode,
    required this.challanSerial,
    required this.taxAmount,
    required this.interest,
    required this.lateFee,
    required this.total,
    required this.paidFromAccountName,
    required this.status,
    required this.createdByName,
    required this.cancelReason,
    required this.deductions,
  });

  factory TdsChallan.fromJson(Json j) => TdsChallan(
    id: asString(j['id']),
    number: asString(j['number']),
    depositDate: asString(j['depositDate']),
    bsrCode: asString(j['bsrCode']),
    challanSerial: asString(j['challanSerial']),
    taxAmount: _d(j['taxAmount']),
    interest: _d(j['interest']),
    lateFee: _d(j['lateFee']),
    total: _d(j['total']),
    paidFromAccountName: asString(j['paidFromAccountName']),
    status: asString(j['status'], 'posted'),
    createdByName: asString(asJsonOrNull(j['createdBy'])?['name']),
    cancelReason: asStringOrNull(j['cancelReason']),
    deductions: asJsonList(j['deductions']).map(TdsDeduction.fromJson).toList(),
  );

  final String id;
  final String number;
  final String depositDate;
  final String bsrCode;
  final String challanSerial;
  final double taxAmount;
  final double interest;
  final double lateFee;
  final double total;
  final String paidFromAccountName;
  final String status;
  final String createdByName;
  final String? cancelReason;
  final List<TdsDeduction> deductions;

  bool get cancelled => status == 'cancelled';
}

class TdsMonth {
  const TdsMonth({
    required this.month,
    required this.deducted,
    required this.deposited,
    required this.pending,
    required this.dueDate,
    required this.overdue,
  });

  factory TdsMonth.fromJson(Json j) => TdsMonth(
    month: asString(j['month']),
    deducted: _d(j['deducted']),
    deposited: _d(j['deposited']),
    pending: _d(j['pending']),
    dueDate: asString(j['dueDate']),
    overdue: asBool(j['overdue']),
  );

  final String month;
  final double deducted;
  final double deposited;
  final double pending;
  final String dueDate;
  final bool overdue;
}

class TdsQuarter {
  const TdsQuarter({
    required this.quarter,
    required this.form,
    required this.dueDate,
    required this.rows,
    required this.amount,
  });

  factory TdsQuarter.fromJson(Json j) => TdsQuarter(
    quarter: asInt(j['quarter']),
    form: asString(j['form']),
    dueDate: asString(j['dueDate']),
    rows: asInt(j['rows']),
    amount: _d(j['amount']),
  );

  final int quarter;
  final String form;
  final String dueDate;
  final int rows;
  final double amount;
}

class TdsSummary {
  const TdsSummary({
    required this.fy,
    required this.months,
    required this.quarters,
  });

  factory TdsSummary.fromJson(Json j) => TdsSummary(
    fy: asString(j['fy']),
    months: asJsonList(j['months']).map(TdsMonth.fromJson).toList(),
    quarters: asJsonList(j['quarters']).map(TdsQuarter.fromJson).toList(),
  );

  final String fy;
  final List<TdsMonth> months;
  final List<TdsQuarter> quarters;
}

class TdsStatement {
  const TdsStatement({
    required this.form,
    required this.fy,
    required this.quarter,
    required this.deductorName,
    required this.tan,
    required this.pan,
    required this.challans,
    required this.rows,
    required this.warnings,
  });

  factory TdsStatement.fromJson(Json j) {
    final d = asJsonOrNull(j['deductor']) ?? const {};
    return TdsStatement(
      form: asString(j['form'], '140'),
      fy: asString(j['fy']),
      quarter: asInt(j['quarter']),
      deductorName: asString(d['name']),
      tan: asStringOrNull(d['tan']),
      pan: asStringOrNull(d['pan']),
      challans: asJsonList(j['challans']).map(TdsChallan.fromJson).toList(),
      rows: asJsonList(j['rows']),
      warnings: asStringList(j['warnings']),
    );
  }

  final String form;
  final String fy;
  final int quarter;
  final String deductorName;
  final String? tan;
  final String? pan;
  final List<TdsChallan> challans;
  final List<Json> rows;
  final List<String> warnings;
}

// -------------------------------------------------------------- Bank recon

class BankStatement {
  const BankStatement({
    required this.id,
    required this.accountId,
    required this.accountName,
    required this.fileName,
    required this.fromDate,
    required this.toDate,
    required this.closingBalance,
    required this.lines,
    required this.matched,
    required this.unmatched,
    required this.ignored,
    this.bookBalance,
    this.unmatchedBook = 0,
    this.lineRows = const [],
  });

  factory BankStatement.fromJson(Json j) => BankStatement(
    id: asString(j['id']),
    accountId: asString(j['accountId']),
    accountName: asString(j['accountName']),
    fileName: asString(j['fileName']),
    fromDate: asString(j['fromDate']),
    toDate: asString(j['toDate']),
    closingBalance: asDoubleOrNull(j['closingBalance']),
    lines: j['lines'] is List ? (j['lines'] as List).length : asInt(j['lines']),
    matched: asInt(j['matched']),
    unmatched: asInt(j['unmatched']),
    ignored: asInt(j['ignored']),
    bookBalance: asDoubleOrNull(j['bookBalance']),
    unmatchedBook: asInt(j['unmatchedBook']),
    lineRows: j['lines'] is List
        ? asJsonList(j['lines']).map(BankLine.fromJson).toList()
        : const [],
  );

  final String id;
  final String accountId;
  final String accountName;
  final String fileName;
  final String fromDate;
  final String toDate;
  final double? closingBalance;
  final int lines;
  final int matched;
  final int unmatched;
  final int ignored;
  final double? bookBalance;
  final int unmatchedBook;
  final List<BankLine> lineRows;

  /// Statement closing balance less the books; `null` when either is missing.
  double? get difference => closingBalance == null || bookBalance == null
      ? null
      : closingBalance! - bookBalance!;
}

class BankMatch {
  const BankMatch({
    required this.journalLineId,
    required this.voucherType,
    required this.number,
    required this.date,
    required this.narration,
    required this.amount,
  });

  factory BankMatch.fromJson(Json j) => BankMatch(
    journalLineId: asString(j['journalLineId']),
    voucherType: asString(j['voucherType']),
    number: asString(j['number']),
    date: asString(j['date']),
    narration: asString(j['narration']),
    amount: _d(j['amount']),
  );

  final String journalLineId;
  final String voucherType;
  final String number;
  final String date;
  final String narration;
  final double amount;
}

class BankLine {
  const BankLine({
    required this.id,
    required this.lineNo,
    required this.date,
    required this.description,
    required this.reference,
    required this.withdrawal,
    required this.deposit,
    required this.balance,
    required this.status,
    required this.match,
  });

  factory BankLine.fromJson(Json j) => BankLine(
    id: asString(j['id']),
    lineNo: asInt(j['lineNo']),
    date: asString(j['date']),
    description: asString(j['description']),
    reference: asStringOrNull(j['reference']),
    withdrawal: _d(j['withdrawal']),
    deposit: _d(j['deposit']),
    balance: asDoubleOrNull(j['balance']),
    status: asString(j['status'], 'unmatched'),
    match: asJsonOrNull(j['match']) == null
        ? null
        : BankMatch.fromJson(asJson(j['match'])),
  );

  final String id;
  final int lineNo;
  final String date;
  final String description;
  final String? reference;
  final double withdrawal;
  final double deposit;
  final double? balance;
  final String status;
  final BankMatch? match;

  bool get isDeposit => deposit > 0;
  double get amount => isDeposit ? deposit : withdrawal;
}

class BankCandidate {
  const BankCandidate({
    required this.journalLineId,
    required this.voucherType,
    required this.number,
    required this.date,
    required this.narration,
    required this.amount,
    required this.partyName,
    required this.score,
  });

  factory BankCandidate.fromJson(Json j) => BankCandidate(
    journalLineId: asString(j['journalLineId']),
    voucherType: asString(j['voucherType']),
    number: asString(j['number']),
    date: asString(j['date']),
    narration: asString(j['narration']),
    amount: _d(j['amount']),
    partyName: asString(j['partyName']),
    score: _d(j['score']),
  );

  final String journalLineId;
  final String voucherType;
  final String number;
  final String date;
  final String narration;
  final double amount;
  final String partyName;
  final double score;
}

// ------------------------------------------------------------- MSME dues

class MsmeRow {
  const MsmeRow({
    required this.purchaseId,
    required this.number,
    required this.partyId,
    required this.partyName,
    required this.udyamNo,
    required this.category,
    required this.billDate,
    required this.dueDate,
    required this.unpaid,
    required this.daysOverdue,
    required this.interest,
  });

  factory MsmeRow.fromJson(Json j) => MsmeRow(
    purchaseId: asString(j['purchaseId']),
    number: asString(j['number']),
    partyId: asString(j['partyId']),
    partyName: asString(j['partyName']),
    udyamNo: asStringOrNull(j['udyamNo']),
    category: asString(j['category']),
    billDate: asString(j['billDate']),
    dueDate: asString(j['msmeDueDate']),
    unpaid: _d(j['unpaid']),
    daysOverdue: asInt(j['daysOverdue']),
    interest: asDoubleOrNull(j['interest']),
  );

  final String purchaseId;
  final String number;
  final String partyId;
  final String partyName;
  final String? udyamNo;
  final String category;
  final String billDate;
  final String dueDate;
  final double unpaid;
  final int daysOverdue;
  final double? interest;
}

class MsmeDues {
  const MsmeDues({
    required this.asOf,
    required this.bankRate,
    required this.rows,
    required this.unpaid,
    required this.overdue,
    required this.interest,
    required this.yearEndDisallowance,
    required this.warnings,
  });

  factory MsmeDues.fromJson(Json j) {
    final t = asJsonOrNull(j['totals']) ?? const {};
    return MsmeDues(
      asOf: asString(j['asOf']),
      bankRate: asDoubleOrNull(j['bankRate']),
      rows: asJsonList(j['rows']).map(MsmeRow.fromJson).toList(),
      unpaid: _d(t['unpaid']),
      overdue: _d(t['overdue']),
      interest: _d(t['interest']),
      yearEndDisallowance: _d(j['yearEndDisallowance']),
      warnings: asStringList(j['warnings']),
    );
  }

  final String asOf;
  final double? bankRate;
  final List<MsmeRow> rows;
  final double unpaid;
  final double overdue;
  final double interest;
  final double yearEndDisallowance;
  final List<String> warnings;
}

// -------------------------------------------------- Docs, alerts, health

const complianceCategories = [
  'licence',
  'registration',
  'insurance',
  'certificate',
  'agreement',
  'other',
];

class ComplianceDoc {
  const ComplianceDoc({
    required this.id,
    required this.name,
    required this.category,
    required this.docNo,
    required this.issuedBy,
    required this.issueDate,
    required this.expiryDate,
    required this.remindDays,
    required this.locationId,
    required this.locationName,
    required this.notes,
    required this.isActive,
    required this.status,
    required this.daysLeft,
  });

  factory ComplianceDoc.fromJson(Json j) => ComplianceDoc(
    id: asString(j['id']),
    name: asString(j['name']),
    category: asString(j['category'], 'other'),
    docNo: asString(j['docNo']),
    issuedBy: asString(j['issuedBy']),
    issueDate: asStringOrNull(j['issueDate']),
    expiryDate: asStringOrNull(j['expiryDate']),
    remindDays: asInt(j['remindDays'], 30),
    locationId: asStringOrNull(j['locationId']),
    locationName: asStringOrNull(j['locationName']),
    notes: asString(j['notes']),
    isActive: asBool(j['isActive'], true),
    status: asString(j['status'], 'valid'),
    daysLeft: j['daysLeft'] == null ? null : asInt(j['daysLeft']),
  );

  final String id;
  final String name;
  final String category;
  final String docNo;
  final String issuedBy;
  final String? issueDate;
  final String? expiryDate;
  final int remindDays;
  final String? locationId;
  final String? locationName;
  final String notes;
  final bool isActive;
  final String status;
  final int? daysLeft;
}

class Alert {
  const Alert({
    required this.kind,
    required this.severity,
    required this.title,
    required this.detail,
    required this.dueDate,
    required this.link,
  });

  factory Alert.fromJson(Json j) => Alert(
    kind: asString(j['kind']),
    severity: asString(j['severity'], 'info'),
    title: asString(j['title']),
    detail: asString(j['detail']),
    dueDate: asStringOrNull(j['dueDate']),
    link: asString(j['link']),
  );

  final String kind;
  final String severity;
  final String title;
  final String detail;
  final String? dueDate;
  final String link;
}

class HealthCheck {
  const HealthCheck({
    required this.key,
    required this.ok,
    required this.required,
    required this.title,
    required this.detail,
    required this.link,
  });

  factory HealthCheck.fromJson(Json j) => HealthCheck(
    key: asString(j['key']),
    ok: asBool(j['ok']),
    required: asString(j['severity']) == 'required',
    title: asString(j['title']),
    detail: asString(j['detail']),
    link: asString(j['link']),
  );

  final String key;
  final bool ok;
  final bool required;
  final String title;
  final String detail;
  final String link;
}

class SetupHealth {
  const SetupHealth({required this.score, required this.checks});

  factory SetupHealth.fromJson(Json j) => SetupHealth(
    score: asInt(j['score']),
    checks: asJsonList(j['checks']).map(HealthCheck.fromJson).toList(),
  );

  final int score;
  final List<HealthCheck> checks;
}

/// The datasets of `GET /export/:dataset`.
const exportDatasets = <(String, String, String)>[
  ('parties', 'Parties', 'Customers and vendors with GSTIN, PAN and balances'),
  ('items', 'Items', 'Item master with HSN, GST rate and prices'),
  ('invoices', 'Invoices', 'One row per sales invoice'),
  ('invoice-lines', 'Invoice lines', 'One row per invoice line'),
  ('purchases', 'Purchases', 'One row per purchase bill'),
  ('purchase-lines', 'Purchase lines', 'One row per purchase line'),
  ('payments', 'Payments and receipts', 'Money in and out with allocations'),
  ('expenses', 'Expenses', 'One row per expense'),
  ('journal', 'Day book (journal)', 'Every posted journal line'),
];

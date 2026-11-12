import '../../core/json.dart';

double _d(Object? v) => asDouble(v);
String _s(Object? v, [String fallback = '']) => asString(v, fallback);

class Totals {
  const Totals({
    this.budget = 0,
    this.actual = 0,
    this.committed = 0,
    this.available = 0,
  });

  factory Totals.fromJson(Json j) => Totals(
    budget: _d(j['budget']),
    actual: _d(j['actual']),
    committed: _d(j['committed']),
    available: _d(j['available']),
  );

  final double budget;
  final double actual;
  final double committed;
  final double available;
}

/// A budget head with its figures. Parents add up the heads under them.
class HeadRow {
  const HeadRow({
    required this.id,
    required this.fy,
    required this.parentId,
    required this.level,
    required this.code,
    required this.name,
    required this.accountId,
    required this.accountName,
    required this.isLeaf,
    required this.isActive,
    required this.estimate,
    required this.revised,
    required this.reappIn,
    required this.reappOut,
    required this.budget,
    required this.actual,
    required this.committed,
    required this.available,
    required this.percentUsed,
    required this.percentCommitted,
    required this.updatedAt,
  });

  factory HeadRow.fromJson(Json j) => HeadRow(
    id: _s(j['id']),
    fy: _s(j['fy']),
    parentId: asStringOrNull(j['parentId']),
    level: _s(j['level'], 'object'),
    code: _s(j['code']),
    name: _s(j['name']),
    accountId: asStringOrNull(j['accountId']),
    accountName: asStringOrNull(j['accountName']),
    isLeaf: asBool(j['isLeaf']),
    isActive: asBool(j['isActive'], true),
    estimate: _d(j['estimate']),
    revised: asDoubleOrNull(j['revised']),
    reappIn: _d(j['reappIn']),
    reappOut: _d(j['reappOut']),
    budget: _d(j['budget']),
    actual: _d(j['actual']),
    committed: _d(j['committed']),
    available: _d(j['available']),
    percentUsed: _d(j['percentUsed']),
    percentCommitted: _d(j['percentCommitted']),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id;
  final String fy;
  final String? parentId;
  final String level;
  final String code;
  final String name;
  final String? accountId;
  final String? accountName;
  final bool isLeaf;
  final bool isActive;
  final double estimate;
  final double? revised;
  final double reappIn;
  final double reappOut;
  final double budget;
  final double actual;
  final double committed;
  final double available;
  final double percentUsed;
  final double percentCommitted;
  final String? updatedAt;

  int get depth => switch (level) {
    'major' => 0,
    'minor' => 1,
    _ => 2,
  };
  String get label => '$code  $name';
}

class HeadsData {
  const HeadsData(this.fy, this.years, this.data, this.totals);

  factory HeadsData.fromJson(Json j) => HeadsData(
    _s(j['fy']),
    asStringList(j['years']),
    asJsonList(j['data']).map(HeadRow.fromJson).toList(),
    Totals.fromJson(asJson(j['totals'])),
  );

  final String fy;
  final List<String> years;
  final List<HeadRow> data;
  final Totals totals;

  List<HeadRow> get leaves =>
      data.where((h) => h.isLeaf && h.isActive).toList();
}

class FundRow {
  const FundRow({
    required this.id,
    required this.name,
    required this.kind,
    required this.sponsor,
    required this.sanctionNo,
    required this.sanctionDate,
    required this.totalAmount,
    required this.periodFrom,
    required this.periodTo,
    required this.returnUnspent,
    required this.status,
    required this.notes,
    required this.received,
    required this.spent,
    required this.committed,
    required this.balance,
    required this.updatedAt,
  });

  factory FundRow.fromJson(Json j) => FundRow(
    id: _s(j['id']),
    name: _s(j['name']),
    kind: _s(j['kind'], 'grant'),
    sponsor: asStringOrNull(j['sponsor']),
    sanctionNo: asStringOrNull(j['sanctionNo']),
    sanctionDate: asStringOrNull(j['sanctionDate']),
    totalAmount: _d(j['totalAmount']),
    periodFrom: asStringOrNull(j['periodFrom']),
    periodTo: asStringOrNull(j['periodTo']),
    returnUnspent: asBool(j['returnUnspent']),
    status: _s(j['status'], 'active'),
    notes: asStringOrNull(j['notes']),
    received: _d(j['received']),
    spent: _d(j['spent']),
    committed: _d(j['committed']),
    balance: _d(j['balance']),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id;
  final String name;
  final String kind;
  final String? sponsor;
  final String? sanctionNo;
  final String? sanctionDate;
  final double totalAmount;
  final String? periodFrom;
  final String? periodTo;
  final bool returnUnspent;
  final String status;
  final String? notes;
  final double received;
  final double spent;
  final double committed;
  final double balance;
  final String? updatedAt;
}

const fundKinds = {
  'grant': 'Government grant',
  'csr': 'CSR grant',
  'own': 'Own funds',
  'donation': 'Donations',
  'other': 'Other',
};

class Sanction {
  const Sanction({
    required this.id,
    required this.number,
    required this.purpose,
    required this.amount,
    required this.status,
    required this.headId,
    required this.headCode,
    required this.headName,
    required this.fundId,
    required this.fundName,
    required this.adminOrderNo,
    required this.financialOrderNo,
    required this.spent,
    required this.committed,
    required this.createdBy,
    required this.createdAt,
  });

  factory Sanction.fromJson(Json j) {
    final h = asJson(j['head']);
    final f = asJson(j['fund']);
    return Sanction(
      id: _s(j['id']),
      number: _s(j['number']),
      purpose: _s(j['purpose']),
      amount: _d(j['amount']),
      status: _s(j['status']),
      headId: _s(h['id']),
      headCode: _s(h['code']),
      headName: _s(h['name']),
      fundId: _s(f['id']),
      fundName: _s(f['name']),
      adminOrderNo: asStringOrNull(j['adminOrderNo']),
      financialOrderNo: asStringOrNull(j['financialOrderNo']),
      spent: _d(j['spent']),
      committed: _d(j['committed']),
      createdBy: _s(j['createdBy']),
      createdAt: _s(j['createdAt']),
    );
  }

  final String id;
  final String number;
  final String purpose;
  final double amount;
  final String status;
  final String headId;
  final String headCode;
  final String headName;
  final String fundId;
  final String fundName;
  final String? adminOrderNo;
  final String? financialOrderNo;
  final double spent;
  final double committed;
  final String createdBy;
  final String createdAt;
}

class Reapp {
  const Reapp({
    required this.id,
    required this.amount,
    required this.orderNo,
    required this.orderDate,
    required this.reason,
    required this.status,
    required this.fromLabel,
    required this.toLabel,
    required this.createdBy,
  });

  factory Reapp.fromJson(Json j) => Reapp(
    id: _s(j['id']),
    amount: _d(j['amount']),
    orderNo: _s(j['orderNo']),
    orderDate: _s(j['orderDate']),
    reason: _s(j['reason']),
    status: _s(j['status']),
    fromLabel:
        '${asJson(j['fromHead'])['code']}  ${asJson(j['fromHead'])['name']}',
    toLabel: '${asJson(j['toHead'])['code']}  ${asJson(j['toHead'])['name']}',
    createdBy: _s(j['createdBy']),
  );

  final String id;
  final double amount;
  final String orderNo;
  final String orderDate;
  final String reason;
  final String status;
  final String fromLabel;
  final String toLabel;
  final String createdBy;
}

class Spendable {
  const Spendable({
    required this.type,
    required this.id,
    required this.number,
    required this.date,
    required this.who,
    required this.what,
    required this.total,
    required this.remaining,
  });

  factory Spendable.fromJson(Json j) => Spendable(
    type: _s(j['sourceType']),
    id: _s(j['sourceId']),
    number: _s(j['number']),
    date: _s(j['date']),
    who: _s(j['who']),
    what: _s(j['what']),
    total: _d(j['total']),
    remaining: _d(j['remaining']),
  );

  final String type;
  final String id;
  final String number;
  final String date;
  final String who;
  final String what;
  final double total;
  final double remaining;
}

class SpendLink {
  const SpendLink({
    required this.id,
    required this.type,
    required this.number,
    required this.date,
    required this.amount,
    required this.headLabel,
    required this.fundName,
  });

  factory SpendLink.fromJson(Json j) => SpendLink(
    id: _s(j['id']),
    type: _s(j['sourceType']),
    number: _s(j['number']),
    date: _s(j['date']),
    amount: _d(j['amount']),
    headLabel: '${asJson(j['head'])['code']}  ${asJson(j['head'])['name']}',
    fundName: _s(asJson(j['fund'])['name']),
  );

  final String id;
  final String type;
  final String number;
  final String date;
  final double amount;
  final String headLabel;
  final String fundName;
}

class FundsHome {
  const FundsHome({
    required this.fy,
    required this.heads,
    required this.funds,
    required this.pending,
    required this.pendingReapp,
    required this.totals,
    required this.overspendMode,
  });

  factory FundsHome.fromJson(Json j) => FundsHome(
    fy: _s(j['fy']),
    heads: asJsonList(j['heads']).map(HeadRow.fromJson).toList(),
    funds: asJsonList(j['funds']).map(FundRow.fromJson).toList(),
    pending: asJsonList(j['pendingSanctions']).map(Sanction.fromJson).toList(),
    pendingReapp: asInt(j['pendingReappropriations']),
    totals: Totals.fromJson(asJson(j['totals'])),
    overspendMode: _s(j['overspendMode'], 'warn'),
  );

  final String fy;
  final List<HeadRow> heads;
  final List<FundRow> funds;
  final List<Sanction> pending;
  final int pendingReapp;
  final Totals totals;
  final String overspendMode;
}

class FundsSettings {
  const FundsSettings({
    required this.overspendMode,
    this.reg80gNo,
    this.reg80gFrom,
    this.reg80gTo,
    this.trustPan,
    this.receiptFooter,
  });

  factory FundsSettings.fromJson(Json j) => FundsSettings(
    overspendMode: _s(j['overspendMode'], 'warn'),
    reg80gNo: asStringOrNull(j['reg80gNo']),
    reg80gFrom: asStringOrNull(j['reg80gFrom']),
    reg80gTo: asStringOrNull(j['reg80gTo']),
    trustPan: asStringOrNull(j['trustPan']),
    receiptFooter: asStringOrNull(j['receiptFooter']),
  );

  final String overspendMode;
  final String? reg80gNo;
  final String? reg80gFrom;
  final String? reg80gTo;
  final String? trustPan;
  final String? receiptFooter;
}

class FundWiseRow {
  const FundWiseRow(
    this.name,
    this.opening,
    this.received,
    this.spent,
    this.closing,
  );

  factory FundWiseRow.fromJson(Json j) => FundWiseRow(
    _s(j['name']),
    _d(j['opening']),
    _d(j['received']),
    _d(j['spent']),
    _d(j['closing']),
  );

  final String name;
  final double opening;
  final double received;
  final double spent;
  final double closing;
}

class UcLine {
  const UcLine(this.code, this.name, this.amount);

  final String code;
  final String name;
  final double amount;
}

/// Figures for the utilisation certificate of one fund and period.
class UcData {
  const UcData({
    required this.fundName,
    required this.sponsor,
    required this.sanctionNo,
    required this.sanctionDate,
    required this.sanctionedAmount,
    required this.companyName,
    required this.companyAddress,
    required this.from,
    required this.to,
    required this.opening,
    required this.received,
    required this.receipts,
    required this.spentByHead,
    required this.spent,
    required this.closing,
    required this.returnUnspent,
    required this.refundDue,
  });

  factory UcData.fromJson(Json j) {
    final f = asJson(j['fund']);
    final c = asJson(j['company']);
    return UcData(
      fundName: _s(f['name']),
      sponsor: asStringOrNull(f['sponsor']),
      sanctionNo: asStringOrNull(f['sanctionNo']),
      sanctionDate: asStringOrNull(f['sanctionDate']),
      sanctionedAmount: _d(f['totalAmount']),
      companyName: _s(c['name']),
      companyAddress: asStringOrNull(c['address']),
      from: _s(j['from']),
      to: _s(j['to']),
      opening: _d(j['opening']),
      received: _d(j['received']),
      receipts: [
        for (final r in asJsonList(j['receipts']))
          UcLine(
            _s(r['date']),
            '${_s(r['number'])}  ${_s(r['source']) == 'donation' ? 'Donation' : 'Grant'}',
            _d(r['amount']),
          ),
      ],
      spentByHead: [
        for (final r in asJsonList(j['spentByHead']))
          UcLine(_s(r['code']), _s(r['name']), _d(r['amount'])),
      ],
      spent: _d(j['spent']),
      closing: _d(j['closing']),
      returnUnspent: asBool(j['returnUnspent']),
      refundDue: _d(j['refundDue']),
    );
  }

  final String fundName;
  final String? sponsor;
  final String? sanctionNo;
  final String? sanctionDate;
  final double sanctionedAmount;
  final String companyName;
  final String? companyAddress;
  final String from;
  final String to;
  final double opening;
  final double received;
  final List<UcLine> receipts;
  final List<UcLine> spentByHead;
  final double spent;
  final double closing;
  final bool returnUnspent;
  final double refundDue;
}

// ---------------------------------------------------------------- donations

class Donor {
  const Donor({
    required this.id,
    required this.name,
    this.phone,
    this.email,
    this.pan,
    this.aadhaarMasked,
    this.address,
    this.donated = 0,
    this.donations = 0,
    this.updatedAt,
  });

  factory Donor.fromJson(Json j) => Donor(
    id: _s(j['id']),
    name: _s(j['name']),
    phone: asStringOrNull(j['phone']),
    email: asStringOrNull(j['email']),
    pan: asStringOrNull(j['pan']),
    aadhaarMasked: asStringOrNull(j['aadhaarMasked']),
    address: asStringOrNull(j['address']),
    donated: _d(j['donated']),
    donations: asInt(j['donations']),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id;
  final String name;
  final String? phone;
  final String? email;
  final String? pan;
  final String? aadhaarMasked;
  final String? address;
  final double donated;
  final int donations;
  final String? updatedAt;

  bool get hasId => (pan ?? '').isNotEmpty || (aadhaarMasked ?? '').isNotEmpty;
  String get line => [?phone, ?pan].join('  ');
}

class Donation {
  const Donation({
    required this.id,
    required this.receiptNo,
    required this.donorId,
    required this.donorName,
    required this.date,
    required this.amount,
    required this.mode,
    required this.purpose,
    required this.fundName,
    required this.isCorpus,
    required this.tax80g,
    required this.deductionEligible,
    required this.warning,
    required this.status,
    this.warnings = const [],
  });

  factory Donation.fromJson(Json j) => Donation(
    id: _s(j['id']),
    receiptNo: _s(j['receiptNo']),
    donorId: _s(j['donorId']),
    donorName: _s(j['donorName']),
    date: _s(j['date']),
    amount: _d(j['amount']),
    mode: _s(j['mode']),
    purpose: asStringOrNull(j['purpose']),
    fundName: asStringOrNull(j['fundName']),
    isCorpus: asBool(j['isCorpus']),
    tax80g: asBool(j['tax80g']),
    deductionEligible: asBool(j['deductionEligible']),
    warning: asStringOrNull(j['warning']),
    status: _s(j['status'], 'posted'),
    warnings: asStringList(j['warnings']),
  );

  final String id;
  final String receiptNo;
  final String donorId;
  final String donorName;
  final String date;
  final double amount;
  final String mode;
  final String? purpose;
  final String? fundName;
  final bool isCorpus;
  final bool tax80g;
  final bool deductionEligible;
  final String? warning;
  final String status;
  final List<String> warnings;

  bool get cancelled => status == 'cancelled';
}

const donationModes = {
  'cash': 'Cash',
  'upi': 'UPI',
  'cheque': 'Cheque',
  'bank': 'Bank transfer',
};

class DonationHome {
  const DonationHome({
    required this.today,
    required this.todayCount,
    required this.todayByMode,
    required this.fy,
    required this.yearCount,
    required this.year,
    required this.corpus,
    required this.eligible80g,
    required this.recent,
    required this.reg80gSet,
  });

  factory DonationHome.fromJson(Json j) {
    final t = asJson(j['today']);
    final y = asJson(j['year']);
    return DonationHome(
      today: _d(t['total']),
      todayCount: asInt(t['count']),
      todayByMode: {
        for (final e in asJson(t['byMode']).entries) e.key: _d(e.value),
      },
      fy: _s(y['fy']),
      yearCount: asInt(y['count']),
      year: _d(y['total']),
      corpus: _d(y['corpus']),
      eligible80g: _d(y['eligible80g']),
      recent: asJsonList(j['recent']).map(Donation.fromJson).toList(),
      reg80gSet: asBool(asJson(j['reg80g'])['set']),
    );
  }

  final double today;
  final int todayCount;
  final Map<String, double> todayByMode;
  final String fy;
  final int yearCount;
  final double year;
  final double corpus;
  final double eligible80g;
  final List<Donation> recent;
  final bool reg80gSet;
}

/// Everything the receipt PDF prints.
class ReceiptData {
  const ReceiptData({
    required this.donation,
    required this.donorName,
    required this.donorPan,
    required this.donorAadhaar,
    required this.donorAddress,
    required this.trustName,
    required this.trustAddress,
    required this.trustPhone,
    required this.trustPan,
    required this.reg80gNo,
    required this.reg80gFrom,
    required this.reg80gTo,
    required this.footer,
    required this.reference,
  });

  factory ReceiptData.fromJson(Json j) {
    final d = asJson(j['donor']);
    final t = asJson(j['trust']);
    final r = asJson(j['reg80g']);
    return ReceiptData(
      donation: Donation.fromJson(j),
      donorName: _s(d['name']),
      donorPan: asStringOrNull(d['pan']),
      donorAadhaar: asStringOrNull(d['aadhaarMasked']),
      donorAddress: asStringOrNull(d['address']),
      trustName: _s(t['name']),
      trustAddress: asStringOrNull(t['address']),
      trustPhone: asStringOrNull(t['phone']),
      trustPan: asStringOrNull(t['pan']),
      reg80gNo: asStringOrNull(r['no']),
      reg80gFrom: asStringOrNull(r['from']),
      reg80gTo: asStringOrNull(r['to']),
      footer: asStringOrNull(j['footer']),
      reference: asStringOrNull(j['reference']),
    );
  }

  final Donation donation;
  final String donorName;
  final String? donorPan;
  final String? donorAadhaar;
  final String? donorAddress;
  final String trustName;
  final String? trustAddress;
  final String? trustPhone;
  final String? trustPan;
  final String? reg80gNo;
  final String? reg80gFrom;
  final String? reg80gTo;
  final String? footer;
  final String? reference;
}

class Form10bd {
  const Form10bd(
    this.fy,
    this.note,
    this.header,
    this.rows,
    this.skipped,
    this.total,
  );

  factory Form10bd.fromJson(Json j) => Form10bd(
    _s(j['fy']),
    _s(j['note']),
    asStringList(j['header']),
    [
      for (final r in (j['rows'] as List? ?? const []))
        [for (final c in (r as List)) '$c'],
    ],
    [
      for (final s in asJsonList(j['skipped']))
        '${_s(s['receiptNo'])}  ${_s(s['donorName'])}',
    ],
    _d(j['total']),
  );

  final String fy;
  final String note;
  final List<String> header;
  final List<List<String>> rows;
  final List<String> skipped;
  final double total;
}

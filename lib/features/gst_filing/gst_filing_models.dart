import '../../core/json.dart';
import '../compliance/compliance_models.dart' show Tax;
import '../filings/filing_models.dart';

double _d(Object? v) => asDouble(v);

/// IGST, CGST, SGST and cess amounts.
class Heads {
  const Heads({this.igst = 0, this.cgst = 0, this.sgst = 0, this.cess = 0});

  factory Heads.fromJson(Object? v) {
    final j = asJsonOrNull(v);
    if (j == null) return const Heads();
    return Heads(
      igst: _d(j['igst']),
      cgst: _d(j['cgst']),
      sgst: _d(j['sgst']),
      cess: _d(j['cess']),
    );
  }

  final double igst;
  final double cgst;
  final double sgst;
  final double cess;

  double get total => igst + cgst + sgst + cess;

  double operator [](String head) => switch (head) {
    'igst' => igst,
    'cgst' => cgst,
    'sgst' => sgst,
    _ => cess,
  };
}

const gstHeads = ['igst', 'cgst', 'sgst', 'cess'];

String headLabel(String h) => h.toUpperCase();

class SetoffMove {
  const SetoffMove(this.from, this.to, this.amount);

  final String from;
  final String to;
  final double amount;
}

class Setoff {
  const Setoff({
    required this.period,
    required this.igstSplit,
    required this.liability,
    required this.rcm,
    required this.creditOpening,
    required this.creditItc,
    required this.creditTotal,
    required this.matrix,
    required this.creditUsed,
    required this.creditCarryForward,
    required this.cashTax,
    required this.cashInterest,
    required this.cashLateFee,
    required this.cashTotal,
    required this.booksCash,
    required this.portalCash,
    required this.shortfall,
    required this.shortfallInterest,
    required this.shortfallLateFee,
    required this.shortfallTotal,
    required this.pmt06,
    required this.pmt06Interest,
    required this.pmt06LateFee,
    required this.steps,
    required this.dueDate,
    required this.daysLate,
    required this.lateInterest,
    required this.lateFee,
    required this.unverified,
  });

  factory Setoff.fromJson(Json j) {
    final credit = asJsonOrNull(j['credit']) ?? const {};
    final cash = asJsonOrNull(j['cash']) ?? const {};
    final bal = asJsonOrNull(j['cashBalance']) ?? const {};
    final short = asJsonOrNull(j['shortfall']) ?? const {};
    final pmt = asJsonOrNull(j['pmt06']) ?? const {};
    final amounts = asJsonOrNull(pmt['amounts']) ?? const {};
    final late = asJsonOrNull(j['late']) ?? const {};
    return Setoff(
      period: asString(j['period']),
      igstSplit: asString(j['igstSplit'], 'cgst_first'),
      liability: Heads.fromJson(j['liability']),
      rcm: Heads.fromJson(j['rcm']),
      creditOpening: Heads.fromJson(credit['opening']),
      creditItc: Heads.fromJson(credit['itc']),
      creditTotal: Heads.fromJson(credit['total']),
      matrix: asJsonList(j['matrix'])
          .map(
            (m) => SetoffMove(
              asString(m['from']),
              asString(m['to']),
              _d(m['amount']),
            ),
          )
          .toList(),
      creditUsed: Heads.fromJson(j['creditUsed']),
      creditCarryForward: Heads.fromJson(j['creditCarryForward']),
      cashTax: Heads.fromJson(cash['tax']),
      cashInterest: _d(cash['interest']),
      cashLateFee: _d(cash['lateFee']),
      cashTotal: _d(cash['total']),
      booksCash: _d(bal['books']),
      portalCash: bal['portal'] == null ? null : Heads.fromJson(bal['portal']),
      shortfall: Heads.fromJson(short),
      shortfallInterest: _d(short['interest']),
      shortfallLateFee: _d(short['lateFee']),
      shortfallTotal: _d(short['total']),
      pmt06: Heads.fromJson(amounts),
      pmt06Interest: _d(amounts['interest']),
      pmt06LateFee: _d(amounts['lateFee']),
      steps: asStringList(pmt['steps']),
      dueDate: asString(late['dueDate']),
      daysLate: asInt(late['daysLate']),
      lateInterest: _d(late['interest']),
      lateFee: _d(late['lateFee']),
      unverified: asStringList(j['unverified']),
    );
  }

  final String period;
  final String igstSplit;
  final Heads liability;
  final Heads rcm;
  final Heads creditOpening;
  final Heads creditItc;
  final Heads creditTotal;
  final List<SetoffMove> matrix;
  final Heads creditUsed;
  final Heads creditCarryForward;
  final Heads cashTax;
  final double cashInterest;
  final double cashLateFee;
  final double cashTotal;
  final double booksCash;
  final Heads? portalCash;
  final Heads shortfall;
  final double shortfallInterest;
  final double shortfallLateFee;
  final double shortfallTotal;
  final Heads pmt06;
  final double pmt06Interest;
  final double pmt06LateFee;
  final List<String> steps;
  final String dueDate;
  final int daysLate;
  final double lateInterest;
  final double lateFee;
  final List<String> unverified;
}

class LedgerSnapshot {
  const LedgerSnapshot({
    required this.id,
    required this.ledger,
    required this.asOf,
    required this.heads,
    this.note = '',
  });

  factory LedgerSnapshot.fromJson(Json j) => LedgerSnapshot(
    id: asString(j['id']),
    ledger: asString(j['ledger']),
    asOf: asString(j['asOf']),
    heads: Heads.fromJson(j),
    note: asString(j['note']),
  );

  final String id;

  /// `credit` or `cash`.
  final String ledger;
  final String asOf;
  final Heads heads;
  final String note;
}

class GstPayment {
  const GstPayment({
    required this.id,
    required this.number,
    required this.date,
    required this.period,
    required this.cpin,
    required this.cin,
    required this.paidFromAccountName,
    required this.heads,
    required this.interest,
    required this.lateFee,
    required this.total,
    required this.status,
  });

  factory GstPayment.fromJson(Json j) => GstPayment(
    id: asString(j['id']),
    number: asString(j['number']),
    date: asString(j['date']),
    period: asStringOrNull(j['period']),
    cpin: asString(j['cpin']),
    cin: asString(j['cin']),
    paidFromAccountName: asString(j['paidFromAccountName']),
    heads: Heads.fromJson(j),
    interest: _d(j['interest']),
    lateFee: _d(j['lateFee']),
    total: _d(j['total']),
    status: asString(j['status'], 'posted'),
  );

  final String id;
  final String number;
  final String date;
  final String? period;
  final String cpin;
  final String cin;
  final String paidFromAccountName;
  final Heads heads;
  final double interest;
  final double lateFee;
  final double total;
  final String status;

  bool get cancelled => status == 'cancelled';
}

class PrefileResult {
  const PrefileResult({
    required this.period,
    required this.returnType,
    required this.checks,
    required this.canFile,
  });

  factory PrefileResult.fromJson(Json j) => PrefileResult(
    period: asString(j['period']),
    returnType: asString(j['return']),
    checks: asJsonList(j['checks']).map(PrefileCheck.fromJson).toList(),
    canFile: asBool(j['canFile'], true),
  );

  final String period;
  final String returnType;
  final List<PrefileCheck> checks;
  final bool canFile;
}

/// GSTR-3B as returned in v1.6 (portal table order).
class Gstr3bSheet {
  const Gstr3bSheet({
    required this.period,
    required this.outward,
    required this.zeroRated,
    required this.zeroNil,
    required this.inwardRcm,
    required this.nonGst,
    required this.interState,
    required this.itcRcm,
    required this.itcOthers,
    required this.rule42,
    required this.rule37,
    required this.reclaimed,
    required this.itcNet,
    required this.others2b,
    required this.inwardExemptInter,
    required this.inwardExemptIntra,
    required this.payableNoCross,
    required this.filing,
    required this.warnings,
    required this.unverified,
  });

  factory Gstr3bSheet.fromJson(Json j) {
    final itc = asJsonOrNull(j['itc']) ?? const {};
    final rev = asJsonOrNull(itc['reversed']) ?? const {};
    final exempt = asJsonOrNull(j['inwardExempt']) ?? const {};
    final f = asJsonOrNull(j['filing']);
    return Gstr3bSheet(
      period: asString(j['period']),
      outward: Tax.fromJson(j['outward']),
      zeroRated: Tax.fromJson(j['zeroRated']),
      zeroNil: _d(asJsonOrNull(j['zeroNil'])?['taxable']),
      inwardRcm: Tax.fromJson(j['inwardRcm']),
      nonGst: _d(asJsonOrNull(j['nonGst'])?['taxable']),
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
      rule42: Tax.fromJson(rev['rule42_43']),
      rule37: Tax.fromJson(rev['rule37']),
      reclaimed: Tax.fromJson(itc['reclaimed']),
      itcNet: Tax.fromJson(itc['net']),
      others2b: itc['others2b'] == null ? null : Tax.fromJson(itc['others2b']),
      inwardExemptInter: _d(exempt['inter']),
      inwardExemptIntra: _d(exempt['intra']),
      payableNoCross: Tax.fromJson(j['payableNoCross'] ?? j['payable']),
      filing: f == null ? null : Filing.fromJson(f),
      warnings: asStringList(j['warnings']),
      unverified: asStringList(j['unverified']),
    );
  }

  final String period;
  final Tax outward;
  final Tax zeroRated;
  final double zeroNil;
  final Tax inwardRcm;
  final double nonGst;
  final List<({String pos, double taxable, double igst})> interState;
  final Tax itcRcm;
  final Tax itcOthers;
  final Tax rule42;
  final Tax rule37;
  final Tax reclaimed;
  final Tax itcNet;
  final Tax? others2b;
  final double inwardExemptInter;
  final double inwardExemptIntra;
  final Tax payableNoCross;
  final Filing? filing;
  final List<String> warnings;
  final List<String> unverified;
}

class ItcReversalRow {
  const ItcReversalRow({
    required this.number,
    required this.partyName,
    required this.supplierGstin,
    required this.billDate,
    required this.day180,
    required this.kind,
    required this.base,
    required this.igst,
    required this.cgst,
    required this.sgst,
  });

  factory ItcReversalRow.fromJson(Json j) => ItcReversalRow(
    number: asString(j['number']),
    partyName: asString(j['partyName']),
    supplierGstin: asString(j['supplierGstin']),
    billDate: asString(j['billDate']),
    day180: asString(j['day180']),
    kind: asString(j['kind']),
    base: _d(j['base']),
    igst: _d(j['igst']),
    cgst: _d(j['cgst']),
    sgst: _d(j['sgst']),
  );

  final String number;
  final String partyName;
  final String supplierGstin;
  final String billDate;
  final String day180;

  /// `reversal` or `reclaim`.
  final String kind;
  final double base;
  final double igst;
  final double cgst;
  final double sgst;
}

class ItcReversals {
  const ItcReversals({
    required this.period,
    required this.rows,
    required this.reversal,
    required this.reclaim,
    required this.unverified,
  });

  factory ItcReversals.fromJson(Json j) {
    final t = asJsonOrNull(j['totals']) ?? const {};
    return ItcReversals(
      period: asString(j['period']),
      rows: asJsonList(j['rows']).map(ItcReversalRow.fromJson).toList(),
      reversal: Tax.fromJson(t['reversal']),
      reclaim: Tax.fromJson(t['reclaim']),
      unverified: asStringList(j['unverified']),
    );
  }

  final String period;
  final List<ItcReversalRow> rows;
  final Tax reversal;
  final Tax reclaim;
  final List<String> unverified;
}

class HsnRow {
  const HsnRow(this.json);

  final Json json;

  String get code => asString(json['hsnCode'] ?? json['hsn']);
  String get description => asString(json['description']);
  double get taxable => _d(json['taxable']);
  double get igst => _d(json['igst']);
  double get cgst => _d(json['cgst']);
  double get sgst => _d(json['sgst']);
}

class Gstr9Month {
  const Gstr9Month({
    required this.period,
    required this.gstr1,
    required this.gstr3b,
    required this.gstr1Filed,
    required this.gstr3bFiled,
  });

  factory Gstr9Month.fromJson(Json j) => Gstr9Month(
    period: asString(j['period']),
    gstr1: Tax.fromJson(j['gstr1']),
    gstr3b: Tax.fromJson(j['gstr3b']),
    gstr1Filed: asBool(j['gstr1Filed']),
    gstr3bFiled: asBool(j['gstr3bFiled']),
  );

  final String period;
  final Tax gstr1;
  final Tax gstr3b;
  final bool gstr1Filed;
  final bool gstr3bFiled;
}

class Gstr9Pack {
  const Gstr9Pack({
    required this.fy,
    required this.gstin,
    required this.turnover,
    required this.mandatory,
    required this.needs9c,
    required this.t4,
    required this.t5,
    required this.t6,
    required this.t7,
    required this.t8,
    required this.t9,
    required this.t10to13,
    required this.t17,
    required this.t18,
    required this.monthly,
    required this.warnings,
    required this.unverified,
  });

  factory Gstr9Pack.fromJson(Json j) {
    final t = asJsonOrNull(j['tables']) ?? const {};
    return Gstr9Pack(
      fy: asString(j['fy']),
      gstin: asString(j['gstin']),
      turnover: _d(j['turnover']),
      mandatory: asBool(j['mandatory']),
      needs9c: asBool(j['needs9c']),
      t4: asJsonOrNull(t['t4']) ?? const {},
      t5: asJsonOrNull(t['t5']) ?? const {},
      t6: asJsonOrNull(t['t6']) ?? const {},
      t7: asJsonOrNull(t['t7']) ?? const {},
      t8: asJsonOrNull(t['t8']) ?? const {},
      t9: asJsonOrNull(t['t9']) ?? const {},
      t10to13: asString(asJsonOrNull(t['t10_13'])?['note']),
      t17: asJsonList(t['t17']).map(HsnRow.new).toList(),
      t18: asJsonList(t['t18']).map(HsnRow.new).toList(),
      monthly: asJsonList(j['monthly']).map(Gstr9Month.fromJson).toList(),
      warnings: asStringList(j['warnings']),
      unverified: asStringList(j['unverified']),
    );
  }

  final String fy;
  final String gstin;
  final double turnover;
  final bool mandatory;
  final bool needs9c;
  final Json t4;
  final Json t5;
  final Json t6;
  final Json t7;
  final Json t8;
  final Json t9;
  final String t10to13;
  final List<HsnRow> t17;
  final List<HsnRow> t18;
  final List<Gstr9Month> monthly;
  final List<String> warnings;
  final List<String> unverified;
}

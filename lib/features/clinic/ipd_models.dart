import '../../core/json.dart';

/// Bed states as the API names them.
enum BedStatus {
  available('Free'),
  occupied('Occupied'),
  cleaning('Cleaning'),
  maintenance('Maintenance');

  const BedStatus(this.label);
  final String label;

  static BedStatus parse(String? s) => BedStatus.values.firstWhere(
    (e) => e.name == s,
    orElse: () => BedStatus.available,
  );
}

String wardKindLabel(String kind) => switch (kind) {
  'general' => 'General',
  'semi_private' => 'Semi-private',
  'private' => 'Private',
  'icu' => 'ICU',
  'nicu' => 'NICU',
  _ => 'Other',
};

const wardKinds = [
  'general',
  'semi_private',
  'private',
  'icu',
  'nicu',
  'other',
];

class BedStay {
  const BedStay({
    required this.admissionId,
    required this.number,
    required this.patientName,
    required this.uhid,
    required this.doctorName,
    required this.admitDate,
    required this.days,
  });

  factory BedStay.fromJson(Json j) => BedStay(
    admissionId: asString(j['id']),
    number: asString(j['number']),
    patientName: asString(j['patientName']),
    uhid: asString(j['uhid']),
    doctorName: asString(j['doctorName']),
    admitDate: asString(j['admitDate']),
    days: asInt(j['days'], 1),
  );

  final String admissionId;
  final String number;
  final String patientName;
  final String uhid;
  final String doctorName;
  final String admitDate;
  final int days;
}

class IpdBed {
  const IpdBed({
    required this.id,
    required this.bedNo,
    required this.dailyRate,
    required this.status,
    this.stay,
    this.isActive = true,
  });

  factory IpdBed.fromJson(Json j) => IpdBed(
    id: asString(j['id']),
    bedNo: asString(j['bedNo']),
    dailyRate: asDouble(j['dailyRate']),
    status: BedStatus.parse(asStringOrNull(j['status'])),
    isActive: asBool(j['isActive'], true),
    stay: j['admission'] == null
        ? null
        : BedStay.fromJson(asJson(j['admission'])),
  );

  final String id;
  final String bedNo;
  final double dailyRate;
  final BedStatus status;
  final bool isActive;
  final BedStay? stay;
}

class IpdWard {
  const IpdWard({
    required this.id,
    required this.name,
    required this.kind,
    required this.beds,
    this.isActive = true,
  });

  factory IpdWard.fromJson(Json j) => IpdWard(
    id: asString(j['id']),
    name: asString(j['name']),
    kind: asString(j['kind'], 'general'),
    isActive: asBool(j['isActive'], true),
    beds: asJsonList(j['beds']).map(IpdBed.fromJson).toList(),
  );

  final String id;
  final String name;
  final String kind;
  final bool isActive;
  final List<IpdBed> beds;
}

class BedCounts {
  const BedCounts({
    this.total = 0,
    this.available = 0,
    this.occupied = 0,
    this.cleaning = 0,
    this.maintenance = 0,
  });

  factory BedCounts.fromJson(Json j) => BedCounts(
    total: asInt(j['total']),
    available: asInt(j['available']),
    occupied: asInt(j['occupied']),
    cleaning: asInt(j['cleaning']),
    maintenance: asInt(j['maintenance']),
  );

  final int total;
  final int available;
  final int occupied;
  final int cleaning;
  final int maintenance;
}

class IpdBoard {
  const IpdBoard({required this.counts, required this.wards});

  factory IpdBoard.fromJson(Json j) => IpdBoard(
    counts: BedCounts.fromJson(asJson(j['counts'])),
    wards: asJsonList(j['wards']).map(IpdWard.fromJson).toList(),
  );

  final BedCounts counts;
  final List<IpdWard> wards;

  List<(IpdWard, IpdBed)> get freeBeds => [
    for (final w in wards)
      for (final b in w.beds)
        if (b.status == BedStatus.available) (w, b),
  ];
}

/// A row in the admissions list.
class AdmissionBrief {
  const AdmissionBrief({
    required this.id,
    required this.number,
    required this.status,
    required this.admitDate,
    required this.days,
    required this.patientName,
    required this.uhid,
    required this.doctorName,
    this.dischargeDate,
    this.bedLabel,
  });

  factory AdmissionBrief.fromJson(Json j) {
    final bed = asJsonOrNull(j['bed']);
    return AdmissionBrief(
      id: asString(j['id']),
      number: asString(j['number']),
      status: asString(j['status']),
      admitDate: asString(j['admitDate']),
      dischargeDate: asStringOrNull(j['dischargeDate']),
      days: asInt(j['days'], 1),
      patientName: asString(asJson(j['patient'])['name']),
      uhid: asString(asJson(j['patient'])['uhid']),
      doctorName: asString(asJson(j['doctor'])['name']),
      bedLabel: bed == null
          ? null
          : '${asString(bed['wardName'])}, ${asString(bed['bedNo'])}',
    );
  }

  final String id;
  final String number;
  final String status;
  final String admitDate;
  final String? dischargeDate;
  final int days;
  final String patientName;
  final String uhid;
  final String doctorName;
  final String? bedLabel;
}

class IpdCharge {
  const IpdCharge({
    required this.id,
    required this.date,
    required this.kind,
    required this.description,
    required this.qty,
    required this.rate,
    required this.amount,
    required this.isVoid,
  });

  factory IpdCharge.fromJson(Json j) => IpdCharge(
    id: asString(j['id']),
    date: asString(j['date']),
    kind: asString(j['kind']),
    description: asString(j['description']),
    qty: asDouble(j['qty'], 1),
    rate: asDouble(j['rate']),
    amount: asDouble(j['amount']),
    isVoid: asBool(j['isVoid']),
  );

  final String id;
  final String date;
  final String kind;
  final String description;
  final double qty;
  final double rate;
  final double amount;
  final bool isVoid;
}

class IpdDeposit {
  const IpdDeposit({
    required this.number,
    required this.mode,
    required this.date,
    required this.amount,
    required this.cancelled,
  });

  factory IpdDeposit.fromJson(Json j) => IpdDeposit(
    number: asString(j['number']),
    mode: asString(j['mode']),
    date: asString(j['date']),
    amount: asDouble(j['amount']),
    cancelled: asBool(j['cancelled']),
  );

  final String number;
  final String mode;
  final String date;
  final double amount;
  final bool cancelled;
}

class IpdTotals {
  const IpdTotals({
    this.bed = 0,
    this.service = 0,
    this.medicine = 0,
    this.total = 0,
    this.deposits = 0,
    this.balance = 0,
  });

  factory IpdTotals.fromJson(Json j) => IpdTotals(
    bed: asDouble(j['bed']),
    service: asDouble(j['service']),
    medicine: asDouble(j['medicine']),
    total: asDouble(j['total']),
    deposits: asDouble(j['deposits']),
    balance: asDouble(j['balance']),
  );

  final double bed;
  final double service;
  final double medicine;
  final double total;
  final double deposits;
  final double balance;
}

class DischargeNotes {
  const DischargeNotes({
    this.diagnosis,
    this.treatment,
    this.advice,
    this.condition,
    this.followupDate,
  });

  factory DischargeNotes.fromJson(Json j) => DischargeNotes(
    diagnosis: asStringOrNull(j['diagnosis']),
    treatment: asStringOrNull(j['treatment']),
    advice: asStringOrNull(j['advice']),
    condition: asStringOrNull(j['condition']),
    followupDate: asStringOrNull(j['followupDate']),
  );

  final String? diagnosis;
  final String? treatment;
  final String? advice;
  final String? condition;
  final String? followupDate;
}

class InvoiceRef {
  const InvoiceRef({
    required this.id,
    required this.number,
    required this.total,
    this.amountPaid = 0,
  });

  factory InvoiceRef.fromJson(Json j) => InvoiceRef(
    id: asString(j['id']),
    number: asString(j['number']),
    total: asDouble(j['total']),
    amountPaid: asDouble(j['amountPaid']),
  );

  final String id;
  final String number;
  final double total;
  final double amountPaid;
}

class Admission {
  const Admission({
    required this.brief,
    required this.patientId,
    required this.doctorId,
    required this.charges,
    required this.deposits,
    required this.totals,
    required this.clinical,
    this.bedId,
    this.updatedAt,
    this.provisionalDiagnosis,
    this.notes = const DischargeNotes(),
    this.invoice,
    this.refundDue = 0,
  });

  factory Admission.fromJson(Json j) {
    final bed = asJsonOrNull(j['bed']);
    return Admission(
      brief: AdmissionBrief.fromJson(j),
      patientId: asString(asJson(j['patient'])['id']),
      doctorId: asString(asJson(j['doctor'])['id']),
      bedId: bed == null ? null : asString(bed['id']),
      updatedAt: asStringOrNull(j['updatedAt']),
      clinical: asBool(j['clinical']),
      provisionalDiagnosis: asStringOrNull(j['provisionalDiagnosis']),
      notes: j['summary'] == null
          ? const DischargeNotes()
          : DischargeNotes.fromJson(asJson(j['summary'])),
      charges: asJsonList(j['charges']).map(IpdCharge.fromJson).toList(),
      deposits: asJsonList(j['deposits']).map(IpdDeposit.fromJson).toList(),
      totals: IpdTotals.fromJson(asJson(j['totals'])),
      refundDue: asDouble(j['refundDue']),
      invoice: j['invoice'] == null
          ? null
          : InvoiceRef.fromJson(asJson(j['invoice'])),
    );
  }

  final AdmissionBrief brief;
  final String patientId;
  final String doctorId;
  final String? bedId;
  final String? updatedAt;
  final bool clinical;
  final String? provisionalDiagnosis;
  final DischargeNotes notes;
  final List<IpdCharge> charges;
  final List<IpdDeposit> deposits;
  final IpdTotals totals;
  final InvoiceRef? invoice;
  final double refundDue;

  bool get admitted => brief.status == 'admitted';
}

class DischargeResult {
  const DischargeResult({
    required this.admission,
    required this.invoice,
    required this.depositsApplied,
    required this.balanceDue,
    required this.refundDue,
  });

  factory DischargeResult.fromJson(Json j) => DischargeResult(
    admission: Admission.fromJson(asJson(j['admission'])),
    invoice: InvoiceRef.fromJson(asJson(j['invoice'])),
    depositsApplied: asDouble(j['depositsApplied']),
    balanceDue: asDouble(j['balanceDue']),
    refundDue: asDouble(j['refundDue']),
  );

  final Admission admission;
  final InvoiceRef invoice;
  final double depositsApplied;
  final double balanceDue;
  final double refundDue;
}

/// Everything the discharge summary PDF prints.
class DischargeSummaryData {
  const DischargeSummaryData({
    required this.hospitalName,
    required this.doctorName,
    required this.patientName,
    required this.uhid,
    required this.admissionNo,
    required this.admitDate,
    required this.days,
    this.hospitalAddress,
    this.hospitalPhone,
    this.speciality,
    this.registrationNo,
    this.patientLine,
    this.allergies,
    this.dischargeDate,
    this.ward,
    this.bed,
    this.provisionalDiagnosis,
    this.notes = const DischargeNotes(),
    this.medicines = const [],
  });

  factory DischargeSummaryData.fromJson(Json j) {
    final h = asJson(j['hospital']);
    final d = asJson(j['doctor']);
    final p = asJson(j['patient']);
    final a = asJson(j['admission']);
    final age = p['ageYears'];
    return DischargeSummaryData(
      hospitalName: asString(h['name']),
      hospitalAddress: asStringOrNull(h['address']),
      hospitalPhone: asStringOrNull(h['phone']),
      doctorName: asString(d['name']),
      speciality: asStringOrNull(d['speciality']),
      registrationNo: asStringOrNull(d['registrationNo']),
      patientName: asString(p['name']),
      uhid: asString(p['uhid']),
      patientLine: [
        if (age != null) '$age y',
        asString(p['sex']),
        if (p['bloodGroup'] != null) asString(p['bloodGroup']),
      ].where((e) => e.isNotEmpty).join(', '),
      allergies: asStringOrNull(p['allergies']),
      admissionNo: asString(a['number']),
      admitDate: asString(a['admitDate']),
      dischargeDate: asStringOrNull(a['dischargeDate']),
      days: asInt(a['days'], 1),
      ward: asStringOrNull(a['ward']),
      bed: asStringOrNull(a['bed']),
      provisionalDiagnosis: asStringOrNull(j['provisionalDiagnosis']),
      notes: DischargeNotes.fromJson(asJson(j['summary'])),
      medicines: [
        for (final m in asJsonList(j['medicines']))
          '${asString(m['name'])}  x ${asDouble(m['qty']).toStringAsFixed(asDouble(m['qty']) == asDouble(m['qty']).roundToDouble() ? 0 : 1)}',
      ],
    );
  }

  final String hospitalName;
  final String? hospitalAddress;
  final String? hospitalPhone;
  final String doctorName;
  final String? speciality;
  final String? registrationNo;
  final String patientName;
  final String uhid;
  final String? patientLine;
  final String? allergies;
  final String admissionNo;
  final String admitDate;
  final String? dischargeDate;
  final int days;
  final String? ward;
  final String? bed;
  final String? provisionalDiagnosis;
  final DischargeNotes notes;
  final List<String> medicines;
}

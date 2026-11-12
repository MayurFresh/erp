import '../../core/json.dart';

/// A short age such as "41 y" for lists.
String ageLabel(int? years) => years == null ? '' : '$years y';

String sexLabel(String sex) => switch (sex) {
  'male' => 'Male',
  'female' => 'Female',
  _ => 'Other',
};

/// The name, UHID, age and phone of a patient inside a list row.
class PatientBrief {
  const PatientBrief({
    required this.id,
    required this.uhid,
    required this.name,
    required this.phone,
    required this.sex,
    this.ageYears,
  });

  factory PatientBrief.fromJson(Json j) => PatientBrief(
    id: asString(j['id']),
    uhid: asString(j['uhid']),
    name: asString(j['name']),
    phone: asString(j['phone']),
    sex: asString(j['sex'], 'other'),
    ageYears: j['ageYears'] == null ? null : asInt(j['ageYears']),
  );

  final String id;
  final String uhid;
  final String name;
  final String phone;
  final String sex;
  final int? ageYears;

  String get line => [
    uhid,
    if (ageYears != null) ageLabel(ageYears),
    sexLabel(sex),
  ].join('  ');
}

class Patient {
  const Patient({
    required this.brief,
    this.partyId,
    this.dob,
    this.address,
    this.bloodGroup,
    this.allergies,
    this.emergencyName,
    this.emergencyPhone,
    this.notes,
    this.canSeeNotes = false,
    this.updatedAt,
  });

  factory Patient.fromJson(Json j) => Patient(
    brief: PatientBrief.fromJson(j),
    partyId: asStringOrNull(j['partyId']),
    dob: asStringOrNull(j['dob']),
    address: asStringOrNull(j['address']),
    bloodGroup: asStringOrNull(j['bloodGroup']),
    allergies: asStringOrNull(j['allergies']),
    emergencyName: asStringOrNull(j['emergencyName']),
    emergencyPhone: asStringOrNull(j['emergencyPhone']),
    notes: asStringOrNull(j['notes']),
    canSeeNotes: j.containsKey('notes'),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final PatientBrief brief;
  final String? partyId;
  final String? dob;
  final String? address;
  final String? bloodGroup;
  final String? allergies;
  final String? emergencyName;
  final String? emergencyPhone;

  /// Only sent to users who may read clinical notes.
  final String? notes;
  final bool canSeeNotes;
  final String? updatedAt;

  String get id => brief.id;
  String get name => brief.name;
}

class WorkingHours {
  const WorkingHours(this.day, this.from, this.to);

  factory WorkingHours.fromJson(Json j) => WorkingHours(
    asInt(j['day']),
    asString(j['from'], '09:00'),
    asString(j['to'], '13:00'),
  );

  /// 0 is Sunday.
  final int day;
  final String from;
  final String to;

  Json toJson() => {'day': day, 'from': from, 'to': to};
}

const weekdayNames = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

class Doctor {
  const Doctor({
    required this.id,
    required this.name,
    this.userId,
    this.speciality,
    this.registrationNo,
    this.consultFee = 0,
    this.followUpFee = 0,
    this.followUpDays = 7,
    this.slotMinutes = 15,
    this.workingHours = const [],
    this.isActive = true,
    this.updatedAt,
  });

  factory Doctor.fromJson(Json j) => Doctor(
    id: asString(j['id']),
    name: asString(j['name']),
    userId: asStringOrNull(j['userId']),
    speciality: asStringOrNull(j['speciality']),
    registrationNo: asStringOrNull(j['registrationNo']),
    consultFee: asDouble(j['consultFee']),
    followUpFee: asDouble(j['followUpFee']),
    followUpDays: asInt(j['followUpDays'], 7),
    slotMinutes: asInt(j['slotMinutes'], 15),
    workingHours: asJsonList(
      j['workingHours'],
    ).map(WorkingHours.fromJson).toList(),
    isActive: asBool(j['isActive'], true),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id;
  final String name;
  final String? userId;
  final String? speciality;
  final String? registrationNo;
  final double consultFee;
  final double followUpFee;
  final int followUpDays;
  final int slotMinutes;
  final List<WorkingHours> workingHours;
  final bool isActive;
  final String? updatedAt;
}

class Slot {
  const Slot(this.startTime, this.free);

  final String startTime;
  final bool free;
}

enum ApptStatus {
  booked('Booked'),
  arrived('Waiting'),
  inConsultation('With doctor'),
  done('Done'),
  cancelled('Cancelled'),
  noShow('No show');

  const ApptStatus(this.label);

  final String label;

  static ApptStatus parse(String? v) => switch (v) {
    'arrived' => arrived,
    'in_consultation' => inConsultation,
    'done' => done,
    'cancelled' => cancelled,
    'no_show' => noShow,
    _ => booked,
  };

  bool get isOpen =>
      this == booked || this == arrived || this == inConsultation;
}

class Appointment {
  const Appointment({
    required this.id,
    required this.date,
    required this.status,
    required this.patient,
    required this.doctorId,
    required this.doctorName,
    this.startTime,
    this.tokenNo,
    this.kind = 'booked',
    this.reason,
    this.visitId,
    this.billed = false,
    this.invoiceNumber,
  });

  factory Appointment.fromJson(Json j) {
    final doctor = asJson(j['doctor']);
    return Appointment(
      id: asString(j['id']),
      date: asString(j['date']),
      status: ApptStatus.parse(asStringOrNull(j['status'])),
      patient: PatientBrief.fromJson(asJson(j['patient'])),
      doctorId: asString(doctor['id']),
      doctorName: asString(doctor['name']),
      startTime: asStringOrNull(j['startTime']),
      tokenNo: j['tokenNo'] == null ? null : asInt(j['tokenNo']),
      kind: asString(j['kind'], 'booked'),
      reason: asStringOrNull(j['reason']),
      visitId: asStringOrNull(j['visitId']),
      billed: asBool(j['billed']),
      invoiceNumber: asStringOrNull(j['invoiceNumber']),
    );
  }

  final String id;
  final String date;
  final ApptStatus status;
  final PatientBrief patient;
  final String doctorId;
  final String doctorName;
  final String? startTime;
  final int? tokenNo;
  final String kind;
  final String? reason;
  final String? visitId;
  final bool billed;
  final String? invoiceNumber;

  String get when =>
      [if (tokenNo != null) 'Token $tokenNo', ?startTime].join('  ');
}

class Vitals {
  const Vitals({
    this.bpSys,
    this.bpDia,
    this.pulse,
    this.tempC,
    this.spo2,
    this.weightKg,
    this.heightCm,
  });

  factory Vitals.fromJson(Json j) => Vitals(
    bpSys: asDoubleOrNull(j['bpSys']),
    bpDia: asDoubleOrNull(j['bpDia']),
    pulse: asDoubleOrNull(j['pulse']),
    tempC: asDoubleOrNull(j['tempC']),
    spo2: asDoubleOrNull(j['spo2']),
    weightKg: asDoubleOrNull(j['weightKg']),
    heightCm: asDoubleOrNull(j['heightCm']),
  );

  final double? bpSys;
  final double? bpDia;
  final double? pulse;
  final double? tempC;
  final double? spo2;
  final double? weightKg;
  final double? heightCm;

  Json toJson() => withoutNulls({
    'bpSys': bpSys,
    'bpDia': bpDia,
    'pulse': pulse,
    'tempC': tempC,
    'spo2': spo2,
    'weightKg': weightKg,
    'heightCm': heightCm,
  });
}

class RxLine {
  const RxLine({
    required this.medicine,
    this.itemId,
    this.dose,
    this.frequency,
    this.days,
    this.instructions,
  });

  factory RxLine.fromJson(Json j) => RxLine(
    medicine: asString(j['medicine']),
    itemId: asStringOrNull(j['itemId']),
    dose: asStringOrNull(j['dose']),
    frequency: asStringOrNull(j['frequency']),
    days: j['days'] == null ? null : asInt(j['days']),
    instructions: asStringOrNull(j['instructions']),
  );

  final String medicine;
  final String? itemId;
  final String? dose;
  final String? frequency;
  final int? days;
  final String? instructions;

  Json toJson() => {
    'itemId': itemId,
    'medicine': medicine,
    'dose': dose,
    'frequency': frequency,
    'days': days,
    'instructions': instructions,
  };
}

class VisitInvoice {
  const VisitInvoice({
    required this.id,
    required this.number,
    required this.total,
    required this.amountPaid,
    required this.status,
  });

  factory VisitInvoice.fromJson(Json j) => VisitInvoice(
    id: asString(j['id']),
    number: asString(j['number']),
    total: asDouble(j['total']),
    amountPaid: asDouble(j['amountPaid']),
    status: asString(j['status']),
  );

  final String id;
  final String number;
  final double total;
  final double amountPaid;
  final String status;

  bool get cancelled => status == 'cancelled';
  double get due => total - amountPaid;
}

class Visit {
  const Visit({
    required this.id,
    required this.date,
    required this.closed,
    required this.patient,
    required this.doctorId,
    required this.doctorName,
    required this.clinical,
    this.feeKind,
    this.invoice,
    this.allergies,
    this.vitals = const Vitals(),
    this.complaints,
    this.findings,
    this.diagnosis,
    this.testsAdvised,
    this.advice,
    this.followupDate,
    this.rx = const [],
    this.updatedAt,
  });

  factory Visit.fromJson(Json j) {
    final doctor = asJson(j['doctor']);
    final inv = asJsonOrNull(j['invoice']);
    return Visit(
      id: asString(j['id']),
      date: asString(j['date']),
      closed: asString(j['status']) == 'closed',
      patient: PatientBrief.fromJson(asJson(j['patient'])),
      doctorId: asString(doctor['id']),
      doctorName: asString(doctor['name']),
      clinical: asBool(j['clinical']),
      feeKind: asStringOrNull(j['feeKind']),
      invoice: inv == null ? null : VisitInvoice.fromJson(inv),
      allergies: asStringOrNull(j['allergies']),
      vitals: Vitals.fromJson(asJson(j['vitals'] ?? const <String, Object?>{})),
      complaints: asStringOrNull(j['complaints']),
      findings: asStringOrNull(j['findings']),
      diagnosis: asStringOrNull(j['diagnosis']),
      testsAdvised: asStringOrNull(j['testsAdvised']),
      advice: asStringOrNull(j['advice']),
      followupDate: asStringOrNull(j['followupDate']),
      rx: asJsonList(j['rx']).map(RxLine.fromJson).toList(),
      updatedAt: asStringOrNull(j['updatedAt']),
    );
  }

  final String id;
  final String date;
  final bool closed;
  final PatientBrief patient;
  final String doctorId;
  final String doctorName;

  /// False for front desk: the header only, no notes.
  final bool clinical;
  final String? feeKind;
  final VisitInvoice? invoice;
  final String? allergies;
  final Vitals vitals;
  final String? complaints;
  final String? findings;
  final String? diagnosis;
  final String? testsAdvised;
  final String? advice;
  final String? followupDate;
  final List<RxLine> rx;
  final String? updatedAt;

  bool get billed => invoice != null && !invoice!.cancelled;
}

class HistoryVisit {
  const HistoryVisit({
    required this.id,
    required this.date,
    required this.doctorName,
    this.diagnosis,
    this.rxCount,
    this.feeKind,
    this.invoice,
  });

  factory HistoryVisit.fromJson(Json j) {
    final inv = asJsonOrNull(j['invoice']);
    return HistoryVisit(
      id: asString(j['id']),
      date: asString(j['date']),
      doctorName: asString(asJson(j['doctor'])['name']),
      diagnosis: asStringOrNull(j['diagnosis']),
      rxCount: j['rxCount'] == null ? null : asInt(j['rxCount']),
      feeKind: asStringOrNull(j['feeKind']),
      invoice: inv == null ? null : VisitInvoice.fromJson(inv),
    );
  }

  final String id;
  final String date;
  final String doctorName;
  final String? diagnosis;
  final int? rxCount;
  final String? feeKind;
  final VisitInvoice? invoice;
}

class PatientHistory {
  const PatientHistory(this.patient, this.visits, this.appointments);

  factory PatientHistory.fromJson(Json j) => PatientHistory(
    Patient.fromJson(asJson(j['patient'])),
    asJsonList(j['visits']).map(HistoryVisit.fromJson).toList(),
    asJsonList(j['appointments']).map(Appointment.fromJson).toList(),
  );

  final Patient patient;
  final List<HistoryVisit> visits;
  final List<Appointment> appointments;
}

/// Everything the A5 prescription needs.
class PrescriptionData {
  const PrescriptionData({
    required this.clinicName,
    required this.doctorName,
    required this.patient,
    required this.date,
    required this.rx,
    this.clinicAddress,
    this.clinicPhone,
    this.speciality,
    this.registrationNo,
    this.allergies,
    this.bloodGroup,
    this.vitals = const Vitals(),
    this.complaints,
    this.findings,
    this.diagnosis,
    this.testsAdvised,
    this.advice,
    this.followupDate,
  });

  factory PrescriptionData.fromJson(Json j) {
    final clinic = asJson(j['clinic']);
    final doctor = asJson(j['doctor']);
    final patient = asJson(j['patient']);
    final visit = asJson(j['visit']);
    return PrescriptionData(
      clinicName: asString(clinic['name']),
      clinicAddress: asStringOrNull(clinic['address']),
      clinicPhone: asStringOrNull(clinic['phone']),
      doctorName: asString(doctor['name']),
      speciality: asStringOrNull(doctor['speciality']),
      registrationNo: asStringOrNull(doctor['registrationNo']),
      patient: PatientBrief.fromJson(patient),
      allergies: asStringOrNull(patient['allergies']),
      bloodGroup: asStringOrNull(patient['bloodGroup']),
      date: asString(visit['date']),
      vitals: Vitals.fromJson(
        asJson(visit['vitals'] ?? const <String, Object?>{}),
      ),
      complaints: asStringOrNull(visit['complaints']),
      findings: asStringOrNull(visit['findings']),
      diagnosis: asStringOrNull(visit['diagnosis']),
      testsAdvised: asStringOrNull(visit['testsAdvised']),
      advice: asStringOrNull(visit['advice']),
      followupDate: asStringOrNull(visit['followupDate']),
      rx: asJsonList(j['rx']).map(RxLine.fromJson).toList(),
    );
  }

  final String clinicName;
  final String? clinicAddress;
  final String? clinicPhone;
  final String doctorName;
  final String? speciality;
  final String? registrationNo;
  final PatientBrief patient;
  final String? allergies;
  final String? bloodGroup;
  final String date;
  final Vitals vitals;
  final String? complaints;
  final String? findings;
  final String? diagnosis;
  final String? testsAdvised;
  final String? advice;
  final String? followupDate;
  final List<RxLine> rx;
}

class BillResult {
  const BillResult(this.invoice, this.feeKind);

  factory BillResult.fromJson(Json j) => BillResult(
    VisitInvoice.fromJson(asJson(j['invoice'])),
    asString(j['feeKind']),
  );

  final VisitInvoice invoice;
  final String feeKind;
}

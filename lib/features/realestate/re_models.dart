/// Models of the real-estate sales pack (API v1.3).
library;

import 'package:flutter/material.dart';

import '../../core/json.dart';

// ------------------------------------------------------------------- units

enum UnitStatus {
  available('available', 'Available'),
  hold('hold', 'On hold'),
  booked('booked', 'Booked'),
  agreement('agreement', 'Agreement'),
  possession('possession', 'Possession');

  const UnitStatus(this.api, this.label);

  final String api;
  final String label;

  static UnitStatus parse(Object? value) => UnitStatus.values.firstWhere(
    (s) => s.api == value,
    orElse: () => UnitStatus.available,
  );

  Color get color => switch (this) {
    UnitStatus.available => Colors.green.shade700,
    UnitStatus.hold => Colors.amber.shade800,
    UnitStatus.booked => Colors.blue.shade700,
    UnitStatus.agreement => Colors.deepPurple.shade600,
    UnitStatus.possession => Colors.blueGrey.shade600,
  };

  /// Only these can be booked.
  bool get bookable => this == available || this == hold;

  /// Only `available` ↔ `hold` can be changed by hand.
  bool get togglesHold => this == available || this == hold;
}

class Unit {
  const Unit({
    required this.id,
    required this.projectId,
    required this.code,
    required this.unitType,
    required this.carpetArea,
    this.projectName = '',
    this.wing,
    this.floor,
    this.balconyArea,
    this.listPrice = 0,
    this.status = UnitStatus.available,
    this.bookingId,
    this.notes,
    this.createdAt,
  });

  factory Unit.fromJson(Json json) => Unit(
    id: asString(json['id']),
    projectId: asString(json['projectId']),
    projectName: asString(json['projectName']),
    code: asString(json['code']),
    wing: asStringOrNull(json['wing']),
    floor: json['floor'] == null ? null : asInt(json['floor']),
    unitType: asString(json['unitType']),
    carpetArea: asDouble(json['carpetArea']),
    balconyArea: asDoubleOrNull(json['balconyArea']),
    listPrice: asDouble(json['listPrice']),
    status: UnitStatus.parse(json['status']),
    bookingId: asStringOrNull(json['bookingId']),
    notes: asStringOrNull(json['notes']),
    createdAt: asDateTimeOrNull(json['createdAt']),
  );

  final String id;
  final String projectId;
  final String projectName;

  /// e.g. `A-1203`.
  final String code;
  final String? wing;
  final int? floor;

  /// e.g. `2 BHK`.
  final String unitType;

  /// RERA carpet area in m².
  final double carpetArea;
  final double? balconyArea;
  final double listPrice;
  final UnitStatus status;
  final String? bookingId;
  final String? notes;
  final DateTime? createdAt;

  /// Body for create and bulk create (without `projectId`).
  Json toInputJson() => {
    'code': code,
    'wing': wing,
    'floor': floor,
    'unitType': unitType,
    'carpetArea': carpetArea,
    'balconyArea': balconyArea,
    'listPrice': listPrice,
    'notes': notes,
  };
}

/// Codes for a bulk add: wing `A`, floors 1–3 and 2 units per floor give
/// `A-101, A-102, A-201, …`; the unit number is two digits. Without a wing
/// the code is just `101`.
List<({String code, int floor})> generateUnitCodes({
  String wing = '',
  required int firstFloor,
  required int floors,
  required int unitsPerFloor,
}) {
  final prefix = wing.trim().isEmpty ? '' : '${wing.trim().toUpperCase()}-';
  return [
    for (var f = firstFloor; f < firstFloor + floors; f++)
      for (var u = 1; u <= unitsPerFloor; u++)
        (code: '$prefix$f${u.toString().padLeft(2, '0')}', floor: f),
  ];
}

/// `POST /units` bulk accepts at most this many units.
const int kMaxBulkUnits = 500;

// ----------------------------------------------------------- payment plans

class PlanStage {
  const PlanStage({
    required this.id,
    required this.name,
    required this.pct,
    this.sortOrder = 0,
  });

  factory PlanStage.fromJson(Json json) => PlanStage(
    id: asString(json['id']),
    name: asString(json['name']),
    pct: asDouble(json['pct']),
    sortOrder: asInt(json['sortOrder']),
  );

  final String id;
  final String name;
  final double pct;
  final int sortOrder;
}

class PaymentPlan {
  const PaymentPlan({
    required this.id,
    required this.projectId,
    required this.name,
    this.isActive = true,
    this.stages = const [],
    this.createdAt,
  });

  factory PaymentPlan.fromJson(Json json) => PaymentPlan(
    id: asString(json['id']),
    projectId: asString(json['projectId']),
    name: asString(json['name']),
    isActive: asBool(json['isActive'], true),
    stages: (asJsonList(json['stages']).map(PlanStage.fromJson).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder))),
    createdAt: asDateTimeOrNull(json['createdAt']),
  );

  final String id;
  final String projectId;
  final String name;
  final bool isActive;
  final List<PlanStage> stages;
  final DateTime? createdAt;

  double get pctTotal => stagePctSum(stages.map((s) => s.pct));
}

/// Σ of stage percentages, rounded to 2 decimals (so 33.33 + 33.33 + 33.34
/// is exactly 100).
double stagePctSum(Iterable<double> pcts) {
  final total = pcts.fold<double>(0, (a, b) => a + b);
  return (total * 100).round() / 100;
}

/// The plan rules: 1–30 stages, each > 0, Σ pct exactly 100.
bool stagesSumTo100(Iterable<double> pcts) =>
    (stagePctSum(pcts) - 100).abs() < 0.005;

/// A message for the first problem with a stage list, or `null` if valid.
String? stagesError(List<({String name, double? pct})> stages) {
  if (stages.isEmpty) return 'Add at least one stage';
  if (stages.length > 30) return 'At most 30 stages';
  for (final s in stages) {
    if (s.name.trim().isEmpty) return 'Every stage needs a name';
    final pct = s.pct;
    if (pct == null || pct <= 0 || pct > 100) {
      return 'Every stage needs a percentage between 0 and 100';
    }
  }
  final sum = stagePctSum(stages.map((s) => s.pct!));
  if (!stagesSumTo100(stages.map((s) => s.pct!))) {
    return 'Stages add up to $sum%, they must add up to 100%';
  }
  return null;
}

// ---------------------------------------------------------------- bookings

enum BookingStatus {
  booked('booked', 'Booked'),
  agreement('agreement', 'Agreement'),
  possession('possession', 'Possession'),
  cancelled('cancelled', 'Cancelled');

  const BookingStatus(this.api, this.label);

  final String api;
  final String label;

  static BookingStatus parse(Object? value) => BookingStatus.values.firstWhere(
    (s) => s.api == value,
    orElse: () => BookingStatus.booked,
  );

  Color get color => switch (this) {
    BookingStatus.booked => Colors.blue.shade700,
    BookingStatus.agreement => Colors.deepPurple.shade600,
    BookingStatus.possession => Colors.green.shade700,
    BookingStatus.cancelled => Colors.red.shade700,
  };
}

class BookingStage {
  const BookingStage({
    required this.id,
    required this.name,
    required this.pct,
    required this.amount,
    this.sortOrder = 0,
    this.demandId,
    this.demandNumber,
  });

  factory BookingStage.fromJson(Json json) => BookingStage(
    id: asString(json['id']),
    name: asString(json['name']),
    pct: asDouble(json['pct']),
    amount: asDouble(json['amount']),
    sortOrder: asInt(json['sortOrder']),
    demandId: asStringOrNull(json['demandId']),
    demandNumber: asStringOrNull(json['demandNumber']),
  );

  final String id;
  final String name;
  final double pct;
  final double amount;
  final int sortOrder;
  final String? demandId;
  final String? demandNumber;

  bool get isDemanded => demandId != null;
}

class BookingTotals {
  const BookingTotals({
    this.demanded = 0,
    this.gst = 0,
    this.received = 0,
    this.due = 0,
    this.undemanded = 0,
  });

  factory BookingTotals.fromJson(Json json) => BookingTotals(
    demanded: asDouble(json['demanded']),
    gst: asDouble(json['gst']),
    received: asDouble(json['received']),
    due: asDouble(json['due']),
    undemanded: asDouble(json['undemanded']),
  );

  /// Excluding GST, open demands.
  final double demanded;
  final double gst;
  final double received;
  final double due;
  final double undemanded;
}

class PersonRef {
  const PersonRef({required this.id, required this.name});

  static PersonRef? maybe(Object? value) {
    final json = asJsonOrNull(value);
    if (json == null) return null;
    return PersonRef(id: asString(json['id']), name: asString(json['name']));
  }

  final String id;
  final String name;
}

class Booking {
  const Booking({
    required this.id,
    required this.number,
    required this.projectId,
    required this.unitId,
    required this.unitCode,
    required this.customerPartyId,
    required this.customerName,
    required this.agreementValue,
    this.projectName = '',
    this.date,
    this.gstPct = 0,
    this.paymentPlanId,
    this.paymentPlanName,
    this.status = BookingStatus.booked,
    this.agreementNo,
    this.agreementDate,
    this.possessionDate,
    this.notes,
    this.stages = const [],
    this.totals = const BookingTotals(),
    this.createdAt,
    this.createdBy,
    this.cancelledAt,
    this.cancelReason,
  });

  factory Booking.fromJson(Json json) => Booking(
    id: asString(json['id']),
    number: asString(json['number']),
    projectId: asString(json['projectId']),
    projectName: asString(json['projectName']),
    unitId: asString(json['unitId']),
    unitCode: asString(json['unitCode']),
    customerPartyId: asString(json['customerPartyId']),
    customerName: asString(json['customerName']),
    date: asStringOrNull(json['date']),
    agreementValue: asDouble(json['agreementValue']),
    gstPct: asDouble(json['gstPct']),
    paymentPlanId: asStringOrNull(json['paymentPlanId']),
    paymentPlanName: asStringOrNull(json['paymentPlanName']),
    status: BookingStatus.parse(json['status']),
    agreementNo: asStringOrNull(json['agreementNo']),
    agreementDate: asStringOrNull(json['agreementDate']),
    possessionDate: asStringOrNull(json['possessionDate']),
    notes: asStringOrNull(json['notes']),
    stages: (asJsonList(json['stages']).map(BookingStage.fromJson).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder))),
    totals: BookingTotals.fromJson(asJson(json['totals'])),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: PersonRef.maybe(json['createdBy']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
  );

  final String id;
  final String number;
  final String projectId;
  final String projectName;
  final String unitId;
  final String unitCode;
  final String customerPartyId;
  final String customerName;
  final String? date;
  final double agreementValue;
  final double gstPct;
  final String? paymentPlanId;
  final String? paymentPlanName;
  final BookingStatus status;
  final String? agreementNo;
  final String? agreementDate;
  final String? possessionDate;
  final String? notes;
  final List<BookingStage> stages;
  final BookingTotals totals;
  final DateTime? createdAt;
  final PersonRef? createdBy;
  final DateTime? cancelledAt;
  final String? cancelReason;

  bool get isCancelled => status == BookingStatus.cancelled;
  List<BookingStage> get undemandedStages =>
      stages.where((s) => !s.isDemanded).toList();
  bool get allDemanded => stages.isNotEmpty && undemandedStages.isEmpty;

  /// While `booked`, demands may total at most 10% of the agreement value
  /// excluding GST (RERA s.13(1)).
  double get preAgreementCap => agreementValue * 0.10;
}

// ----------------------------------------------------------------- demands

class DemandStage {
  const DemandStage({
    required this.id,
    required this.name,
    required this.pct,
    required this.amount,
  });

  factory DemandStage.fromJson(Json json) => DemandStage(
    id: asString(json['id']),
    name: asString(json['name']),
    pct: asDouble(json['pct']),
    amount: asDouble(json['amount']),
  );

  final String id;
  final String name;
  final double pct;
  final double amount;
}

class Demand {
  const Demand({
    required this.id,
    required this.number,
    required this.bookingId,
    required this.bookingNumber,
    required this.unitCode,
    required this.partyId,
    required this.partyName,
    this.projectId = '',
    this.date,
    this.dueDate,
    this.stages = const [],
    this.amount = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.total = 0,
    this.amountPaid = 0,
    this.amountDue = 0,
    this.paymentStatus = 'unpaid',
    this.status = 'open',
    this.createdAt,
    this.createdBy,
    this.cancelledAt,
    this.cancelReason,
  });

  factory Demand.fromJson(Json json) => Demand(
    id: asString(json['id']),
    number: asString(json['number']),
    bookingId: asString(json['bookingId']),
    bookingNumber: asString(json['bookingNumber']),
    projectId: asString(json['projectId']),
    unitCode: asString(json['unitCode']),
    partyId: asString(json['partyId']),
    partyName: asString(json['partyName']),
    date: asStringOrNull(json['date']),
    dueDate: asStringOrNull(json['dueDate']),
    stages: asJsonList(json['stages']).map(DemandStage.fromJson).toList(),
    amount: asDouble(json['amount']),
    cgst: asDouble(json['cgst']),
    sgst: asDouble(json['sgst']),
    total: asDouble(json['total']),
    amountPaid: asDouble(json['amountPaid']),
    amountDue: asDouble(json['amountDue']),
    paymentStatus: asString(json['paymentStatus'], 'unpaid'),
    status: asString(json['status'], 'open'),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: PersonRef.maybe(json['createdBy']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
  );

  final String id;
  final String number;
  final String bookingId;
  final String bookingNumber;
  final String projectId;
  final String unitCode;
  final String partyId;
  final String partyName;
  final String? date;
  final String? dueDate;
  final List<DemandStage> stages;

  /// Excluding GST.
  final double amount;
  final double cgst;
  final double sgst;
  final double total;
  final double amountPaid;
  final double amountDue;

  /// `unpaid`, `partial` or `paid`.
  final String paymentStatus;

  /// `open` or `cancelled`.
  final String status;
  final DateTime? createdAt;
  final PersonRef? createdBy;
  final DateTime? cancelledAt;
  final String? cancelReason;

  bool get isCancelled => status == 'cancelled';
  double get gst => cgst + sgst;
  String get stageNames => stages.map((s) => s.name).join(', ');

  String get paymentLabel => switch (paymentStatus) {
    'paid' => 'Paid',
    'partial' => 'Part paid',
    _ => 'Unpaid',
  };

  Color paymentColor() => switch (paymentStatus) {
    'paid' => Colors.green.shade700,
    'partial' => Colors.orange.shade800,
    _ => Colors.red.shade700,
  };
}

// -------------------------------------------------------------------- RERA

class ProjectRera {
  const ProjectRera({
    required this.projectId,
    this.reraRegNo,
    this.reraAccountId,
    this.reraAccountName,
    this.to,
    this.collections = 0,
    this.required = 0,
    this.deposited = 0,
    this.withdrawn = 0,
    this.balance = 0,
    this.shortfall = 0,
  });

  factory ProjectRera.fromJson(Json json) => ProjectRera(
    projectId: asString(json['projectId']),
    reraRegNo: asStringOrNull(json['reraRegNo']),
    reraAccountId: asStringOrNull(json['reraAccountId']),
    reraAccountName: asStringOrNull(json['reraAccountName']),
    to: asStringOrNull(json['to']),
    collections: asDouble(json['collections']),
    required: asDouble(json['required']),
    deposited: asDouble(json['deposited']),
    withdrawn: asDouble(json['withdrawn']),
    balance: asDouble(json['balance']),
    shortfall: asDouble(json['shortfall']),
  );

  final String projectId;
  final String? reraRegNo;
  final String? reraAccountId;
  final String? reraAccountName;
  final String? to;

  /// Receipts allocated to the project's demands, GST excluded.
  final double collections;

  /// 70% of [collections].
  final double required;
  final double deposited;
  final double withdrawn;
  final double balance;
  final double shortfall;

  bool get hasShortfall => shortfall > 0;
}

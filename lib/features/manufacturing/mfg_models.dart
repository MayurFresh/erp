import '../../core/json.dart';

DateTime? _date(Object? v) => asDateTimeOrNull(v);

class MfgHome {
  const MfgHome({
    required this.ordersByStatus,
    required this.shortagesCount,
    required this.todayOutput,
    required this.openJobWork,
  });

  factory MfgHome.fromJson(Json j) => MfgHome(
    ordersByStatus: {
      for (final e in asJson(j['ordersByStatus']).entries)
        e.key: asInt(e.value),
    },
    shortagesCount: asInt(j['shortagesCount']),
    todayOutput: asJsonList(j['todayOutput']).map(TodayOutput.fromJson).toList(),
    openJobWork: asInt(j['openJobWork']),
  );

  final Map<String, int> ordersByStatus;
  final int shortagesCount;
  final List<TodayOutput> todayOutput;
  final int openJobWork;

  int count(String status) => ordersByStatus[status] ?? 0;
}

class TodayOutput {
  const TodayOutput(this.name, this.unit, this.goodQty, this.rejectedQty);

  factory TodayOutput.fromJson(Json j) => TodayOutput(
    asString(j['name']),
    asString(j['unit']),
    asDouble(j['goodQty']),
    asDouble(j['rejectedQty']),
  );

  final String name, unit;
  final double goodQty, rejectedQty;
}

class WorkCentre {
  const WorkCentre({
    required this.id,
    required this.name,
    required this.isActive,
    this.hourlyCost,
    this.updatedAt,
  });

  factory WorkCentre.fromJson(Json j) => WorkCentre(
    id: asString(j['id']),
    name: asString(j['name']),
    isActive: asBool(j['isActive'], true),
    hourlyCost: asDoubleOrNull(j['hourlyCost']),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id, name;
  final bool isActive;
  final double? hourlyCost;
  final String? updatedAt;
}

class BomSummary {
  const BomSummary({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.version,
    required this.status,
    required this.outputQty,
    required this.lineCount,
  });

  factory BomSummary.fromJson(Json j) => BomSummary(
    id: asString(j['id']),
    itemId: asString(j['itemId']),
    itemName: asString(j['itemName']),
    unit: asString(j['unit']),
    version: asInt(j['version'], 1),
    status: asString(j['status']),
    outputQty: asDouble(j['outputQty'], 1),
    lineCount: asInt(j['lineCount']),
  );

  final String id, itemId, itemName, unit, status;
  final int version, lineCount;
  final double outputQty;
}

class BomLine {
  const BomLine({
    required this.kind,
    required this.itemId,
    required this.name,
    required this.unit,
    required this.qty,
    this.scrapPct = 0,
    this.rate,
    this.hasBom = false,
  });

  factory BomLine.fromJson(Json j) => BomLine(
    kind: asString(j['kind'], 'component'),
    itemId: asString(j['itemId']),
    name: asString(j['name']),
    unit: asString(j['unit']),
    qty: asDouble(j['qty']),
    scrapPct: asDouble(j['scrapPct']),
    rate: asDoubleOrNull(j['rate']),
    hasBom: asBool(j['hasBom']),
  );

  final String kind, itemId, name, unit;
  final double qty, scrapPct;
  final double? rate;
  final bool hasBom;

  bool get isByProduct => kind == 'byproduct';

  Json toBody() => {
    'kind': kind,
    'itemId': itemId,
    'qty': qty,
    if (scrapPct > 0) 'scrapPct': scrapPct,
    if (isByProduct) 'rate': rate ?? 0,
  };
}

class BomStep {
  const BomStep({
    required this.operation,
    required this.workCentreId,
    required this.workCentreName,
    required this.minutesPerUnit,
    this.hourlyCost,
  });

  factory BomStep.fromJson(Json j) => BomStep(
    operation: asString(j['operation']),
    workCentreId: asString(j['workCentreId']),
    workCentreName: asString(j['workCentreName']),
    minutesPerUnit: asDouble(j['minutesPerUnit']),
    hourlyCost: asDoubleOrNull(j['hourlyCost']),
  );

  final String operation, workCentreId, workCentreName;
  final double minutesPerUnit;
  final double? hourlyCost;

  Json toBody() => {
    'operation': operation,
    'workCentreId': workCentreId,
    'minutesPerUnit': minutesPerUnit,
  };
}

class StandardCost {
  const StandardCost(this.material, this.work, this.byProducts, this.unitCost);

  factory StandardCost.fromJson(Json j) => StandardCost(
    asDouble(j['material']),
    asDouble(j['work']),
    asDouble(j['byProducts']),
    asDouble(j['unitCost']),
  );

  final double material, work, byProducts, unitCost;
}

class Bom {
  const Bom({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.version,
    required this.status,
    required this.outputQty,
    required this.lines,
    required this.steps,
    this.note,
    this.updatedAt,
    this.standardCost,
  });

  factory Bom.fromJson(Json j) => Bom(
    id: asString(j['id']),
    itemId: asString(j['itemId']),
    itemName: asString(j['itemName']),
    unit: asString(j['unit']),
    version: asInt(j['version'], 1),
    status: asString(j['status']),
    outputQty: asDouble(j['outputQty'], 1),
    note: asStringOrNull(j['note']),
    updatedAt: asStringOrNull(j['updatedAt']),
    lines: asJsonList(j['lines']).map(BomLine.fromJson).toList(),
    steps: asJsonList(j['steps']).map(BomStep.fromJson).toList(),
    standardCost: j['standardCost'] == null
        ? null
        : StandardCost.fromJson(asJson(j['standardCost'])),
  );

  final String id, itemId, itemName, unit, status;
  final int version;
  final double outputQty;
  final String? note, updatedAt;
  final List<BomLine> lines;
  final List<BomStep> steps;
  final StandardCost? standardCost;

  bool get isDraft => status == 'draft';
}

class ExplodeNode {
  const ExplodeNode(this.name, this.unit, this.qty, this.hasBom, this.children);

  factory ExplodeNode.fromJson(Json j) => ExplodeNode(
    asString(j['name']),
    asString(j['unit']),
    asDouble(j['qty']),
    j['bomId'] != null,
    asJsonList(j['children']).map(ExplodeNode.fromJson).toList(),
  );

  final String name, unit;
  final double qty;
  final bool hasBom;
  final List<ExplodeNode> children;
}

class RawNeed {
  const RawNeed(this.name, this.unit, this.qty, this.onHand);

  factory RawNeed.fromJson(Json j) => RawNeed(
    asString(j['name']),
    asString(j['unit']),
    asDouble(j['qty']),
    asDouble(j['onHand']),
  );

  final String name, unit;
  final double qty, onHand;

  double get short => qty > onHand ? qty - onHand : 0;
}

class Explosion {
  const Explosion(this.itemName, this.qty, this.tree, this.raw);

  factory Explosion.fromJson(Json j) => Explosion(
    asString(j['itemName']),
    asDouble(j['qty']),
    asJsonList(j['tree']).map(ExplodeNode.fromJson).toList(),
    asJsonList(j['raw']).map(RawNeed.fromJson).toList(),
  );

  final String itemName;
  final double qty;
  final List<ExplodeNode> tree;
  final List<RawNeed> raw;
}

class OrderSummary {
  const OrderSummary({
    required this.id,
    required this.number,
    required this.status,
    required this.itemName,
    required this.unit,
    required this.qty,
    required this.goodQty,
    required this.rejectedQty,
    this.plannedEnd,
  });

  factory OrderSummary.fromJson(Json j) => OrderSummary(
    id: asString(j['id']),
    number: asString(j['number']),
    status: asString(j['status']),
    itemName: asString(j['itemName']),
    unit: asString(j['unit']),
    qty: asDouble(j['qty']),
    goodQty: asDouble(j['goodQty']),
    rejectedQty: asDouble(j['rejectedQty']),
    plannedEnd: asStringOrNull(j['plannedEnd']),
  );

  final String id, number, status, itemName, unit;
  final double qty, goodQty, rejectedQty;
  final String? plannedEnd;
}

class OrderMaterial {
  const OrderMaterial({
    required this.itemId,
    required this.name,
    required this.unit,
    required this.plannedQty,
    required this.issuedQty,
    required this.returnedQty,
    required this.netQty,
    required this.pendingQty,
    required this.onHand,
    this.issuedValue,
  });

  factory OrderMaterial.fromJson(Json j) => OrderMaterial(
    itemId: asString(j['itemId']),
    name: asString(j['name']),
    unit: asString(j['unit']),
    plannedQty: asDouble(j['plannedQty']),
    issuedQty: asDouble(j['issuedQty']),
    returnedQty: asDouble(j['returnedQty']),
    netQty: asDouble(j['netQty']),
    pendingQty: asDouble(j['pendingQty']),
    onHand: asDouble(j['onHand']),
    issuedValue: asDoubleOrNull(j['issuedValue']),
  );

  final String itemId, name, unit;
  final double plannedQty, issuedQty, returnedQty, netQty, pendingQty, onHand;
  final double? issuedValue;
}

class OrderStep {
  const OrderStep(this.operation, this.workCentre, this.plannedMinutes);

  factory OrderStep.fromJson(Json j) => OrderStep(
    asString(j['operation']),
    asString(j['workCentreName']),
    asDouble(j['plannedMinutes']),
  );

  final String operation, workCentre;
  final double plannedMinutes;
}

class OrderOutput {
  const OrderOutput({
    required this.id,
    required this.date,
    required this.goodQty,
    required this.rejectedQty,
    required this.minutes,
    required this.byProducts,
    this.note,
    this.unitCost,
    this.value,
  });

  factory OrderOutput.fromJson(Json j) => OrderOutput(
    id: asString(j['id']),
    date: asString(j['date']),
    goodQty: asDouble(j['goodQty']),
    rejectedQty: asDouble(j['rejectedQty']),
    minutes: asDoubleOrNull(j['minutes']),
    note: asStringOrNull(j['note']),
    unitCost: asDoubleOrNull(j['unitCost']),
    value: asDoubleOrNull(j['value']),
    byProducts: asJsonList(j['byProducts'])
        .map((b) => '${asString(b['name'])} ${asDouble(b['qty'])} ${asString(b['unit'])}')
        .toList(),
  );

  final String id, date;
  final double goodQty, rejectedQty;
  final double? minutes, unitCost, value;
  final String? note;
  final List<String> byProducts;
}

class OrderMovement {
  const OrderMovement(this.kind, this.name, this.unit, this.qty, this.by, this.createdAt, this.value);

  factory OrderMovement.fromJson(Json j) => OrderMovement(
    asString(j['kind']),
    asString(j['name']),
    asString(j['unit']),
    asDouble(j['qty']),
    asString(j['by']),
    _date(j['createdAt']),
    asDoubleOrNull(j['value']),
  );

  final String kind, name, unit, by;
  final double qty;
  final DateTime? createdAt;
  final double? value;
}

class OrderInspection {
  const OrderInspection(this.passQty, this.reworkQty, this.rejectQty, this.note, this.by);

  factory OrderInspection.fromJson(Json j) => OrderInspection(
    asDouble(j['passQty']),
    asDouble(j['reworkQty']),
    asDouble(j['rejectQty']),
    asStringOrNull(j['note']),
    asString(j['by']),
  );

  final double passQty, reworkQty, rejectQty;
  final String? note;
  final String by;
}

class VarianceLine {
  const VarianceLine(this.name, this.unit, this.expectedQty, this.actualQty, this.varianceQty, this.varianceValue);

  factory VarianceLine.fromJson(Json j) => VarianceLine(
    asString(j['name']),
    asString(j['unit']),
    asDouble(j['expectedQty']),
    asDouble(j['actualQty']),
    asDouble(j['varianceQty']),
    asDoubleOrNull(j['varianceValue']),
  );

  final String name, unit;
  final double expectedQty, actualQty, varianceQty;
  final double? varianceValue;
}

class OrderCost {
  const OrderCost(this.material, this.conversion, this.total, this.unitCost, this.lossValue);

  factory OrderCost.fromJson(Json j) => OrderCost(
    asDouble(j['material']),
    asDouble(j['conversion']),
    asDouble(j['total']),
    asDouble(j['unitCost']),
    asDouble(j['lossValue']),
  );

  final double material, conversion, total, unitCost, lossValue;
}

class MfgOrder {
  const MfgOrder({
    required this.id,
    required this.number,
    required this.status,
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.bomVersion,
    required this.locationId,
    required this.locationName,
    required this.qty,
    required this.goodQty,
    required this.rejectedQty,
    required this.nextActions,
    required this.materials,
    required this.steps,
    required this.outputs,
    required this.movements,
    required this.inspections,
    required this.variance,
    this.yieldPct,
    this.completionPct = 0,
    this.plannedStart,
    this.plannedEnd,
    this.salesOrderNumber,
    this.notes,
    this.closeNote,
    this.cancelReason,
    this.updatedAt,
    this.cost,
  });

  factory MfgOrder.fromJson(Json j) {
    final v = asJson(j['variance']);
    return MfgOrder(
      id: asString(j['id']),
      number: asString(j['number']),
      status: asString(j['status']),
      itemId: asString(j['itemId']),
      itemName: asString(j['itemName']),
      unit: asString(j['unit']),
      bomVersion: asInt(j['bomVersion'], 1),
      locationId: asString(j['locationId']),
      locationName: asString(j['locationName']),
      qty: asDouble(j['qty']),
      goodQty: asDouble(j['goodQty']),
      rejectedQty: asDouble(j['rejectedQty']),
      plannedStart: asStringOrNull(j['plannedStart']),
      plannedEnd: asStringOrNull(j['plannedEnd']),
      salesOrderNumber: asStringOrNull(j['salesOrderNumber']),
      notes: asStringOrNull(j['notes']),
      closeNote: asStringOrNull(j['closeNote']),
      cancelReason: asStringOrNull(j['cancelReason']),
      updatedAt: asStringOrNull(j['updatedAt']),
      nextActions: asStringList(j['nextActions']),
      materials: asJsonList(j['materials']).map(OrderMaterial.fromJson).toList(),
      steps: asJsonList(j['steps']).map(OrderStep.fromJson).toList(),
      outputs: asJsonList(j['outputs']).map(OrderOutput.fromJson).toList(),
      movements: asJsonList(j['movements']).map(OrderMovement.fromJson).toList(),
      inspections: asJsonList(j['inspections']).map(OrderInspection.fromJson).toList(),
      variance: asJsonList(v['lines']).map(VarianceLine.fromJson).toList(),
      yieldPct: asDoubleOrNull(v['yieldPct']),
      completionPct: asDouble(v['completionPct']),
      cost: j['cost'] == null ? null : OrderCost.fromJson(asJson(j['cost'])),
    );
  }

  final String id, number, status, itemId, itemName, unit;
  final String locationId, locationName;
  final int bomVersion;
  final double qty, goodQty, rejectedQty, completionPct;
  final double? yieldPct;
  final String? plannedStart, plannedEnd, salesOrderNumber, notes, closeNote;
  final String? cancelReason, updatedAt;
  final List<String> nextActions;
  final List<OrderMaterial> materials;
  final List<OrderStep> steps;
  final List<OrderOutput> outputs;
  final List<OrderMovement> movements;
  final List<OrderInspection> inspections;
  final List<VarianceLine> variance;
  final OrderCost? cost;

  bool can(String action) => nextActions.contains(action);
  bool get isOpen => status == 'released' || status == 'in_progress';
}

class Shortage {
  const Shortage({
    required this.itemId,
    required this.name,
    required this.unit,
    required this.required,
    required this.onHand,
    required this.onOrder,
    required this.shortage,
  });

  factory Shortage.fromJson(Json j) => Shortage(
    itemId: asString(j['itemId']),
    name: asString(j['name']),
    unit: asString(j['unit']),
    required: asDouble(j['required']),
    onHand: asDouble(j['onHand']),
    onOrder: asDouble(j['onOrder']),
    shortage: asDouble(j['shortage']),
  );

  final String itemId, name, unit;
  final double required, onHand, onOrder, shortage;
}

class ChallanSummary {
  const ChallanSummary(this.id, this.number, this.status, this.partyName, this.process, this.challanDate, this.expectedReturn);

  factory ChallanSummary.fromJson(Json j) => ChallanSummary(
    asString(j['id']),
    asString(j['number']),
    asString(j['status']),
    asString(j['partyName']),
    asString(j['process']),
    asString(j['challanDate']),
    asStringOrNull(j['expectedReturn']),
  );

  final String id, number, status, partyName, process, challanDate;
  final String? expectedReturn;
}

class ChallanLine {
  const ChallanLine({
    required this.id,
    required this.name,
    required this.unit,
    required this.returnName,
    required this.qtySent,
    required this.qtyReceived,
    required this.qtyScrap,
    required this.qtyPending,
    this.hsnCode,
  });

  factory ChallanLine.fromJson(Json j) => ChallanLine(
    id: asString(j['id']),
    name: asString(j['name']),
    unit: asString(j['unit']),
    returnName: asString(j['returnName']),
    hsnCode: asStringOrNull(j['hsnCode']),
    qtySent: asDouble(j['qtySent']),
    qtyReceived: asDouble(j['qtyReceived']),
    qtyScrap: asDouble(j['qtyScrap']),
    qtyPending: asDouble(j['qtyPending']),
  );

  final String id, name, unit, returnName;
  final String? hsnCode;
  final double qtySent, qtyReceived, qtyScrap, qtyPending;
}

class Challan {
  const Challan({
    required this.id,
    required this.number,
    required this.status,
    required this.partyName,
    required this.locationName,
    required this.challanDate,
    required this.process,
    required this.ageDays,
    required this.lines,
    this.partyGstin,
    this.expectedReturn,
    this.vehicleNo,
    this.notes,
    this.cancelReason,
    this.companyName,
    this.companyGstin,
  });

  factory Challan.fromJson(Json j) => Challan(
    id: asString(j['id']),
    number: asString(j['number']),
    status: asString(j['status']),
    partyName: asString(j['partyName']),
    partyGstin: asStringOrNull(j['partyGstin']),
    locationName: asString(j['locationName']),
    challanDate: asString(j['challanDate']),
    process: asString(j['process']),
    expectedReturn: asStringOrNull(j['expectedReturn']),
    vehicleNo: asStringOrNull(j['vehicleNo']),
    notes: asStringOrNull(j['notes']),
    cancelReason: asStringOrNull(j['cancelReason']),
    companyName: asStringOrNull(j['companyName']),
    companyGstin: asStringOrNull(j['companyGstin']),
    ageDays: asInt(j['ageDays']),
    lines: asJsonList(j['lines']).map(ChallanLine.fromJson).toList(),
  );

  final String id, number, status, partyName, locationName, challanDate, process;
  final String? partyGstin, expectedReturn, vehicleNo, notes, cancelReason;
  final String? companyName, companyGstin;
  final int ageDays;
  final List<ChallanLine> lines;

  bool get canReceive => status != 'returned' && status != 'cancelled' && lines.any((l) => l.qtyPending > 0);
  bool get canCancel => lines.every((l) => l.qtyReceived == 0 && l.qtyScrap == 0) && status != 'cancelled';
}

class Itc04Row {
  const Itc04Row(this.jobWorker, this.item, this.unit, this.sent, this.received, this.scrap, this.pending, this.days, this.overdue);

  factory Itc04Row.fromJson(Json j) => Itc04Row(
    asString(j['jobWorker']),
    asString(j['item']),
    asString(j['unit']),
    asDouble(j['qtySent']),
    asDouble(j['qtyReceived']),
    asDouble(j['qtyScrap']),
    asDouble(j['qtyPending']),
    asInt(j['oldestPendingDays']),
    asBool(j['overdue']),
  );

  final String jobWorker, item, unit;
  final double sent, received, scrap, pending;
  final int days;
  final bool overdue;
}

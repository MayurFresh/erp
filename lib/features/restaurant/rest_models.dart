import 'package:flutter/material.dart';

import '../../core/app_colors.dart';
import '../../core/json.dart';

enum Diet {
  veg('veg', 'Veg'),
  nonVeg('non_veg', 'Non-veg'),
  egg('egg', 'Egg');

  const Diet(this.wire, this.label);
  final String wire;
  final String label;

  static Diet parse(Object? v) =>
      values.firstWhere((d) => d.wire == v, orElse: () => Diet.veg);
}

enum TableStatus {
  free('free', 'Free'),
  occupied('occupied', 'Occupied'),
  billPrinted('bill_printed', 'Bill printed');

  const TableStatus(this.wire, this.label);
  final String wire;
  final String label;

  static TableStatus parse(Object? v) =>
      values.firstWhere((s) => s.wire == v, orElse: () => TableStatus.free);

  Color background(AppColors c) => switch (this) {
    TableStatus.free => c.successContainer,
    TableStatus.occupied => c.warningContainer,
    TableStatus.billPrinted => c.infoContainer,
  };

  Color foreground(AppColors c) => switch (this) {
    TableStatus.free => c.onSuccessContainer,
    TableStatus.occupied => c.onWarningContainer,
    TableStatus.billPrinted => c.onInfoContainer,
  };
}

enum KitchenStatus {
  newTicket('new', 'New'),
  preparing('preparing', 'Preparing'),
  ready('ready', 'Ready'),
  served('served', 'Served');

  const KitchenStatus(this.wire, this.label);
  final String wire;
  final String label;

  static KitchenStatus parse(Object? v) => values.firstWhere(
    (s) => s.wire == v,
    orElse: () => KitchenStatus.newTicket,
  );

  KitchenStatus? get next =>
      index + 1 < values.length ? values[index + 1] : null;

  /// Action label on the kitchen card.
  String get advanceLabel => switch (this) {
    KitchenStatus.newTicket => 'Start',
    KitchenStatus.preparing => 'Ready',
    KitchenStatus.ready => 'Served',
    KitchenStatus.served => '',
  };
}

class RestSettings {
  const RestSettings({
    this.serviceChargePct = 0,
    this.serviceChargeGst = 5,
    this.stations = const ['Main'],
  });

  factory RestSettings.fromJson(Json j) => RestSettings(
    serviceChargePct: asDouble(j['serviceChargePct']),
    serviceChargeGst: asDouble(j['serviceChargeGst'], 5),
    stations: asStringList(j['stations']).isEmpty
        ? const ['Main']
        : asStringList(j['stations']),
  );

  final double serviceChargePct;
  final double serviceChargeGst;
  final List<String> stations;
}

class MenuCategory {
  const MenuCategory({
    required this.id,
    required this.name,
    this.sortOrder = 0,
    this.isActive = true,
  });

  factory MenuCategory.fromJson(Json j) => MenuCategory(
    id: asString(j['id']),
    name: asString(j['name']),
    sortOrder: asInt(j['sortOrder']),
    isActive: asBool(j['isActive'], true),
  );

  final String id;
  final String name;
  final int sortOrder;
  final bool isActive;
}

class MenuEntry {
  const MenuEntry({
    required this.itemId,
    required this.name,
    required this.price,
    this.shortName,
    this.gstRate = 5,
    this.categoryId,
    this.categoryName,
    this.diet = Diet.veg,
    this.available = true,
    this.availableToday = true,
    this.station = 'Main',
    this.updatedAt,
  });

  factory MenuEntry.fromJson(Json j) => MenuEntry(
    itemId: asString(j['itemId']),
    name: asString(j['name']),
    shortName: asStringOrNull(j['shortName']),
    price: asDouble(j['price']),
    gstRate: asDouble(j['gstRate'], 5),
    categoryId: asStringOrNull(j['categoryId']),
    categoryName: asStringOrNull(j['categoryName']),
    diet: Diet.parse(j['diet']),
    available: asBool(j['available'], true),
    availableToday: asBool(j['availableToday'], true),
    station: asString(j['station'], 'Main'),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String itemId;
  final String name;
  final String? shortName;
  final double price;
  final double gstRate;
  final String? categoryId;
  final String? categoryName;
  final Diet diet;
  final bool available;
  final bool availableToday;
  final String station;
  final String? updatedAt;
}

class TableOrderSummary {
  const TableOrderSummary({
    required this.id,
    required this.number,
    this.covers,
    this.captainName,
    this.openedAt,
    this.amount = 0,
    this.unsentLines = 0,
    this.readyLines = 0,
  });

  factory TableOrderSummary.fromJson(Json j) => TableOrderSummary(
    id: asString(j['id']),
    number: asString(j['number']),
    covers: j['covers'] == null ? null : asInt(j['covers']),
    captainName: asStringOrNull(j['captainName']),
    openedAt: asDateTimeOrNull(j['openedAt']),
    amount: asDouble(j['amount']),
    unsentLines: asInt(j['unsentLines']),
    readyLines: asInt(j['readyLines']),
  );

  final String id;
  final String number;
  final int? covers;
  final String? captainName;
  final DateTime? openedAt;
  final double amount;
  final int unsentLines;
  final int readyLines;
}

class FloorTable {
  const FloorTable({
    required this.id,
    required this.areaId,
    required this.name,
    this.seats = 4,
    this.sortOrder = 0,
    this.isActive = true,
    this.status = TableStatus.free,
    this.order,
  });

  factory FloorTable.fromJson(Json j) => FloorTable(
    id: asString(j['id']),
    areaId: asString(j['areaId']),
    name: asString(j['name']),
    seats: asInt(j['seats'], 4),
    sortOrder: asInt(j['sortOrder']),
    isActive: asBool(j['isActive'], true),
    status: TableStatus.parse(j['status']),
    order: asJsonOrNull(j['order']) == null
        ? null
        : TableOrderSummary.fromJson(asJson(j['order'])),
  );

  final String id;
  final String areaId;
  final String name;
  final int seats;
  final int sortOrder;
  final bool isActive;
  final TableStatus status;
  final TableOrderSummary? order;
}

class FloorArea {
  const FloorArea({
    required this.id,
    required this.name,
    this.sortOrder = 0,
    this.isActive = true,
    this.tables = const [],
  });

  factory FloorArea.fromJson(Json j) => FloorArea(
    id: asString(j['id']),
    name: asString(j['name']),
    sortOrder: asInt(j['sortOrder']),
    isActive: asBool(j['isActive'], true),
    tables: asJsonList(j['tables']).map(FloorTable.fromJson).toList(),
  );

  final String id;
  final String name;
  final int sortOrder;
  final bool isActive;
  final List<FloorTable> tables;
}

class OrderLine {
  const OrderLine({
    required this.id,
    required this.itemId,
    required this.name,
    required this.qty,
    required this.rate,
    this.shortName,
    this.station = 'Main',
    this.amount = 0,
    this.note,
    this.state = 'draft',
    this.kitchenStatus = KitchenStatus.newTicket,
    this.kotNo,
    this.cancelReason,
  });

  factory OrderLine.fromJson(Json j) => OrderLine(
    id: asString(j['id']),
    itemId: asString(j['itemId']),
    name: asString(j['name']),
    shortName: asStringOrNull(j['shortName']),
    station: asString(j['station'], 'Main'),
    qty: asDouble(j['qty']),
    rate: asDouble(j['rate']),
    amount: asDouble(j['amount']),
    note: asStringOrNull(j['note']),
    state: asString(j['state'], 'draft'),
    kitchenStatus: KitchenStatus.parse(j['kitchenStatus']),
    kotNo: j['kotNo'] == null ? null : asInt(j['kotNo']),
    cancelReason: asStringOrNull(j['cancelReason']),
  );

  final String id;
  final String itemId;
  final String name;
  final String? shortName;
  final String station;
  final double qty;
  final double rate;
  final double amount;
  final String? note;
  final String state;
  final KitchenStatus kitchenStatus;
  final int? kotNo;
  final String? cancelReason;

  bool get isDraft => state == 'draft';
  bool get isSent => state == 'sent';
  bool get isCancelled => state == 'cancelled';
}

class GstSummaryRow {
  const GstSummaryRow({
    required this.rate,
    required this.taxable,
    required this.cgst,
    required this.sgst,
    required this.igst,
  });

  factory GstSummaryRow.fromJson(Json j) => GstSummaryRow(
    rate: asDouble(j['rate']),
    taxable: asDouble(j['taxable']),
    cgst: asDouble(j['cgst']),
    sgst: asDouble(j['sgst']),
    igst: asDouble(j['igst']),
  );

  final double rate, taxable, cgst, sgst, igst;
}

class BillLine {
  const BillLine({
    required this.name,
    required this.qty,
    required this.rate,
    required this.amount,
    this.gstRate = 0,
  });

  factory BillLine.fromJson(Json j) => BillLine(
    name: asString(j['name']),
    qty: asDouble(j['qty']),
    rate: asDouble(j['rate']),
    amount: asDouble(j['amount']),
    gstRate: asDouble(j['gstRate']),
  );

  final String name;
  final double qty, rate, amount, gstRate;
}

class Bill {
  const Bill({
    this.lines = const [],
    this.gross = 0,
    this.discountPct = 0,
    this.discount = 0,
    this.serviceChargePct = 0,
    this.serviceCharge = 0,
    this.taxable = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.taxTotal = 0,
    this.roundOff = 0,
    this.total = 0,
    this.gstSummary = const [],
  });

  factory Bill.fromJson(Json j) => Bill(
    lines: asJsonList(j['lines']).map(BillLine.fromJson).toList(),
    gross: asDouble(j['gross']),
    discountPct: asDouble(j['discountPct']),
    discount: asDouble(j['discount']),
    serviceChargePct: asDouble(j['serviceChargePct']),
    serviceCharge: asDouble(j['serviceCharge']),
    taxable: asDouble(j['taxable']),
    cgst: asDouble(j['cgst']),
    sgst: asDouble(j['sgst']),
    igst: asDouble(j['igst']),
    taxTotal: asDouble(j['taxTotal']),
    roundOff: asDouble(j['roundOff']),
    total: asDouble(j['total']),
    gstSummary: asJsonList(
      j['gstSummary'],
    ).map(GstSummaryRow.fromJson).toList(),
  );

  final List<BillLine> lines;
  final double gross,
      discountPct,
      discount,
      serviceChargePct,
      serviceCharge,
      taxable,
      cgst,
      sgst,
      igst,
      taxTotal,
      roundOff,
      total;
  final List<GstSummaryRow> gstSummary;
}

class OrderKot {
  const OrderKot({
    required this.id,
    required this.kotNo,
    required this.station,
    required this.status,
  });

  factory OrderKot.fromJson(Json j) => OrderKot(
    id: asString(j['id']),
    kotNo: asInt(j['kotNo']),
    station: asString(j['station']),
    status: asString(j['status']),
  );

  final String id;
  final int kotNo;
  final String station;
  final String status;
}

class RestOrder {
  const RestOrder({
    required this.id,
    required this.number,
    required this.kind,
    required this.status,
    this.tableId,
    this.tableName,
    this.areaName,
    this.covers,
    this.captainName,
    this.customerName,
    this.customerPhone,
    this.deliveryAddress,
    this.notes,
    this.discountPct = 0,
    this.discountReason,
    this.invoiceId,
    this.invoiceNumber,
    this.createdAt,
    this.updatedAt,
    this.lines = const [],
    this.kots = const [],
    this.bill = const Bill(),
  });

  factory RestOrder.fromJson(Json j) => RestOrder(
    id: asString(j['id']),
    number: asString(j['number']),
    kind: asString(j['kind'], 'dine_in'),
    status: asString(j['status'], 'open'),
    tableId: asStringOrNull(j['tableId']),
    tableName: asStringOrNull(j['tableName']),
    areaName: asStringOrNull(j['areaName']),
    covers: j['covers'] == null ? null : asInt(j['covers']),
    captainName: asStringOrNull(asJson(j['captain'])['name']),
    customerName: asStringOrNull(j['customerName']),
    customerPhone: asStringOrNull(j['customerPhone']),
    deliveryAddress: asStringOrNull(j['deliveryAddress']),
    notes: asStringOrNull(j['notes']),
    discountPct: asDouble(j['discountPct']),
    discountReason: asStringOrNull(j['discountReason']),
    invoiceId: asStringOrNull(j['invoiceId']),
    invoiceNumber: asStringOrNull(j['invoiceNumber']),
    createdAt: asDateTimeOrNull(j['createdAt']),
    updatedAt: asStringOrNull(j['updatedAt']),
    lines: asJsonList(j['lines']).map(OrderLine.fromJson).toList(),
    kots: asJsonList(j['kots']).map(OrderKot.fromJson).toList(),
    bill: Bill.fromJson(asJson(j['bill'])),
  );

  final String id;
  final String number;
  final String kind;
  final String status;
  final String? tableId;
  final String? tableName;
  final String? areaName;
  final int? covers;
  final String? captainName;
  final String? customerName;
  final String? customerPhone;
  final String? deliveryAddress;
  final String? notes;
  final double discountPct;
  final String? discountReason;
  final String? invoiceId;
  final String? invoiceNumber;
  final DateTime? createdAt;
  final String? updatedAt;
  final List<OrderLine> lines;
  final List<OrderKot> kots;
  final Bill bill;

  bool get isOpen => status == 'open';
  bool get isBillPrinted => status == 'bill_printed';
  bool get isActive => isOpen || isBillPrinted;
  bool get isDineIn => kind == 'dine_in';
  List<OrderLine> get liveLines =>
      lines.where((l) => !l.isCancelled).toList(growable: false);
  int get draftCount => lines.where((l) => l.isDraft).length;

  String get kindLabel => switch (kind) {
    'takeaway' => 'Takeaway',
    'delivery' => 'Delivery',
    _ => 'Dine-in',
  };

  /// "Table T3", or the guest's name for takeaway and delivery.
  String get title => isDineIn
      ? 'Table ${tableName ?? ''}'.trim()
      : [
          kindLabel,
          if ((customerName ?? '').isNotEmpty) customerName!,
        ].join(' · ');
}

class OrderSummary {
  const OrderSummary({
    required this.id,
    required this.number,
    required this.kind,
    required this.status,
    this.tableName,
    this.customerName,
    this.customerPhone,
    this.itemCount = 0,
    this.amount = 0,
    this.readyLines = 0,
    this.unsentLines = 0,
    this.createdAt,
  });

  factory OrderSummary.fromJson(Json j) => OrderSummary(
    id: asString(j['id']),
    number: asString(j['number']),
    kind: asString(j['kind']),
    status: asString(j['status']),
    tableName: asStringOrNull(j['tableName']),
    customerName: asStringOrNull(j['customerName']),
    customerPhone: asStringOrNull(j['customerPhone']),
    itemCount: asInt(j['itemCount']),
    amount: asDouble(j['amount']),
    readyLines: asInt(j['readyLines']),
    unsentLines: asInt(j['unsentLines']),
    createdAt: asDateTimeOrNull(j['createdAt']),
  );

  final String id, number, kind, status;
  final String? tableName, customerName, customerPhone;
  final int itemCount, readyLines, unsentLines;
  final double amount;
  final DateTime? createdAt;
}

class KotLine {
  const KotLine({
    required this.id,
    required this.name,
    required this.qty,
    this.note,
    this.state = 'sent',
    this.kitchenStatus = KitchenStatus.newTicket,
  });

  factory KotLine.fromJson(Json j) => KotLine(
    id: asString(j['id']),
    name: asString(j['name']),
    qty: asDouble(j['qty']),
    note: asStringOrNull(j['note']),
    state: asString(j['state'], 'sent'),
    kitchenStatus: KitchenStatus.parse(j['kitchenStatus']),
  );

  final String id;
  final String name;
  final double qty;
  final String? note;
  final String state;
  final KitchenStatus kitchenStatus;

  bool get isCancelled => state == 'cancelled';
}

class Kot {
  const Kot({
    required this.id,
    required this.kotNo,
    required this.station,
    required this.status,
    required this.orderNumber,
    this.kind = 'dine_in',
    this.tableName,
    this.areaName,
    this.covers,
    this.captainName,
    this.customerName,
    this.createdAt,
    this.lines = const [],
  });

  factory Kot.fromJson(Json j) => Kot(
    id: asString(j['id']),
    kotNo: asInt(j['kotNo']),
    station: asString(j['station']),
    status: KitchenStatus.parse(j['status']),
    orderNumber: asString(j['orderNumber']),
    kind: asString(j['kind'], 'dine_in'),
    tableName: asStringOrNull(j['tableName']),
    areaName: asStringOrNull(j['areaName']),
    covers: j['covers'] == null ? null : asInt(j['covers']),
    captainName: asStringOrNull(j['captainName']),
    customerName: asStringOrNull(j['customerName']),
    createdAt: asDateTimeOrNull(j['createdAt']),
    lines: asJsonList(j['lines']).map(KotLine.fromJson).toList(),
  );

  final String id;
  final int kotNo;
  final String station;
  final KitchenStatus status;
  final String orderNumber;
  final String kind;
  final String? tableName, areaName, captainName, customerName;
  final int? covers;
  final DateTime? createdAt;
  final List<KotLine> lines;

  /// "T3", or "Takeaway" / "Delivery" with the guest's name.
  String get where => kind == 'dine_in'
      ? (tableName ?? '')
      : [
          kind == 'delivery' ? 'Delivery' : 'Takeaway',
          if ((customerName ?? '').isNotEmpty) customerName!,
        ].join(' · ');

  List<KotLine> get liveLines =>
      lines.where((l) => !l.isCancelled).toList(growable: false);
}

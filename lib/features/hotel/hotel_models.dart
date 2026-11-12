import '../../core/json.dart';

String roomStatusLabel(String s) => switch (s) {
  'clean' => 'Clean',
  'dirty' => 'Dirty',
  'inspected' => 'Inspected',
  'out_of_order' => 'Out of order',
  _ => s,
};

String resStatusLabel(String s) => switch (s) {
  'tentative' => 'Tentative',
  'confirmed' => 'Confirmed',
  'checked_in' => 'In house',
  'checked_out' => 'Checked out',
  'cancelled' => 'Cancelled',
  'no_show' => 'No-show',
  _ => s,
};

String sourceLabel(String s) => switch (s) {
  'walk_in' => 'Walk-in',
  'phone' => 'Phone',
  'ota' => 'Online agent',
  'agent' => 'Agent',
  _ => s,
};

class RoomType {
  const RoomType({
    required this.id,
    required this.name,
    required this.baseOccupancy,
    required this.maxOccupancy,
    required this.baseTariff,
    required this.extraPersonCharge,
    required this.isActive,
    this.roomCount = 0,
    this.updatedAt,
  });

  factory RoomType.fromJson(Json j) => RoomType(
    id: asString(j['id']),
    name: asString(j['name']),
    baseOccupancy: asInt(j['baseOccupancy'], 2),
    maxOccupancy: asInt(j['maxOccupancy'], 3),
    baseTariff: asDouble(j['baseTariff']),
    extraPersonCharge: asDouble(j['extraPersonCharge']),
    isActive: asBool(j['isActive'], true),
    roomCount: asInt(j['roomCount']),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id;
  final String name;
  final int baseOccupancy;
  final int maxOccupancy;
  final double baseTariff;
  final double extraPersonCharge;
  final bool isActive;
  final int roomCount;
  final String? updatedAt;
}

class Room {
  const Room({
    required this.id,
    required this.number,
    required this.type,
    required this.roomTypeId,
    required this.status,
    this.floor,
    this.statusReason,
    this.occupied = false,
    this.guest,
    this.isActive = true,
    this.updatedAt,
  });

  factory Room.fromJson(Json j) => Room(
    id: asString(j['id']),
    number: asString(j['number']),
    type: asString(j['type']),
    roomTypeId: asString(j['roomTypeId']),
    status: asString(j['status'], 'clean'),
    floor: asStringOrNull(j['floor']),
    statusReason: asStringOrNull(j['statusReason']),
    occupied: asBool(j['occupied']),
    guest: asStringOrNull(j['guest']),
    isActive: asBool(j['isActive'], true),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id;
  final String number;
  final String type;
  final String roomTypeId;
  final String status;
  final String? floor;
  final String? statusReason;
  final bool occupied;
  final String? guest;
  final bool isActive;
  final String? updatedAt;
}

class RatePlan {
  const RatePlan({
    required this.id,
    required this.roomTypeId,
    required this.name,
    required this.meal,
    required this.weekdayTariff,
    required this.weekendTariff,
    required this.isActive,
    this.updatedAt,
  });

  factory RatePlan.fromJson(Json j) => RatePlan(
    id: asString(j['id']),
    roomTypeId: asString(j['roomTypeId']),
    name: asString(j['name']),
    meal: asString(j['meal'], 'room_only'),
    weekdayTariff: asDouble(j['weekdayTariff']),
    weekendTariff: asDouble(j['weekendTariff']),
    isActive: asBool(j['isActive'], true),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id;
  final String roomTypeId;
  final String name;
  final String meal;
  final double weekdayTariff;
  final double weekendTariff;
  final bool isActive;
  final String? updatedAt;
}

class GuestDetails {
  const GuestDetails({
    required this.name,
    this.phone,
    this.address,
    this.idType,
    this.idNumber,
    this.nationality,
    this.passportNo,
    this.visaNo,
    this.visaType,
    this.visaExpiry,
    this.arrivedFrom,
    this.goingTo,
    this.purpose,
  });

  factory GuestDetails.fromJson(Json j) => GuestDetails(
    name: asString(j['name']),
    phone: asStringOrNull(j['phone']),
    address: asStringOrNull(j['address']),
    idType: asStringOrNull(j['idType']),
    idNumber: asStringOrNull(j['idNumber']),
    nationality: asStringOrNull(j['nationality']),
    passportNo: asStringOrNull(j['passportNo']),
    visaNo: asStringOrNull(j['visaNo']),
    visaType: asStringOrNull(j['visaType']),
    visaExpiry: asStringOrNull(j['visaExpiry']),
    arrivedFrom: asStringOrNull(j['arrivedFrom']),
    goingTo: asStringOrNull(j['goingTo']),
    purpose: asStringOrNull(j['purpose']),
  );

  final String name;
  final String? phone;
  final String? address;
  final String? idType;
  final String? idNumber;
  final String? nationality;
  final String? passportNo;
  final String? visaNo;
  final String? visaType;
  final String? visaExpiry;
  final String? arrivedFrom;
  final String? goingTo;
  final String? purpose;
}

class BookedRoom {
  const BookedRoom({
    required this.id,
    required this.roomTypeId,
    required this.typeName,
    required this.adults,
    required this.children,
    this.roomId,
    this.roomNumber,
    this.roomStatus,
    this.ratePlanName,
    this.guest,
  });

  factory BookedRoom.fromJson(Json j) => BookedRoom(
    id: asString(j['id']),
    roomTypeId: asString(j['roomTypeId']),
    typeName: asString(j['typeName']),
    adults: asInt(j['adults'], 1),
    children: asInt(j['children']),
    roomId: asStringOrNull(j['roomId']),
    roomNumber: asStringOrNull(j['roomNumber']),
    roomStatus: asStringOrNull(j['roomStatus']),
    ratePlanName: asStringOrNull(j['ratePlanName']),
    guest: asJsonOrNull(j['guest']) == null
        ? null
        : GuestDetails.fromJson(asJson(j['guest'])),
  );

  final String id;
  final String roomTypeId;
  final String typeName;
  final int adults;
  final int children;
  final String? roomId;
  final String? roomNumber;
  final String? roomStatus;
  final String? ratePlanName;
  final GuestDetails? guest;

  String get label => roomNumber == null
      ? '$typeName (not assigned)'
      : 'Room $roomNumber, $typeName';
}

class Reservation {
  const Reservation({
    required this.id,
    required this.number,
    required this.status,
    required this.arrival,
    required this.departure,
    required this.nights,
    required this.guestName,
    required this.guestPartyId,
    required this.rooms,
    required this.advance,
    required this.source,
    this.guestPhone,
    this.sourceName,
    this.notes,
    this.overrideTariff,
    this.invoiceId,
    this.updatedAt,
  });

  factory Reservation.fromJson(Json j) {
    final g = asJson(j['guest']);
    return Reservation(
      id: asString(j['id']),
      number: asString(j['number']),
      status: asString(j['status']),
      arrival: asString(j['arrival']),
      departure: asString(j['departure']),
      nights: asInt(j['nights']),
      guestName: asString(g['name']),
      guestPartyId: asString(g['partyId']),
      guestPhone: asStringOrNull(g['phone']),
      rooms: asJsonList(j['rooms']).map(BookedRoom.fromJson).toList(),
      advance: asDouble(j['advance']),
      source: asString(j['source'], 'walk_in'),
      sourceName: asStringOrNull(j['sourceName']),
      notes: asStringOrNull(j['notes']),
      overrideTariff: asDoubleOrNull(j['overrideTariff']),
      invoiceId: asStringOrNull(j['invoiceId']),
      updatedAt: asStringOrNull(j['updatedAt']),
    );
  }

  final String id;
  final String number;
  final String status;
  final String arrival;
  final String departure;
  final int nights;
  final String guestName;
  final String guestPartyId;
  final String? guestPhone;
  final List<BookedRoom> rooms;
  final double advance;
  final String source;
  final String? sourceName;
  final String? notes;
  final double? overrideTariff;
  final String? invoiceId;
  final String? updatedAt;

  bool get isOpen => const {
    'tentative',
    'confirmed',
    'checked_in',
  }.contains(status);
  bool get canCheckIn => status == 'tentative' || status == 'confirmed';
  bool get inHouse => status == 'checked_in';
  String get roomsLine => rooms.map((r) => r.roomNumber ?? r.typeName).join(', ');
}

class FolioLine {
  const FolioLine({
    required this.id,
    required this.date,
    required this.kind,
    required this.chargeType,
    required this.description,
    required this.qty,
    required this.rate,
    required this.amount,
    required this.gstRate,
    required this.voided,
  });

  factory FolioLine.fromJson(Json j) => FolioLine(
    id: asString(j['id']),
    date: asString(j['date']),
    kind: asString(j['kind']),
    chargeType: asString(j['chargeType']),
    description: asString(j['description']),
    qty: asDouble(j['qty'], 1),
    rate: asDouble(j['rate']),
    amount: asDouble(j['amount']),
    gstRate: asDouble(j['gstRate']),
    voided: asBool(j['voided']),
  );

  final String id;
  final String date;
  final String kind;
  final String chargeType;
  final String description;
  final double qty;
  final double rate;
  final double amount;
  final double gstRate;
  final bool voided;

  bool get isDiscount => kind == 'discount';
  bool get canVoid => kind != 'room' && !voided;
}

class FolioPayment {
  const FolioPayment({
    required this.number,
    required this.kind,
    required this.amount,
    required this.mode,
    required this.status,
  });

  factory FolioPayment.fromJson(Json j) => FolioPayment(
    number: asString(j['number']),
    kind: asString(j['kind']),
    amount: asDouble(j['amount']),
    mode: asString(j['mode']),
    status: asString(j['status']),
  );

  final String number;
  final String kind;
  final double amount;
  final String mode;
  final String status;
}

class FolioTotals {
  const FolioTotals({
    required this.gross,
    required this.discount,
    required this.subtotal,
    required this.tax,
    required this.total,
    required this.paid,
    required this.balance,
    required this.estimate,
  });

  factory FolioTotals.fromJson(Json j) => FolioTotals(
    gross: asDouble(j['gross']),
    discount: asDouble(j['discount']),
    subtotal: asDouble(j['subtotal']),
    tax: asDouble(j['tax']),
    total: asDouble(j['total']),
    paid: asDouble(j['paid']),
    balance: asDouble(j['balance']),
    estimate: asBool(j['estimate'], true),
  );

  final double gross;
  final double discount;
  final double subtotal;
  final double tax;
  final double total;
  final double paid;
  final double balance;
  final bool estimate;
}

class FolioInvoice {
  const FolioInvoice({
    required this.id,
    required this.number,
    required this.total,
    required this.date,
  });

  factory FolioInvoice.fromJson(Json j) => FolioInvoice(
    id: asString(j['id']),
    number: asString(j['number']),
    total: asDouble(j['total']),
    date: asString(j['date']),
  );

  final String id;
  final String number;
  final double total;
  final String date;
}

class Folio {
  const Folio({
    required this.reservation,
    required this.lines,
    required this.payments,
    required this.totals,
    required this.pricesIncludeTax,
    this.invoice,
  });

  factory Folio.fromJson(Json j) => Folio(
    reservation: Reservation.fromJson(asJson(j['reservation'])),
    lines: asJsonList(j['lines']).map(FolioLine.fromJson).toList(),
    payments: asJsonList(j['payments']).map(FolioPayment.fromJson).toList(),
    totals: FolioTotals.fromJson(asJson(j['totals'])),
    pricesIncludeTax: asBool(j['pricesIncludeTax']),
    invoice: asJsonOrNull(j['invoice']) == null
        ? null
        : FolioInvoice.fromJson(asJson(j['invoice'])),
  );

  final Reservation reservation;
  final List<FolioLine> lines;
  final List<FolioPayment> payments;
  final FolioTotals totals;
  final bool pricesIncludeTax;
  final FolioInvoice? invoice;
}

class DeskItem {
  const DeskItem({
    required this.id,
    required this.number,
    required this.status,
    required this.guest,
    required this.arrival,
    required this.departure,
    required this.rooms,
    required this.advance,
    this.phone,
    this.balance,
  });

  factory DeskItem.fromJson(Json j) => DeskItem(
    id: asString(j['id']),
    number: asString(j['number']),
    status: asString(j['status']),
    guest: asString(j['guest']),
    phone: asStringOrNull(j['phone']),
    arrival: asString(j['arrival']),
    departure: asString(j['departure']),
    rooms: asJsonList(j['rooms'])
        .map((r) => asString(r['number'], asString(r['type'])))
        .join(', '),
    advance: asDouble(j['advance']),
    balance: asDoubleOrNull(j['balance']),
  );

  final String id;
  final String number;
  final String status;
  final String guest;
  final String? phone;
  final String arrival;
  final String departure;
  final String rooms;
  final double advance;
  final double? balance;
}

class TodayData {
  const TodayData({
    required this.date,
    required this.arrivals,
    required this.departures,
    required this.inHouse,
    required this.roomCounts,
    required this.occupied,
    required this.totalRooms,
  });

  factory TodayData.fromJson(Json j) {
    final c = asJson(j['roomCounts']);
    return TodayData(
      date: asString(j['date']),
      arrivals: asJsonList(j['arrivals']).map(DeskItem.fromJson).toList(),
      departures: asJsonList(j['departures']).map(DeskItem.fromJson).toList(),
      inHouse: asJsonList(j['inHouse']).map(DeskItem.fromJson).toList(),
      roomCounts: {
        for (final k in const ['clean', 'dirty', 'inspected', 'out_of_order'])
          k: asInt(c[k]),
      },
      occupied: asInt(j['occupied']),
      totalRooms: asInt(j['totalRooms']),
    );
  }

  final String date;
  final List<DeskItem> arrivals;
  final List<DeskItem> departures;
  final List<DeskItem> inHouse;
  final Map<String, int> roomCounts;
  final int occupied;
  final int totalRooms;
}

class Stay {
  const Stay({
    required this.id,
    required this.reservationId,
    required this.number,
    required this.guest,
    required this.arrival,
    required this.departure,
    required this.status,
    required this.typeName,
  });

  factory Stay.fromJson(Json j) => Stay(
    id: asString(j['id']),
    reservationId: asString(j['reservationId']),
    number: asString(j['number']),
    guest: asString(j['guest']),
    arrival: asString(j['arrival']),
    departure: asString(j['departure']),
    status: asString(j['status']),
    typeName: asString(j['typeName']),
  );

  final String id;
  final String reservationId;
  final String number;
  final String guest;
  final String arrival;
  final String departure;
  final String status;
  final String typeName;
}

class BoardRoom {
  const BoardRoom({
    required this.id,
    required this.number,
    required this.type,
    required this.status,
    required this.stays,
  });

  factory BoardRoom.fromJson(Json j) => BoardRoom(
    id: asString(j['id']),
    number: asString(j['number']),
    type: asString(j['type']),
    status: asString(j['status']),
    stays: asJsonList(j['stays']).map(Stay.fromJson).toList(),
  );

  final String id;
  final String number;
  final String type;
  final String status;
  final List<Stay> stays;
}

class Board {
  const Board({
    required this.from,
    required this.dates,
    required this.rooms,
    required this.unassigned,
  });

  factory Board.fromJson(Json j) => Board(
    from: asString(j['from']),
    dates: asStringList(j['dates']),
    rooms: asJsonList(j['rooms']).map(BoardRoom.fromJson).toList(),
    unassigned: asJsonList(j['unassigned']).map(Stay.fromJson).toList(),
  );

  final String from;
  final List<String> dates;
  final List<BoardRoom> rooms;
  final List<Stay> unassigned;
}

class TypeAvailability {
  const TypeAvailability({
    required this.roomTypeId,
    required this.name,
    required this.total,
    required this.minAvailable,
  });

  factory TypeAvailability.fromJson(Json j) {
    final days = asJsonList(j['byDate']).map((d) => asInt(d['available']));
    return TypeAvailability(
      roomTypeId: asString(j['roomTypeId']),
      name: asString(j['name']),
      total: asInt(j['total']),
      minAvailable: days.isEmpty ? asInt(j['total']) : days.reduce((a, b) => a < b ? a : b),
    );
  }

  final String roomTypeId;
  final String name;
  final int total;

  /// Fewest rooms free on any night of the asked range.
  final int minAvailable;
}

class OccupancyRow {
  const OccupancyRow({
    required this.date,
    required this.available,
    required this.sold,
    required this.revenue,
    required this.occupancyPct,
    required this.adr,
    required this.revpar,
  });

  factory OccupancyRow.fromJson(Json j) => OccupancyRow(
    date: asString(j['date']),
    available: asInt(j['available']),
    sold: asInt(j['sold']),
    revenue: asDouble(j['revenue']),
    occupancyPct: asDouble(j['occupancyPct']),
    adr: asDouble(j['adr']),
    revpar: asDouble(j['revpar']),
  );

  final String date;
  final int available;
  final int sold;
  final double revenue;
  final double occupancyPct;
  final double adr;
  final double revpar;
}

class RegisterRow {
  const RegisterRow({
    required this.serial,
    required this.room,
    required this.name,
    required this.address,
    required this.nationality,
    required this.idType,
    required this.idNumber,
    required this.phone,
    required this.checkedInAt,
    required this.checkedOutAt,
    required this.passportNo,
    required this.visaNo,
  });

  factory RegisterRow.fromJson(Json j) => RegisterRow(
    serial: asInt(j['serial']),
    room: asString(j['room']),
    name: asString(j['name']),
    address: asString(j['address']),
    nationality: asString(j['nationality']),
    idType: asString(j['idType']),
    idNumber: asString(j['idNumber']),
    phone: asString(j['phone']),
    checkedInAt: asString(j['checkedInAt']),
    checkedOutAt: asString(j['checkedOutAt']),
    passportNo: asString(j['passportNo']),
    visaNo: asString(j['visaNo']),
  );

  final int serial;
  final String room;
  final String name;
  final String address;
  final String nationality;
  final String idType;
  final String idNumber;
  final String phone;
  final String checkedInAt;
  final String checkedOutAt;
  final String passportNo;
  final String visaNo;
}

class CheckOutResult {
  const CheckOutResult({
    required this.invoiceId,
    required this.invoiceNumber,
    required this.total,
    required this.refundDue,
  });

  factory CheckOutResult.fromJson(Json j) {
    final i = asJson(j['invoice']);
    return CheckOutResult(
      invoiceId: asString(i['id']),
      invoiceNumber: asString(i['number']),
      total: asDouble(i['total']),
      refundDue: asDouble(j['refundDue']),
    );
  }

  final String invoiceId;
  final String invoiceNumber;
  final double total;
  final double refundDue;
}

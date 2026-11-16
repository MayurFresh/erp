import '../../core/json.dart';

/// Models for delivery challans, currencies, export settings and TCS
/// (docs/API.md v1.20).

const challanReasons = <String, String>{
  'job_work': 'Job work',
  'supply_on_approval': 'Supply on approval',
  'exhibition': 'Exhibition or display',
  'branch_transfer': 'Branch transfer',
  'liquid_gas': 'Liquid gas, quantity not known',
  'other': 'Other',
};

const challanStatuses = <String, String>{
  'open': 'Open',
  'partly_closed': 'Partly closed',
  'closed': 'Closed',
  'cancelled': 'Cancelled',
};

const exportCategories = <String, String>{
  'export_igst': 'Export with payment of IGST',
  'export_lut': 'Export under LUT, without tax',
  'sez_igst': 'Supply to SEZ with payment of IGST',
  'sez_lut': 'Supply to SEZ under LUT, without tax',
  'deemed': 'Deemed export',
};

class ChallanLine {
  const ChallanLine({
    required this.id,
    required this.itemId,
    required this.description,
    required this.unit,
    required this.qty,
    required this.rate,
    required this.gstRate,
    required this.taxableValue,
    required this.tax,
    required this.returnedQty,
    required this.invoicedQty,
    required this.pendingQty,
    this.hsnCode,
    this.provisional = false,
  });

  factory ChallanLine.fromJson(Json j) => ChallanLine(
    id: asString(j['id']),
    itemId: asString(j['itemId']),
    description: asString(j['description']),
    hsnCode: asStringOrNull(j['hsnCode']),
    unit: asString(j['unit']),
    qty: asDouble(j['qty']),
    provisional: asBool(j['provisional']),
    rate: asDouble(j['rate']),
    gstRate: asDouble(j['gstRate']),
    taxableValue: asDouble(j['taxableValue']),
    tax: asDouble(j['cgst']) + asDouble(j['sgst']) + asDouble(j['igst']),
    returnedQty: asDouble(j['returnedQty']),
    invoicedQty: asDouble(j['invoicedQty']),
    pendingQty: asDouble(j['pendingQty']),
  );

  final String id;
  final String itemId;
  final String description;
  final String? hsnCode;
  final String unit;
  final double qty;
  final bool provisional;
  final double rate;
  final double gstRate;
  final double taxableValue;
  final double tax;
  final double returnedQty;
  final double invoicedQty;
  final double pendingQty;
}

class ChallanSummary {
  const ChallanSummary({
    required this.id,
    required this.number,
    required this.date,
    required this.reason,
    required this.consigneeName,
    required this.status,
  });

  factory ChallanSummary.fromJson(Json j) => ChallanSummary(
    id: asString(j['id']),
    number: asString(j['number']),
    date: asString(j['date']),
    reason: asString(j['reason']),
    consigneeName: asString(j['consigneeName']),
    status: asString(j['status']),
  );

  final String id;
  final String number;
  final String date;
  final String reason;
  final String consigneeName;
  final String status;
}

class Challan {
  const Challan({
    required this.id,
    required this.number,
    required this.date,
    required this.reason,
    required this.status,
    required this.locationName,
    required this.consigneeName,
    required this.consignorName,
    required this.taxableTotal,
    required this.taxTotal,
    required this.lines,
    this.reasonNote,
    this.toLocationName,
    this.partyId,
    this.consigneeAddress,
    this.consigneeGstin,
    this.consigneeState,
    this.consignorGstin,
    this.vehicleNo,
    this.transporter,
    this.ewbNo,
    this.notes,
  });

  factory Challan.fromJson(Json j) {
    final consignee = asJson(j['consignee']);
    final consignor = asJson(j['consignor']);
    return Challan(
      id: asString(j['id']),
      number: asString(j['number']),
      date: asString(j['date']),
      reason: asString(j['reason']),
      reasonNote: asStringOrNull(j['reasonNote']),
      status: asString(j['status']),
      locationName: asString(j['locationName']),
      toLocationName: asStringOrNull(j['toLocationName']),
      partyId: asStringOrNull(j['partyId']),
      consigneeName: asString(consignee['name']),
      consigneeAddress: asStringOrNull(consignee['address']),
      consigneeGstin: asStringOrNull(consignee['gstin']),
      consigneeState: asStringOrNull(consignee['stateCode']),
      consignorName: asString(consignor['name']),
      consignorGstin: asStringOrNull(consignor['gstin']),
      vehicleNo: asStringOrNull(j['vehicleNo']),
      transporter: asStringOrNull(j['transporter']),
      ewbNo: asStringOrNull(j['ewbNo']),
      notes: asStringOrNull(j['notes']),
      taxableTotal: asDouble(j['taxableTotal']),
      taxTotal: asDouble(j['taxTotal']),
      lines: [for (final l in asJsonList(j['lines'])) ChallanLine.fromJson(l)],
    );
  }

  final String id;
  final String number;
  final String date;
  final String reason;
  final String? reasonNote;
  final String status;
  final String locationName;
  final String? toLocationName;
  final String? partyId;
  final String consigneeName;
  final String? consigneeAddress;
  final String? consigneeGstin;
  final String? consigneeState;
  final String consignorName;
  final String? consignorGstin;
  final String? vehicleNo;
  final String? transporter;
  final String? ewbNo;
  final String? notes;
  final double taxableTotal;
  final double taxTotal;
  final List<ChallanLine> lines;

  bool get isActive => status == 'open' || status == 'partly_closed';
  bool get canBill =>
      isActive &&
      partyId != null &&
      reason != 'job_work' &&
      reason != 'branch_transfer';
  bool get canCancel =>
      status == 'open' &&
      lines.every((l) => l.returnedQty == 0 && l.invoicedQty == 0);
}

class ChallanLineInput {
  const ChallanLineInput({
    required this.itemId,
    required this.qty,
    this.rate,
    this.provisional = false,
  });

  final String itemId;
  final double qty;
  final double? rate;
  final bool provisional;

  Json toJson() => withoutNulls({
    'itemId': itemId,
    'qty': qty,
    'rate': rate,
    if (provisional) 'provisional': true,
  });
}

class ChallanInput {
  const ChallanInput({
    required this.locationId,
    required this.reason,
    required this.lines,
    this.toLocationId,
    this.partyId,
    this.consigneeName,
    this.consigneeAddress,
    this.consigneeGstin,
    this.vehicleNo,
    this.transporter,
    this.ewbNo,
    this.notes,
  });

  final String locationId;
  final String reason;
  final String? toLocationId;
  final String? partyId;
  final String? consigneeName;
  final String? consigneeAddress;
  final String? consigneeGstin;
  final String? vehicleNo;
  final String? transporter;
  final String? ewbNo;
  final String? notes;
  final List<ChallanLineInput> lines;

  Json toJson() => withoutNulls({
    'locationId': locationId,
    'reason': reason,
    'toLocationId': toLocationId,
    'partyId': partyId,
    if (consigneeName != null)
      'consignee': withoutNulls({
        'name': consigneeName,
        'address': consigneeAddress,
        'gstin': consigneeGstin,
      }),
    'vehicleNo': vehicleNo,
    'transporter': transporter,
    'ewbNo': ewbNo,
    'notes': notes,
    'lines': [for (final l in lines) l.toJson()],
  });
}

class Currency {
  const Currency({
    required this.code,
    required this.name,
    required this.symbol,
    required this.decimals,
    required this.isActive,
  });

  factory Currency.fromJson(Json j) => Currency(
    code: asString(j['code']),
    name: asString(j['name']),
    symbol: asString(j['symbol']),
    decimals: asInt(j['decimals'], 2),
    isActive: asBool(j['isActive'], true),
  );

  final String code;
  final String name;
  final String symbol;
  final int decimals;
  final bool isActive;
}

class FxRate {
  const FxRate({
    required this.code,
    required this.date,
    required this.rate,
    this.note,
  });

  factory FxRate.fromJson(Json j) => FxRate(
    code: asString(j['code']),
    date: asString(j['date']),
    rate: asDouble(j['rate']),
    note: asStringOrNull(j['note']),
  );

  final String code;
  final String date;
  final double rate;
  final String? note;
}

class Lut {
  const Lut({
    required this.id,
    required this.fy,
    required this.lutNo,
    required this.validFrom,
    required this.validTo,
    this.arn,
  });

  factory Lut.fromJson(Json j) => Lut(
    id: asString(j['id']),
    fy: asString(j['fy']),
    lutNo: asString(j['lutNo']),
    arn: asStringOrNull(j['arn']),
    validFrom: asString(j['validFrom']),
    validTo: asString(j['validTo']),
  );

  final String id;
  final String fy;
  final String lutNo;
  final String? arn;
  final String validFrom;
  final String validTo;
}

class TcsNature {
  const TcsNature({
    required this.id,
    required this.code,
    required this.label,
    required this.sectionOld,
    required this.rate,
    required this.threshold,
    required this.isActive,
    this.sectionNew,
  });

  factory TcsNature.fromJson(Json j) => TcsNature(
    id: asString(j['id']),
    code: asString(j['code']),
    label: asString(j['label']),
    sectionOld: asString(j['sectionOld']),
    sectionNew: asStringOrNull(j['sectionNew']),
    rate: asDouble(j['rate']),
    threshold: asDouble(j['threshold']),
    isActive: asBool(j['isActive'], true),
  );

  final String id;
  final String code;
  final String label;
  final String sectionOld;
  final String? sectionNew;
  final double rate;
  final double threshold;
  final bool isActive;
}

class ExportSettings {
  const ExportSettings({this.tcsEnabled = false, this.tcsBase = 'taxable'});

  factory ExportSettings.fromJson(Json j) => ExportSettings(
    tcsEnabled: asBool(j['tcsEnabled']),
    tcsBase: asString(j['tcsBase'], 'taxable'),
  );

  final bool tcsEnabled;
  final String tcsBase;
}

class TcsRow {
  const TcsRow({
    required this.number,
    required this.date,
    required this.partyName,
    required this.section,
    required this.rate,
    required this.base,
    required this.tcs,
    this.pan,
  });

  factory TcsRow.fromJson(Json j) => TcsRow(
    number: asString(j['number']),
    date: asString(j['date']),
    partyName: asString(j['partyName']),
    pan: asStringOrNull(j['pan']),
    section: asString(j['section']),
    rate: asDouble(j['rate']),
    base: asDouble(j['base']),
    tcs: asDouble(j['tcs']),
  );

  final String number;
  final String date;
  final String partyName;
  final String? pan;
  final String section;
  final double rate;
  final double base;
  final double tcs;
}

class TcsReport {
  const TcsReport({
    required this.rows,
    required this.total,
    required this.missingPan,
  });

  factory TcsReport.fromJson(Json j) => TcsReport(
    rows: [for (final r in asJsonList(j['data'])) TcsRow.fromJson(r)],
    total: asDouble(j['total']),
    missingPan: asInt(j['missingPan']),
  );

  final List<TcsRow> rows;
  final double total;
  final int missingPan;
}

/// Export, currency and TCS facts printed on an invoice (`ext` in the
/// invoice JSON); null when the invoice has none.
class InvoiceExt {
  const InvoiceExt({
    this.category,
    this.declaration,
    this.lutNo,
    this.shippingBillNo,
    this.shippingBillDate,
    this.portCode,
    this.country,
    this.currencyCode,
    this.exchangeRate,
    this.fcTotal,
    this.tcsSection,
    this.tcsRate,
    this.tcsAmount = 0,
  });

  static InvoiceExt? fromJson(Object? raw) {
    final j = asJsonOrNull(raw);
    if (j == null) return null;
    return InvoiceExt(
      category: asStringOrNull(j['category']),
      declaration: asStringOrNull(j['declaration']),
      lutNo: asStringOrNull(j['lutNo']),
      shippingBillNo: asStringOrNull(j['shippingBillNo']),
      shippingBillDate: asStringOrNull(j['shippingBillDate']),
      portCode: asStringOrNull(j['portCode']),
      country: asStringOrNull(j['country']),
      currencyCode: asStringOrNull(j['currencyCode']),
      exchangeRate: asDoubleOrNull(j['exchangeRate']),
      fcTotal: asDoubleOrNull(j['fcTotal']),
      tcsSection: asStringOrNull(j['tcsSection']),
      tcsRate: asDoubleOrNull(j['tcsRate']),
      tcsAmount: asDouble(j['tcsAmount']),
    );
  }

  final String? category;
  final String? declaration;
  final String? lutNo;
  final String? shippingBillNo;
  final String? shippingBillDate;
  final String? portCode;
  final String? country;
  final String? currencyCode;
  final double? exchangeRate;
  final double? fcTotal;
  final String? tcsSection;
  final double? tcsRate;
  final double tcsAmount;
}

/// The extra invoice fields a user chose, as the JSON merged into the invoice
/// body. Empty when nothing is set.
class ExportChoice {
  const ExportChoice({
    this.category,
    this.shippingBillNo,
    this.shippingBillDate,
    this.portCode,
    this.country,
    this.currencyCode,
    this.rate,
    this.tcsOff = false,
  });

  final String? category;
  final String? shippingBillNo;
  final String? shippingBillDate;
  final String? portCode;
  final String? country;
  final String? currencyCode;
  final double? rate;
  final bool tcsOff;

  Json toJson() => {
    if (category != null)
      'exportInfo': withoutNulls({
        'category': category,
        'shippingBillNo': shippingBillNo,
        'shippingBillDate': shippingBillDate,
        'portCode': portCode,
        'country': country,
      }),
    if (currencyCode != null && currencyCode != 'INR')
      'currency': withoutNulls({'code': currencyCode, 'rate': rate}),
    if (tcsOff) 'tcs': {'off': true},
  };
}

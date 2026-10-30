import '../../core/json.dart';

enum PartyType {
  customer('Customer'),
  vendor('Vendor'),
  both('Customer & vendor');

  const PartyType(this.label);

  final String label;

  static PartyType parse(Object? value) => PartyType.values.firstWhere(
    (t) => t.name == value,
    orElse: () => PartyType.customer,
  );
}

class Party {
  const Party({
    required this.id,
    required this.companyId,
    required this.type,
    required this.name,
    this.gstin,
    this.stateCode,
    this.phone,
    this.email,
    this.address,
    this.pan,
    this.pincode,
    this.creditLimit = 0,
    this.creditDays = 0,
    this.balance,
    this.createdAt,
    this.udyamNo,
    this.msmeCategory,
    this.tdsSectionId,
    this.tdsSectionCode,
  });

  factory Party.fromJson(Json json) => Party(
    id: asString(json['id']),
    companyId: asString(json['companyId']),
    type: PartyType.parse(json['type']),
    name: asString(json['name']),
    gstin: asStringOrNull(json['gstin']),
    stateCode: asStringOrNull(json['stateCode']),
    phone: asStringOrNull(json['phone']),
    email: asStringOrNull(json['email']),
    address: asStringOrNull(json['address']),
    pan: asStringOrNull(json['pan']),
    pincode: asStringOrNull(json['pincode']),
    creditLimit: asDouble(json['creditLimit']),
    creditDays: asInt(json['creditDays']),
    balance: asDoubleOrNull(json['balance']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    udyamNo: asStringOrNull(json['udyamNo']),
    msmeCategory: asStringOrNull(json['msmeCategory']),
    tdsSectionId: asStringOrNull(json['tdsSectionId']),
    tdsSectionCode: asStringOrNull(json['tdsSectionCode']),
  );

  final String id;
  final String companyId;
  final PartyType type;
  final String name;
  final String? gstin;
  final String? stateCode;
  final String? phone;
  final String? email;
  final String? address;

  /// `AAAAA9999A` (API v1.3).
  final String? pan;

  /// 6 digits, not starting with 0 (API v1.3); needed for e-invoicing.
  final String? pincode;
  final double creditLimit;

  /// Invoice due date = invoice date + credit days.
  final int creditDays;

  /// `+` they owe us, `−` we owe them; `null` if the server omits it.
  final double? balance;
  final DateTime? createdAt;

  /// `UDYAM-XX-00-0000000` (API v1.4).
  final String? udyamNo;

  /// `micro`, `small`, `medium` or null.
  final String? msmeCategory;
  final String? tdsSectionId;
  final String? tdsSectionCode;

  /// Micro and small suppliers must be paid within 45 days (MSMED Act s.15).
  bool get isMsmeMicroSmall =>
      msmeCategory == 'micro' || msmeCategory == 'small';

  bool get isCustomer => type != PartyType.vendor;
  bool get isVendor => type != PartyType.customer;

  Json toInputJson() => {
    'type': type.name,
    'name': name,
    'gstin': gstin,
    'stateCode': stateCode,
    'phone': phone,
    'email': email,
    'address': address,
    'pan': pan,
    'pincode': pincode,
    'creditLimit': creditLimit,
    'creditDays': creditDays,
    'udyamNo': udyamNo,
    'msmeCategory': msmeCategory,
    'tdsSectionId': tdsSectionId,
  };
}

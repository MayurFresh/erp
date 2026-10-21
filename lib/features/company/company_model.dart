import '../../core/json.dart';

/// The company profile (`GET /company`; also the base of each membership in
/// `/me`). The v1.1 contact, bank and invoice fields are `null` when absent.
class Company {
  const Company({
    required this.id,
    required this.name,
    required this.stateCode,
    this.legalName,
    this.gstin,
    this.pan,
    this.address,
    this.phone,
    this.email,
    this.website,
    this.bankName,
    this.bankAccountNo,
    this.bankIfsc,
    this.upiId,
    this.invoiceTerms,
    this.invoiceFooter,
  });

  factory Company.fromJson(Json json) => Company(
    id: asString(json['id']),
    name: asString(json['name']),
    legalName: asStringOrNull(json['legalName']),
    gstin: asStringOrNull(json['gstin']),
    stateCode: asString(json['stateCode']),
    pan: asStringOrNull(json['pan']),
    address: asStringOrNull(json['address']),
    phone: asStringOrNull(json['phone']),
    email: asStringOrNull(json['email']),
    website: asStringOrNull(json['website']),
    bankName: asStringOrNull(json['bankName']),
    bankAccountNo: asStringOrNull(json['bankAccountNo']),
    bankIfsc: asStringOrNull(json['bankIfsc']),
    upiId: asStringOrNull(json['upiId']),
    invoiceTerms: asStringOrNull(json['invoiceTerms']),
    invoiceFooter: asStringOrNull(json['invoiceFooter']),
  );

  final String id;
  final String name;
  final String? legalName;
  final String? gstin;
  final String stateCode;
  final String? pan;
  final String? address;
  final String? phone;
  final String? email;
  final String? website;
  final String? bankName;
  final String? bankAccountNo;
  final String? bankIfsc;
  final String? upiId;
  final String? invoiceTerms;
  final String? invoiceFooter;

  bool get hasBankDetails =>
      [bankName, bankAccountNo, bankIfsc, upiId].any(_present);

  static bool _present(String? value) => value != null && value.isNotEmpty;
}

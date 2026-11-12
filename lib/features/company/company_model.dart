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
    this.pincode,
    this.einvoiceEnabled = false,
    this.einvoiceMode = 'manual',
    this.tan,
    this.booksLockedUntil,
    this.msmeBankRate,
    this.gstFiling = 'monthly',
    this.constitution,
    this.responsiblePerson,
    this.itrForm,
    this.businessType = 'general',
    this.plan = 'business',
    this.enabledModules,
    this.terms = const {},
    this.country = 'IN',
    this.currency = 'INR',
    this.logoFileId,
    this.brandColor,
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
    pincode: asStringOrNull(json['pincode']),
    einvoiceEnabled: asBool(json['einvoiceEnabled']),
    einvoiceMode: asString(json['einvoiceMode'], 'manual'),
    tan: asStringOrNull(json['tan']),
    booksLockedUntil: asStringOrNull(json['booksLockedUntil']),
    msmeBankRate: asDoubleOrNull(json['msmeBankRate']),
    gstFiling: asString(json['gstFiling'], 'monthly'),
    constitution: asStringOrNull(json['constitution']),
    responsiblePerson: asJsonOrNull(json['responsiblePerson']) == null
        ? null
        : ResponsiblePerson.fromJson(asJson(json['responsiblePerson'])),
    itrForm: asStringOrNull(json['itrForm']),
    businessType: asString(json['businessType'], 'general'),
    plan: asString(json['plan'], 'business'),
    enabledModules: asStringListOrNull(json['enabledModules']),
    terms: {
      for (final e in (asJsonOrNull(json['terms']) ?? const {}).entries)
        e.key: e.value.toString(),
    },
    country: asString(json['country'], 'IN'),
    currency: asString(json['currency'], 'INR'),
    logoFileId: asStringOrNull(json['logoFileId']),
    brandColor: asStringOrNull(json['brandColor']),
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
  final String? pincode;

  /// GST e-invoicing (API v1.3).
  final bool einvoiceEnabled;

  /// `manual` or `sandbox`.
  final String einvoiceMode;

  /// TAN, `AAAA99999A` (API v1.4).
  final String? tan;

  /// `YYYY-MM-DD`: no posting on or before this date.
  final String? booksLockedUntil;

  /// RBI bank rate, % p.a., used for MSME interest.
  final double? msmeBankRate;

  /// `monthly` or `quarterly`.
  final String gstFiling;

  /// `proprietorship`, `partnership`, `llp`, `private_company`,
  /// `public_company`, `huf`, `trust`, `other` or `null` (API v1.6).
  final String? constitution;

  /// The deductor's responsible person for TDS statements (API v1.6).
  final ResponsiblePerson? responsiblePerson;

  /// `itr3`, `itr4`, `itr5`, `itr6` or `null` (API v1.6).
  final String? itrForm;

  /// Business type id from `GET /business-types` (API v1.8.2).
  final String businessType;

  /// `solo`, `team`, `business` or `enterprise`.
  final String plan;

  /// `null` = the defaults for [businessType].
  final List<String>? enabledModules;

  /// Word overrides, e.g. `{'customer': 'Patient'}`.
  final Map<String, String> terms;

  /// ISO 3166-1 alpha-2.
  final String country;

  /// ISO 4217.
  final String currency;

  final String? logoFileId;

  /// `#RRGGBB`, used on PDFs and client reports.
  final String? brandColor;

  bool get einvoiceSandbox => einvoiceMode == 'sandbox';

  bool get hasBankDetails =>
      [bankName, bankAccountNo, bankIfsc, upiId].any(_present);

  static bool _present(String? value) => value != null && value.isNotEmpty;
}

/// `company.responsiblePerson` (API v1.6).
class ResponsiblePerson {
  const ResponsiblePerson({
    this.name = '',
    this.designation = '',
    this.pan = '',
    this.mobile = '',
    this.email = '',
  });

  factory ResponsiblePerson.fromJson(Json json) => ResponsiblePerson(
    name: asString(json['name']),
    designation: asString(json['designation']),
    pan: asString(json['pan']),
    mobile: asString(json['mobile']),
    email: asString(json['email']),
  );

  final String name;
  final String designation;
  final String pan;
  final String mobile;
  final String email;

  Json toJson() => {
    'name': name,
    'designation': designation,
    'pan': pan,
    'mobile': mobile,
    'email': email,
  };

  @override
  bool operator ==(Object other) =>
      other is ResponsiblePerson &&
      other.name == name &&
      other.designation == designation &&
      other.pan == pan &&
      other.mobile == mobile &&
      other.email == email;

  @override
  int get hashCode => Object.hash(name, designation, pan, mobile, email);
}

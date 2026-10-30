/// Company profile edits, permission catalogue, role and user edits.
/// Pure Dart.
library;

import '../../core/json.dart';
import '../company/company_model.dart';
import '../users/user_models.dart';
import '../../core/validators.dart';

export '../../core/validators.dart'
    show
        panPattern,
        tanPattern,
        ifscPattern,
        pincodePattern,
        upiPattern,
        bankAccountPattern,
        validatePan,
        validateTan,
        validateIfsc,
        validatePincode,
        validateUpi,
        validateBankAccount;

export '../company/company_model.dart' show Company, ResponsiblePerson;
export '../users/user_models.dart' show Role, RoleAssignment, UserRow;

// ------------------------------------------------------------------ Company

/// Fields `PATCH /company` accepts, in form order.
const List<String> companyFields = [
  'name',
  'legalName',
  'gstin',
  'pan',
  'tan',
  'msmeBankRate',
  'address',
  'pincode',
  'phone',
  'email',
  'website',
  'bankName',
  'bankAccountNo',
  'bankIfsc',
  'upiId',
  'invoiceTerms',
  'invoiceFooter',
  'constitution',
  'itrForm',
];

/// Form keys of the responsible person (API v1.6), sent as one object.
const List<String> responsiblePersonKeys = [
  'rpName',
  'rpDesignation',
  'rpPan',
  'rpMobile',
  'rpEmail',
];

/// Constitutions the API accepts, with labels.
const Map<String, String> constitutionLabels = {
  'proprietorship': 'Proprietorship',
  'partnership': 'Partnership firm',
  'llp': 'LLP',
  'private_company': 'Private limited company',
  'public_company': 'Public company',
  'huf': 'HUF',
  'trust': 'Trust',
  'other': 'Other',
};

/// ITR forms the API accepts, with labels.
const Map<String, String> itrFormLabels = {
  'itr3': 'ITR-3 (business or profession, books of account)',
  'itr4': 'ITR-4 (presumptive income)',
  'itr5': 'ITR-5 (firm, LLP)',
  'itr6': 'ITR-6 (company)',
};

/// Editable values of [c] keyed by [companyFields] (`null` → `''`).
Map<String, String> companyFormValues(Company c) => {
  'name': c.name,
  'legalName': c.legalName ?? '',
  'gstin': c.gstin ?? '',
  'pan': c.pan ?? '',
  'tan': c.tan ?? '',
  'msmeBankRate': c.msmeBankRate == null ? '' : '${c.msmeBankRate}',
  'address': c.address ?? '',
  'pincode': c.pincode ?? '',
  'phone': c.phone ?? '',
  'email': c.email ?? '',
  'website': c.website ?? '',
  'bankName': c.bankName ?? '',
  'bankAccountNo': c.bankAccountNo ?? '',
  'bankIfsc': c.bankIfsc ?? '',
  'upiId': c.upiId ?? '',
  'invoiceTerms': c.invoiceTerms ?? '',
  'invoiceFooter': c.invoiceFooter ?? '',
  'constitution': c.constitution ?? '',
  'itrForm': c.itrForm ?? '',
  'rpName': c.responsiblePerson?.name ?? '',
  'rpDesignation': c.responsiblePerson?.designation ?? '',
  'rpPan': c.responsiblePerson?.pan ?? '',
  'rpMobile': c.responsiblePerson?.mobile ?? '',
  'rpEmail': c.responsiblePerson?.email ?? '',
};

/// The responsible person typed into the form; `null` when every field is
/// empty. Codes are trimmed and the PAN upper-cased.
ResponsiblePerson? responsiblePersonFromValues(Map<String, String> values) {
  String v(String key) => (values[key] ?? '').trim();
  final rp = ResponsiblePerson(
    name: v('rpName'),
    designation: v('rpDesignation'),
    pan: v('rpPan').toUpperCase(),
    mobile: v('rpMobile'),
    email: v('rpEmail'),
  );
  return const ResponsiblePerson() == rp ? null : rp;
}

/// Fields whose value changed; a cleared field is sent as `null`. Codes
/// (GSTIN, PAN, IFSC) are upper-cased. Multi-line fields keep inner line
/// breaks but are trimmed.
Json companyPatch(Company original, Map<String, String> values) {
  final before = companyFormValues(original);
  const upper = {'gstin', 'pan', 'tan', 'bankIfsc'};
  final result = <String, dynamic>{};
  for (final field in companyFields) {
    var value = (values[field] ?? before[field] ?? '').trim();
    if (upper.contains(field)) value = value.toUpperCase();
    if (value == (before[field] ?? '').trim()) continue;
    result[field] = value.isEmpty && field != 'name' ? null : value;
  }
  final rpBefore = original.responsiblePerson;
  final rpNow = responsiblePersonFromValues({...before, ...values});
  if (rpNow != rpBefore) result['responsiblePerson'] = rpNow?.toJson();
  // The bank rate is a number on the wire.
  final rate = result['msmeBankRate'];
  if (rate is String) result['msmeBankRate'] = double.tryParse(rate);
  return result;
}

/// The PAN embedded in a GSTIN (characters 3–12), if it looks valid.
String? panFromGstin(String? gstin) {
  final g = gstin?.trim().toUpperCase() ?? '';
  if (g.length < 12) return null;
  final pan = g.substring(2, 12);
  return panPattern.hasMatch(pan) ? pan : null;
}

// -------------------------------------------------------------- Permissions

/// One entry of `GET /permissions`.
class PermissionDef {
  const PermissionDef({
    required this.key,
    required this.module,
    required this.label,
  });

  factory PermissionDef.fromJson(Json json) => PermissionDef(
    key: asString(json['key']),
    module: asString(json['module'], 'Other'),
    label: asString(json['label'], asString(json['key'])),
  );

  final String key;
  final String module;
  final String label;
}

/// Permissions grouped by module, keeping the server's order.
Map<String, List<PermissionDef>> groupPermissions(
  Iterable<PermissionDef> defs,
) {
  final result = <String, List<PermissionDef>>{};
  for (final d in defs) {
    result.putIfAbsent(d.module, () => []).add(d);
  }
  return result;
}

/// `true` all chosen, `false` none, `null` some (tri-state checkbox).
bool? moduleSelection(List<PermissionDef> module, Set<String> selected) {
  final count = module.where((d) => selected.contains(d.key)).length;
  if (count == 0) return false;
  if (count == module.length) return true;
  return null;
}

/// Body for `POST /roles` or the changed fields for `PATCH /roles/:id`.
class RoleInput {
  const RoleInput({
    required this.name,
    required this.permissions,
    this.description,
  });

  final String name;
  final String? description;
  final Set<String> permissions;

  Json toCreateJson() => {
    'name': name,
    if (description != null && description!.isNotEmpty)
      'description': description,
    'permissions': permissions.toList()..sort(),
  };

  Json toPatchJson(Role original) {
    final before = original.permissions.toSet();
    final desc = description?.isEmpty ?? true ? null : description;
    return {
      if (name != original.name) 'name': name,
      if (desc != original.description) 'description': desc,
      if (before.length != permissions.length ||
          !before.containsAll(permissions))
        'permissions': permissions.toList()..sort(),
    };
  }
}

/// `Copy of Owner`, `Copy of Owner (2)`, … avoiding [taken] names.
String copyName(String name, Iterable<String> taken) {
  final names = taken.map((n) => n.toLowerCase()).toSet();
  var candidate = 'Copy of $name';
  for (var i = 2; names.contains(candidate.toLowerCase()); i++) {
    candidate = 'Copy of $name ($i)';
  }
  return candidate;
}

// -------------------------------------------------------------------- Users

/// Changed fields for `PATCH /users/:id`. Role and locations replace the
/// user's assignment in the active company, so both are sent when either
/// changes.
Json userPatch(
  UserRow original, {
  required String name,
  required String? phone,
  required bool isActive,
  required String? roleId,
  required List<String>? locationIds,
}) {
  final assignment = original.assignments.isEmpty
      ? null
      : original.assignments.first;
  final beforeLocations = assignment?.locationIds;
  bool sameLocations() {
    if (beforeLocations == null || locationIds == null) {
      return beforeLocations == null && locationIds == null;
    }
    return beforeLocations.length == locationIds.length &&
        beforeLocations.toSet().containsAll(locationIds);
  }

  final accessChanged =
      roleId != null && (roleId != assignment?.roleId || !sameLocations());
  return {
    if (name != original.name) 'name': name,
    if ((phone ?? '') != (original.phone ?? '')) 'phone': phone,
    if (isActive != original.isActive) 'isActive': isActive,
    if (accessChanged) ...{'roleId': roleId, 'locationIds': locationIds},
  };
}

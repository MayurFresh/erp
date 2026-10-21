import '../../core/json.dart';
import '../../core/permissions.dart';
import '../../core/token_store.dart';
import '../company/company_model.dart';

export '../company/company_model.dart' show Company;

class User {
  const User({
    required this.id,
    required this.name,
    required this.email,
    this.phone,
  });

  factory User.fromJson(Json json) => User(
    id: asString(json['id']),
    name: asString(json['name']),
    email: asString(json['email']),
    phone: asStringOrNull(json['phone']),
  );

  final String id;
  final String name;
  final String email;
  final String? phone;

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    final letters = parts.take(2).map((p) => p[0].toUpperCase()).join();
    return letters.isEmpty ? '?' : letters;
  }
}

class RoleRef {
  const RoleRef({required this.id, required this.name});

  factory RoleRef.fromJson(Json json) =>
      RoleRef(id: asString(json['id']), name: asString(json['name']));

  final String id;
  final String name;
}

/// A company the user belongs to, with their roles, permissions and
/// location scope in it (`Company & { roles, permissions, locationIds }`).
class Membership extends Company {
  const Membership({
    required super.id,
    required super.name,
    required super.stateCode,
    super.legalName,
    super.gstin,
    super.pan,
    super.address,
    super.phone,
    super.email,
    super.website,
    super.bankName,
    super.bankAccountNo,
    super.bankIfsc,
    super.upiId,
    super.invoiceTerms,
    super.invoiceFooter,
    this.roles = const [],
    this.permissions = PermissionSet.none,
    this.locationIds,
  });

  factory Membership.fromJson(Json json) {
    final c = Company.fromJson(json);
    return Membership(
      id: c.id,
      name: c.name,
      legalName: c.legalName,
      gstin: c.gstin,
      stateCode: c.stateCode,
      pan: c.pan,
      address: c.address,
      phone: c.phone,
      email: c.email,
      website: c.website,
      bankName: c.bankName,
      bankAccountNo: c.bankAccountNo,
      bankIfsc: c.bankIfsc,
      upiId: c.upiId,
      invoiceTerms: c.invoiceTerms,
      invoiceFooter: c.invoiceFooter,
      roles: asJsonList(json['roles']).map(RoleRef.fromJson).toList(),
      permissions: PermissionSet(asStringList(json['permissions']).toSet()),
      locationIds: asStringListOrNull(json['locationIds']),
    );
  }

  final List<RoleRef> roles;
  final PermissionSet permissions;

  /// `null` = all locations.
  final List<String>? locationIds;

  bool get allLocations => locationIds == null;

  bool can(String permission) => permissions.can(permission);
}

class Me {
  const Me({required this.user, required this.companies});

  factory Me.fromJson(Json json) => Me(
    user: User.fromJson(asJson(json['user'])),
    companies: asJsonList(json['companies']).map(Membership.fromJson).toList(),
  );

  final User user;
  final List<Membership> companies;

  Membership? company(String? id) {
    for (final company in companies) {
      if (company.id == id) return company;
    }
    return null;
  }
}

class AuthResult {
  const AuthResult({required this.tokens, required this.user});

  factory AuthResult.fromJson(Json json) => AuthResult(
    tokens: AuthTokens.fromJson(json),
    user: User.fromJson(asJson(json['user'])),
  );

  final AuthTokens tokens;
  final User user;
}

class SignupRequest {
  const SignupRequest({
    required this.businessName,
    required this.name,
    required this.email,
    required this.password,
    required this.stateCode,
    this.phone,
    this.gstin,
  });

  final String businessName;
  final String name;
  final String email;
  final String password;
  final String stateCode;
  final String? phone;
  final String? gstin;

  Json toJson() => withoutNulls({
    'businessName': businessName,
    'name': name,
    'email': email,
    'password': password,
    'phone': phone,
    'stateCode': stateCode,
    'gstin': gstin,
  });
}

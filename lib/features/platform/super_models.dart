import '../../core/json.dart';

/// A count under a key, as in "by business type".
class SuperCount {
  const SuperCount(this.key, this.count);

  factory SuperCount.fromJson(Json json) =>
      SuperCount(asString(json['key'], 'none'), asInt(json['count']));

  final String key;
  final int count;
}

class SuperOverview {
  const SuperOverview({
    required this.tenants,
    required this.activeTenants,
    required this.suspendedTenants,
    required this.users,
    required this.companies,
    required this.signedInLast30Days,
    required this.byBusinessType,
    required this.byPlan,
    required this.byCountry,
    required this.signupsByMonth,
  });

  factory SuperOverview.fromJson(Json json) => SuperOverview(
    tenants: asInt(json['tenants']),
    activeTenants: asInt(json['activeTenants']),
    suspendedTenants: asInt(json['suspendedTenants']),
    users: asInt(json['users']),
    companies: asInt(json['companies']),
    signedInLast30Days: asInt(json['usersSignedInLast30Days']),
    byBusinessType: asJsonList(
      json['byBusinessType'],
    ).map(SuperCount.fromJson).toList(),
    byPlan: asJsonList(json['byPlan']).map(SuperCount.fromJson).toList(),
    byCountry: asJsonList(json['byCountry']).map(SuperCount.fromJson).toList(),
    signupsByMonth: [
      for (final m in asJsonList(json['signupsByMonth']))
        (asString(m['month']), asInt(m['count'])),
    ],
  );

  final int tenants;
  final int activeTenants;
  final int suspendedTenants;
  final int users;
  final int companies;
  final int signedInLast30Days;
  final List<SuperCount> byBusinessType;
  final List<SuperCount> byPlan;
  final List<SuperCount> byCountry;

  /// `(YYYY-MM, sign-ups)` for the last 12 months, oldest first.
  final List<(String, int)> signupsByMonth;
}

class SuperTenant {
  const SuperTenant({
    required this.id,
    required this.name,
    required this.status,
    required this.createdAt,
    this.suspendedAt,
    this.suspendedReason,
    this.companyCount = 0,
    this.userCount = 0,
    this.activeUsers = 0,
    this.businessType,
    this.plan,
    this.country,
    this.ownerName,
    this.ownerEmail,
    this.lastSignInAt,
    this.hasPlatformAdmin = false,
  });

  factory SuperTenant.fromJson(Json json) => SuperTenant(
    id: asString(json['id']),
    name: asString(json['name']),
    status: asString(json['status'], 'active'),
    createdAt: asDateTimeOrNull(json['createdAt']),
    suspendedAt: asDateTimeOrNull(json['suspendedAt']),
    suspendedReason: asStringOrNull(json['suspendedReason']),
    companyCount: asInt(json['companyCount']),
    userCount: asInt(json['userCount']),
    activeUsers: asInt(json['activeUsers']),
    businessType: asStringOrNull(json['businessType']),
    plan: asStringOrNull(json['plan']),
    country: asStringOrNull(json['country']),
    ownerName: asStringOrNull(json['ownerName']),
    ownerEmail: asStringOrNull(json['ownerEmail']),
    lastSignInAt: asDateTimeOrNull(json['lastSignInAt']),
    hasPlatformAdmin: asBool(json['hasPlatformAdmin']),
  );

  final String id;
  final String name;
  final String status;
  final DateTime? createdAt;
  final DateTime? suspendedAt;
  final String? suspendedReason;
  final int companyCount;
  final int userCount;
  final int activeUsers;
  final String? businessType;
  final String? plan;
  final String? country;
  final String? ownerName;
  final String? ownerEmail;
  final DateTime? lastSignInAt;
  final bool hasPlatformAdmin;

  bool get suspended => status == 'suspended';
}

class SuperCompany {
  const SuperCompany({
    required this.id,
    required this.name,
    required this.businessType,
    required this.plan,
    required this.country,
    required this.enabledModules,
    required this.createdAt,
    required this.invoices,
    required this.parties,
    required this.items,
  });

  factory SuperCompany.fromJson(Json json) {
    final counts = asJson(json['counts']);
    return SuperCompany(
      id: asString(json['id']),
      name: asString(json['name']),
      businessType: asString(json['businessType']),
      plan: asString(json['plan']),
      country: asString(json['country']),
      enabledModules: json['enabledModules'] == null
          ? null
          : asStringList(json['enabledModules']),
      createdAt: asDateTimeOrNull(json['createdAt']),
      invoices: asInt(counts['invoices']),
      parties: asInt(counts['parties']),
      items: asInt(counts['items']),
    );
  }

  final String id;
  final String name;
  final String businessType;
  final String plan;
  final String country;

  /// `null` = the business type's defaults.
  final List<String>? enabledModules;
  final DateTime? createdAt;
  final int invoices;
  final int parties;
  final int items;
}

class SuperUser {
  const SuperUser({
    required this.id,
    required this.name,
    required this.email,
    required this.isActive,
    required this.isLocked,
    required this.twoFactor,
    required this.isPlatformAdmin,
    required this.roles,
    this.lastSignInAt,
  });

  factory SuperUser.fromJson(Json json) => SuperUser(
    id: asString(json['id']),
    name: asString(json['name']),
    email: asString(json['email']),
    isActive: asBool(json['isActive'], true),
    isLocked: asBool(json['isLocked']),
    twoFactor: asBool(json['twoFactor']),
    isPlatformAdmin: asBool(json['isPlatformAdmin']),
    lastSignInAt: asDateTimeOrNull(json['lastSignInAt']),
    roles: [
      for (final r in asJsonList(json['roles']))
        (asString(r['companyId']), asString(r['role'])),
    ],
  );

  final String id;
  final String name;
  final String email;
  final bool isActive;
  final bool isLocked;
  final bool twoFactor;
  final bool isPlatformAdmin;
  final DateTime? lastSignInAt;

  /// `(companyId, role name)`.
  final List<(String, String)> roles;
}

class SuperTenantDetail {
  const SuperTenantDetail({
    required this.tenant,
    required this.companies,
    required this.users,
  });

  factory SuperTenantDetail.fromJson(Json json) => SuperTenantDetail(
    tenant: SuperTenant.fromJson(asJson(json['tenant'])),
    companies: asJsonList(
      json['companies'],
    ).map(SuperCompany.fromJson).toList(),
    users: asJsonList(json['users']).map(SuperUser.fromJson).toList(),
  );

  final SuperTenant tenant;
  final List<SuperCompany> companies;
  final List<SuperUser> users;
}

class SuperAuditEntry {
  const SuperAuditEntry({
    required this.id,
    required this.adminName,
    required this.action,
    required this.createdAt,
    this.tenantId,
    this.tenantName,
    this.detail = const {},
  });

  factory SuperAuditEntry.fromJson(Json json) => SuperAuditEntry(
    id: asString(json['id']),
    adminName: asString(json['adminName']),
    action: asString(json['action']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    tenantId: asStringOrNull(json['tenantId']),
    tenantName: asStringOrNull(json['tenantName']),
    detail: asJsonOrNull(json['detail']) ?? const {},
  );

  final String id;
  final String adminName;
  final String action;
  final DateTime? createdAt;
  final String? tenantId;
  final String? tenantName;
  final Json detail;
}

class ResetLink {
  const ResetLink(this.link, this.expiresAt);

  final String link;
  final DateTime? expiresAt;
}

const _actionWords = {
  'tenant_suspend': 'Suspended account',
  'tenant_activate': 'Reactivated account',
  'tenant_rename': 'Renamed account',
  'company_update': 'Changed company plan or type',
  'user_deactivate': 'Deactivated user',
  'user_activate': 'Activated user',
  'user_unlock': 'Unlocked user',
  'user_sign_out': 'Signed user out everywhere',
  'user_reset_link': 'Created password reset link',
};

String superActionLabel(String action) => _actionWords[action] ?? action;

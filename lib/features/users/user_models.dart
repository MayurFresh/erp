import '../../core/json.dart';

class Role {
  const Role({
    required this.id,
    required this.name,
    this.description,
    this.isSystem = false,
    this.permissions = const [],
  });

  factory Role.fromJson(Json json) => Role(
    id: asString(json['id']),
    name: asString(json['name']),
    description: asStringOrNull(json['description']),
    isSystem: asBool(json['isSystem']),
    permissions: asStringList(json['permissions']),
  );

  final String id;
  final String name;
  final String? description;
  final bool isSystem;
  final List<String> permissions;
}

class RoleAssignment {
  const RoleAssignment({
    required this.roleId,
    required this.roleName,
    this.locationIds,
  });

  factory RoleAssignment.fromJson(Json json) => RoleAssignment(
    roleId: asString(json['roleId']),
    roleName: asString(json['roleName']),
    locationIds: asStringListOrNull(json['locationIds']),
  );

  final String roleId;
  final String roleName;

  /// `null` = all locations.
  final List<String>? locationIds;
}

class UserRow {
  const UserRow({
    required this.id,
    required this.name,
    required this.email,
    this.phone,
    this.isActive = true,
    this.assignments = const [],
  });

  factory UserRow.fromJson(Json json) => UserRow(
    id: asString(json['id']),
    name: asString(json['name']),
    email: asString(json['email']),
    phone: asStringOrNull(json['phone']),
    isActive: asBool(json['isActive'], true),
    assignments: asJsonList(
      json['assignments'],
    ).map(RoleAssignment.fromJson).toList(),
  );

  final String id;
  final String name;
  final String email;
  final String? phone;
  final bool isActive;
  final List<RoleAssignment> assignments;
}

class NewUser {
  const NewUser({
    required this.name,
    required this.email,
    required this.password,
    required this.roleId,
    this.phone,
    this.locationIds,
  });

  final String name;
  final String email;
  final String? phone;
  final String password;
  final String roleId;

  /// `null` = all locations.
  final List<String>? locationIds;

  Json toJson() => {
    'name': name,
    'email': email,
    if (phone != null) 'phone': phone,
    'password': password,
    'roleId': roleId,
    'locationIds': locationIds,
  };
}

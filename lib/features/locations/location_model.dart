import '../../core/json.dart';

const List<String> locationTypes = [
  'branch',
  'site',
  'warehouse',
  'department',
  'store',
  'office',
];

String locationTypeLabel(String type) =>
    type.isEmpty ? type : '${type[0].toUpperCase()}${type.substring(1)}';

class Location {
  const Location({
    required this.id,
    required this.companyId,
    required this.type,
    required this.name,
    required this.stateCode,
    this.parentId,
    this.code,
    this.address,
    this.isActive = true,
    this.createdAt,
  });

  factory Location.fromJson(Json json) => Location(
    id: asString(json['id']),
    companyId: asString(json['companyId']),
    parentId: asStringOrNull(json['parentId']),
    type: asString(json['type']),
    name: asString(json['name']),
    code: asStringOrNull(json['code']),
    stateCode: asString(json['stateCode']),
    address: asStringOrNull(json['address']),
    isActive: asBool(json['isActive'], true),
    createdAt: asDateTimeOrNull(json['createdAt']),
  );

  final String id;
  final String companyId;
  final String? parentId;
  final String type;
  final String name;
  final String? code;
  final String stateCode;
  final String? address;
  final bool isActive;
  final DateTime? createdAt;

  String get displayName => code == null ? name : '$name ($code)';

  Json toInputJson() => {
    'type': type,
    'name': name,
    'code': code,
    'stateCode': stateCode,
    'address': address,
    'isActive': isActive,
  };
}

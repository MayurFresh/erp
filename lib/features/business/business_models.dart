import 'package:flutter/material.dart';

import '../../core/json.dart';

class RoleTemplateDef {
  const RoleTemplateDef(this.name, this.description, this.permissions);

  factory RoleTemplateDef.fromJson(Json j) => RoleTemplateDef(
    asString(j['name']),
    asString(j['description']),
    [for (final p in (j['permissions'] as List? ?? const [])) '$p'],
  );

  final String name;
  final String description;
  final List<String> permissions;
}

class BusinessTypeDef {
  const BusinessTypeDef({
    required this.id,
    required this.name,
    required this.group,
    required this.description,
    required this.icon,
    required this.modules,
    required this.roles,
    required this.terms,
    this.quickActions = const [],
  });

  factory BusinessTypeDef.fromJson(Json j) => BusinessTypeDef(
    id: asString(j['id']),
    name: asString(j['name']),
    group: asString(j['group']),
    description: asString(j['description']),
    icon: asString(j['icon']),
    modules: [for (final m in (j['modules'] as List? ?? const [])) '$m'],
    roles: asJsonList(j['roles']).map(RoleTemplateDef.fromJson).toList(),
    terms: {for (final e in asJson(j['terms']).entries) e.key: '${e.value}'},
    quickActions: [
      for (final q in asJsonList(j['quickActions']))
        (
          label: asString(q['label']),
          route: asString(q['route']),
          permission: asString(q['permission']),
        ),
    ],
  );

  final String id;
  final String name;
  final String group;
  final String description;
  final String icon;
  final List<String> modules;
  final List<RoleTemplateDef> roles;
  final Map<String, String> terms;
  final List<({String label, String route, String permission})> quickActions;
}

class BusinessGroupDef {
  const BusinessGroupDef(this.id, this.name);

  final String id;
  final String name;
}

class BusinessCatalogue {
  const BusinessCatalogue({required this.groups, required this.types});

  factory BusinessCatalogue.fromJson(Json j) => BusinessCatalogue(
    groups: [
      for (final g in asJsonList(j['groups']))
        BusinessGroupDef(asString(g['id']), asString(g['name'])),
    ],
    types: asJsonList(j['types']).map(BusinessTypeDef.fromJson).toList(),
  );

  /// Used when the catalogue cannot be loaded (offline signup).
  static const BusinessCatalogue empty = BusinessCatalogue(
    groups: [],
    types: [],
  );

  final List<BusinessGroupDef> groups;
  final List<BusinessTypeDef> types;

  BusinessTypeDef? byId(String id) {
    for (final t in types) {
      if (t.id == id) return t;
    }
    return null;
  }
}

/// Material icon for a catalogue icon key.
const Map<String, IconData> kTypeIcons = {
  'store': Icons.store,
  'shopping_bag': Icons.shopping_bag,
  'checkroom': Icons.checkroom,
  'devices': Icons.devices,
  'hardware': Icons.hardware,
  'medication': Icons.medication,
  'diamond': Icons.diamond,
  'warehouse': Icons.warehouse,
  'build': Icons.build,
  'language': Icons.language,
  'storefront': Icons.storefront,
  'restaurant': Icons.restaurant,
  'local_cafe': Icons.local_cafe,
  'ramen_dining': Icons.ramen_dining,
  'celebration': Icons.celebration,
  'medical_services': Icons.medical_services,
  'local_hospital': Icons.local_hospital,
  'biotech': Icons.biotech,
  'gavel': Icons.gavel,
  'calculate': Icons.calculate,
  'support_agent': Icons.support_agent,
  'architecture': Icons.architecture,
  'code': Icons.code,
  'person': Icons.person,
  'engineering': Icons.engineering,
  'apartment': Icons.apartment,
  'chair': Icons.chair,
  'precision_manufacturing': Icons.precision_manufacturing,
  'handyman': Icons.handyman,
  'texture': Icons.texture,
  'school': Icons.school,
  'menu_book': Icons.menu_book,
  'hotel': Icons.hotel,
  'flight': Icons.flight,
  'local_shipping': Icons.local_shipping,
  'agriculture': Icons.agriculture,
  'content_cut': Icons.content_cut,
  'fitness_center': Icons.fitness_center,
  'car_repair': Icons.car_repair,
  'volunteer_activism': Icons.volunteer_activism,
  'home_work': Icons.home_work,
  'temple_hindu': Icons.temple_hindu,
  'account_balance': Icons.account_balance,
  'domain': Icons.domain,
  'location_city': Icons.location_city,
  'person_pin': Icons.person_pin,
  'handshake': Icons.handshake,
  'groups': Icons.groups,
  'corporate_fare': Icons.corporate_fare,
  'hub': Icons.hub,
  'business_center': Icons.business_center,
};

IconData typeIcon(String key) => kTypeIcons[key] ?? Icons.business_center;

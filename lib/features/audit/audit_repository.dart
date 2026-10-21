import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';

class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.entity,
    required this.entityId,
    required this.action,
    this.userId,
    this.userName,
    this.before,
    this.after,
    this.createdAt,
  });

  factory AuditEntry.fromJson(Json json) => AuditEntry(
    id: asString(json['id']),
    entity: asString(json['entity']),
    entityId: asString(json['entityId']),
    action: asString(json['action']),
    userId: asStringOrNull(json['userId']),
    userName: asStringOrNull(json['userName']),
    before: asJsonOrNull(json['before']),
    after: asJsonOrNull(json['after']),
    createdAt: asDateTimeOrNull(json['createdAt']),
  );

  final String id;
  final String entity;
  final String entityId;
  final String action;
  final String? userId;
  final String? userName;
  final Json? before;
  final Json? after;
  final DateTime? createdAt;
}

final auditRepositoryProvider = Provider<AuditRepository>(
  (ref) => AuditRepository(ref.watch(apiClientProvider)),
);

class AuditRepository {
  AuditRepository(this._api);

  final ApiClient _api;

  Future<Paged<AuditEntry>> list({
    String? entity,
    String? entityId,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/audit',
    AuditEntry.fromJson,
    query: {
      'entity': entity,
      'entityId': entityId,
      'offset': offset,
      'limit': limit,
    },
  );
}

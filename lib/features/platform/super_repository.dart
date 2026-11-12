import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import 'super_models.dart';

final superRepositoryProvider = Provider<SuperRepository>(
  (ref) => SuperRepository(ref.watch(apiClientProvider)),
);

/// Bumped after any change so lists and details reload.
final superRevisionProvider = NotifierProvider<SuperRevision, int>(
  SuperRevision.new,
);

class SuperRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final superOverviewProvider = FutureProvider.autoDispose<SuperOverview>((ref) {
  ref.watch(superRevisionProvider);
  return ref.watch(superRepositoryProvider).overview();
});

final superTenantProvider = FutureProvider.autoDispose
    .family<SuperTenantDetail, String>((ref, id) {
      ref.watch(superRevisionProvider);
      return ref.watch(superRepositoryProvider).tenant(id);
    });

/// The platform admin calls (`/platform/*`). There is no "sign in as" yet.
class SuperRepository {
  SuperRepository(this._api);

  final ApiClient _api;

  Future<SuperOverview> overview() async =>
      SuperOverview.fromJson(await _api.getJson('/platform/overview'));

  Future<Paged<SuperTenant>> tenants({
    String? q,
    String? status,
    String? plan,
    String? businessType,
    int offset = 0,
    int limit = 50,
  }) async => Paged.fromJson(
    await _api.getJson(
      '/platform/tenants',
      query: {
        'q': (q == null || q.isEmpty) ? null : q,
        'status': status,
        'plan': plan,
        'businessType': businessType,
        'offset': offset,
        'limit': limit,
      },
    ),
    SuperTenant.fromJson,
  );

  Future<SuperTenantDetail> tenant(String id) async =>
      SuperTenantDetail.fromJson(await _api.getJson('/platform/tenants/$id'));

  Future<void> suspend(String id, String reason) => _api.patchJson(
    '/platform/tenants/$id',
    body: {'status': 'suspended', 'reason': reason},
  );

  Future<void> reactivate(String id) =>
      _api.patchJson('/platform/tenants/$id', body: {'status': 'active'});

  Future<void> rename(String id, String name) =>
      _api.patchJson('/platform/tenants/$id', body: {'name': name});

  Future<void> updateCompany(String id, {String? plan, String? businessType}) =>
      _api.patchJson(
        '/platform/companies/$id',
        body: withoutNulls({'plan': plan, 'businessType': businessType}),
      );

  /// `deactivate`, `activate`, `unlock` or `sign-out`.
  Future<void> userAction(String userId, String action) =>
      _api.post('/platform/users/$userId/$action');

  Future<ResetLink> resetLink(String userId) async {
    final json = await _api.postJson('/platform/users/$userId/reset-link');
    return ResetLink(
      asString(json['link']),
      asDateTimeOrNull(json['expiresAt']),
    );
  }

  Future<List<SuperAuditEntry>> audit({int limit = 100}) async => asJsonList(
    (await _api.getJson('/platform/audit', query: {'limit': limit}))['data'],
  ).map(SuperAuditEntry.fromJson).toList();
}

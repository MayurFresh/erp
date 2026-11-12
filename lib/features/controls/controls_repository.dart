import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'controls_models.dart';

final controlsRepositoryProvider = Provider<ControlsRepository>(
  (ref) => ControlsRepository(ref.watch(apiClientProvider)),
);

/// Bumped after approving, rejecting, cancelling or submitting a request.
final approvalsRevisionProvider = NotifierProvider<ApprovalsRevision, int>(
  ApprovalsRevision.new,
);

class ApprovalsRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// Pending counts for the nav badge: `{ awaitingMe, mine }`.
final approvalCountProvider = FutureProvider.autoDispose<(int, int)>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(approvalsRevisionProvider);
  return ref.watch(controlsRepositoryProvider).approvalCount();
});

final approvalProvider = FutureProvider.autoDispose
    .family<ApprovalRequest, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(controlsRepositoryProvider).approval(id);
    });

/// Active custom fields of an entity (empty list when unavailable).
final customFieldsProvider = FutureProvider.autoDispose
    .family<List<CustomField>, String>((ref, entity) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(controlsRepositoryProvider).customFields(entity);
    });

final costCentresProvider = FutureProvider.autoDispose
    .family<List<CostCentre>, bool>((ref, includeInactive) {
      ref.watch(activeCompanyIdProvider);
      return ref
          .watch(controlsRepositoryProvider)
          .costCentres(includeInactive: includeInactive);
    });

/// Whether the company requires a cost centre on documents.
final costCentreRequiredProvider = FutureProvider.autoDispose<bool>((ref) {
  ref.watch(activeCompanyIdProvider);
  return ref.watch(controlsRepositoryProvider).costCentreRequired();
});

class ControlsRepository {
  ControlsRepository(this._api);

  final ApiClient _api;

  Future<bool> costCentreRequired() async =>
      asBool((await _api.getJson('/company'))['costCentreRequired']);

  Future<void> setCostCentreRequired(bool value) =>
      _api.patch('/company', body: {'costCentreRequired': value});

  Future<(int, int)> approvalCount() async {
    final res = await _api.getJson('/approvals/count');
    return (asInt(res['awaitingMe']), asInt(res['mine']));
  }

  Future<Paged<ApprovalRequest>> approvals({
    required String scope,
    String? status,
    String? docType,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/approvals',
    ApprovalRequest.fromJson,
    query: {
      'scope': scope,
      'status': status,
      'docType': docType,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<ApprovalRequest> approval(String id) async =>
      ApprovalRequest.fromJson(await _api.getJson('/approvals/$id'));

  Future<ApprovalRequest> approve(String id, {String? comment}) async =>
      ApprovalRequest.fromJson(
        await _api.postJson(
          '/approvals/$id/approve',
          body: {if (comment != null && comment.isNotEmpty) 'comment': comment},
        ),
      );

  Future<ApprovalRequest> reject(String id, String comment) async =>
      ApprovalRequest.fromJson(
        await _api.postJson(
          '/approvals/$id/reject',
          body: {'comment': comment},
        ),
      );

  Future<ApprovalRequest> cancel(String id) async =>
      ApprovalRequest.fromJson(await _api.postJson('/approvals/$id/cancel'));

  Future<List<ApprovalRule>> rules({String? docType}) async {
    final res = await _api.getJson(
      '/approval-rules',
      query: {'docType': docType},
    );
    return asJsonList(res['data']).map(ApprovalRule.fromJson).toList();
  }

  Future<void> createRule(Json body) =>
      _api.post('/approval-rules', body: body);

  Future<void> updateRule(String id, Json body) =>
      _api.patch('/approval-rules/$id', body: body);

  Future<void> deactivateRule(String id) => _api.delete('/approval-rules/$id');

  Future<List<CustomField>> customFields(
    String? entity, {
    bool includeInactive = false,
  }) async {
    final res = await _api.getJson(
      '/custom-fields',
      query: {'entity': entity, if (includeInactive) 'includeInactive': true},
    );
    return asJsonList(res['data']).map(CustomField.fromJson).toList();
  }

  Future<void> createCustomField(Json body) =>
      _api.post('/custom-fields', body: body);

  Future<void> updateCustomField(String id, Json body) =>
      _api.patch('/custom-fields/$id', body: body);

  Future<List<CostCentre>> costCentres({bool includeInactive = false}) async {
    final res = await _api.getJson(
      '/cost-centres',
      query: {if (includeInactive) 'includeInactive': true},
    );
    return asJsonList(res['data']).map(CostCentre.fromJson).toList();
  }

  Future<void> createCostCentre(Json body) =>
      _api.post('/cost-centres', body: body);

  Future<void> updateCostCentre(String id, Json body) =>
      _api.patch('/cost-centres/$id', body: body);

  Future<CostCentreReport> costCentreReport({String? from, String? to}) async =>
      CostCentreReport.fromJson(
        await _api.getJson(
          '/reports/cost-centres',
          query: {'from': from, 'to': to},
        ),
      );

  Future<String> importTemplate(String kind) =>
      _api.getText('/imports/templates/$kind');

  Future<ImportJob> createImport({
    required String kind,
    required String csv,
    String? fileName,
    String? asOf,
    bool updateExisting = false,
  }) async => ImportJob.fromJson(
    await _api.postJson(
      '/imports',
      body: {
        'kind': kind,
        'csv': csv,
        'fileName': ?fileName,
        'options': {'asOf': ?asOf, 'updateExisting': updateExisting},
      },
    ),
  );

  Future<Paged<ImportJob>> imports({int offset = 0, int limit = 50}) =>
      _api.getPage(
        '/imports',
        ImportJob.fromJson,
        query: {'offset': offset, 'limit': limit},
      );

  Future<ImportJob> importJob(String id) async =>
      ImportJob.fromJson(await _api.getJson('/imports/$id'));

  Future<ImportJob> commitImport(String id) async =>
      ImportJob.fromJson(await _api.postJson('/imports/$id/commit'));
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_client.dart';
import '../../../core/json.dart';
import '../../../core/providers.dart';
import '../../auth/session.dart';
import '../common/c_revisions.dart';
import '../models/labour_models.dart';
import '../models/subcontract_models.dart';
import 'construction_repository.dart';

final subcontractRepositoryProvider = Provider<SubcontractRepository>(
  (ref) => SubcontractRepository(ref.watch(apiClientProvider)),
);

/// Labour advances, work orders and RA bills (API v1.3).
class SubcontractRepository {
  SubcontractRepository(this._api);

  /// Action endpoints take no fields but the server rejects a JSON request
  /// without a body, so they get `{}`.
  static const Map<String, dynamic> _noBody = {};

  final ApiClient _api;

  // ---------------------------------------------------------- labour advances

  Future<Paged<LabourAdvance>> labourAdvances({
    String? q,
    String? workerId,
    String? siteId,
    LabourAdvanceStatus? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/labour-advances',
    LabourAdvance.fromJson,
    query: {
      'q': q,
      'workerId': workerId,
      'siteId': siteId,
      'status': status?.name,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<LabourAdvance> labourAdvance(String id) async =>
      LabourAdvance.fromJson(await _api.getJson('/labour-advances/$id'));

  Future<LabourAdvance> createLabourAdvance({
    required String workerId,
    required double amount,
    required String paidFromAccountId,
    String? date,
    String? notes,
  }) async => LabourAdvance.fromJson(
    await _api.postJson(
      '/labour-advances',
      body: withoutNulls({
        'workerId': workerId,
        'date': date,
        'amount': amount,
        'paidFromAccountId': paidFromAccountId,
        'notes': notes,
      }),
    ),
  );

  Future<LabourAdvance> cancelLabourAdvance(String id, String reason) async =>
      LabourAdvance.fromJson(
        await _api.postJson(
          '/labour-advances/$id/cancel',
          body: {'reason': reason},
        ),
      );

  // -------------------------------------------------------------- work orders

  Future<Paged<WorkOrder>> workOrders({
    String? q,
    String? projectId,
    String? contractorId,
    WorkOrderStatus? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/work-orders',
    WorkOrder.fromJson,
    query: {
      'q': q,
      'projectId': projectId,
      'contractorId': contractorId,
      'status': status?.name,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<WorkOrder> workOrder(String id) async =>
      WorkOrder.fromJson(await _api.getJson('/work-orders/$id'));

  /// [body] as built by the work-order form.
  Future<WorkOrder> createWorkOrder(Json body) async => WorkOrder.fromJson(
    await _api.postJson('/work-orders', body: withoutNulls(body)),
  );

  /// `null` values clear optional fields, so the body is sent as is.
  Future<WorkOrder> updateWorkOrder(String id, Json body) async =>
      WorkOrder.fromJson(await _api.patchJson('/work-orders/$id', body: body));

  Future<WorkOrder> _workOrderAction(
    String id,
    String action, [
    Json body = _noBody,
  ]) async => WorkOrder.fromJson(
    await _api.postJson('/work-orders/$id/$action', body: body),
  );

  Future<WorkOrder> activateWorkOrder(String id) =>
      _workOrderAction(id, 'activate');

  Future<WorkOrder> closeWorkOrder(String id) => _workOrderAction(id, 'close');

  Future<WorkOrder> cancelWorkOrder(String id, String reason) =>
      _workOrderAction(id, 'cancel', {'reason': reason});

  Future<List<ContractorAdvance>> contractorAdvances(
    String workOrderId,
  ) async => (await _api.getPage(
    '/work-orders/$workOrderId/advances',
    ContractorAdvance.fromJson,
  )).data;

  Future<ContractorAdvance> payContractorAdvance(
    String workOrderId, {
    required double amount,
    required String paidFromAccountId,
    String? date,
    String? notes,
  }) async => ContractorAdvance.fromJson(
    await _api.postJson(
      '/work-orders/$workOrderId/advances',
      body: withoutNulls({
        'date': date,
        'amount': amount,
        'paidFromAccountId': paidFromAccountId,
        'notes': notes,
      }),
    ),
  );

  Future<ContractorAdvance> cancelContractorAdvance(
    String id,
    String reason,
  ) async => ContractorAdvance.fromJson(
    await _api.postJson(
      '/contractor-advances/$id/cancel',
      body: {'reason': reason},
    ),
  );

  Future<List<RetentionRelease>> retentionReleases(String workOrderId) async =>
      (await _api.getPage(
        '/work-orders/$workOrderId/retention-releases',
        RetentionRelease.fromJson,
      )).data;

  Future<RetentionRelease> releaseRetention(
    String workOrderId, {
    required double amount,
    String? date,
    String? notes,
  }) async => RetentionRelease.fromJson(
    await _api.postJson(
      '/work-orders/$workOrderId/retention-releases',
      body: withoutNulls({'date': date, 'amount': amount, 'notes': notes}),
    ),
  );

  /// The unsaved next bill: `prevQty` per line, `cumQty = prevQty`.
  Future<RaBill> raBillTemplate(String workOrderId) async => RaBill.fromJson(
    await _api.getJson('/work-orders/$workOrderId/ra-bill-template'),
  );

  // ----------------------------------------------------------------- RA bills

  Future<Paged<RaBill>> raBills({
    String? q,
    String? workOrderId,
    String? projectId,
    String? contractorId,
    RaBillStatus? status,
    RaPaymentStatus? paymentStatus,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/ra-bills',
    RaBill.fromJson,
    query: {
      'q': q,
      'workOrderId': workOrderId,
      'projectId': projectId,
      'contractorId': contractorId,
      'status': status?.name,
      'paymentStatus': paymentStatus?.name,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<RaBill> raBill(String id) async =>
      RaBill.fromJson(await _api.getJson('/ra-bills/$id'));

  Future<RaBill> createRaBill(Json body) async =>
      RaBill.fromJson(await _api.postJson('/ra-bills', body: body));

  Future<RaBill> updateRaBill(String id, Json body) async =>
      RaBill.fromJson(await _api.patchJson('/ra-bills/$id', body: body));

  Future<RaBill> _raAction(
    String id,
    String action, [
    Json body = _noBody,
  ]) async =>
      RaBill.fromJson(await _api.postJson('/ra-bills/$id/$action', body: body));

  Future<RaBill> submitRaBill(String id) => _raAction(id, 'submit');

  Future<RaBill> approveRaBill(String id) => _raAction(id, 'approve');

  Future<RaBill> rejectRaBill(String id, String reason) =>
      _raAction(id, 'reject', {'reason': reason});

  Future<RaBill> cancelRaBill(String id, String reason) =>
      _raAction(id, 'cancel', {'reason': reason});
}

SubcontractRepository _repo(Ref ref) =>
    ref.watch(subcontractRepositoryProvider);

final labourAdvanceProvider = FutureProvider.autoDispose
    .family<LabourAdvance, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watchC(const [CKind.labourAdvances]);
      return _repo(ref).labourAdvance(id);
    });

final workOrderProvider = FutureProvider.autoDispose.family<WorkOrder, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchC(const [CKind.workOrders, CKind.raBills]);
  return _repo(ref).workOrder(id);
});

final workOrderAdvancesProvider = FutureProvider.autoDispose
    .family<List<ContractorAdvance>, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watchC(const [CKind.workOrders]);
      return _repo(ref).contractorAdvances(id);
    });

final workOrderReleasesProvider = FutureProvider.autoDispose
    .family<List<RetentionRelease>, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watchC(const [CKind.workOrders, CKind.raBills]);
      return _repo(ref).retentionReleases(id);
    });

final workOrderBillsProvider = FutureProvider.autoDispose
    .family<List<RaBill>, String>((ref, workOrderId) async {
      ref.watch(activeCompanyIdProvider);
      ref.watchC(const [CKind.raBills]);
      return (await _repo(
        ref,
      ).raBills(workOrderId: workOrderId, limit: 200)).data;
    });

final raBillProvider = FutureProvider.autoDispose.family<RaBill, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchC(const [CKind.raBills]);
  return _repo(ref).raBill(id);
});

final raBillTemplateProvider = FutureProvider.autoDispose
    .family<RaBill, String>((ref, workOrderId) {
      ref.watch(activeCompanyIdProvider);
      ref.watchC(const [CKind.raBills, CKind.workOrders]);
      return _repo(ref).raBillTemplate(workOrderId);
    });

/// Active work orders (up to 200) for the RA bill form's picker.
final activeWorkOrdersProvider = FutureProvider.autoDispose<List<WorkOrder>>((
  ref,
) async {
  ref.watch(activeCompanyIdProvider);
  ref.watchC(const [CKind.workOrders]);
  return (await _repo(
    ref,
  ).workOrders(status: WorkOrderStatus.active, limit: 200)).data;
});

/// Workers in scope (up to 200), for pickers and filters.
final workersLookupProvider = FutureProvider.autoDispose<List<Worker>>((
  ref,
) async {
  ref.watch(activeCompanyIdProvider);
  ref.watchC(const [CKind.workers, CKind.labourAdvances]);
  return (await ref.watch(constructionRepositoryProvider).workers(limit: 200))
      .data;
});

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import '../fulfilment/fulfilment_models.dart';
import '../returns/return_models.dart';
import 'sales_order_models.dart';

/// Bumped after any order-to-cash write so lists and details reload.
final o2cRevisionProvider = NotifierProvider<O2cRevision, int>(O2cRevision.new);

class O2cRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final o2cRepositoryProvider = Provider<O2cRepository>(
  (ref) => O2cRepository(ref.watch(apiClientProvider)),
);

final salesOrderProvider = FutureProvider.autoDispose
    .family<SalesOrder, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(o2cRevisionProvider);
      return ref.watch(o2cRepositoryProvider).order(id);
    });

final pickListProvider = FutureProvider.autoDispose.family<PickList, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(o2cRevisionProvider);
  return ref.watch(o2cRepositoryProvider).pickList(id);
});

final shipmentProvider = FutureProvider.autoDispose.family<Shipment, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(o2cRevisionProvider);
  return ref.watch(o2cRepositoryProvider).shipment(id);
});

final salesReturnProvider = FutureProvider.autoDispose
    .family<SalesReturn, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(o2cRevisionProvider);
      return ref.watch(o2cRepositoryProvider).salesReturn(id);
    });

class O2cRepository {
  O2cRepository(this._api);

  final ApiClient _api;

  // Orders
  Future<Paged<SalesOrder>> orders({
    String? q,
    String? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/sales-orders',
    SalesOrder.fromJson,
    query: {'q': q, 'status': status, 'offset': offset, 'limit': limit},
  );

  Future<SalesOrder> order(String id) async =>
      SalesOrder.fromJson(await _api.getJson('/sales-orders/$id'));

  Future<Paged<Availability>> availability({
    required String locationId,
    String? q,
    int offset = 0,
    int limit = 30,
  }) => _api.getPage(
    '/sales-orders/availability',
    Availability.fromJson,
    query: {'locationId': locationId, 'q': q, 'offset': offset, 'limit': limit},
  );

  Future<SalesOrder> createOrder(SalesOrderInput input) async =>
      SalesOrder.fromJson(
        await _api.postJson('/sales-orders', body: input.toJson()),
      );

  Future<SalesOrder> updateOrder(
    String id,
    SalesOrderInput input, {
    DateTime? expectedUpdatedAt,
  }) async => SalesOrder.fromJson(
    await _api.patchJson(
      '/sales-orders/$id',
      body: {
        ...input.toJson(),
        if (expectedUpdatedAt != null)
          'expectedUpdatedAt': expectedUpdatedAt.toUtc().toIso8601String(),
      },
    ),
  );

  Future<SalesOrder> orderAction(
    String id,
    String action, {
    Json? body,
  }) async => SalesOrder.fromJson(
    await _api.postJson('/sales-orders/$id/$action', body: body ?? {}),
  );

  Future<ScanResult> packScan(
    String orderId, {
    required String scanId,
    required String code,
    double qty = 1,
  }) async => ScanResult.fromJson(
    await _api.postJson(
      '/sales-orders/$orderId/pack-scans',
      body: {'scanId': scanId, 'code': code, 'qty': qty},
    ),
  );

  Future<SalesOrder> pack(String orderId) async => SalesOrder.fromJson(
    await _api.postJson('/sales-orders/$orderId/pack', body: {}),
  );

  /// Dispatch creates an invoice, so every retry of one attempt must reuse
  /// [idempotencyKey].
  Future<Json> dispatch(
    String orderId, {
    required String idempotencyKey,
    required Json body,
  }) => _api.postJson(
    '/sales-orders/$orderId/dispatch',
    body: body,
    idempotencyKey: idempotencyKey,
  );

  // Pick lists
  Future<Paged<PickListSummary>> pickLists({
    String? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/pick-lists',
    PickListSummary.fromJson,
    query: {'status': status, 'offset': offset, 'limit': limit},
  );

  Future<PickList> pickList(String id) async =>
      PickList.fromJson(await _api.getJson('/pick-lists/$id'));

  Future<PickList> createPickList(
    String locationId,
    List<String> orderIds,
  ) async => PickList.fromJson(
    await _api.postJson(
      '/pick-lists',
      body: {'locationId': locationId, 'orderIds': orderIds},
    ),
  );

  Future<ScanResult> pickScan(
    String id, {
    required String scanId,
    required String code,
    double qty = 1,
  }) async => ScanResult.fromJson(
    await _api.postJson(
      '/pick-lists/$id/scan',
      body: {'scanId': scanId, 'code': code, 'qty': qty},
    ),
  );

  Future<void> pickListAction(String id, String action) async {
    await _api.postJson('/pick-lists/$id/$action', body: {});
  }

  // Shipments
  Future<Paged<Shipment>> shipments({
    String? q,
    String? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/shipments',
    Shipment.fromJson,
    query: {'q': q, 'status': status, 'offset': offset, 'limit': limit},
  );

  Future<Shipment> shipment(String id) async =>
      Shipment.fromJson(await _api.getJson('/shipments/$id'));

  Future<Shipment> shipmentStatus(
    String id, {
    required String status,
    String? note,
    String? courier,
    String? awb,
  }) async => Shipment.fromJson(
    await _api.postJson(
      '/shipments/$id/status',
      body: {'status': status, 'note': ?note, 'courier': ?courier, 'awb': ?awb},
    ),
  );

  // Returns
  Future<Paged<SalesReturn>> returns({
    String? q,
    String? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/sales-returns',
    SalesReturn.fromJson,
    query: {'q': q, 'status': status, 'offset': offset, 'limit': limit},
  );

  Future<SalesReturn> salesReturn(String id) async =>
      SalesReturn.fromJson(await _api.getJson('/sales-returns/$id'));

  Future<SalesReturn> createReturn({
    required String orderId,
    required String reason,
    required List<Json> lines,
  }) async => SalesReturn.fromJson(
    await _api.postJson(
      '/sales-returns',
      body: {'orderId': orderId, 'reason': reason, 'lines': lines},
    ),
  );

  Future<SalesReturn> returnAction(
    String id,
    String action, {
    Json? body,
  }) async => SalesReturn.fromJson(
    await _api.postJson('/sales-returns/$id/$action', body: body ?? {}),
  );
}

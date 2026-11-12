import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import '../purchases/purchase_model.dart';
import 'po_models.dart';

/// Purchase order changes bump these kinds (there is no dedicated one).
const poKinds = [DataKind.purchases, DataKind.stock];

final poRepositoryProvider = Provider<PoRepository>(
  (ref) => PoRepository(ref.watch(apiClientProvider)),
);

final purchaseOrderProvider = FutureProvider.autoDispose
    .family<PurchaseOrder, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watchRevisions(poKinds);
      return ref.watch(poRepositoryProvider).get(id);
    });

final goodsReceiptsProvider = FutureProvider.autoDispose
    .family<List<GoodsReceipt>, String>((ref, poId) {
      ref.watch(activeCompanyIdProvider);
      ref.watchRevisions(poKinds);
      return ref.watch(poRepositoryProvider).receiptsFor(poId);
    });

final reorderSuggestionsProvider = FutureProvider.autoDispose
    .family<List<ReorderSuggestion>, String?>((ref, locationId) {
      ref.watch(activeCompanyIdProvider);
      ref.watchRevisions(poKinds);
      return ref.watch(poRepositoryProvider).reorder(locationId);
    });

class PoRepository {
  PoRepository(this._api);

  final ApiClient _api;

  Future<Paged<PurchaseOrder>> list({
    String? q,
    String? status,
    String? partyId,
    String? locationId,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/purchase-orders',
    PurchaseOrder.fromJson,
    query: {
      'q': q,
      'status': status,
      'partyId': partyId,
      'locationId': locationId,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<PurchaseOrder> get(String id) async =>
      PurchaseOrder.fromJson(await _api.getJson('/purchase-orders/$id'));

  Future<PurchaseOrder> preview(PoDraft draft) async => PurchaseOrder.fromJson(
    await _api.postJson('/purchase-orders/preview', body: draft.toJson()),
  );

  Future<PurchaseOrder> create(PoDraft draft) async => PurchaseOrder.fromJson(
    await _api.postJson('/purchase-orders', body: draft.toJson()),
  );

  /// The client has no PUT; the server accepts PATCH with the full body.
  Future<PurchaseOrder> update(
    String id,
    PoDraft draft, {
    DateTime? expectedUpdatedAt,
  }) async => PurchaseOrder.fromJson(
    await _api.patchJson(
      '/purchase-orders/$id',
      body: {
        ...draft.toJson(),
        if (expectedUpdatedAt != null)
          'expectedUpdatedAt': expectedUpdatedAt.toUtc().toIso8601String(),
      },
    ),
  );

  Future<PurchaseOrder> _action(String id, String action, [Json? body]) async =>
      PurchaseOrder.fromJson(
        await _api.postJson('/purchase-orders/$id/$action', body: body),
      );

  Future<PurchaseOrder> submit(String id) => _action(id, 'submit');

  Future<PurchaseOrder> send(String id) => _action(id, 'send');

  Future<PurchaseOrder> cancel(String id, String reason) =>
      _action(id, 'cancel', {'reason': reason});

  Future<List<GoodsReceipt>> receiptsFor(String poId) async =>
      (await _api.getPage(
        '/goods-receipts',
        GoodsReceipt.fromJson,
        query: {'purchaseOrderId': poId, 'limit': 100},
      )).data;

  Future<GoodsReceipt> receipt(String id) async =>
      GoodsReceipt.fromJson(await _api.getJson('/goods-receipts/$id'));

  Future<GoodsReceipt> receive({
    required String purchaseOrderId,
    required String receiptDate,
    String? challanNo,
    String? vehicleNo,
    String? notes,
    required List<Json> lines,
  }) async => GoodsReceipt.fromJson(
    await _api.postJson(
      '/goods-receipts',
      body: withoutNulls({
        'purchaseOrderId': purchaseOrderId,
        'receiptDate': receiptDate,
        'challanNo': challanNo,
        'vehicleNo': vehicleNo,
        'notes': notes,
        'lines': lines,
      }),
    ),
  );

  Future<GoodsReceipt> cancelReceipt(String id, String reason) async =>
      GoodsReceipt.fromJson(
        await _api.postJson(
          '/goods-receipts/$id/cancel',
          body: {'reason': reason},
        ),
      );

  /// Posts a bill built from receipt lines (`grnLineId` on each line).
  /// Sent as plain JSON so the bill model needs no change.
  Future<Purchase> createBillFromGrn(Json body) async =>
      Purchase.fromJson(await _api.postJson('/purchases', body: body));

  Future<List<ReorderSuggestion>> reorder(String? locationId) async =>
      (await _api.getPage(
        '/reorder-suggestions',
        ReorderSuggestion.fromJson,
        query: {'locationId': locationId},
      )).data;

  Future<List<PurchaseOrder>> createFromSuggestions(
    List<Json> selections,
  ) async {
    final res = await _api.postJson(
      '/reorder-suggestions/purchase-orders',
      body: {'selections': selections},
    );
    return asJsonList(res['data']).map(PurchaseOrder.fromJson).toList();
  }
}

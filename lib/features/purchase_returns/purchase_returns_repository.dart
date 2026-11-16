import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import '../documents/document_models.dart';
import 'purchase_return_model.dart';

final purchaseReturnsRepositoryProvider = Provider<PurchaseReturnsRepository>(
  (ref) => PurchaseReturnsRepository(ref.watch(apiClientProvider)),
);

final purchaseReturnProvider = FutureProvider.autoDispose
    .family<PurchaseReturn, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(revisionProvider(DataKind.purchaseReturns));
      return ref.watch(purchaseReturnsRepositoryProvider).get(id);
    });

class PurchaseReturnsRepository {
  PurchaseReturnsRepository(this._api);

  final ApiClient _api;

  Future<Paged<PurchaseReturn>> list({
    String? q,
    DocStatus? status,
    String? kind,
    String? purchaseId,
    String? partyId,
    String? from,
    String? to,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/purchase-returns',
    PurchaseReturn.fromJson,
    query: {
      'q': q,
      'status': status?.name,
      'kind': kind,
      'purchaseId': purchaseId,
      'partyId': partyId,
      'from': from,
      'to': to,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<PurchaseReturn> get(String id) async =>
      PurchaseReturn.fromJson(await _api.getJson('/purchase-returns/$id'));

  Future<PurchaseReturn> create(PurchaseReturnDraft draft) async =>
      PurchaseReturn.fromJson(
        await _api.postJson('/purchase-returns', body: draft.toJson()),
      );

  Future<PurchaseReturn> cancel(String id, String reason) async =>
      PurchaseReturn.fromJson(
        await _api.postJson(
          '/purchase-returns/$id/cancel',
          body: {'reason': reason},
        ),
      );
}

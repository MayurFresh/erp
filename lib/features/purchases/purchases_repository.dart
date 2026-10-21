import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import '../documents/document_models.dart';
import 'purchase_model.dart';

final purchasesRepositoryProvider = Provider<PurchasesRepository>(
  (ref) => PurchasesRepository(ref.watch(apiClientProvider)),
);

final purchaseProvider = FutureProvider.autoDispose.family<Purchase, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchRevisions(const [DataKind.purchases, DataKind.payments]);
  return ref.watch(purchasesRepositoryProvider).get(id);
});

class PurchasesRepository {
  PurchasesRepository(this._api);

  final ApiClient _api;

  Future<Paged<Purchase>> list({
    String? q,
    DocStatus? status,
    PaymentStatus? paymentStatus,
    String? from,
    String? to,
    String? locationId,
    String? partyId,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/purchases',
    Purchase.fromJson,
    query: {
      'q': q,
      'status': status?.name,
      'paymentStatus': paymentStatus?.name,
      'from': from,
      'to': to,
      'locationId': locationId,
      'partyId': partyId,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Purchase> get(String id) async =>
      Purchase.fromJson(await _api.getJson('/purchases/$id'));

  /// Totals without saving (`id` and `number` are null).
  Future<Purchase> preview(PurchaseDraft draft) async => Purchase.fromJson(
    await _api.postJson('/purchases/preview', body: draft.toJson()),
  );

  Future<Purchase> create(PurchaseDraft draft) async => Purchase.fromJson(
    await _api.postJson('/purchases', body: draft.toJson()),
  );

  Future<Purchase> cancel(String id, String reason) async => Purchase.fromJson(
    await _api.postJson('/purchases/$id/cancel', body: {'reason': reason}),
  );
}

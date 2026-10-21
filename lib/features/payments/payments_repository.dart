import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import '../documents/document_models.dart';
import 'payment_model.dart';

final paymentsRepositoryProvider = Provider<PaymentsRepository>(
  (ref) => PaymentsRepository(ref.watch(apiClientProvider)),
);

final paymentProvider = FutureProvider.autoDispose.family<Payment, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(revisionProvider(DataKind.payments));
  return ref.watch(paymentsRepositoryProvider).get(id);
});

/// Open invoices and purchases of a party, oldest first.
final outstandingProvider = FutureProvider.autoDispose
    .family<Outstanding, String>((ref, partyId) {
      ref.watch(activeCompanyIdProvider);
      ref.watchRevisions(moneyKinds);
      return ref.watch(paymentsRepositoryProvider).outstanding(partyId);
    });

class PaymentsRepository {
  PaymentsRepository(this._api);

  final ApiClient _api;

  Future<Paged<Payment>> list({
    PaymentKind? kind,
    String? q,
    String? partyId,
    String? from,
    String? to,
    DocStatus? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/payments',
    Payment.fromJson,
    query: {
      'kind': kind?.name,
      'q': q,
      'partyId': partyId,
      'from': from,
      'to': to,
      'status': status?.name,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Payment> get(String id) async =>
      Payment.fromJson(await _api.getJson('/payments/$id'));

  Future<Payment> create(PaymentDraft draft) async =>
      Payment.fromJson(await _api.postJson('/payments', body: draft.toJson()));

  /// Releases the allocations.
  Future<Payment> cancel(String id, String reason) async => Payment.fromJson(
    await _api.postJson('/payments/$id/cancel', body: {'reason': reason}),
  );

  Future<Outstanding> outstanding(String partyId) async =>
      Outstanding.fromJson(await _api.getJson('/parties/$partyId/outstanding'));
}

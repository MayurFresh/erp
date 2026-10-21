import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'invoice_model.dart';

final invoicesRepositoryProvider = Provider<InvoicesRepository>(
  (ref) => InvoicesRepository(ref.watch(apiClientProvider)),
);

final invoiceProvider = FutureProvider.autoDispose.family<Invoice, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchRevisions(const [
    DataKind.invoices,
    DataKind.payments,
    DataKind.creditNotes,
  ]);
  return ref.watch(invoicesRepositoryProvider).get(id);
});

class InvoicesRepository {
  InvoicesRepository(this._api);

  final ApiClient _api;

  Future<Paged<Invoice>> list({
    String? q,
    InvoiceStatus? status,
    String? from,
    String? to,
    String? locationId,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/invoices',
    Invoice.fromJson,
    query: {
      'q': q,
      'status': status?.name,
      'from': from,
      'to': to,
      'locationId': locationId,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Invoice> get(String id) async =>
      Invoice.fromJson(await _api.getJson('/invoices/$id'));

  /// Computes totals without saving (`id` and `number` are null).
  Future<Invoice> preview(InvoiceDraft draft) async => Invoice.fromJson(
    await _api.postJson('/invoices/preview', body: draft.toJson()),
  );

  Future<Invoice> create(InvoiceDraft draft) async =>
      Invoice.fromJson(await _api.postJson('/invoices', body: draft.toJson()));

  Future<Invoice> cancel(String id, String reason) async => Invoice.fromJson(
    await _api.postJson('/invoices/$id/cancel', body: {'reason': reason}),
  );
}

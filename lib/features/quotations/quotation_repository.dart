import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'quotation_models.dart';

/// Bumped after any quotation write so lists and details reload.
final quotationRevisionProvider = NotifierProvider<QuotationRevision, int>(
  QuotationRevision.new,
);

class QuotationRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final quotationRepositoryProvider = Provider<QuotationRepository>(
  (ref) => QuotationRepository(ref.watch(apiClientProvider)),
);

final quotationProvider = FutureProvider.autoDispose.family<Quotation, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(quotationRevisionProvider);
  return ref.watch(quotationRepositoryProvider).get(id);
});

class QuotationRepository {
  QuotationRepository(this._api);

  final ApiClient _api;

  Future<Paged<Quotation>> list({
    String? q,
    String? status,
    String? kind,
    String? partyId,
    String? dealId,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/quotations',
    Quotation.fromJson,
    query: {
      'q': q,
      'status': status,
      'kind': kind,
      'partyId': partyId,
      'dealId': dealId,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Quotation> get(String id) async =>
      Quotation.fromJson(await _api.getJson('/quotations/$id'));

  Future<Quotation> create(QuotationInput input) async => Quotation.fromJson(
    await _api.postJson('/quotations', body: input.toJson()),
  );

  Future<Quotation> update(
    String id,
    QuotationInput input, {
    DateTime? expectedUpdatedAt,
  }) async => Quotation.fromJson(
    await _api.patchJson(
      '/quotations/$id',
      body: {
        ...input.toJson(),
        if (expectedUpdatedAt != null)
          'expectedUpdatedAt': expectedUpdatedAt.toUtc().toIso8601String(),
      },
    ),
  );

  /// `send`, `accept`, `decline` (with `reason`), `cancel` or `revise`.
  Future<Quotation> action(String id, String action, {String? reason}) async =>
      Quotation.fromJson(
        await _api.postJson(
          '/quotations/$id/$action',
          body: {'reason': ?reason},
        ),
      );

  Future<ConvertResult> convert(
    String id,
    String to, {
    String? locationId,
  }) async => ConvertResult.fromJson(
    await _api.postJson(
      '/quotations/$id/convert',
      body: {'to': to, 'locationId': ?locationId},
    ),
  );
}

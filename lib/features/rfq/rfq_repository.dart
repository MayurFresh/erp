import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'rfq_models.dart';

final rfqRepositoryProvider = Provider<RfqRepository>(
  (ref) => RfqRepository(ref.watch(apiClientProvider)),
);

final rfqProvider = FutureProvider.autoDispose.family<Rfq, String>((ref, id) {
  ref.watch(activeCompanyIdProvider);
  ref.watchRevisions(const [DataKind.purchases]);
  return ref.watch(rfqRepositoryProvider).get(id);
});

class RfqRepository {
  RfqRepository(this._api);

  final ApiClient _api;

  Future<Paged<Rfq>> list({
    String? q,
    String? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/rfqs',
    Rfq.fromJson,
    query: {'q': q, 'status': status, 'offset': offset, 'limit': limit},
  );

  Future<Rfq> get(String id) async =>
      Rfq.fromJson(await _api.getJson('/rfqs/$id'));

  Future<Rfq> create(Json body) async =>
      Rfq.fromJson(await _api.postJson('/rfqs', body: body));

  Future<Rfq> update(String id, Json body) async =>
      Rfq.fromJson(await _api.patchJson('/rfqs/$id', body: body));

  Future<void> delete(String id) async {
    await _api.delete('/rfqs/$id');
  }

  Future<Rfq> send(String id) async =>
      Rfq.fromJson(await _api.postJson('/rfqs/$id/send'));

  Future<Rfq> saveQuotes(String id, String partyId, List<Json> quotes) async =>
      Rfq.fromJson(
        await _api.patchJson(
          '/rfqs/$id/quotes',
          body: {'partyId': partyId, 'quotes': quotes},
        ),
      );

  Future<Rfq> choose(String id, {String? lineId, String? partyId}) async =>
      Rfq.fromJson(
        await _api.patchJson(
          '/rfqs/$id/choices',
          body: lineId == null
              ? {'mode': 'lowest'}
              : {
                  'choices': [
                    {'lineId': lineId, 'partyId': partyId},
                  ],
                },
        ),
      );

  Future<Rfq> convert(String id) async =>
      Rfq.fromJson(await _api.postJson('/rfqs/$id/convert'));

  Future<Rfq> close(String id) async =>
      Rfq.fromJson(await _api.postJson('/rfqs/$id/close'));

  /// Approved indents to start a request from.
  Future<List<Json>> approvedIndents(String q) async {
    final page = await _api.getJson(
      '/indents',
      query: {'status': 'approved', 'q': q, 'limit': 30},
    );
    return asJsonList(page['data']);
  }
}
